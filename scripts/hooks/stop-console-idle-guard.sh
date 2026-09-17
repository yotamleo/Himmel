#!/usr/bin/env bash
# stop-console-idle-guard.sh — Stop hook (HIMMEL-3144).
#
# WHY: console F ended its turn with an empty fleet, a 9-item held queue and
# `PROCEED` from the bank, and stayed dead for 58 minutes — Stop was
# unguarded (the only Stop entry, stop-queue.mjs's speak-reply job, never
# blocks) and no monitor event starts a new turn in an idle interactive
# session. This hook is the wake path D1 in the ticket calls for: it blocks
# a CONSOLE session's stop exactly once per turn so it is re-prompted
# instead of going structurally dead. What "outstanding work" means here is
# deliberately narrow and testable: a console that has genuinely finished
# its shift RELEASES its queue-lock (wrap) or hands off via `/console next`
# before ending its turn; holding the lock at Stop time, on a turn that is
# not the guard's own re-entry, IS the D1 failure mode. This hook does not
# inspect the held Jira/dispatch queue itself (out of scope per the ticket —
# "not in scope: changing what a console does with its queue").
#
# ROUTING — sibling entry, NOT enqueued through stop-queue.mjs. stop-queue
# exists to make detached, end-of-session work non-blocking (HIMMEL-2004):
# every job it runs is deliberately async, and the hook that enqueues it
# returns in milliseconds having already decided ALLOW (see its own header
# comment: "EXIT CODE IS THE FALLBACK SIGNAL... never 2"). This hook's whole
# job is the opposite — it must hand Claude Code a synchronous
# `{"decision":"block",...}` on stdout BEFORE the turn actually ends, so it
# is wired as its own Stop entry next to (not through) stop-queue.mjs.
#
# CONSOLE DETECTION — best-effort, via queue-lock.sh's persisted-token
# mechanism (HIMMEL-2813): the console's queue-lock is acquired by
# console.sh, a launcher script that exits before the actual `claude`
# process starts, so the lock's owner.json never carries this session's id
# and there is no other artifact tying "this session" to "that lock" a Stop
# hook can read. What queue-lock.sh DOES persist, keyed on
# sha256("$CLAUDE_CODE_SESSION_ID|<handover-path>"), under
# `${XDG_RUNTIME_DIR}/himmel-queue-lock/`, is a per-session, per-document
# token file written on every acquire/heartbeat/release THIS session made
# (queue-lock.sh's own comment on `_ql_token_persist`: "best-effort ON
# PURPOSE"). Recomputing that digest for the Stop payload's `session_id`
# against every held `*-console` lock and checking whether the file exists
# is the same best-effort signal, one layer up — a false negative here just
# allows the stop (fail-open), it never blocks one it should not.
#
# FAIL-OPEN CONTRACT: every step below that cannot positively confirm
# "console session, first stop this turn, lock still held" allows the stop.
# A malformed or missing payload, an unresolvable handover root, an
# unreadable/corrupt lock dir, a missing sha256 tool, a `bank-preflight.sh`
# or `queue-lock.sh status --sweep` that fails or hangs — all of these
# `exit 0` with NO stdout, which Claude Code reads as allow. The block JSON
# is built and printed only as the LAST statement, once every input it
# depends on has already succeeded — nothing partial is ever emitted. Every
# subprocess this hook shells out to (`git`, `bank-preflight.sh`,
# `queue-lock.sh status --sweep`) is wrapped with a hard `timeout` so a
# hung dependency degrades to "allow" rather than trapping the session.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GUARD_TIMEOUT_SECS="${HIMMEL_STOP_GUARD_TIMEOUT:-6}"   # sub-budget under the 10s harness Stop timeout
# Test seams (default: the real scripts) -- so the fault-injection tests can
# point these at a stub without PATH tricks, the same convention as tick.sh's
# TICK_BANK_CACHE_FILE / FLEET_PS_CMD.
BANK_PREFLIGHT_SH="${HIMMEL_STOP_GUARD_BANK_PREFLIGHT:-$REPO/scripts/lib/bank-preflight.sh}"
QUEUE_LOCK_SH="${HIMMEL_STOP_GUARD_QUEUE_LOCK:-$REPO/scripts/handover/queue-lock.sh}"

# _bounded <cmd...> -- run under a hard timeout when `timeout` exists;
# best-effort (unbounded) when it does not, same degrade-gracefully posture
# as the rest of this fail-open hook.
_bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$GUARD_TIMEOUT_SECS" "$@"
    else
        "$@"
    fi
}

# shellcheck source=../lib/handover-path.sh
. "$HERE/../lib/handover-path.sh" 2>/dev/null || exit 0

# --- read the hook payload -------------------------------------------------
# -d '' slurps all of stdin (Claude Code hook JSON may be pretty-printed
# across multiple lines) until EOF; that always leaves a nonzero `read`
# status with $payload populated, so the status is deliberately not checked.
payload=""
IFS= read -r -t 5 -d '' payload

