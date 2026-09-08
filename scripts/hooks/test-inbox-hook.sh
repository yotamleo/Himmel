#!/usr/bin/env bash
# test-inbox-hook.sh — HIMMEL-2788. Exercises scripts/lib/claudex-inbox.sh's
# cursor bookkeeping directly, and the two hook scripts
# (claudex-inbox-hook.sh / claudex-inbox-sessionstart.sh) end-to-end via a
# fabricated HANDOVER_DIR + session-name.sh's SESSION_NAME_CMDLINE_FILE test
# seam. bash 3.2-safe. Run: bash scripts/hooks/test-inbox-hook.sh
#
# PLATFORM GUARD: no .ps1 twin, by design, not oversight — tests a Linux-only
# claudex lane (see claudex-inbox-hook.sh's header).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inbox-hook-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# --- direct inbox_new_bullets() tests --------------------------------------

# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/handover-path.sh"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/claudex-inbox.sh"

HANDOVER_DIR="$WORK/handover-root"
mkdir -p "$HANDOVER_DIR/inbox"
export HANDOVER_DIR
SESSION="HIMMEL-2788-test-leg"
INBOX="$HANDOVER_DIR/inbox/$SESSION.md"

# Direct callers own delivery and commit; the race test below also covers the
# legacy inbox_new_bullets entry point.
# shellcheck disable=SC2317,SC2329 # Callback invoked by inbox_with_lock.
deliver_direct() {
    inbox_peek "$1" || return 1
    if [ -n "$inbox_bullets" ]; then
        printf '%s\n' "$inbox_bullets" || return 1
    fi
    inbox_commit
}

# Case 1: no inbox file yet -> silent no-op, rc 0
out="$(inbox_with_lock "$SESSION" deliver_direct)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "missing inbox: rc=0 silent"
else
    fail "missing inbox: rc=0 silent (rc=$rc out='$out')"
fi

# Case 2: one bullet appended -> delivered once
printf -- '- 09:00 first ruling\n' >> "$INBOX"
out="$(inbox_with_lock "$SESSION" deliver_direct)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'first ruling'; then
    pass "new bullet: injected"
else
    fail "new bullet: injected (rc=$rc out='$out')"
fi

# Case 3 (RED control): calling again with no new content -> nothing
out="$(inbox_with_lock "$SESSION" deliver_direct)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "second call with no new content: nothing delivered (RED control)"
else
    fail "second call with no new content: nothing delivered (rc=$rc out='$out')"
fi

# Case 4: cursor survives "restart" (a fresh subshell re-reading the same
# cursor file from disk, not an in-memory value)
printf -- '- 09:05 second ruling\n' >> "$INBOX"
out="$(bash -c '. "$1/scripts/lib/handover-path.sh"; . "$1/scripts/lib/claudex-inbox.sh"; inbox_new_bullets "$2"' _ "$REPO_ROOT" "$SESSION")"
if printf '%s' "$out" | grep -qF 'second ruling' && ! printf '%s' "$out" | grep -qF 'first ruling'; then
    pass "cursor persists across process restart: only the new bullet delivered"
else
    fail "cursor persists across process restart (out='$out')"
fi

# --- claudex-inbox-hook.sh end-to-end (PostToolUse / JSON contract) --------

run_hook() { # <hook-script>
    CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 \
        SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE" HANDOVER_DIR="$HANDOVER_DIR" \
        bash "$1"
}

CMDLINE_FILE="$WORK/cmdline"
printf 'claude\0--model\0claude-sonnet-5\0-n\0%s\0load\0doc.md\0' "$SESSION" > "$CMDLINE_FILE"

if command -v jq >/dev/null 2>&1; then
    printf -- '- 09:10 third ruling\n' >> "$INBOX"

    out="$(run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
    ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
    if printf '%s' "$ctx" | grep -qF 'third ruling'; then
        pass "claudex-inbox-hook.sh: delivers as hookSpecificOutput.additionalContext"
    else
        fail "claudex-inbox-hook.sh: delivers as hookSpecificOutput.additionalContext (out='$out')"
    fi

    # RED control: second run, nothing new -> silent, empty stdout
    out2="$(run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
    if [ -z "$out2" ]; then
        pass "claudex-inbox-hook.sh: second run with no new content is silent (RED control)"
    else
        fail "claudex-inbox-hook.sh: second run with no new content is silent (out='$out2')"
    fi
else
    fail "jq not available — cannot exercise claudex-inbox-hook.sh's JSON contract"
fi

