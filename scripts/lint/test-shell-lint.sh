#!/usr/bin/env bash
# test-shell-lint.sh — Tests for scripts/lint/shell-lint.sh (HIMMEL-478, C4).
#
# Usage: bash scripts/lint/test-shell-lint.sh
#
# Cases:
#   1. success criterion : staged .sh with unused var + BOM + set -e leak →
#                          all three caught, exit 1
#   2. clean file        : proper set -uo pipefail, no BOM, vars used → exit 0
#   3. statusline exclude : a file under scripts/statusline/ is skipped (mirror gate)
#   4. --staged mode      : lints staged shell files in a git repo, exit 1 on issue
#   5. --help             : exits 0 and prints usage
#   6. errexit variants   : set -eu / set -euo / set -o errexit all flagged;
#                          set -uo pipefail / set -o pipefail NOT flagged
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe; shellcheck-clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/shell-lint.sh"

[ -f "$LINT" ] || { printf 'FAIL: shell-lint.sh not found at %s\n' "$LINT"; exit 1; }

PASS=0
FAIL=0
TMP_ROOT=""
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    [ $# -ge 2 ] && printf '        %s\n' "$2"
    FAIL=$((FAIL + 1))
}
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "missing: $2"; fi
}
assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "unexpected: $2"; else pass "$1"; fi
}

HAVE_SHELLCHECK=0
command -v shellcheck >/dev/null 2>&1 && HAVE_SHELLCHECK=1

TMP_ROOT="$(mktemp -d)"

# Write a UTF-8 BOM (EF BB BF) then the given body to $1.
_write_bom_file() {
    local path="$1"; shift
    printf '\xEF\xBB\xBF' > "$path"
    cat >> "$path"
}

# ---------------------------------------------------------------------------
# Case 1: success criterion — unused var + BOM + set -e leak, all three caught
# ---------------------------------------------------------------------------
printf '\nCase 1: success criterion (unused var + BOM + set -e leak)\n'

BAD="$TMP_ROOT/bad.sh"
_write_bom_file "$BAD" <<'EOF'
#!/usr/bin/env bash
set -e
unused_var="never referenced"
echo "hi"
EOF

OUT1="$(bash "$LINT" "$BAD" 2>&1)"; EC1=$?

if [ "$EC1" -eq 1 ]; then pass "exit 1 on a file with issues"; else fail "expected exit 1, got $EC1" "$OUT1"; fi
assert_contains "BOM detected" "BOM" "$OUT1"
assert_contains "errexit (set -e) leak detected" "errexit" "$OUT1"
if [ "$HAVE_SHELLCHECK" -eq 1 ]; then
    assert_contains "shellcheck unused-var (SC2034) surfaced" "SC2034" "$OUT1"
else
    printf '  SKIP: shellcheck not installed — SC2034 assertion skipped\n'
fi

# ---------------------------------------------------------------------------
# Case 2: clean file → exit 0
# ---------------------------------------------------------------------------
printf '\nCase 2: clean file exits 0\n'

CLEAN="$TMP_ROOT/clean.sh"
cat > "$CLEAN" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
greeting="hello"
printf '%s\n' "$greeting"
EOF

OUT2="$(bash "$LINT" "$CLEAN" 2>&1)"; EC2=$?
if [ "$EC2" -eq 0 ]; then pass "clean file exits 0"; else fail "expected exit 0, got $EC2" "$OUT2"; fi

# ---------------------------------------------------------------------------
# Case 3: statusline path is excluded (mirror the real gate)
# ---------------------------------------------------------------------------
printf '\nCase 3: scripts/statusline/ excluded\n'

mkdir -p "$TMP_ROOT/scripts/statusline"
SL="$TMP_ROOT/scripts/statusline/vendored.sh"
_write_bom_file "$SL" <<'EOF'
#!/usr/bin/env bash
set -e
unused_var="x"
EOF

OUT3="$(bash "$LINT" "$SL" 2>&1)"; EC3=$?
if [ "$EC3" -eq 0 ]; then pass "statusline file skipped (exit 0)"; else fail "expected exit 0 (excluded), got $EC3" "$OUT3"; fi
assert_not_contains "statusline findings not reported" "errexit" "$OUT3"

# ---------------------------------------------------------------------------
# Case 4: --staged mode lints staged shell in a git repo
# ---------------------------------------------------------------------------
printf '\nCase 4: --staged mode\n'

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
(
    cd "$REPO" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    printf '\xEF\xBB\xBF' > staged.sh
    cat >> staged.sh <<'EOF'
#!/usr/bin/env bash
set -e
echo hi
EOF
    printf '#!/usr/bin/env bash\nset -uo pipefail\necho clean\n' > unstaged.sh
    git add staged.sh
)
OUT4="$(cd "$REPO" && bash "$LINT" --staged 2>&1)"; EC4=$?
if [ "$EC4" -eq 1 ]; then pass "--staged exits 1 on a staged issue"; else fail "expected exit 1, got $EC4" "$OUT4"; fi
assert_contains "--staged reports the staged file" "staged.sh" "$OUT4"
assert_not_contains "--staged ignores the unstaged file" "unstaged.sh" "$OUT4"

