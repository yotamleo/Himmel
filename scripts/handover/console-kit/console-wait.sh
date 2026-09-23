#!/usr/bin/env bash
# console-wait.sh — HIMMEL-3509. The console's one event waiter.
#
#   console-wait.sh <inbox-file> [tick.sh args...]
#
# A console used to arm two `Monitor` loops (the Telegram inbox follower and
# tick.sh). The Monitor tool caps an arm at 30 min, so every expiry woke a
# full-context console turn only to re-arm. This replaces both: the console
# runs it ONCE with Bash `run_in_background`, which has no such cap and
# re-invokes the session when the command exits. It stays silent while nothing
# happens and exits, printing one WAKE block, on the first real event:
#
#   WAKE telegram               unread lines in <inbox-file> (the bridge's
#   <line>...                   `/console <name>` appends), via inbox-follow.sh
#                               --once, so its byte cursor is shared and a
#                               re-arm replays nothing.
#   WAKE tick changed=<f,...>   the tick's ACTION KEY changed and the change
#     bank=<verdict>            held for two consecutive samples; bank= is the
#   TICK ...                    bank-preflight verdict word the key carries.
#   WAKE tick-fail samples=<n>  CONSOLE_WAIT_FAIL_WAKE consecutive samples
#                               failed (tick or bank read): the monitor is
#                               broken. Once per streak; the re-arm stays quiet
#                               until a sample succeeds.
#
# The action key is the tick fields a console acts on: legs=, livestate=,
# prs=, tails=, legset=, board= (its class; the STALE age is dropped) and the
# bank-preflight verdict word. Everything else on the tick line (heartbeat,
# procs, fill, fleet, gql, orphans...) moves without needing a console act and
# never wakes. Two consecutive samples must differ from the saved key (not
# necessarily from each other), so one failed `gh` read (prs=none for a single
# tick) is not an event. The first sample with no saved
# key, or with a saved key taken under different tick args (a re-arm after a
# dispatch or wrap), is a silent baseline. A tick.sh that exits non-zero or
# prints no TICK line, or a bank read that fails or is not a verdict token, is
# a failed sample: never a change, and only a streak of them wakes.
#
# Files next to the inbox:
#   <inbox>.wait       heartbeat, rewritten every poll:
#                      `hb=<epoch> pid=<pid> key=<sha16> tick=<ok|fail|-> state=waiting`,
#                      `state=sampling` while a tick runs, then on every
#                      catchable exit `... state=exited exit=<reason>`.
#                      A sample (tick, then bank) can take up to twice
#                      CONSOLE_WAIT_TICK_TIMEOUT (+5 s kill grace each), and a
#                      Telegram line waits for it. A heartbeat older than that
#                      plus a few polls, still
#                      waiting or sampling, is a waiter that died without
#                      trapping (SIGKILL).
#   <inbox>.wait.state   the saved action key (line 1: tick-args hash, line 2: key;
#                        line 3 `failwoke` once a failure streak has woken).
#                        Written atomically: temp file in the same dir, then
#                        `mv`, so a kill mid-write never leaves it torn.
#   <inbox>.wait.lock    the one-waiter flock (the file stays; the lock does not).
#
# Exit: 0 = a WAKE block was printed; 1 = the inbox could not be drained;
# 2 = usage; 3 = another waiter is already live on this inbox (its pid is named).
#
# Env: CONSOLE_WAIT_INTERVAL tick interval in seconds (default 180);
# CONSOLE_WAIT_POLL_SEC inbox poll (default 1); CONSOLE_WAIT_TICK_TIMEOUT
# seconds a tick may run before it counts as failed (default 120), so a hung
# tick cannot freeze the Telegram path; CONSOLE_WAIT_FAIL_WAKE consecutive
# failed samples before a tick-fail wake (default 3); CONSOLE_WAIT_TICK / CONSOLE_WAIT_BANK
# replace tick.sh / the bank verdict command (tests).
#
# Leg messages (SendMessage) wake a console on their own; only the Telegram
# and tick paths depend on this waiter.
#
# ponytail: an external SIGKILL of the waiter re-invokes the session (task
# notification, measured HIMMEL-3509); the harness-internal "low memory" kill
# of a background task (HIMMEL-3097) is unreproduced, so a waiter lost that way
# is visible only as a stale heartbeat, upgrade: HIMMEL-3510 (bridge-side
# stale-heartbeat alert).
#
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only.
# bash 3.2-safe.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    echo "usage: console-wait.sh <inbox-file> [tick.sh args...]" >&2
    exit 2
