#!/usr/bin/env bash
# test-check-ci-forks-probe.sh -- HIMMEL-2169 gh-fork profiling probe for
# scripts/test-check-ci.sh.
#
# WHY THIS EXISTS: test-check-ci.sh runs ~110 cases / 244 assertions in
# ~624s fresh (~5.7s/case, vs ~1.3s/case on comparable suites). The suspected
# driver is the NUMBER of gh-stub subprocess forks inside check-ci.sh's own
# retry/poll/pagination loops, not fixture setup (already amortized across 3
# shared ledger repos). This probe MEASURES that per case; it does not fix
# anything (no optimization here -- that is a follow-up ticket, evidence-led).
#
# HOW: an instrumented COPY of the suite is built at runtime (the suite file
# itself is never modified). The suite's own run() already truncates
# $STUBDIR/args.log at the top of every case and the gh stub already appends
# one line per invocation to it (`echo "$*" >> "$GH_STUB_ARGS"`) -- so the
# probe does not need its own gh-stub counter, it just reads what the suite
# already produces. Two exact, unique anchor lines inside run() get one
# appended line each via sed:
#   - right after run() resets its per-case state (`: > "$STUBDIR/claims"`):
#     start a nanosecond timer.
#   - right after the case's own `RC=$?`: stop the timer, snapshot
#     args.log's line count (= gh forks for THIS case, since it was just
#     reset), and append both plus a copy of args.log's lines (case-tagged)
#     to two probe log files.
# A separate static pass over the UNMODIFIED suite source maps each case
# (in source/call order, same order run() is invoked at runtime) to its
# nearest preceding "# <id> — " case-label comment, so the runtime log can be
# joined back to case ids without teaching the instrumentation about labels.
#
# Exit: 0 on a completed run (measurement tool, not an assertion suite -- the
# suite's own PASS/FAIL is echoed but does not fail this probe); 1 on a setup
# error (missing suite, anchor lines not found -- suite edited out from under
# this probe).
#
# Usage: bash scripts/test-check-ci-forks-probe.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$SCRIPT_DIR/test-check-ci.sh"
[ -r "$SUITE" ] || { echo "FATAL: cannot read $SUITE" >&2; exit 1; }

