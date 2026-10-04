#!/usr/bin/env bash
# ensure-qmd-daemon.sh - bring up the shared qmd HTTP MCP daemon if it is not
# already serving on localhost:8181 (HIMMEL-592).
#
# Lives INSIDE the qmd plugin (wired via hooks/hooks.json SessionStart with
# ${CLAUDE_PLUGIN_ROOT}) so it runs from ANY session in ANY repo where the
# plugin is enabled - not just himmel checkouts. The plugin declares an HTTP
# MCP endpoint shared by every Claude session instead of a per-session stdio
# process; this script is that endpoint's startup path. It probes the
# endpoint, exits 0 silently when a qmd daemon already answers, and otherwise
# starts one (idempotent) and waits for it to come alive. Cheap on the healthy
# path (one local curl); loud on failure (clear remediation, never a silent
# empty index).
#
# Foreign-listener safety: a non-qmd process holding port 8181 must NOT count
# as "alive" - the probe validates the MCP initialize reply is qmd-shaped
# (serverInfo.name == "qmd") and fails loudly on a port collision.
#
# Bounded start: the daemon start is wrapped in timeout(1) when available so
# a hung qmd/bun start cannot stall every new session at SessionStart.
# Worst case ~44s common / ~59s pathological (QMD_START_TIMEOUT 20 + kill
# grace 5 + port-release wait 15, or 30 if every connect attempt itself
# stalls to its own 1s timeout(1) bound + post-start wait loop ~4), under
# Claude Code's default 60s hook timeout - do
# not raise the defaults past that budget. Note: a malformed QMD_MCP_URL
# override looks identical to daemon-dead (curl stderr is discarded by
# design).
#
# qmd resolution is inlined (bun + the bun-global qmd.js FIRST, then the bun
# bin shim, then PATH; .exe variant on Windows) - self-contained mirror of the
# essentials of himmel's scripts/lib/qmd-bin.sh, which this plugin copy cannot
# source because the plugin must work outside a himmel checkout.
# bash 3.2-safe, shellcheck clean, ASCII-only.
#
# Test seams (used only by scripts/qmd/test-ensure-qmd-daemon.sh in the
# himmel repo; default to production):
#   QMD_MCP_URL         probe URL AND raw-TCP-probe host:port (default
#                        http://localhost:8181/mcp)
#   QMD_CURL            curl binary         (default curl)
#   QMD_START_TIMEOUT   daemon-start bound  (default 20 seconds)
#   QMD_PS              ps binary           (default ps)
# Operator knobs (HIMMEL-3062):
#   QMD_RSS_CEILING_MB        recycle the daemon above this RSS (default 4096;
#                              0 disables)
#   QMD_RECYCLE_COOLDOWN_MIN  minimum minutes between recycles (default 30)
set -u

