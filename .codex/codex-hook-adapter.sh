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

# emit_context <reason> <event> — print Codex's non-blocking additionalContext
# JSON on stdout and exit 0 (HIMMEL-565). Used for guardrail exit 2 on lifecycle
# events that have NO permission gate (PostToolUse, SessionStart, UserPromptSubmit).
# Their `*.command.output` schema (openai/codex generated schemas) carries
# `hookSpecificOutput.additionalContext` — appended to the model's context — not a
# permissionDecision. (The fixture proves the adapter emits this shape; a live
# Codex runtime probe of the auto-arm path is still pending — see harness-compat.md.)
# A PostToolUse auto-arm (auto-arm-on-subagent-cap.sh) exits 2 AFTER its side
# effects ran, so the message belongs in additionalContext — emitting a PreToolUse
# deny here is the wrong lifecycle event AND a bogus permission gate for a tool
# that already ran.
emit_context() {
  local r="$1" ev="$2"
  # Normalise to a known additionalContext-carrying event; default to PostToolUse
  # (the only non-permission event himmel wires a blocking/exit-2 guardrail on —
  # the SessionStart/UserPromptSubmit hooks in .codex/hooks.json are advisory). An
  # unrecognised inbound event would otherwise yield an invalid `hookEventName`
  # const that Codex's strict parser rejects, dropping the message.
  case "$ev" in PostToolUse|SessionStart|UserPromptSubmit) ;; *) ev="PostToolUse" ;; esac
  # No jq-less fallback: reaching here means the exit-2 dispatcher already parsed
  # the inbound event with jq, so jq is present (a jq-less run resolves ev to
  # PreToolUse → emit_deny, never here). emit_deny keeps its fallback because its
  # precondition callers run before any jq use.
  jq -cn --arg ev "$ev" --arg r "$r" \
    '{hookSpecificOutput:{hookEventName:$ev,additionalContext:$r}}'
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

# Inbound lifecycle event, parsed once. SessionStart / UserPromptSubmit are
# advisory CONTEXT events with no permission gate. Under Codex a hook feeds the
# model via `hookSpecificOutput.additionalContext`, NOT raw stdout — that JSON
# channel is exactly why HIMMEL-565 added emit_context. So for these two events
# the guardrail's output (stdout for an exit-0 advisory hook like
# inject-initiative / inject-where-are-we / inject-doc-freshness; stderr for a
# defensive exit-2) is captured and re-emitted through emit_context; empty output
# → nothing injected, exit 0. This is what makes himmel's advisory SessionStart /
# UserPromptSubmit hooks actually FIRE under Codex (HIMMEL-596) instead of being
# wired-but-inert. PreToolUse / PermissionRequest / PostToolUse keep the
# stdout-passthrough contract below (auto-approve emits its JSON decision on
# stdout — it MUST pass through verbatim, so it must NOT be wrapped).
ev="$(printf '%s' "$input" | jq -r '.hook_event_name // "PreToolUse"' 2>/dev/null || echo PreToolUse)"
case "$ev" in
  SessionStart|UserPromptSubmit)
    # Combine stdout+stderr (an advisory context message has no separate channels
    # to preserve) and run the guardrail exactly once. $(...) strips trailing
    # newlines; also drop a stray CR (Windows). emit_context exits 0; an empty
    # body is an advisory no-op (exit 0) — these hooks never block session start.
    cbody="$( printf '%s' "$input" | bash "$script" 2>&1 )"
    cbody="${cbody%$'\r'}"
    [ -n "$cbody" ] && emit_context "$cbody" "$ev"
    exit 0
    ;;
esac

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
  # ev parsed above; SessionStart/UserPromptSubmit already returned, so this only
  # sees PreToolUse/PermissionRequest (→ deny) and PostToolUse/unknown (→ context).
  case "$ev" in
    PreToolUse|PermissionRequest)
      # Block: translate to Codex's JSON deny. hookEventName mirrors the inbound event.
      emit_deny "$reason" "$ev"
      ;;
    *)
      # Non-permission lifecycle event (PostToolUse, SessionStart, UserPromptSubmit):
      # surface the guardrail's message as additionalContext, never a permission deny.
      emit_context "$reason" "$ev"
      ;;
  esac
fi

# Non-block: surface the guardrail's stderr (advisory) and propagate its code.
[ -n "$reason" ] && printf '%s' "$reason" >&2
exit "${code:-0}"
