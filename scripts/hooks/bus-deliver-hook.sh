#!/usr/bin/env bash
# bus-deliver-hook.sh — PostToolUse + SessionStart hook (HIMMEL-4828, himmel-bus T5).
#
# WHY: the himmel-bus MCP server can send and read, but nothing puts a waiting
# message in front of a session. This hook delivers this session's bus log
# (verified, batched, summary-first) as additionalContext (PostToolUse) or plain
# stdout (SessionStart). The logic lives in marketplace/plugins/himmel-bus/lib/
# deliver.mjs; this file is the cheap gate in front of it.
#
# DARK BY DEFAULT: nothing happens unless HIMMEL_BUS_NAME names a bus peer. The
# name only opts in — the worker still resolves identity from the process
# ancestry and delivers nothing unless it matches that name.
#
# FAST PATH (every tool call, every session): no node unless the log has
# something new. Log size vs the cursor's `off`, plus no closed segments and no
# halt mark. Anything unusual falls through to the worker, which is the judge.
#
# Fail OPEN, always exit 0: delivery must never block a tool call. Linux-only
# (the identity walk reads /proc); no .ps1 twin by design.
set -uo pipefail

name="${HIMMEL_BUS_NAME:-}"
[ -n "$name" ] || exit 0
case "$name" in *[!A-Za-z0-9._-]* | [!A-Za-z0-9]*) exit 0 ;; esac
[ "${#name}" -le 64 ] || exit 0

root="${XDG_STATE_HOME:-${HOME:-}/.local/state}/himmel/bus"
log="$root/log/$name.jsonl"
cur="$root/cur/$name"
[ -f "$log" ] || exit 0  # fail-open-ok: a delivery nudge, not a fence; an unreadable log means no mail is shown, never a permission granted
size="$(wc -c < "$log" 2>/dev/null | tr -d ' ')"
[ "${size:-0}" -gt 0 ] || exit 0

if [ -f "$cur" ]; then
  cur_json="$(cat "$cur" 2>/dev/null)"
  case "$cur_json" in *'"halted"'*) exit 0 ;; esac
  off="$(printf '%s' "$cur_json" | sed -n 's/.*"off":\([0-9][0-9]*\).*/\1/p')"
  k="$(printf '%s' "$cur_json" | sed -n 's/.*"k":\([0-9][0-9]*\).*/\1/p')"
  if [ "${off:-x}" = "$size" ] && [ "${k:-x}" = "0" ] && ! ls "$root/log/$name".[0-9]* >/dev/null 2>&1; then
    exit 0
  fi
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=../lib/resolve-node.sh
. "$HERE/../lib/resolve-node.sh" 2>/dev/null || exit 0
node="$(resolve_node)" || exit 0
"$node" "$HERE/bus-deliver-run.js" 2>/dev/null
exit 0
