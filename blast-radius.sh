#!/usr/bin/env bash
#
# blast-radius.sh
#
# Determines which microservices are affected by changes in shared packages.
# Uses Go's dependency graph to find transitive consumers of changed packages.
#
# Usage:
#   ./scripts/blast-radius.sh                          # auto-detect changed shared packages (vs main/HEAD~1)
#   ./scripts/blast-radius.sh --base v1.2.3 --head v1.2.4
#   ./scripts/blast-radius.sh --packages "shared/models,shared/auth"
#   ./scripts/blast-radius.sh --all                    # show full dependency map
#
# Output modes:
#   --format list     (default) newline-separated service names
#   --format json     JSON array for CI matrix consumption
#   --format detail   show which packages affect which services
#
# Configuration (env vars or flags):
#   SERVICES_DIR      directory containing services (default: "services")
#   SHARED_DIRS       comma-separated shared package dirs (default: "shared,pkg,internal/common")
#   MODULE_ROOT       go module root (auto-detected from go.mod)

set -euo pipefail

# --- Defaults ---
SERVICES_DIR="${SERVICES_DIR:-services}"
SHARED_DIRS="${SHARED_DIRS:-shared,pkg,internal/common}"
FORMAT="list"
BASE_REF=""
HEAD_REF=""
EXPLICIT_PACKAGES=""
SHOW_ALL=false
VERBOSE=false

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)       BASE_REF="$2"; shift 2 ;;
        --head)       HEAD_REF="$2"; shift 2 ;;
        --packages)   EXPLICIT_PACKAGES="$2"; shift 2 ;;
        --format)     FORMAT="$2"; shift 2 ;;
        --services-dir) SERVICES_DIR="$2"; shift 2 ;;
        --shared-dirs)  SHARED_DIRS="$2"; shift 2 ;;
        --all)        SHOW_ALL=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        --help|-h)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

log() {
    if $VERBOSE; then
        echo "[blast-radius] $*" >&2
    fi
}

# --- Detect module root ---
if [[ ! -f go.mod ]]; then
    echo "Error: go.mod not found. Run from repo root." >&2
    exit 1
fi
MODULE_ROOT=$(head -1 go.mod | awk '{print $2}')
log "Module root: $MODULE_ROOT"

# --- Discover services ---
declare -a SERVICES=()
if [[ ! -d "$SERVICES_DIR" ]]; then
    echo "Error: services directory '$SERVICES_DIR' not found." >&2
    exit 1
fi

