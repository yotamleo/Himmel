#!/usr/bin/env bash
# test-restart-bridge.sh — hermetic V6 coverage for restart-bridge.sh
# (HIMMEL-2176 Task 9). Never starts a real bridge, never touches the
# operator's ~/.claude/handover/bridge or ~/.claude/channels/telegram — a
# fake `bun` on PATH plus a sandboxed HOME/BRIDGE_ROOT/BRIDGE_LOCK_DIR AND a
# sandboxed --repo root stand in for everything real. Cases that genuinely
# cannot run on this host (no `flock`) SKIP, printing why, rather than faking
# a pass.
#
# HIMMEL-2551 added three things here, after this suite was proven to SIGKILL
# the operator's live production bridge while reporting "17 passed, 0 failed":
#   * its own fixture repo root ($WORK/repo) — the launcher scopes kills to the
#     launching instance's $repo/scripts/telegram, so sharing the real checkout
#     made the fixture's bridge dir identical to production's;
#   * a foreign-bridge case (a decoy `bun supervisor.ts` running from ANOTHER
#     bridge dir must survive our `stop`), with a red-control.sh mutation
#     control proving that case is non-vacuous;
#   * cases for the HIMMEL_TEST_FIXTURE=1 refusals (rc=3): no BRIDGE_ROOT, and
#     --repo pointing at the launcher's own checkout.
# CR rounds added the rest, and the last three are a matched set — they pin the
# two identity sources against each other, which is where every earlier round
# of this ticket went wrong by fixing one and breaking the other:
#   * FOREIGN (different root AND checkout): survives start and stop, and the
#     launcher WARNS rather than passing over it silently;
#   * SHARED ROOT (our ledger, foreign cwd, entry written after the process
#     started): IS swept — otherwise a worktree and the primary checkout both
#     poll one token;
#   * RECYCLED PID (our ledger, foreign cwd, process started AFTER the ledger
#     was written): is NOT swept.
# Staleness, not cwd, is what separates the last two — each has its own RED
# control mutating the freshness comparison in the opposite direction.
#
# Usage: bash scripts/telegram/test-restart-bridge.sh
set -uo pipefail

WORK=$(mktemp -d "${TMPDIR:-/tmp}/restart-bridge-test.XXXXXX") || exit 1
[ -n "$WORK" ] || exit 1

# capture_ps_ef — `ps -ef` with the widest CMD column available. BSD-derived
# ps (macOS) truncates the last (CMD) column to terminal width even when
# stdout is a pipe/file, which would truncate the fakebin paths this suite
# greps for; `-ww` requests unlimited width there. Not every `ps` accepts
# `-w` (this repo's Git Bash MSYS ps rejects it) — probe by trying `-ww`
# first and falling back to a bare `ps -ef` when it errors.
capture_ps_ef() {
  local out
  if out=$(ps -ww -ef 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  ps -ef 2>/dev/null
}

# shellcheck disable=SC2317,SC2329 # cleanup runs from a trap, so it only LOOKS unreachable
cleanup() {
  # best-effort: reap any fake-bun processes this run may have left behind
  # (a case that never called `stop` on its own). The fake bun's idle loop
  # sleeps in 1s ticks, so anything missed here self-terminates within ~1s
  # of its parent dying regardless.
  local pids=() p pat
  # Both trees: the fixture's own fake bun AND the decoy copy the
  # foreign-bridge case launches from a separate path (HIMMEL-2551). Two
  # literal -F sweeps rather than one regex — $WORK is an mktemp path and may
  # legitimately carry regex metacharacters.
  for pat in "$WORK/fakebin/bun" "$WORK/decoybin/bun" "$WORK/slowbin/stage2"; do
    # shellcheck disable=SC2009 # portable across GNU/BSD/MSYS ps -ef; pgrep is
    # inconsistent/absent on this repo's MSYS dev host.
    while IFS= read -r p; do [ -n "$p" ] && pids+=("$p"); done \
      < <(capture_ps_ef | grep -F "$pat" | grep -v grep | awk '{print $2}')
  done
  [ "${#pids[@]}" -gt 0 ] && { kill -9 "${pids[@]}" >/dev/null 2>&1 || true; }
  rm -rf "$WORK"
}
trap 'cleanup' EXIT

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/telegram/restart-bridge.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

export HOME="$WORK/home"
mkdir -p "$HOME"
export BRIDGE_ROOT="$WORK/bridge-root"
mkdir -p "$BRIDGE_ROOT"
export BRIDGE_LOCK_DIR="$WORK/locks"
mkdir -p "$BRIDGE_LOCK_DIR"
export TELEGRAM_BOT_TOKEN="test-fixture-token-0123456789abcdef"
unset HIMMEL_REPO 2>/dev/null || true

# The fixture's OWN repo root — never the real checkout. restart-bridge.sh
# scopes its kills to the launching instance's bridge dir
# ($repo/scripts/telegram), so a fixture passing the real $REPO_ROOT would
# share a bridge dir with the operator's production bridge and sweep it away
# (HIMMEL-2551, proven live). The fixture bridge dir MUST differ from any real
# one. Only the EXISTENCE of supervisor.ts is checked by the launcher, and the
# fake `bun` below never reads it, so an empty stub is enough.
FIXTURE_REPO="$WORK/repo"
FIXTURE_BRIDGE_DIR="$FIXTURE_REPO/scripts/telegram"
mkdir -p "$FIXTURE_BRIDGE_DIR"
: > "$FIXTURE_BRIDGE_DIR/supervisor.ts"

# Declare ourselves a test fixture. restart-bridge.sh REFUSES start/stop/run
# with rc=3 under this marker when BRIDGE_ROOT is unset — belt and braces for a
# fixture that sandboxes HOME but forgets the bridge root. Ours IS sandboxed
# (just above), so the guard correctly does not fire for the rest of the suite.
export HIMMEL_TEST_FIXTURE=1

FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/bun" <<'EOF'
#!/usr/bin/env bash
# Fake `bun` test double: `bun supervisor.ts` spawns a `bun poller.ts` child
# (mirroring the real supervisor.ts -> poller.ts relationship) and both idle
# in a tight sleep loop so a SIGKILL to the tracked pid takes effect within
# ~1s, never leaking a long-lived orphan.
set -u
case "${1:-}" in
  supervisor.ts)
    "$0" poller.ts &
    while :; do sleep 1; done
    ;;
  poller.ts)
    while :; do sleep 1; done
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/bun"
export PATH="$FAKE_BIN:$PATH"

# A SECOND copy of the same fake bun, on its own path, for the foreign-bridge
# case: its `ps` lines never collide with the $FAKE_BIN counts the rest of the
# suite polls on, so the two populations can be counted independently.
DECOY_BIN="$WORK/decoybin"
mkdir -p "$DECOY_BIN"
cp "$FAKE_BIN/bun" "$DECOY_BIN/bun"
chmod +x "$DECOY_BIN/bun"
DECOY_DIR="$WORK/decoy-root/scripts/telegram"
mkdir -p "$DECOY_DIR"
DECOY_PAT="$DECOY_BIN/bun"

# start_decoy — launch one decoy bridge (supervisor + its poller child) from
# the decoy root; sets $decoy_pid to the supervisor's pid. `exec` inside the
# subshell keeps $! the pid that ends up running the fake bun.
decoy_pid=""
start_decoy() {
  ( cd "$DECOY_DIR" && exec "$DECOY_BIN/bun" supervisor.ts ) >>"$WORK/decoy.log" 2>&1 &
  decoy_pid=$!
}

# decoy_poller_pid — the pid of the decoy's poller child.
decoy_poller_pid() {
  # shellcheck disable=SC2009 # see the trap cleanup comment above
  capture_ps_ef | grep -F -- "$DECOY_BIN/bun poller.ts" | grep -v grep | awk '{print $2}' | tail -n1
}

reap_decoys() {
  local dp
  # shellcheck disable=SC2009 # see the trap cleanup comment above
  for dp in $(capture_ps_ef | grep -F -- "$DECOY_PAT" | grep -v grep | awk '{print $2}'); do
    kill -9 "$dp" 2>/dev/null || true
  done
  poll_until "$DECOY_PAT" 0 15 >/dev/null
}

# plant_pidfile <supervisor-pid> [poller-pid] — forge OUR ledger so it records
# the decoy, the way a shared BRIDGE_ROOT genuinely would.
plant_pidfile() {
  if [ -n "${2:-}" ]; then
    printf '{"supervisor":%s,"poller":%s}' "$1" "$2" > "$BRIDGE_ROOT/supervisor.pid"
  else
    printf '{"supervisor":%s,"poller":null}' "$1" > "$BRIDGE_ROOT/supervisor.pid"
  fi
}

# age_pidfile <seconds-back> — back-date the PIDFILE (never the process: a
# process's start time cannot be faked) so a live decoy reads as having started
# AFTER the ledger was written — the recycled-pid shape. rc=1 when neither
# touch dialect is available, so the caller can SKIP rather than fake a pass.
age_pidfile() {
  local back="$1" ts stamp
  ts=$(( $(date +%s) - back ))
  touch -d "@$ts" "$BRIDGE_ROOT/supervisor.pid" 2>/dev/null && return 0   # GNU
  stamp=$(date -r "$ts" +%Y%m%d%H%M.%S 2>/dev/null) || return 1           # BSD
  touch -t "$stamp" "$BRIDGE_ROOT/supervisor.pid" 2>/dev/null
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
pass() { echo "PASS $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL $1 -- $2" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { echo "SKIP $1 -- $2" >&2; SKIP_COUNT=$((SKIP_COUNT + 1)); }
check() {
  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

# run_with_timeout <secs> <cmd...> — bounds a call to the script under test so
# a genuine hang never wedges the whole suite. Uses GNU `timeout` when
# present; otherwise a portable background+poll fallback (never assumes
# `timeout` exists — absent by default on macOS).
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  "$@" &
  local bg=$!
  local i=0
  while kill -0 "$bg" 2>/dev/null && [ "$i" -lt "$secs" ]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$bg" 2>/dev/null; then
    kill -9 "$bg" 2>/dev/null || true
    wait "$bg" 2>/dev/null
    return 124
  fi
  wait "$bg"
}

count_procs() {
  # count_procs <literal-substring> — number of live process lines containing
  # the substring (the fake bun always logs its FULL invoked path + arg, e.g.
  # "$FAKE_BIN/bun poller.ts", so a literal grep -F is exact and portable
  # across GNU/BSD/MSYS `ps -ef` column layouts).
  # shellcheck disable=SC2009 # see the trap cleanup comment above
  capture_ps_ef | grep -F -- "$1" | grep -v grep | grep -c . || true
}

poll_until() {
  # poll_until <substring> <expected-count> [max-attempts] — polls up to
  # ~(max-attempts * 0.2)s, printing the final observed count either way.
  local pattern="$1" expected="$2" max="${3:-30}" i=0 c
  while [ "$i" -lt "$max" ]; do
    c=$(count_procs "$pattern")
    [ "$c" = "$expected" ] && { printf '%s' "$c"; return 0; }
    i=$((i + 1))
    sleep 0.2
  done
  count_procs "$pattern"
}

start_bridge() { run_with_timeout 20 "$SCRIPT" --repo "$FIXTURE_REPO" start; }
stop_bridge()  { run_with_timeout 20 "$SCRIPT" --repo "$FIXTURE_REPO" stop; }
status_bridge(){ run_with_timeout 20 "$SCRIPT" --repo "$FIXTURE_REPO" status; }

POLLER_PAT="$FAKE_BIN/bun poller.ts"
SUPERVISOR_PAT="$FAKE_BIN/bun supervisor.ts"

# ── Case: double start -> exactly one poller survives ──────────────────────
start_bridge >"$WORK/log-start1.log" 2>&1
c1=$(poll_until "$POLLER_PAT" 1 30)
check "first start: exactly one poller" 1 "$c1"

start_bridge >"$WORK/log-start2.log" 2>&1
c2=$(poll_until "$POLLER_PAT" 1 30)
check "double start: exactly one poller survives after the 2nd start" 1 "$c2"
sc2=$(poll_until "$SUPERVISOR_PAT" 1 10)
check "double start: exactly one supervisor survives after the 2nd start" 1 "$sc2"

# ── Case: stop releases everything; status reports without side effects ────
status_bridge >"$WORK/log-status.log" 2>&1
status_rc=$?
check "status: exits 0" 0 "$status_rc"
c_after_status=$(count_procs "$POLLER_PAT")
check "status: does not touch running processes (poller count unchanged)" 1 "$c_after_status"

stop_bridge >"$WORK/log-stop.log" 2>&1
stop_rc=$?
check "stop: exits 0" 0 "$stop_rc"
c_after_stop=$(poll_until "$POLLER_PAT" 0 30)
check "stop: releases every poller" 0 "$c_after_stop"
sc_after_stop=$(poll_until "$SUPERVISOR_PAT" 0 10)
check "stop: releases every supervisor" 0 "$sc_after_stop"

# Lock released: a fresh non-blocking flock acquisition on the same path
# should succeed immediately once `stop` (and its own script process) exited.
# The redirection here is scoped to this ONE `flock` invocation, so the lock
# self-releases the moment the command returns — no separate unlock needed.
if command -v flock >/dev/null 2>&1; then
  TOKEN_LOCK=$("$SCRIPT" --print-lock-path)
  mkdir -p "$(dirname "$TOKEN_LOCK")"
  if flock -n -x 9 9>"$TOKEN_LOCK"; then
    pass "stop: lock is free for immediate re-acquisition afterward"
  else
    fail "stop: lock is free for immediate re-acquisition afterward" "flock -n failed — lock still held"
  fi
else
  skip "stop: lock is free for immediate re-acquisition afterward" "no 'flock' on PATH on this host"
fi

# ── Case: stale-PROC kill — an orphaned poller (no supervisor) is killed on start ──
# Launched with cwd = the FIXTURE bridge dir, which is both what instance
# scoping requires (HIMMEL-2551) and more faithful: a real orphan was started
# by a previous start_verb, so it carries exactly that cwd. `exec` inside the
# subshell keeps $! the pid that ends up running the fake bun.
( cd "$FIXTURE_BRIDGE_DIR" && exec "$FAKE_BIN/bun" poller.ts ) >"$WORK/orphan.log" 2>&1 &
orphan_pid=$!
orphan_seen=$(poll_until "$POLLER_PAT" 1 30)
check "orphan setup: fake orphan poller is alive before start" 1 "$orphan_seen"

start_bridge >"$WORK/log-start3.log" 2>&1
sleep 0.3
if kill -0 "$orphan_pid" 2>/dev/null; then
  fail "stale-proc kill: the pre-existing orphan poller pid is gone after start" "pid $orphan_pid still alive"
else
  pass "stale-proc kill: the pre-existing orphan poller pid is gone after start"
fi
c3=$(poll_until "$POLLER_PAT" 1 30)
check "stale-proc kill: exactly one (fresh) poller survives after start" 1 "$c3"

stop_bridge >"$WORK/log-stop2.log" 2>&1
poll_until "$POLLER_PAT" 0 30 >/dev/null
poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

# ── Case: lock path carries a token HASH, never raw token material ─────────
TOKEN_LOCK=$("$SCRIPT" --print-lock-path)
if [ -n "$TOKEN_LOCK" ]; then pass "--print-lock-path: prints a non-empty path"; else fail "--print-lock-path: prints a non-empty path" "empty output"; fi

case "$TOKEN_LOCK" in
  *"$TELEGRAM_BOT_TOKEN"*)
    fail "lock path never contains the raw token" "path='$TOKEN_LOCK' contains the fixture token"
    ;;
  *)
    pass "lock path never contains the raw token"
    ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  EXPECTED_HASH=$(printf '%s' "$TELEGRAM_BOT_TOKEN" | sha256sum | awk '{print $1}' | cut -c1-16)
