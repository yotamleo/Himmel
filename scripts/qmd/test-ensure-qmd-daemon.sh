#!/usr/bin/env bash
# test-ensure-qmd-daemon.sh - hermetic smoke test for the qmd plugin's
# ensure-qmd-daemon.sh (marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh).
#
# Never touches the real qmd daemon on 8181: HOME is pointed at an empty temp
# dir (so the bun-bin fallback finds nothing), a MOCK qmd + MOCK curl stand in
# on PATH / via QMD_CURL, and PATH is reduced to coreutil dirs plus the mock
# bin so no real qmd leaks in.
#
# Covers: (a) alive short-circuit (qmd NOT invoked); (b) dead -> start daemon ->
# comes alive (qmd invoked with `mcp --http --daemon`); (c) qmd missing ->
# nonzero + install hint; (d) foreign listener -> nonzero + port-taken message;
# (e) hung daemon start -> bounded by QMD_START_TIMEOUT, nonzero + clear message;
# (f) start "succeeds" but probe never comes alive -> wait loop exhausts,
# nonzero + "nothing came alive" + mcp.log + start-output passthrough;
# (g) timeout(1) absent -> degrade branch still starts the daemon and exits 0;
# (h) bun-global bin is preferred over a PATH qmd (resolution order);
# (i) bun + the bun-global dist/cli/qmd.js is preferred over the bun bin shim
#     AND a PATH qmd (HIMMEL-928 - the daemon child must inherit bun, never a
#     node-shebang shim's node execPath).
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

work="$(mktemp -d)"
# HIMMEL-3775: every fake-daemon.sh stub PID this run starts is tracked here
# and reaped on EXIT/INT/TERM (not only on the happy path), so a forced early
# exit (an assertion failure, a kill partway through) never leaks a stub.
declare -a STUB_PIDS=()
reap_stubs() {
  local pid
  for pid in "${STUB_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${STUB_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
}
trap 'reap_stubs; rm -rf "$work"' EXIT
# A trap without an explicit exit does not terminate the script on INT/TERM -
# it runs the handler, then execution continues from where the signal landed
# (now inside a removed $work). Exit explicitly so an interrupt actually stops
# the suite instead of running on against a deleted work directory.
trap 'reap_stubs; rm -rf "$work"; exit 130' INT
trap 'reap_stubs; rm -rf "$work"; exit 143' TERM
# Test-only hooks for HIMMEL-3775's leak regression test (test-ensure-qmd-daemon-leak.sh):
# QMD_TEST_WORK_MARKER, if set, receives this run's unique $work path so the
# leak test can pgrep -f its fake-daemon.sh by a marker no other run shares.
# QMD_TEST_FORCE_FAIL_AFTER=start_fake_daemon forces an early exit right after
# a stub starts, modeling a kill/assertion-failure partway through.
: "${QMD_TEST_WORK_MARKER:=}"
[ -z "$QMD_TEST_WORK_MARKER" ] || printf '%s\n' "$work" > "$QMD_TEST_WORK_MARKER"
: "${QMD_TEST_FORCE_FAIL_AFTER:=}"

home="$work/home"
mkdir -p "$home"
state="$work/state"
mkdir -p "$state"
bin="$work/bin"
mkdir -p "$bin"

# ---- timeout stub for hosts without GNU timeout (stock macOS) -----------------
# The script under test degrades to an UNBOUNDED daemon start when timeout(1)
# is absent, so (e) could never pass there (HIMMEL-3719). Provide a minimal
# GNU-shaped stub in $bin: `timeout [-k N] SECS cmd...`, rc 124 on a kill.
# ponytail: the stub ignores -k's KILL grace (TERM only), so a TERM-ignoring child would hang; upgrade path is providing coreutils timeout on the macOS runner.
if ! command -v timeout >/dev/null 2>&1; then
  cat > "$bin/timeout" <<'TOEOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "timeout (test stub)"; exit 0; fi
if [ "$1" = "-k" ]; then shift 2; fi
secs="$1"; shift
flag="${TMPDIR:-/tmp}/timeout-stub.$$"
rm -f "$flag"
"$@" &
cpid=$!
( sleep "$secs"; touch "$flag"; kill -TERM "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
wpid=$!
wait "$cpid"; rc=$?
kill "$wpid" 2>/dev/null
if [ -f "$flag" ]; then rm -f "$flag"; exit 124; fi
exit "$rc"
TOEOF
  chmod +x "$bin/timeout"
fi

# ---- SAFE_PATH: coreutil dirs only, captured before we scrub PATH ----------
safe=""
for t in sleep grep sed cat mkdir touch rm dirname env bash timeout date; do
  p="$(command -v "$t")" || continue
  d="$(dirname "$p")"
  case ":$safe:" in *":$d:"*) ;; *) safe="$safe:$d" ;; esac
done
safe="${safe#:}"

