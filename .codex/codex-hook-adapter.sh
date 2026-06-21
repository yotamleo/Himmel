#!/usr/bin/env bash
# Codex hook adapter (HIMMEL-427). Bridges himmel's exit-code block convention to
# Codex's JSON decision convention.
#
# himmel guardrails signal a BLOCK by exiting 2 (Claude Code's convention: exit 2
# = deny, stderr shown to the model). Codex's hook engine does NOT act on exit 2
# — it blocks a tool call ONLY when a hook prints a JSON
#   {"hookSpecificOutput":{"hookEventName":"<ev>","permissionDecision":"deny",...}}
# on stdout. A guardrail (or this adapter) that merely exits 2/non-zero is
# reported by Codex as a failed (non-blocking) hook and the tool call PROCEEDS.
# (Verified against codex-cli 0.141.0: `exit 2` -> "PreToolUse Failed", command
# runs; deny-JSON -> "PreToolUse Blocked".)
#
# CONSEQUENCE: every path that must block has to speak the deny JSON, not an exit
# code. So the adapter translates a guardrail's exit-2 block into the JSON deny,
# AND fails CLOSED (same JSON deny) on its OWN precondition errors (missing script
# name, unset CLAUDE_PROJECT_DIR, missing guardrail file) — a bare `exit 2` there
# would fail OPEN under Codex. Every other guardrail outcome passes through
# unchanged, so the guardrails stay single-sourced and keep working verbatim under
# Claude Code (which never invokes this adapter — only .codex/hooks.json does).
set -u

# emit_deny <reason> [event] — print Codex's JSON deny on stdout and exit 0 (fail
# closed). `event` is whitelisted to the block-capable events; anything else (or
# absent) defaults to PreToolUse, the event all himmel blockers use.
emit_deny() {
  local r="$1" ev="${2:-PreToolUse}"
  case "$ev" in PreToolUse|PermissionRequest) ;; *) ev="PreToolUse" ;; esac
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ev "$ev" --arg r "$r" \
      '{hookSpecificOutput:{hookEventName:$ev,permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    # jq is a hard dependency of the guardrails; this path is only reached if jq
    # vanished mid-run. Emit a minimal static deny (no untrusted interpolation).
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"blocked fail-closed (jq unavailable to format reason)"}}\n'
  fi
  exit 0
}

name="${1:-}"
[ -n "$name" ] || emit_deny "codex-hook-adapter: missing script name — fail closed"
# run-hook.cmd's cmd.exe branch exports CLAUDE_PROJECT_DIR with backslashes;
# normalise a copy to forward slashes so the guardrail path resolves under Git
# Bash. The bash branch already exports a forward-slash path (no-op here).
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || emit_deny "codex-hook-adapter: CLAUDE_PROJECT_DIR unset — fail closed"
proj="${CLAUDE_PROJECT_DIR//\\//}"
script="$proj/scripts/hooks/$name"
# A missing guardrail (typo in hooks.json, or referenced before it's ported) must
# fail CLOSED, not silently let the tool through.
[ -f "$script" ] || emit_deny "codex-hook-adapter: guardrail '$name' not found at $script — fail closed"

input="$(cat)"

# Run the guardrail with the hook JSON on stdin. Capture its STDERR into a var
# while its STDOUT (e.g. an auto-approve decision) passes straight through to the
# real stdout (fd 3). No temp files: Codex runs hooks inside the tool sandbox
# where $TMPDIR/`/tmp` may be unwritable. The trailing EXIT: marker carries the
# guardrail's real exit code (PIPESTATUS[1]) out of the command substitution; it
# is a separate command in the { …; …; } group so it ALWAYS runs (code is never
# empty), and being appended last it survives a guardrail stderr that itself
# contains "EXIT:" (the greedy ## / shortest % both resolve to the final marker).
exec 3>&1
captured="$( { printf '%s' "$input" | bash "$script" 2>&1 1>&3; printf 'EXIT:%s' "${PIPESTATUS[1]}"; } )"
exec 3>&-
code="${captured##*EXIT:}"
reason="${captured%EXIT:*}"
reason="${reason%$'\n'}"; reason="${reason%$'\r'}"   # drop the guardrail's trailing CR/LF

if [ "$code" = "2" ]; then
  # Block: translate to Codex's JSON deny. hookEventName mirrors the inbound event.
  ev="$(printf '%s' "$input" | jq -r '.hook_event_name // "PreToolUse"' 2>/dev/null || echo PreToolUse)"
  emit_deny "$reason" "$ev"
fi

# Non-block: surface the guardrail's stderr (advisory) and propagate its code.
[ -n "$reason" ] && printf '%s' "$reason" >&2
exit "${code:-0}"
