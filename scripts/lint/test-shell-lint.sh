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
# 7-10. heredoc-body set -e, --staged-from-subdir, missing-file exit 2, set -Ee.
# 11-17. CR-learnings advisory checks (HIMMEL-1315, 2026-07-28): regex-class,
#        mktemp template, bash32 constructs, echo-e, gnu-flag (+BSD-fallback
#        exclusion + gnu-ok exemption), BOM covers .ps1, --staged admits .ps1.
#  18. self-check (HIMMEL-1355): shell-lint reports no findings against this
#      suite's own file (its fixtures/assertions are exempted from advisory
#      checks the same way shell-lint.sh exempts its own source).
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
# Cases 11-17: CR-learnings advisory portability checks (HIMMEL-1315, 2026-07-28).
# ---------------------------------------------------------------------------

# Case 11: [regex-class] — \s/\d/\w in a grep -E pattern is flagged; a POSIX
# class ([[:space:]]) is not.
printf '\nCase 11: regex-class detection\n'
RC_BAD="$TMP_ROOT/rc_bad.sh"
cat > "$RC_BAD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
grep -E '\s+' file
EOF
OUT11="$(bash "$LINT" "$RC_BAD" 2>&1)"
if printf '%s' "$OUT11" | grep -qF '[regex-class]'; then pass "regex-class flags \\s in grep -E"; else fail "regex-class should flag \\s" "$OUT11"; fi
RC_GOOD="$TMP_ROOT/rc_good.sh"
cat > "$RC_GOOD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
grep -E '[[:space:]]+' file
EOF
OUT11b="$(bash "$LINT" "$RC_GOOD" 2>&1)"
if printf '%s' "$OUT11b" | grep -qF '[regex-class]'; then fail "regex-class false positive on POSIX class" "$OUT11b"; else pass "regex-class ignores POSIX [[:space:]]"; fi

# Case 12: [mktemp] — no-template mktemp/-d is flagged; a templated form is not.
printf '\nCase 12: mktemp template detection\n'
MT_BAD="$TMP_ROOT/mt_bad.sh"
cat > "$MT_BAD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
d="$(mktemp -d)"
EOF
OUT12="$(bash "$LINT" "$MT_BAD" 2>&1)"
if printf '%s' "$OUT12" | grep -qF '[mktemp]'; then pass "mktemp flags no-template mktemp -d"; else fail "mktemp should flag no-template" "$OUT12"; fi
MT_GOOD="$TMP_ROOT/mt_good.sh"
cat > "$MT_GOOD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
d="$(mktemp -d -t prefix.XXXXXX)"
EOF
OUT12b="$(bash "$LINT" "$MT_GOOD" 2>&1)"
if printf '%s' "$OUT12b" | grep -qF '[mktemp]'; then fail "mktemp false positive on templated form" "$OUT12b"; else pass "mktemp ignores templated form"; fi

# Case 13: [bash32] — declare -A is flagged.
printf '\nCase 13: bash32 detection\n'
B32="$TMP_ROOT/b32.sh"
cat > "$B32" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
declare -A seen
EOF
OUT13="$(bash "$LINT" "$B32" 2>&1)"
if printf '%s' "$OUT13" | grep -qF '[bash32]'; then pass "bash32 flags declare -A"; else fail "bash32 should flag declare -A" "$OUT13"; fi

# Case 14: [echo-e] — echo -e is flagged.
printf '\nCase 14: echo-e detection\n'
EFLAG="$TMP_ROOT/eflag.sh"
cat > "$EFLAG" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo -e "hi"
EOF
OUT14="$(bash "$LINT" "$EFLAG" 2>&1)"
if printf '%s' "$OUT14" | grep -qF '[echo-e]'; then pass "echo-e flags echo -e"; else fail "echo-e should flag echo -e" "$OUT14"; fi

