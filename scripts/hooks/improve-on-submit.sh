#!/usr/bin/env bash
# improve-on-submit.sh — UserPromptSubmit hook for /improve (HIMMEL-127).
#
# Gated by the IMPROVE_ON_SUBMIT env var (must be set in the shell that
# LAUNCHED Claude — bypass convention per CLAUDE.md "Bypass convention"
# section). When active, every prompt the operator submits gets context
# injected suggesting Claude run /improve on it first to refine it before
# responding.
#
# Default: OFF. Exit silently when the env is unset.
#
# Hook contract (UserPromptSubmit):
#   - Reads UserPromptSubmit JSON payload from stdin (we don't currently
#     consume any fields; the prompt body is already visible to Claude).
#   - Exit 0 with optional stdout → stdout is injected as additional
#     context for Claude on this turn.
#   - Non-zero exit → blocks the prompt (we never block; only ever 0).
#
# Wiring (in .codex/hooks.json):
#   {
#     "hooks": {
#       "UserPromptSubmit": [
#         { "hooks": [ { "type": "command",
#                        "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/improve-on-submit.sh"
#                      } ] }
#       ]
#     }
#   }
#
# v1 = env-gated (this file). v2 (future child) = length/keyword-gated
# auto-fire so the env var isn't needed for long/exploratory prompts.

set -euo pipefail

# Always exit clean; never block a prompt.
trap 'exit 0' ERR

# Drain stdin so the hook contract doesn't break the runtime if it pipes a
# payload. We don't currently need the JSON body.
if [ -t 0 ]; then
    :
else
    cat >/dev/null 2>&1 || true
fi

# Off-switch check.
case "${IMPROVE_ON_SUBMIT:-}" in
    1|true|TRUE|on|ON|yes|YES)
        ;;
    *)
        exit 0
        ;;
esac

# Inject context that asks Claude to run /improve before responding.
# The text is written so it triggers the slash command pattern documented
# in .claude/commands/improve.md without conflicting with other workflows.
cat <<'EOF'
<system-reminder>
IMPROVE_ON_SUBMIT is active for this Claude Code session.

Before responding to the user's most recent prompt:
1. Treat the prompt above as the draft input to the /improve slash command
   (see .claude/commands/improve.md for the workflow).
2. Run the hybrid clarifying-question workflow (always ask the success-
   criterion anchor question; ask 1-2 content-specific Qs only if the draft
   surfaces ambiguity; cap at 3 questions total).
3. Synthesize the refined prompt.
4. Call `bash scripts/improve/save-artifact.sh --original <verbatim>
   --refined <verbatim> --notes <Q-answers> --rationale <1-2-sentences>` to
   persist the audit artifact under <handover-root>/.improve/.
5. Then respond to the user using the REFINED prompt as the effective input,
   not the original draft. Surface the artifact path so the operator can
   review later.

If the draft is short, imperative, and already unambiguous (e.g. "merge PR
#123", "rerun the test"), skip /improve and respond directly.

To disable for the rest of the session, unset IMPROVE_ON_SUBMIT in the
launching shell + restart claude (env vars don't propagate into a running
session).
</system-reminder>
EOF
