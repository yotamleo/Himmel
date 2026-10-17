#!/usr/bin/env bash
# scripts/handover/console-kit/test-leg-event.sh - suite for leg-event.sh, the
# marker router that sends a leg's MERGED / WRAPPED message to wrap-merged.sh
# and escalates everything else. Hermetic: wrap-merged.sh and the manifest
# listing are stubs (the LE_WRAP / LE_LIST seams).
#
# Cases:
#   1. usage: missing --doc / --fleet / message              -> rc 2
#   2. MERGED #<pr> N<k>: wrap-merged gets --doc --fleet <leg doc> --pr <pr> -> HANDLED, rc 0
#   3. WRAPPED N<k> with no PR: no --pr passed               -> HANDLED, rc 0
#   4. READY / FINDING / unknown marker                      -> ESCALATE, rc 10, wrap-merged not run
#   5. no leg label in the message                           -> ESCALATE, rc 10
#   6. label not in the manifest                             -> ESCALATE, rc 10
#   7. wrap-merged fails (rc 3)                              -> ESCALATE naming rc=3, rc 10
#   8. message on stdin ("-") and a leading "- " bullet marker
#   12. a WRAPPED message that mentions deferred / follow-up / residual with no key -> ESCALATE
#
# Platform guard: Linux bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/leg-event.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/le-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

cat > "$W/wrap" <<'EOF'
#!/usr/bin/env bash
echo "wrap $*" >> "$LE_CALLS"
[ -z "${LE_WRAP_ERR:-}" ] || echo "$LE_WRAP_ERR" >&2
exit "${LE_WRAP_RC:-0}"
EOF
cat > "$W/list" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' /h/HIMMEL-1-N2078-foo-2026-10-14.md /h/HIMMEL-2-N2088-bar-2026-10-14.md /h/HIMMEL-3-qux-2026-10-14.md
EOF
cat > "$W/live" <<'EOF2'
#!/usr/bin/env bash
echo "live $*" >> "$LE_LIVE_CALLS"
[ -z "${LE_LIVE_ERR:-}" ] || echo "$LE_LIVE_ERR" >&2
exit "${LE_LIVE_RC:-0}"
EOF2
chmod +x "$W/wrap" "$W/list" "$W/live"
export LE_STATION_LOG="$W/station.log" LE_WRAP="$W/wrap" LE_LIST="$W/list" LE_STATION="$W/station" LE_CALLS="$W/calls" LE_LIVE="$W/live" LE_LIVE_CALLS="$W/live-calls"
: > "$W/doc"
run() { : > "$LE_CALLS"; : > "$LE_LIVE_CALLS"; printf '%s\n' "$1" > "$W/msg"; out="$(bash "$SCRIPT" --doc "$W/doc" --fleet "$W/fleet.json" "$W/msg" 2>/dev/null)"; rc=$?; calls="$(cat "$LE_CALLS")"; }

bash "$SCRIPT" >/dev/null 2>&1; check "1 no args rc" "$?" 2
bash "$SCRIPT" --doc "$W/doc" "$W/msg" >/dev/null 2>&1; check "1 no fleet rc" "$?" 2

run "MERGED #2566 → abcdef01 (N2088)"
check "2 rc" "$rc" 0
contains "2 stdout" "$out" "HANDLED wrap-merged N2088"
contains "2 wrap args" "$calls" "wrap --doc $W/doc --fleet $W/fleet.json /h/HIMMEL-2-N2088-bar-2026-10-14.md --pr 2566"

run "WRAPPED N2078. Lock released."
check "3 rc" "$rc" 0
contains "3 leg doc" "$calls" "/h/HIMMEL-1-N2078-foo-2026-10-14.md"
lacks "3 no --pr" "$calls" "--pr"

# a leg message that leads with its label and ticket key still routes
run "N2088 HIMMEL-2 MERGED #2566 → abcdef01 WRAPPED: lock released"
check "3b label-first rc" "$rc" 0
contains "3b label-first args" "$calls" "--pr 2566"

for m in "READY 2553 0780b95dcad44fe293c7798066626cd52bb2dce N2088" "FINDING N2088 (token x): q" "PUSHED abc N2088"; do
    run "$m"
    check "4 rc [$m]" "$rc" 10
    contains "4 escalate [$m]" "$out" "ESCALATE"
    check "4 wrap not run [$m]" "$calls" ""
