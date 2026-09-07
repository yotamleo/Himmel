#!/usr/bin/env bash
# himmel Codex hook wrapper (HIMMEL-427/HIMMEL-2019). Unix-only; Codex selects
# this file through command. Windows uses run-hook.cmd through commandWindows.
#
# Resolve + run the adapter, which runs the guardrail and translates an exit-2
# block into the JSON deny Codex understands.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_PROJECT_DIR="$(cd "$HOOK_DIR/.." && pwd)"
export CLAUDE_PROJECT_DIR
# Guardrails read the hook JSON from stdin (inherited); no positional args
# forwarded. A missing script name is handled by the adapter (fail-closed JSON
# deny), so it is passed straight through rather than gated with a bare exit 2.
# --lifecycle is not merely stripped: it is EXPORTED, because the adapter has its
# own fail-closed preconditions (missing guardrail file, unset project dir) and
# must honour the same no-permission-gate contract the cmd branch does.
# Cleared first for the same reason the cmd branch clears it: this wrapper is the
# only authority, and an inherited value must never promote a gate hook.
HIMMEL_CODEX_HOOK_LIFECYCLE=""
export HIMMEL_CODEX_HOOK_LIFECYCLE
while :; do
  case "${1:-}" in
    --lifecycle) HIMMEL_CODEX_HOOK_LIFECYCLE=1; shift ;;
    --sandbox|--no-sandbox) shift ;;
    *) break ;;
  esac
done
exec bash "$CLAUDE_PROJECT_DIR/.codex/codex-hook-adapter.sh" "${1:-}"
