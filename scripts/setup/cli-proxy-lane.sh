#!/usr/bin/env bash
# scripts/setup/cli-proxy-lane.sh — Linux bring-up for the claudex lane
# (HIMMEL-2778). Twin of scripts/setup/cli-proxy-lane.ps1 (Windows). bash
# 3.2-safe.
#
# The proxy is a HOST process on 127.0.0.1:8317, backed by CLIProxyAPI
# (router-for-me/CLIProxyAPI), exposing an Anthropic-compatible API over an
# OAuth-authenticated OpenAI codex subscription. scripts/claude-codex is the
# consumer.
#
# Per-host order:  --install  ->  --login (once)  ->  --register
# Run with no flag for a status report + the next command to run.
#
# Lifecycle: --stop / --restart bounce the running instance. They refuse
# while a client is actively connected (a bounce kills an in-flight
# codex-lane render) unless --force is given.
#
# Usage:
#   cli-proxy-lane.sh --install            download binary + write config.yaml
#   cli-proxy-lane.sh --login              one-time codex OAuth (device-code flow)
#   cli-proxy-lane.sh --register           systemd --user unit, starts now + at login
#   cli-proxy-lane.sh --start              foreground (debugging; Ctrl-C to stop)
#   cli-proxy-lane.sh --stop               stop the running proxy
#   cli-proxy-lane.sh --restart            bounce the proxy
#   cli-proxy-lane.sh --verify             one-line reachability probe
#   cli-proxy-lane.sh --status             multi-line status report
#   cli-proxy-lane.sh --force              override the bounce-safety guard
#
# CLIPROXY_API_KEY is never hardcoded: --install requires it set (env or the
# repo .env, loaded by name via scripts/lib/load-dotenv.sh) and writes it into
# ~/.cli-proxy-api/config.yaml (mode 0600).
set -u

DIR="$HOME/.cli-proxy-api"
EXE="$DIR/cli-proxy-api"
CFG="$DIR/config.yaml"
VER_STAMP="$DIR/cli-proxy-api.version"
PORT=8317
VERSION="7.2.154"
RELEASE_BASE="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${VERSION}"
ASSET="CLIProxyAPI_${VERSION}_linux_amd64.tar.gz"
RELEASE_URL="${RELEASE_BASE}/${ASSET}"
# Pinned sha256 of the linux_amd64 asset at v7.2.154, verified against the
# release's own checksums.txt (HIMMEL-2778, re-pinned HIMMEL-2816). Upstream DOES publish per-asset
# checksums as of this version — the .ps1's "upstream publishes no per-asset
# checksum" comment is stale; not corrected here (out of scope, Windows file).
ASSET_SHA256="2a2256ceff048d5fa813aa54e8daa43e870b40e698d5cd21efad46e25aa5a1f9"

UNIT_NAME="cli-proxy-api.service"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"

HERE="$(cd "$(dirname "$0")" && pwd)"

TMP_DIR=""
# shellcheck disable=SC2329,SC2317  # invoked indirectly via the EXIT trap
# below (SC2329 on shellcheck 0.11+, SC2317 on the older engine bundled by
# pre-commit's shellcheck-py v0.10.0.1 -- same false positive, different code)
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

die() { echo "cli-proxy-lane: $*" >&2; exit 1; }

# The pinned RELEASE_URL/ASSET_SHA256 below are for linux_amd64 only -- no
# other Linux arch's checksum has been verified against upstream's
# checksums.txt, so refuse to install on anything else rather than silently
# writing an unexecutable binary that only fails later, mid --start/--register.
assert_supported_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64 | amd64) return 0 ;;
  esac
  die "unsupported architecture '$m' -- this lane only ships a pinned+verified linux_amd64 asset (v${VERSION})"
}

usage() {
  cat <<'USAGE'
Usage: cli-proxy-lane.sh [--install] [--login] [--register] [--start]
                          [--stop] [--restart] [--verify] [--status] [--force]

No flag = status report. Per-host order: --install -> --login -> --register.
USAGE
}

