#!/usr/bin/env bash
#
# test-changelog.sh
#
# Diagnostic script to understand why changelog.sh's while loop
# isn't processing commits even when get_commits returns data.
#
# Usage:
#   ./test-changelog.sh [--from REF] [--to REF] [--service NAME]
#
# Examples:
#   ./test-changelog.sh --from HEAD~5
#   ./test-changelog.sh --from billing/v1.0.0 --to billing/v1.1.0 --service billing

set -euo pipefail

# --- Defaults (adjust these for your repo) ---
SERVICES_DIR="${SERVICES_DIR:-services}"
SHARED_DIRS="${SHARED_DIRS:-shared,pkg,internal/common}"
SERVICE=""
FROM_REF=""
TO_REF="HEAD"

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --service|-s) SERVICE="$2"; shift 2 ;;
        --from)       FROM_REF="$2"; shift 2 ;;
        --to)         TO_REF="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [[ -z "$FROM_REF" ]]; then
    echo "Usage: $0 --from <ref> [--to <ref>] [--service <name>]"
    echo ""
    echo "Example: $0 --from HEAD~5"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

header() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}\n"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

# ============================================================
header "TEST 0: Environment Check"
# ============================================================

echo "Bash version: $BASH_VERSION"
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    fail "Bash version < 4. Associative arrays (declare -A) won't work."
    echo "    Install newer bash: brew install bash"
    echo "    Then run with: /opt/homebrew/bin/bash $0 $*"
else
    pass "Bash version >= 4"
fi

echo ""
echo "Parameters:"
echo "  FROM_REF:     $FROM_REF"
echo "  TO_REF:       $TO_REF"
echo "  SERVICE:      ${SERVICE:-<none>}"
echo "  SERVICES_DIR: $SERVICES_DIR"
echo "  SHARED_DIRS:  $SHARED_DIRS"

# ============================================================
header "TEST 1: Do the refs exist?"
# ============================================================

if git rev-parse --verify "$FROM_REF" &>/dev/null; then
    pass "FROM_REF '$FROM_REF' exists"
    echo "    Resolves to: $(git rev-parse --short "$FROM_REF")"
else
    fail "FROM_REF '$FROM_REF' does not exist"
fi

if git rev-parse --verify "$TO_REF" &>/dev/null; then
    pass "TO_REF '$TO_REF' exists"
    echo "    Resolves to: $(git rev-parse --short "$TO_REF")"
else
    fail "TO_REF '$TO_REF' does not exist"
fi

# ============================================================
header "TEST 2: Raw git log (no path filters)"
# ============================================================

info "Running: git log --no-merges --oneline ${FROM_REF}..${TO_REF}"
echo ""

commit_count=$(git log --no-merges --oneline "${FROM_REF}..${TO_REF}" 2>/dev/null | wc -l | xargs)
echo "Found $commit_count commits in range"
echo ""

if [[ "$commit_count" -gt 0 ]]; then
    pass "Commits exist in range"
    echo ""
    echo "First 5 commits:"
    git log --no-merges --oneline "${FROM_REF}..${TO_REF}" 2>/dev/null | head -5 | sed 's/^/    /'
else
    fail "No commits in range — check your refs"
    echo ""
    echo "Debug: Is FROM_REF an ancestor of TO_REF?"
    if git merge-base --is-ancestor "$FROM_REF" "$TO_REF" 2>/dev/null; then
        echo "    Yes, $FROM_REF is ancestor of $TO_REF"
    else
        echo "    No! This might be why. Try swapping --from and --to?"
    fi
fi

# ============================================================
header "TEST 3: Path filter construction"
# ============================================================

declare -a PATH_FILTERS=()

if [[ -n "$SERVICE" ]]; then
    service_path="${SERVICES_DIR}/${SERVICE}/"
    PATH_FILTERS+=("$service_path")

    if [[ -d "$service_path" ]]; then
        pass "Service directory exists: $service_path"
    else
        fail "Service directory NOT FOUND: $service_path"
        echo "    This will cause git log to return 0 commits!"
        echo ""
        echo "    Available directories in $SERVICES_DIR/:"
        if [[ -d "$SERVICES_DIR" ]]; then
            ls -1 "$SERVICES_DIR" 2>/dev/null | sed 's/^/      /' || echo "      (none)"
        else
            echo "      $SERVICES_DIR/ does not exist!"
        fi
    fi

    # Add shared dirs
    IFS=',' read -ra shared_dirs <<< "$SHARED_DIRS"
    for dir in "${shared_dirs[@]}"; do
        dir=$(echo "$dir" | xargs)  # trim
        if [[ -d "$dir" ]]; then
            PATH_FILTERS+=("${dir}/")
            pass "Shared dir exists: ${dir}/"
        else
            info "Shared dir not found (skipped): ${dir}/"
        fi
    done
fi

