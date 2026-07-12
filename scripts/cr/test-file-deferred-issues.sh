#!/usr/bin/env bash
# Tests for file-deferred-issues.sh routing through the forge seam (HIMMEL-327).
# Exercises the GitHub path (FORGE=github via a `gh` stub on PATH + GH_CMD) and
# the Bitbucket issues-disabled graceful degrade (FORGE=bitbucket, CLI exit 3 →
# warn + exit 0, spec §5.2). No network: every forge call is stubbed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FDI="$SCRIPT_DIR/file-deferred-issues.sh"

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
assert_contains() {  # name haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *)      fail "$1" "expected to contain '$3' in: $2" ;;
    esac
}
assert_not_contains() {  # name haystack needle
    case "$2" in
        *"$3"*) fail "$1" "expected NOT to contain '$3' in: $2" ;;
        *)      pass "$1" ;;
    esac
}
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi; }

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# A git repo with one commit — the script calls `git rev-parse --short HEAD`.
REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
git -C "$REPO" commit -q --allow-empty -m init

# Two deferred-class findings.
INPUT="$TMP_ROOT/review.txt"
cat >"$INPUT" <<'EOF'
src/a.ts:10: NIT: rename foo. use bar.
docs/readme.md: LOW: missing example. add one.
EOF

# ── GitHub path: a `gh` stub on PATH (dedupe/label call bare `gh`) AND via
# GH_CMD (the seam's repo-context + issue-create). ISSUE_LIST_RESULT lets a case
# simulate "duplicate exists" by exporting an issue number.
BIN="$TMP_ROOT/bin"; mkdir -p "$BIN"
# PATH needs the unix form (/c/...): a `C:/...` element mis-splits on the `:`
# PATH separator under Git Bash, so the bare-`gh` dedupe/label calls would fall
# through to the real gh. GH_CMD is invoked directly (not via PATH), so the
# `C:/` form is fine there.
BIN_UNIX=$(cygpath -u "$BIN" 2>/dev/null || printf '%s' "$BIN")
GH_STUB="$BIN/gh"
cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"label create"*)            exit 0 ;;
    *"issue list"*)              printf '%s' "${ISSUE_LIST_RESULT:-}" ;;
    *"issue create"*)            echo "https://github.com/owner/repo/issues/99" ;;
    *) echo "gh-stub: unhandled: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB"

run_gh() {  # runs the filer on the GitHub path; echoes combined stdout+stderr
    ( cd "$REPO" && PATH="$BIN_UNIX:$PATH" FORGE=github GH_CMD="$GH_STUB" \
        ISSUE_LIST_RESULT="${ISSUE_LIST_RESULT:-}" \
        bash "$FDI" --pr 1 --input "$INPUT" "$@" 2>&1 )
}

echo "TEST: GitHub path files both findings"
out=$(ISSUE_LIST_RESULT="" run_gh); rc=$?
assert_eq "github files → exit 0" "0" "$rc"
assert_contains "github filed first"  "$out" "filed https://github.com/owner/repo/issues/99"
assert_contains "github summary 2 filed" "$out" "2 filed"

echo "TEST: GitHub path dedupes when an issue already exists"
out=$(ISSUE_LIST_RESULT="42" run_gh); rc=$?
assert_eq "github dedupe → exit 0" "0" "$rc"
assert_contains "github skipped duplicate" "$out" "skipped (duplicate, issue #42)"
assert_not_contains "github dedupe files nothing" "$out" "filed https://github.com"

echo "TEST: GitHub path dry-run files nothing"
out=$(ISSUE_LIST_RESULT="" run_gh --dry-run); rc=$?
assert_eq "github dry-run → exit 0" "0" "$rc"
assert_contains "github dry-run plan" "$out" "skipped (dry-run)"
assert_not_contains "github dry-run no create" "$out" "filed https://github.com"

# ── GitHub path: a REAL create failure (rc neither 0 nor 3) must surface as
# FAILED + exit 3 — NOT be mistaken for the issues-disabled degrade.
BIN2="$TMP_ROOT/bin2"; mkdir -p "$BIN2"
BIN2_UNIX=$(cygpath -u "$BIN2" 2>/dev/null || printf '%s' "$BIN2")
cat >"$BIN2/gh" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*nameWithOwner*) echo "owner/repo" ;;
    *"label create"*)            exit 0 ;;
    *"issue list"*)              printf '' ;;
    *"issue create"*)            echo "gh: HTTP 500 boom" >&2; exit 1 ;;
    *) echo "gh-stub2: unhandled: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$BIN2/gh"

echo "TEST: GitHub path surfaces a real create failure (exit 3, not a degrade)"
out=$( cd "$REPO" && PATH="$BIN2_UNIX:$PATH" FORGE=github GH_CMD="$BIN2/gh" \
    bash "$FDI" --pr 1 --input "$INPUT" 2>&1 ); rc=$?
assert_eq "github create-fail → exit 3" "3" "$rc"
assert_contains "github FAILED line" "$out" "FAILED"
assert_not_contains "github create-fail not degraded" "$out" "issue tracker appears disabled"

# ── Bitbucket path: issues disabled → CLI `issue create` exits 3 → degrade.
BB_STUB="$TMP_ROOT/bb-stub.sh"
cat >"$BB_STUB" <<'STUB'
#!/usr/bin/env bash
case "$* " in
    "repo view"*)    echo '{"workspace":"ws","repo_slug":"repo","full_name":"ws/repo","default_branch":"main"}' ;;
    "issue create"*) echo "bitbucket: issue create failed: issue tracker is disabled on this repository (404)" >&2; exit 3 ;;
    *) echo "bb-stub: unhandled: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$BB_STUB"

echo "TEST: Bitbucket issues-disabled degrades gracefully (spec §5.2)"
out=$( cd "$REPO" && FORGE=bitbucket BITBUCKET_CMD="$BB_STUB" \
    bash "$FDI" --pr 1 --input "$INPUT" 2>&1 ); rc=$?
assert_eq "bitbucket degrade → exit 0" "0" "$rc"
assert_contains "bitbucket warns issues disabled" "$out" "issue tracker appears disabled on this bitbucket repository"
assert_contains "bitbucket names finding 1" "$out" "src/a.ts:10: NIT: rename foo."
assert_contains "bitbucket names finding 2" "$out" "docs/readme.md: LOW: missing example."
assert_not_contains "bitbucket files nothing" "$out" "filed http"
assert_not_contains "bitbucket no summary line" "$out" "file-deferred-issues: summary"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