# ---- Mock curl: mode-driven via QMD_MOCK_CURL_MODE -------------------------
#   alive    -> qmd-shaped initialize reply (faithful to real qmd 2.5.2 shape)
#   foreign  -> non-qmd JSON
#   sneaky   -> foreign serverInfo but a name:qmd pair OUTSIDE serverInfo
#   dead     -> nothing, connection-refused rc
#   sentinel -> qmd-shaped reply iff $QMD_MOCK_STATE/alive exists, else dead
# Dead exits rc 7 (connect refused); the rc 7 vs rc 28 (timeout) distinction
# is intentionally collapsed - production branches on empty body only.
mock_curl="$bin/curl"
cat > "$mock_curl" <<'EOF'
#!/usr/bin/env bash
qmd_reply='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"qmd","version":"2.5.2"},"instructions":"QMD is your local search engine."}}'
case "${QMD_MOCK_CURL_MODE:-dead}" in
  alive)   printf '%s' "$qmd_reply"; exit 0 ;;
  foreign) printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"other-server"}}}'; exit 0 ;;
  sneaky)  printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":[{"name":"qmd"}]},"serverInfo":{"name":"other-server","version":"1.0"}}}'; exit 0 ;;
  sentinel)
    if [ -f "$QMD_MOCK_STATE/alive" ]; then printf '%s' "$qmd_reply"; exit 0; fi
    exit 7 ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$mock_curl"

# ---- Mock qmd: records argv; simulates daemon start via a sentinel file -----
# QMD_MOCK_HANG=1 -> the daemon start hangs. `exec sleep`, NOT a child sleep:
# a grandchild sleep would keep holding the $() pipe open after timeout(1)
# kills the mock - the known Git-Bash timeout reaping trap.
mock_qmd="$bin/qmd"
cat > "$mock_qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-argv.log"
if [ "$*" = "mcp --http --daemon" ]; then
  pwd -P >> "$QMD_MOCK_STATE/qmd-cwd.log"
  if [ "${QMD_MOCK_HANG:-0}" = "1" ]; then
    exec sleep 60
  fi
  if [ -n "${QMD_MOCK_LOCK_DIR:-}" ]; then
    if [ -d "$QMD_MOCK_LOCK_DIR" ]; then echo held >> "$QMD_MOCK_STATE/lock-at-start"; else echo free >> "$QMD_MOCK_STATE/lock-at-start"; fi
  fi
  if [ -n "${QMD_MOCK_SLOW:-}" ]; then sleep "$QMD_MOCK_SLOW"; fi
  touch "$QMD_MOCK_STATE/alive"
  echo "Started qmd HTTP daemon (PID 4242)."
fi
exit 0
EOF
chmod +x "$mock_qmd"

# A fixed, verified-free test port for QMD_MCP_URL: the fix under test adds a
# raw TCP connect probe (distinct from the mocked curl probe below), which
# makes REAL localhost connections - it must never point at the real qmd
# daemon's port (8181, commonly live on this machine) or every existing case
# here would race a live process instead of the dead port they assume.
test_port="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
bash -c "(exec 3<>/dev/tcp/127.0.0.1/$test_port) 2>/dev/null" && \
  fail "precondition: chosen test port $test_port is unexpectedly held"
test_url="http://127.0.0.1:$test_port/mcp"

# run_ensure <curl-mode> <path> -> sets global rc/out.
# QMD_MOCK_HANG / QMD_START_TIMEOUT / QMD_MCP_URL pass through from the
# caller's scope (QMD_MCP_URL defaults to the hermetic test_port above).
run_ensure() {
  rm -f "$state/qmd-argv.log"
  set +e
  out="$(QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE="$1" QMD_MOCK_STATE="$state" \
    QMD_MOCK_HANG="${QMD_MOCK_HANG:-0}" QMD_START_TIMEOUT="${QMD_START_TIMEOUT:-20}" \
    QMD_MCP_URL="${QMD_MCP_URL:-$test_url}" \
    HOME="$home" PATH="$2" \
    bash "$script" 2>&1)"
  rc=$?
  set -e
}
set -e

# ---- (a) alive short-circuit: qmd never invoked ----------------------------
run_ensure alive "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(a) alive: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(a) alive: qmd was invoked but should have been skipped"
echo "ok (a): alive endpoint short-circuits, qmd not invoked"

# ---- (b) dead -> start daemon -> comes alive -------------------------------
rm -f "$state/alive"
run_ensure sentinel "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(b) dead->alive: expected rc 0, got $rc ($out)"
[ -f "$state/qmd-argv.log" ] || fail "(b) dead->alive: qmd was never invoked"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(b) dead->alive: qmd not called with 'mcp --http --daemon' (got: $(cat "$state/qmd-argv.log"))"
echo "ok (b): dead endpoint starts daemon (qmd mcp --http --daemon) then goes alive"