# localhost, NOT 127.0.0.1: the daemon binds qmd's own advertised address,
# which resolves to ::1 (IPv6-only) on Windows - an IPv4 probe gets
# connection-refused against a healthy daemon (round-3 CR, reproduced live).
# .mcp.json + the ps1 twin use the same URL; keep all three aligned.
QMD_MCP_URL="${QMD_MCP_URL:-http://localhost:8181/mcp}"
QMD_CURL="${QMD_CURL:-curl}"
QMD_START_TIMEOUT="${QMD_START_TIMEOUT:-20}"
QMD_PS="${QMD_PS:-ps}"
QMD_RSS_CEILING_MB="${QMD_RSS_CEILING_MB:-4096}"
QMD_RECYCLE_COOLDOWN_MIN="${QMD_RECYCLE_COOLDOWN_MIN:-30}"
case "$QMD_RECYCLE_COOLDOWN_MIN" in ''|*[!0-9]*) QMD_RECYCLE_COOLDOWN_MIN=30 ;; esac
# Force base 10: a leading zero (`08`) is octal to Bash arithmetic and aborts.
# A non-numeric ceiling disables it.
case "$QMD_RSS_CEILING_MB" in ''|*[!0-9]*) QMD_RSS_CEILING_MB=0 ;; esac
QMD_RSS_CEILING_MB=$((10#$QMD_RSS_CEILING_MB))
QMD_RECYCLE_COOLDOWN_MIN=$((10#$QMD_RECYCLE_COOLDOWN_MIN))
PROBE_TIMEOUT=2
WAIT_TRIES=5
PORT_WAIT_TRIES=15

INIT_PAYLOAD='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ensure-qmd-daemon","version":"1"}}}'

# Echo the raw probe response body (empty on connection failure).
probe_body() {
  "$QMD_CURL" -s -m "$PROBE_TIMEOUT" -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$INIT_PAYLOAD" \
    "$QMD_MCP_URL" 2>/dev/null
}

# True when the body carries a qmd-shaped MCP initialize reply: the match is
# scoped to the serverInfo object (serverInfo.name == "qmd"), so a foreign
# server whose reply merely CONTAINS a name:qmd pair elsewhere (tool list,
# echoed fragment) does not falsely validate.
is_qmd_shaped() {
  printf '%s' "$1" | grep -Eq '"serverInfo"[[:space:]]*:[[:space:]]*\{[^}]*"name"[[:space:]]*:[[:space:]]*"qmd"'
}

# Resolve how to invoke qmd. Sets QMD_BIN (argv0) and QMD_BIN_ARG1 (optional
# first arg). Preference order (HIMMEL-928):
#   1. bun + the bun-global @tobilu/qmd dist/cli/qmd.js -> `bun <qmd.js>`
#   2. bun global bin shim ($HOME/.bun/bin/qmd, .exe variant on Windows)
#   3. PATH
# bun-js FIRST is load-bearing, not just parity with qmd_cmd in himmel's
# scripts/lib/qmd-bin.sh: the bin shim honors the CLI's node shebang and runs
# qmd under NODE, and the --daemon child is spawned via process.execPath - so
# a shim-started daemon runs under whatever node is installed. Under bun qmd
# uses bun:sqlite; under node it needs the better-sqlite3 native binding,
# which bun's install blocks by default and which breaks again on every node
# ABI bump (reproduced live: absent binding + node 26 killed the daemon at
# startup - HIMMEL-928). `bun <qmd.js>` makes process.execPath = bun and the
# daemon child inherits it. Bun-before-PATH:
# a broken Windows qmd stub can shadow PATH (HIMMEL-163), so the known-good
# bun install wins when present. Provenance: minimal inline mirror of
# qmd-bin.sh - see header.
resolve_qmd() {
  # One bun root for BOTH the js and the shim fallbacks: a relocated
  # BUN_INSTALL must not resolve the js from one root and the shim from
  # $HOME/.bun (CodeRabbit, PR #1134).
  bun_root="${BUN_INSTALL:-$HOME/.bun}"
  bun_js="$bun_root/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
  if [ -f "$bun_js" ] && command -v bun >/dev/null 2>&1; then
    QMD_BIN="bun"
    QMD_BIN_ARG1="$bun_js"
    return 0
  fi
  QMD_BIN_ARG1=""
  if [ -x "$bun_root/bin/qmd" ]; then
    QMD_BIN="$bun_root/bin/qmd"
    return 0
  fi
  if [ -f "$bun_root/bin/qmd.exe" ]; then
    QMD_BIN="$bun_root/bin/qmd.exe"
    return 0
  fi
  if command -v qmd >/dev/null 2>&1; then
    QMD_BIN="qmd"
    return 0
  fi
  return 1
}

# ---- Memory ceiling + detached self-recycle (HIMMEL-3062) --------------------
# A long-lived daemon has been seen to grow to 6.8 GB RSS / 37% idle CPU over
# ~4.5h, at which point vec queries time out while lex keeps answering. Bound
# it: on the healthy path, read the RSS of the pid in qmd's own pidfile (ONE ps
# call, no network - this runs at every SessionStart, HIMMEL-1844) and, over
# QMD_RSS_CEILING_MB, hand the recycle to a DETACHED copy of this script
# (--recycle) so the SIGTERM + ~15s unwind + restart never spends the hook's
# budget. Fleets start many sessions at once, so a mkdir lock admits one
# recycler and a stamp holds off another for QMD_RECYCLE_COOLDOWN_MIN.
# ponytail: ceiling is POSIX-ps only (Git Bash's ps has no -o, so the check is a silent no-op there) and the ps1 twin is not ported, port in HIMMEL-3751.
qmd_state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/qmd"
pidfile="$qmd_state_dir/mcp.pid"
recycle_lock="$qmd_state_dir/recycle.lock"
recycle_stamp="$qmd_state_dir/recycle.stamp"
recycle_log="$qmd_state_dir/recycle.log"

# Echo "<rss_kb> <etime>" for a live qmd mcp pid, else fail.
qmd_rss() {
  local row rss etime
  row="$("$QMD_PS" -o rss= -o etime= -o args= -p "$1" 2>/dev/null)" || return 1
  case "$row" in *qmd*mcp*) ;; *) return 1 ;; esac
  read -r rss etime _ <<EOF
$row
EOF
  case "$rss" in ''|*[!0-9]*) return 1 ;; esac
  echo "$rss $etime"
}

check_ceiling() {
  local pid row rss_kb etime now last ceiling_kb
  [ "$QMD_RSS_CEILING_MB" -gt 0 ] || return 0
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  row="$(qmd_rss "$pid")" || return 0
  rss_kb="${row%% *}"
  etime="${row#* }"
  ceiling_kb=$((QMD_RSS_CEILING_MB * 1024))
  [ "$rss_kb" -gt "$ceiling_kb" ] || return 0
  now="$(date +%s)"
  last="$(cat "$recycle_stamp" 2>/dev/null)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt $((QMD_RECYCLE_COOLDOWN_MIN * 60)) ]; then
    echo "ensure-qmd-daemon: qmd daemon (PID $pid) RSS $((rss_kb / 1024)) MB > ceiling ${QMD_RSS_CEILING_MB} MB, but it was recycled under ${QMD_RECYCLE_COOLDOWN_MIN} min ago - cooldown, not recycling again" >&2  # t13b-ok: log text only, starts nothing
    return 0
  fi
  # A crashed recycler must not wedge the ceiling forever: a lock older than
  # its worst case (~90s: 30s kill wait + the ~59s start path) is cleared. The
  # stamp re-check after mkdir stops a session that read the stamp before the
  # winner wrote it.
  if ! mkdir "$recycle_lock" 2>/dev/null; then
    last="$(cat "$recycle_lock/at" 2>/dev/null)"
    case "$last" in
      # No 'at' yet: its holder may sit between mkdir and the write, so judge
      # staleness by the lock directory's own age instead.
      ''|*[!0-9]*) [ -n "$(find "$recycle_lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] || return 0 ;; # gnu-ok: BSD find has -maxdepth and -mmin too
      *) [ $((now - last)) -gt 120 ] || return 0 ;;
    esac
    # Clear it, never take it over here: two sessions that both judged it
    # stale could each remove the other's fresh lock and both recycle. The
    # next session start takes the lock through a plain mkdir.
    rm -rf "$recycle_lock"
    echo "ensure-qmd-daemon: cleared a stale recycle lock; the next session start recycles the daemon (RSS $((rss_kb / 1024)) MB > ceiling ${QMD_RSS_CEILING_MB} MB)" >&2  # t13b-ok: log text only, starts nothing
    return 0
  fi
  last="$(cat "$recycle_stamp" 2>/dev/null)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt $((QMD_RECYCLE_COOLDOWN_MIN * 60)) ]; then
    rm -rf "$recycle_lock"
    return 0
  fi
  echo "$now" > "$recycle_lock/at"
  echo "$now" > "$recycle_stamp"
  echo "ensure-qmd-daemon: qmd daemon (PID $pid, up $etime) RSS $((rss_kb / 1024)) MB > ceiling ${QMD_RSS_CEILING_MB} MB - recycling it in the background (log: $recycle_log)" >&2  # t13b-ok: log text; the recycler restarts the existing qmd server through the normal start path, bounded
  # Every fd redirected: a child holding the hook's stdout/stderr would make
  # Claude Code wait on it. setsid (when present) survives the session's exit.
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$0" --recycle "$pid" </dev/null >>"$recycle_log" 2>&1 &
  else
    bash "$0" --recycle "$pid" </dev/null >>"$recycle_log" 2>&1 &
  fi
}

