#!/usr/bin/env bash
# UserPromptExpansion hook for the /pr-check slash command.
#
# HIMMEL-2306: `/pr-check` takes NO argument (HIMMEL-2226, operator ruling
# 2026-08-31). Until this hook, a supplied argument was SILENTLY IGNORED, so a
# stale `/pr-check <repo-path>` typed from muscle memory reviewed the CURRENT
# repo — and could clear ITS CR marker — instead of the one the operator meant.
#
# Why this is a hook and not a line in the runbook. HIMMEL-2226 tried twice to
# enforce the contract in-prompt and both were rejected on review:
#
#   1. A fence reading `$ARGUMENTS` and refusing when non-empty. That IS the
#      injection surface HIMMEL-2226 exists to delete: the harness substitutes
#      the argument as literal TEXT before any shell parses it, so a path
#      containing an apostrophe or `$(…)` breaks out and executes.
#      `scripts/cr/test-pr-check-pair.sh` check (vi) now asserts `$ARGUMENTS`
#      appears nowhere in either twin, so that route is structurally closed.
#   2. Substituting the argument into a sentinel line in PROSE, on the theory
#      that prose carries no shell. Shipped briefly, reverted the same night —
#      the agent reading the runbook is ITSELF an interpreter, so a crafted
#      argument lands in its instructions before any guard is evaluated.
#
# The general lesson: no in-prompt construct can enforce this. Anything that
# lets the runbook OBSERVE the argument has already brought the untrusted value
# inside the boundary it is trying to defend. So the refusal has to happen
# before the prompt is assembled — which is what this hook does. The value never
# reaches the runbook: there is nothing to inject into, and nothing to instruct
# the agent to ignore. (CLAUDE.md, "Structural > instructional": on the second
# drift escalate to a hook, gate or classifier, never to stronger prose. This
# was the second drift.)
#
# Event choice, verified against the INSTALLED build rather than the docs
# (claude.exe 2.1.251 — the published hook docs disagree with the binary on two
# points that matter here, see below):
#
#   - `UserPromptExpansion` fires when a user-typed command expands into a
#     prompt, before it reaches the model, and can block that expansion. Its
#     payload carries `expansion_type` ("slash_command" | "mcp_prompt"),
#     `command_name`, `command_args`, `command_source` and `prompt`.
#     `command_args` is a FIRST-CLASS FIELD, so this hook never parses the raw
#     prompt text — it reads the argument the harness already split out.
#   - The docs describe `command_input` and `expanded_prompt` fields; NEITHER
#     exists in this build. The fields are `command_args` and `prompt`.
#   - The docs describe blocking via `hookSpecificOutput.permissionDecision:
#     "deny"`; that enum is PreToolUse-only. For this event the contract is a
#     top-level `{"decision":"block"}` — or exit 2, which the binary's own
#     per-event table documents as "block expansion and show stderr to user
#     only". This hook uses exit 2: one stable contract, no JSON to get wrong.
#   - The matcher for this event is `fieldToMatch: "command_name"`, compared
#     against the BARE name (`pr-check`, no leading slash).
#
# Wiring is an OPERATOR step — `.claude/settings.json` is not agent-writable:
#
#   "UserPromptExpansion": [
#     { "matcher": "pr-check",
#       "hooks": [ { "type": "command",
#                    "command": "bash \"$HIMMEL_REPO/scripts/hooks/block-pr-check-args.sh\"" } ] }
#   ]
#
# THE ANCHOR IS `HIMMEL_REPO`, NOT `CLAUDE_PROJECT_DIR` — and that is
# load-bearing, not a style choice (panel round 3). `/pr-check`'s supported
# foreign-repo workflow (HIMMEL-2035) is to start a session whose cwd IS the
# repo under review, so in exactly that lane `CLAUDE_PROJECT_DIR` points at the
# REVIEWED repo. Wiring this hook through it would mean one of two things, both
# bad: a crafted repo carrying its own `scripts/hooks/block-pr-check-args.sh`
# gets it EXECUTED as a hook, or the path does not exist and the guard silently
# never fires. `HIMMEL_REPO` is the anchor the guardrail stack already treats as
# authoritative — adopt/setup wires it into settings.json `env`, so it arrives
# from OUTSIDE any repo and a reviewed repo cannot forge it. Same reasoning as
# HIMMEL-2226 Finding 1, which resolved `<himmel_dir>` from this anchor for
# precisely this reason; a security hook must not be located by the thing it is
# guarding against.
#
# The `command_name` check below is deliberately kept even though the matcher
# already narrows to `pr-check`: a wiring that omits the matcher must not turn
# this into a guard on every slash command.
#
# FAILURE DIRECTION: FAIL CLOSED (scripts/hooks/CLAUDE.md). This is a security
# fence, not a workflow nudge — it exists to keep an untrusted value out of a
# prompt, so anything it cannot evaluate is REFUSED rather than waved through.
# Concretely: missing jq, a payload that is not valid JSON, and any unexpected
# non-zero from the body all exit 2, and the EXIT trap below converts a stray
# rc into 2 so a crash cannot read as an allow. The blast radius of that choice
# is deliberately small: wired with its matcher, this hook only ever runs for
# `/pr-check`, so a fail-closed error refuses exactly that one command and
# nothing else. It ALLOWS (exit 0) only after positively establishing all three
# of: this is a slash-command expansion, the command is pr-check, and the
# argument is empty — never by falling through.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow the expansion
#   2 - block it; stderr is shown to the user
#
# Bypass: set PR_CHECK_ARGS_OK=1 in the shell that launched the agent, e.g.
# `PR_CHECK_ARGS_OK=1 claude`. Session-sticky — a per-call prefix does NOT
# work; restart without it to re-enable the guard. The deny message names it.
set -euo pipefail

