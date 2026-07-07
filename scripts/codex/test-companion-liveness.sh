#!/usr/bin/env bash
# Hermetic tests for companion-liveness.sh (HIMMEL-741).
# No real Codex install: temp state dirs hold fixture state.json files shaped
# exactly like lib/state.mjs (queued/running jobs with real+dead pids, empty,
# missing, corrupt). Asserts the exit-code contract: 0 healthy / 1 findings /
# 2 cannot-read.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/companion-liveness.sh"

command -v node >/dev/null 2>&1 || command -v node.exe >/dev/null 2>&1 || {
  echo "FAIL: node required" >&2; exit 1; }

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
assert_rc() {  # assert_rc <expected> <ok-name> <fail-detail>
  if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$3"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CODEX_STUCK_THRESHOLD_SECS=60

NOW_ISO="$(node -e 'process.stdout.write(new Date().toISOString())' 2>/dev/null \
        || node.exe -e 'process.stdout.write(new Date().toISOString())')"
STALE_ISO='2020-01-01T00:00:00.000Z'

# A definitely-live pid the script's _pid_alive will confirm on THIS platform.
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
  msys*|cygwin*|win32*|MINGW*|MSYS*)
    # MSYS $$ does not map to a Windows pid; use System (pid 4), always alive.
    LIVE_PID="$(MSYS_NO_PATHCONV=1 tasklist /FO CSV /NH 2>/dev/null | sed -n '2p' | sed 's/^"[^"]*","\([0-9]*\)".*/\1/')"
    [ -n "$LIVE_PID" ] || LIVE_PID=4
    ;;
  *) LIVE_PID="$$" ;;
esac
DEAD_PID=999999   # nothing this high should be live in a test run

# --- fixture helpers ---------------------------------------------------------
# make_state <dir> <status> <pid-json> <updatedAt>
make_state() {
  local dir="$1" status="$2" pidjson="$3" ts="$4"
  mkdir -p "$dir"
  cat > "$dir/state.json" <<JSON
{
  "version": 1,
  "config": { "stopReviewGate": false },
  "jobs": [
    {
      "id": "task-fixture-01",
      "kind": "task",
      "kindLabel": "rescue",
      "title": "Fixture Codex Task",
      "workspaceRoot": "C:/tmp/ws",
      "jobClass": "task",
      "status": "$status",
      "createdAt": "$ts",
      "updatedAt": "$ts",
      "startedAt": "$ts",
      "pid": $pidjson,
      "logFile": "$dir/task-fixture-01.log"
    }
  ]
}
JSON
}

run_probe() {  # run_probe <state-dir> ; sets $RC and $OUT
  set +e
  OUT="$(CODEX_STATE_DIR="$1" bash "$PROBE" 2>&1)"
  RC=$?
  set -e
}

# --- 1: queued + stale + null pid -> STUCK (exit 1) --------------------------
D="$TMP/queued-stale"; make_state "$D" 'queued' 'null' "$STALE_ISO"
run_probe "$D"
assert_rc 1 "queued-stale null-pid exits 1" "queued-stale rc=$RC out=$OUT"
case "$OUT" in *"STUCK"*"task-fixture-01"*) pass "queued-stale names the job";; *) fail "queued-stale output: $OUT";; esac

# --- 2: queued + fresh -> healthy (exit 0) -----------------------------------
D="$TMP/queued-fresh"; make_state "$D" 'queued' 'null' "$NOW_ISO"
run_probe "$D"
assert_rc 0 "queued-fresh exits 0" "queued-fresh rc=$RC out=$OUT"

# --- 3: running + stale + LIVE pid -> healthy (runner alive) ------------------
D="$TMP/running-live"; make_state "$D" 'running' "$LIVE_PID" "$STALE_ISO"
run_probe "$D"
assert_rc 0 "running-with-live-pid exits 0" "running-live rc=$RC out=$OUT (LIVE_PID=$LIVE_PID)"

# --- 4: running + stale + DEAD pid -> STUCK (exit 1) -------------------------
D="$TMP/running-dead"; make_state "$D" 'running' "$DEAD_PID" "$STALE_ISO"
run_probe "$D"
assert_rc 1 "running-with-dead-pid exits 1" "running-dead rc=$RC out=$OUT"

# --- 5: empty jobs array -> healthy (exit 0) ---------------------------------
D="$TMP/empty"; mkdir -p "$D"
printf '%s\n' '{ "version": 1, "config": {}, "jobs": [] }' > "$D/state.json"
run_probe "$D"
assert_rc 0 "empty jobs exits 0" "empty rc=$RC out=$OUT"

# --- 6: missing state.json -> healthy (exit 0) -------------------------------
D="$TMP/missing"; mkdir -p "$D"
run_probe "$D"
assert_rc 0 "missing state.json exits 0" "missing rc=$RC out=$OUT"

# --- 7: corrupt JSON -> cannot-read (exit 2) ---------------------------------
D="$TMP/corrupt"; mkdir -p "$D"
printf '%s\n' '{ this is : not json' > "$D/state.json"
run_probe "$D"
assert_rc 2 "corrupt json exits 2" "corrupt rc=$RC out=$OUT"

# --- 8: slug resolution via CODEX_STATE_ROOT + workspace ---------------------
ROOT="$TMP/root"; WS="$TMP/ws-himmel/my.repo"
mkdir -p "$WS"
# slug of basename 'my.repo' is 'my.repo' (dots/dashes preserved).
make_state "$ROOT/my.repo-deadbeefdeadbeef" 'queued' 'null' "$STALE_ISO"
set +e
OUT="$(CODEX_STATE_ROOT="$ROOT" bash "$PROBE" "$WS" 2>&1)"; RC=$?
set -e
assert_rc 1 "slug-matched state dir found via workspace (exit 1)" "slug-match rc=$RC out=$OUT"

# --- 9: nonexistent state root -> healthy (exit 0) ---------------------------
set +e
OUT="$(CODEX_STATE_ROOT="$TMP/does-not-exist" bash "$PROBE" "$TMP/ws-himmel/my.repo" 2>&1)"; RC=$?
set -e
assert_rc 0 "nonexistent state root exits 0" "no-root rc=$RC out=$OUT"

# --- 10: tmpdir fallback root (CLAUDE_PLUGIN_DATA unset) is scanned ----------
# lib/state.mjs falls back to os.tmpdir()/codex-companion when the harness does
# not set CLAUDE_PLUGIN_DATA; a stuck job there must be found, not false-healthy.
FAKE_TMP="$TMP/fake-tmpdir"; FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_TMP" "$FAKE_HOME"
make_state "$FAKE_TMP/codex-companion/my.repo-cafebabecafebabe" 'queued' 'null' "$STALE_ISO"
set +e
OUT="$(env -u CODEX_STATE_ROOT -u CLAUDE_PLUGIN_DATA TMPDIR="$FAKE_TMP" HOME="$FAKE_HOME" \
    CODEX_STUCK_THRESHOLD_SECS=60 bash "$PROBE" "$TMP/ws-himmel/my.repo" 2>&1)"; RC=$?
set -e
assert_rc 1 "tmpdir fallback root scanned (stuck job found, exit 1)" "tmpdir-fallback rc=$RC out=$OUT"

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
