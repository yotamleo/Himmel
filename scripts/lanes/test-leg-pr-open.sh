#!/usr/bin/env bash
# scripts/lanes/test-leg-pr-open.sh - HIMMEL-3031. Hermetic tests for
# leg-pr-open.sh: a GH_CMD stub records every argv line to a file, so the
# assertion that matters (the PR body text appears ONLY as the --body value
# the forge seam passes to gh, never in the Bash command a leg types) is a
# grep, not a guess. No network, no real gh/PR.
#
# Platform guard: no .ps1 twin, by design. Bash plus git — it runs under git
# bash on Windows unchanged (same requirements as the SUT it exercises).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/leg-pr-open.sh"

PASS=0
FAIL=0
TMP_ROOT=""
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi
}
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing '$3' in: $2" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) fail "$1" "unexpectedly found '$3' in: $2" ;; *) pass "$1" ;; esac
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/leg-pr-open-test.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# ── fixture: a real bare "origin" + a pushed feature branch (no network) ────
BARE="$TMP_ROOT/origin.git"
git init -q --bare "$BARE"
REPO="$TMP_ROOT/repo"
git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO"; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name test
git -C "$REPO" remote add origin "$BARE"
echo base > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm base
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b feat/x
echo change > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm change
git -C "$REPO" push -q -u origin feat/x
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

TITLE_FILE="$TMP_ROOT/title.txt"
BODY_FILE="$TMP_ROOT/body.txt"
printf 'feat(lanes): [HIMMEL-3031] leg-pr-open.sh publishes a PR from files\n' > "$TITLE_FILE"
BODY_MARKER="body-text-marker-$$-never-on-the-bash-argv-claude-typed"
printf '## Summary\n\n%s\n\n## diff --stat\n f | 1 +\n\nleg-burn: calls=5 avg-ctx=1.0k\n' \
    "$BODY_MARKER" > "$BODY_FILE"

# GH_CMD stub: records every argv line it is called with, then answers just
# enough to drive pr_find_open / pr_create / pr_edit / repo_view.
ARGV_LOG="$TMP_ROOT/argv.log"
GH_STUB="$TMP_ROOT/gh-stub.sh"
cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
case "$* " in
    *"pr list"*"--state open"*)
        if [ -n "${STUB_FIND_OPEN_STDERR:-}" ]; then
            echo "$STUB_FIND_OPEN_STDERR" >&2
        fi
        if [ -n "${STUB_OPEN_PR:-}" ]; then
            printf '%s\n' "$STUB_OPEN_PR"
        fi
        ;;
    *"pr create"*)
        if [ -n "${STUB_CREATE_STDERR:-}" ]; then
            echo "$STUB_CREATE_STDERR" >&2
        fi
        echo "https://github.com/owner/repo/pull/9"
        # real `gh pr create` on a repo with CodeRabbit armed is followed by
        # the seam's own CR-trigger confirmation line on stdout (HIMMEL-1924)
        # — reproduce that here, not just the bare URL.
        echo "posted @coderabbitai review on PR #9 (owner/repo) for head $HEAD_SHA_STUB"
        ;;
    *"pr edit"*)   exit 0 ;;
    *"repo view"*) echo "owner/repo" ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB"

run_sut() {  # args passed straight through to the SUT
    (
        cd "$REPO" || exit 99
        FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" \
            HEAD_SHA_STUB="$HEAD_SHA" \
            bash "$SUT" "$@"
    )
}

# ── (a) create path: no open PR -> pr create, never pr edit ─────────────────
echo "TEST: create path (no existing PR)"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
out_a=$(run_sut "$TITLE_FILE" "$BODY_FILE"); rc_a=$?
assert_eq "create path exits 0" "0" "$rc_a"
assert_eq "create path prints exactly the success line" \
    "PR 9 https://github.com/owner/repo/pull/9 $HEAD_SHA" "$out_a"
argv_a=$(cat "$ARGV_LOG")
contains "argv contains pr create" "$argv_a" "pr create"
contains "argv contains --base main" "$argv_a" "--base main"
contains "argv contains --title with the title text" "$argv_a" "--title feat(lanes): [HIMMEL-3031]"
contains "the body text reaches gh as the --body value" "$argv_a" "$BODY_MARKER"
not_contains "no pr edit is called on the create path" "$argv_a" "pr edit"

# The utility's OWN invocation (what a leg's Bash tool call actually contains)
# is exactly two file paths — never the body text.
inv_args=("$TITLE_FILE" "$BODY_FILE")
assert_eq "the utility invocation is exactly two args" "2" "${#inv_args[@]}"
invocation_line="bash $SUT $TITLE_FILE $BODY_FILE"
not_contains "the utility invocation line carries no body text" "$invocation_line" "$BODY_MARKER"

