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
# (h) bun-global bin is preferred over a PATH qmd (resolution order).
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

home="$work/home"
mkdir -p "$home"
state="$work/state"
mkdir -p "$state"
bin="$work/bin"
mkdir -p "$bin"

# ---- SAFE_PATH: coreutil dirs only, captured before we scrub PATH ----------
safe=""
for t in sleep grep sed cat mkdir touch rm dirname env bash timeout date; do
  d="$(dirname "$(command -v "$t")")"
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
  if [ "${QMD_MOCK_HANG:-0}" = "1" ]; then
    exec sleep 60
  fi
  touch "$QMD_MOCK_STATE/alive"
  echo "Started qmd HTTP daemon (PID 4242)."
fi
exit 0
EOF
chmod +x "$mock_qmd"

# run_ensure <curl-mode> <path> -> sets global rc/out.
# QMD_MOCK_HANG / QMD_START_TIMEOUT pass through from the caller's scope.
run_ensure() {
  rm -f "$state/qmd-argv.log"
  set +e
  out="$(QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE="$1" QMD_MOCK_STATE="$state" \
    QMD_MOCK_HANG="${QMD_MOCK_HANG:-0}" QMD_START_TIMEOUT="${QMD_START_TIMEOUT:-20}" \
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
for t in bash grep sed sleep touch; do
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

echo "PASS: all ensure-qmd-daemon cases"
