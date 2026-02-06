#!/usr/bin/env bash
#
# debug-changelog.sh
#
# Diagnostic script to isolate why changelog.sh's while loop
# isn't processing commits.
#
# Usage:
#   ./debug-changelog.sh [--from REF] [--to REF] [--service NAME]
#
# Examples:
#   ./debug-changelog.sh --from HEAD~5
#   ./debug-changelog.sh --from billing/v1.0.0 --service billing

set -euo pipefail

# --- Defaults ---
FROM_REF=""
TO_REF="HEAD"
SERVICES_DIR="${SERVICES_DIR:-services}"
SHARED_DIRS="${SHARED_DIRS:-shared,pkg,internal/common}"
SERVICE=""

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --service|-s) SERVICE="$2"; shift 2 ;;
        --from)       FROM_REF="$2"; shift 2 ;;
        --to)         TO_REF="$2"; shift 2 ;;
        --services-dir) SERVICES_DIR="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [[ -z "$FROM_REF" ]]; then
    echo "Usage: $0 --from <ref> [--to <ref>] [--service <name>]"
    exit 1
fi

echo "========================================"
echo "Debug Changelog"
echo "========================================"
echo ""
echo "Configuration:"
echo "  FROM_REF:     $FROM_REF"
echo "  TO_REF:       $TO_REF"
echo "  SERVICE:      ${SERVICE:-<none>}"
echo "  SERVICES_DIR: $SERVICES_DIR"
echo "  SHARED_DIRS:  $SHARED_DIRS"
echo "  Bash version: $BASH_VERSION"
echo ""

# --- Build PATH_FILTERS exactly as changelog.sh does ---
declare -a PATH_FILTERS=()

if [[ -n "$SERVICE" ]]; then
    PATH_FILTERS+=("${SERVICES_DIR}/${SERVICE}/")
    IFS=',' read -ra shared_dirs <<< "$SHARED_DIRS"
    for dir in "${shared_dirs[@]}"; do
        dir=$(echo "$dir" | xargs)
        if [[ -d "$dir" ]]; then
            PATH_FILTERS+=("${dir}/")
        fi
    done
fi

echo "PATH_FILTERS:"
if [[ ${#PATH_FILTERS[@]} -eq 0 ]]; then
    echo "  (empty - no path filtering)"
else
    for p in "${PATH_FILTERS[@]}"; do
        if [[ -d "$p" ]]; then
            echo "  $p (exists)"
        else
            echo "  $p (NOT FOUND!)"
        fi
    done
fi
echo ""

# --- get_commits function exactly as changelog.sh ---
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

# --- Test 1: Direct function call ---
echo "========================================"
echo "Test 1: Direct get_commits call"
echo "========================================"
echo ""

raw_output=$(get_commits "raw")
line_count=$(echo "$raw_output" | grep -c . || true)

echo "Raw output line count: $line_count"
echo ""
echo "First 3 lines:"
echo "$raw_output" | head -3 | while IFS= read -r line; do
    echo "  $line"
done
echo ""

# --- Test 2: Parse with here-string ---
echo "========================================"
echo "Test 2: Parsing via here-string (<<<"
echo "========================================"
echo ""

count=0
while IFS='|' read -r hash short_hash author email date subject; do
    if [[ -z "$hash" ]]; then
        echo "  EMPTY hash on iteration $count"
        continue
    fi
    ((++count))
    if [[ $count -le 3 ]]; then
        echo "  [$count] $short_hash - $subject"
    fi
done <<< "$raw_output"

echo ""
echo "Total parsed: $count"
echo ""

# --- Test 3: Parse with process substitution ---
echo "========================================"
echo "Test 3: Parsing via process substitution < <(...)"
echo "========================================"
echo ""

count=0
while IFS='|' read -r hash short_hash author email date subject; do
    if [[ -z "$hash" ]]; then
        echo "  EMPTY hash on iteration $count"
        continue
    fi
    ((++count))
    if [[ $count -le 3 ]]; then
        echo "  [$count] $short_hash - $subject"
    fi
done < <(get_commits "raw")

echo ""
echo "Total parsed: $count"
echo ""

# --- Test 4: Associative array storage (like changelog.sh) ---
echo "========================================"
echo "Test 4: Associative array storage"
echo "========================================"
echo ""

declare -A COMMITS_BY_CATEGORY
CATEGORY_ORDER=("feat" "fix" "other")

# Initialize
for cat in "${CATEGORY_ORDER[@]}"; do
    COMMITS_BY_CATEGORY[$cat]=""
done

categorize_simple() {
    local subject="$1"
    local lower=$(echo "$subject" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        feat:*|feat\(*) echo "feat" ;;
        fix:*|fix\(*) echo "fix" ;;
        *) echo "other" ;;
    esac
}

count=0
while IFS='|' read -r hash short_hash author email date subject; do
    [[ -z "$hash" ]] && continue
    ((++count))

    category=$(categorize_simple "$subject")
    commit_line="${short_hash}|${author}|${date}|${subject}"
    COMMITS_BY_CATEGORY[$category]="${COMMITS_BY_CATEGORY[$category]}${commit_line}"$'\n'
done < <(get_commits "raw")

echo "Stored $count commits in associative array"
echo ""

for cat in "${CATEGORY_ORDER[@]}"; do
    commits="${COMMITS_BY_CATEGORY[$cat]}"
    if [[ -n "$commits" ]]; then
        cat_count=$(echo "$commits" | grep -c . || true)
        echo "  $cat: $cat_count commits"
    fi
done
echo ""

# --- Test 5: Simulated render ---
echo "========================================"
echo "Test 5: Simulated render output"
echo "========================================"
echo ""

for cat in "${CATEGORY_ORDER[@]}"; do
    commits="${COMMITS_BY_CATEGORY[$cat]}"
    [[ -z "$commits" ]] && continue

    echo "--- $cat ---"
    while IFS='|' read -r short_hash author date subject; do
        [[ -z "$short_hash" ]] && continue
        echo "  $short_hash: $subject"
    done <<< "$commits"
    echo ""
done

echo "========================================"
echo "Summary"
echo "========================================"
echo ""

if [[ $count -eq 0 ]]; then
    echo "NO COMMITS PROCESSED"
    echo ""
    echo "Possible causes:"
    echo "  - FROM_REF and TO_REF have no commits between them"
    echo "  - PATH_FILTERS exclude all commits"
    echo "  - Service directory doesn't exist"
else
    echo "SUCCESS: Processed $count commits"
    echo ""
    echo "If changelog.sh still produces no output, the issue is"
    echo "in a part of the script not tested here."
fi