# Case 15: [gnu-flag] — grep -P flagged; GNU||BSD portable idiom not; gnu-ok
# marker (preceding line) exempts.
printf '\nCase 15: gnu-flag detection + BSD-fallback + gnu-ok exemption\n'
GF_BAD="$TMP_ROOT/gf_bad.sh"
cat > "$GF_BAD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "$x" | grep -oP '"id"'
EOF
OUT15="$(bash "$LINT" "$GF_BAD" 2>&1)"
if printf '%s' "$OUT15" | grep -qF '[gnu-flag]'; then pass "gnu-flag flags grep -P"; else fail "gnu-flag should flag grep -P" "$OUT15"; fi
GF_FB="$TMP_ROOT/gf_fb.sh"
cat > "$GF_FB" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
EOF
OUT15b="$(bash "$LINT" "$GF_FB" 2>&1)"
if printf '%s' "$OUT15b" | grep -qF '[gnu-flag]'; then fail "gnu-flag false positive on GNU||BSD fallback" "$OUT15b"; else pass "gnu-flag ignores GNU||BSD portable idiom"; fi
GF_OK="$TMP_ROOT/gf_ok.sh"
cat > "$GF_OK" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
# gnu-ok: JSON extraction needs PCRE
echo "$x" | grep -oP '"id"'
EOF
OUT15c="$(bash "$LINT" "$GF_OK" 2>&1)"
if printf '%s' "$OUT15c" | grep -qF '[gnu-flag]'; then fail "gnu-ok marker did not exempt grep -P" "$OUT15c"; else pass "gnu-ok marker exempts grep -P"; fi

# Case 16: [BOM] covers *.ps1, and a .ps1 runs NO shell-specific check.
printf '\nCase 16: BOM covers .ps1; .ps1 skips shell checks\n'
PS1="$TMP_ROOT/thing.ps1"
_write_bom_file "$PS1" <<'EOF'
Write-Output "hi"
EOF
OUT16="$(bash "$LINT" "$PS1" 2>&1)"
if printf '%s' "$OUT16" | grep -qF '[BOM]'; then pass "BOM detected in .ps1"; else fail "BOM should be detected in .ps1" "$OUT16"; fi
if printf '%s' "$OUT16" | grep -qE '\[(errexit|shellcheck|regex-class|mktemp|bash32|gnu-flag|echo-e)\]'; then
    fail ".ps1 ran a shell-specific check" "$OUT16"
else
    pass ".ps1 reaches [BOM] only"
fi

# Case 17: --staged lints a staged .ps1 (BOM) — the gathering admits *.ps1.
printf '\nCase 17: --staged lints a staged .ps1\n'
REPO2="$TMP_ROOT/repo2"
mkdir -p "$REPO2"
(
    cd "$REPO2" || exit 1
    git init -q
    git config user.email t@t.t
    git config user.name t
    printf '\xEF\xBB\xBF' > staged.ps1
    printf 'Write-Output hi\n' >> staged.ps1
    git add staged.ps1
)
OUT17="$(cd "$REPO2" && bash "$LINT" --staged 2>&1)"
if printf '%s' "$OUT17" | grep -qF 'staged.ps1' && printf '%s' "$OUT17" | grep -qF '[BOM]'; then
    pass "--staged detects BOM in staged .ps1"
else
    fail "--staged should lint a staged .ps1 BOM" "$OUT17"
fi

# Case 18: shell-lint reports no findings against its own test file
# (HIMMEL-1355) — this suite's fixtures/assertions embed the same
# patterns/tags/hints as DATA (e.g. Case 12's `mktemp -d`, Case 16's grep
# alternation naming every advisory tag), so shell-lint exempts
# scripts/lint/test-shell-lint.sh from advisory checks alongside its own
# source. Guard that exemption directly against the real file on disk.
# ---------------------------------------------------------------------------
printf '\nCase 18: shell-lint has no findings on its own test file\n'
SELF="$SCRIPT_DIR/test-shell-lint.sh"
OUT18="$(bash "$LINT" "$SELF" 2>&1)"; EC18=$?
if [ "$EC18" -eq 0 ]; then pass "shell-lint exits 0 on test-shell-lint.sh"; else fail "expected exit 0, got $EC18" "$OUT18"; fi
if printf '%s' "$OUT18" | grep -qE '\[(regex-class|mktemp|bash32|gnu-flag|echo-e)\]'; then
    fail "shell-lint should not report advisory findings on its own test file" "$OUT18"
else
    pass "no advisory findings on test-shell-lint.sh"
fi

# ---------------------------------------------------------------------------
printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