# Detached recycler: stop the old daemon, wait for it to exit, then run the
# normal start path (probe dead -> port-release wait -> start -> verify).
if [ "${1:-}" = "--recycle" ]; then
  pid="${2:-}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') recycle: SIGTERM qmd daemon PID $pid"  # t13b-ok: log text only, starts nothing
  if qmd_rss "$pid" >/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    w=0
    while [ "$w" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
      w=$((w + 1))
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "recycle: PID $pid still alive after 30s - SIGKILL"
      kill -KILL "$pid" 2>/dev/null
    fi
  else
    echo "recycle: PID $pid is no longer a qmd mcp process - skipping the kill"
  fi
  bash "$0"
  rc=$?
  echo "$(date '+%Y-%m-%d %H:%M:%S') recycle: restart rc=$rc"
  rm -rf "$recycle_lock"
  exit "$rc"
fi

# ---- Healthy path: something already answers -------------------------------
body="$(probe_body)"
if [ -n "$body" ]; then
  if is_qmd_shaped "$body"; then
    check_ceiling
    exit 0
  fi
  echo "ensure-qmd-daemon: ERROR - a process is listening on $QMD_MCP_URL but it is NOT qmd" >&2
  echo "  (the MCP initialize reply has no qmd serverInfo). Port 8181 is taken by another service." >&2
  echo "  Free the port or stop that service, then start a fresh session." >&2
  exit 1
fi

# ---- Embed-model swap in progress: do NOT start (HIMMEL-4314) --------------
# scripts/luna/qmd-embed-model.sh swap holds this mkdir lock (holder pid inside)
# from its liveness check to its commit or rollback. A daemon started in that
# window serves the OLD model's query embeddings against the NEW vectors (a
# dimension mismatch, or silent garbage when the dimensions match). A lock whose
# pid is dead is stale: clear it and carry on; with no pid file it is stale once
# a minute old. Same path and rule as swap_lock_* in qmd-embed-model.sh, which
# this plugin copy cannot source.
# The start TAKES the lock (released on exit) rather than only checking it: a
# check-then-start leaves a window in which a swap could take the lock and pass
# its own liveness checks. Holding it makes the two mutually exclusive; a swap
# that starts meanwhile is refused, and its final re-check sees a started daemon.
swap_lock="$qmd_state_dir/embed-swap.lock"
mkdir -p "$qmd_state_dir" 2>/dev/null
if ! mkdir "$swap_lock" 2>/dev/null; then
  swap_pid="$(cat "$swap_lock/pid" 2>/dev/null)"
  case "$swap_pid" in
    ''|*[!0-9]*) [ -n "$(find "$swap_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && swap_stale=1 || swap_stale=0 ;;
    *) kill -0 "$swap_pid" 2>/dev/null && swap_stale=0 || swap_stale=1 ;;
  esac
  if [ "$swap_stale" -eq 1 ]; then
    rm -rf "$swap_lock"
  fi
  if ! mkdir "$swap_lock" 2>/dev/null; then
    echo "ensure-qmd-daemon: an embed-model swap is in progress (pid ${swap_pid:-unknown}, $swap_lock) - NOT starting the qmd daemon." >&2
    echo "  Starting it now would serve queries against a half-swapped index. Retry once the swap finishes;" >&2
    echo "  if that pid is gone, remove the lock directory." >&2
    exit 1
  fi
