#!/usr/bin/env bash
#
# changelog.sh
#
# Generates a scoped changelog between two refs (tags, commits, branches)
# for a specific service or the entire repo, including shared dependency changes.
#
# Usage:
#   ./scripts/changelog.sh --service billing --from billing/v1.2.3 --to billing/v1.2.4
#   ./scripts/changelog.sh --from v1.2.3 --to v1.2.4                   # whole repo
#   ./scripts/changelog.sh --service billing --from billing/v1.2.3      # to=HEAD
#   ./scripts/changelog.sh --service billing --from billing/v1.2.3 --format markdown
#
# Output formats:
#   --format text       (default) plain text changelog
#   --format markdown   markdown suitable for GitHub releases
#   --format json       structured JSON for programmatic consumption
#
# Configuration (env vars or flags):
#   SERVICES_DIR      directory containing services (default: "services")
#   SHARED_DIRS       comma-separated shared package dirs (default: "shared,pkg,internal/common")

set -euo pipefail

# --- Defaults ---
SERVICES_DIR="${SERVICES_DIR:-services}"
SHARED_DIRS="${SHARED_DIRS:-shared,pkg,internal/common}"
SERVICE=""
FROM_REF=""
TO_REF="HEAD"
FORMAT="text"
INCLUDE_STATS=true
INCLUDE_BREAKING=true
VERBOSE=false

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --service|-s)     SERVICE="$2"; shift 2 ;;
        --from)           FROM_REF="$2"; shift 2 ;;
        --to)             TO_REF="$2"; shift 2 ;;
        --format|-f)      FORMAT="$2"; shift 2 ;;
        --services-dir)   SERVICES_DIR="$2"; shift 2 ;;
        --shared-dirs)    SHARED_DIRS="$2"; shift 2 ;;
        --no-stats)       INCLUDE_STATS=false; shift ;;
        --no-breaking)    INCLUDE_BREAKING=false; shift ;;
        --verbose|-v)     VERBOSE=true; shift ;;
        --help|-h)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$FROM_REF" ]]; then
    echo "Error: --from is required" >&2
    exit 1
fi

log() {
    if $VERBOSE; then echo "[changelog] $*" >&2; fi
}

# --- Build path filters for the diff ---
declare -a PATH_FILTERS=()

if [[ -n "$SERVICE" ]]; then
    # Service-specific: include service dir + all shared dirs
    PATH_FILTERS+=("${SERVICES_DIR}/${SERVICE}/")
    IFS=',' read -ra shared_dirs <<< "$SHARED_DIRS"
    for dir in "${shared_dirs[@]}"; do
        dir=$(echo "$dir" | xargs)
        if [[ -d "$dir" ]]; then
            PATH_FILTERS+=("${dir}/")
        fi
    done
fi

log "Path filters: ${PATH_FILTERS[*]:-<all>}"

