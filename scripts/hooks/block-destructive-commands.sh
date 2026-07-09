#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell.
#
# Deterministic destructive-command floor shared by Claude and Codex lanes
# (HIMMEL-754). Ports the TERMINAL_DESTRUCTIVE command classes from
# scripts/hermes/assets/parity_guard.py: catastrophic/shared-machine/
# irreversible terminal shapes only. Routine git/gh/mv/cp, non-recursive rm,
# curl without remote-exec pipe, and normal git status/commit/push are allowed.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow
#   2 - block; stderr is shown to the model/user
#
# Bypass: set DESTRUCTIVE_OK=1 in the shell that launched the agent. Session-
# sticky; restart without it to re-enable the guard.
set -euo pipefail

# Security hook: any unexpected top-level failure must deny, not fail open as a
# plain rc=1 hook error.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if [ "${DESTRUCTIVE_OK:-0}" = "1" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-destructive-commands: jq not on PATH - refusing to evaluate; install jq" >&2
    exit 2
fi

input=$(cat)
if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
    echo "block-destructive-commands: malformed/truncated JSON on stdin - failing closed" >&2
    exit 2
fi
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$tool" in
    Bash|PowerShell|"") ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# parity_guard.norm() lower-cases before applying TERMINAL_DESTRUCTIVE. Newlines
# separate shell commands, so preserve them as semicolon boundaries.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;')

contains() {
    printf '%s' "$cmd_lc" | grep -Eq "$1"
}

deny() {
    echo "block-destructive-commands: destructive command refused ($1)" >&2
    exit 2
}

# Binary boundary helpers are inlined in the patterns below. Every binary atom
# that parity_guard names tolerates an optional .exe suffix for the Windows lane.
# Bare-name atoms (format/schtasks/taskkill/shutdown/icacls classes) anchor to
# COMMAND POSITION - start of command or right after a separator, tolerating
# whitespace and env-var assignment prefixes - so the bare word inside an
# argument (git log --pretty=format:, grep -rn format src/) does not match.
# Mirrors parity_guard.py's _CMDPOS idiom for the external-write fence.
CMDPOS='(^|[|;&(`])[[:space:]]*([[:alnum:]_]+=[^[:space:]|;&]*[[:space:]]+)*'
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?([^[:alnum:]_.-][^|;&]*)?[[:space:]]-[[:alnum:]_]*r'; then
    deny "recursive rm"
fi
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?([^[:alnum:]_.-]|$)[^|;&]*--recursive([^[:alnum:]_-]|$)'; then
    deny "recursive rm"
fi
if contains '(^|[^[:alnum:]_.-])(del|erase|rd|rmdir)(\.exe)?([^[:alnum:]_.-]|$)[^|;&]*/s'; then
    deny "recursive Windows delete"
fi
# mkfs keeps no trailing boundary (parity: \bmkfs) so mkfs.ext4 still matches.
if contains "${CMDPOS}"'((format|diskpart|bcdedit)(\.exe)?([^[:alnum:]_.-]|$)|mkfs)'; then
    deny "disk/boot mutation"
fi
if contains '(^|[^[:alnum:]_.-])cipher(\.exe)?[[:space:]]+/w'; then
    deny "disk wipe"
fi
if contains "${CMDPOS}"'schtasks(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "scheduled-task mutation"
fi
if contains "${CMDPOS}"'(taskkill|stop-process|pskill)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "process termination"
fi
if contains '(^|[^[:alnum:]_.-])kill(\.exe)?[[:space:]]+-9'; then
    deny "process termination"
fi
if contains "${CMDPOS}"'(shutdown|reboot|logoff)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "system shutdown"
fi
if contains '(^|[^[:alnum:]_.-])reg(\.exe)?[[:space:]]+(add|delete)([[:space:]]|$)'; then
    deny "registry mutation"
fi
if contains "${CMDPOS}"'(icacls|takeown)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "permission mutation"
fi
if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+push([^|;&]*)(--force|--force-with-lease|[[:space:]]-f([^[:alnum:]_-]|$))'; then
    deny "force push"
fi
if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+reset[[:space:]]+--hard([^[:alnum:]_-]|$)'; then
    deny "git reset --hard"
fi
if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+clean[[:space:]]+-[[:alnum:]_]*f'; then
    deny "git clean -f"
fi
if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+filter-branch([^[:alnum:]_-]|$)'; then
    deny "git filter-branch"
fi
if contains '(^|[^[:alnum:]_.-])curl(\.exe)?[^|;&]*\|[[:space:]]*(ba)?sh(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "remote exec pipe"
fi
if contains '(^|[^[:alnum:]_.-])wget(\.exe)?[^|;&]*\|[[:space:]]*(ba)?sh(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "remote exec pipe"
fi

exit 0
