#!/usr/bin/env bash
# test-console-wait.sh — HIMMEL-3509. Exercises console-wait.sh, the console's
# one event waiter: silent while nothing changes, exits with exactly one WAKE
# block on a Telegram inbox line or a confirmed change of the tick's action
# key. tick.sh and the bank verdict are stubbed (CONSOLE_WAIT_TICK /
# CONSOLE_WAIT_BANK), so no gh, lock or bank read happens here. bash 3.2-safe.
#
# CONSOLE_WAIT overrides the script under test (the RED control: today's
# Monitor-arm shape, which runs tick.sh on every arm, fails the idle cases).
#
# Run: bash scripts/handover/console-kit/test-console-wait.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CONSOLE_WAIT:-$HERE/console-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/console-wait-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB/tick.rc" ] && exit "$(cat "$STUB/tick.rc")"
# tick.sleep: a slow tick (seconds), as a real gh-bound tick can be.
[ -f "$STUB/tick.sleep" ] && sleep "$(cat "$STUB/tick.sleep")"
# tick.ignoreterm: a hung tick that ignores SIGTERM (timeout needs -k).
if [ -f "$STUB/tick.ignoreterm" ]; then trap '' TERM; sleep 20; exit 0; fi
# tick.failafter: prints its line, then fails (a tick that dies mid-run).
if [ -f "$STUB/tick.failafter" ]; then cat "$STUB/tick.line"; exit 1; fi
# tick.blip: served for exactly one sample, then gone.
if [ -f "$STUB/tick.blip" ]; then cat "$STUB/tick.blip"; rm -f "$STUB/tick.blip"; exit 0; fi
# tick.churn: every sample serves a new prs= value (a busy repo's PR set).
if [ -f "$STUB/tick.churn" ]; then
    n=$(( $(cat "$STUB/tick.churn") + 1 )); printf '%s\n' "$n" > "$STUB/tick.churn"
    sed "s/prs=[^ ]*/prs=#$n/" "$STUB/tick.line"; exit 0
fi
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/bank"
EOF
export STUB
export CONSOLE_WAIT_TICK="$STUB/tick.sh" CONSOLE_WAIT_BANK="$STUB/bank.sh"
export CONSOLE_WAIT_INTERVAL=1 CONSOLE_WAIT_POLL_SEC=0.2
# A failure streak wakes only in (f4); elsewhere a failed sample is just "not a change".
export CONSOLE_WAIT_FAIL_WAKE=1000

# tick_line <legs> <board> [hb] [prs]: a tick line whose action fields are set.
tick_line() {
    printf 'TICK 03:00 hb=%s legs=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=%s bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s\n' \
        "${3:-1m}" "$1" "${4:-#10}" "$2" > "$STUB/tick.line"
}
reset_stub() { rm -f "$STUB/tick.rc" "$STUB/tick.blip" "$STUB/tick.churn" "$STUB/tick.sleep" "$STUB/tick.failafter" "$STUB/tick.ignoreterm"; tick_line "N1:FRESH" "ok"; printf 'PROCEED\n' > "$STUB/bank"; }

# wait_hb <inbox>: block until the waiter has taken its baseline (heartbeat
# carries a key), at most ~5 s.
wait_hb() {
    n=0
    while [ "$n" -lt 50 ]; do
        grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}
# wait_exit <pid>: wait at most ~8 s for the waiter to exit; sets rc to its
# exit code or "running". Not a $(...) helper: `wait` must run in the shell
# that started the waiter.
wait_exit() {
    n=0
    while [ "$n" -lt 80 ]; do
        if ! kill -0 "$1" 2>/dev/null; then wait "$1"; rc=$?; return; fi
        sleep 0.1; n=$((n + 1))
    done
    rc=running
}
new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
start() { # <inbox> <outfile> [tick args...]
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}