# --- CLIPROXY_API_KEY (never hardcoded) -------------------------------------
# shellcheck source=../lib/load-dotenv.sh
if [ -z "${CLIPROXY_API_KEY-}" ] && [ -f "$HERE/../lib/load-dotenv.sh" ]; then
  . "$HERE/../lib/load-dotenv.sh"
  load_dotenv --root "$(_load_dotenv_primary_for "${CLI_PROXY_LANE_DOTENV_ROOT:-$HERE/../..}")" CLIPROXY_API_KEY
  # load_dotenv leaves surrounding quotes literal; strip one matching pair
  # (mirrors scripts/claude-codex's own surrounding-quote-strip).
  case "${CLIPROXY_API_KEY-}" in
    \"*\") CLIPROXY_API_KEY="${CLIPROXY_API_KEY#\"}"; CLIPROXY_API_KEY="${CLIPROXY_API_KEY%\"}" ;;
    \'*\') CLIPROXY_API_KEY="${CLIPROXY_API_KEY#\'}"; CLIPROXY_API_KEY="${CLIPROXY_API_KEY%\'}" ;;
  esac
fi

# --- probes ------------------------------------------------------------------

proxy_http_code() {
  # Authenticated HTTP probe (not just a port check): an unrelated listener
  # on $PORT would pass a bare TCP test but not answer /v1/models. --max-time
  # bounds a listener that accepts but never responds (else --verify/--status/
  # --restart can hang indefinitely).
  # --noproxy: loopback traffic (and the bearer key on it) must never route
  # through an external proxy just because http_proxy/ALL_PROXY happens to
  # be set in the caller's environment.
  printf 'header "Authorization: Bearer %s"\n' "${CLIPROXY_API_KEY-}" \
    | curl -s --max-time 5 --noproxy '127.0.0.1' -K - \
      -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null
}

proxy_running() {
  # 200 = up + our key accepted; 401 = up but key rejected (still HTTP).
  local c
  c="$(proxy_http_code)"
  [ "$c" = "200" ] || [ "$c" = "401" ]
}

has_oauth() {
  set -- "$DIR"/codex-*.json
  [ -e "$1" ]
}

lane_workers_live() {
  # Bounce-safety guard (mirrors Test-LaneWorkersLive in the .ps1): an
  # ESTABLISHED TCP connection to the proxy port means a client is connected
  # right now (mid-stream or on a keep-alive) — the exact condition under
  # which a bounce hurts. Conservative on both edges: fails CLOSED (treats
  # "cannot determine" as live) when ss is unavailable.
  if ! command -v ss >/dev/null 2>&1; then
    echo "cli-proxy-lane: WARNING: 'ss' not found — cannot verify no client is connected; treating as live (refusing bounce). Install iproute2, or pass --force." >&2
    return 0
  fi
  local out ss_rc
  out="$(ss -Htn state established "( sport = :${PORT} )" 2>/dev/null)"
  ss_rc=$?
  if [ "$ss_rc" -ne 0 ]; then
    echo "cli-proxy-lane: WARNING: 'ss' exited $ss_rc — cannot verify no client is connected; treating as live (refusing bounce). Re-run with --force to override." >&2
    return 0
  fi
  [ -n "$out" ]
}

assert_bounce_safe() {
  [ "$FORCE" = "1" ] && return 0
  if lane_workers_live; then
    die "refusing proxy bounce: a client is actively connected on port ${PORT} (an in-flight codex-lane render would be killed). Re-run with --force to override."
  fi
}

assert_exe() { [ -x "$EXE" ] || die "binary missing at $EXE — run --install first"; }
assert_config() { [ -f "$CFG" ] || die "config missing at $CFG — run --install first"; }

# regex_escape <path> — backslash-escapes BRE metacharacters so a path
# under $HOME (which may legitimately contain ., +, (, ), etc.) can't be
# pasted into pgrep -f's pattern and match the wrong process, or fail to
# match its own.
regex_escape() { printf '%s' "$1" | sed -e 's/[]\.^$*+?(){}|[]/\\&/g'; }

proxy_pid() {
  # Anchored on end-of-string only (no trailing "| " alternative): every
  # SERVER invocation (systemd ExecStart, the nohup detached launch, and
  # --start's foreground run) is exactly "$EXE -config $CFG" with nothing
  # after it. --login's device-code flow runs the SAME exe with the SAME
  # -config, plus a trailing -codex-device-login flag -- a "| " alternative
  # here would match that too, letting --stop/--restart kill an in-progress
  # login instead of (or before finding) the actual server.
  local exe_re cfg_re
  exe_re="$(regex_escape "$EXE")"
  cfg_re="$(regex_escape "$CFG")"
  pgrep -f "^${exe_re} -config ${cfg_re}\$" 2>/dev/null | head -n1
}

# listening_pid: PID of whatever the kernel says is bound to
# 127.0.0.1:$PORT right now (ss's own socket table), or empty if ss is
# missing or nothing is listening. Neither is-active text nor a bare HTTP
# probe can be fooled by a same-command-line process racing for the port --
# this can't either, since it comes straight from the kernel.
listening_pid() {
  command -v ss >/dev/null 2>&1 || return 1
  local listen_line
  # The sport filter alone matches ANY local address on that port; we only
  # ever bind 127.0.0.1, so require it in the Local-Address:Port column too
  # -- otherwise something listening on a different address at the same
  # port (e.g. 0.0.0.0) could be mistaken for OUR proxy.
  listen_line="$(ss -Htlnp "( sport = :${PORT} )" 2>/dev/null | grep -F "127.0.0.1:${PORT} " | head -n1)"
  printf '%s' "$listen_line" | sed -n 's/.*pid=\([0-9]\{1,\}\).*/\1/p'
}

# pid_owns_port: is the given PID (a process WE just launched) the one the
# kernel says is actually bound to 127.0.0.1:$PORT? Same rationale as
# unit_owns_port below, for the non-systemd (detached nohup) launch path,
# which has no MainPID to compare against.
pid_owns_port() {
  local pid="$1" listen_pid
  [ -n "$pid" ] || return 1
  listen_pid="$(listening_pid)"
  [ -n "$listen_pid" ] || { echo "cli-proxy-lane: WARNING: 'ss' not found or nothing listening -- cannot verify the launched process owns 127.0.0.1:${PORT}" >&2; return 1; }
  [ "$pid" = "$listen_pid" ]
}

# unit_owns_port: is $UNIT_NAME's OWN tracked process the one actually bound
# to 127.0.0.1:$PORT right now? is-active alone isn't enough -- Type=simple
# marks a unit active as soon as it forks/execs, before it's necessarily
# finished binding, so a foreground proxy that already owns the port can
# satisfy both the HTTP probe and (briefly) is-active while OUR unit is
# still starting or has failed to bind. Comparing the kernel's own socket
# owner (ss) against systemd's own MainPID sidesteps that race entirely:
# neither source can be fooled by a same-command-line process racing us for
# the port.
unit_owns_port() {
  local main_pid
  main_pid="$(systemctl --user show "$UNIT_NAME" --property=MainPID --value 2>/dev/null)"
  [ -n "$main_pid" ] && [ "$main_pid" != "0" ] || return 1
  pid_owns_port "$main_pid"
}

# --- install -------------------------------------------------------------

write_config() {
  [ -n "${CLIPROXY_API_KEY-}" ] || die "CLIPROXY_API_KEY is not set. Add it to the repo .env (never settings.json) or export it in the launching shell, then re-run --install. It must match an api-keys entry in ~/.cli-proxy-api/config.yaml."
  case "$CLIPROXY_API_KEY" in
    *'"'*|*\\*) die "CLIPROXY_API_KEY contains a double-quote or backslash character, which config.yaml's quoted YAML string cannot embed safely; regenerate the key without one." ;;
    *$'\n'*|*$'\r'*) die "CLIPROXY_API_KEY contains a newline or carriage-return character -- a YAML double-quoted scalar folds embedded newlines, which would silently change the key config.yaml actually stores; regenerate the key without one." ;;
  esac
  mkdir -p "$DIR" || die "mkdir -p $DIR failed"
  # host 127.0.0.1 ONLY: the default empty host binds ALL interfaces, which
  # would LAN-expose the OAuth-wrapped subscription endpoint.
  # umask 077 in the subshell: the file is created 0600 from its first byte,
  # never briefly world/group-readable between creation and the chmod below.
  (
    umask 077
    cat > "$CFG" <<CFGEOF
host: "127.0.0.1"
port: ${PORT}
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "${CLIPROXY_API_KEY}"
CFGEOF
  ) || die "writing $CFG failed"
  chmod 600 "$CFG" || die "chmod 600 $CFG failed"
  echo "wrote config: $CFG"
}

