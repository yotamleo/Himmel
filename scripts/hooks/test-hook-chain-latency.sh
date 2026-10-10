#!/usr/bin/env bash
# Latency test for the PreToolUse Bash hook chain (HIMMEL-4678).
#
# Usage: bash scripts/hooks/test-hook-chain-latency.sh
#
# Why: run-hook-with-bash.js --chain runs every member under a time budget and
# a must-run member that overruns it FAILS CLOSED (a deny with a misleading
# reason). The station logged 275 such denies of block-chokepoint-env-prefix.sh
# in one day: its tokenizers walked the command one character at a time with
# ${s:i:1}, and bash computes that expansion's offset by scanning the string
# from the start (multibyte-decoding it in a UTF-8 locale), so every walker was
# O(n^2) in the command length. A 12 KB heredoc of prose took seconds idle and
# blew the 15 s member window under fleet load.
#
# Contract under test, for EVERY member wired on the Bash PreToolUse matcher
# (read from .claude/settings.json, so a new member is covered unasked):
#   * SCALING: four times the input costs at most SCALE_MAX times the time
#     (min of RUNS runs per size, so a load spike on one run does not count).
#     Linear work is <= 4x; the quadratic walkers were 9-14x.
#   * p95 PIN: across a corpus of everyday commands, the member's p95 wall time
#     stays under P95_BUDGET_MS.
#
# Budgets, measured 2026-10-07 on the station at load average 8-10 with two
# copies of this test running concurrently (HIMMEL-4678):
#   * p95: the slowest member (block-write-into-main-checkout.sh) peaked at
#     292 ms loaded; the budget is that x2 (the run-shell-tests.sh rule).
#   * SCALE_MAX is a ratio, which load mostly cancels, so it is NOT doubled:
#     the quadratic walkers this test was written against ran 9-14x. The pair is
#     160 -> 640 lines (HIMMEL-4729): the UTF-8 pattern ops it fixed only went
#     superlinear above about 20 KB, so the old 40 -> 160 pair could not see them.
# Env overrides exist for slower boxes, never to make a red go green.
#
# Exit codes: 0 all cases passed, 1 at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
SETTINGS="$ROOT/.claude/settings.json"

# Tenths, because bash arithmetic is integer: 45 = 4.5x.
SCALE_MAX_X10=${HOOK_LATENCY_SCALE_MAX_X10:-45}
SCALE_MAX="$((SCALE_MAX_X10 / 10)).$((SCALE_MAX_X10 % 10))"
# Every member run is bounded, so a hung member fails this test, not the CI shard.
# The bound is a GNU timeout/gtimeout resolved once (stock macOS ships neither);
# without one the member runs unbounded rather than as command-not-found.
MEMBER_TIMEOUT=${HOOK_LATENCY_MEMBER_TIMEOUT:-60}
# shellcheck source=../lib/timeout-bin.sh
. "$ROOT/scripts/lib/timeout-bin.sh"
P95_BUDGET_MS=${HOOK_LATENCY_P95_BUDGET_MS:-600}
RUNS=3

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

if [ -z "${EPOCHREALTIME:-}" ]; then
    echo "SKIP test-hook-chain-latency: needs bash >= 5 (EPOCHREALTIME)"
    exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "FAIL fixture: jq not found"; exit 1; }