elif command -v shasum >/dev/null 2>&1; then
  EXPECTED_HASH=$(printf '%s' "$TELEGRAM_BOT_TOKEN" | shasum -a 256 | awk '{print $1}' | cut -c1-16)
else
  EXPECTED_HASH=""
fi
if [ -n "$EXPECTED_HASH" ]; then
  EXPECTED_PATH="$BRIDGE_LOCK_DIR/bridge-${EXPECTED_HASH}.lock"
  check "lock path matches the pinned <lockDir>/bridge-<hash16>.lock formula" "$EXPECTED_PATH" "$TOKEN_LOCK"
else
  skip "lock path matches the pinned formula" "no sha256sum/shasum on PATH to cross-check independently"
fi

# ── Case: a stale lock left by a killed holder does not wedge the next start ──
if command -v flock >/dev/null 2>&1; then
  # A SINGLE process holds the lock end-to-end (fork once, then `exec` into
  # `sleep` so the SAME pid keeps fd 9 open) — killing that one pid closes
  # its fd and releases the kernel-level flock immediately, the exact
  # "holder died" shape stale-lock recovery exists for. (Piping the lock
  # through `flock file -c cmd` instead would spawn `cmd` as a CHILD that
  # inherits — and can keep open — the same locked fd, so killing only the
  # parent would NOT reliably release it.)
  (
    exec 9>"$TOKEN_LOCK"
    flock -n 9 || exit 1
    exec sleep 999
  ) &
  holder_pid=$!
  sleep 0.5
  kill -9 "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  start_bridge >"$WORK/log-start4.log" 2>&1
  rc=$?
  check "stale lock from a killed holder does not wedge the next start (rc=0)" 0 "$rc"
  c4=$(poll_until "$POLLER_PAT" 1 30)
  check "stale lock: start still converges to exactly one poller" 1 "$c4"
  stop_bridge >"$WORK/log-stop3.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
else
  skip "stale lock from a killed holder does not wedge the next start" "no 'flock' on PATH on this host (MSYS/Windows Git Bash here) — the real target is Linux; flock's kernel-level release-on-exit is not exercisable without it"
fi

# ── Case: a FOREIGN bridge survives START's stale sweep (HIMMEL-2551) ─────
# start_verb's stale sweep is the PROVEN killer: it is what SIGKILLed the
# operator's live supervisor/poller (pids 1751090/1751099) while this suite
# reported all-green. The decoy runs `bun supervisor.ts` (which spawns its own
# poller.ts child) from ITS OWN bridge dir — exactly the shape of a second
# himmel checkout's real bridge, and exactly what the old machine-wide
# entrypoint-name matcher used to sweep away.
start_decoy
decoy_seen=$(poll_until "$DECOY_PAT" 2 30)
check "foreign-bridge setup: the decoy supervisor+poller are alive before start" 2 "$decoy_seen"

start_bridge >"$WORK/log-start-foreign.log" 2>&1
# Non-destructive signal: leaving a foreign bridge alone must be VISIBLE, not
# silent — the launcher no longer papers over a shared-token misconfiguration.
# The count is asserted as ">= our 2 decoys", never as an exact number: the
# warning legitimately also counts any OTHER bridge live on the host (an
# operator's real one included), which is the whole point of it, so an exact
# match would make this case depend on what else the machine is running.
warn_n=$(sed -n 's/.*left \([0-9][0-9]*\) bridge-shaped process(es) alone.*/\1/p' "$WORK/log-start-foreign.log" | tail -n1)
if [ -n "$warn_n" ] && [ "$warn_n" -ge 2 ]; then
  pass "foreign bridge: start WARNS that it left the foreign bridge process(es) alone (n=$warn_n >= our 2 decoys)"
else
  fail "foreign bridge: start WARNS that it left the foreign bridge process(es) alone" \
    "extracted n='$warn_n'; log said: $(tr '\n' '|' < "$WORK/log-start-foreign.log")"
fi
if grep -q "409 Conflict" "$WORK/log-start-foreign.log"; then
  pass "foreign bridge: the warning names the 409-conflict consequence of a shared token"
else
  fail "foreign bridge: the warning names the 409-conflict consequence of a shared token" \
    "log said: $(tr '\n' '|' < "$WORK/log-start-foreign.log")"
fi
decoy_after_start=$(count_procs "$DECOY_PAT")
check "foreign bridge: START's stale sweep leaves the decoy alone (count unchanged)" 2 "$decoy_after_start"
if kill -0 "$decoy_pid" 2>/dev/null; then
  pass "foreign bridge: the decoy's original supervisor pid is still alive after start"
else
  fail "foreign bridge: the decoy's original supervisor pid is still alive after start" "pid $decoy_pid is gone"
fi
# …and our own bridge still converged, so the sweep was not simply disabled.
cf1=$(poll_until "$POLLER_PAT" 1 30)
check "foreign bridge: our own start still converges to exactly one poller" 1 "$cf1"
cf2=$(poll_until "$SUPERVISOR_PAT" 1 10)
check "foreign bridge: our own start still converges to exactly one supervisor" 1 "$cf2"

# ── Case: a FOREIGN bridge survives our stop ──────────────────────────────
stop_bridge >"$WORK/log-stop-foreign.log" 2>&1
stop_foreign_rc=$?
check "foreign bridge: stop exits 0" 0 "$stop_foreign_rc"
# 'killed 2' is the non-vacuity half: stop really did kill OUR supervisor+poller
# in the very same call that left the decoy standing.
if grep -q "stop: killed 2 bridge process(es)" "$WORK/log-stop-foreign.log"; then
  pass "foreign bridge: stop reports 'killed 2' — it killed OUR bridge, not nothing"
else
  fail "foreign bridge: stop reports 'killed 2' — it killed OUR bridge, not nothing" \
    "log said: $(tr '\n' '|' < "$WORK/log-stop-foreign.log")"
fi
poll_until "$POLLER_PAT" 0 30 >/dev/null
poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
decoy_after=$(count_procs "$DECOY_PAT")
check "foreign bridge: the decoy survives our stop (count unchanged)" 2 "$decoy_after"
if kill -0 "$decoy_pid" 2>/dev/null; then
  pass "foreign bridge: the decoy's original supervisor pid is still alive after stop"
else
  fail "foreign bridge: the decoy's original supervisor pid is still alive after stop" "pid $decoy_pid is gone"
fi

# ── Case: with nothing of ours running, stop is a clean no-op ─────────────
# The decoy is still up; a machine-wide matcher would report killing it.
stop_bridge >"$WORK/log-stop-noop.log" 2>&1
if grep -q "stop: killed 0 bridge process(es)" "$WORK/log-stop-noop.log"; then
  pass "foreign bridge: a second stop reports 'killed 0' while the decoy is still up"
else
  fail "foreign bridge: a second stop reports 'killed 0' while the decoy is still up" \
    "log said: $(tr '\n' '|' < "$WORK/log-stop-noop.log")"
fi
decoy_after_noop=$(count_procs "$DECOY_PAT")
check "foreign bridge: the decoy survives the no-op stop too" 2 "$decoy_after_noop"

# ── Shared RED-control setup ───────────────────────────────────────────────
# Read by the sourced red-control.sh (where its stderr capture lands), not by
# this file — exported for the same reason scripts/lib/test-red-control.sh
# exports it, so the scratch capture stays inside $WORK and the EXIT trap reaps it.
RED_CONTROL_TMPDIR="$WORK"
export RED_CONTROL_TMPDIR
# shellcheck source=../lib/red-control.sh
. "$REPO_ROOT/scripts/lib/red-control.sh"

# SAFETY FENCE — shared by every control below, and deliberately NOT part of
# any mutation. Each mutant re-enables (or suppresses) a cross-instance
# decision, and the machine-wide one would SIGKILL the operator's real Telegram
# bridge: that is the bug under test, and a control must not reproduce it on a
# live machine. This stand-in `ps` runs the real one and passes through ONLY
# command lines under this fixture's scratch dir, so a mutant's candidate set
# can never contain anything real. It only ever REMOVES real processes; the
# decoy — the process the assertions are about — lives under $WORK and stays in
# the set, so each mutation is still fully exercised.
PS_FENCE="$WORK/psfence"
mkdir -p "$PS_FENCE"
REAL_PS=$(command -v ps)
# Only the CANDIDATE SCAN (`ps -ef`) is filtered. The launcher also runs
# per-pid `ps -o etimes=/-o lstart= -p <pid>` to date a ledger entry, and those
# must pass through untouched — filtering them made every timestamp
# undeterminable, which silently took ledger_entry_fresh's degrade path and
# made a mutant look green for the wrong reason. Passing them through cannot
# widen the blast radius: a per-pid query is only ever made about a pid that is
# already in the (filtered) candidate set, so it can never introduce a real
# process into the kill set.
cat > "$PS_FENCE/ps" <<EOF
#!/usr/bin/env bash
filter=0
for a in "\$@"; do if [ "\$a" = "-ef" ]; then filter=1; fi; done
if [ "\$filter" -eq 0 ]; then exec "$REAL_PS" "\$@"; fi
out=\$("$REAL_PS" "\$@" 2>/dev/null) || true
printf '%s\n' "\$out" | grep -F -- "$WORK/" || true
exit 0
EOF
chmod +x "$PS_FENCE/ps"

# mutant_killed_from_stdout — the count the mutant itself reported. Derived
# from its OWN stdout so red-control contract point (b), "it produced a value",
# is real rather than inferred from the process table alone.
mutant_killed_from_stdout() {
  printf '%s\n' "$RED_CONTROL_OUT" | sed -n 's/.*stop: killed \([0-9][0-9]*\) bridge process(es).*/\1/p' | tail -n1
}