install_binary() {
  local installed_ver=""
  [ -f "$VER_STAMP" ] && installed_ver="$(head -n1 "$VER_STAMP" 2>/dev/null)"
  if [ -x "$EXE" ] && [ "$installed_ver" = "$VERSION" ]; then
    echo "binary already present at pinned v${VERSION}: $EXE"
    return 0
  fi
  if [ -x "$EXE" ] && systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null && [ "$FORCE" != "1" ]; then
    die "installed version '${installed_ver:-unknown}' != pinned v${VERSION} and the proxy unit is RUNNING — run 'systemctl --user stop ${UNIT_NAME}' first, then --install, then --register (or pass --force)."
  fi
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cli-proxy-lane.XXXXXX")" || die "mktemp failed"
  echo "downloading CLIProxyAPI v${VERSION} ..."
  curl -sfL -o "$TMP_DIR/$ASSET" "$RELEASE_URL" || die "download failed: $RELEASE_URL"
  local got_sha
  got_sha="$(sha256sum "$TMP_DIR/$ASSET" | awk '{print $1}')"
  [ "$got_sha" = "$ASSET_SHA256" ] || die "checksum mismatch for $ASSET: got $got_sha, expected $ASSET_SHA256 — refusing to install a tampered/corrupt download."
  tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR" || die "extract failed"
  [ -f "$TMP_DIR/cli-proxy-api" ] || die "cli-proxy-api not found in release archive"
  install -m 755 "$TMP_DIR/cli-proxy-api" "$EXE" || die "installing binary to $EXE failed"
  printf '%s\n' "$VERSION" > "$VER_STAMP"
  echo "installed binary: $EXE (v${VERSION})"
}