# --- (a) idle: no event, no change -> no output, still waiting -------------
reset_stub
I="$(new_inbox a)"
timeout 4 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/a.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(a) an idle window with no event emits nothing" "" "$(cat "$WORK/a.out")"
check "(a) an idle waiter is still waiting when the window closes (rc 124)" "124" "$rc"
check "(a) the idle waiter wrote a heartbeat" "yes" "$(grep -q '^hb=[0-9]* pid=[0-9]* ' "$I.wait" && echo yes)"

# --- (a2) a re-arm on an unchanged state emits nothing either --------------
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/a2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(a2) a re-arm with nothing changed emits nothing" "" "$(cat "$WORK/a2.out")"
check "(a2) and is still waiting when the window closes (rc 124)" "124" "$rc"

# --- (b) a real change -> exactly one WAKE block, then exit 0 --------------
reset_stub
I="$(new_inbox b)"
start "$I" "$WORK/b.out" --legs "N1.md"
wait_hb "$I" || fail "(b) no baseline heartbeat"
tick_line "N1:FREE" "ok"
wait_exit "$WPID"
check "(b) a leg going FREE ends the wait with rc 0" "0" "$rc"
check "(b) the wake names the changed field" "WAKE tick changed=legs bank=PROCEED" "$(head -n1 "$WORK/b.out")"
check "(b) the wake carries the tick line" "yes" "$(sed -n 2p "$WORK/b.out" | grep -q '^TICK .*legs=N1:FREE' && echo yes)"  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(b) exactly one wake block (2 lines)" "2" "$(wc -l < "$WORK/b.out" | tr -d ' ')"
check "(b) the exit reason is logged" "yes" "$(grep -q 'exit=wake-tick' "$I.wait" && echo yes)"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/b2.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(b) the re-arm after the wake does not wake again for the same change" "" "$(cat "$WORK/b2.out")"
check "(b) the re-arm is still waiting when the window closes (rc 124)" "124" "$rc"

# --- (c) noise fields do not wake: hb, board age, prs unchanged ------------
reset_stub
tick_line "N1:FRESH" "STALE:5m" "1m"
I="$(new_inbox c)"
start "$I" "$WORK/c.out" --legs "N1.md"
wait_hb "$I" || fail "(c) no baseline heartbeat"
tick_line "N1:FRESH" "STALE:9m" "7m"
wait_exit "$WPID"
check "(c) a heartbeat or board-age change does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(c) a TERM is logged as the exit reason" "yes" "$(grep -q 'exit=signal-TERM' "$I.wait" && echo yes)"

# --- (d) a one-sample blip (a failed gh read) does not wake -----------------
reset_stub
I="$(new_inbox d)"
start "$I" "$WORK/d.out" --legs "N1.md"
wait_hb "$I" || fail "(d) no baseline heartbeat"
sed 's/prs=#10/prs=none/' "$STUB/tick.line" > "$STUB/tick.blip"
wait_exit "$WPID"
check "(d) a change seen on one sample only does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (d2) a key that changes on every sample still wakes -------------------
# Measured on the live repo (HIMMEL-3509): the open-PR set moved between every
# 180 s sample, so "the same new key twice" never held and the waiter stayed
# silent through real changes. Two consecutive samples off the saved key wake.
reset_stub
I="$(new_inbox d2)"
start "$I" "$WORK/d2.out" --legs "N1.md"
wait_hb "$I" || fail "(d2) no baseline heartbeat"
printf '0\n' > "$STUB/tick.churn"
wait_exit "$WPID"
check "(d2) a key that differs from the saved one on every sample wakes" "0" "$rc"
check "(d2) the wake names prs" "WAKE tick changed=prs bank=PROCEED" "$(head -n1 "$WORK/d2.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# --- (e) a bank verdict change wakes, naming bank --------------------------
reset_stub
I="$(new_inbox e)"
start "$I" "$WORK/e.out" --legs "N1.md"
wait_hb "$I" || fail "(e) no baseline heartbeat"
printf 'SKIPPED-BANK\n' > "$STUB/bank"
wait_exit "$WPID"
check "(e) a bank verdict change ends the wait" "0" "$rc"
check "(e) the wake names bank and carries the new verdict" "WAKE tick changed=bank bank=SKIPPED-BANK" "$(head -n1 "$WORK/e.out")"