# ---- (b2) daemon cwd is $HOME, never the caller's cwd (HIMMEL-4334) ----------
# The daemon outlives the session that started it; inheriting a worktree cwd
# pinned that worktree ("in use") long after its PR merged.
rm -f "$state/alive" "$state/qmd-cwd.log"
mkdir -p "$work/caller-wt"
pushd "$work/caller-wt" >/dev/null
run_ensure sentinel "$bin:$safe"
popd >/dev/null
[ "$rc" -eq 0 ] || fail "(b2) daemon cwd: expected rc 0, got $rc ($out)"
want_cwd="$(cd "$home" && pwd -P)"
[ "$(cat "$state/qmd-cwd.log" 2>/dev/null)" = "$want_cwd" ] || \
  fail "(b2) daemon cwd: expected $want_cwd, got '$(cat "$state/qmd-cwd.log" 2>/dev/null)'"
echo "ok (b2): daemon starts with cwd \$HOME, not the caller's cwd"

# ---- (c) qmd missing entirely ----------------------------------------------
# PATH without the mock bin dir -> PATH lookup and the bun-bin fallback
# (empty temp HOME) both fail -> not-installed error.
rm -f "$state/alive"
run_ensure dead "$safe"
[ "$rc" -ne 0 ] || fail "(c) qmd-missing: expected nonzero rc"
printf '%s' "$out" | grep -q "not installed" || \
  fail "(c) qmd-missing: missing 'not installed' remediation (got: $out)"
echo "ok (c): qmd missing -> nonzero with install hint"

# ---- (d) foreign listener on the port --------------------------------------
run_ensure foreign "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(d) foreign: expected nonzero rc"
printf '%s' "$out" | grep -qi "not qmd" || \
  fail "(d) foreign: missing 'not qmd' port-taken message (got: $out)"
echo "ok (d): foreign listener -> nonzero with port-taken message"

# ---- (d2) sneaky foreign listener: name:qmd OUTSIDE serverInfo ---------------
# Reply contains a "name":"qmd" pair inside a tools array but a DIFFERENT
# serverInfo name -> must still classify as foreign (serverInfo-scoped match).
run_ensure sneaky "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(d2) sneaky: expected nonzero rc"
printf '%s' "$out" | grep -qi "not qmd" || \
  fail "(d2) sneaky: missing 'not qmd' port-taken message (got: $out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(d2) sneaky: qmd was invoked but should not have been"
echo "ok (d2): name:qmd outside serverInfo still classified foreign"

# ---- (e) hung daemon start is bounded ---------------------------------------
rm -f "$state/alive"
t0="$(date +%s)"
QMD_MOCK_HANG=1 QMD_START_TIMEOUT=2 run_ensure dead "$bin:$safe"
t1="$(date +%s)"
dur=$((t1 - t0))
[ "$rc" -ne 0 ] || fail "(e) hang: expected nonzero rc"
[ "$dur" -lt 15 ] || fail "(e) hang: not bounded - took ${dur}s with QMD_START_TIMEOUT=2"
printf '%s' "$out" | grep -q "timed out" || \
  fail "(e) hang: missing 'timed out' message (got: $out)"
printf '%s' "$out" | grep -q "mcp.log" || \
  fail "(e) hang: missing 'mcp.log' pointer (got: $out)"
echo "ok (e): hung daemon start bounded (${dur}s) with clear timeout message"

# ---- (f) start "succeeds" but the probe never comes alive --------------------
# curl stays dead the whole time; the fast mock qmd exits 0 as if it started.
# The wait loop exhausts its 5 probes (~4s of sleeps) and fails loudly,
# echoing the captured qmd start output back (the start_out passthrough).
rm -f "$state/alive"
run_ensure dead "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(f) never-alive: expected nonzero rc"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(f) never-alive: qmd start was never attempted"
printf '%s' "$out" | grep -q "nothing came alive" || \
  fail "(f) never-alive: missing 'nothing came alive' message (got: $out)"
printf '%s' "$out" | grep -q "mcp.log" || \
  fail "(f) never-alive: missing 'mcp.log' pointer (got: $out)"
printf '%s' "$out" | grep -q "Started qmd HTTP daemon (PID 4242)." || \
  fail "(f) never-alive: qmd start output not passed through (got: $out)"
echo "ok (f): start-ok-but-never-alive exhausts the wait loop with start output passed through"

# ---- (g) timeout(1) absent: degrade branch still starts the daemon ----------
# In Git Bash, timeout(1) shares /usr/bin with every other coreutil, so a PATH
# that "omits timeout's dir" would also lose grep/sed/bash. Instead build a
# restricted bin of absolute-shebang wrapper scripts for ONLY the tools the
# ensure script and the mocks need (timeout deliberately absent), and assert
# the precondition that `command -v timeout` really fails on that PATH.
rbin="$work/rbin"
mkdir -p "$rbin"
real_bash="$(command -v bash)"
for t in bash grep sed sleep touch mkdir cat rm find rmdir; do
  real="$(command -v "$t")"
  printf '#!%s\nexec "%s" "$@"\n' "$real_bash" "$real" > "$rbin/$t"
  chmod +x "$rbin/$t"
done
cp "$mock_qmd" "$rbin/qmd"
chmod +x "$rbin/qmd"
if PATH="$rbin" "$real_bash" -c 'command -v timeout' >/dev/null 2>&1; then
  fail "(g) precondition: timeout still resolvable on the restricted PATH"