cmd_install() {
  assert_supported_arch
  mkdir -p "$DIR"
  if [ -f "$CFG" ]; then
    echo "config already present: $CFG"
  else
    write_config
  fi
  install_binary
}

# --- login / register / start ------------------------------------------------

cmd_login() {
  assert_exe; assert_config
  echo "codex device-login: open the printed URL on any browser, enter the code,"
  echo "and sign in with your codex / ChatGPT account. Writes ~/.cli-proxy-api/codex-<email>.json."
  "$EXE" -config "$CFG" -codex-device-login
  local rc=$?
  [ "$rc" -eq 0 ] || die "codex device-login failed (exit $rc)"
}

cmd_register() {
  assert_exe; assert_config
  command -v systemctl >/dev/null 2>&1 || die "'systemctl' not found — not a systemd/Linux host; ${UNIT_NAME} was NOT installed"
  mkdir -p "$UNIT_DIR" || die "mkdir -p $UNIT_DIR failed"
  # ExecStart quoting: a double-quoted systemd command line survives a HOME
  # containing spaces; %%-escaping survives a HOME containing a literal '%'
  # (systemd's own specifier prefix), so registration can't silently point at
  # the wrong path or fail to parse.
  local exe_unit cfg_unit
  exe_unit="${EXE//%/%%}"
  cfg_unit="${CFG//%/%%}"
  cat > "$UNIT_PATH" <<UNITEOF
[Unit]
Description=Himmel claudex lane proxy (CLIProxyAPI, HIMMEL-2778)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
ExecStart="${exe_unit}" -config "${cfg_unit}"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNITEOF
  local unit_rc=$?
  [ "$unit_rc" -eq 0 ] || die "writing $UNIT_PATH failed (exit $unit_rc)"
  systemctl --user daemon-reload || die "systemctl --user daemon-reload failed"
  systemctl --user enable --now "$UNIT_NAME" || die "systemctl --user enable --now ${UNIT_NAME} failed"
  if ! loginctl enable-linger "$(id -un)" 2>/dev/null; then
    echo "cli-proxy-lane: WARNING: loginctl enable-linger failed — the unit will not start before first login. Run manually: loginctl enable-linger $(id -un)" >&2
  fi
  # Type=simple: enable --now can return success before the process has
  # actually finished binding, so probe readiness rather than taking the
  # unit's own report of success at face value. A caller (script or human)
  # checking $? must see a real failure here, not a silently-swallowed one.
  if ! wait_proxy_running 10; then
    die "$UNIT_NAME is enabled but not yet answering on 127.0.0.1:${PORT} within 10s (registered, but not confirmed running -- check with: cli-proxy-lane --status)"
  fi
  # The HTTP probe alone can't tell OUR unit apart from an unrelated process
  # that happens to already own the port (e.g. a stray --start foreground
  # run) -- and neither can is-active by itself, since Type=simple marks a
  # unit active as soon as it forks, before it's necessarily bound. Confirm
  # the unit's own MainPID is what the kernel says is actually listening.
  unit_owns_port || die "127.0.0.1:${PORT} is reachable, but ${UNIT_NAME}'s own tracked process isn't the one listening there -- something else may be answering that port. Run: cli-proxy-lane --status"
  echo "registered + started: $UNIT_NAME"
}

