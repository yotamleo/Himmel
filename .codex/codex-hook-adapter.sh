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
# would fail OPEN under Codex. Exception: a hook the wrapper marked --lifecycle
# (SessionStart/Stop) has no permission gate to fail closed ON, so those
# preconditions report honestly instead — see fail_precondition (HIMMEL-1981).
# Every other guardrail outcome passes through
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

# fail_precondition <reason> — the adapter's OWN startup errors, raised BEFORE
# stdin is read, so the inbound event is still unknown (HIMMEL-1981). For a hook
# wired to a permission-gate event that must be a fail-CLOSED deny; for one wired
# to a NO-permission-gate event (SessionStart/Stop) a deny envelope is both
# meaningless and rejected by that event's output schema, so report the failure
# honestly instead (stderr + rc 1 -> Codex's "hook failed" banner). The platform
# wrapper exports HIMMEL_CODEX_HOOK_LIFECYCLE=1 for the latter; deliberately NOT
# consulted
# by emit_deny itself, so a real guardrail BLOCK on a permission-gate event can
# never be downgraded to a non-decision by a stray env var.
fail_precondition() {
  if [ "${HIMMEL_CODEX_HOOK_LIFECYCLE:-}" = "1" ]; then
    printf '%s; advisory hook did not run\n' "$1" >&2
    exit 1
  fi
  emit_deny "$1"
}

name="${1:-}"
[ -n "$name" ] || fail_precondition "codex-hook-adapter: missing script name — fail closed"
# run-hook.cmd exports CLAUDE_PROJECT_DIR with backslashes;
# normalise a copy to forward slashes so the guardrail path resolves under Git
# Bash. The bash branch already exports a forward-slash path (no-op here).
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || fail_precondition "codex-hook-adapter: CLAUDE_PROJECT_DIR unset — fail closed"
proj="${CLAUDE_PROJECT_DIR//\\//}"

# HIMMEL-1989: <name> may be a PLUS-separated CHAIN — `a.sh+b.sh+c.sh`. Codex
# launches one cmd.exe -> Git Bash -> adapter stack PER hook entry, so nine
# PreToolUse entries on a Bash tool call cost nine of them; a chain runs the same
# guardrails, in the same order, inside ONE adapter. Order is the order Codex
# would have fired them in (block order in hooks.json, then within-block order) —
# `.codex/hooks.json` is the single source of that order and
# scripts/codex/test-codex-hook-parity.sh maps every element back to its Claude
# wiring. A single name is just a chain of one, so nothing below is special-cased.
#
# The separator is `+`, NOT a comma: cmd.exe treats `,` (like space, tab, `;` and
# `=`) as an ARGUMENT DELIMITER, so `run-hook.cmd --sandbox a.sh,b.sh,c.sh`
# arrives as %2=a.sh %3=b.sh and the chain would silently truncate to its first
# guardrail — every later guard quietly not running. Measured on cmd.exe
# 10.0.26200; `+` passes through intact. The parity gate rejects a comma in a
# run-hook.cmd command precisely because the truncation happens BEFORE the
# adapter can see it.
#
# Validate the WHOLE string before splitting: bash's treatment of empty fields
# under a non-whitespace IFS is exactly the kind of edge a security path should
# not lean on, and a stray CR or shell metacharacter from a hand-edited
# hooks.json must fail CLOSED rather than resolve to something surprising.
case "$name" in
  +*|*+|*++*|*[!A-Za-z0-9._+-]*)
    fail_precondition "codex-hook-adapter: malformed guardrail chain '$name' — fail closed" ;;
esac
# Every element is resolved and existence-checked BEFORE any of them runs: a
# chain with one bad member must deny outright, never run a prefix of itself.
scripts=()
oldifs="$IFS"; IFS='+'
for n in $name; do
  IFS="$oldifs"
  # A missing guardrail (typo in hooks.json, or referenced before it's ported)
  # must fail CLOSED, not silently let the tool through.
  [ -f "$proj/scripts/hooks/$n" ] || fail_precondition "codex-hook-adapter: guardrail '$n' not found at $proj/scripts/hooks/$n — fail closed"
  scripts+=("$proj/scripts/hooks/$n")
  IFS='+'
