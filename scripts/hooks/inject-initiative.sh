#!/usr/bin/env bash
# inject-initiative.sh — SessionStart hook for opt-in initiative mode (HIMMEL-425).
#
# Gated by the HIMMEL_INITIATIVE env var (must be set in the shell that
# LAUNCHED Claude — bypass convention per scripts/hooks/CLAUDE.md; a per-call
# prefix does NOT reach the hook process). When active, the session is given a
# scoped "drive to ship" directive so a normal session proactively runs the
# /pr-check → open PR → transition ticket → handover sequence at natural
# completion points, without the operator saying "ship it" each time.
#
# Per-part control (mirrors CRITIC_PANEL_TIERS): the value is either a master
# switch (1/true/on/yes/all → all four parts) or a comma-separated subset of
# the canonical parts `prcheck,pr,ticket,handover`. Parsing is
# case-insensitive and whitespace-tolerant; unknown tokens are ignored; steps
# always render in canonical order regardless of input order. The directive
# echoes the recognized tokens (`Active steps: …`) so a typo is visible.
#
# Default: OFF. Exit silently when the env is unset, falsy, or resolves to no
# recognized part — behaviour then is byte-identical to a session without the
# directive.
#
# This is ADVISORY injected context, not a permission change: it cannot widen
# what the hooks allow. The safety rails still HARD-block (check-cr-marker-on-
# pr-create gates gh pr create; the persistence classifier vetoes reactive
# --amend and settings.json self-edits; merge stays an operator action).
#
# Hook contract (SessionStart):
#   - Reads the SessionStart JSON payload from stdin (we don't consume fields).
#   - Exit 0 with stdout → stdout is injected as additional context.
#   - Non-zero exit → would surface an error; we never block, only ever exit 0.
#
# Wiring (in .claude/settings.json):
#   {
#     "hooks": {
#       "SessionStart": [
#         { "hooks": [ { "type": "command",
#                        "command": "bash $CLAUDE_PROJECT_DIR/scripts/hooks/inject-initiative.sh"
#                      } ] }
#       ]
#     }
#   }

set -euo pipefail

# Always exit clean; never block session start.
trap 'exit 0' ERR

# Drain stdin so the hook contract doesn't break the runtime if it pipes a
# payload. We don't currently need the JSON body.
if [ -t 0 ]; then
    :
else
    cat >/dev/null 2>&1 || true
fi

# --- Parse HIMMEL_INITIATIVE into the set of active chain parts -------------
# The value is either a whole-string master switch or a comma-separated subset
# of the four canonical parts (mirrors CRITIC_PANEL_TIERS). Normalize once:
# lowercase + strip all whitespace so "PR, ticket" == "pr,ticket". Bash 3.2-safe.
_norm=$(printf '%s' "${HIMMEL_INITIATIVE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

# Resolve the active parts (canonical order is fixed by the loop below, not by
# input order). `active` is a space-separated list drawn from the canonical set.
case "$_norm" in
    ""|0|false|off|no)
        exit 0
        ;;
    1|true|on|yes|all)
        active="prcheck pr ticket handover"
        ;;
    *)
        # Comma subset: keep only canonical tokens (membership test against the
        # input dedups, drops empty/trailing fields, and ignores unknowns).
        active=""
        for _tok in prcheck pr ticket handover; do
            case ",$_norm," in
                *,"$_tok",*) active="$active $_tok" ;;
            esac
        done
        active="${active# }"
        # A non-empty value that resolved to nothing (all-unknown / typo) is off.
        [ -n "$active" ] || exit 0
        ;;
esac

# CSV of recognized tokens for the in-session echo (typo visibility).
_steps_csv=$(printf '%s' "$active" | tr ' ' ',')

# --- Assemble the directive ------------------------------------------------
# Invariant prose stays in quoted heredocs (it contains backticks that an
# unquoted heredoc would try to command-substitute). Only the numbered step
# list is built dynamically, so it renumbers to the active subset.
cat <<'EOF'
<system-reminder>
HIMMEL_INITIATIVE is active for this Claude Code session.
EOF
printf 'Active steps: %s\n' "$_steps_csv"
cat <<'EOF'

Take initiative: drive the current work to done without waiting for an
explicit "ship it" each time. At a *natural completion point* (a logical chunk
of work is finished AND verified):
EOF

_n=0
# shellcheck disable=SC2016 # backticks in the format strings are literal directive prose, not expansions
for _tok in $active; do
    _n=$((_n + 1))
    case "$_tok" in
        prcheck)  printf '%d. Run `/pr-check` and loop — fix every finding, re-run — until CR is clean.\n' "$_n" ;;
        pr)       printf '%d. When CR is clean, open or refresh the PR.\n' "$_n" ;;
        ticket)   printf '%d. Transition the Jira ticket to the appropriate status.\n' "$_n" ;;
        handover) printf '%d. Write the handover.\n' "$_n" ;;
    esac
done

cat <<'EOF'

Scope and limits:
- Fire only at completion points, NOT on every small edit. Don't interrupt
  mid-task.
- Do NOT merge — merge stays an operator action.
- This directive does NOT relax any safety rail. The CR-marker hook still
  HARD-blocks `gh pr create` until a clean /pr-check; attestation trailers must
  be in the FIRST commit; reactive `git commit --amend` and self-editing
  `.claude/settings.json` to widen rules are still HARD-vetoed.

To disable for the rest of the session, unset HIMMEL_INITIATIVE in the
launching shell + restart claude (env vars don't propagate into a running
session). For per-part control, set HIMMEL_INITIATIVE to a comma-separated
subset of: prcheck, pr, ticket, handover (e.g. HIMMEL_INITIATIVE=prcheck,pr).
</system-reminder>
EOF

exit 0
