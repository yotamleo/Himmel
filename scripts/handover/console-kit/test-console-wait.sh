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

# tick_line <legs> <board> [hb] [prs]: a tick line whose action fields are set.
tick_line() {
    printf 'TICK 03:00 hb=%s legs=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=%s bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s\n' \
        "${3:-1m}" "$1" "${4:-#10}" "$2" > "$STUB/tick.line"
}
reset_stub() { rm -f "$STUB/tick.rc" "$STUB/tick.blip" "$STUB/tick.churn";tick_line "N1:FRESH" "ok"; printf 'PROCEED\n' > "$STUB/bank"; }

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
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/a2.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(a2) a re-arm with nothing changed emits nothing" "" "$(cat "$WORK/a2.out")"

# --- (b) a real change -> exactly one WAKE block, then exit 0 --------------
reset_stub
I="$(new_inbox b)"
start "$I" "$WORK/b.out" --legs "N1.md"
wait_hb "$I" || fail "(b) no baseline heartbeat"
tick_line "N1:FREE" "ok"
wait_exit "$WPID"
check "(b) a leg going FREE ends the wait with rc 0" "0" "$rc"
check "(b) the wake names the changed field" "WAKE tick changed=legs" "$(head -n1 "$WORK/b.out")"
check "(b) the wake carries the tick line" "yes" "$(sed -n 2p "$WORK/b.out" | grep -q '^TICK .*legs=N1:FREE' && echo yes)"  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(b) exactly one wake block (2 lines)" "2" "$(wc -l < "$WORK/b.out" | tr -d ' ')"
check "(b) the exit reason is logged" "yes" "$(grep -q 'exit=wake-tick' "$I.wait" && echo yes)"
timeout 3 bash "$WAIT" "$I" --legs "N1.md" > "$WORK/b2.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(b) the re-arm after the wake does not wake again for the same change" "" "$(cat "$WORK/b2.out")"

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
check "(d2) the wake names prs" "WAKE tick changed=prs" "$(head -n1 "$WORK/d2.out")"
[ "$rc" = running ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# --- (e) a bank verdict change wakes, naming bank --------------------------
reset_stub
I="$(new_inbox e)"
start "$I" "$WORK/e.out" --legs "N1.md"
wait_hb "$I" || fail "(e) no baseline heartbeat"
printf 'SKIPPED-BANK\n' > "$STUB/bank"
wait_exit "$WPID"
check "(e) a bank verdict change ends the wait" "0" "$rc"
check "(e) the wake names bank" "WAKE tick changed=bank" "$(head -n1 "$WORK/e.out")"

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
timeout 2 bash "$WAIT" "$I" --legs "N1.md" >/dev/null 2>&1  # gnu-ok: Linux-only kit; pipefail-ok: none set
tick_line "N1:FRESH,N2:FRESH" "ok"
timeout 3 bash "$WAIT" "$I" --legs "N1.md N2.md" > "$WORK/j.out" 2>/dev/null  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(j) a re-arm with a new leg set re-baselines instead of waking" "" "$(cat "$WORK/j.out")"

# --- (k) usage ---------------------------------------------------------------
bash "$WAIT" >/dev/null 2>&1; rc=$?
check "(k) no inbox argument is a usage error (rc 2)" "2" "$rc"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