# missing inbox (fresh unknown session name) -> rc 0, no stdout
CMDLINE_FILE2="$WORK/cmdline-unknown"
printf 'claude\0-n\0HIMMEL-2788-no-such-session\0' > "$CMDLINE_FILE2"
out="$(CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE2" \
    HANDOVER_DIR="$HANDOVER_DIR" bash "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "claudex-inbox-hook.sh: missing inbox -> rc 0 silent"
else
    fail "claudex-inbox-hook.sh: missing inbox -> rc 0 silent (rc=$rc out='$out')"
fi

# bad (traversal-shaped) session name -> refused, rc 0, no stdout
CMDLINE_FILE3="$WORK/cmdline-bad"
printf 'claude\0-n\0../../etc/passwd\0' > "$CMDLINE_FILE3"
out="$(CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE3" \
    HANDOVER_DIR="$HANDOVER_DIR" bash "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "claudex-inbox-hook.sh: traversal-shaped session name refused"
else
    fail "claudex-inbox-hook.sh: traversal-shaped session name refused (rc=$rc out='$out')"
fi

# --- claudex-inbox-sessionstart.sh (SessionStart / plain-text contract) ----

# Fresh session + fresh bullet so this is independent of the PostToolUse runs
# above (same cursor file would otherwise already be caught up).
SESSION2="HIMMEL-2788-test-leg-sessionstart"
INBOX2="$HANDOVER_DIR/inbox/$SESSION2.md"
printf -- '- 09:15 sessionstart ruling\n' >> "$INBOX2"
CMDLINE_FILE4="$WORK/cmdline-ss"
printf 'claude\0-n\0%s\0' "$SESSION2" > "$CMDLINE_FILE4"
out="$(CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PID=12345 SESSION_NAME_CMDLINE_FILE="$CMDLINE_FILE4" \
    HANDOVER_DIR="$HANDOVER_DIR" bash "$REPO_ROOT/scripts/hooks/claudex-inbox-sessionstart.sh")"
if printf '%s' "$out" | grep -qF 'sessionstart ruling' && ! printf '%s' "$out" | grep -q '{'; then
    pass "claudex-inbox-sessionstart.sh: plain-text delivery, no JSON envelope"
else
    fail "claudex-inbox-sessionstart.sh: plain-text delivery, no JSON envelope (out='$out')"
fi

# Shared cursor: PostToolUse hook run right after -> nothing left to deliver
CMDLINE_FILE="$CMDLINE_FILE4"
out2="$(run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
if [ -z "$out2" ]; then
    pass "shared cursor: PostToolUse hook delivers nothing after SessionStart already consumed it"
else
    fail "shared cursor: PostToolUse hook delivers nothing after SessionStart already consumed it (out='$out2')"
fi

# HIMMEL-2791: a serialization failure must leave the ruling pending.
mkdir -p "$WORK/fail-jq"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/fail-jq/jq"
chmod +x "$WORK/fail-jq/jq"
printf -- '- retry after serialization failure\n' >> "$INBOX2"
before="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION2")"
out="$(PATH="$WORK/fail-jq:$PATH" run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"; rc=$?
after="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION2")"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$before" = "$after" ]; then
    pass "failed jq: fail-open without advancing cursor"
else
    fail "failed jq: cursor advanced or hook failed (before=$before after=$after rc=$rc)"
fi
out="$(run_hook "$REPO_ROOT/scripts/hooks/claudex-inbox-hook.sh")"
if printf '%s' "$out" | grep -qF 'retry after serialization failure'; then
    pass "failed jq: next successful delivery retries the ruling"
else
    fail "failed jq: ruling lost instead of retried"
fi

# HIMMEL-2790: pause writer one at mv, then start writer two. The second
# announces either its lock attempt (fixed) or its mv (unlocked baseline).
# These handshakes force overlap; elapsed time is never the assertion.
mkdir -p "$WORK/race-bin" "$WORK/race"
INBOX_RACE="$WORK/race"
REAL_MV="$(command -v mv)"
REAL_FLOCK="$(command -v flock)"
export INBOX_RACE REAL_MV REAL_FLOCK
cat > "$WORK/race-bin/mv" <<'STUB'
#!/usr/bin/env bash
if [ "$RACE_WRITER" = one ]; then
    touch "$INBOX_RACE/ready"
    for ((i=0; i<1000; i++)); do
        [ ! -f "$INBOX_RACE/release" ] || exec "$REAL_MV" "$@"
        sleep .01
    done
    exit 1
