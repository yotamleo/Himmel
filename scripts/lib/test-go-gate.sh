#!/usr/bin/env bash
# scripts/lib/test-go-gate.sh -- fixture test for scripts/lib/go-gate.sh's
# console_leg() predicate (HIMMEL-3149).
#
# Before HIMMEL-3149 the HIMMEL_CONSOLE_LEG truthiness test was hand-copied at
# three sites (merge-on-green.sh's _truthy(), block-unresolved-cr-merge.sh's
# gate 3, console-kit/go.sh's inline check) with no shared source of truth --
# nothing stopped one copy drifting from the other two. This suite is a single
# table-driven test: one spellings list, checked directly against console_leg()
# and, for the cheapest call site (go.sh, which only needs a HANDOVER_DIR
# fixture and no gh/network calls), against the live end-to-end behaviour too.
# It also asserts structurally that none of the three sites still hand-rolls
# its own case statement -- each must call console_leg instead.
#
# RED-control instructions for reviewers (HIMMEL-3149 contract step 3):
#   BEFORE the fix: `git stash` the go-gate.sh/merge-on-green.sh/
#   block-unresolved-cr-merge.sh/go.sh changes (keep this test file) and rerun
#   -- FAIL, because scripts/lib/go-gate.sh has no console_leg() to source.
#   AFTER the fix, to prove the table itself can fail: temporarily add a
#   spelling (e.g. 'disabled') to ONE call site's own copy in a scratch file,
#   point this suite's *_SRC override at it, rerun -- FAIL naming the site;
#   then `bash scripts/git/restore-to-head.sh <path>` to restore.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, no .ps1 twin needed (no hook
# dispatch here).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_GATE_SRC="${GO_GATE_SRC:-$HERE/go-gate.sh}"
GO_SCRIPT="${GO_SCRIPT:-$HERE/../handover/console-kit/go.sh}"
MERGE_ON_GREEN_SRC="${MERGE_ON_GREEN_SRC:-$HERE/../handover/merge-on-green.sh}"
BLOCK_CR_MERGE_SRC="${BLOCK_CR_MERGE_SRC:-$HERE/../hooks/block-unresolved-cr-merge.sh}"

FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }

# --- 1. Table-driven: console_leg() directly ------------------------------
# One spellings list, each row (value, expected rc). Falsy: empty, 0, false,
# off, no -- case-insensitive, whitespace-stripped, same five every call site
# used before HIMMEL-3149. Everything else is truthy.
SPELLINGS='
""|0
"0"|0
"false"|0
"off"|0
"no"|0
"FALSE"|0
"Off"|0
"NO"|0
" 0 "|0
"  "|0
"1"|1
"true"|1
"yes"|1
"TRUE"|1
" 1 "|1
"2"|1
"anything"|1
'

unset -f console_leg go_gate 2>/dev/null || true
# shellcheck source=/dev/null
if ! . "$GO_GATE_SRC" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1; then
    fail "cannot source $GO_GATE_SRC or it does not define console_leg -- this is the RED-before-fix case"
else
    old_ifs="$IFS"
    IFS='
'
    for row in $SPELLINGS; do
        IFS="$old_ifs"
        [ -n "$row" ] || continue
        val="${row%%|*}"
        exp_truthy="${row##*|}"
        val="${val#\"}"; val="${val%\"}"
        rc=0
        HIMMEL_CONSOLE_LEG="$val" bash -c '
            unset -f console_leg 2>/dev/null || true
            . "$1"
            console_leg
        ' _ "$GO_GATE_SRC" || rc=$?
        if [ "$exp_truthy" -eq 1 ] && [ "$rc" -ne 0 ]; then
            fail "console_leg HIMMEL_CONSOLE_LEG='$val' expected truthy (rc 0), got rc=$rc"
        elif [ "$exp_truthy" -eq 0 ] && [ "$rc" -eq 0 ]; then
            fail "console_leg HIMMEL_CONSOLE_LEG='$val' expected falsy (rc!=0), got rc=0"
        fi
        IFS='
'
    done
    IFS="$old_ifs"
fi

# --- 1b. Structural: the shared predicate must match exactly the five
# documented falsy spellings, no more, no fewer -- guards against a NEW
# spelling being added to the one shared site (forbidden, see the ticket's
# do-not list), which the plain value table above would otherwise miss if the
# new spelling isn't also added there.
CASE_LINE=$(grep -E "return 1 ;;" "$GO_GATE_SRC" 2>/dev/null | head -1)
if ! printf '%s' "$CASE_LINE" | grep -qE "''\|0\|false\|off\|no\) return 1"; then
    fail "$GO_GATE_SRC's console_leg falsy branch no longer matches exactly the five spellings (empty/0/false/off/no) -- got: $CASE_LINE"
fi

# --- 2. Structural: no call site still hand-rolls the case statement -----
for site in "$MERGE_ON_GREEN_SRC" "$BLOCK_CR_MERGE_SRC" "$GO_SCRIPT"; do
    if grep -qE "HIMMEL_CONSOLE_LEG.*tr -d '\[:space:\]'.*\bin\$|case .*HIMMEL_CONSOLE_LEG" "$site"; then
        fail "$site still hand-rolls a HIMMEL_CONSOLE_LEG case statement instead of calling console_leg"
    fi
    if ! grep -q 'console_leg' "$site"; then
        fail "$site never calls console_leg -- HIMMEL-3149 predicate not wired in"
    fi
done

# --- 3. Live end-to-end: full table against go.sh (cheapest call site) ---
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-go-gate.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$ROOT"' EXIT
SHA="$(printf '%040d' 7)"

old_ifs="$IFS"
IFS='
'
for row in $SPELLINGS; do
    IFS="$old_ifs"
    [ -n "$row" ] || continue
    val="${row%%|*}"
    exp_truthy="${row##*|}"
    val="${val#\"}"; val="${val%\"}"
    rc=0
    HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_LEG="$val" bash "$GO_SCRIPT" 77 "$SHA" >/dev/null 2>&1 || rc=$?
    if [ "$exp_truthy" -eq 1 ]; then
        if [ "$rc" -ne 3 ]; then
            fail "go.sh HIMMEL_CONSOLE_LEG='$val' expected refusal (rc 3), got rc=$rc"
        fi
    else
        if [ "$rc" -ne 0 ]; then
            fail "go.sh HIMMEL_CONSOLE_LEG='$val' expected a written GO (rc 0), got rc=$rc"
        fi
    fi
    IFS='
'
done
IFS="$old_ifs"

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: test-go-gate.sh"
    exit 0
fi
exit 1
