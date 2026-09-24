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
CASE_PATTERN=$(printf '%s' "$CASE_LINE" | sed -E 's/^[[:space:]]*//; s/\).*$//')
if [ "$CASE_PATTERN" != "''|0|false|off|no" ]; then
    fail "$GO_GATE_SRC's console_leg falsy branch no longer matches exactly the five spellings (empty/0/false/off/no) -- got: $CASE_LINE"
fi

# --- 2. Structural: no call site still hand-rolls the case statement -----
for site in "$MERGE_ON_GREEN_SRC" "$BLOCK_CR_MERGE_SRC" "$GO_SCRIPT"; do
    if grep -qE "HIMMEL_CONSOLE_LEG.*tr -d '\[:space:\]'.*\bin\$|case .*HIMMEL_CONSOLE_LEG" "$site"; then
        fail "$site still hand-rolls a HIMMEL_CONSOLE_LEG case statement instead of calling console_leg"
    fi
    # Executable call only: strip full-line comments and the two references
    # to the name that are not invocations (declare -F probe, unset -f drop).
    if ! grep -vE '^[[:space:]]*#' "$site" | grep -vE 'declare -F console_leg|unset -f' | grep -q 'console_leg'; then
        fail "$site never calls console_leg -- HIMMEL-3149 predicate not wired in"
    fi
done

# --- 3. Live end-to-end: full table against go.sh (cheapest call site) ---
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-go-gate.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$ROOT"' EXIT
ROOT="$(cd "$ROOT" && pwd)"
# HIMMEL-3543: go.sh mints its GO key under $HOME/.config/himmel — a scratch
# HOME keeps every run below off the operator's real key.
export HOME="$ROOT/home"
mkdir -p "$HOME"
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

# --- 4. HIMMEL-3543: a GO is authenticated, not merely present -----------
# A leg that can write the handover root must not be able to forge its own
# GO. go.sh signs pr|sha with a key only it mints; go_gate verifies the mac.
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY 2>/dev/null || true
GROOT="$ROOT/g4"
mkdir -p "$GROOT/.locks/go"
gate() {  # <pr> <sha> -> rc of go_gate in a clean shell, reason on stdout
    bash -c 'unset -f go_gate 2>/dev/null || true; . "$1"; go_gate "$2" "$3" "$4"' _ "$GO_GATE_SRC" "$1" "$2" "$GROOT"
}

# 4a. A leg-planted GO — the plain lines go.sh used to write — is refused.
printf 'pr=%s\nhead=%s\nby=leg\nat=2026-09-24T00:00:00Z\n' 91 "$SHA" > "$GROOT/.locks/go/91.$SHA"
rc=0; out=$(gate 91 "$SHA") || rc=$?
[ "$rc" -eq 2 ] || fail "4a: a leg-planted GO (no mac) was accepted by go_gate (rc=$rc) -- HIMMEL-3543"
case "$out" in *mac*) ;; *) fail "4a: refusal does not name the mac as the cause: $out" ;; esac

# 4b. A real console GO written by go.sh passes.
rc=0; HANDOVER_DIR="$GROOT" bash "$GO_SCRIPT" 92 "$SHA" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "4b: go.sh could not write a GO (rc=$rc)"
rc=0; out=$(gate 92 "$SHA") || rc=$?
[ "$rc" -eq 0 ] || fail "4b: a real console GO was refused (rc=$rc): $out"

# 4c. The key go.sh minted is 0600 and 64 hex chars.
KEY="$HOME/.config/himmel/go-hmac.key"
if [ ! -f "$KEY" ]; then
    fail "4c: go.sh minted no key at $KEY"
else
    mode=$(stat -c %a "$KEY" 2>/dev/null || stat -f %Lp "$KEY" 2>/dev/null)
    [ "$mode" = "600" ] || fail "4c: key mode is $mode, want 600"
    grep -qxE '[0-9a-f]{64}' "$KEY" || fail "4c: key is not 64 lowercase hex chars"
fi

# 4d. A real GO copied onto another PR's path, pr= line rewritten, is refused:
# the mac binds pr as well as sha.
sed 's/^pr=92$/pr=93/' "$GROOT/.locks/go/92.$SHA" > "$GROOT/.locks/go/93.$SHA"
rc=0; gate 93 "$SHA" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "4d: a GO re-bound to another PR was accepted (rc=$rc)"

# 4e. The mac is a real HMAC-SHA256 over himmel-go-v1|<pr>|<sha>.
if [ -f "$KEY" ]; then
    want=$(printf 'himmel-go-v1|92|%s' "$SHA" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "$KEY")" | awk '{print $NF}')
    got=$(sed -n 's/^mac=//p' "$GROOT/.locks/go/92.$SHA")
    if [ -z "$want" ] || [ "$got" != "$want" ]; then
        fail "4e: mac [$got] is not HMAC-SHA256 [$want]"
    fi
fi

# 4f. No key at the verifier (a different HOME) fails closed.
rc=0; HOME="$ROOT/nokey" gate 92 "$SHA" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "4f: go_gate accepted a GO with no key to verify against (rc=$rc)"
[ ! -e "$ROOT/nokey/.config/himmel/go-hmac.key" ] || fail "4f: the verifier minted a key (only go.sh may)"

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: test-go-gate.sh"
    exit 0
fi
exit 1