# --- (f) a failing tick is never a change ----------------------------------
reset_stub
I="$(new_inbox f)"
start "$I" "$WORK/f.out" --legs "N1.md"
wait_hb "$I" || fail "(f) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
wait_exit "$WPID"
check "(f) a failing tick.sh does not wake" "running" "$rc"
check "(f) the heartbeat records the failed tick" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (f2) an empty bank read is a failed sample, never a change ------------
reset_stub
I="$(new_inbox f2)"
start "$I" "$WORK/f2.out" --legs "N1.md"
wait_hb "$I" || fail "(f2) no baseline heartbeat"
: > "$STUB/bank"
wait_exit "$WPID"
check "(f2) an empty bank read does not wake" "running" "$rc"
check "(f2) the heartbeat records the failed sample" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (f3) a bank read that is not a verdict token is a failed sample --------
reset_stub
I="$(new_inbox f3)"
start "$I" "$WORK/f3.out" --legs "N1.md"
wait_hb "$I" || fail "(f3) no baseline heartbeat"
printf 'Traceback: boom\n' > "$STUB/bank"
wait_exit "$WPID"
check "(f3) a non-token bank line does not wake" "running" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (f4) a failure streak wakes once; the re-arm stays quiet until a success -
reset_stub
I="$(new_inbox f4)"
CONSOLE_WAIT_FAIL_WAKE=3 start "$I" "$WORK/f4.out" --legs "N1.md"
wait_hb "$I" || fail "(f4) no baseline heartbeat"
printf '1\n' > "$STUB/tick.rc"
wait_exit "$WPID"
check "(f4) a streak of failed samples ends the wait" "0" "$rc"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
check "(f4) the wake names the failure streak" "WAKE tick-fail samples=3" "$(head -n1 "$WORK/f4.out")"
CONSOLE_WAIT_FAIL_WAKE=3 timeout 6 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/f4b.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(f4) the re-arm during the same streak runs silent" "124" "$rc"
check "(f4) the re-arm during the same streak prints nothing" "" "$(cat "$WORK/f4b.out")"
rm -f "$STUB/tick.rc"
CONSOLE_WAIT_FAIL_WAKE=3 timeout 3 bash "$WAIT" "$I" --legs "N1.md" >/dev/null 2>&1  # gnu-ok: Linux-only kit; pipefail-ok: none set
printf '1\n' > "$STUB/tick.rc"
CONSOLE_WAIT_FAIL_WAKE=3 timeout 8 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/f4c.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(f4) a new streak after a success wakes again" "WAKE tick-fail samples=3" "$(head -n1 "$WORK/f4c.out")"

# --- (g) a Telegram line wakes at once; a re-arm replays nothing -----------
reset_stub
I="$(new_inbox g)"
start "$I" "$WORK/g.out" --legs "N1.md"
wait_hb "$I" || fail "(g) no baseline heartbeat"
printf -- '- 03:10 [telegram from=1 chat=2] hello\n' >> "$I"
wait_exit "$WPID"
check "(g) an inbox line ends the wait with rc 0" "0" "$rc"
check "(g) the wake is a telegram block with the line" "$(printf 'WAKE telegram\n- 03:10 [telegram from=1 chat=2] hello')" "$(cat "$WORK/g.out")"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/g2.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(g) a re-arm does not replay a delivered line" "" "$(cat "$WORK/g2.out")"

# --- (h) a line queued while no waiter ran is delivered on arm -------------
printf -- '- 03:20 [telegram from=1 chat=2] queued\n' >> "$I"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/h.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(h) a line queued between arms is delivered by the next arm" "$(printf 'WAKE telegram\n- 03:20 [telegram from=1 chat=2] queued')" "$(cat "$WORK/h.out")"
check "(h) and the arm exits 0" "0" "$rc"

