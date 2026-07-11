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
# whitespace, env-var assignment prefixes, and (HIMMEL-851 CR r1) a BOUNDED set
# of launcher wrappers - sudo, env, cmd [/switches] /c, powershell/pwsh
# [-flags] -c/-command - plus
# one optional quote before the atom (a quoted word in command position still
# executes) and (CR r2) a bounded EXECUTABLE-PATH prefix - optional Windows
# drive + path segments ending in "/" or "\" - so /sbin/<name>, ./<name>, and
# drive-qualified <name>.exe forms (quoted or not) are refused like the bare
# name. The exe-path prefix also applies before each WRAPPER token (CR r4),
# so /usr/bin/env <name>, /usr/bin/sudo <name>, and a path-qualified
# cmd.exe /c are refused like the bare-wrapper forms. sudo/env tolerate their
# own flag runs (CR r6: sudo -n, env -i), each flag may optionally consume one
# following non-dash value token (CR r7: sudo -u root, env -u PATH - generic,
# no per-option table; over-consumes at worst one benign token, never a
# bypass), and env also tolerates assignment arguments (env -i foo=bar
# shutdown). The bare word inside an argument
# (git log --pretty=format:, grep -rn format src/, echo shutdown) still does
# not match, and the atoms' trailing boundary keeps format-table-style
# basenames allowed. Deliberately NOT a general shell parser - the RESIDUAL
# documented gap is QUOTED-PAYLOAD wrappers (bash -c "<verb> ...", sh -c,
# xargs / nohup chains), out of scope per the ticket's no-general-parser rule.
# This bounded grammar is intentionally NOT an arms race: further wrapper
# permutations belong to the HIMMEL-912 shared-tokenizer follow-up, and this
# CC-hook + the auto-mode classifier remain the outer defense layers. Mirrors
# parity_guard.py's _CMDPOS_DESTRUCTIVE (shared contract).
# Assignment VALUE is quote-aware (CR r5): FOO='a b' / FOO="a b" would
# otherwise break prefix consumption at the space and drop the verb out of
# command position. Factored into ASSIGN so the env-prefix (CR r6) reuses it.
EXEPFX='["'\'']?([a-z]:)?([^[:space:]|;&`"'\'']*[/\\])?'
ASSIGN='[[:alnum:]_]+=('\''[^'\'']*'\''|"[^"]*"|[^[:space:]|;&]*)'
CMDPOS='(^|[|;&(`])[[:space:]]*(('"$ASSIGN"'|'"$EXEPFX"'(sudo([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|'"$ASSIGN"'))*|cmd(\.exe)?([[:space:]]+/[[:alnum:]]+(:[[:alnum:]]+)?)*[[:space:]]+/c|(powershell|pwsh)(\.exe)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+-c[[:alnum:]]*))[[:space:]]+)*'"$EXEPFX"
# Separator before the flag tolerates a real space OR a lowercased ${IFS}
# token (a common word-split bypass), and the flag itself tolerates one
# leading quote char - both `-rf` and `"-rf"`/`'-rf'` trip it (HIMMEL-851 U2/U3).
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?([^[:alnum:]_.-][^|;&]*)?([[:space:]]|\$\{ifs\})['\''"]?-[[:alnum:]_]*r'; then
    deny "recursive rm"
fi
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?([^[:alnum:]_.-]|$)[^|;&]*--recursive([^[:alnum:]_-]|$)'; then
    deny "recursive rm"
fi
# Backslash-newline continuation: newlines are already folded to ';' above, so
# `rm \<newline>-rf` becomes `rm \;-rf` here - the literal backslash before the
# folded separator is the tell (HIMMEL-851 U3). `;+` (not a single `;`): on
# Windows, jq's text-mode stdout turns the JSON-decoded `\n` into `\r\n`, so
# ONE real newline folds to TWO semicolons here - tolerate either.
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?[[:space:]]*\\[[:space:]]*;+[[:space:]]*-[[:alnum:]_]*r'; then
    deny "recursive rm (line continuation)"
fi
# /s is bound to the switch (space/another switch/end), not a path prefix -
# `rd /scripts` must not false-trip on the "/s" substring (HIMMEL-851 U1).
if contains '(^|[^[:alnum:]_.-])(del|erase|rd|rmdir)(\.exe)?([^[:alnum:]_.-]|$)[^|;&]*/s([^[:alnum:]_.-]|$)'; then
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