# ── Case: a SHARED-ROOT bridge (our ledger, foreign cwd, live entry) IS swept ─
# The other half of instance scoping, and the ordinary local shape: a git
# worktree and the primary checkout share $HOME and therefore BRIDGE_ROOT, but
# have different bridge dirs. They share ONE supervisor.pid, so each must still
# sweep the other or both poll the same token. Planting BOTH decoy pids is what
# a real supervisor records. The pidfile is written AFTER the decoy started, so
# the entry is live, not stale.
decoy_poller=$(decoy_poller_pid)
plant_pidfile "$decoy_pid" "$decoy_poller"
stop_bridge >"$WORK/log-stop-sharedroot.log" 2>&1
if grep -q "stop: killed 2 bridge process(es)" "$WORK/log-stop-sharedroot.log"; then
  pass "shared root: a bridge recorded in OUR live ledger is swept despite a foreign cwd"
else
  fail "shared root: a bridge recorded in OUR live ledger is swept despite a foreign cwd" \
    "log said: $(tr '\n' '|' < "$WORK/log-stop-sharedroot.log")"
fi
sharedroot_after=$(poll_until "$DECOY_PAT" 0 15)
check "shared root: both recorded decoy processes are gone" 0 "$sharedroot_after"
rm -f "$BRIDGE_ROOT/supervisor.pid"

# ── RED control for the shared-root case ──────────────────────────────────
# Mutate the freshness comparison to `false`: every ledger entry then reads as
# stale, source (2) never fires, and the shared-root bridge is misclassified as
# foreign and left running — the duplicate-poller regression.
MUTANT_FRESH_FALSE="$WORK/mutant-fresh-false.sh"
# shellcheck disable=SC2016 # $started/$fresh_cutoff are literal text in the file being mutated
sed 's|^\( *\)\[ "\$started" -le "\$fresh_cutoff" \]$|\1false|' "$SCRIPT" > "$MUTANT_FRESH_FALSE"
if cmp -s "$SCRIPT" "$MUTANT_FRESH_FALSE"; then
  fail "RED control (shared root): the mutation actually applies" \
    "sed changed nothing — the freshness line '[ \"\$started\" -le \"\$fresh_cutoff\" ]' was not found in $SCRIPT. A no-op mutant is a BROKEN control, not evidence."
else
  pass "RED control (shared root): the mutation actually applies"
  start_decoy
  sr_seen=$(poll_until "$DECOY_PAT" 2 30)
  check "RED control (shared root) setup: a fresh decoy is alive" 2 "$sr_seen"
  plant_pidfile "$decoy_pid" "$(decoy_poller_pid)"
  red_control_run --env PATH="$PS_FENCE:$PATH" -- bash "$MUTANT_FRESH_FALSE" --repo "$FIXTURE_REPO" stop
  sr_killed=$(mutant_killed_from_stdout)
  sr_after=$(poll_until "$DECOY_PAT" 0 15)
  if red_control_assert \
      --label "RED control (a live shared-root ledger entry IS ours)" \
      --observed     "killed=$sr_killed decoy_after=$sr_after" \
      --expect-wrong "killed=0 decoy_after=2" \
      --correct      "killed=2 decoy_after=0" \
      --note "with every ledger entry treated as stale, a worktree and the primary checkout stop seeing each other and both poll one token"; then
    pass "RED control (shared root): the sweep assertion is non-vacuous"
  else
    fail "RED control (shared root): the sweep assertion is non-vacuous" "see the RED-control FAIL line above"
  fi
  rm -f "$BRIDGE_ROOT/supervisor.pid"
  reap_decoys
fi

# ── Case: an UNDETERMINABLE freshness verdict cannot override a foreign cwd ─
# The degrade exists so a host with neither cwd nor timestamps can still stop
# its own bridge — not so that a ledger entry outranks cwd evidence we DO have.
# Simulated by stubbing `stat` (both the GNU and BSD forms fail), the same
# stand-in-on-PATH shape the fake `bun` and the ps fence already use. The pair
# is what makes it non-vacuous: identical state, one env difference — with the
# stub the decoy SURVIVES, without it the very same decoy IS swept.
#
# Not exercisable here, and named rather than glossed: the OTHER arm (cwd
# unreadable AND freshness undeterminable, which still licenses ownership) has
# no hermetic simulation on Linux — /proc/<pid>/cwd is genuinely readable for
# our own processes and cannot be hidden without root.
STAT_STUB="$WORK/statstub"
mkdir -p "$STAT_STUB"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STAT_STUB/stat"
chmod +x "$STAT_STUB/stat"

start_decoy
degrade_seen=$(poll_until "$DECOY_PAT" 2 30)
check "degrade setup: a fresh decoy is alive" 2 "$degrade_seen"
plant_pidfile "$decoy_pid" "$(decoy_poller_pid)"

# `env` rather than a subshell PATH assignment: it puts the stub in front for
# exactly this one invocation without the suite's own PATH ever changing.
degrade_out=$(run_with_timeout 20 env PATH="$STAT_STUB:$PATH" bash "$SCRIPT" --repo "$FIXTURE_REPO" stop 2>&1)
case "$degrade_out" in
  *"stop: killed 0 bridge process(es)"*)
    pass "undeterminable freshness: a ledger entry does NOT override a readable, foreign cwd"
    ;;
  *)
    fail "undeterminable freshness: a ledger entry does NOT override a readable, foreign cwd" \
      "output was: $(printf '%s' "$degrade_out" | tr '\n' '|')"
    ;;
esac
degrade_after=$(count_procs "$DECOY_PAT")
check "undeterminable freshness: the decoy survives" 2 "$degrade_after"

# The discriminating half: same decoy, same ledger, WITHOUT the stub it is
# swept — so the survival above is the degrade narrowing, not a dead fixture.
stop_bridge >"$WORK/log-stop-degrade-control.log" 2>&1
if grep -q "stop: killed 2 bridge process(es)" "$WORK/log-stop-degrade-control.log"; then
  pass "undeterminable freshness (control): with timestamps readable, the same decoy IS swept"
else
  fail "undeterminable freshness (control): with timestamps readable, the same decoy IS swept" \
    "log said: $(tr '\n' '|' < "$WORK/log-stop-degrade-control.log")"
fi
degrade_control_after=$(poll_until "$DECOY_PAT" 0 15)
check "undeterminable freshness (control): the decoy is gone" 0 "$degrade_control_after"
rm -f "$BRIDGE_ROOT/supervisor.pid"

# ── Case: the pidfile mtime is read ONCE per scan, not once per candidate ──
# The caching half of the read-order fix, and the half that IS observable from
# outside: a counting `stat` stub records every invocation. With the mtime
# captured once by the scan there is exactly ONE; when ledger_entry_fresh
# stat'ed the file itself there was one per ledger-matched candidate, which is
# 2 here (both decoy pids are planted). So the count discriminates.
#
# The ORDERING half — mtime before contents — is deliberately NOT asserted
# here: reproducing a mid-scan rewrite needs a stub that mutates the pidfile
# between the two reads, and such a case would be asserting the stub's
# behaviour rather than the launcher's. It rests on the argument recorded in
# list_bridge_pids' comment instead.
STAT_COUNT_DIR="$WORK/statcount"
mkdir -p "$STAT_COUNT_DIR"
STAT_COUNT_FILE="$WORK/stat-calls.txt"
REAL_STAT=$(command -v stat)
if [ -n "$REAL_STAT" ]; then
  cat > "$STAT_COUNT_DIR/stat" <<EOF
#!/usr/bin/env bash
printf 'call\n' >> "$STAT_COUNT_FILE"
exec "$REAL_STAT" "\$@"
EOF
  chmod +x "$STAT_COUNT_DIR/stat"

  start_decoy
  statc_seen=$(poll_until "$DECOY_PAT" 2 30)
  check "stat-count setup: a fresh decoy is alive" 2 "$statc_seen"
  plant_pidfile "$decoy_pid" "$(decoy_poller_pid)"
  : > "$STAT_COUNT_FILE"
  run_with_timeout 20 env PATH="$STAT_COUNT_DIR:$PATH" bash "$SCRIPT" --repo "$FIXTURE_REPO" stop >"$WORK/log-statcount.log" 2>&1
  stat_calls=$(grep -c . "$STAT_COUNT_FILE" 2>/dev/null || true)
  check "read-once: one 'stop' scan stats the pidfile exactly once" 1 "$stat_calls"
  rm -f "$BRIDGE_ROOT/supervisor.pid"
  reap_decoys
else
  skip "read-once: one 'stop' scan stats the pidfile exactly once" \
    "no 'stat' on PATH to wrap with a counting stub on this host"
fi

# ── Case: a STALE ledger entry (recycled pid) is NOT swept ────────────────
# The recycling shape: our supervisor died, its pid was reused by ANOTHER
# checkout's supervisor, so that pid is a live bridge candidate AND still sits
# in our ledger. Distinguished from the shared-root case above by ONE fact —
# the process started AFTER the ledger was written. We age the PIDFILE rather
# than fake the process: a real process's start time cannot be forged.
start_decoy
recycled_seen=$(poll_until "$DECOY_PAT" 2 30)
check "recycled-pid setup: a fresh decoy is alive" 2 "$recycled_seen"
start_bridge >"$WORK/log-start-recycled.log" 2>&1
poll_until "$POLLER_PAT" 1 30 >/dev/null
plant_pidfile "$decoy_pid"
if age_pidfile 300; then
  stop_bridge >"$WORK/log-stop-recycled.log" 2>&1
  if grep -q "stop: killed 2 bridge process(es)" "$WORK/log-stop-recycled.log"; then
    pass "recycled pid: our own bridge is still swept in the same call"
  else
    fail "recycled pid: our own bridge is still swept in the same call" \
      "log said: $(tr '\n' '|' < "$WORK/log-stop-recycled.log")"
  fi
  recycled_after=$(count_procs "$DECOY_PAT")
  check "recycled pid: a ledger entry whose process started AFTER the pidfile survives" 2 "$recycled_after"
  if kill -0 "$decoy_pid" 2>/dev/null; then
    pass "recycled pid: the planted decoy pid itself is still alive after stop"
  else
    fail "recycled pid: the planted decoy pid itself is still alive after stop" "pid $decoy_pid is gone"
  fi

  # ── RED control for the recycled-pid case ──────────────────────────────
  # Mutate the same freshness comparison the other way — to `true`: every
  # ledger entry then reads as live, and the recycled pid is claimed and
  # killed. Only the supervisor pid was planted, so the poller (foreign cwd,
  # not in the ledger) stays: killed=1 / decoy_after=1.
  MUTANT_FRESH_TRUE="$WORK/mutant-fresh-true.sh"
  # shellcheck disable=SC2016 # $started/$fresh_cutoff are literal text in the file being mutated
  sed 's|^\( *\)\[ "\$started" -le "\$fresh_cutoff" \]$|\1true|' "$SCRIPT" > "$MUTANT_FRESH_TRUE"
  if cmp -s "$SCRIPT" "$MUTANT_FRESH_TRUE"; then
    fail "RED control (recycled pid): the mutation actually applies" \
      "sed changed nothing — the freshness line was not found in $SCRIPT. A no-op mutant is a BROKEN control, not evidence."
  else
    pass "RED control (recycled pid): the mutation actually applies"
    red_control_run --env PATH="$PS_FENCE:$PATH" -- bash "$MUTANT_FRESH_TRUE" --repo "$FIXTURE_REPO" stop
    rc_killed=$(mutant_killed_from_stdout)
    rc_after=$(poll_until "$DECOY_PAT" 1 15)
    if red_control_assert \
        --label "RED control (a stale ledger entry is NOT ours)" \
        --observed     "killed=$rc_killed decoy_after=$rc_after" \
        --expect-wrong "killed=1 decoy_after=1" \
        --correct      "killed=0 decoy_after=2" \
        --note "without the staleness check, a ledger entry whose pid was recycled by ANOTHER checkout's supervisor licenses SIGKILLing it"; then
      pass "RED control (recycled pid): the staleness assertion is non-vacuous"
    else
      fail "RED control (recycled pid): the staleness assertion is non-vacuous" "see the RED-control FAIL line above"
    fi
  fi
else
  skip "recycled pid: a ledger entry whose process started AFTER the pidfile survives" \
    "neither 'touch -d @<epoch>' (GNU) nor 'date -r <epoch>' + 'touch -t' (BSD) works on this host, so the pidfile cannot be aged; faking the PROCESS start time instead would test nothing"
  stop_bridge >"$WORK/log-stop-recycled.log" 2>&1
fi
rm -f "$BRIDGE_ROOT/supervisor.pid"
poll_until "$POLLER_PAT" 0 30 >/dev/null
poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
reap_decoys