# A UTF-8 locale: the quadratic cost is worst there, and it is what the station
# and the CI runners run hooks under.
# Without one the test would time the cheap path and pass vacuously, so no
# locale is a fixture failure, not a fallback.
LOCALES=$(locale -a 2>/dev/null)
UTF8_LOCALE=''
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if printf '%s\n' "$LOCALES" | grep -x -- "$l" >/dev/null; then UTF8_LOCALE=$l; break; fi
done
[ -n "$UTF8_LOCALE" ] || { echo "FAIL fixture: no UTF-8 locale (tried C.UTF-8, C.utf8, en_US.UTF-8, en_US.utf8)"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/hook-latency.XXXXXX") || { echo "FAIL fixture: mktemp"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"

MEMBERS=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$SETTINGS" \
    | grep -o -E 'scripts/hooks/[A-Za-z0-9_-]+\.sh' | awk '!seen[$0]++')
[ -n "$MEMBERS" ] || { echo "FAIL fixture: no Bash PreToolUse members in $SETTINGS"; exit 1; }

payload() {  # payload <command> <file>
    jq -n --arg c "$1" --arg cwd "$SANDBOX" \
        '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd, session_id: "hook-latency"}' > "$2" \
        && [ -s "$2" ] || { echo "FAIL fixture: jq wrote no payload to ${2##*/}"; exit 1; }
}

# A python heredoc of prose -- the shape that starved the chain on the station
# (HIMMEL-2975's 15 KB heredoc): multibyte text, quotes on every line.
prose() {  # prose <lines>
    local i out="python3 - <<'PYEOF'"$'\n'
    for ((i = 0; i < $1; i++)); do
        out+="print('line $i — the console hands the leg a brief; see the doc é')"$'\n'
    done
    printf '%sPYEOF' "$out"
}
# 160 -> 640 lines (about 11 KB -> 45 KB): the superlinear UTF-8 pattern ops of
# HIMMEL-4729 only show above about 20 KB, so the old 40 -> 160 pair hid them.
payload "$(prose 160)" "$SANDBOX/small.json"
payload "$(prose 640)" "$SANDBOX/big.json"

# shellcheck disable=SC2016  # the corpus is command TEXT; nothing expands here
CORPUS=(
    'git status'
    'ls -la scripts/hooks'
    'cd /tmp && grep -rn "needle" . | head -5'
    'bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-block-git-stash.sh'
    "jq -r '.hooks | keys[]' .claude/settings.json"
    'for f in scripts/hooks/*.sh; do wc -l "$f"; done'
    'git commit -m "fix(hooks): [HIMMEL-1] a subject — with a dash"'
    'gh pr view 1 --json title,state'
    'node scripts/jira/dist/index.js get HIMMEL-1'
    "$(prose 12)"
)
n=0
for c in "${CORPUS[@]}"; do payload "$c" "$SANDBOX/c$n.json"; n=$((n + 1)); done

MS=0
BAD_RC=''
# The role flags switch on the members gated to a leg or a relay session
# (read-clamp.sh, guard-relay-writes.sh), so their real path is timed rather
# than their first-line exit.
# A member answers 0 (allow / no opinion) or 2 (deny). Any other status is a
# broken member (a syntax error, a missing dependency) that exits fast and
# would otherwise pass both checks; the first one is kept in BAD_RC.
run_ms() {  # run_ms <member> <payload file> -- wall ms into MS
    local t0 t1 rc
    t0=${EPOCHREALTIME//[!0-9]/}
    env -i PATH="$PATH" HOME="$SANDBOX/home" TMPDIR="${TMPDIR:-/tmp}" \
        LANG="$UTF8_LOCALE" LC_ALL="$UTF8_LOCALE" CLAUDE_PROJECT_DIR="$ROOT" \
        HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_RELAY=1 \
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" "$MEMBER_TIMEOUT"} bash "$ROOT/$1" < "$2" > /dev/null 2>&1
    rc=$?
    t1=${EPOCHREALTIME//[!0-9]/}
    MS=$(( (t1 - t0) / 1000 ))
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && [ -z "$BAD_RC" ]; then
        BAD_RC="exit $rc on ${2##*/}"
    fi
}
min_ms() {  # min_ms <member> <payload file> -- min of RUNS runs into MS
    local k best=''
    for ((k = 0; k < RUNS; k++)); do
        run_ms "$1" "$2"
        if [ -z "$best" ] || [ "$MS" -lt "$best" ]; then best=$MS; fi
    done
    MS=$best
}

for m in $MEMBERS; do
    name=${m##*/}
    if [ ! -f "$ROOT/$m" ]; then fail "$name: wired in settings.json but missing"; continue; fi
    BAD_RC=''
    min_ms "$m" "$SANDBOX/small.json"; small=$MS
    min_ms "$m" "$SANDBOX/big.json"; big=$MS
    # +50ms of slack so a member that costs nothing at either size cannot fail
    # on scheduler noise alone.
    if [ $(( big * 10 )) -le $(( SCALE_MAX_X10 * small + 500 )) ]; then
        pass "$name scaling: 4x input ${small}ms -> ${big}ms (<= ${SCALE_MAX}x)"
    else
        fail "$name scaling: 4x input ${small}ms -> ${big}ms (> ${SCALE_MAX}x: superlinear)"
    fi

    samples=()
    for ((k = 0; k < n; k++)); do
        run_ms "$m" "$SANDBOX/c$k.json"; samples+=("$MS")
        run_ms "$m" "$SANDBOX/c$k.json"; samples+=("$MS")
    done
    total=${#samples[@]}
    idx=$(( (total * 95 + 99) / 100 - 1 ))
    p95=$(printf '%s\n' "${samples[@]}" | sort -n | sed -n "$((idx + 1))p")
    if [ "$p95" -le "$P95_BUDGET_MS" ]; then
        pass "$name p95 ${p95}ms over $total runs (<= ${P95_BUDGET_MS}ms)"
    else
        fail "$name p95 ${p95}ms over $total runs (> ${P95_BUDGET_MS}ms)"
    fi
    if [ -n "$BAD_RC" ]; then
        fail "$name: $BAD_RC (a member answers 0 or 2; anything else is broken)"
    fi
done

# Pathological shapes (HIMMEL-5154). The prose heredoc above is the shape the
# chain starved on, but each member has its own quadratic trap that prose never
# reaches: a long multibyte word, quoted multibyte, a quote-dense line, a
# `${...}` run, a `$"..."` run. One row per member, N and 4N repeats; a row
# fails when its member is made quadratic again.
rep() {  # rep <string> <count> -- doubling, so building the payload is linear
    local s=$1 cnt=$2 out=$1 k=1
    while [ $(( k * 2 )) -le "$cnt" ]; do out+=$out; k=$(( k * 2 )); done
    while [ "$k" -lt "$cnt" ]; do out+=$s; k=$(( k + 1 )); done
    printf '%s' "$out"
}
shape_row() {  # shape_row <member> <label> <unit> <small N> <big N> [<prefix> [<suffix> [<closer>]]]
    local m=$1 label=$2 unit=$3 ns=$4 nb=$5 pre=${6:-echo } suf=${7:-} cl=${8:-} name small big
    name=${m##*/}
    if [ ! -f "$ROOT/$m" ]; then fail "$name $label: wired member missing"; return; fi
    # a closer, when given, is repeated N times after the unit run (nesting)
    payload "${pre}$(rep "$unit" "$ns")$([ -n "$cl" ] && rep "$cl" "$ns")${suf}" "$SANDBOX/s.json"
    payload "${pre}$(rep "$unit" "$nb")$([ -n "$cl" ] && rep "$cl" "$nb")${suf}" "$SANDBOX/b.json"
    BAD_RC=''
    min_ms "$m" "$SANDBOX/s.json"; small=$MS
    min_ms "$m" "$SANDBOX/b.json"; big=$MS
    # A member that cannot source its library denies in about 2 ms at both
    # sizes (rc 2 is a legal answer), which would pass the ratio vacuously: a
    # shape row also requires that the member really scanned the payload.
    # (10 ms: five times a lib-less exit, with headroom on fast hosts.)
    if [ "$small" -lt 10 ]; then
        fail "$name $label: ran ${small}ms at the small size (exited before scanning: vacuous row)"
    elif [ $(( big * 10 )) -le $(( SCALE_MAX_X10 * small + 500 )) ]; then
        pass "$name $label: 4x input ${small}ms -> ${big}ms (<= ${SCALE_MAX}x)"
    else
        fail "$name $label: 4x input ${small}ms -> ${big}ms (> ${SCALE_MAX}x: superlinear)"
    fi
    if [ -n "$BAD_RC" ]; then fail "$name $label: $BAD_RC (a member answers 0 or 2; anything else is broken)"; fi
}
# shellcheck disable=SC2016,SC2088  # shape units are command TEXT; nothing expands here
{
    shape_row scripts/hooks/block-write-into-main-checkout.sh 'one long U+3000 word' '　' 500 2000
    shape_row scripts/hooks/block-destructive-commands.sh 'quoted multibyte' 'é"a b"; ' 1000 4000
    shape_row scripts/hooks/require-quiet-run.sh 'quote-dense line' "'a b' " 2000 8000
    shape_row scripts/hooks/block-chokepoint-env-prefix.sh '${...} run with multibyte' '${V}é' 500 2000 'echo é'
    shape_row scripts/hooks/block-chokepoint-env-prefix.sh 'dense unmatched ${ openers' '${V:-' 2000 8000
    shape_row scripts/hooks/block-chokepoint-env-prefix.sh 'deeply nested ${ with matching closers' '${V:-' 3000 12000 'echo ' '' '}'
    shape_row scripts/hooks/block-edit-live-settings.sh '$"..." name words' '~/.cl$"a"ude/x ' 500 2000 'echo ' '> /tmp/out.txt'
}

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