# shellcheck disable=SC2016  # literal text to grep for, not a shell expansion
TIMER_ANCHOR='    : > "$STUBDIR/claims"'
RC_ANCHOR='    RC=$?'
grep -qF "$TIMER_ANCHOR" "$SUITE" || { echo "FATAL: timer anchor not found in $SUITE (suite edited?)" >&2; exit 1; }
grep -qF "$RC_ANCHOR" "$SUITE" || { echo "FATAL: RC anchor not found in $SUITE (suite edited?)" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/checkci-forks-probe.XXXXXX") || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# --- 1. static pass: call order -> nearest preceding "# <id> — " label -----
LABELS="$WORK/labels.txt"
awk '
    /^# [0-9]+[A-Za-z0-9]* — / {
        line = $0; sub(/^# /, "", line); sub(/ — .*/, "", line); label = line
    }
    /^(run |run_in_repo )/ { print (label == "" ? "unlabeled" : label) }
' "$SUITE" > "$LABELS"

# --- 2. instrumented copy -----------------------------------------------
export PROBE_LOG="$WORK/timing.tsv"
export PROBE_ARGS_LOG="$WORK/args.tsv"
: > "$PROBE_LOG"
: > "$PROBE_ARGS_LOG"

SEDSCRIPT="$WORK/inject.sed"
cat > "$SEDSCRIPT" <<'SEDEOF'
/^    : > "\$STUBDIR\/claims"$/a\
    _probe_t0=$(date +%s%N)
/^    RC=\$?$/a\
    _probe_t1=$(date +%s%N); _probe_ms=$(( (_probe_t1 - _probe_t0) / 1000000 )); _probe_forks=$(grep -c . "$STUBDIR/args.log" 2>/dev/null); _probe_forks=${_probe_forks:-0}; printf '%s\t%s\t%s\t%s\n' "$COUNT" "$mode" "$_probe_forks" "$_probe_ms" >> "$PROBE_LOG"; sed "s/^/$COUNT\t$mode\t/" "$STUBDIR/args.log" >> "$PROBE_ARGS_LOG"
SEDEOF

SPLICED="$WORK/spliced.sh"
sed -f "$SEDSCRIPT" "$SUITE" > "$WORK/spliced-pre.sh"
# The suite derives SCRIPT_DIR/SCRIPT from its OWN location (bare
# `dirname "${BASH_SOURCE[0]}"`); this splice runs out of a temp dir, where
# that resolves to a check-ci.sh that does not exist and every case fails
# rc 127 before gh is ever invoked (same fix as probe-check-ci-escalate.sh).
# Re-point right after the suite's own assignment -- later wins.
awk -v d="$SCRIPT_DIR" -v s="$SCRIPT_DIR/check-ci.sh" '
    { print }
    $0 == "SCRIPT=\"$SCRIPT_DIR/check-ci.sh\"" {
        print "SCRIPT_DIR=\"" d "\""
        print "SCRIPT=\"" s "\""
    }
' "$WORK/spliced-pre.sh" > "$SPLICED"

echo "== test-check-ci-forks-probe: running the full instrumented suite (this takes several minutes) =="
T0=$(date +%s)
bash "$SPLICED" > "$WORK/suite.out" 2>&1
SUITE_RC=$?
T1=$(date +%s)
echo "== suite finished: rc=$SUITE_RC, wall=$((T1 - T0))s =="
tail -3 "$WORK/suite.out"
if [ "$SUITE_RC" -ne 0 ]; then
    echo "-- suite FAIL/TIMEOUT lines (probe is measurement-only; this does not fail the probe) --"
    grep -E '^  (FAIL|TIMEOUT):' "$WORK/suite.out" || echo "  (rc!=0 but no FAIL/TIMEOUT line matched -- inspect suite.out manually)"
fi

N_LABELS=$(wc -l < "$LABELS" | tr -d ' ')
N_TIMING=$(wc -l < "$PROBE_LOG" | tr -d ' ')
if [ "$N_LABELS" != "$N_TIMING" ]; then
    echo "WARN: label count ($N_LABELS) != timed-case count ($N_TIMING) -- report below is misaligned; suite structure likely changed since this probe was written" >&2
fi

# --- 3. report -------------------------------------------------------------
JOINED="$WORK/joined.tsv"
# label \t COUNT \t mode \t forks \t ms \t family
paste "$LABELS" "$PROBE_LOG" | awk -F'\t' '
    { family = $1; gsub(/[^0-9].*$/, "", family); print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"family }
' > "$JOINED"

echo
echo "=== per-case table (label, count, mode, gh-forks, wall-ms) ==="
awk -F'\t' '{ printf "%-8s case#%-4s %-24s forks=%-4s ms=%s\n", $1, $2, $3, $4, $5 }' "$JOINED"

echo
echo "=== per-family aggregation (sorted by total gh-forks desc) ==="
printf '%-8s %6s %10s %10s %10s %10s\n' family cases tot_forks avg_forks tot_ms avg_ms
awk -F'\t' '
    { n[$6]++; forks[$6]+=$4; ms[$6]+=$5 }
    END {
        for (f in n) printf "%-8s %6d %10d %10.1f %10d %10.1f\n", f, n[f], forks[f], forks[f]/n[f], ms[f], ms[f]/n[f]
    }
' "$JOINED" | sort -k3,3 -rn

echo
echo "=== top 10 offenders by gh-forks, with dominant argv pattern ==="
TOP="$WORK/top10.tsv"
sort -t$'\t' -k4,4 -rn "$JOINED" | head -10 > "$TOP"
# shellcheck disable=SC2034  # family: read for column alignment, not used here
while IFS=$'\t' read -r label count mode forks ms family; do
    dominant=$(awk -F'\t' -v c="$count" '
        $1 == c {
            line = $0
            if (line ~ /checks.*--watch/) print "watch/poll"
            else if (line ~ /checks/) print "probe(register)"
            else if (line ~ /graphql/) print "pagination(threads)"
            else if (line ~ /pr view/) print "view(status/review)"
            else if (line ~ / -X /) print "post(escalate/comment)"
            else print "other"
        }
    ' "$PROBE_ARGS_LOG" | sort | uniq -c | sort -rn | head -1)
    printf '  %-8s case#%-4s %-24s forks=%-4s ms=%-6s dominant=%s\n' "$label" "$count" "$mode" "$forks" "$ms" "${dominant:-(no gh calls)}"
done < "$TOP"

echo
echo "Full per-case table: $JOINED (probe workdir is cleaned up on exit -- redirect this script's stdout to keep it)"
exit 0