# --- (i) a second waiter on the same inbox is refused ----------------------
reset_stub
I="$(new_inbox i)"
start "$I" "$WORK/i.out" --legs "N1.md"
wait_hb "$I" || fail "(i) no baseline heartbeat"
bash "$WAIT" "$I" --legs "N1.md" > "$WORK/i2.out" 2>&1; rc=$?
check "(i) a second waiter on a live one is refused with rc 3" "3" "$rc"
check "(i) the refusal names the live pid" "yes" "$(grep -q "pid $WPID" "$WORK/i2.out" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (j) new tick args re-baseline silently --------------------------------
reset_stub
I="$(new_inbox j)"
timeout 2 bash "$WAIT" "$I" --legs "N1.md" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(j) the first arm ran until the timeout" "124" "$rc"
base1="$(cat "$I.wait.state" 2>/dev/null)"
tick_line "N1:FRESH,N2:FRESH" "ok"
timeout 3 bash "$WAIT" "$I" --legs "N1.md N2.md" > "$WORK/j.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(j) the re-arm ran until the timeout" "124" "$rc"
check "(j) a re-arm with a new leg set re-baselines instead of waking" "" "$(cat "$WORK/j.out")"
base2="$(cat "$I.wait.state" 2>/dev/null)"
if [ -n "$base1" ] && [ -n "$base2" ] && [ "$base1" != "$base2" ]; then pass "(j) the saved baseline moved to the new leg set"; else fail "(j) the saved baseline moved to the new leg set (was '$base1' now '$base2')"; fi

# --- (l) a tick that prints a line and then fails is never a change -------
reset_stub
I="$(new_inbox l)"
start "$I" "$WORK/l.out" --legs "N1.md"
wait_hb "$I" || fail "(l) no baseline heartbeat"
tick_line "N1:FREE" "ok"; : > "$STUB/tick.failafter"
sleep 3.5
check "(l) a failing tick's TICK line does not wake" "" "$(cat "$WORK/l.out")"
check "(l) the failing tick is recorded as tick=fail" "yes" "$(grep -q 'tick=fail' "$I.wait" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (m) the heartbeat exists before the first (slow) sample returns -------
reset_stub
printf '3\n' > "$STUB/tick.sleep"
I="$(new_inbox m)"
start "$I" "$WORK/m.out" --legs "N1.md"
sleep 1
check "(m) a waiter mid-sample already shows state=sampling" "yes" "$(grep -q 'state=sampling' "$I.wait" 2>/dev/null && echo yes)"
bash "$WAIT" "$I" --legs "N1.md" > "$WORK/m2.out" 2>&1; rc=$?
check "(m) a second waiter during the first sample is refused (rc 3)" "3" "$rc"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (n) a partial inbox line (no newline yet) does not wake ---------------
reset_stub
I="$(new_inbox n)"
start "$I" "$WORK/n.out" --legs "N1.md"
wait_hb "$I" || fail "(n) no baseline heartbeat"
printf -- '- 03:30 [telegram from=1 chat=2] half' >> "$I"
sleep 1
check "(n) a partial line does not wake" "" "$(cat "$WORK/n.out")"
printf ' done\n' >> "$I"
wait_exit "$WPID"
check "(n) completing the line wakes with it whole" "$(printf 'WAKE telegram\n- 03:30 [telegram from=1 chat=2] half done')" "$(cat "$WORK/n.out")"