# ── RED control: the machine-wide matcher (the original HIMMEL-2551 bug) ───
# With no ledger entry at all, the decoy is foreign purely by cwd. Neutering
# the cwd comparison restores the pre-HIMMEL-2551 behaviour that SIGKILLed the
# operator's live bridge.
start_decoy
mw_seen=$(poll_until "$DECOY_PAT" 2 30)
check "machine-wide control setup: a fresh decoy is alive" 2 "$mw_seen"
MUTANT="$WORK/mutant-restart-bridge.sh"
# shellcheck disable=SC2016 # the single quotes are REQUIRED: $cwd/$BRIDGE_DIR_REAL
# are literal text in the file being mutated, not variables to expand here.
sed 's|^\( *\)\[ "\$cwd" = "\$BRIDGE_DIR_REAL" \]$|\1true|' "$SCRIPT" > "$MUTANT"
if cmp -s "$SCRIPT" "$MUTANT"; then
  fail "RED control (foreign bridge): the mutation actually applies" \
    "sed changed nothing — the ownership line '[ \"\$cwd\" = \"\$BRIDGE_DIR_REAL\" ]' was not found in $SCRIPT. A no-op mutant is a BROKEN control, not evidence."
else
  pass "RED control (foreign bridge): the mutation actually applies"
  red_control_run --env PATH="$PS_FENCE:$PATH" -- bash "$MUTANT" --repo "$FIXTURE_REPO" stop
  mutant_killed=$(mutant_killed_from_stdout)
  mutant_decoy_after=$(poll_until "$DECOY_PAT" 0 15)
  if red_control_assert \
      --label "RED control (foreign bridge survives stop)" \
      --observed     "killed=$mutant_killed decoy_after=$mutant_decoy_after" \
      --expect-wrong "killed=2 decoy_after=0" \
      --correct      "killed=0 decoy_after=2" \
      --note "WITHOUT the instance check, stop falls back to the machine-wide entrypoint-name matcher and SIGKILLs another checkout's bridge — the HIMMEL-2551 bug"; then
    pass "RED control (foreign bridge): the survival assertion is non-vacuous"
  else
    fail "RED control (foreign bridge): the survival assertion is non-vacuous" "see the RED-control FAIL line above"
  fi
fi
reap_decoys

# ── Case: the HIMMEL_TEST_FIXTURE guard refuses an un-sandboxed bridge root ─
# HOME is already the sandbox, so the default root this WOULD have used is
# $WORK/home/.claude/handover/bridge — nothing real is ever involved.
for guard_verb in stop start; do
  guard_out=$(env -u BRIDGE_ROOT HIMMEL_TEST_FIXTURE=1 bash "$SCRIPT" --repo "$FIXTURE_REPO" "$guard_verb" 2>&1)
  guard_rc=$?
  check "fixture guard: '$guard_verb' with HIMMEL_TEST_FIXTURE=1 and no BRIDGE_ROOT exits 3" 3 "$guard_rc"
  case "$guard_out" in
    *"REFUSING '$guard_verb'"*handover/bridge*)
      pass "fixture guard: '$guard_verb' refusal names the verb and the default root it would have used"
      ;;
    *)
      fail "fixture guard: '$guard_verb' refusal names the verb and the default root it would have used" \
        "output was: $(printf '%s' "$guard_out" | tr '\n' '|')"
      ;;
  esac
done

# ── Case: the fixture guard also refuses --repo at the script's own checkout ─
# The second limb of the guard: BRIDGE_ROOT sandboxed but --repo pointing at
# the checkout the launcher itself lives in, so the cwd identity source would
# select THAT checkout's real bridge processes. Exercised against a scratch
# COPY of the launcher rather than the repo's own — the condition under test is
# path equality between $BRIDGE_DIR_REAL and the script's own directory, and
# probing it with the real checkout's path is precisely the kill this guard
# exists to prevent, so it is never used as a fixture input.
SELF_REPO="$WORK/selfrepo"
mkdir -p "$SELF_REPO/scripts/telegram"
cp "$SCRIPT" "$SELF_REPO/scripts/telegram/restart-bridge.sh"
: > "$SELF_REPO/scripts/telegram/supervisor.ts"
for self_verb in stop start run; do
  self_out=$(run_with_timeout 20 bash "$SELF_REPO/scripts/telegram/restart-bridge.sh" --repo "$SELF_REPO" "$self_verb" 2>&1)
  self_rc=$?
  check "fixture guard: '$self_verb' refuses when --repo is the launcher's own checkout (rc=3)" 3 "$self_rc"
  case "$self_out" in
    *"the checkout this script itself lives in"*)
      pass "fixture guard: '$self_verb' refusal names both the target and the script's own bridge dir"
      ;;
    *)
      fail "fixture guard: '$self_verb' refusal names both the target and the script's own bridge dir" \
        "output was: $(printf '%s' "$self_out" | tr '\n' '|')"
      ;;
  esac
done

# ── Case: the fixture guard refuses ANY real checkout, not just our own ────
# A fixture aimed at a DIFFERENT clone passes the own-checkout comparison and
# would still kill that clone's live bridge by cwd. The general limb is "inside
# a git work tree". Exercised against a THROWAWAY `git init` repo under $WORK —
# never a real checkout, since pointing a test at one is the very kill this
# guard exists to prevent.
if command -v git >/dev/null 2>&1; then
  GIT_REPO="$WORK/gitrepo"
  mkdir -p "$GIT_REPO/scripts/telegram"
  : > "$GIT_REPO/scripts/telegram/supervisor.ts"
  if git -C "$GIT_REPO" init -q >/dev/null 2>&1; then
    # The assertion that would have caught the fail-open: the refusal must not
    # depend on a working `git`. A stub that always fails stands in for both
    # "git broken" and "git absent" — the check walks up looking for `.git`
    # itself and never shells out, so the two are the same to it. Under the
    # previous `git rev-parse` implementation this invocation was ALLOWED.
    GIT_STUB="$WORK/gitstub"
    mkdir -p "$GIT_STUB"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$GIT_STUB/git"
    chmod +x "$GIT_STUB/git"
    nogit_out=$(run_with_timeout 20 env PATH="$GIT_STUB:$PATH" bash "$SCRIPT" --repo "$GIT_REPO" stop 2>&1)
    nogit_rc=$?
    check "fixture guard: refuses a git work tree even with 'git' unusable (rc=3)" 3 "$nogit_rc"
    case "$nogit_out" in
      *"is inside a git work tree"*)
        pass "fixture guard: the git-less refusal is the work-tree one, not an unrelated error"
        ;;
      *)
        fail "fixture guard: the git-less refusal is the work-tree one, not an unrelated error" \
          "output was: $(printf '%s' "$nogit_out" | tr '\n' '|')"
        ;;
    esac

    for git_verb in stop start run; do
      git_out=$(run_with_timeout 20 bash "$SCRIPT" --repo "$GIT_REPO" "$git_verb" 2>&1)
      git_rc=$?
      check "fixture guard: '$git_verb' refuses a --repo inside a git work tree (rc=3)" 3 "$git_rc"
      case "$git_out" in
        *"is inside a git work tree"*)
          pass "fixture guard: '$git_verb' refusal names the git-work-tree condition"
          ;;
        *)
          fail "fixture guard: '$git_verb' refusal names the git-work-tree condition" \
            "output was: $(printf '%s' "$git_out" | tr '\n' '|')"
          ;;
      esac
    done
    # The discrimination, not merely that something refuses: the fixture's OWN
    # repo root is not a git repo and must still be ALLOWED.
    if git -C "$FIXTURE_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      skip "fixture guard: the fixture's own (non-git) repo root is still allowed" \
        "\$WORK itself is inside a git work tree on this host, so the fixture repo cannot demonstrate the negative"
    else
      allow_rc=0
      stop_bridge >"$WORK/log-guard-allow.log" 2>&1 || allow_rc=$?
      check "fixture guard: the fixture's own (non-git) repo root is still allowed (stop exits 0)" 0 "$allow_rc"
    fi
  else
    skip "fixture guard: refuses a --repo inside a git work tree" \
      "'git init' failed in the scratch repo on this host — only the FIXTURE needs git to build a faithful work tree; the guard itself never shells out to it"
  fi
else
  skip "fixture guard: refuses a --repo inside a git work tree" \
    "no 'git' on PATH to build the scratch work tree this case needs — the guard itself is pure shell and unconditional, so this is a fixture limitation, not a gap in the check"
fi

# The complement, asserted once explicitly rather than only implied by the rest
# of the suite: with BRIDGE_ROOT sandboxed, the same marker changes nothing.
guard_ok_rc=0
stop_bridge >"$WORK/log-guard-ok.log" 2>&1 || guard_ok_rc=$?
check "fixture guard: does NOT fire while BRIDGE_ROOT is sandboxed (stop still exits 0)" 0 "$guard_ok_rc"

# ── Case: `run` execs the supervisor in the FOREGROUND (systemd Type=simple) ─
# The unit's whole shape depends on this path: Type=simple tracks ExecStart's
# own process as MAINPID, so `run` is only honest if the launcher BECOMES the
# supervisor. Backgrounded directly rather than through run_with_timeout —
# `run` is a daemon that never returns, and the wrapper's extra `timeout`
# process would break exactly the pid identity being asserted. The bounded
# poll below is the hang guard; the `stop` that follows uses run_with_timeout,
# which is where a genuine deadlock regression would show.
"$SCRIPT" --repo "$FIXTURE_REPO" run >"$WORK/log-run.log" 2>&1 &
run_pid=$!
run_args=""
run_i=0
while [ "$run_i" -lt 40 ]; do
  run_args=$(ps -o args= -p "$run_pid" 2>/dev/null) || run_args=""
  case "$run_args" in
    *"$FAKE_BIN/bun"*supervisor.ts*) break ;;
  esac
  run_i=$((run_i + 1))
  sleep 0.2
done
case "$run_args" in
  *"$FAKE_BIN/bun"*supervisor.ts*)
    pass "run: the launcher process BECOMES the supervisor (exec preserves the pid — the MAINPID contract)"
    ;;
  *)
    fail "run: the launcher process BECOMES the supervisor (exec preserves the pid — the MAINPID contract)" \
      "pid $run_pid args='$run_args'; log: $(tr '\n' '|' < "$WORK/log-run.log")"
    ;;
esac

# fd 200 must NOT survive the exec: a leaked lock fd keeps the flock's
# open-file-description alive for the bridge's whole lifetime and deadlocks the
# next `stop`. (With no `flock` on the host fd 200 is never opened at all, so
# this reads as absent either way — still the correct observation.)
if [ -d "/proc/$run_pid/fd" ]; then
  if [ -e "/proc/$run_pid/fd/200" ]; then
    fail "run: the lock fd 200 is not leaked into the exec'd supervisor" "/proc/$run_pid/fd/200 still exists"
  else
    pass "run: the lock fd 200 is not leaked into the exec'd supervisor"
  fi
elif command -v lsof >/dev/null 2>&1; then
  if [ -n "$(lsof -p "$run_pid" -d 200 -Fn 2>/dev/null)" ]; then
    fail "run: the lock fd 200 is not leaked into the exec'd supervisor" "lsof still reports fd 200 open on pid $run_pid"
  else
    pass "run: the lock fd 200 is not leaked into the exec'd supervisor"
  fi
else
  skip "run: the lock fd 200 is not leaked into the exec'd supervisor" \
    "no /proc and no 'lsof' on this host — a process's open fds are not observable here, and asserting anything weaker would not be this property"
fi

# A following `stop` must return promptly. If the fd HAD leaked, its blocking
# `flock 200` would hang until run_with_timeout kills it at rc=124.
run_with_timeout 20 "$SCRIPT" --repo "$FIXTURE_REPO" stop >"$WORK/log-stop-run.log" 2>&1
stop_after_run_rc=$?
check "run: a following stop returns rc=0 rather than deadlocking on the lock" 0 "$stop_after_run_rc"
poll_until "$POLLER_PAT" 0 30 >/dev/null
run_left=$(poll_until "$SUPERVISOR_PAT" 0 10)
check "run: stop reaps the foreground supervisor it started" 0 "$run_left"
kill -9 "$run_pid" 2>/dev/null || true
wait "$run_pid" 2>/dev/null || true