fi
rm -f "$state/alive"
run_ensure sentinel "$rbin"
[ "$rc" -eq 0 ] || fail "(g) no-timeout: expected rc 0, got $rc ($out)"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(g) no-timeout: degrade branch did not invoke qmd with 'mcp --http --daemon'"
echo "ok (g): timeout(1) absent -> unbounded degrade branch still starts the daemon"

# ---- (h) bun-global bin preferred over a PATH qmd ----------------------------
# Populate $HOME/.bun/bin/qmd (records that the bun copy ran, brings the
# daemon alive) and put a DECOY qmd on PATH that would fail loudly if invoked.
mkdir -p "$home/.bun/bin"
cat > "$home/.bun/bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-bun.log"
if [ "$*" = "mcp --http --daemon" ]; then
  touch "$QMD_MOCK_STATE/alive"
fi
exit 0
EOF
chmod +x "$home/.bun/bin/qmd"
decoy_bin="$work/decoy-bin"
mkdir -p "$decoy_bin"
cat > "$decoy_bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-decoy.log"
echo "DECOY qmd invoked - bun-first resolution is broken" >&2
exit 1
EOF
chmod +x "$decoy_bin/qmd"
rm -f "$state/alive" "$state/qmd-bun.log" "$state/qmd-decoy.log"
run_ensure sentinel "$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(h) bun-first: expected rc 0, got $rc ($out)"
[ -f "$state/qmd-bun.log" ] || fail "(h) bun-first: bun copy was not invoked"
grep -qx 'mcp --http --daemon' "$state/qmd-bun.log" || \
  fail "(h) bun-first: bun copy not called with 'mcp --http --daemon'"
[ ! -f "$state/qmd-decoy.log" ] || fail "(h) bun-first: PATH decoy qmd was invoked"
echo "ok (h): bun-global qmd preferred over the PATH decoy"

# ---- (i) bun + global qmd.js preferred over the bun bin shim -----------------
# HIMMEL-928: create the bun-global dist/cli/qmd.js and a mock `bun`; the (h)
# bun-bin shim and the PATH decoy stay in place - the `bun <qmd.js>` invocation
# must win them both, so the daemon child inherits bun's execPath (the bin
# shim honors the CLI's node shebang and would hand the daemon to node, where
# the bun-ABI better-sqlite3 prebuild refuses to load).
mkdir -p "$home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
touch "$home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
cat > "$bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-bunjs.log"
case "$*" in
  */dist/cli/qmd.js\ mcp\ --http\ --daemon) touch "$QMD_MOCK_STATE/alive" ;;
esac
exit 0
EOF
chmod +x "$bin/bun"
rm -f "$state/alive" "$state/qmd-bun.log" "$state/qmd-decoy.log" "$state/qmd-bunjs.log"
run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i) bun-js-first: expected rc 0, got $rc ($out)"
[ -f "$state/qmd-bunjs.log" ] || fail "(i) bun-js-first: bun + qmd.js was not invoked"
grep -q 'dist/cli/qmd.js mcp --http --daemon' "$state/qmd-bunjs.log" || \
  fail "(i) bun-js-first: bun not called with '<qmd.js> mcp --http --daemon' (got: $(cat "$state/qmd-bunjs.log"))"
[ ! -f "$state/qmd-bun.log" ] || fail "(i) bun-js-first: bun bin shim was invoked but the js path should win"
[ ! -f "$state/qmd-decoy.log" ] || fail "(i) bun-js-first: PATH decoy qmd was invoked"
echo "ok (i): bun + global qmd.js preferred over the bun bin shim and PATH"

# ---- (i2) BUN_INSTALL override is honored for the bun-js resolution ----------
# Parity with qmd-bin.sh's own BUN_INSTALL test: the two resolvers are
# documented mirrors, so both must honor a relocated bun root. The DEFAULT
# $HOME/.bun global qmd.js stays in place - the override must win over it.
mkdir -p "$work/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
touch "$work/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rm -f "$state/alive" "$state/qmd-bunjs.log" "$state/qmd-bun.log" "$state/qmd-decoy.log"
BUN_INSTALL="$work/custom-bun" run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i2) BUN_INSTALL: expected rc 0, got $rc ($out)"
grep -q 'custom-bun' "$state/qmd-bunjs.log" || \
  fail "(i2) BUN_INSTALL: override path not used (got: $(cat "$state/qmd-bunjs.log" 2>/dev/null))"
echo "ok (i2): BUN_INSTALL override honored for the bun-js resolution"

# ---- (i3) bun present but global qmd.js ABSENT -> falls back to bun bin shim -
# Pins the [ -f qmd.js ] && command -v bun conjunction: bun alone must NOT
# select the js invocation; the (h) bun-bin shim mock takes over instead.
rm -f "$home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rm -f "$state/alive" "$state/qmd-bunjs.log" "$state/qmd-bun.log" "$state/qmd-decoy.log"
run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i3) js-absent fallback: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-bunjs.log" ] || fail "(i3) js-absent fallback: bun-js invoked despite missing qmd.js"
[ -f "$state/qmd-bun.log" ] || fail "(i3) js-absent fallback: bun bin shim was not invoked"
grep -qx 'mcp --http --daemon' "$state/qmd-bun.log" || \
  fail "(i3) js-absent fallback: shim not called with 'mcp --http --daemon'"
