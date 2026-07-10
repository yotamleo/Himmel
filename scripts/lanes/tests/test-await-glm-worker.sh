#!/usr/bin/env bash
# Hermetic tests for await-glm-worker.sh (HIMMEL-883). Fixture sessions in a
# temp BRIDGE_ROOT; never touches the real glm-sessions root.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../await-glm-worker.sh"
TMP="$(mktemp -d -t await-glm-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export BRIDGE_ROOT="$TMP/bridge"

fails=0
check() { # <name> <expected-rc> <actual-rc>
    if [ "$2" -eq "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1 (expected rc=$2 got rc=$3)"
        fails=$((fails + 1))
    fi
}

mk_session() { # <name> <status> -> echoes dir
    d="$BRIDGE_ROOT/glm-sessions/$1"
    mkdir -p "$d"
    printf '{\n  "status": "%s",\n  "pid": 1\n}\n' "$2" > "$d/meta.json"
    echo "$d"
}

# 1. terminal session by explicit --session-dir -> rc 0, prints meta
d=$(mk_session "glm-t1-1000000000001" "done")
printf '{"text":"[done] all green"}\n' > "$d/outbox.jsonl"
out=$(bash "$SUT" --session-dir "$d" --max-mins 1)
check "terminal-by-dir rc" 0 $?
case "$out" in
    *'"status": "done"'*'[done] all green'*) echo "ok   terminal-by-dir output" ;;
    *) echo "FAIL terminal-by-dir output: $out"; fails=$((fails + 1)) ;;
esac

# 2. slug resolution picks the NEWEST session (older done ignored in favor of
#    newer timeout)
mk_session "glm-t2-1000000000001" "done" >/dev/null
mk_session "glm-t2-1000000000002" timeout >/dev/null
out=$(bash "$SUT" --slug t2 --max-mins 1)
check "newest-by-slug rc" 0 $?
case "$out" in
    *1000000000002*'"status": "timeout"'*) echo "ok   newest-by-slug output" ;;
    *) echo "FAIL newest-by-slug output: $out"; fails=$((fails + 1)) ;;
esac

# 3. missing session -> rc 2 (window must elapse first; use tiny window via
#    POLL override through max-mins 0 -> immediate deadline)
bash "$SUT" --slug does-not-exist --max-mins 0 >/dev/null 2>&1
check "missing-session rc" 2 $?

# 4. still-running session -> rc 3 after the window closes
d=$(mk_session "glm-t4-1000000000001" running)
bash "$SUT" --session-dir "$d" --max-mins 0 >/dev/null
check "still-running rc" 3 $?

# 5. no selector -> rc 2
bash "$SUT" --max-mins 0 >/dev/null 2>&1
check "no-selector rc" 2 $?

# 6. running session that flips to done mid-poll -> rc 0
d=$(mk_session "glm-t6-1000000000001" running)
( sleep 12; printf '{\n  "status": "done",\n  "pid": 1\n}\n' > "$d/meta.json" ) &
flipper=$!
bash "$SUT" --session-dir "$d" --max-mins 1 >/dev/null
rc=$?
wait "$flipper" 2>/dev/null
check "flip-to-done rc" 0 "$rc"

# 7. SLUG mode: session dir does not exist at poll start, appears mid-window
#    -> rc 0 (proves resolve_session_dir re-runs on every loop iteration; a
#    hoisted one-shot resolution would fail this)
( sleep 12; mk_session "glm-t7-1000000000001" "done" >/dev/null ) &
flipper=$!
bash "$SUT" --slug t7 --max-mins 1 >/dev/null
rc=$?
wait "$flipper" 2>/dev/null
check "slug-late-appear rc" 0 "$rc"

# 8. SLUG mode: running session flips to done mid-window -> rc 0 (re-poll of a
#    slug-resolved dir, the documented primary invocation shape)
d=$(mk_session "glm-t8-1000000000001" running)
( sleep 12; printf '{\n  "status": "done",\n  "pid": 1\n}\n' > "$d/meta.json" ) &
flipper=$!
bash "$SUT" --slug t8 --max-mins 1 >/dev/null
rc=$?
wait "$flipper" 2>/dev/null
check "slug-flip-to-done rc" 0 "$rc"

# 9. unknown flag -> rc 2 (bad-args branch of the parser)
bash "$SUT" --bogus x --max-mins 0 >/dev/null 2>&1
check "unknown-arg rc" 2 $?

# 10. value-taking flag with no value -> rc 2, not an infinite loop (HIMMEL-883
# codex-adv). timeout-guard so a regression to `shift 2` hangs the check, not CI.
if command -v timeout >/dev/null 2>&1; then
    timeout 5 bash "$SUT" --slug >/dev/null 2>&1
else
    bash "$SUT" --slug >/dev/null 2>&1
fi
check "missing-value rc" 2 $?

# 11. unrecognized / partial status -> NOT terminal (rc 3). Guards against false
# completion on a torn/corrupt meta write; only a known terminal status ends it
# (HIMMEL-883 codex-adv round 4).
d=$(mk_session "glm-t11-1000000000001" "partial-write-xyz")
bash "$SUT" --session-dir "$d" --max-mins 0 >/dev/null 2>&1
check "unknown-status-not-terminal rc" 3 $?

echo
if [ "$fails" -gt 0 ]; then
    echo "test-await-glm-worker: $fails FAILURE(S)"
    exit 1
fi
echo "test-await-glm-worker: all tests pass"