# ---------------------------------------------------------------------------
# Case 5: --help
# ---------------------------------------------------------------------------
printf '\nCase 5: --help\n'

HELP="$(bash "$LINT" --help 2>&1)"; HEC=$?
if [ "$HEC" -eq 0 ]; then pass "--help exits 0"; else fail "--help expected 0, got $HEC"; fi
assert_contains "--help mentions --staged" "--staged" "$HELP"

# ---------------------------------------------------------------------------
# Case 6: errexit variants — flagged vs not
# ---------------------------------------------------------------------------
printf '\nCase 6: errexit variant detection\n'

for variant in "set -eu" "set -euo pipefail" "set -o errexit"; do
    f="$TMP_ROOT/ee.sh"
    printf '#!/usr/bin/env bash\n%s\necho hi\n' "$variant" > "$f"
    o="$(bash "$LINT" "$f" 2>&1)"; e=$?
    if [ "$e" -eq 1 ] && printf '%s' "$o" | grep -qF errexit; then
        pass "errexit flagged: '$variant'"
    else
        fail "errexit should be flagged: '$variant'" "$o"
    fi
done

for ok in "set -uo pipefail" "set -o pipefail" "set -u"; do
    f="$TMP_ROOT/ok.sh"
    printf '#!/usr/bin/env bash\n%s\necho ok\n' "$ok" > "$f"
    o="$(bash "$LINT" "$f" 2>&1)"; e=$?
    if printf '%s' "$o" | grep -qF errexit; then
        fail "errexit FALSE positive: '$ok'" "$o"
    else
        pass "errexit not flagged (correct): '$ok'"
    fi
done

# ---------------------------------------------------------------------------
# Case 7: `set -e` inside a heredoc body is NOT flagged (prologue-only scan)
# ---------------------------------------------------------------------------
printf '\nCase 7: heredoc-body set -e is not a false positive\n'

HD="$TMP_ROOT/heredoc.sh"
cat > "$HD" <<'OUTER'
#!/usr/bin/env bash
set -uo pipefail
cat > /dev/null <<'INNER'
set -e
INNER
echo finished
OUTER

OUT7="$(bash "$LINT" "$HD" 2>&1)"; EC7=$?
if [ "$EC7" -eq 0 ]; then pass "heredoc-body set -e not flagged (exit 0)"; else fail "expected exit 0, got $EC7" "$OUT7"; fi
assert_not_contains "no errexit false positive on heredoc body" "errexit" "$OUT7"

# ---------------------------------------------------------------------------
# Case 8: --staged works from a subdirectory (repo-root path resolution)
# ---------------------------------------------------------------------------
printf '\nCase 8: --staged from a subdirectory\n'

mkdir -p "$REPO/sub/deeper"
OUT8="$(cd "$REPO/sub/deeper" && bash "$LINT" --staged 2>&1)"; EC8=$?
if [ "$EC8" -eq 1 ]; then pass "--staged from subdir still finds the staged issue"; else fail "expected exit 1 from subdir, got $EC8" "$OUT8"; fi
assert_contains "--staged from subdir reports the staged file" "staged.sh" "$OUT8"

# ---------------------------------------------------------------------------
# Case 9: explicit missing file is not a false clean (exit 2, not "clean")
# ---------------------------------------------------------------------------
printf '\nCase 9: all-missing explicit input is not a false clean\n'

OUT9="$(bash "$LINT" "$TMP_ROOT/does-not-exist.sh" 2>&1)"; EC9=$?
if [ "$EC9" -eq 2 ]; then pass "all-missing explicit input exits 2"; else fail "expected exit 2, got $EC9" "$OUT9"; fi
assert_not_contains "missing-file run does not report clean" "clean (" "$OUT9"

# ---------------------------------------------------------------------------
# Case 10: set -Ee (errtrace+errexit bundle) is flagged (case-insensitive prefix)
# ---------------------------------------------------------------------------
printf '\nCase 10: set -Ee flagged\n'

EE2="$TMP_ROOT/ee2.sh"
printf '#!/usr/bin/env bash\nset -Ee\necho hi\n' > "$EE2"
OUT10="$(bash "$LINT" "$EE2" 2>&1)"; EC10=$?
if [ "$EC10" -eq 1 ] && printf '%s' "$OUT10" | grep -qF errexit; then
    pass "set -Ee flagged as errexit"
else
    fail "set -Ee should be flagged" "$OUT10"
fi

# ---------------------------------------------------------------------------
printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