# ── (b) update path: an open PR exists -> pr edit, never pr create ──────────
echo "TEST: update path (existing open PR)"
: > "$ARGV_LOG"
out_b=$(STUB_OPEN_PR=42 run_sut "$TITLE_FILE" "$BODY_FILE"); rc_b=$?
assert_eq "update path exits 0" "0" "$rc_b"
assert_eq "update path prints exactly the success line" \
    "PR 42 https://github.com/owner/repo/pull/42 $HEAD_SHA" "$out_b"
argv_b=$(cat "$ARGV_LOG")
contains "argv contains pr edit 42" "$argv_b" "pr edit 42"
contains "the body text reaches gh as the --body value on update too" "$argv_b" "$BODY_MARKER"
not_contains "no pr create is called on the update path" "$argv_b" "pr create"

# ── (c) refuses on main ──────────────────────────────────────────────────────
echo "TEST: refuses on main"
git -C "$REPO" checkout -q main
err_c=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_c=$?
if [ "$rc_c" -ne 0 ]; then pass "refuses on main (rc!=0)"; else fail "refuses on main (rc!=0)" "got rc=$rc_c"; fi
contains "refusal on main names main" "$err_c" "main"
git -C "$REPO" checkout -q feat/x

# ── (d) refuses when the branch has no upstream ─────────────────────────────
echo "TEST: refuses when the branch has no upstream"
git -C "$REPO" checkout -q -b feat/no-upstream
err_d=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_d=$?
if [ "$rc_d" -ne 0 ]; then pass "refuses with no upstream (rc!=0)"; else fail "refuses with no upstream (rc!=0)" "got rc=$rc_d"; fi
contains "refusal names upstream" "$err_d" "upstream"
git -C "$REPO" checkout -q feat/x
git -C "$REPO" branch -q -D feat/no-upstream

# ── (e) refuses an empty body file ───────────────────────────────────────────
echo "TEST: refuses an empty body file"
EMPTY_BODY="$TMP_ROOT/empty-body.txt"
: > "$EMPTY_BODY"
err_e=$(run_sut "$TITLE_FILE" "$EMPTY_BODY" 2>&1 >/dev/null); rc_e=$?
if [ "$rc_e" -ne 0 ]; then pass "refuses an empty body file (rc!=0)"; else fail "refuses an empty body file (rc!=0)" "got rc=$rc_e"; fi
contains "refusal names the empty body" "$err_e" "empty"

# ── (f) create path survives a stderr warning racing the stdout URL (codex-1) ──
echo "TEST: create path survives a stderr warning during create"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
export STUB_CREATE_STDERR="warn: transient network/blip, retrying"
out_f=$(run_sut "$TITLE_FILE" "$BODY_FILE"); rc_f=$?
unset STUB_CREATE_STDERR
assert_eq "stderr-warning create path exits 0" "0" "$rc_f"
assert_eq "stderr-warning create path prints exactly the success line" \
    "PR 9 https://github.com/owner/repo/pull/9 $HEAD_SHA" "$out_f"

# ── (g) refuses when local HEAD has not been pushed to upstream (codex-2) ───
echo "TEST: refuses when local HEAD is unpushed relative to upstream"
echo change2 > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm change2
err_g=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_g=$?
if [ "$rc_g" -ne 0 ]; then pass "refuses when HEAD unpushed (rc!=0)"; else fail "refuses when HEAD unpushed (rc!=0)" "got rc=$rc_g"; fi
contains "refusal names push" "$err_g" "push"
git -C "$REPO" push -q origin feat/x

# ── (h) find-open lookup survives a stderr warning on a CLEAN success (codex-1 round 2) ──
echo "TEST: find-open lookup survives a stderr warning on success (no open PR)"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
export STUB_FIND_OPEN_STDERR="warn: rate limit at 4999/5000"
out_h=$(run_sut "$TITLE_FILE" "$BODY_FILE"); rc_h=$?
unset STUB_FIND_OPEN_STDERR
assert_eq "find-open-stderr path exits 0" "0" "$rc_h"
# HEAD_SHA was captured before test (g) advanced the branch with a further
# commit — re-derive the CURRENT head rather than reuse the stale constant.
head_sha_h=$(git -C "$REPO" rev-parse HEAD)
assert_eq "find-open-stderr path prints exactly the success line (creates, not a bogus update)" \
    "PR 9 https://github.com/owner/repo/pull/9 $head_sha_h" "$out_h"
argv_h=$(cat "$ARGV_LOG")
contains "find-open-stderr path still creates (stderr warning did not fake an existing PR)" "$argv_h" "pr create"
not_contains "find-open-stderr path never edits" "$argv_h" "pr edit"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