# ── LAUNCH HANDOFF (HIMMEL-2556) fixture: the "slow double" ────────────────
# The reproduction needs a launched process that is ALIVE but whose `ps`
# cmdline does not match list_bridge_pids' `*bun*` candidate filter for a few
# seconds, then becomes a genuine fake-bun supervisor WITH THE SAME PID —
# simulating the real handoff window where `nohup`/`exec` has already made
# the future supervisor a live process, but bun itself has not yet run.
#
#   $SLOWBIN/bun (what `command -v bun` resolves to when $SLOWBIN leads PATH):
#     exec -a "$WORK/handoff-placeholder" bash "$SLOWBIN/stage2" "$@"
#   $SLOWBIN/stage2:
#     sleep $SLOW_SECS; exec "$FAKE_BIN/bun" "$@"
#
# Two facts make this work, both confirmed by exercising the fixture rather
# than assumed:
#   * `exec -a NAME` is HONORED here because bash is being exec'd directly —
#     not through its OWN shebang. Had stage2 instead been exec'd directly
#     (skipping the `bash "$SLOWBIN/stage2"` indirection), the kernel's
#     shebang handling would replace argv[0] with the script's own path,
#     discarding the requested name — which is exactly why stage2 is invoked
#     as `bash $SLOWBIN/stage2` and not as `$SLOWBIN/stage2` directly.
#   * neither the placeholder argv[0] nor the stage2 path may contain the
#     substring "bun" — list_bridge_pids' very first filter is
#     `case "$line" in *bun*) ;; *) continue ;; esac`, so either one
#     containing "bun" would make the "slow" half indistinguishable from an
#     already-visible bridge process and defeat the whole fixture. Both paths
#     derive from $WORK (an mktemp path), so the gate below — refusing to
#     build the fixture at all when $WORK itself contains "bun" — is
#     sufficient to guarantee neither derived path does either.
# Every case built on this fixture is gated on RACE_OK and SKIPs with
# RACE_SKIP_REASON when it is 0, rather than faking a pass.
RACE_OK=1
RACE_SKIP_REASON=""
if ! command -v flock >/dev/null 2>&1; then
  RACE_OK=0
  RACE_SKIP_REASON="no 'flock' on PATH on this host — without a real lock there is no serialization for a launch-handoff race to close, and these cases would be faking a pass rather than testing a degraded (documented) mode"
fi
case "$WORK" in
  *bun*)
    RACE_OK=0
    RACE_SKIP_REASON="\$WORK ($WORK) contains the substring 'bun', which would make the slow-double's derived paths match list_bridge_pids' *bun* candidate filter and defeat the fixture"
    ;;
esac

SLOW_SECS=6
SLOWBIN="$WORK/slowbin"
if [ "$RACE_OK" -eq 1 ]; then
  mkdir -p "$SLOWBIN"
  cat > "$SLOWBIN/bun" <<EOF
#!/usr/bin/env bash
exec -a "$WORK/handoff-placeholder" bash "$SLOWBIN/stage2" "\$@"
EOF
  chmod +x "$SLOWBIN/bun"
  cat > "$SLOWBIN/stage2" <<EOF
#!/usr/bin/env bash
sleep $SLOW_SECS
exec "$FAKE_BIN/bun" "\$@"
EOF
  chmod +x "$SLOWBIN/stage2"
  # VERIFY the generated files by observation, not assumption: both must have
  # actually interpolated $WORK/$SLOWBIN/$FAKE_BIN (an unquoted heredoc, so
  # they should have) rather than carrying a literal, never-expanded '$WORK'.
  # shellcheck disable=SC2016 # deliberate: searching for a LITERAL '$WORD'
  # left unexpanded in the generated files, not something meant to expand here
  if grep -q '\$WORK\|\$SLOWBIN\|\$FAKE_BIN' "$SLOWBIN/bun" "$SLOWBIN/stage2" 2>/dev/null; then
    RACE_OK=0
    RACE_SKIP_REASON="the slow-double fixture files still contain a literal, unexpanded \$WORK/\$SLOWBIN/\$FAKE_BIN — interpolation did not happen as expected"
  else
    pass "launch-handoff fixture: the slow-double files interpolate \$WORK/\$FAKE_BIN correctly (verified by reading them back)"
  fi
fi

# ── Case R1: start vs start during the handoff window, RED-controlled ─────
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-r1-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  # Launcher A: the SLOW bun, so its own script process (and the lock it
  # holds) exits long before its child becomes a visible `bun supervisor.ts`.
  ( PATH="$SLOWBIN:$PATH" run_with_timeout 20 "$SCRIPT" --repo "$FIXTURE_REPO" start ) >"$WORK/log-r1-a.log" 2>&1 &
  r1_a_bg=$!
  wait "$r1_a_bg"
  r1_a_rc=$?
  check "R1 setup: launcher A (slow double) exits 0" 0 "$r1_a_rc"

  r1_a_marker_pid=""
  if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
    r1_a_marker_content=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
    r1_a_marker_pid="${r1_a_marker_content%% *}"
  fi
  r1_a_super_now=$(count_procs "$SUPERVISOR_PAT")

  if [ "$r1_a_super_now" -eq 0 ] && [ -n "$r1_a_marker_pid" ]; then
    pass "R1 setup: the handoff window is open (no visible supervisor yet, marker present)"

    r1_b_rc=0
    start_bridge >"$WORK/log-r1-b.log" 2>&1 || r1_b_rc=$?

    # Wait out the slow double's sleep plus slack, then count.
    sleep $((SLOW_SECS + 2))
    r1_supers=$(poll_until "$SUPERVISOR_PAT" 1 30)
    r1_pollers=$(poll_until "$POLLER_PAT" 1 30)

    if [ "$r1_b_rc" = "4" ] && [ "$r1_supers" = "1" ] && [ "$r1_pollers" = "1" ]; then
      pass "R1: a concurrent start during the handoff window is refused (rc=4); exactly one supervisor/poller survive (observed rc=$r1_b_rc supervisors=$r1_supers pollers=$r1_pollers)"
    else
      fail "R1: a concurrent start during the handoff window is refused (rc=4); exactly one supervisor/poller survive" \
        "observed rc=$r1_b_rc supervisors=$r1_supers pollers=$r1_pollers"
    fi

    stop_bridge >"$WORK/log-r1-cleanup-stop.log" 2>&1
    poll_until "$POLLER_PAT" 0 30 >/dev/null
    poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

    # ── RED control for R1 ─────────────────────────────────────────────
    MUTANT_R1="$WORK/mutant-r1-no-guard.sh"
    sed 's|^\( *\)refuse_if_launch_in_progress$|\1:|' "$SCRIPT" > "$MUTANT_R1"
    if cmp -s "$SCRIPT" "$MUTANT_R1"; then
      fail "RED control (R1 launch handoff): the mutation actually applies" \
        "sed changed nothing — the bare 'refuse_if_launch_in_progress' call was not found in $SCRIPT. A no-op mutant is a BROKEN control, not evidence."
    else
      pass "RED control (R1 launch handoff): the mutation actually applies"

      stop_bridge >"$WORK/log-r1-red-pre-stop.log" 2>&1
      poll_until "$POLLER_PAT" 0 30 >/dev/null
      poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

      # Launcher A again for the control run — plain PATH is fine per the
      # brief; only launcher B (the mutant) must be fenced against real host
      # processes.
      ( PATH="$SLOWBIN:$PATH" run_with_timeout 20 "$SCRIPT" --repo "$FIXTURE_REPO" start ) >"$WORK/log-r1-red-a.log" 2>&1 &
      r1_red_a_bg=$!
      wait "$r1_red_a_bg"

      r1_red_a_super_now=$(count_procs "$SUPERVISOR_PAT")
      r1_red_a_marker_pid=""
      if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
        r1_red_a_marker_content=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
        r1_red_a_marker_pid="${r1_red_a_marker_content%% *}"
      fi

      if [ "$r1_red_a_super_now" -eq 0 ] && [ -n "$r1_red_a_marker_pid" ]; then
        red_control_run --env PATH="$PS_FENCE:$PATH" -- bash "$MUTANT_R1" --repo "$FIXTURE_REPO" start
        r1_mutant_b_rc="$RED_CONTROL_RC"
        sleep $((SLOW_SECS + 2))
        r1_red_supers=$(poll_until "$SUPERVISOR_PAT" 2 30)
        r1_red_pollers=$(poll_until "$POLLER_PAT" 2 30)
        if red_control_assert \
            --label "RED control (R1 launch handoff)" \
            --observed     "rc=$r1_mutant_b_rc supervisors=$r1_red_supers pollers=$r1_red_pollers" \
            --expect-wrong "rc=0 supervisors=2 pollers=2" \
            --correct      "rc=4 supervisors=1 pollers=1" \
            --expect-rc "0" \
            --note "without the guard, a concurrent start during the launch handoff window launches a DUPLICATE supervisor+poller — two pollers on one token means Telegram returns 409 Conflict to one of them"; then
          pass "RED control (R1 launch handoff): the refusal assertion is non-vacuous"
        else
          fail "RED control (R1 launch handoff): the refusal assertion is non-vacuous" "see the RED-control FAIL line above"
        fi
      else
        skip "RED control (R1 launch handoff): the refusal assertion is non-vacuous" \
          "the handoff window closed before launcher B (mutant) could race it on this run — the reproduction is timing-sensitive; not asserting on a window that did not open"
      fi
      stop_bridge >"$WORK/log-r1-red-cleanup-stop.log" 2>&1
      poll_until "$POLLER_PAT" 0 30 >/dev/null
      poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
    fi
  else
    skip "R1: a concurrent start during the handoff window is refused (rc=4)" \
      "the handoff window closed before assertion (supervisor already visible=$r1_a_super_now, marker present=$([ -n "$r1_a_marker_pid" ] && echo yes || echo no)) — the double was too fast on this host; not asserting on a window that did not open"
    skip "RED control (R1 launch handoff): the refusal assertion is non-vacuous" \
      "R1's own setup window did not open (see the skip above), so the RED control was not attempted"
    stop_bridge >"$WORK/log-r1-fallback-stop.log" 2>&1
    poll_until "$POLLER_PAT" 0 30 >/dev/null
    poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  fi
else
  skip "R1: a concurrent start during the handoff window is refused (rc=4)" "$RACE_SKIP_REASON"
  skip "RED control (R1 launch handoff): the refusal assertion is non-vacuous" "$RACE_SKIP_REASON"
fi

