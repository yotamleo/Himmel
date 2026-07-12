#!/usr/bin/env bash
# scripts/hermes/dispatch-trusted.sh — TRUSTED-engine hermes dispatch with the
# external-writes opt-in (HERMES_EXTERNAL_WRITES_OK=1) set INSIDE the wrapper.
#
# WHY (HIMMEL-654 session-8, operator-directed): a hermes WORKER writing repo
# files needs the fence opt-in in its launch env, but an inline
# `HERMES_EXTERNAL_WRITES_OK=1 bash invoke.sh …` is denied by the auto-mode
# classifier as an unnamed safety-bypass flag. This wrapper is the NAMED
# escape hatch: the operator authorizes it ONCE with a specific standing
# allow-rule, after which agents dispatch trusted hermes workers unattended.
#
#   Operator setup (one-time; agents cannot self-add rules):
#     .claude/settings.json → permissions.allow:
#       "Bash(bash scripts/hermes/dispatch-trusted.sh:*)"
#
# SAFETY: this wrapper does NOT relax the fence. parity_guard's
# _external_writes_allowed() stays fail-closed — an untrusted engine
# (z.ai / GLM) is refused REGARDLESS of the env var; the opt-in only takes
# effect on a trusted (codex-class) engine. Defaults to the himmel_agent
# profile (senior trusted tier) unless the caller passes --profile.
#
# Usage: identical to invoke.sh (see scripts/hermes/invoke.sh):
#   dispatch-trusted.sh [--model <m>] [--profile <p>] [--toolsets <list>]
#                       [--prompt-file <path>] [--log <path>] [<prompt>|-]
#
# Environment:
#   HERMES_INVOKE   Override the invoke.sh path (tests inject a stub).
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVOKE="${HERMES_INVOKE:-$SCRIPT_DIR/invoke.sh}"

if [ ! -f "$INVOKE" ]; then
    echo "dispatch-trusted.sh: invoke chokepoint not found: $INVOKE" >&2
    exit 2
fi

# Default to the trusted senior profile unless the caller chose one.
have_profile=0
for a in "$@"; do
    case "$a" in --profile|--profile=*) have_profile=1 ;; esac
done

if [ "$have_profile" -eq 1 ]; then
    HERMES_EXTERNAL_WRITES_OK=1 exec bash "$INVOKE" "$@"
fi
HERMES_EXTERNAL_WRITES_OK=1 exec bash "$INVOKE" --profile himmel_agent "$@"