echo ""
echo "Final PATH_FILTERS array:"
if [[ ${#PATH_FILTERS[@]} -eq 0 ]]; then
    echo "    (empty — no path filtering, all commits included)"
else
    for p in "${PATH_FILTERS[@]}"; do
        echo "    - $p"
    done
fi

# ============================================================
header "TEST 4: Git log WITH path filters"
# ============================================================

if [[ ${#PATH_FILTERS[@]} -gt 0 ]]; then
    info "Running: git log --no-merges --oneline ${FROM_REF}..${TO_REF} -- ${PATH_FILTERS[*]}"
    echo ""

    filtered_count=$(git log --no-merges --oneline "${FROM_REF}..${TO_REF}" -- "${PATH_FILTERS[@]}" 2>/dev/null | wc -l | xargs)
    echo "Found $filtered_count commits matching path filters"

    if [[ "$filtered_count" -eq 0 && "$commit_count" -gt 0 ]]; then
        fail "Path filters excluded ALL commits!"
        echo ""
        echo "    You have $commit_count commits in the range, but none touch:"
        for p in "${PATH_FILTERS[@]}"; do
            echo "      - $p"
        done
        echo ""
        echo "    Possible causes:"
        echo "      1. Service directory name doesn't match actual folder"
        echo "      2. Commits in this range don't touch this service"
        echo "      3. Commits only touched other services"
    elif [[ "$filtered_count" -gt 0 ]]; then
        pass "Found $filtered_count commits after filtering"
        echo ""
        echo "First 5 filtered commits:"
        git log --no-merges --oneline "${FROM_REF}..${TO_REF}" -- "${PATH_FILTERS[@]}" 2>/dev/null | head -5 | sed 's/^/    /'
    fi
else
    echo "(Skipped — no path filters to test)"
fi

# ============================================================
header "TEST 5: Raw format parsing"
# ============================================================

FORMAT_STRING="%H|%h|%an|%ae|%ad|%s"
info "Testing git log --format='$FORMAT_STRING' --date=short"
echo ""

# Build the command
git_cmd=(git log --no-merges "--format=$FORMAT_STRING" "--date=short" "${FROM_REF}..${TO_REF}")
if [[ ${#PATH_FILTERS[@]} -gt 0 ]]; then
    git_cmd+=(--)
    git_cmd+=("${PATH_FILTERS[@]}")
fi

echo "Full command: ${git_cmd[*]}"
echo ""

raw_output=$("${git_cmd[@]}" 2>/dev/null || true)
raw_lines=$(echo "$raw_output" | grep -c . || true)

echo "Raw output lines: $raw_lines"
echo ""

if [[ "$raw_lines" -gt 0 ]]; then
    pass "Raw format produces output"
    echo ""
    echo "First 3 lines of raw output:"
    echo "$raw_output" | head -3 | while IFS= read -r line; do
        echo "    $line"
    done

    echo ""
    echo "Parsing first line:"
    first_line=$(echo "$raw_output" | head -1)
    IFS='|' read -r hash short_hash author email date subject <<< "$first_line"
    echo "    hash:       ${hash:-<empty>}"
    echo "    short_hash: ${short_hash:-<empty>}"
    echo "    author:     ${author:-<empty>}"
    echo "    email:      ${email:-<empty>}"
    echo "    date:       ${date:-<empty>}"
    echo "    subject:    ${subject:-<empty>}"

    if [[ -n "$hash" ]]; then
        pass "Parsing works correctly"
    else
        fail "Parsing failed — hash is empty"
    fi
else
    fail "No raw output produced"
fi

# ============================================================
header "TEST 6: While loop simulation"
# ============================================================

info "Simulating the while loop from changelog.sh"
echo ""

loop_count=0
while IFS='|' read -r hash short_hash author email date subject; do
    [[ -z "$hash" ]] && continue
    ((loop_count++))
    if [[ $loop_count -le 3 ]]; then
        echo "  Iteration $loop_count: $short_hash - $subject"
    fi
done <<< "$raw_output"

echo ""
echo "Total iterations: $loop_count"

if [[ "$loop_count" -eq 0 && "$raw_lines" -gt 0 ]]; then
    fail "While loop processed 0 commits but raw output had $raw_lines lines!"
    echo ""
    echo "    This suggests a parsing issue. Checking for problematic characters..."
    echo ""
    echo "    First line hex dump:"
    echo "$raw_output" | head -1 | xxd | head -2
elif [[ "$loop_count" -gt 0 ]]; then
    pass "While loop processed $loop_count commits"
else
    info "No commits to process (expected given previous tests)"
fi

# ============================================================
header "TEST 7: Process substitution test"
# ============================================================

info "Testing process substitution syntax: while ... done < <(command)"
echo ""

# This is what changelog.sh uses
get_commits_test() {
    git log --no-merges "--format=%H|%h|%an|%ae|%ad|%s" "--date=short" "${FROM_REF}..${TO_REF}" 2>/dev/null || true
}

ps_count=0
while IFS='|' read -r hash short_hash author email date subject; do
    [[ -z "$hash" ]] && continue
    ((ps_count++))
done < <(get_commits_test)

echo "Commits processed via process substitution: $ps_count"

if [[ "$ps_count" -gt 0 ]]; then
    pass "Process substitution works"
elif [[ "$commit_count" -gt 0 ]]; then
    fail "Process substitution returned 0 but commits exist"
    echo "    This might be a bash version issue with process substitution"
else
    info "No commits (consistent with earlier tests)"
fi

# ============================================================
header "SUMMARY"
# ============================================================

echo "Based on the tests above:"
echo ""

if [[ "$commit_count" -eq 0 ]]; then
    echo "  → No commits in range. Check your --from and --to refs."
elif [[ ${#PATH_FILTERS[@]} -gt 0 && "$filtered_count" -eq 0 ]]; then
    echo "  → Path filters are excluding all commits."
    echo "  → Either the service directory doesn't exist, or no commits"
    echo "    in this range touched that service."
    echo ""
    echo "  Try running without --service to see all commits:"
    echo "    $0 --from $FROM_REF --to $TO_REF"
elif [[ "$loop_count" -eq 0 && "$raw_lines" -gt 0 ]]; then
    echo "  → Raw output exists but parsing failed."
    echo "  → Check for special characters in commit messages."
else
    echo "  → Everything looks OK. The while loop should work."
    echo "  → If changelog.sh still fails, the issue might be with"
    echo "    associative arrays (declare -A) on bash < 4."
fi

echo ""