# ── Case R2: 'run' writes the marker under the lock; a concurrent start refuses ──
# COVERAGE, stated precisely rather than over-read: this case proves (1) the
# marker becomes readable while 'run' is mid-handoff and blocks a concurrent
# 'start' (rc=4, no second supervisor), and (2) — via the lock-freedom poll
# below — that the marker is ALREADY on disk by the moment the lock first
# becomes acquirable again, the closest observable proxy for "written under
# the lock" available without a test-only hook in run_verb itself (there is
# no injectable seam for the sub-millisecond gap between the write and the fd
# close, and adding one to production code purely to make it testable is out
# of bounds). It does NOT, and cannot, directly observe fd 200 being held
# DURING the write — only that the write is provably complete by the time the
# lock next opens, which run_verb's own code order (write, then close)
# guarantees deterministically rather than by timing luck. Lighter than R1 by
# design otherwise — R1's RED control already covers the shared guard code
# path; R2 exists to prove BOTH verbs are covered and to add the ordering
# proxy R1 cannot exercise, since start_verb's lock is held by a DIFFERENT
# process (the launcher script) than the one that becomes the supervisor.
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-r2-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  R2_LOCK_PATH=$("$SCRIPT" --print-lock-path)

  # 'run' execs, so its OWN pid is the marker pid — `exec` inside the subshell
  # keeps $! that same pid through to the marker write.
  ( PATH="$SLOWBIN:$PATH" exec "$SCRIPT" --repo "$FIXTURE_REPO" run ) >"$WORK/log-r2-run.log" 2>&1 &
  r2_run_bg=$!

  # Two-phase poll, deliberately: a single "wait until the lock is free"
  # check is AMBIGUOUS between "run_verb held it and released it" (what we
  # want to observe) and "run_verb has not even started yet" (the lock was
  # never contended) — both read as "free" to a bare poll. Proven live: an
  # earlier version of this case asserted straight off a single free-poll and
  # FAILED, because the very first check (before the backgrounded job had
  # even been scheduled) already found the lock free with no marker written
  # yet. So: first poll until the lock is observably HELD (proof run_verb
  # actually acquired it), THEN poll until it is free again — only that
  # second transition is evidence of a release, and only a release proves the
  # write (which run_verb's own code order places strictly before the fd
  # close — see its ORDERING comment) already happened. If the HELD phase is
  # never observed within the bound, this is the sub-millisecond-gap case the
  # brief anticipated: SKIP rather than assert on an ambiguous read. Each
  # probe acquires and immediately releases (the subshell exits right after
  # `flock -n` returns, closing its own fd 9), so it cannot itself interfere
  # with the concurrent-start assertion that follows.
  r2_seen_held=0
  r2_h=0
  while [ "$r2_h" -lt 150 ]; do
    if ( flock -n 9 ) 9>"$R2_LOCK_PATH" 2>/dev/null; then
      :   # still free (or not yet contended) — keep polling
    else
      r2_seen_held=1
      break
    fi
    r2_h=$((r2_h + 1))
    sleep 0.02
  done

  if [ "$r2_seen_held" -eq 1 ]; then
    r2_lock_free=0
    r2_i=0
    while [ "$r2_i" -lt 100 ]; do
      if ( flock -n 9 ) 9>"$R2_LOCK_PATH" 2>/dev/null; then
        r2_lock_free=1
        break
      fi
      r2_i=$((r2_i + 1))
      sleep 0.05
    done

    if [ "$r2_lock_free" -eq 1 ]; then
      pass "R2: the lock, once observed held, is released again (run_verb finished with it, past the marker write)"
      if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
        pass "R2: the marker file already exists the instant the (previously-held) lock frees again (write-before-release)"
      else
        fail "R2: the marker file already exists the instant the (previously-held) lock frees again (write-before-release)" \
          "the lock was held, then freed, but no marker file is present"
      fi
    else
      skip "R2: the lock, once observed held, is released again (run_verb finished with it, past the marker write)" \
        "the lock was observed held but never became free again within ~5s — 'run' may be wedged; not this ticket's failure mode to diagnose here"
      skip "R2: the marker file already exists the instant the (previously-held) lock frees again (write-before-release)" \
        "see the release-timeout skip above"
    fi
  else
    skip "R2: the lock, once observed held, is released again (run_verb finished with it, past the marker write)" \
      "never observed the lock actually HELD within ~3s of backgrounding 'run' — the acquire-to-release window on this host is apparently narrower than this poll's ~20ms granularity can catch; this is exactly the sub-millisecond gap the brief said not to chase, so this is a stated coverage gap, not a flaky assertion"
    skip "R2: the marker file already exists the instant the (previously-held) lock frees again (write-before-release)" \
      "see the never-observed-held skip above"
  fi

  r2_marker_pid=""
  r2_j=0
  while [ "$r2_j" -lt 50 ]; do
    if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
      r2_content=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
      r2_marker_pid="${r2_content%% *}"
      [ -n "$r2_marker_pid" ] && break
    fi
    r2_j=$((r2_j + 1))
    sleep 0.1
  done

  if [ -n "$r2_marker_pid" ]; then
    pass "R2: 'run' writes the launch marker before it becomes visible"
    check "R2: the marker names the backgrounded 'run' process's own pid" "$r2_run_bg" "$r2_marker_pid"

    r2_b_rc=0
    start_bridge >"$WORK/log-r2-b.log" 2>&1 || r2_b_rc=$?
    check "R2: a concurrent start while 'run' is mid-handoff is refused (rc=4)" 4 "$r2_b_rc"
    r2_supers_mid=$(count_procs "$SUPERVISOR_PAT")
    check "R2: no second supervisor appears while 'run' is mid-handoff" 0 "$r2_supers_mid"
  else
    # FAIL-vs-SKIP decided from what was actually OBSERVED, never from the
    # marker's absence itself (CR round 5 [codex-1]): the marker never
    # appearing is exactly the regression this case exists to catch, so
    # inferring "couldn't run the scenario" from that same absence made the
    # detection target and the SKIP condition the same fact — delete
    # write_launch_marker from run_verb and this branch used to SKIP both
    # assertions, the suite reported 0 failed, and run_verb's entire handoff
    # protection went untested while everything looked green.
    if [ "$r2_seen_held" -eq 1 ] && [ "$r2_lock_free" -eq 1 ]; then
      # The two earlier sub-assertions ALREADY proved the launch got
      # underway independent of the marker: run_verb had to acquire_lock ->
      # refuse_if_launch_in_progress -> sweep_stale -> bun resolution -> fd
      # close to produce that observed hold-then-release transition at all
      # (none of those steps depend on write_launch_marker succeeding). A
      # marker absent AFTER that point is not something we failed to
      # observe — it IS the regression.
      fail "R2: 'run' writes the launch marker before it becomes visible" \
        "the lock was observed held then released (run_verb demonstrably reached the fd-close point), but no marker file ever appeared — write_launch_marker did not run or did not persist"
      fail "R2: a concurrent start while 'run' is mid-handoff is refused (rc=4)" \
        "cannot exercise the refusal: no marker was ever written for a concurrent start to find (see the FAIL immediately above)"
    elif ps -p "$r2_run_bg" >/dev/null 2>&1; then
      # Genuinely could not anchor on the lock transition (the sub-
      # millisecond-gap case), but the backgrounded 'run' process is
      # observably still alive — a real inability to run THIS OBSERVATION,
      # not evidence the marker write failed.
      skip "R2: 'run' writes the launch marker before it becomes visible" \
        "backgrounded 'run' (pid $r2_run_bg) is alive, but the lock-held/lock-free observation never anchored (r2_seen_held=$r2_seen_held r2_lock_free=$r2_lock_free) — cannot distinguish 'still mid-handoff' from 'broken' without asserting on an unobserved window"
      skip "R2: a concurrent start while 'run' is mid-handoff is refused (rc=4)" "see the setup skip above"
    else
      # The backgrounded 'run' process is gone AND we never anchored on the
      # lock transition: the scenario itself did not run far enough to
      # observe, which is the legitimate "could not run this" skip.
      skip "R2: 'run' writes the launch marker before it becomes visible" \
        "backgrounded 'run' (pid $r2_run_bg) is no longer alive and the lock-held/lock-free observation never anchored (r2_seen_held=$r2_seen_held r2_lock_free=$r2_lock_free) — the scenario did not run far enough to observe (died before or during launch)"
      skip "R2: a concurrent start while 'run' is mid-handoff is refused (rc=4)" "see the setup skip above"
    fi
  fi

  sleep $((SLOW_SECS + 2))
  stop_bridge >"$WORK/log-r2-cleanup-stop.log" 2>&1
  wait "$r2_run_bg" 2>/dev/null || true
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  # ── RED control for R2 (CR round 5 [codex-1]) ──────────────────────────
  # The control that makes the fail-vs-skip fix above PROVABLE rather than
  # merely intended: it demonstrates the case goes RED under exactly the
  # mutation that used to make it SKIP. Neuters run_verb's
  # `write_launch_marker "$$"` call — and ONLY that one: start_verb's own
  # call is `write_launch_marker "$child"`, a textually distinct string, so
  # this sed cannot touch it.
  MUTANT_R2="$WORK/mutant-r2-no-marker.sh"
  sed 's|^\( *\)write_launch_marker "\$\$"$|\1:|' "$SCRIPT" > "$MUTANT_R2"
  if cmp -s "$SCRIPT" "$MUTANT_R2"; then
    fail "RED control (R2 run-verb marker): the mutation actually applies" \
      "sed changed nothing — the 'write_launch_marker \"\$\$\"' call was not found in $SCRIPT. A no-op mutant is a BROKEN control, not evidence."
  else
    pass "RED control (R2 run-verb marker): the mutation actually applies"

    stop_bridge >"$WORK/log-r2-red-pre-stop.log" 2>&1
    poll_until "$POLLER_PAT" 0 30 >/dev/null
    poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

    # Mutant 'run' in the background, fenced (PS_FENCE) so its own
    # sweep_stale/discovery scans can never see a real host process — same
    # shape as R1's control. `run` execs, so $! is the pid that becomes the
    # (fake) supervisor once the slow double resolves.
    ( PATH="$PS_FENCE:$SLOWBIN:$PATH" bash "$MUTANT_R2" --repo "$FIXTURE_REPO" run ) >"$WORK/log-r2-red-run.log" 2>&1 &
    r2_red_run_bg=$!

    # Same two-phase poll as the real case: without the marker write, the
    # lock is still acquired-then-released on schedule (nothing about
    # deleting the marker write changes the lock's own timing), so this
    # observation is still meaningful for confirming the mutant launch
    # genuinely got underway before we race it with a concurrent start.
    r2_red_seen_held=0
    r2_red_h=0
    while [ "$r2_red_h" -lt 150 ]; do
      if ( flock -n 9 ) 9>"$R2_LOCK_PATH" 2>/dev/null; then
        :
      else
        r2_red_seen_held=1
        break
      fi
      r2_red_h=$((r2_red_h + 1))
      sleep 0.02
    done
    if [ "$r2_red_seen_held" -eq 1 ]; then
      r2_red_i=0
      while [ "$r2_red_i" -lt 100 ]; do
        if ( flock -n 9 ) 9>"$R2_LOCK_PATH" 2>/dev/null; then
          break
        fi
        r2_red_i=$((r2_red_i + 1))
        sleep 0.05
      done
    fi

    if [ "$r2_red_seen_held" -eq 1 ]; then
      # Concurrent start B is the PROBE whose result is what "RED" actually
      # means here — A (backgrounded above) carries the mutation, so B must
      # be the call red_control_run captures: real (unmutated) script, fenced
      # (PS_FENCE) so its own sweep_stale/discovery scan can never reach a
      # real host process, real fast bun via the ambient PATH. Matches
      # red_control_run's own contract (point (a), "the mutant RAN") in
      # spirit: what's under test is the SCENARIO's outcome with A mutated,
      # and B's observable reaction (refused or not) IS that outcome.
      red_control_run --env PATH="$PS_FENCE:$PATH" -- "$SCRIPT" --repo "$FIXTURE_REPO" start
      r2_red_b_rc="$RED_CONTROL_RC"
      sleep $((SLOW_SECS + 2))
      r2_red_supers=$(poll_until "$SUPERVISOR_PAT" 2 30)

      if red_control_assert \
          --label "RED control (R2 run-verb marker)" \
          --observed     "rc=$r2_red_b_rc supervisors=$r2_red_supers" \
          --expect-wrong "rc=0 supervisors=2" \
          --correct      "rc=4 supervisors=1" \
          --expect-rc "0" \
          --note "without run_verb's marker write, a concurrent start during 'run's handoff window is never refused and launches a SECOND supervisor — two pollers on one token, Telegram 409"; then
        pass "RED control (R2 run-verb marker): the fail-vs-skip fix is non-vacuous"
      else
        fail "RED control (R2 run-verb marker): the fail-vs-skip fix is non-vacuous" "see the RED-control FAIL line above"
      fi
    else
      skip "RED control (R2 run-verb marker): the fail-vs-skip fix is non-vacuous" \
        "the mutant's own lock-held/lock-free window never anchored on this run — a timing limitation of the control's own setup, not evidence about the mutation"
    fi

    # Reap whatever the mutant started — its own supervisor/poller (once the
    # slow double resolved) plus the still-alive backgrounded 'run' process
    # itself, the same discipline R1's control and reap_decoys already use.
    sleep $((SLOW_SECS + 2))
    stop_bridge >"$WORK/log-r2-red-cleanup-stop.log" 2>&1
    kill -9 "$r2_red_run_bg" 2>/dev/null || true
    wait "$r2_red_run_bg" 2>/dev/null || true
    poll_until "$POLLER_PAT" 0 30 >/dev/null
    poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  fi
else
  skip "R2: the lock, once observed held, is released again (run_verb finished with it, past the marker write)" "$RACE_SKIP_REASON"
  skip "R2: the marker file already exists the instant the (previously-held) lock frees again (write-before-release)" "$RACE_SKIP_REASON"
  skip "R2: 'run' writes the launch marker before it becomes visible" "$RACE_SKIP_REASON"
  skip "R2: a concurrent start while 'run' is mid-handoff is refused (rc=4)" "$RACE_SKIP_REASON"
  skip "RED control (R2 run-verb marker): the mutation actually applies" "$RACE_SKIP_REASON"
  skip "RED control (R2 run-verb marker): the fail-vs-skip fix is non-vacuous" "$RACE_SKIP_REASON"
fi

# ── Case R3: a marker naming a DEAD launcher pid cannot wedge a later start ─
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-r3-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  ( exec sleep 0.1 ) &
  r3_dead_pid=$!
  wait "$r3_dead_pid" 2>/dev/null || true
  r3_dead_ok=1
  if ps -p "$r3_dead_pid" >/dev/null 2>&1; then
    r3_dead_ok=0
  fi

  if [ "$r3_dead_ok" -eq 1 ]; then
    printf '%s %s\n' "$r3_dead_pid" "$(date +%s)" > "$BRIDGE_ROOT/supervisor.launching"
    r3_rc=0
    start_bridge >"$WORK/log-r3-start.log" 2>&1 || r3_rc=$?
    check "R3: a start with a stale (dead-pid) marker present exits 0" 0 "$r3_rc"
    r3_pollers=$(poll_until "$POLLER_PAT" 1 30)
    check "R3: start launches normally past a dead-launcher marker" 1 "$r3_pollers"
    if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
      r3_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
      r3_marker_pid_after="${r3_marker_after%% *}"
      if [ "$r3_marker_pid_after" != "$r3_dead_pid" ]; then
        pass "R3: the stale (dead-pid) marker was replaced by the new launch's own marker"
      else
        fail "R3: the stale (dead-pid) marker was replaced by the new launch's own marker" "marker still names the dead pid $r3_dead_pid"
      fi
    else
      pass "R3: the stale (dead-pid) marker was removed"
    fi
    stop_bridge >"$WORK/log-r3-cleanup-stop.log" 2>&1
    poll_until "$POLLER_PAT" 0 30 >/dev/null
    poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  else
    skip "R3: a start with a stale (dead-pid) marker present exits 0" \
      "could not obtain a provably-dead pid (pid $r3_dead_pid still shows alive via 'ps -p' immediately after 'wait') on this host"
    skip "R3: start launches normally past a dead-launcher marker" "see the setup skip above"
  fi
  rm -f "$BRIDGE_ROOT/supervisor.launching"