done

run "WRAPPED. All done."
check "5 rc" "$rc" 10
contains "5 reason" "$out" "no-label"

run "WRAPPED N9999"
check "6 rc" "$rc" 10
contains "6 reason" "$out" "not-in-manifest"
check "6 wrap not run" "$calls" ""

run "WRAPPED N2078 after N2088 merged"
check "6b two labels rc" "$rc" 10
contains "6b reason" "$out" "ambiguous-label"
check "6b wrap not run" "$calls" ""

run "WRAPPED N2078 (N2078 again)"
check "6c same label twice rc" "$rc" 0

LE_WRAP_RC=3 LE_WRAP_ERR="wrap-merged: step pr-state failed: PR #2566 is 'OPEN'" run "MERGED #2566 N2088"
check "7 rc" "$rc" 10
contains "7 escalate rc" "$out" "ESCALATE wrap-merged-failed rc=3"
contains "7 step surfaced" "$out" "step pr-state failed"

printf -- '- MERGED #2566 N2088\n' | bash "$SCRIPT" --doc "$W/doc" --fleet "$W/fleet.json" - >"$W/o" 2>&1; rc=$?
check "8 stdin bullet rc" "$rc" 0
contains "8 handled" "$(cat "$W/o")" "HANDLED wrap-merged N2088"

# 12. the station sync after a MERGED
cat > "$W/station" <<'EOF'
#!/usr/bin/env bash
echo "station $*" >> "$LE_CALLS"
echo "STEP marketplace rc=0"
echo "STATION=${LE_STATION_VAL:-OK}"
exit "${LE_STATION_RC:-0}"
EOF
chmod +x "$W/station"