done
IFS="$oldifs"
# Unreachable by construction — an empty $name is rejected above and a name of
# only separators cannot survive the case validator — but a chain that resolved
# to ZERO members would run no guardrail and exit 0, i.e. fail OPEN. Assert it
# locally rather than resting on a proof about bash word splitting.
[ "${#scripts[@]}" -gt 0 ] || fail_precondition "codex-hook-adapter: guardrail chain '$name' resolved to no members — fail closed"

input="$(cat)"
nl='
'

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
    # to preserve) and run each chain member exactly once, in order. $(...) strips
    # trailing newlines; also drop a stray CR (Windows). emit_context exits 0; an
    # empty body is an advisory no-op (exit 0) — these hooks never block session
    # start. SessionStart is a real multi-member chain since HIMMEL-2003 (Stop is
    # still one entry per hook); the join below is what makes the members' bodies
    # arrive as one context block. There is no per-member clamp here, so the
    # entry's own `timeout` in hooks.json is the ONLY bound — a multi-member
    # chain carries 60s, like every other `+` chain there.
    cbody=""
    for script in "${scripts[@]}"; do
      one="$( printf '%s' "$input" | bash "$script" 2>&1 )"
      one="${one%$'\r'}"
      [ -n "$one" ] && cbody="${cbody:+$cbody$nl}$one"
    done
    [ -n "$cbody" ] && emit_context "$cbody" "$ev"
    exit 0
    ;;
  Stop|SessionEnd)
    # SessionEnd-class hooks (HIMMEL-599): refresh-where-are-we-on-end,
    # jira-nudge-on-end, end-session-wiki. Unlike SessionStart/UserPromptSubmit,
    # Codex's stop.command.output schema has NO additionalContext / hookSpecificOutput
    # — only a continue/decision/systemMessage gate. himmel's SessionEnd hooks are
    # ADVISORY + side-effecting (refresh the ledger / write the session note / nudge
    # via Telegram) and must NEVER block teardown. So run the hook for its side
    # effects and route any stdout+stderr to OUR stderr as advisory — NOT to Codex's
    # Stop *decision* parser (raw advisory text there is mis-parsed), and NOT through
    # the generic exit-2 path (which would emit a hookSpecificOutput shape Stop's
    # strict deny_unknown_fields schema rejects). Always exit 0. Under Codex,
    # Codex's real SessionEnd event shares this branch (HIMMEL-2021): its output
    # schema is input-only, so the same never-emit-a-decision rule is what makes
    # it safe, and its 1-3s cap is why only an enqueue-and-exit hook is wired
    # there.
    # jira-nudge's operator surface is its Telegram relay, not this stdout. $(...)
    # strips trailing newlines; drop a stray CR (Windows). Empty body = no-op.
    cbody=""
    for script in "${scripts[@]}"; do
      one="$( printf '%s' "$input" | bash "$script" 2>&1 )"
      one="${one%$'\r'}"
      [ -n "$one" ] && cbody="${cbody:+$cbody$nl}$one"
    done
    [ -n "$cbody" ] && printf '%s\n' "$cbody" >&2
    exit 0
    ;;
esac