fi
echo "$$" > "$swap_lock/pid"
# shellcheck disable=SC2064 # expand now: the lock path is fixed for this run
trap "[ \"\$(cat '$swap_lock/pid' 2>/dev/null)\" = \"$$\" ] && rm -rf '$swap_lock'" EXIT

# ---- Dead: start the daemon ------------------------------------------------
if ! resolve_qmd; then
  echo "ensure-qmd-daemon: ERROR - qmd is not installed / not on PATH." >&2
  echo "  Install it: bash <himmel-repo>/scripts/lib/qmd-bin.sh install (HIMMEL-877)" >&2
  exit 1
fi

# A killed daemon can take ~15s to unwind (bun stops 46 threads) before it
# actually releases the port. If the MCP probe above found the endpoint dead
# but a previous daemon is still mid-unwind, racing straight to start here
# would launch a second daemon contending with the first for the same port
# (HIMMEL-3062). Poll a raw TCP connect - distinct from the qmd-shaped MCP
# probe above, this only asks "is anything listening", not "is it qmd" - and
# wait for the port to fully free before starting. PORT_WAIT_TRIES=15 matches
# the documented ~15s unwind time (common case: each connect attempt below
# resolves near-instantly against a still-held port, so the wait is
# PORT_WAIT_TRIES * 1s of sleeping); a port still held past that still falls
# through to the normal start attempt rather than hanging forever. Each
# connect attempt is itself bounded with timeout(1) when available
# (degrading to an unbounded connect otherwise) so a stalled connect - not
# just a held port - cannot blow the bound either; this only adds to the
# total in the pathological case where every single attempt actually stalls
# (see the worst-case budget in the file header). On a bash build without
# /dev/tcp support, the connect always "fails" and this loop is a silent
# no-op - same behavior as before this fix.
port_host="${QMD_MCP_URL#*://}"
port_host="${port_host%%/*}"
port_num="${port_host##*:}"
port_host="${port_host%%:*}"
port_held() {
  if command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # $1/$2 are the inner bash -c's OWN positional
    # params (bound below), not this shell's - must stay single-quoted.
    timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$port_host" "$port_num" 2>/dev/null
  else
    (exec 3<>"/dev/tcp/$port_host/$port_num") 2>/dev/null
  fi
}
p=0
while [ "$p" -lt "$PORT_WAIT_TRIES" ] && port_held; do
  p=$((p + 1))
  sleep 1