fi
inbox="$1"; shift
hb_file="$inbox.wait"
key_file="$inbox.wait.state"
interval="${CONSOLE_WAIT_INTERVAL:-180}"
poll="${CONSOLE_WAIT_POLL_SEC:-1}"
tick_timeout="${CONSOLE_WAIT_TICK_TIMEOUT:-120}"
tick_cmd="${CONSOLE_WAIT_TICK:-$HERE/tick.sh}"

# One waiter per inbox: a second would double every wake. flock is atomic and
# the lock dies with the waiter; every child runs with fd 9 closed, so a killed
# waiter's tick or sleep cannot go on holding it. The inbox's directory may not
# exist yet on a first start; inbox-follow.sh creates the inbox itself.
if ! mkdir -p "$(dirname "$inbox")" || ! exec 9>>"$inbox.wait.lock"; then
    echo "console-wait: cannot open $inbox.wait.lock" >&2
    exit 1
fi
if ! flock -n 9; then  # gnu-ok: Linux-only kit (util-linux flock, PLATFORM GUARD)
    other="$(sed -n 's/.* pid=\([0-9][0-9]*\) .*/\1/p' "$hb_file" 2>/dev/null | head -n 1)"
    echo "console-wait: a waiter is already live on $inbox (pid ${other:-?}) — not starting a second" >&2
    exit 3
fi

cur_hash=""; tick_state="-"; exit_reason="unknown"
heartbeat() { # <state> [exit reason]
    local line
    line="hb=$(date +%s) pid=$$ key=${cur_hash:--} tick=$tick_state state=$1"
    [ -n "${2:-}" ] && line="$line exit=$2"
    printf '%s\n' "$line" > "$hb_file.tmp" 2>/dev/null && mv -f "$hb_file.tmp" "$hb_file" 2>/dev/null
}
trap 'heartbeat exited "$exit_reason"' EXIT
trap "exit_reason='signal-TERM'; exit 143" TERM
trap "exit_reason='signal-INT'; exit 130" INT
trap "exit_reason='signal-HUP'; exit 129" HUP

args_hash="$(printf '%s\n' "$*" | sha256sum | cut -c1-16)"  # gnu-ok: Linux-only kit (PLATFORM GUARD)

# bank_word: prints the bank-preflight verdict token; non-zero when the read
# failed, timed out, or its last line is not one of the verdict tokens.
bank_word() {
    local out
    if [ -n "${CONSOLE_WAIT_BANK:-}" ]; then
        out="$(bash "$CONSOLE_WAIT_BANK" 2>/dev/null)" || return 1
    else
        # gnu-ok: Linux-only kit (timeout). Same side-effect-free spelling tick.sh uses for its fleet census.
        out="$(CADENCE_BANK_LAUNCH='' CADENCE_BANK_LEDGER=/dev/null timeout -k 5 "$tick_timeout" \
            bash "$REPO/scripts/lib/bank-preflight.sh" 2>/dev/null)" || return 1
    fi
    out="$(printf '%s\n' "$out" | tail -n 1)"
    case "$out" in
        PROCEED|SKIPPED-BANK|SKIPPED-FLEET|BANK-STALE|BANK-UNKNOWN) printf '%s\n' "$out" ;;
        *) return 1 ;;
    esac
}