# Security hook: any unexpected top-level failure must deny, not fail open as a
# plain rc=1 hook error.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if [ "${PR_CHECK_ARGS_OK:-0}" = "1" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-pr-check-args: jq not on PATH - refusing to evaluate; install jq" >&2
    exit 2
fi

payload="$(cat)"

# A malformed payload is not a licence to proceed: fail closed.
if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    echo "block-pr-check-args: hook payload is not valid JSON - refusing to evaluate" >&2
    exit 2
fi

# SCOPE IS DECIDED ON POSITIVE EVIDENCE OF BEING OUT OF SCOPE — never on a
# field this hook merely failed to read. An earlier revision skipped unless
# `expansion_type` was exactly "slash_command", so a payload where that key was
# missing or renamed took the ALLOW path: a silent disarm dressed as a
# fail-closed hook. That is the very failure mode this ticket is about — the
# published docs named fields (`command_input`, `expanded_prompt`) that do not
# exist in the binary, so a schema this hook cannot parse is a live scenario,
# not a hypothetical. Hence `has()` below: it distinguishes ABSENT from
# PRESENT-but-different, which `// ""` cannot.
# TYPE, not mere presence. `has()` alone is still too weak: an explicit JSON
# null satisfies it, and `// ""` then coerces the null to the empty string — so
# `{"command_args": null}` would read as "a bare invocation" and be ALLOWED,
# and `{"command_name": null}` as "some other command, not my business". Both
# are schema drift, not evidence. The 2.1.251 schema types all three of these
# as plain strings (`command_name:i(), command_args:i()`), so anything that is
# not a string here is by definition not the schema this hook was written
# against, and must not be interpreted (panel round 4).
type_type="$(printf '%s' "$payload" | jq -r '.expansion_type | type')"
name_type="$(printf '%s' "$payload" | jq -r '.command_name | type')"
args_type="$(printf '%s' "$payload" | jq -r '.command_args | type')"
expansion_type="$(printf '%s' "$payload" | jq -r '.expansion_type // ""')"
command_name="$(printf '%s' "$payload" | jq -r '.command_name // ""')"
command_args="$(printf '%s' "$payload" | jq -r '.command_args // ""')"

# OUT OF SCOPE (1): the payload names a command, and it is not pr-check. Only a
# real STRING name is evidence — absent, null or any non-string is not.
if [ "$name_type" = "string" ]; then
    case "$command_name" in
        pr-check|/pr-check) ;;  # in scope, fall through
        *) exit 0 ;;
    esac
fi

# OUT OF SCOPE (2): an MCP prompt that happens to share the name is a different
# surface. Again only an EXPLICIT string "mcp_prompt" exits; absent, null or
# unrecognised falls through to the argument check rather than skipping it.
if [ "$type_type" = "string" ] && [ "$expansion_type" = "mcp_prompt" ]; then
    exit 0
fi

# In scope (or indistinguishable from it). The argument field must be READABLE
# AS A STRING: if it is absent, null, or any other type, this hook cannot
# certify that no argument was supplied, and "cannot certify" is exactly the
# case that must deny.
if [ "$args_type" != "string" ]; then
    cat >&2 <<'EOF'
block-pr-check-args: DENIED — this payload has no usable `command_args` STRING
(it is absent, null, or another type), so the guard cannot tell whether
/pr-check was given an argument. Refusing rather than guessing: an unreadable
payload is the one case that must not be waved through.

Most likely the hook event schema changed. Re-read it from the installed build
(the published docs have been wrong here before) and update this hook.

Bypass, if you need to proceed meanwhile: PR_CHECK_ARGS_OK=1 in the shell that
launches the agent.
EOF
    exit 2
fi

# Trim surrounding whitespace. `/pr-check ` (a trailing space) is a bare
# invocation, not an argument, and must not be refused.
trimmed="$(printf '%s' "$command_args" | tr -d '[:space:]')"
[ -n "$trimmed" ] || exit 0

# Deliberately does NOT echo the argument back. The whole point of refusing here
# is that the untrusted value never transits a prompt; printing it into the
# transcript would hand it straight to the agent this hook is protecting.
cat >&2 <<'EOF'
block-pr-check-args: DENIED — /pr-check takes no argument (HIMMEL-2226,
operator ruling 2026-08-31). The argument was discarded; nothing was expanded
and nothing ran.

Passing one used to be silently ignored, which is the actual hazard: the run
would review the CURRENT repo — and could clear ITS CR marker — not the path
you typed.

To review a branch in another repo (an adopter's own repo, or a throwaway clone
of an upstream PR): start a session whose cwd IS that repo, then run a bare

    /pr-check

cwd selects the repo under review; the himmel scripts are resolved separately
from the HIMMEL_REPO anchor, so a bare invocation is always unambiguous.

(Bypass, if you genuinely need the argument through: PR_CHECK_ARGS_OK=1 in the
shell that launches the agent — but the runbook reads no argument, so this only
restores the silent-ignore behaviour this guard exists to end.)
EOF
exit 2
