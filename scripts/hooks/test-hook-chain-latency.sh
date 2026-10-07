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
# Budgets are LOADED figures x2 (the run-shell-tests.sh rule), measured on the
# station at load average ~8 with parallel suites; see the HIMMEL-4678 PR. Env
# overrides exist for slower boxes, never to make a red go green.
#
# Exit codes: 0 all cases passed, 1 at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
SETTINGS="$ROOT/.claude/settings.json"

SCALE_MAX=${HOOK_LATENCY_SCALE_MAX:-6}
P95_BUDGET_MS=${HOOK_LATENCY_P95_BUDGET_MS:-1500}
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
UTF8_LOCALE=''
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qx "$l"; then UTF8_LOCALE=$l; break; fi
done
[ -n "$UTF8_LOCALE" ] || UTF8_LOCALE=C.UTF-8

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/hook-latency.XXXXXX") || { echo "FAIL fixture: mktemp"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home"

MEMBERS=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$SETTINGS" \
    | grep -o -E 'scripts/hooks/[A-Za-z0-9_-]+\.sh' | awk '!seen[$0]++')
[ -n "$MEMBERS" ] || { echo "FAIL fixture: no Bash PreToolUse members in $SETTINGS"; exit 1; }

payload() {  # payload <command> <file>
    jq -n --arg c "$1" --arg cwd "$SANDBOX" \
        '{tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd, session_id: "hook-latency"}' > "$2"
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
payload "$(prose 40)" "$SANDBOX/small.json"
payload "$(prose 160)" "$SANDBOX/big.json"

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
# The role flags switch on the members gated to a leg or a relay session
# (read-clamp.sh, guard-relay-writes.sh), so their real path is timed rather
# than their first-line exit.
run_ms() {  # run_ms <member> <payload file> -- wall ms into MS
    local t0 t1
    t0=${EPOCHREALTIME//[!0-9]/}
    env -i PATH="$PATH" HOME="$SANDBOX/home" TMPDIR="${TMPDIR:-/tmp}" \
        LANG="$UTF8_LOCALE" LC_ALL="$UTF8_LOCALE" CLAUDE_PROJECT_DIR="$ROOT" \
        HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_RELAY=1 \
        bash "$ROOT/$1" < "$2" > /dev/null 2>&1
    t1=${EPOCHREALTIME//[!0-9]/}
    MS=$(( (t1 - t0) / 1000 ))
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
    min_ms "$m" "$SANDBOX/small.json"; small=$MS
    min_ms "$m" "$SANDBOX/big.json"; big=$MS
    # +50ms of slack so a member that costs nothing at either size cannot fail
    # on scheduler noise alone.
    if [ "$big" -le $(( SCALE_MAX * small + 50 )) ]; then
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
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