field() { # <name> <tick line>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}

# sample: sets tick_line and key (empty on a failed tick).
sample() {
    local f v raw bank
    key=""
    # A tick that exits non-zero failed, whatever it printed first.
    raw="$(timeout -k 5 "$tick_timeout" bash "$tick_cmd" "$@" 2>/dev/null)" || { tick_state=fail; return; }  # gnu-ok: Linux-only kit
    tick_line="$(printf '%s\n' "$raw" | grep '^TICK ' | head -n 1)"
    if [ -z "$tick_line" ]; then tick_state=fail; return; fi
    # A failed or garbled bank read is a failed sample, not a verdict.
    bank="$(bank_word)" || { tick_state=fail; return; }
    tick_state=ok
    for f in legs livestate prs tails legset board; do
        v="$(field "$f" "$tick_line")"
        # A field missing from a malformed/partial tick line is a failed
        # sample, never a key with an empty value baked in.
        if [ -z "$v" ]; then tick_state=fail; key=""; return; fi
        [ "$f" = board ] && v="${v%%:*}"
        key="$key$f=$v|"
    done
    key="${key}bank=$bank"
}

changed_fields() { # <old key> <new key>
    printf '%s\n' "$1" | tr '|' '\n' > "$hb_file.old"
    printf '%s\n' "$2" | tr '|' '\n' | while IFS= read -r kv; do
        grep -qxF -- "$kv" "$hb_file.old" || printf '%s\n' "${kv%%=*}"
    done | paste -sd, -
    rm -f "$hb_file.old"
}

saved=""
if [ -f "$key_file" ] && [ "$(sed -n 1p "$key_file")" = "$args_hash" ]; then
    saved="$(sed -n 2p "$key_file")"
fi
save_key() {
    tmp="$(mktemp "$key_file.XXXXXX" 2>/dev/null)" || return 0
    if printf '%s\n%s\n' "$args_hash" "$1" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$key_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
}
# Line 3 `failwoke` = this failure streak already woke the console once.
fail_woke() {
    [ "$(sed -n 1p "$key_file" 2>/dev/null)" = "$args_hash" ] && [ "$(sed -n 3p "$key_file" 2>/dev/null)" = failwoke ]
}

pending=""
fail_streak=0
fail_wake="${CONSOLE_WAIT_FAIL_WAKE:-3}"
next_tick=0
heartbeat sampling
while :; do
    # Telegram first: it is the cheap check and the operator's line. Peek, print
    # the header, then let --once stream the lines: each line is on stdout
    # before its cursor moves, so a kill mid-wake replays, never drops.
    bash "$HERE/inbox-follow.sh" --peek "$inbox" 9>&-; rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'WAKE telegram\n'
        bash "$HERE/inbox-follow.sh" --once "$inbox" 9>&- || { exit_reason='inbox-error'; exit 1; }
        exit_reason='wake-telegram'; exit 0
    elif [ "$rc" -ne 1 ]; then
        exit_reason='inbox-error'; exit 1
    fi
    if [ "$(date +%s)" -ge "$next_tick" ]; then
        next_tick=$(( $(date +%s) + interval ))
        # The Telegram path is blocked while a tick runs (up to twice
        # CONSOLE_WAIT_TICK_TIMEOUT with the bank read); say so in the heartbeat.
        heartbeat sampling
        sample "$@" 9>&-
        if [ -n "$key" ]; then
            fail_streak=0
            fail_woke && save_key "${saved:-$key}"
            cur_hash="$(printf '%s' "$key" | sha256sum | cut -c1-16)"  # gnu-ok: Linux-only kit
            if [ -z "$saved" ]; then
                saved="$key"; save_key "$key"
            elif [ "$key" = "$saved" ]; then
                pending=""
            elif [ -n "$pending" ]; then
                # Two consecutive samples off the saved key, equal or not: a
                # key that moves on every sample (a busy repo's PR set) is
                # still a change, not a blip.
                printf 'WAKE tick changed=%s bank=%s\n%s\n' "$(changed_fields "$saved" "$key")" "${key##*|bank=}" "$tick_line"
                save_key "$key"
                exit_reason='wake-tick'; exit 0
            else
                pending=1
            fi
        else
            pending=""
            fail_streak=$((fail_streak + 1))
            # A monitor that stays broken is an event too, but only once per
            # streak: the re-arm stays quiet until a sample succeeds.
            if [ "$fail_streak" -ge "$fail_wake" ] && ! fail_woke; then
                if tmp="$(mktemp "$key_file.XXXXXX" 2>/dev/null)"; then
                    if printf '%s\n%s\nfailwoke\n' "$args_hash" "$saved" > "$tmp" 2>/dev/null; then
                        mv -f "$tmp" "$key_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
                    else
                        rm -f "$tmp" 2>/dev/null
                    fi
                fi
                printf 'WAKE tick-fail samples=%s\n' "$fail_streak"
                exit_reason='wake-tick-fail'; exit 0
            fi
        fi
    fi
    heartbeat waiting
    sleep "$poll" 9>&-
done
