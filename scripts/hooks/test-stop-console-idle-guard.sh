#!/usr/bin/env bash
# Smoke suite for scripts/hooks/stop-console-idle-guard.sh (HIMMEL-3144): a
# Stop hook that blocks a CONSOLE session's stop, once per turn, when it
# still holds the queue-lock on its own *-console.md document (D1: no wake
# path existed, so a console that ended its turn there just stayed dead).
#
# RED CONTROL FIRST (below): the hook genuinely did not exist on the base
# commit this ticket cut from — proving D1 had nothing to block a console's
# stop with, before this suite exercises the fix that now does.
#
# Cases covered after the RED control: (a) console stop -> block once, with
# a non-empty, next-action-naming reason; (b) the SAME payload with
# stop_hook_active:true -> allow (the loop guard); (c) a leg's stop payload
# (no console lock held) -> allow; (d) two SEPARATE induced faults, each
# with its own asserted precondition -> allow: (i) the held lock's
# owner.json made unreadable, (ii) a stubbed bank-preflight.sh that exits
# non-zero.
#
# Isolated fixture: its own HANDOVER_DIR/XDG_RUNTIME_DIR under mktemp -d, a
# real queue-lock.sh acquire against a fabricated *-console.md doc, scoped
# via QUEUE_LOCK_SESSION_SCOPE (queue-lock.sh's own documented test-caller
# convention) rather than the ambient CLAUDE_CODE_SESSION_ID, so this suite
# is deterministic regardless of what session runs it.
#
# Cleanup avoids `rm -rf` on purpose (himmel's own block-destructive-
# commands.sh refuses recursive+force rm, including from inside a test run
# under this repo's hooks) — every removal below is a non-recursive `rm -f`
# on a path this suite created itself, plus bottom-up `rmdir`.
#
# bash 3.2-safe.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HOOKS/../.." && pwd)"
HOOK="$HOOKS/stop-console-idle-guard.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "SKIP: no sha256 tool on PATH"
    exit 0
fi

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip() { printf '  SKIP %s\n' "$1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stop-console-idle-guard-test.XXXXXX")" || { echo "setup: mktemp -d failed" >&2; exit 1; }
HANDOVER_DIR="$TMP/handover"
XDG_RUNTIME_DIR="$TMP/xdg"
mkdir -p "$HANDOVER_DIR" "$XDG_RUNTIME_DIR"
export HANDOVER_DIR XDG_RUNTIME_DIR

SESSION_ID="test-session-himmel-3144"
CONSOLE_DOC="$HANDOVER_DIR/FIXTURE-nextleg-console.md"
printf 'fixture console doc\n' > "$CONSOLE_DOC"