fi
touch "$INBOX_RACE/second"
exec "$REAL_MV" "$@"
STUB
cat > "$WORK/race-bin/flock" <<'STUB'
#!/usr/bin/env bash
[ "$RACE_WRITER" != two ] || touch "$INBOX_RACE/second"
exec "$REAL_FLOCK" "$@"
STUB
chmod +x "$WORK/race-bin/mv" "$WORK/race-bin/flock"
wait_race_file() {
    local i
    for ((i=0; i<1000; i++)); do
        [ ! -f "$1" ] || return 0
        sleep .01
    done
    return 1
}
printf -- '- concurrent ruling\n' > "$HANDOVER_DIR/inbox/race.md"
(PATH="$WORK/race-bin:$PATH" RACE_WRITER=one inbox_new_bullets race) > "$WORK/one" &
pid1=$!
wait_race_file "$INBOX_RACE/ready" || fail "cursor race: first writer reached mv"
(PATH="$WORK/race-bin:$PATH" RACE_WRITER=two inbox_new_bullets race) > "$WORK/two" &
pid2=$!
wait_race_file "$INBOX_RACE/second" || fail "cursor race: second writer overlapped"
touch "$INBOX_RACE/release"
wait "$pid1" || fail "cursor race: first writer exited successfully"
wait "$pid2" || fail "cursor race: second writer exited successfully"
count="$(cat "$WORK/one" "$WORK/two" | grep -cF 'concurrent ruling')"
if [ "$count" -eq 1 ]; then
    pass "concurrent cursor writers deliver the ruling once"
else
    fail "concurrent cursor writers duplicated ruling (count=$count)"
fi

# Both hook delivery mechanisms must preserve pending content on stdout error.
for hook in claudex-inbox-hook.sh claudex-inbox-sessionstart.sh; do
    printf -- '- stdout retry %s\n' "$hook" >> "$INBOX2"
    before="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION2")"
    run_hook "$REPO_ROOT/scripts/hooks/$hook" > /dev/full 2>/dev/null; rc=$?
    after="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION2")"
    out="$(run_hook "$REPO_ROOT/scripts/hooks/$hook")"
    if [ "$rc" -eq 0 ] && [ "$before" = "$after" ] && printf '%s' "$out" | grep -qF "stdout retry $hook"; then
        pass "$hook: stdout failure keeps cursor and retries"
    else
        fail "$hook: stdout failure lost pending content"
    fi
done

printf -- '- direct stdout retry\n' >> "$INBOX"
before="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION")"
inbox_with_lock "$SESSION" deliver_direct > /dev/full 2>/dev/null
after="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION")"
out="$(inbox_with_lock "$SESSION" deliver_direct)"
if [ "$before" = "$after" ] && printf '%s' "$out" | grep -qF 'direct stdout retry'; then
    pass "direct caller: failed stdout does not commit"
else
    fail "direct caller: failed stdout consumed ruling"
fi

# Peek alone must not persist, even when the caller subsequently exits.
printf -- '- peek then exit\n' >> "$INBOX"
before="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION")"
inbox_with_lock "$SESSION" inbox_peek
after="$(cat "$HANDOVER_DIR/inbox/.cursor/$SESSION")"
out="$(inbox_new_bullets "$SESSION")"
if [ "$before" = "$after" ] && printf '%s' "$out" | grep -qF 'peek then exit'; then
    pass "peek without commit leaves ruling pending and releases lock"
else
    fail "peek without commit consumed ruling or retained lock"
fi

# Missing flock is the explicit unlocked fallback, not a delivery outage.
printf -- '- unlocked fallback\n' >> "$INBOX"
out="$(
    # shellcheck disable=SC2317,SC2329 # Overrides lookup inside the sourced helper.
    command() {
        if [ "$*" = '-v flock' ]; then return 1; fi
        builtin command "$@"
    }
    inbox_new_bullets "$SESSION"
)"
again="$(inbox_new_bullets "$SESSION")"
if printf '%s' "$out" | grep -qF 'unlocked fallback' && [ -z "$again" ]; then
    pass "missing flock: ruling delivered and cursor committed"
else
    fail "missing flock: delivery or commit failed"
fi

# HIMMEL-2790 (CodeRabbit): a corrupted/hand-recovered cursor file holding a
# leading-zero, digit-only value (e.g. "08") must not be misparsed as an
# invalid octal literal by inbox_peek's arithmetic expansion.
SESSION_OCTAL="HIMMEL-2788-octal-leg"
INBOX_OCTAL="$HANDOVER_DIR/inbox/$SESSION_OCTAL.md"
printf -- '- octal cursor ruling\n' > "$INBOX_OCTAL"
printf '08' > "$HANDOVER_DIR/inbox/.cursor/$SESSION_OCTAL"
out="$(inbox_new_bullets "$SESSION_OCTAL")"
if [ -n "$out" ]; then
    pass "leading-zero cursor value delivers instead of crashing arithmetic expansion"
else
    fail "leading-zero cursor value crashed arithmetic expansion or lost the ruling"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