[ -n "$payload" ] || exit 0

# stop_hook_active is a JSON boolean, not a quoted string, so
# _hp_json_field (string-field only) cannot read it — this is the loop
# guard and it must fire on the very first check, unconditionally.
case "$payload" in
    *'"stop_hook_active"'*)
        stop_active_match="$(printf '%s' "$payload" | grep -E '"stop_hook_active"[[:space:]]*:[[:space:]]*true')"
        [ -z "$stop_active_match" ] || exit 0
        ;;
esac

_hp_json_field "$payload" session_id
session_id="$_HP_FIELD"
[ -n "$session_id" ] || exit 0

# --- is the stopping session holding a *-console.md queue-lock? -----------
# shellcheck disable=SC2016  # $1 is meant for the inner bash -c, not this shell
root="$(_bounded bash -c '. "$1/../lib/handover-path.sh" 2>/dev/null && handover_root 2>/dev/null' _ "$HERE")" || exit 0
[ -n "$root" ] || exit 0

lockdir_root="$root/.locks/queue"
[ -d "$lockdir_root" ] || exit 0

digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    fi
}

token_dir="${XDG_RUNTIME_DIR:-/tmp}/himmel-queue-lock"

console_doc=""
for lockdir in "$lockdir_root"/*-console.lock; do
    [ -d "$lockdir" ] || continue
    [ -f "$lockdir/owner.json" ] || continue
    owner_raw="$(cat "$lockdir/owner.json" 2>/dev/null)" || continue
    _hp_json_field "$owner_raw" handover
    candidate_doc="$_HP_FIELD"
    [ -n "$candidate_doc" ] || continue
    # Same backslash->slash normalization queue-lock.sh's own
    # _ql_token_digest applies before hashing, so a Git-Bash-acquired lock's
    # digest still matches here.
    candidate_doc="${candidate_doc//\\//}"
    digest="$(digest_of "$session_id|$candidate_doc")"
    [ -n "$digest" ] || continue
    token_match=0
    for tokfile in "$token_dir/$digest".*; do
        [ -f "$tokfile" ] && token_match=1
    done
    if [ "$token_match" -eq 1 ]; then
        console_doc="$candidate_doc"
        break
    fi
done

[ -n "$console_doc" ] || exit 0

# --- confirmed: console session, first stop this turn, lock still held ----
# Gather the state a useful reason names. Any failure here allows the stop
# outright rather than blocking with an empty/generic reason (HIMMEL-3144:
# "a reason that only says do not idle is not acceptable").
bank_err_file="$(mktemp "${TMPDIR:-/tmp}/stop-console-idle-guard-bank.XXXXXX" 2>/dev/null)" || exit 0
bank_token="$(_bounded env CADENCE_BANK_LEG=stop-console-idle-guard bash "$BANK_PREFLIGHT_SH" 2>"$bank_err_file")"
bank_rc=$?
bank_fleet_line="$(grep -m1 '^bank-preflight: FLEET ' "$bank_err_file" 2>/dev/null)"
rm -f "$bank_err_file" 2>/dev/null
[ "$bank_rc" -eq 0 ] || exit 0
[ -n "$bank_token" ] || exit 0
[ -n "$bank_fleet_line" ] || bank_fleet_line="bank-preflight: FLEET unavailable"
bank_fleet_line="${bank_fleet_line#bank-preflight: }"

sweep_out="$(_bounded bash "$QUEUE_LOCK_SH" status --sweep "$root" 2>/dev/null)"
sweep_rc=$?
# 0 = clean/no-flags, 20 = at least one flagged lock (still a VALID sweep,
# not a fault) -- any other code (including a timeout's 124) is a real fault.
case "$sweep_rc" in
    0|20) ;;
    *) exit 0 ;;
esac

leg_count=0
leg_names=""
while IFS= read -r line; do
    case "$line" in
        slug=*-console\ *) continue ;;   # the console's own lock, not a leg
        slug=*)
            leg_count=$((leg_count + 1))
            leg_slug="${line#slug=}"
            leg_slug="${leg_slug%% *}"
            leg_names="${leg_names:+$leg_names, }$leg_slug"
            ;;
    esac
done <<SWEEP
$sweep_out
SWEEP
[ -n "$leg_names" ] || leg_names="none"

console_doc_name="${console_doc##*/}"

reason="Console stop guard (HIMMEL-3144): this session still holds the queue-lock on $console_doc_name — ending the turn now would leave it structurally dead (no Stop hook, no monitor event, starts a new one). Before stopping: dispatch the next queued item, verify a READY PR, or run \`/console next --arm\` to hand off. State read at this stop — $bank_fleet_line; bank: $bank_token; leg locks held ($leg_count): $leg_names."

_hp_json_escape "$reason"
printf '{"decision":"block","reason":"%s"}\n' "$_HP_ESC"
exit 0