RELEASE_TOKEN=""
cleanup() {
    if [ -n "$RELEASE_TOKEN" ]; then
        chmod 644 "$HANDOVER_DIR"/.locks/queue/*-console.lock/owner.json 2>/dev/null
        bash "$REPO/scripts/handover/queue-lock.sh" release "$CONSOLE_DOC" "$RELEASE_TOKEN" >/dev/null 2>&1
    fi
    for f in "$HANDOVER_DIR"/.locks/queue/*.lock/*; do rm -f "$f" 2>/dev/null; done
    for d in "$HANDOVER_DIR"/.locks/queue/*.lock; do rmdir "$d" 2>/dev/null; done
    rm -f "$HANDOVER_DIR/.locks/queue/takeovers.log" 2>/dev/null
    rmdir "$HANDOVER_DIR/.locks/queue" 2>/dev/null
    rmdir "$HANDOVER_DIR/.locks" 2>/dev/null
    rm -f "$CONSOLE_DOC" 2>/dev/null
    rmdir "$HANDOVER_DIR" 2>/dev/null
    for f in "$XDG_RUNTIME_DIR/himmel-queue-lock"/*; do rm -f "$f" 2>/dev/null; done
    rmdir "$XDG_RUNTIME_DIR/himmel-queue-lock" 2>/dev/null
    rmdir "$XDG_RUNTIME_DIR" 2>/dev/null
    rm -f "$TMP/bank-preflight-stub.sh" 2>/dev/null
    rmdir "$TMP" 2>/dev/null
}
trap cleanup EXIT

lock_out="$(QUEUE_LOCK_SESSION_SCOPE="$SESSION_ID" bash "$REPO/scripts/handover/queue-lock.sh" acquire "$CONSOLE_DOC")" \
    || { echo "setup: could not acquire the fixture console lock" >&2; exit 1; }
# shellcheck disable=SC2016  # backtick span pattern, not a shell expansion
RELEASE_TOKEN="$(printf '%s\n' "$lock_out" | sed -n 's/^release-token: `\(.*\)`$/\1/p')"
[ -n "$RELEASE_TOKEN" ] || { echo "setup: acquire printed no release token" >&2; exit 1; }

CONSOLE_PAYLOAD="$(printf '{"session_id":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$SESSION_ID")"
CONSOLE_PAYLOAD_ACTIVE="$(printf '{"session_id":"%s","stop_hook_active":true,"hook_event_name":"Stop"}' "$SESSION_ID")"
LEG_PAYLOAD='{"session_id":"a-leg-session-not-a-console","stop_hook_active":false,"hook_event_name":"Stop"}'

is_block() { local out; out="$(printf '%s' "$1" | grep '"decision":"block"')"; [ -n "$out" ]; }

run_guard() {   # run_guard <payload> [ENV=val ...]
    local payload="$1"; shift
    printf '%s' "$payload" | env "$@" bash "$HOOK"
}

# --- RED control: no wake path existed at the base this ticket cut from ---
BASE_SHA="ac9253f154287f2c276af7c86177a76f7169931f"
if git -C "$REPO" cat-file -e "$BASE_SHA:scripts/hooks/stop-console-idle-guard.sh" 2>/dev/null; then
    bad "RED control: stop-console-idle-guard.sh already existed at $BASE_SHA — D1's premise (no wake path) does not hold for this base"
else
    ok "RED control: stop-console-idle-guard.sh did not exist at base $BASE_SHA — D1 had nothing to block a console's stop with"
fi

# --- (a) console session + outstanding work -> block once ------------------
out="$(run_guard "$CONSOLE_PAYLOAD")"
if is_block "$out"; then ok "(a) console stop, lock held -> block"; else bad "(a) console stop -> expected block, got: $out"; fi
reason="$(printf '%s' "$out" | sed -n 's/.*"reason":"\(.*\)"}$/\1/p')"
if [ -n "$reason" ]; then ok "(a) reason is non-empty"; else bad "(a) reason is empty"; fi
case "$reason" in
    *'/console next --arm'*) ok "(a) reason names a concrete next action" ;;
    *) bad "(a) reason does not name a concrete next action — got: $reason" ;;
esac

# --- (b) same payload, stop_hook_active:true -> allow (loop guard) --------
out="$(run_guard "$CONSOLE_PAYLOAD_ACTIVE")"
if is_block "$out"; then bad "(b) stop_hook_active=true -> expected allow, got: $out"; else ok "(b) stop_hook_active=true -> allow"; fi

# --- (c) a leg's stop payload (no console lock held) -> allow -------------
out="$(run_guard "$LEG_PAYLOAD")"
if is_block "$out"; then bad "(c) leg stop -> expected allow, got: $out"; else ok "(c) leg stop -> allow"; fi

# --- (d)(i) induced fault: the held lock's owner.json is unreadable -------
chmod 000 "$HANDOVER_DIR"/.locks/queue/*-console.lock/owner.json 2>/dev/null
readable=1
for f in "$HANDOVER_DIR"/.locks/queue/*-console.lock/owner.json; do
    [ -r "$f" ] && readable=0
done
out="$(run_guard "$CONSOLE_PAYLOAD")"
chmod 644 "$HANDOVER_DIR"/.locks/queue/*-console.lock/owner.json 2>/dev/null
if [ "$readable" -eq 0 ]; then
    skip "(d-i) owner.json is still readable after chmod 000 (running as root?) — precondition not engaged"
else
    if is_block "$out"; then bad "(d-i) unreadable owner.json -> expected allow, got: $out"; else ok "(d-i) unreadable owner.json -> allow"; fi
fi

# --- (d)(ii) induced fault: bank-preflight.sh exits non-zero --------------
STUB="$TMP/bank-preflight-stub.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf 'echo "stub: refusing on purpose (test fault injection)" >&2\n'
    printf 'exit 7\n'
} > "$STUB"
chmod +x "$STUB"
out="$(run_guard "$CONSOLE_PAYLOAD" HIMMEL_STOP_GUARD_BANK_PREFLIGHT="$STUB")"
if is_block "$out"; then bad "(d-ii) bank-preflight.sh exit!=0 -> expected allow, got: $out"; else ok "(d-ii) bank-preflight.sh exit!=0 -> allow"; fi
# Prove the stub's precondition was real, not a no-op: case (a) already
# showed the REAL bank-preflight.sh path blocks — re-run it here once more
# so a future refactor that stops calling BANK_PREFLIGHT_SH at all can't
# silently turn (d-ii) into a vacuous control.
out="$(run_guard "$CONSOLE_PAYLOAD")"
if is_block "$out"; then ok "(d-ii) control: the real bank-preflight.sh still blocks (stub was exercised, not bypassed)"; else bad "(d-ii) control: the real bank-preflight.sh no longer blocks — got: $out"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