# --- (o) a hung tick that ignores TERM still frees the Telegram path -------
reset_stub
: > "$STUB/tick.ignoreterm"
I="$(new_inbox o)"
CONSOLE_WAIT_TICK_TIMEOUT=1 start "$I" "$WORK/o.out" --legs "N1.md"
# The line lands after the TERM (1 s), while the first sample is still hung.
sleep 2
printf -- '- 03:40 [telegram from=1 chat=2] hello\n' >> "$I"
n=0
while [ "$n" -lt 150 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
check "(o) the line is delivered within 15 s despite a TERM-ignoring tick" "WAKE telegram" "$(head -n1 "$WORK/o.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (p) two waiters started at the same instant: exactly one runs ---------
reset_stub
I="$(new_inbox p)"
bash "$WAIT" "$I" --legs "N1.md" > "$WORK/p1.out" 2>&1 &
P1=$!
bash "$WAIT" "$I" --legs "N1.md" > "$WORK/p2.out" 2>&1 &
P2=$!
sleep 2
alive=0
kill -0 "$P1" 2>/dev/null && alive=$((alive + 1))
kill -0 "$P2" 2>/dev/null && alive=$((alive + 1))
check "(p) exactly one of two simultaneous waiters is still running" "1" "$alive"
kill "$P1" "$P2" 2>/dev/null; wait "$P1" "$P2" 2>/dev/null

# --- (q) a first start with no consoles/ directory yet still arms -----------
reset_stub
I="$WORK/q/consoles/c.md"
start "$I" "$WORK/q.out" --legs "N1.md"
wait_hb "$I" || fail "(q) no baseline heartbeat when consoles/ was absent"
check "(q) the waiter created the inbox" "yes" "$([ -f "$I" ] && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (r) a tick line missing an action field is a failed sample, never a
# key with an empty value baked in: it counts toward the fail streak, not a
# changed-key wake, even across two consecutive malformed samples -----------
reset_stub
I="$(new_inbox r)"
CONSOLE_WAIT_FAIL_WAKE=2 start "$I" "$WORK/r.out" --legs "N1.md"
wait_hb "$I" || fail "(r) no baseline heartbeat"
sed 's/ tails=N1:LIVE//' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
wait_exit "$WPID"
check "(r) a streak of malformed samples ends the wait" "0" "$rc"
check "(r) the wake is tick-fail, never a changed key from an empty field" "WAKE tick-fail samples=2" "$(head -n1 "$WORK/r.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# --- (s) .wait.state is written atomically (temp file + rename), never with
# an in-place '>' redirect that could leave a torn key file on a kill -------
# shellcheck disable=SC2016 # literal grep pattern, not a shell expansion
check "(s) no in-place '> \"\$key_file\"' write remains (must go through .tmp + mv)" "0" \
    "$(grep -cF '> "$key_file"' "$HERE/console-wait.sh")"

# --- (t) a board class move to ok never wakes on its own; the saved key
# still moves to board=ok, so a later move to STALE wakes again (HIMMEL-3521) -
reset_stub
tick_line "N1:FRESH" "STALE:5m"
I="$(new_inbox t)"
start "$I" "$WORK/t.out" --legs "N1.md"
wait_hb "$I" || fail "(t) no baseline heartbeat"
tick_line "N1:FRESH" "ok"
wait_exit "$WPID"
check "(t) a board move to ok alone does not wake" "running" "$rc"
check "(t) the saved key still moved to board=ok" "yes" "$(grep -q 'board=ok' "$I.wait.state" && echo yes)"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

# --- (u) a board class move to STALE wakes, naming board -------------------
reset_stub
I="$(new_inbox u)"
start "$I" "$WORK/u.out" --legs "N1.md"
wait_hb "$I" || fail "(u) no baseline heartbeat"
tick_line "N1:FRESH" "STALE:3m"
wait_exit "$WPID"
check "(u) a board move to STALE ends the wait" "0" "$rc"
check "(u) the wake names board" "WAKE tick changed=board bank=PROCEED" "$(head -n1 "$WORK/u.out")"

# --- (v) board STALE-to-ok combined with a prs change still wakes, naming
# only the real field ---------------------------------------------------------
reset_stub
tick_line "N1:FRESH" "STALE:5m"
I="$(new_inbox v)"
start "$I" "$WORK/v.out" --legs "N1.md"
wait_hb "$I" || fail "(v) no baseline heartbeat"
tick_line "N1:FRESH" "ok" "1m" "#99"
wait_exit "$WPID"
check "(v) board-to-ok combined with a prs change still wakes" "0" "$rc"
check "(v) the wake names only prs, not board" "WAKE tick changed=prs bank=PROCEED" "$(head -n1 "$WORK/v.out")"

# --- (k) usage ---------------------------------------------------------------
bash "$WAIT" >/dev/null 2>&1; rc=$?
check "(k) no inbox argument is a usage error (rc 2)" "2" "$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