for svc_dir in "$SERVICES_DIR"/*/; do
    if [[ -f "${svc_dir}main.go" ]] || [[ -f "${svc_dir}cmd/main.go" ]] || ls "${svc_dir}"*.go &>/dev/null; then
        svc_name=$(basename "$svc_dir")
        SERVICES+=("$svc_name")
    fi
done

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    echo "Error: no services found in '$SERVICES_DIR'." >&2
    exit 1
fi
log "Found ${#SERVICES[@]} services: ${SERVICES[*]}"

# --- Build dependency map: service -> list of internal packages it imports ---
declare -A SVC_DEPS

build_dependency_map() {
    log "Building dependency map..."
    for svc in "${SERVICES[@]}"; do
        svc_path="./${SERVICES_DIR}/${svc}/..."

        # Get all dependencies including transitive, filter to our module only
        deps=$(go list -deps $svc_path 2>/dev/null \
            | grep "^${MODULE_ROOT}/" \
            | grep -v "^${MODULE_ROOT}/${SERVICES_DIR}/${svc}" \
            || true)

        SVC_DEPS[$svc]="$deps"
        dep_count=$(echo "$deps" | grep -c . || true)
        log "  $svc depends on $dep_count internal packages"
    done
}

# --- Determine which shared packages changed ---
find_changed_packages() {
    local changed_files=""

    if [[ -n "$EXPLICIT_PACKAGES" ]]; then
        # Packages explicitly provided — convert to module paths
        IFS=',' read -ra pkg_dirs <<< "$EXPLICIT_PACKAGES"
        for dir in "${pkg_dirs[@]}"; do
            dir=$(echo "$dir" | xargs)  # trim whitespace
            echo "${MODULE_ROOT}/${dir}"
        done
        return
    fi

    # Auto-detect from git diff
    local base="${BASE_REF:-HEAD~1}"
    local head="${HEAD_REF:-HEAD}"

    log "Diffing $base..$head"
    changed_files=$(git diff --name-only "$base" "$head" 2>/dev/null || true)

    if [[ -z "$changed_files" ]]; then
        log "No changed files detected"
        return
    fi

    # Filter to shared directories only
    IFS=',' read -ra shared_dirs <<< "$SHARED_DIRS"
    local shared_changes=""
    for dir in "${shared_dirs[@]}"; do
        dir=$(echo "$dir" | xargs)
        matches=$(echo "$changed_files" | grep "^${dir}/" || true)
        if [[ -n "$matches" ]]; then
            shared_changes="${shared_changes}${matches}"$'\n'
        fi
    done

    if [[ -z "$shared_changes" ]]; then
        log "No changes in shared directories"
        return
    fi

    # Convert file paths to Go package paths (deduplicated)
    echo "$shared_changes" \
        | grep '\.go$' \
        | xargs -I{} dirname {} \
        | sort -u \
        | while read -r pkg_dir; do
            echo "${MODULE_ROOT}/${pkg_dir}"
        done
}

# --- Find affected services ---
find_affected_services() {
    local changed_packages="$1"

    if [[ -z "$changed_packages" ]]; then
        return
    fi

    declare -A AFFECTED           # service -> 1
    declare -A AFFECTED_BY        # service -> list of changed packages that affect it

    for svc in "${SERVICES[@]}"; do
        local svc_deps="${SVC_DEPS[$svc]}"

        while IFS= read -r changed_pkg; do
            [[ -z "$changed_pkg" ]] && continue

            # Check if this service depends on the changed package
            # (exact match or sub-package match)
            if echo "$svc_deps" | grep -q "^${changed_pkg}$\|^${changed_pkg}/"; then
                AFFECTED[$svc]=1
                AFFECTED_BY[$svc]="${AFFECTED_BY[$svc]:-}${changed_pkg}"$'\n'
            fi
        done <<< "$changed_packages"
    done

    # Also check if the service's own code changed (direct service changes)
    if [[ -n "$BASE_REF" ]] || [[ -z "$EXPLICIT_PACKAGES" ]]; then
        local base="${BASE_REF:-HEAD~1}"
        local head="${HEAD_REF:-HEAD}"
        for svc in "${SERVICES[@]}"; do
            svc_changes=$(git diff --name-only "$base" "$head" -- "${SERVICES_DIR}/${svc}/" 2>/dev/null || true)
            if [[ -n "$svc_changes" ]]; then
                AFFECTED[$svc]=1
                AFFECTED_BY[$svc]="${AFFECTED_BY[$svc]:-}(direct changes)"$'\n'
            fi
        done
    fi

    # --- Output ---
    case "$FORMAT" in
        json)
            local first=true
            echo -n "["
            for svc in $(echo "${!AFFECTED[@]}" | tr ' ' '\n' | sort); do
                if $first; then first=false; else echo -n ","; fi
                echo -n "\"$svc\""
            done
            echo "]"
            ;;
        detail)
            for svc in $(echo "${!AFFECTED[@]}" | tr ' ' '\n' | sort); do
                echo "=== $svc ==="
                echo "${AFFECTED_BY[$svc]}" | grep -v '^$' | sort -u | sed 's/^/  ← /'
                echo ""
            done
            ;;
        list|*)
            for svc in $(echo "${!AFFECTED[@]}" | tr ' ' '\n' | sort); do
                echo "$svc"
            done
            ;;
    esac
}

# --- Full dependency map mode ---
show_full_map() {
    echo "=== Full Dependency Map ==="
    echo ""
    for svc in $(echo "${SERVICES[@]}" | tr ' ' '\n' | sort); do
        echo "[$svc]"
        if [[ -n "${SVC_DEPS[$svc]:-}" ]]; then
            echo "${SVC_DEPS[$svc]}" | grep -v '^$' | sort -u | sed 's/^/  → /'
        else
            echo "  (no shared dependencies)"
        fi
        echo ""
    done

    # Reverse map: which shared packages are consumed by which services
    echo "=== Reverse Map (shared package → consumers) ==="
    echo ""
    declare -A REVERSE_MAP
    for svc in "${SERVICES[@]}"; do
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            # Strip module root for readability
            short_dep="${dep#${MODULE_ROOT}/}"
            # Only show shared deps, not other services
            for shared_dir in $(echo "$SHARED_DIRS" | tr ',' ' '); do
                if [[ "$short_dep" == "${shared_dir}"* ]]; then
                    REVERSE_MAP[$short_dep]="${REVERSE_MAP[$short_dep]:-}${svc} "
                fi
            done
        done <<< "${SVC_DEPS[$svc]:-}"
    done

    for pkg in $(echo "${!REVERSE_MAP[@]}" | tr ' ' '\n' | sort); do
        consumers="${REVERSE_MAP[$pkg]}"
        count=$(echo "$consumers" | wc -w)
        echo "[$pkg] (${count} consumers)"
        echo "$consumers" | tr ' ' '\n' | grep -v '^$' | sort | sed 's/^/  ← /'
        echo ""
    done
}

# --- Main ---
build_dependency_map

if $SHOW_ALL; then
    show_full_map
    exit 0
fi

changed=$(find_changed_packages)

if [[ -z "$changed" ]]; then
    log "No shared packages changed — checking for direct service changes only"
    if [[ -n "$BASE_REF" ]] || [[ -z "$EXPLICIT_PACKAGES" ]]; then
        # Still check for direct service code changes
        find_affected_services ""
    else
        case "$FORMAT" in
            json) echo "[]" ;;
            *)    log "No affected services" ;;
        esac
    fi
    exit 0
fi

log "Changed packages:"
echo "$changed" | while read -r p; do log "  $p"; done

find_affected_services "$changed"
