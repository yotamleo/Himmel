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
# Worst case ~29s (QMD_START_TIMEOUT 20 + kill grace 5 + wait loop ~4), under
# Claude Code's default 60s hook timeout - do not raise the defaults past
# that budget. Note: a malformed QMD_MCP_URL override looks identical to
# daemon-dead (curl stderr is discarded by design).
#
# qmd resolution is inlined (bun global bin FIRST, then PATH; .exe variant
# on Windows) - self-contained mirror of the essentials of
# himmel's scripts/lib/qmd-bin.sh, which this plugin copy cannot source
# because the plugin must work outside a himmel checkout.
# bash 3.2-safe, shellcheck clean, ASCII-only.
#
# Test seams (used only by scripts/qmd/test-ensure-qmd-daemon.sh in the
# himmel repo; default to production):
#   QMD_MCP_URL         probe URL           (default http://localhost:8181/mcp)
#   QMD_CURL            curl binary         (default curl)
#   QMD_START_TIMEOUT   daemon-start bound  (default 20 seconds)
set -u

# localhost, NOT 127.0.0.1: the daemon binds qmd's own advertised address,
# which resolves to ::1 (IPv6-only) on Windows - an IPv4 probe gets
# connection-refused against a healthy daemon (round-3 CR, reproduced live).
# .mcp.json + the ps1 twin use the same URL; keep all three aligned.
QMD_MCP_URL="${QMD_MCP_URL:-http://localhost:8181/mcp}"
QMD_CURL="${QMD_CURL:-curl}"
QMD_START_TIMEOUT="${QMD_START_TIMEOUT:-20}"
PROBE_TIMEOUT=2
WAIT_TRIES=5

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

# Resolve the qmd binary: bun global bin FIRST ($HOME/.bun/bin/qmd, .exe
# variant on Windows), then PATH. Bun-first matches scripts/lib/qmd-bin.sh
# (himmel repo): a broken Windows qmd stub can shadow PATH (HIMMEL-163), so
# the known-good bun install wins when present. Provenance: minimal inline
# mirror of qmd-bin.sh - see header.
resolve_qmd() {
  if [ -x "$HOME/.bun/bin/qmd" ]; then
    echo "$HOME/.bun/bin/qmd"
    return 0
  fi
  if [ -f "$HOME/.bun/bin/qmd.exe" ]; then
    echo "$HOME/.bun/bin/qmd.exe"
    return 0
  fi
  if command -v qmd >/dev/null 2>&1; then
    echo "qmd"
    return 0
  fi
  return 1
}

# ---- Healthy path: something already answers -------------------------------
body="$(probe_body)"
if [ -n "$body" ]; then
  if is_qmd_shaped "$body"; then
    exit 0
  fi
  echo "ensure-qmd-daemon: ERROR - a process is listening on $QMD_MCP_URL but it is NOT qmd" >&2
  echo "  (the MCP initialize reply has no qmd serverInfo). Port 8181 is taken by another service." >&2
  echo "  Free the port or stop that service, then start a fresh session." >&2
  exit 1
fi

# ---- Dead: start the daemon ------------------------------------------------
if ! QMD_BIN="$(resolve_qmd)"; then
  echo "ensure-qmd-daemon: ERROR - qmd is not installed / not on PATH." >&2
  echo "  Install it: bash <himmel-repo>/scripts/lib/qmd-bin.sh install (HIMMEL-877)" >&2
  exit 1
fi

# qmd mcp --http --daemon is idempotent: already-running prints
# "Already running (PID N)" and exits 0. Bound the start with timeout(1)
# so a hung qmd/bun start cannot stall SessionStart; when timeout(1) is
# absent (rare platform), degrade to an unbounded start.
start_rc=0
if command -v timeout >/dev/null 2>&1; then
  start_out="$(timeout -k 5 "$QMD_START_TIMEOUT" "$QMD_BIN" mcp --http --daemon 2>&1)" || start_rc=$?
else
  start_out="$("$QMD_BIN" mcp --http --daemon 2>&1)" || start_rc=$?
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
echo "  Check the daemon log: ~/.cache/qmd/mcp.log" >&2
exit 1