# Run the guardrail with the hook JSON on stdin, capturing stdout AND stderr
# together (no fd-3 passthrough). Codex's PreToolUse output schema honours ONLY a
# deny decision: it REJECTS a Claude-style permissionDecision:"allow" or an
# `updatedInput` — codex-cli 0.149 surfaces "unsupported permissionDecision:allow"
# / "updatedInput without permissionDecision:allow" and marks the hook failed
# (HIMMEL-1987). himmel guardrails that emit that allow envelope on stdout
# (auto-approve-safe-bash; the Claude-only rtk-hook-guard) are a no-op under
# Codex's own approval model anyway, so the adapter must NEVER forward guardrail
# stdout verbatim — it captures everything and re-emits only what Codex honours:
# a BLOCK (exit 2, OR a permissionDecision:"deny" on stdout) -> Codex deny JSON;
# anything else (allow, updatedInput, advisory, empty) -> swallowed, proceed.
# No temp files: the Codex tool sandbox may have an unwritable /tmp. The trailing
# EXIT: marker carries the guardrail's real exit code (PIPESTATUS[1]) out of the
# command substitution; appended last, it survives guardrail output containing
# "EXIT:" (## / % both resolve to the final marker).
#
# HIMMEL-1989: the chain runs in declared order and the FIRST deny wins and
# SHORT-CIRCUITS — emit_deny/emit_context exit, so later members do not run.
# Codex's own semantics ran every matched hook and then honoured the deny; that
# difference is safe here because every himmel PreToolUse guardrail is a pure
# check. The one side-effecting PreToolUse hook, auto-arm-on-cap, deliberately
# stays in its own `.*` entry so it fires regardless of an earlier deny.
advisory=""
for script in "${scripts[@]}"; do
  captured="$( { printf '%s' "$input" | bash "$script" 2>&1; printf 'EXIT:%s' "${PIPESTATUS[1]}"; } )"
  code="${captured##*EXIT:}"
  out="${captured%EXIT:*}"
  out="${out%$'\n'}"; out="${out%$'\r'}"   # drop the guardrail's trailing CR/LF

  # A guardrail BLOCKS via exit 2 (himmel convention) OR a permissionDecision:"deny"
  # on stdout; either must reach Codex as a deny. Every other outcome proceeds.
  is_deny=0
  [ "$code" = "2" ] && is_deny=1
  # himmel guardrails deny via exit 2 (stderr reason) — this stdout-deny match is
  # defensive, for a guardrail that instead emits a JSON deny envelope directly.
  # Whitespace-tolerant (space/tab/newline around the colon): an exact-spacing
  # glob missed a pretty-printed envelope and would fail OPEN.
  if printf '%s' "$out" | grep -Eq '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    is_deny=1
  fi

  if [ "$is_deny" = "1" ]; then
    # ev parsed above; SessionStart/UserPromptSubmit/Stop already returned, so this
    # only sees PreToolUse/PermissionRequest (→ deny) and PostToolUse/unknown (→ context).
    # $out is the guardrail's reason: on exit 2 himmel guardrails print a plain
    # human message to stderr (now in $out); no himmel guardrail denies via a
    # stdout JSON envelope, so passing $out as the reason is a plain string here.
    case "$ev" in
      PreToolUse|PermissionRequest)
        # Block: translate to Codex's JSON deny. hookEventName mirrors the inbound event.
        emit_deny "$out" "$ev"
        ;;
      *)
        # Non-permission lifecycle event (PostToolUse, SessionStart, UserPromptSubmit):
        # surface the guardrail's message as additionalContext, never a permission deny.
        emit_context "$out" "$ev"
        ;;
    esac
  fi

  # Non-block: this member proceeds. Its stdout is deliberately NOT forwarded to
  # Codex — a permissionDecision:"allow" / updatedInput would be rejected
  # (HIMMEL-1987) — so it is held for OUR stderr once the whole chain is through.
  [ -n "$out" ] && advisory="${advisory:+$advisory$nl}$out"
done

# Whole chain proceeded CLEANLY. Codex has no concept of "ran fine but exited
# nonzero": a hook that isn't a deny and still exits nonzero is rendered as a
# "PreToolUse hook (failed)" banner — spurious noise for a guardrail that ran fine
# and simply exited nonzero (e.g. an informational 1/7). Under Codex a hook BLOCKS
# only via exit 2 / a deny JSON; every other outcome must proceed cleanly, so
# always exit 0 here (never propagate a guardrail's own code).
[ -n "$advisory" ] && printf '%s' "$advisory" >&2
exit 0