# --- Gather commits ---
get_commits() {
    local format="$1"
    local -a git_args=("log" "--no-merges" "${FROM_REF}..${TO_REF}")

    case "$format" in
        raw)
            git_args+=("--format=%H|%h|%an|%ae|%ad|%s" "--date=short")
            ;;
        oneline)
            git_args+=("--oneline")
            ;;
    esac

    if [[ ${#PATH_FILTERS[@]} -gt 0 ]]; then
        git_args+=("--")
        git_args+=("${PATH_FILTERS[@]}")
    fi

    git "${git_args[@]}" 2>/dev/null || true
}

# --- Categorize commits using conventional commit prefixes ---
# Categories: feat, fix, refactor, perf, docs, test, chore, breaking, other
categorize_commit() {
    local subject="$1"
    local lower_subject=$(echo "$subject" | tr '[:upper:]' '[:lower:]')

    # Check for breaking change indicators
    if echo "$lower_subject" | grep -qE '(breaking|BREAKING CHANGE|!)'; then
        echo "breaking"
        return
    fi

    # Conventional commit prefix detection
    case "$lower_subject" in
        feat:*|feat\(*) echo "feat" ;;
        fix:*|fix\(*|bugfix:*|hotfix:*) echo "fix" ;;
        refactor:*|refactor\(*) echo "refactor" ;;
        perf:*|perf\(*) echo "perf" ;;
        docs:*|docs\(*|doc:*) echo "docs" ;;
        test:*|test\(*|tests:*) echo "test" ;;
        chore:*|chore\(*|ci:*|build:*) echo "chore" ;;
        revert:*|revert\(*) echo "revert" ;;
        *)
            # Heuristic fallback for non-conventional commits
            if echo "$lower_subject" | grep -qE '\b(add|implement|introduce|support|new)\b'; then
                echo "feat"
            elif echo "$lower_subject" | grep -qE '\b(fix|resolve|correct|patch|bug)\b'; then
                echo "fix"
            elif echo "$lower_subject" | grep -qE '\b(update|upgrade|bump|migrate)\b'; then
                echo "chore"
            elif echo "$lower_subject" | grep -qE '\b(refactor|clean|reorganize|restructure)\b'; then
                echo "refactor"
            elif echo "$lower_subject" | grep -qE '\b(perf|optimize|speed|fast|slow)\b'; then
                echo "perf"
            else
                echo "other"
            fi
            ;;
    esac
}

# --- Classify which area a commit touched ---
classify_commit_scope() {
    local hash="$1"
    local files_changed

    if [[ -n "$SERVICE" ]]; then
        files_changed=$(git diff-tree --no-commit-id --name-only -r "$hash" 2>/dev/null || true)
        local touched_service=false
        local touched_shared=false
        local shared_areas=""

        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if [[ "$file" == "${SERVICES_DIR}/${SERVICE}/"* ]]; then
                touched_service=true
            fi
            IFS=',' read -ra shared_dirs <<< "$SHARED_DIRS"
            for dir in "${shared_dirs[@]}"; do
                dir=$(echo "$dir" | xargs)
                if [[ "$file" == "${dir}/"* ]]; then
                    touched_shared=true
                    # Extract the sub-package (e.g., shared/models)
                    local subpkg=$(echo "$file" | cut -d'/' -f1-2)
                    if [[ ! "$shared_areas" == *"$subpkg"* ]]; then
                        shared_areas="${shared_areas}${subpkg},"
                    fi
                fi
            done
        done <<< "$files_changed"

        if $touched_service && $touched_shared; then
            echo "both|${shared_areas%,}"
        elif $touched_shared; then
            echo "shared|${shared_areas%,}"
        else
            echo "service|"
        fi
    else
        echo "repo|"
    fi
}

# --- Detect potential breaking changes in Go code ---
detect_breaking_changes() {
    local hash="$1"
    local diff_output

    diff_output=$(git diff "${hash}~1" "${hash}" -- "${PATH_FILTERS[@]}" 2>/dev/null || true)

    local indicators=""

    # Removed or renamed exported functions/types
    local removed_exports=$(echo "$diff_output" \
        | grep '^-' \
        | grep -oE '\bfunc [A-Z][A-Za-z0-9]*|type [A-Z][A-Za-z0-9]*' \
        || true)
    if [[ -n "$removed_exports" ]]; then
        indicators="${indicators}removed exports: $(echo "$removed_exports" | head -3 | tr '\n' ', ')\n"
    fi

    # Changed function signatures (rough heuristic)
    local sig_changes=$(echo "$diff_output" \
        | grep -E '^[-+]func.*\(' \
        | grep -oE 'func [A-Z][A-Za-z0-9]*\([^)]*\)' \
        || true)
    # If same function name appears in both + and - with different sigs
    if [[ -n "$sig_changes" ]]; then
        local func_names=$(echo "$sig_changes" | grep -oE 'func [A-Z][A-Za-z0-9]*' | sort | uniq -d)
        if [[ -n "$func_names" ]]; then
            indicators="${indicators}changed signatures: $(echo "$func_names" | tr '\n' ', ')\n"
        fi
    fi

    # Struct field removals/renames in shared packages
    local struct_changes=$(echo "$diff_output" \
        | grep -E '^\-[[:space:]]+[A-Z][A-Za-z0-9]*[[:space:]]' \
        || true)
    if [[ -n "$struct_changes" ]]; then
        indicators="${indicators}possible removed struct fields\n"
    fi

    echo -e "$indicators"
}

# --- File change stats ---
get_change_stats() {
    local stat_output
    if [[ ${#PATH_FILTERS[@]} -gt 0 ]]; then
        stat_output=$(git diff --stat "${FROM_REF}..${TO_REF}" -- "${PATH_FILTERS[@]}" 2>/dev/null || true)
    else
        stat_output=$(git diff --stat "${FROM_REF}..${TO_REF}" 2>/dev/null || true)
    fi
    echo "$stat_output"
}

# --- Main: Collect and organize all data ---
declare -A COMMITS_BY_CATEGORY
CATEGORY_ORDER=("breaking" "feat" "fix" "perf" "refactor" "revert" "chore" "docs" "test" "other")

declare -A CATEGORY_LABELS
CATEGORY_LABELS=(
    [breaking]="⚠️  Breaking Changes"
    [feat]="✨ Features"
    [fix]="🐛 Bug Fixes"
    [perf]="⚡ Performance"
    [refactor]="♻️  Refactors"
    [revert]="⏪ Reverts"
    [chore]="🔧 Chores"
    [docs]="📝 Documentation"
    [test]="✅ Tests"
    [other]="📦 Other"
)

declare -A CATEGORY_LABELS_PLAIN
CATEGORY_LABELS_PLAIN=(
    [breaking]="BREAKING CHANGES"
    [feat]="Features"
    [fix]="Bug Fixes"
    [perf]="Performance"
    [refactor]="Refactors"
    [revert]="Reverts"
    [chore]="Chores"
    [docs]="Documentation"
    [test]="Tests"
    [other]="Other"
)

# Initialize categories
for cat in "${CATEGORY_ORDER[@]}"; do
    COMMITS_BY_CATEGORY[$cat]=""
done

BREAKING_DETAILS=""
SHARED_CHANGES=""
TOTAL_COMMITS=0

log "Collecting commits ${FROM_REF}..${TO_REF}"

while IFS='|' read -r hash short_hash author email date subject; do
    [[ -z "$hash" ]] && continue
    ((++TOTAL_COMMITS))

    category=$(categorize_commit "$subject")
    scope_info=$(classify_commit_scope "$hash")
    scope_type="${scope_info%%|*}"
    scope_areas="${scope_info#*|}"

    # Build the commit line
    commit_line="${short_hash}|${author}|${date}|${subject}|${scope_type}|${scope_areas}"
    COMMITS_BY_CATEGORY[$category]="${COMMITS_BY_CATEGORY[$category]}${commit_line}"$'\n'

    # Check for breaking changes
    if $INCLUDE_BREAKING && [[ "$category" == "breaking" || "$scope_type" == "shared" || "$scope_type" == "both" ]]; then
        breaking=$(detect_breaking_changes "$hash")
        if [[ -n "$breaking" ]]; then
            BREAKING_DETAILS="${BREAKING_DETAILS}${short_hash}: ${breaking}"
        fi
    fi

    # Track shared dependency changes
    if [[ "$scope_type" == "shared" || "$scope_type" == "both" ]]; then
        SHARED_CHANGES="${SHARED_CHANGES}${commit_line}"$'\n'
    fi

done < <(get_commits "raw")

log "Found $TOTAL_COMMITS commits"

# --- Render: Text format ---
render_text() {
    local title="Changelog"
    if [[ -n "$SERVICE" ]]; then
        title="Changelog: $SERVICE"
    fi

    echo "════════════════════════════════════════════════════════"
    echo "  $title"
    echo "  ${FROM_REF} → ${TO_REF}"
    echo "  $(date '+%Y-%m-%d')"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "Total commits: $TOTAL_COMMITS"
    echo ""

    for cat in "${CATEGORY_ORDER[@]}"; do
        local commits="${COMMITS_BY_CATEGORY[$cat]}"
        [[ -z "$commits" ]] && continue

        echo "── ${CATEGORY_LABELS_PLAIN[$cat]} ──"
        echo ""
        while IFS='|' read -r short_hash author date subject scope_type scope_areas; do
            [[ -z "$short_hash" ]] && continue
            local scope_tag=""
            if [[ "$scope_type" == "shared" ]]; then
                scope_tag=" [shared: ${scope_areas}]"
            elif [[ "$scope_type" == "both" ]]; then
                scope_tag=" [+shared: ${scope_areas}]"
            fi
            echo "  ${short_hash}  ${subject}${scope_tag}"
            echo "           — ${author}, ${date}"
        done <<< "$commits"
        echo ""
    done

    # Shared dependency impact summary
    if [[ -n "$SERVICE" && -n "$SHARED_CHANGES" ]]; then
        echo "── Shared Dependency Changes ──"
        echo ""
        echo "  The following commits modified shared packages that $SERVICE depends on."
        echo "  Review these carefully for backward compatibility."
        echo ""
        local shared_pkgs=$(echo "$SHARED_CHANGES" \
            | cut -d'|' -f6 \
            | tr ',' '\n' \
            | sort -u \
            | grep -v '^$')
        echo "  Affected shared packages:"
        echo "$shared_pkgs" | sed 's/^/    → /'
        echo ""
    fi

    # Breaking change details
    if [[ -n "$BREAKING_DETAILS" ]]; then
        echo "── Breaking Change Details ──"
        echo ""
        echo "$BREAKING_DETAILS" | sed 's/^/  /'
        echo ""
    fi

    # Stats
    if $INCLUDE_STATS; then
        echo "── File Change Summary ──"
        echo ""
        get_change_stats | tail -1 | sed 's/^/  /'
        echo ""
    fi
}

# --- Render: Markdown format ---
render_markdown() {
    local title="Changelog"
    if [[ -n "$SERVICE" ]]; then
        title="Changelog: \`$SERVICE\`"
    fi

    echo "# $title"
    echo ""
    echo "**${FROM_REF}** → **${TO_REF}** | $(date '+%Y-%m-%d') | $TOTAL_COMMITS commits"
    echo ""

    for cat in "${CATEGORY_ORDER[@]}"; do
        local commits="${COMMITS_BY_CATEGORY[$cat]}"
        [[ -z "$commits" ]] && continue

        echo "## ${CATEGORY_LABELS[$cat]}"
        echo ""
        while IFS='|' read -r short_hash author date subject scope_type scope_areas; do
            [[ -z "$short_hash" ]] && continue
            local scope_badge=""
            if [[ "$scope_type" == "shared" ]]; then
                scope_badge=" \`shared: ${scope_areas}\`"
            elif [[ "$scope_type" == "both" ]]; then
                scope_badge=" \`+shared: ${scope_areas}\`"
            fi
            echo "- \`${short_hash}\` ${subject}${scope_badge} — *${author}*"
        done <<< "$commits"
        echo ""
    done

    # Shared impact section
    if [[ -n "$SERVICE" && -n "$SHARED_CHANGES" ]]; then
        echo "## 🔗 Shared Dependency Impact"
        echo ""
        echo "> These commits modified shared packages consumed by \`$SERVICE\`."
        echo "> Review for backward compatibility before deploying."
        echo ""
        local shared_pkgs=$(echo "$SHARED_CHANGES" \
            | cut -d'|' -f6 \
            | tr ',' '\n' \
            | sort -u \
            | grep -v '^$')
        echo "**Affected packages:**"
        echo "$shared_pkgs" | sed 's/^/- `/' | sed 's/$/`/'
        echo ""
    fi

    # Breaking change details
    if [[ -n "$BREAKING_DETAILS" ]]; then
        echo "## ⚠️ Breaking Change Analysis"
        echo ""
        echo '```'
        echo "$BREAKING_DETAILS"
        echo '```'
        echo ""
    fi

    # Stats
    if $INCLUDE_STATS; then
        echo "<details>"
        echo "<summary>📊 Change Statistics</summary>"
        echo ""
        echo '```'
        get_change_stats
        echo '```'
        echo ""
        echo "</details>"
    fi
}

# --- Render: JSON format ---
render_json() {
    echo "{"
    echo "  \"service\": $(if [[ -n "$SERVICE" ]]; then echo "\"$SERVICE\""; else echo "null"; fi),"
    echo "  \"from\": \"$FROM_REF\","
    echo "  \"to\": \"$TO_REF\","
    echo "  \"generated\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\","
    echo "  \"total_commits\": $TOTAL_COMMITS,"
    echo "  \"categories\": {"

    local first_cat=true
    for cat in "${CATEGORY_ORDER[@]}"; do
        local commits="${COMMITS_BY_CATEGORY[$cat]}"
        [[ -z "$commits" ]] && continue

        if $first_cat; then first_cat=false; else echo ","; fi
        echo -n "    \"$cat\": ["

        local first_commit=true
        while IFS='|' read -r short_hash author date subject scope_type scope_areas; do
            [[ -z "$short_hash" ]] && continue
            if $first_commit; then first_commit=false; else echo -n ","; fi
            # Escape quotes in subject
            subject=$(echo "$subject" | sed 's/"/\\"/g')
            author=$(echo "$author" | sed 's/"/\\"/g')
            echo -n "{\"hash\":\"$short_hash\",\"author\":\"$author\",\"date\":\"$date\",\"subject\":\"$subject\",\"scope\":\"$scope_type\""
            if [[ -n "$scope_areas" ]]; then
                echo -n ",\"shared_packages\":\"$scope_areas\""
            fi
            echo -n "}"
        done <<< "$commits"
        echo -n "]"
    done

    echo ""
    echo "  },"

    # Shared packages
    if [[ -n "$SHARED_CHANGES" ]]; then
        local shared_pkgs=$(echo "$SHARED_CHANGES" \
            | cut -d'|' -f6 \
            | tr ',' '\n' \
            | sort -u \
            | grep -v '^$')
        echo -n "  \"affected_shared_packages\": ["
        local first=true
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            if $first; then first=false; else echo -n ","; fi
            echo -n "\"$pkg\""
        done <<< "$shared_pkgs"
        echo "],"
    else
        echo "  \"affected_shared_packages\": [],"
    fi

    echo "  \"has_breaking_changes\": $(if [[ -n "$BREAKING_DETAILS" ]]; then echo "true"; else echo "false"; fi)"
    echo "}"
}

# --- Dispatch ---
case "$FORMAT" in
    markdown|md) render_markdown ;;
    json)        render_json ;;
    text|*)      render_text ;;
esac