echo "ok (i3): bun present without global qmd.js falls back to the bun bin shim"

# ---- (i4) BUN_INSTALL override + missing qmd.js -> shim under the SAME root -
# CodeRabbit (PR #1134): (i2) covered override+js-present and (i3) covered
# default-root+js-missing, but never the combination - which is exactly where
# a $HOME-hardcoded shim fallback breaks under a relocated bun root. The shim
# must resolve from $BUN_INSTALL/bin, not $HOME/.bun/bin.
rm -f "$work/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
mkdir -p "$work/custom-bun/bin"
cat > "$work/custom-bun/bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-custom-shim.log"
if [ "$*" = "mcp --http --daemon" ]; then
  touch "$QMD_MOCK_STATE/alive"
fi
exit 0
EOF
chmod +x "$work/custom-bun/bin/qmd"
rm -f "$state/alive" "$state/qmd-bunjs.log" "$state/qmd-bun.log" "$state/qmd-decoy.log" "$state/qmd-custom-shim.log"
BUN_INSTALL="$work/custom-bun" run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i4) override+js-absent: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-bunjs.log" ] || fail "(i4) override+js-absent: bun-js invoked despite missing qmd.js"
[ -f "$state/qmd-custom-shim.log" ] || fail "(i4) override+js-absent: BUN_INSTALL/bin shim was not used"
grep -qx 'mcp --http --daemon' "$state/qmd-custom-shim.log" || \
  fail "(i4) override+js-absent: custom shim not called with 'mcp --http --daemon'"
[ ! -f "$state/qmd-bun.log" ] || fail "(i4) override+js-absent: default \$HOME shim used instead of the BUN_INSTALL root"
echo "ok (i4): BUN_INSTALL override + missing qmd.js falls back to the override root's shim"