cmd_start() {
  assert_exe; assert_config
  has_oauth || echo "cli-proxy-lane: WARNING: no codex OAuth found — cc-codex will 401 until you run --login" >&2
  echo "starting proxy on 127.0.0.1:${PORT} (Ctrl-C to stop) ..."
  "$EXE" -config "$CFG"
  local rc=$?
  [ "$rc" -eq 0 ] || die "proxy exited with error (exit $rc)"
}

# --- stop / restart ------------------------------------------------------

stop_proxy_now() {
  # Match active AND activating/reloading: after a crash, Restart=on-failure
  # leaves the unit in "activating" (auto-restart armed, no process yet) for
  # up to RestartSec — is-active --quiet misses that window, so a bare "stop"
  # would report nothing to stop while the unit auto-restarts moments later.
  local unit_state
  unit_state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null)"
  case "$unit_state" in
    active | activating | reloading)
      systemctl --user stop "$UNIT_NAME" || die "systemctl --user stop ${UNIT_NAME} failed"
      ;;
  esac
  # Stopping the unit above only touches OUR unit's own tracked process --
  # it says nothing about a separate standalone proxy (a foreground --start
  # left running, or a rogue process that grabbed the port while the unit
  # was still activating after a bind failure) that can be alive at the
  # same time and would otherwise survive --stop entirely, leaving the port
  # held and --restart unable to replace it. Always check for one too,
  # regardless of which branch above ran (a no-op if the unit's own process
  # was the only match and is already gone).
  local pid
  pid="$(proxy_pid)"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  local i=0
  while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && die "proxy process did not exit within 10s"
  return 0
}

proxy_alive() {
  local unit_state
  unit_state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null)"
  case "$unit_state" in
    active | activating | reloading) return 0 ;;
  esac
  [ -n "$(proxy_pid)" ]
}

cmd_stop() {
  assert_bounce_safe
  if proxy_alive; then
    echo "stopping cli-proxy-api ..."
    stop_proxy_now
    echo "stopped."
  else
    echo "no running cli-proxy-api process (nothing to stop)."
  fi
}

start_background() {
  # Prefer the registered unit if enabled; otherwise launch detached, so
  # --restart brings the proxy up regardless of how it was started before.
  # NOHUP_PID (global) records the launched child's own PID so the detached
  # path can be ownership-checked too, same as the unit path -- set empty
  # here so a caller can tell which branch ran.
  NOHUP_PID=""
  if systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
    systemctl --user start "$UNIT_NAME"
  else
    nohup "$EXE" -config "$CFG" >/dev/null 2>&1 &
    NOHUP_PID=$!
    disown 2>/dev/null || true
  fi
}

wait_proxy_running() {
  # Elapsed-time bound, not an iteration count: proxy_running's own curl
  # probe can itself take up to 5s (its --max-time) on a stalled listener,
  # so counting loop iterations let a stall stretch a "20s" wait to ~100s+.
  local timeout="${1:-20}" start
  start="$SECONDS"
  while [ "$((SECONDS - start))" -lt "$timeout" ]; do
    proxy_running && return 0
    sleep 1
  done
  return 1
}

cmd_restart() {
  assert_exe; assert_config
  assert_bounce_safe
  if proxy_alive; then
    echo "stopping cli-proxy-api ..."
    stop_proxy_now
  fi
  echo "relaunching proxy (background) ..."
  start_background || die "launching the proxy failed (systemctl --user start ${UNIT_NAME}, or the detached launch)"
  if ! wait_proxy_running 20; then
    die "proxy did not come up on 127.0.0.1:${PORT} within 20s (run --status, or --start in the foreground to see the error)"
  fi
  # Same ownership check as --register: an HTTP-reachable listener alone
  # doesn't prove OUR launch is what's answering it. When start_background
  # went through the unit, compare against systemd's own MainPID; when it
  # went through the detached nohup fallback (no systemd state to check),
  # compare against the PID that launch itself just returned instead --
  # either way, something we independently know must match the kernel's
  # socket owner before --restart claims success.
  if systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
    unit_owns_port || die "127.0.0.1:${PORT} is reachable, but ${UNIT_NAME}'s own tracked process isn't the one listening there -- something else may be answering that port. Run: cli-proxy-lane --status"
  else
    pid_owns_port "$NOHUP_PID" || die "127.0.0.1:${PORT} is reachable, but the process this --restart just launched (pid ${NOHUP_PID}) isn't the one listening there -- something else may be answering that port. Run: cli-proxy-lane --status"
  fi
  echo "proxy back up on 127.0.0.1:${PORT}."
}

# --- verify / status -------------------------------------------------------

