#!/usr/bin/env bash
# mcp-gate.sh — opt-in launch gate for an OPTIONAL plugin MCP server (HIMMEL-591).
#
# Claude Code has no native lazy / on-first-use stdio MCP spawn (it eagerly
# starts every enabled plugin's server at session start; GitHub #18497 closed
# not-planned), and plugin-provided servers have no per-server settings toggle.
# So a session that never calls telegram / luna-correlate still held their bun
# servers — the per-session multiplication this ticket kills (~18 bun + 24 node,
# ~900MB across a few idle sessions on win11).
#
# This wrapper sits in FRONT of run-bun.sh in .mcp.json. It is DEFAULT-OFF: unless
# the session opted in via one of the named gate env vars, it exits 0 WITHOUT
# spawning bun, so an uninterested session holds no process for this server.
# When opted in, it exec's the real launcher unchanged (args pass straight through,
# so stdio/behaviour is byte-for-byte the eager path).
#
# Wired from .mcp.json as:
#   command "bash",
#   args ["${CLAUDE_PLUGIN_ROOT}/mcp-gate.sh", "<VAR1 VAR2 ...>", "bash",
#         "${CLAUDE_PLUGIN_ROOT}/run-bun.sh", "run", ...]
# Arg 1 = a space-separated list of gate env var NAMES; ANY set to a non-empty,
# non-"0" value opts in. The rest is the command to exec when opted in.
#
# telegram-himmel gates on HIMMEL_MCP_TELEGRAM OR TELEGRAM_OWN_POLLER (either
# alone opts in), so the existing `TELEGRAM_OWN_POLLER=1 claude …` owner launch
# keeps its server with no doc change; a send-only session opts in with
# HIMMEL_MCP_TELEGRAM=1.
#
# Shipped PER-PLUGIN (kept byte-identical, like run-bun.sh) because a .mcp.json in
# the plugin cache can only anchor on ${CLAUDE_PLUGIN_ROOT}. bash 3.2-safe.
#
# A gated-off server shows as not-connected in /mcp — expected: the session
# opted out. Opt in (or launch a dedicated session) to get its tools back.
set -u

gate_vars="${1:-}"; shift || true

opted=0
# shellcheck disable=SC2086  # deliberate word-split: gate_vars is a space list of NAMES
for _v in $gate_vars; do
    _val="${!_v:-}"   # bash indirect expansion (3.2-safe); no eval on the name
    if [ -n "$_val" ] && [ "$_val" != "0" ]; then opted=1; break; fi
done

if [ "$opted" != 1 ]; then
    # Not opted in: do NOT spawn bun. Exit clean so no process is held.
    exit 0
fi

exec "$@"