else
  skip "R3: a start with a stale (dead-pid) marker present exits 0" "$RACE_SKIP_REASON"
  skip "R3: start launches normally past a dead-launcher marker" "$RACE_SKIP_REASON"
fi

# ── Case R4: an OVER-AGE marker (live pid, backdated epoch) is ignored+removed ──
# The backstop test, named as such: even a genuinely alive pid must not wedge
# a later start once its marker has aged past LAUNCH_MARKER_MAX_AGE_SEC.
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-r4-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  r4_old_epoch=$(( $(date +%s) - 300 ))
  printf '%s %s\n' "$$" "$r4_old_epoch" > "$BRIDGE_ROOT/supervisor.launching"

  r4_rc=0
  start_bridge >"$WORK/log-r4-start.log" 2>&1 || r4_rc=$?
  check "R4: a start with an over-age marker (live pid) exits 0" 0 "$r4_rc"
  r4_pollers=$(poll_until "$POLLER_PAT" 1 30)
  check "R4: start launches normally past an over-age marker" 1 "$r4_pollers"

  if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
    r4_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
    r4_marker_pid_after="${r4_marker_after%% *}"
    if [ "$r4_marker_pid_after" != "$$" ]; then
      pass "R4: the over-age marker was replaced by the new launch's own marker (no longer names the suite's own pid)"
    else
      fail "R4: the over-age marker was replaced by the new launch's own marker" "marker still names the suite's own pid ($$)"
    fi
  else
    fail "R4: the over-age marker was replaced by the new launch's own marker" "no marker file present after start"
  fi

  stop_bridge >"$WORK/log-r4-cleanup-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  rm -f "$BRIDGE_ROOT/supervisor.launching"
else
  skip "R4: a start with an over-age marker (live pid) exits 0" "$RACE_SKIP_REASON"
  skip "R4: start launches normally past an over-age marker" "$RACE_SKIP_REASON"
fi

# ── Case R5: an UNREADABLE epoch ("-", live pid) is ignored+removed, LOUDLY ──
# CR round 2 [codex-1]: an age this function cannot COMPUTE must read
# INACTIVE, not active-forever — the "-" epoch is exactly what
# write_launch_marker itself writes when `date` failed at write time, so this
# is not a synthetic case, it is the real shape that function produces on a
# clockless host. No timing needed: the marker is written directly, same
# pattern as R3/R4.
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-r5-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  printf '%s %s\n' "$$" "-" > "$BRIDGE_ROOT/supervisor.launching"

  r5_rc=0
  start_bridge >"$WORK/log-r5-start.log" 2>&1 || r5_rc=$?
  check "R5: a start with an unreadable-epoch marker (live pid) exits 0" 0 "$r5_rc"
  r5_pollers=$(poll_until "$POLLER_PAT" 1 30)
  check "R5: start launches normally past an unreadable-epoch marker" 1 "$r5_pollers"

  if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
    r5_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
    r5_marker_pid_after="${r5_marker_after%% *}"
    if [ "$r5_marker_pid_after" != "$$" ]; then
      pass "R5: the unreadable-epoch marker was replaced by the new launch's own marker (no longer names the suite's own pid)"
    else
      fail "R5: the unreadable-epoch marker was replaced by the new launch's own marker" "marker still names the suite's own pid ($$)"
    fi
  else
    fail "R5: the unreadable-epoch marker was replaced by the new launch's own marker" "no marker file present after start"
  fi

  if grep -q "unboundable age" "$WORK/log-r5-start.log" && grep -q "epoch field is unreadable" "$WORK/log-r5-start.log"; then
    pass "R5: the unboundable-age WARNING fires, naming the unreadable-epoch reason"
  else
    fail "R5: the unboundable-age WARNING fires, naming the unreadable-epoch reason" \
      "log said: $(tr '\n' '|' < "$WORK/log-r5-start.log")"
  fi

  stop_bridge >"$WORK/log-r5-cleanup-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  rm -f "$BRIDGE_ROOT/supervisor.launching"
else
  skip "R5: a start with an unreadable-epoch marker (live pid) exits 0" "$RACE_SKIP_REASON"
  skip "R5: start launches normally past an unreadable-epoch marker" "$RACE_SKIP_REASON"
  skip "R5: the unboundable-age WARNING fires, naming the unreadable-epoch reason" "$RACE_SKIP_REASON"
fi

# ── Case R6: a NEGATIVE age (epoch ahead of the clock) is ignored+removed, LOUDLY ──
# CR round 2 [codex-1]'s other unboundable-age route: a marker epoch AHEAD of
# "now" (a clock stepped backward by NTP, or a bridge root shared across
# machines with skewed clocks) makes `now - epoch` negative, so the plain
# `-gt LAUNCH_MARKER_MAX_AGE_SEC` comparison alone would never catch it — the
# marker could stay ACTIVE far past 30s. No timing needed: the marker is
# written directly with an epoch 1 hour in the future.
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-r6-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  r6_future_epoch=$(( $(date +%s) + 3600 ))
  printf '%s %s\n' "$$" "$r6_future_epoch" > "$BRIDGE_ROOT/supervisor.launching"

  r6_rc=0
  start_bridge >"$WORK/log-r6-start.log" 2>&1 || r6_rc=$?
  check "R6: a start with a future-epoch marker (live pid) exits 0" 0 "$r6_rc"
  r6_pollers=$(poll_until "$POLLER_PAT" 1 30)
  check "R6: start launches normally past a future-epoch marker" 1 "$r6_pollers"

  if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
    r6_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
    r6_marker_pid_after="${r6_marker_after%% *}"
    if [ "$r6_marker_pid_after" != "$$" ]; then
      pass "R6: the future-epoch marker was replaced by the new launch's own marker (no longer names the suite's own pid)"
    else
      fail "R6: the future-epoch marker was replaced by the new launch's own marker" "marker still names the suite's own pid ($$)"
    fi
  else
    fail "R6: the future-epoch marker was replaced by the new launch's own marker" "no marker file present after start"
  fi

  if grep -q "unboundable age" "$WORK/log-r6-start.log" && grep -q "ahead of the current clock" "$WORK/log-r6-start.log"; then
    pass "R6: the unboundable-age WARNING fires, naming the negative-age reason"
  else
    fail "R6: the unboundable-age WARNING fires, naming the negative-age reason" \
      "log said: $(tr '\n' '|' < "$WORK/log-r6-start.log")"
  fi

  stop_bridge >"$WORK/log-r6-cleanup-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  rm -f "$BRIDGE_ROOT/supervisor.launching"
else
  skip "R6: a start with a future-epoch marker (live pid) exits 0" "$RACE_SKIP_REASON"
  skip "R6: start launches normally past a future-epoch marker" "$RACE_SKIP_REASON"
  skip "R6: the unboundable-age WARNING fires, naming the negative-age reason" "$RACE_SKIP_REASON"
fi

# ── Case R7: an epoch with a LEADING ZERO does not crash the launcher ──────
# CR round 4 [codex-1]: the all-digits `case` above accepts "08"/"09", and
# bash arithmetic reads an UNQUOTED leading-zero literal as OCTAL — "08" and
# "09" are invalid octal digits, so plain `$((now - epoch))` raised a hard
# evaluation error. Reproduced by hand before this fix existed: it did NOT
# merely make `start` exit non-zero — it silently unwound the whole call
# stack past sweep_stale, bun resolution, and the launch itself, straight to
# the script's own trailing `exit 0`, so `start` reported SUCCESS having
# launched nothing and left the malformed marker untouched. `10#$epoch`
# normalizes to base 10 before the arithmetic. "08" is chosen deliberately
# rather than "07": 07 is a VALID octal literal (decimal 7) and would parse
# without error, so a regression that dropped the `10#` prefix would produce
# a silently WRONG age, not a loud failure — this suite would not catch it.
# "08"/"09" fail LOUDLY without the fix, so a regression here reintroduces a
# hard crash this case cannot miss.
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-r7-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  printf '%s %s\n' "$$" "08" > "$BRIDGE_ROOT/supervisor.launching"

  r7_rc=0
  start_bridge >"$WORK/log-r7-start.log" 2>&1 || r7_rc=$?
  check "R7: a start with a leading-zero-epoch marker (live pid) exits 0, not an arithmetic crash" 0 "$r7_rc"
  r7_pollers=$(poll_until "$POLLER_PAT" 1 30)
  check "R7: start launches normally past a leading-zero-epoch marker" 1 "$r7_pollers"

  if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
    r7_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
    r7_marker_pid_after="${r7_marker_after%% *}"
    if [ "$r7_marker_pid_after" != "$$" ]; then
      pass "R7: the leading-zero-epoch marker was replaced by the new launch's own marker (no longer names the suite's own pid)"
    else
      fail "R7: the leading-zero-epoch marker was replaced by the new launch's own marker" "marker still names the suite's own pid ($$)"
    fi
  else
    fail "R7: the leading-zero-epoch marker was replaced by the new launch's own marker" "no marker file present after start"
  fi

  # Non-vacuity check specific to this case: confirm the log carries no
  # arithmetic-evaluator error text, so a regression that reintroduces the
  # crash (but happens to still exit 0, as observed pre-fix) is still caught.
  if grep -qi "value too great for base\|syntax error" "$WORK/log-r7-start.log"; then
    fail "R7: no arithmetic-evaluator error appears in the launch output" \
      "log said: $(tr '\n' '|' < "$WORK/log-r7-start.log")"
  else
    pass "R7: no arithmetic-evaluator error appears in the launch output"
  fi

  stop_bridge >"$WORK/log-r7-cleanup-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  rm -f "$BRIDGE_ROOT/supervisor.launching"
else
  skip "R7: a start with a leading-zero-epoch marker (live pid) exits 0, not an arithmetic crash" "$RACE_SKIP_REASON"
  skip "R7: start launches normally past a leading-zero-epoch marker" "$RACE_SKIP_REASON"
  skip "R7: no arithmetic-evaluator error appears in the launch output" "$RACE_SKIP_REASON"
fi

# ── RETASK 02H-G9-9c4e21-impl (1/2): a start failing at bun resolution ─────
# leaves NO marker behind. This is the ORDERING half of the HIMMEL-2556
# hardening: write_launch_marker in start_verb sits AFTER bun_bin resolution,
# so a start that cannot find bun must exit before ever writing a marker —
# pid-liveness alone would not catch this failure mode (the calling shell's
# own pid stays alive for the rest of this test process's life). Written to
# be correct whether or not a marker pre-existed, per the brief.
# A curated PATH, not just "/usr/bin:/bin": this station has a real 'bun'
# installed as a system package (/usr/bin/bun), so any PATH built from real
# system directories resolves it. Build a scratch dir of symlinks to exactly
# the external commands restart-bridge.sh actually calls, deliberately never
# 'bun' itself, and use ONLY that directory as PATH (no fallback dirs) — the
# one reliable way to guarantee "no bun anywhere on PATH" on a host that
# genuinely has one installed.
NOBUN_BIN="$WORK/nobun-path"
mkdir -p "$NOBUN_BIN"
for nobun_tool in bash sh sha256sum shasum openssl ps awk sed grep date stat \
    mkdir dirname readlink flock cat rm kill sleep nohup cp env timeout tr \
    basename true false printf; do
  nobun_tool_path=$(command -v "$nobun_tool" 2>/dev/null) || continue
  ln -sf "$nobun_tool_path" "$NOBUN_BIN/$nobun_tool" 2>/dev/null || true
done
NOBUN_OK=1
if [ ! -x "$NOBUN_BIN/bash" ]; then
  NOBUN_OK=0
fi
if PATH="$NOBUN_BIN" command -v bun >/dev/null 2>&1; then
  NOBUN_OK=0
fi