cmd_verify() {
  local code
  code="$(proxy_http_code)"
  echo "proxy http://127.0.0.1:${PORT} -> HTTP ${code}  (200/401 = reachable; 000 = not running)"
  [ "$code" = "200" ] || [ "$code" = "401" ]
}

cmd_status() {
  local has_exe=0 has_cfg=0 has_oa=0 has_unit=0 run=0 authed=1 code

  [ -x "$EXE" ] && has_exe=1
  [ -f "$CFG" ] && has_cfg=1
  has_oauth && has_oa=1
  systemctl --user is-enabled --quiet "$UNIT_NAME" 2>/dev/null && has_unit=1
  code="$(proxy_http_code)"
  case "$code" in
    200) run=1 ;;
    401) run=1; authed=0 ;;
  esac

  echo "== CLIProxyAPI codex lane (127.0.0.1:${PORT}) =="
  if [ "$has_exe" = 1 ]; then echo "binary:      OK   $EXE"; else echo "binary:      MISSING      -> --install"; fi
  if [ "$has_cfg" = 1 ]; then echo "config:      OK   $CFG"; else echo "config:      MISSING      -> --install"; fi
  if [ "$has_oa" = 1 ]; then echo "codex auth:  OK"; else echo "codex auth:  MISSING      -> --login"; fi
  if [ "$has_unit" = 1 ]; then echo "unit:        OK   $UNIT_NAME"; else echo "unit:        not registered -> --register"; fi
  if [ "$run" = 1 ] && [ "$authed" = 1 ]; then
    echo "running:     OK   127.0.0.1:${PORT}"
  elif [ "$run" = 1 ]; then
    echo "running:     OK but UNAUTHENTICATED (HTTP 401) -> CLIPROXY_API_KEY doesn't match config.yaml"
  else
    echo "running:     no             -> --start / --register"
  fi
  echo ""
  if [ "$has_exe" = 0 ] || [ "$has_cfg" = 0 ]; then
    echo "NEXT: cli-proxy-lane.sh --install"
  elif [ "$has_oa" = 0 ]; then
    echo "NEXT: cli-proxy-lane.sh --login   (then --register)"
  elif [ "$run" = 0 ]; then
    echo "NEXT: cli-proxy-lane.sh --register   (or --start for foreground debugging)"
  elif [ "$authed" = 0 ]; then
    echo "NEXT: fix the key in $CFG (--install skips a config.yaml that already exists), then --restart"
  else
    echo "lane is up. Test: bash scripts/claude-codex -p \"reply OK\""
  fi

  [ "$has_exe" = 1 ] && [ "$has_cfg" = 1 ] && [ "$has_oa" = 1 ] && [ "$run" = 1 ] && [ "$authed" = 1 ]
}

# --- dispatch ------------------------------------------------------------

FORCE=0
DO_INSTALL=0
DO_LOGIN=0
DO_REGISTER=0
DO_START=0
DO_STOP=0
DO_RESTART=0
DO_VERIFY=0
DO_STATUS=0

for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    --login) DO_LOGIN=1 ;;
    --register) DO_REGISTER=1 ;;
    --start) DO_START=1 ;;
    --stop) DO_STOP=1 ;;
    --restart) DO_RESTART=1 ;;
    --verify) DO_VERIFY=1 ;;
    --status) DO_STATUS=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $arg (see --help)" ;;
  esac
done

RC=0
[ "$DO_INSTALL" = 1 ] && { cmd_install || RC=$?; }
[ "$DO_LOGIN" = 1 ] && { cmd_login || RC=$?; }
[ "$DO_REGISTER" = 1 ] && { cmd_register || RC=$?; }
[ "$DO_START" = 1 ] && { cmd_start || RC=$?; }
[ "$DO_VERIFY" = 1 ] && { cmd_verify || RC=$?; }
[ "$DO_STOP" = 1 ] && { cmd_stop || RC=$?; }
[ "$DO_RESTART" = 1 ] && { cmd_restart || RC=$?; }
[ "$DO_STATUS" = 1 ] && { cmd_status || RC=$?; }

if [ "$DO_INSTALL" = 0 ] && [ "$DO_LOGIN" = 0 ] && [ "$DO_REGISTER" = 0 ] && \
   [ "$DO_START" = 0 ] && [ "$DO_STOP" = 0 ] && [ "$DO_RESTART" = 0 ] && \
   [ "$DO_VERIFY" = 0 ] && [ "$DO_STATUS" = 0 ]; then
  cmd_status || RC=$?
fi

exit "$RC"