# The sync runs detached (its --versions fetches and rebuilds are unbounded): the
# line comes back at once with station=pending, the sync's output lands in the log
# and its verdict in the state file tick.sh reads.
export LE_STATION_LOG="$W/station.log"
await() { local i=0; while [ "$i" -lt 50 ]; do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

: > "$LE_STATION_LOG"
run "MERGED #2566 → abcdef01 (N2088)"
await "$LE_CALLS" "station --pr 2566"; check "12 station sync gets the PR" "$?" 0
contains "12 line says pending and names the log" "$out" "HANDLED wrap-merged N2088 station=pending log=$LE_STATION_LOG"
await "$LE_STATION_LOG" "STATION=OK"; check "12 sync output lands in the log" "$?" 0

cat > "$W/station-ld" <<'EOF'
#!/usr/bin/env bash
echo "LOCAL-DIFF luna_template scripts/foo.sh: echo local-patch"
echo "STATION=BEHIND:luna_template"
EOF
chmod +x "$W/station-ld"
: > "$LE_STATION_LOG"
LE_STATION="$W/station-ld" run "MERGED #2566 N2088"
await "$LE_STATION_LOG" "LOCAL-DIFF luna_template scripts/foo.sh: echo local-patch"; check "12 local-diff hunk reaches the log" "$?" 0

cat > "$W/station-hang" <<'EOF'
#!/usr/bin/env bash
sleep 6
EOF
chmod +x "$W/station-hang"
t0=$SECONDS
LE_STATION="$W/station-hang" run "MERGED #2566 N2088"
check "12 a hanging sync does not delay the handling" "$(( SECONDS - t0 < 4 ))" 1
check "12 hanging sync handled rc" "$rc" 0
contains "12 hanging sync still prints HANDLED" "$out" "HANDLED wrap-merged N2088 station=pending"
pkill -f "$W/station-hang" 2>/dev/null || true

run "WRAPPED N2078"
lacks "12 WRAPPED runs no station sync" "$calls" "station"

LE_WRAP_RC=3 run "MERGED #2566 N2088"
lacks "12 failed wrap runs no station sync" "$calls" "station"

# 9. the leg named only by its session name (the leg doc's stem) routes
run "WRAPPED HIMMEL-2-N2088-bar-2026-10-14 lock released"
check "9 session-name rc" "$rc" 0
contains "9 session-name leg doc" "$calls" "/h/HIMMEL-2-N2088-bar-2026-10-14.md"
run "WRAPPED HIMMEL-1-N2078-foo-2026-10-14 and HIMMEL-2-N2088-bar-2026-10-14"
check "9b two sessions rc" "$rc" 10
run "WRAPPED HIMMEL-3-qux-2026-10-14 lock released"
check "9d label-less session rc" "$rc" 0
contains "9d label-less session leg doc" "$calls" "/h/HIMMEL-3-qux-2026-10-14.md"
run "WRAPPED HIMMEL-3-qux-2026-10-14-retry lock released"
contains "9e longer unlisted session does not match a listed stem" "$out" "ESCALATE no-label"
run "WRAPPED HIMMEL-9-nobody-2026-10-14"
contains "9c unknown session still no-label" "$out" "ESCALATE no-label"

# 10. a handled event re-renders the legs line; an escalated one does not
run "WRAPPED N2078"
contains "10 live-state ran" "$(cat "$LE_LIVE_CALLS")" "live $W/doc"
run "READY 1 abc N2078"
check "10b no live-state on escalate" "$(cat "$LE_LIVE_CALLS")" ""
LE_WRAP_RC=3 run "WRAPPED N2078"
check "10c no live-state when wrap failed" "$(cat "$LE_LIVE_CALLS")" ""
LE_LIVE_RC=1 LE_LIVE_ERR="live-state: boom" run "WRAPPED N2078"
check "10d live-state failure rc" "$rc" 0
contains "10d live-state failure surfaced" "$out" "live-state=failed"

# 11. end to end with the real live-state.sh: the wrapped leg leaves the legs line
cat > "$W/c.md" <<'EOF2'
# console

## Live state
legs: `N2078:nonce1:tok:11`
tick: x
EOF2
printf '{"legs":[]}\n' > "$W/c.fleet.json"
printf 'WRAPPED N2078\n' > "$W/msg"
out="$(LE_LIVE='' bash "$SCRIPT" --doc "$W/c.md" --fleet "$W/c.fleet.json" "$W/msg" 2>/dev/null)"; rc=$?
check "11 rc" "$rc" 0
lacks "11 legs line drops the wrapped leg" "$(cat "$W/c.md")" "N2078:"
contains "11 legs line is none" "$(cat "$W/c.md")" "legs: none"

# 12. a WRAPPED message that mentions deferred / follow-up / residual must name a ticket
run "WRAPPED N2078. Deferred: the retry path."
check "12a unkeyed deferred rc" "$rc" 10
contains "12a escalate reason" "$out" "ESCALATE unfiled-residual"
contains "12a names the line" "$out" "Deferred: the retry path."
check "12a wrap not run" "$calls" ""
run "$(printf 'WRAPPED N2078\n- follow-up: tighten the regex\n')"
check "12b unkeyed follow-up on a later line rc" "$rc" 10
run "WRAPPED N2078. Residual risk left for later."
check "12c unkeyed residual rc" "$rc" 10
run "WRAPPED N2078. Follow-up filed as HIMMEL-6200."
check "12d keyed follow-up rc" "$rc" 0
run "WRAPPED N2078. Deferred the retry path, no-ticket: operator accepted."
check "12e no-ticket reason rc" "$rc" 0
run "WRAPPED N2078. Deferred the retry path, no-ticket:"
check "12f empty no-ticket reason rc" "$rc" 10
run "WRAPPED N2078. No residuals, nothing deferred."
check "12g a negated mention rc" "$rc" 0
run "WRAPPED N2078. No residuals; follow-up: fix the retry path"
check "12g2 a negated mention does not hide an affirmative one on the same line rc" "$rc" 10
run "WRAPPED N2078. No residuals or follow-ups."
check "12g3 a coordinated negation rc" "$rc" 0
run "WRAPPED N2078 without fixing residuals"
check "12g4 an intervening non-modifier word is not a negation rc" "$rc" 10
run "WRAPPED N2078. No further follow-ups."
check "12g5 a modifier between the negator and the mention rc" "$rc" 0
run "WRAPPED N2078. Lock released."
check "12h a plain wrap rc" "$rc" 0
run "MERGED #2566 → abcdef01 N2088. Follow-up: x"
check "12i MERGED is not checked here rc" "$rc" 0

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