done

# qmd mcp --http --daemon is idempotent: already-running prints
# "Already running (PID N)" and exits 0. Bound the start with timeout(1)
# so a hung qmd/bun start cannot stall SessionStart; when timeout(1) is
# absent (rare platform), degrade to an unbounded start.
# ${QMD_BIN_ARG1:+"$QMD_BIN_ARG1"} expands to the quoted qmd.js path on the
# bun-js resolution and to NOTHING (no empty argv slot) otherwise.
start_rc=0
if command -v timeout >/dev/null 2>&1; then
  start_out="$(timeout -k 5 "$QMD_START_TIMEOUT" "$QMD_BIN" ${QMD_BIN_ARG1:+"$QMD_BIN_ARG1"} mcp --http --daemon 2>&1)" || start_rc=$?
else
  start_out="$("$QMD_BIN" ${QMD_BIN_ARG1:+"$QMD_BIN_ARG1"} mcp --http --daemon 2>&1)" || start_rc=$?
fi
if [ "$start_rc" -eq 124 ] || [ "$start_rc" -eq 137 ]; then
  echo "ensure-qmd-daemon: ERROR - 'qmd mcp --http --daemon' timed out after ${QMD_START_TIMEOUT}s (killed)." >&2
  echo "  A hung start would stall every new session, so it was bounded and aborted." >&2
  echo "  Check the daemon log: ~/.cache/qmd/mcp.log" >&2
  exit 1
fi

i=0
while [ "$i" -lt "$WAIT_TRIES" ]; do
  body="$(probe_body)"
  if [ -n "$body" ] && is_qmd_shaped "$body"; then
    exit 0
  fi
  i=$((i + 1))
  if [ "$i" -lt "$WAIT_TRIES" ]; then
    sleep 1
  fi
done

echo "ensure-qmd-daemon: ERROR - started 'qmd mcp --http --daemon' but nothing came alive on $QMD_MCP_URL." >&2
echo "  qmd output was:" >&2
printf '%s\n' "$start_out" | sed 's/^/    /' >&2
if [ -z "${QMD_BIN_ARG1:-}" ]; then
  # Non-bun-js resolution: the daemon was started via '$QMD_BIN' - a
  # node-shebang shim/PATH path, the exact fragile leg HIMMEL-928 fixed.
  # Most likely cause: the node-side better-sqlite3 binding is missing.
  echo "  (daemon was started via '$QMD_BIN', not 'bun <qmd.js>' - if node's" >&2
  echo "  better-sqlite3 binding is missing, fix with:" >&2
  echo "  bash <himmel-repo>/scripts/lib/qmd-bin.sh install)" >&2
fi
echo "  Check the daemon log: ~/.cache/qmd/mcp.log" >&2
exit 1