if [ "$NOBUN_OK" -eq 1 ]; then
  nobun_marker_before=""
  [ -f "$BRIDGE_ROOT/supervisor.launching" ] && nobun_marker_before=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)

  nobun_rc=0
  run_with_timeout 20 env PATH="$NOBUN_BIN" bash "$SCRIPT" --repo "$FIXTURE_REPO" start >"$WORK/log-nobun.log" 2>&1 || nobun_rc=$?
  if [ "$nobun_rc" -ne 0 ]; then
    pass "RETASK: a start failing at bun resolution exits non-zero"
  else
    fail "RETASK: a start failing at bun resolution exits non-zero" "rc=0; log: $(tr '\n' '|' < "$WORK/log-nobun.log")"
  fi

  nobun_marker_after=""
  [ -f "$BRIDGE_ROOT/supervisor.launching" ] && nobun_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
  if [ -z "$nobun_marker_before" ]; then
    if [ -z "$nobun_marker_after" ]; then
      pass "RETASK: a start failing at bun resolution leaves no marker file"
    else
      fail "RETASK: a start failing at bun resolution leaves no marker file" "a marker was newly created: $nobun_marker_after"
    fi
  else
    if [ "$nobun_marker_after" = "$nobun_marker_before" ]; then
      pass "RETASK: a start failing at bun resolution leaves a pre-existing marker unchanged"
    else
      fail "RETASK: a start failing at bun resolution leaves a pre-existing marker unchanged" \
        "before='$nobun_marker_before' after='$nobun_marker_after'"
    fi
  fi
else
  skip "RETASK: a start failing at bun resolution exits non-zero" \
    "could not build a bun-less PATH on this host (either 'bash' itself could not be resolved to symlink, or a real 'bun' is STILL found even on the curated command set — cannot exercise this ordering guarantee reliably)"
  skip "RETASK: a start failing at bun resolution leaves no marker file" \
    "could not build a bun-less PATH on this host (either 'bash' itself could not be resolved to symlink, or a real 'bun' is STILL found even on the curated command set — cannot exercise this ordering guarantee reliably)"
fi

# ── RETASK 02H-G9-9c4e21-impl (2/2): a launcher REFUSED with rc=4 does not ──
# overwrite the in-flight marker it was refused because of. Reuses the R1/R2
# slow-double setup. Captures the marker's pid+epoch BEFORE the refused call
# and asserts it is byte-identical after — refuse_if_launch_in_progress must
# exit 4 before writing any marker of its own.
if [ "$RACE_OK" -eq 1 ]; then
  stop_bridge >"$WORK/log-retaskb-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  ( PATH="$SLOWBIN:$PATH" run_with_timeout 20 "$SCRIPT" --repo "$FIXTURE_REPO" start ) >"$WORK/log-retaskb-a.log" 2>&1 &
  rtb_a_bg=$!
  wait "$rtb_a_bg"

  rtb_super_now=$(count_procs "$SUPERVISOR_PAT")
  rtb_marker_before=""
  [ -f "$BRIDGE_ROOT/supervisor.launching" ] && rtb_marker_before=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)

  if [ "$rtb_super_now" -eq 0 ] && [ -n "$rtb_marker_before" ]; then
    rtb_b_rc=0
    start_bridge >"$WORK/log-retaskb-b.log" 2>&1 || rtb_b_rc=$?
    rtb_marker_after=""
    [ -f "$BRIDGE_ROOT/supervisor.launching" ] && rtb_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)

    check "RETASK: a refused launcher's own exit code is 4" 4 "$rtb_b_rc"
    if [ "$rtb_marker_after" = "$rtb_marker_before" ]; then
      pass "RETASK: a refused (rc=4) launcher leaves the in-flight marker byte-identical"
    else
      fail "RETASK: a refused (rc=4) launcher leaves the in-flight marker byte-identical" \
        "before='$rtb_marker_before' after='$rtb_marker_after'"
    fi
  else
    skip "RETASK: a refused (rc=4) launcher leaves the in-flight marker byte-identical" \
      "the handoff window closed before this could be observed (supervisor visible=$rtb_super_now, marker present=$([ -n "$rtb_marker_before" ] && echo yes || echo no))"
  fi

  sleep $((SLOW_SECS + 2))
  stop_bridge >"$WORK/log-retaskb-cleanup-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
else
  skip "RETASK: a refused (rc=4) launcher leaves the in-flight marker byte-identical" "$RACE_SKIP_REASON"
fi

# ── CR round 1 [codex-1]: a marker-write FAILURE degrades LOUDLY, not silently ──
# write_launch_marker must stay non-fatal (the launch proceeds either way —
# that part is deliberate and unchanged), but a lost marker write must be
# VISIBLE, matching every other degrade in this file (flock absent, an
# unreadable cwd, an unattributable candidate left alone — all print one named
# WARNING). A `chmod`-based unwritable $BRIDGE_ROOT is the cheapest hermetic
# way to force the write to fail without a test-only hook in production code.
# Gated on NOT running as root: root bypasses ordinary permission checks, so
# the directory would stay effectively writable regardless of its mode bits,
# defeating this fixture — SKIP rather than silently no-op in that case.
if [ "$(id -u)" -ne 0 ]; then
  stop_bridge >"$WORK/log-warn-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
  rm -f "$BRIDGE_ROOT/supervisor.launching"

  # $BRIDGE_ROOT already EXISTS at this point (created at suite setup), so
  # write_launch_marker's `mkdir -p` is a no-op that does not itself need
  # write access — it is the marker FILE creation inside the directory
  # (r-xr-xr-x, no write bit) that fails, exercising the write_ok=0 arm.
  chmod 555 "$BRIDGE_ROOT"
  warn_rc=0
  start_bridge >"$WORK/log-warn-start.log" 2>&1 || warn_rc=$?
  # Restore BEFORE any further step (including this case's own cleanup)
  # needs to write under $BRIDGE_ROOT again.
  chmod 755 "$BRIDGE_ROOT"

  check "marker-write failure: the launch still succeeds (rc=0) despite an unwritable bridge root" 0 "$warn_rc"

  if grep -q "could not write the launch marker" "$WORK/log-warn-start.log" && \
      grep -q "handoff protection is DISABLED" "$WORK/log-warn-start.log"; then
    pass "marker-write failure: a named WARNING fires, naming both the marker path and the concrete handoff-disabled consequence"
  else
    fail "marker-write failure: a named WARNING fires, naming both the marker path and the concrete handoff-disabled consequence" \
      "log said: $(tr '\n' '|' < "$WORK/log-warn-start.log")"
  fi

  warn_pollers=$(poll_until "$POLLER_PAT" 1 30)
  check "marker-write failure: the bridge itself still launches normally (one poller)" 1 "$warn_pollers"

  if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
    fail "marker-write failure: no marker file was actually created" \
      "a marker file exists at $BRIDGE_ROOT/supervisor.launching despite the unwritable directory"
  else
    pass "marker-write failure: no marker file was actually created"
  fi

  stop_bridge >"$WORK/log-warn-cleanup-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
else
  skip "marker-write failure: the launch still succeeds (rc=0) despite an unwritable bridge root" \
    "running as root — a chmod-based unwritable-directory check is defeated by root bypassing permission checks"
  skip "marker-write failure: a named WARNING fires, naming both the marker path and the concrete handoff-disabled consequence" \
    "see the root skip above"
  skip "marker-write failure: the bridge itself still launches normally (one poller)" "see the root skip above"
  skip "marker-write failure: no marker file was actually created" "see the root skip above"
fi

# ── CR round 6 [codex-1]: a marker-REMOVE FAILURE also degrades LOUDLY ────
# Sibling of the round-1 case above, same family: `rm -f` needs WRITE
# permission on the marker's DIRECTORY (not the file itself), and `-f`
# suppresses only a missing-FILE error, never a permission error. An
# INACTIVE marker (a dead pid is the easiest inactive state — see R3) sitting
# in an unwritable bridge root used to make prune_launch_marker's unguarded
# `rm -f` abort start/run before they launched anything — a plain internal
# contradiction with round 1's promise (stated twice in the header) that
# unwritable marker storage is non-fatal, since write and remove are the SAME
# storage with the SAME failure mode.
#
# Deliberately planting the marker FILE *before* the chmod (unlike the
# round-1 case, which `rm -f`s any pre-existing marker first): this isolates
# prune's failure from write's. Overwriting an EXISTING file's *contents*
# only needs write permission on the FILE itself (already has it, from
# before the chmod); only CREATING or UNLINKING a directory entry needs
# write permission on the DIRECTORY. So with a marker already on disk, only
# the `rm -f` inside prune_launch_marker is exercised — write_launch_marker's
# later overwrite of that same file, once the launch proceeds, still
# succeeds independently, which is confirmed below rather than assumed.
if [ "$(id -u)" -ne 0 ]; then
  stop_bridge >"$WORK/log-warn2-pre-stop.log" 2>&1
  poll_until "$POLLER_PAT" 0 30 >/dev/null
  poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null

  ( exec sleep 0.1 ) &
  warn2_dead_pid=$!
  wait "$warn2_dead_pid" 2>/dev/null || true
  warn2_dead_ok=1
  if ps -p "$warn2_dead_pid" >/dev/null 2>&1; then
    warn2_dead_ok=0
  fi

  if [ "$warn2_dead_ok" -eq 1 ]; then
    printf '%s %s\n' "$warn2_dead_pid" "$(date +%s)" > "$BRIDGE_ROOT/supervisor.launching"

    chmod 555 "$BRIDGE_ROOT"
    warn2_rc=0
    start_bridge >"$WORK/log-warn2-start.log" 2>&1 || warn2_rc=$?
    # Restore BEFORE any further step (including this case's own cleanup)
    # needs to write under $BRIDGE_ROOT again.
    chmod 755 "$BRIDGE_ROOT"

    check "marker-remove failure: the launch still succeeds (rc=0) despite an unwritable bridge root" 0 "$warn2_rc"

    if grep -q "could not remove the stale launch marker" "$WORK/log-warn2-start.log"; then
      pass "marker-remove failure: a named WARNING fires, naming the marker path and that it will be retried"
    else
      fail "marker-remove failure: a named WARNING fires, naming the marker path and that it will be retried" \
        "log said: $(tr '\n' '|' < "$WORK/log-warn2-start.log")"
    fi

    warn2_pollers=$(poll_until "$POLLER_PAT" 1 30)
    check "marker-remove failure: the bridge itself still launches normally (one poller)" 1 "$warn2_pollers"

    # Confirms the isolation claimed above: write_launch_marker's own later
    # overwrite of the SAME file succeeds independently of prune's rm
    # failure, so the marker now names the NEW launch's pid, not the dead one.
    if [ -f "$BRIDGE_ROOT/supervisor.launching" ]; then
      warn2_marker_after=$(cat "$BRIDGE_ROOT/supervisor.launching" 2>/dev/null)
      warn2_marker_pid_after="${warn2_marker_after%% *}"
      if [ "$warn2_marker_pid_after" != "$warn2_dead_pid" ]; then
        pass "marker-remove failure: write_launch_marker's later overwrite of the same file still succeeds (marker no longer names the dead pid)"
      else
        fail "marker-remove failure: write_launch_marker's later overwrite of the same file still succeeds" \
          "marker still names the dead pid $warn2_dead_pid"
      fi
    else
      fail "marker-remove failure: write_launch_marker's later overwrite of the same file still succeeds" \
        "no marker file present after start"
    fi

    stop_bridge >"$WORK/log-warn2-cleanup-stop.log" 2>&1
    poll_until "$POLLER_PAT" 0 30 >/dev/null
    poll_until "$SUPERVISOR_PAT" 0 10 >/dev/null
    rm -f "$BRIDGE_ROOT/supervisor.launching"
  else
    skip "marker-remove failure: the launch still succeeds (rc=0) despite an unwritable bridge root" \
      "could not obtain a provably-dead pid (pid $warn2_dead_pid still shows alive via 'ps -p' immediately after 'wait') on this host"
    skip "marker-remove failure: a named WARNING fires, naming the marker path and that it will be retried" "see the setup skip above"
    skip "marker-remove failure: the bridge itself still launches normally (one poller)" "see the setup skip above"
    skip "marker-remove failure: write_launch_marker's later overwrite of the same file still succeeds" "see the setup skip above"
  fi
else
  skip "marker-remove failure: the launch still succeeds (rc=0) despite an unwritable bridge root" \
    "running as root — a chmod-based unwritable-directory check is defeated by root bypassing permission checks"
  skip "marker-remove failure: a named WARNING fires, naming the marker path and that it will be retried" \
    "see the root skip above"
  skip "marker-remove failure: the bridge itself still launches normally (one poller)" "see the root skip above"
  skip "marker-remove failure: write_launch_marker's later overwrite of the same file still succeeds" "see the root skip above"
fi

echo ""
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "OK test-restart-bridge: $PASS_COUNT passed, $SKIP_COUNT skipped, 0 failed"
  exit 0
fi
echo "ERR test-restart-bridge: $PASS_COUNT passed, $SKIP_COUNT skipped, $FAIL_COUNT failed"
exit 1