# ---- (j) port held by a dying process delays the start (HIMMEL-3062) --------
# A fixture binds+listens on a REAL localhost port (no MCP handshake - a raw
# TCP connect should still see it as held) for hold_secs seconds, then
# releases it - simulating the ~15s bun-thread unwind window after SIGTERM on
# a killed daemon. The mocked MCP probe ("sentinel" mode) reports dead the
# whole time, until the mock qmd sets the alive sentinel after it is invoked.
# Assert: qmd start is NOT attempted while the fixture still holds the port,
# and it IS attempted (and succeeds) once the fixture releases it.
# Reset the bun-shim artifacts left by cases (h)-(i4) so resolve_qmd falls
# through to the plain PATH mock at $bin/qmd (the one this case asserts on).
rm -rf "$home/.bun"
rm -f "$state/alive" "$state/qmd-argv.log"
hold_port="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
hold_secs=3
python3 - "$hold_port" "$hold_secs" <<'PY' &
import socket, sys, time
port = int(sys.argv[1])
hold = float(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(128)
# Drain the accept queue for the whole hold: BSD/macOS refuses further connects
# once a never-accepting listener's backlog is full, which would read as "port
# free" to the script under test.
s.settimeout(0.2)
end = time.time() + hold
while time.time() < end:
    try:
        s.accept()[0].close()
    except socket.timeout:
        pass
s.close()
PY
fixture_pid=$!
# Give the fixture a moment to actually bind before the script starts probing.
sleep 0.5
bash -c "(exec 3<>/dev/tcp/127.0.0.1/$hold_port) 2>/dev/null" || \
  fail "(j) precondition: fixture on port $hold_port is not actually held"

(
  QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
    QMD_MCP_URL="http://127.0.0.1:$hold_port/mcp" \
    HOME="$home" PATH="$bin:$safe" \
    bash "$script" > "$work/j-out.log" 2>&1
) &
ensure_pid=$!

sleep 2
[ ! -f "$state/qmd-argv.log" ] || \
  fail "(j) port-held: qmd was invoked while the fixture still held the port (raced a dying process)"

wait "$fixture_pid" 2>/dev/null
wait "$ensure_pid"
rc=$?
[ "$rc" -eq 0 ] || fail "(j) port-held: expected rc 0 once the port freed, got $rc ($(cat "$work/j-out.log"))"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(j) port-held: qmd was never invoked after the port freed"
echo "ok (j): dying process holding the port delays the daemon start until it releases"

# ---- (k)-(n) memory ceiling + detached self-recycle (HIMMEL-3062) -----------
# A fake "daemon" (a real process, so kill/kill -0 are real) is named by a
# pidfile under a scratch XDG_CACHE_HOME; a mock ps reports its RSS. The fake
# models the ~15s bun unwind: on SIGTERM it takes UNWIND seconds to exit, then
# drops the alive sentinel (the MCP probe goes dead) the way a real exit would.
xdg="$work/xdg"
mkdir -p "$xdg/qmd"
mock_ps="$bin/ps"
cat > "$mock_ps" <<'EOF'
#!/usr/bin/env bash
# Mimics `ps -o rss= -o etime= -o args= -p <pid>`: prints nothing and exits 1
# for a dead pid, like real ps.
pid="${!#}"
kill -0 "$pid" 2>/dev/null || exit 1
echo "$*" >> "$QMD_MOCK_STATE/ps-argv.log"
printf '%s 04:31:07 bun /x/dist/cli/qmd.js mcp --http --port 8181\n' "$QMD_MOCK_RSS_KB"
EOF
chmod +x "$mock_ps"
fake_daemon="$work/fake-daemon.sh"
cat > "$fake_daemon" <<'EOF'
#!/usr/bin/env bash
trap 'sleep "${UNWIND:-0}"; rm -f "$QMD_MOCK_STATE/alive"; exit 0' TERM
touch "$QMD_MOCK_STATE/alive"
while :; do sleep 1; done
EOF
chmod +x "$fake_daemon"

start_fake_daemon() { # <unwind secs> -> sets fake_pid, writes the pidfile
  UNWIND="$1" QMD_MOCK_STATE="$state" bash "$fake_daemon" &
  fake_pid=$!
  STUB_PIDS+=("$fake_pid")
  echo "$fake_pid" > "$xdg/qmd/mcp.pid"
  local i=0
  while [ ! -f "$state/alive" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
  [ -f "$state/alive" ] || fail "precondition: fake daemon never came alive"
  [ "$QMD_TEST_FORCE_FAIL_AFTER" != "start_fake_daemon" ] || \
    fail "forced failure after start_fake_daemon (HIMMEL-3775 leak-test hook)"
}

# run_ceiling <rss_kb> [<ceiling_mb>] -> sets rc/out/dur; the hook's own wall time
run_ceiling() {
  rm -f "$state/qmd-argv.log"
  local t0 t1
  t0="$(date +%s)"
  set +e
  out="$(QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
    QMD_MOCK_RSS_KB="$1" QMD_PS="$mock_ps" XDG_CACHE_HOME="$xdg" \
    QMD_RSS_CEILING_MB="${2:-4096}" QMD_MCP_URL="$test_url" \
    HOME="$home" PATH="$bin:$safe" \
    bash "$script" 2>&1)"
  rc=$?
  set -e
  t1="$(date +%s)"
  dur=$((t1 - t0))
}

# Wait (bounded) for the detached recycler to finish: it restarted qmd and
# logged its restart rc (the lock is released right after that line).
wait_restarted() {
  local i=0
  while [ "$i" -lt 40 ]; do
    grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" 2>/dev/null &&
      grep -q 'recycle: restart rc=' "$xdg/qmd/recycle.log" 2>/dev/null &&
      [ ! -d "$xdg/qmd/recycle.lock" ] && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

# ---- (k) under the ceiling: no recycle, daemon untouched --------------------
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp"
start_fake_daemon 0
run_ceiling 1048576   # 1 GB
[ "$rc" -eq 0 ] || fail "(k) under-ceiling: expected rc 0, got $rc ($out)"
[ -f "$state/ps-argv.log" ] || fail "(k) under-ceiling: RSS was never read (ps not called) ($out)"
sleep 1
kill -0 "$fake_pid" 2>/dev/null || fail "(k) under-ceiling: daemon was killed below the ceiling"
[ ! -f "$state/qmd-argv.log" ] || fail "(k) under-ceiling: qmd was restarted below the ceiling"
kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null
echo "ok (k): RSS under the ceiling leaves the daemon alone"

# ---- (l) over the ceiling: hook returns promptly, recycle runs DETACHED -----
# The fake takes 4s to unwind; the hook must not wait for it (SessionStart
# budget, HIMMEL-1844) - it returns at once and the recycler finishes later.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
start_fake_daemon 4
run_ceiling 7340032   # 7 GB
[ "$rc" -eq 0 ] || fail "(l) over-ceiling: expected rc 0, got $rc ($out)"
[ "$dur" -lt 3 ] || fail "(l) over-ceiling: hook blocked ${dur}s on the recycle (must run detached)"
grep -q "recycling" <<< "$out" || \
  fail "(l) over-ceiling: no loud 'recycling' line (got: $out)"
kill -0 "$fake_pid" 2>/dev/null || true
wait_restarted || fail "(l) over-ceiling: detached recycler never restarted qmd ($(cat "$xdg/qmd/recycle.log" 2>/dev/null))"
kill -0 "$fake_pid" 2>/dev/null && fail "(l) over-ceiling: old daemon still alive after the recycle"
[ -f "$xdg/qmd/recycle.stamp" ] || fail "(l) over-ceiling: no recycle stamp written"
grep -q 'recycle: restart rc=0' "$xdg/qmd/recycle.log" || \
  fail "(l) over-ceiling: restart did not succeed ($(cat "$xdg/qmd/recycle.log"))"
echo "ok (l): over the ceiling -> hook returned in ${dur}s, detached recycler stopped + restarted qmd"

# ---- (m) cooldown: a fresh stamp blocks a second recycle --------------------
rm -f "$state/alive" "$state/ps-argv.log"
start_fake_daemon 0
run_ceiling 7340032
[ "$rc" -eq 0 ] || fail "(m) cooldown: expected rc 0, got $rc ($out)"
sleep 1
kill -0 "$fake_pid" 2>/dev/null || fail "(m) cooldown: daemon recycled again inside the cooldown"
grep -q "cooldown" <<< "$out" || fail "(m) cooldown: skip not reported (got: $out)"
kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null
echo "ok (m): a recycle inside the cooldown window is skipped"

# ---- (n) stampede: concurrent sessions start ONE recycle ---------------------
rm -f "$state/alive" "$state/ps-argv.log" "$state/qmd-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
start_fake_daemon 3
for s in 1 2 3 4 5; do
  ( QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
      QMD_MOCK_RSS_KB=7340032 QMD_PS="$mock_ps" XDG_CACHE_HOME="$xdg" \
      QMD_RSS_CEILING_MB=4096 QMD_MCP_URL="$test_url" \
      HOME="$home" PATH="$bin:$safe" \
      bash "$script" > "$work/n-$s.log" 2>&1 ) &
done
wait_restarted || fail "(n) stampede: no recycle happened"
sleep 2
starts="$(grep -c 'SIGTERM' "$xdg/qmd/recycle.log" 2>/dev/null || true)"
[ "$starts" = 1 ] || fail "(n) stampede: expected exactly 1 recycle, got ${starts:-0} ($(cat "$xdg/qmd/recycle.log" 2>/dev/null))"
kill "$fake_pid" 2>/dev/null || true
wait 2>/dev/null || true
echo "ok (n): five concurrent sessions over the ceiling ran exactly one recycle"

# ---- (o) leading-zero knobs are decimal, never octal -------------------------
# `08` is not a valid octal literal: Bash arithmetic on it aborts the hook.
# `00` is zero, so it disables the ceiling exactly like `0`.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.log"
date +%s > "$xdg/qmd/recycle.stamp"
start_fake_daemon 0
run_ceiling 7340032 08
[ "$rc" -eq 0 ] || fail "(o) ceiling 08: expected rc 0, got $rc ($out)"
grep -q "ceiling 8 MB" <<< "$out" || fail "(o) ceiling 08: not read as 8 MB (got: $out)"
run_ceiling 7340032 00
[ "$rc" -eq 0 ] || fail "(o) ceiling 00: expected rc 0, got $rc ($out)"
grep -q "ceiling" <<< "$out" && fail "(o) ceiling 00: must disable the ceiling (got: $out)"
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
echo "ok (o): ceiling 08 reads as 8 MB, 00 disables it"

# ---- (p) a lock whose owner has not yet written its 'at' is not stale --------
# A winner is between its mkdir and its 'at' write: a second session must judge
# the lock by the directory's own age, not reclaim it as ancient.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
mkdir "$xdg/qmd/recycle.lock"
start_fake_daemon 0
run_ceiling 7340032
[ "$rc" -eq 0 ] || fail "(p) fresh lock: expected rc 0, got $rc ($out)"
grep -q "recycling" <<< "$out" && fail "(p) fresh lock without 'at' was reclaimed (got: $out)"
[ -d "$xdg/qmd/recycle.lock" ] || fail "(p) fresh lock without 'at' was removed"
kill -0 "$fake_pid" 2>/dev/null || fail "(p) daemon recycled while another session held the lock"
rm -rf "$xdg/qmd/recycle.lock"
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
echo "ok (p): a fresh lock with no 'at' file is left to its owner"

# ---- (q) a stale lock is cleared, never taken over in the same run -----------
# Two sessions that both judged one lock stale could each remove the other's
# fresh lock and both recycle; so the reclaimer only clears it, and the next
# session start takes the lock through a plain mkdir.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
mkdir "$xdg/qmd/recycle.lock"
echo $(( $(date +%s) - 300 )) > "$xdg/qmd/recycle.lock/at"
start_fake_daemon 0
run_ceiling 7340032
[ "$rc" -eq 0 ] || fail "(q) stale lock: expected rc 0, got $rc ($out)"
grep -q "recycling" <<< "$out" && fail "(q) stale lock: the reclaiming run also recycled (got: $out)"
[ ! -d "$xdg/qmd/recycle.lock" ] || fail "(q) stale lock: not cleared"
run_ceiling 7340032
grep -q "recycling" <<< "$out" || fail "(q) stale lock: the next session did not recycle (got: $out)"
wait_restarted || fail "(q) stale lock: recycle after the clear never finished ($(cat "$xdg/qmd/recycle.log" 2>/dev/null))"
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
echo "ok (q): a stale lock is cleared, and the next session recycles"

# ---- (r) an embed-model swap in progress: the daemon is NOT started (HIMMEL-4314) --
# qmd-embed-model.sh swap holds <cache>/qmd/embed-swap.lock (holder pid inside)
# from its liveness check to its commit/rollback. A daemon relaunched in that
# window served gemma query embeddings against qwen vectors. Every start path
# refuses while the holder is alive; a dead holder's lock is stale and cleared.
swap_lock="$home/.cache/qmd/embed-swap.lock"
rm -f "$state/alive"
mkdir -p "$swap_lock"
sleep 30 &
holder_pid=$!
echo "$holder_pid" > "$swap_lock/pid"
echo swap > "$swap_lock/role"
run_ensure sentinel "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(r) swap held: expected a refusal, got rc 0 ($out)"
grep -q "swap" <<< "$out" || fail "(r) swap held: refusal does not name the swap (got: $out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(r) swap held: qmd was invoked ($(cat "$state/qmd-argv.log"))"
[ -d "$swap_lock" ] || fail "(r) swap held: a LIVE holder's lock was removed"
echo "ok (r): a live swap lock refuses the daemon start, qmd not invoked, lock kept"

# ---- (s) the swap's holder died: stale lock cleared, daemon starts -----------
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$state/alive"
# another contender is mid-reclaim (its guard is fresh): do not clear under it,
# or both could win the lock
mkdir "$swap_lock.reclaim"
run_ensure sentinel "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(s) reclaim in flight: expected a refusal, got rc 0 ($out)"
[ -d "$swap_lock" ] || fail "(s) reclaim in flight: the stale lock was cleared under another reclaimer"
[ ! -f "$state/qmd-argv.log" ] || fail "(s) reclaim in flight: qmd was invoked"
rmdir "$swap_lock.reclaim"
run_ensure sentinel "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(s) stale swap lock: expected rc 0, got $rc ($out)"
[ ! -d "$swap_lock" ] || fail "(s) stale swap lock: not cleared"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || fail "(s) stale swap lock: the daemon was not started"
echo "ok (s): a swap lock whose holder is dead is cleared and the daemon starts"

# ---- (t) the start itself holds the lock, so a swap cannot slip in (HIMMEL-4314) --
# Checking the lock and then starting leaves a window: a swap could take the lock
# between the two and pass its own liveness checks. The start path takes the same
# lock around the start, so a swap started meanwhile is refused, and releases it.
rm -f "$state/alive" "$state/lock-at-start"
export QMD_MOCK_LOCK_DIR="$swap_lock"
run_ensure sentinel "$bin:$safe"
unset QMD_MOCK_LOCK_DIR
[ "$rc" -eq 0 ] || fail "(t) start: expected rc 0, got $rc ($out)"
grep -qx held "$state/lock-at-start" 2>/dev/null || fail "(t) start: the swap lock was not held while the daemon started ($(cat "$state/lock-at-start" 2>/dev/null))"
[ ! -d "$swap_lock" ] || fail "(t) start: the lock was not released after the start"
echo "ok (t): the daemon start holds the swap lock and releases it"

# ---- (u) two sessions start together: neither is told a swap is running -------
# The console launches several legs within a second, so two SessionStart hooks
# race for the lock. The loser sees an ENSURE holder, not a swap: it exits 0
# quietly (the other start is already on it), never "swap in progress".
rm -f "$state/alive" "$state/qmd-argv.log"
export QMD_MOCK_SLOW=2
u_pids=""
for n in 1 2; do
  (
    set +e
    QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
      QMD_START_TIMEOUT=20 QMD_MCP_URL="$test_url" HOME="$home" PATH="$bin:$safe" \
      bash "$script" > "$state/u$n.out" 2>&1
    echo "$?" > "$state/u$n.rc"
  ) &
  u_pids="$u_pids $!"
  sleep 0.3
done
# shellcheck disable=SC2086 # word-split the pid list on purpose
wait $u_pids
unset QMD_MOCK_SLOW
for n in 1 2; do
  [ "$(cat "$state/u$n.rc")" = "0" ] || fail "(u) concurrent start $n: expected rc 0, got $(cat "$state/u$n.rc") ($(cat "$state/u$n.out"))"
  if grep -q "swap" "$state/u$n.out"; then fail "(u) concurrent start $n: told a swap is in progress ($(cat "$state/u$n.out"))"; fi
done
[ "$(grep -c '^mcp --http --daemon$' "$state/qmd-argv.log")" = "1" ] || fail "(u) concurrent starts: expected exactly one daemon start ($(cat "$state/qmd-argv.log"))"
[ ! -d "$swap_lock" ] || fail "(u) concurrent starts: the lock was not released"
echo "ok (u): two concurrent starts both exit 0, no swap message, one daemon start"

# ---- (v) a live holder with no role yet is treated as a swap (conservative) ---
rm -f "$state/alive"
mkdir -p "$swap_lock"
sleep 30 &
holder_pid=$!
echo "$holder_pid" > "$swap_lock/pid"
run_ensure sentinel "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(v) role-less live holder: expected a refusal, got rc 0 ($out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(v) role-less live holder: qmd was invoked"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -rf "$swap_lock"
echo "ok (v): a live holder with no role is refused like a swap"

echo "PASS: all ensure-qmd-daemon cases"
