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

# Sanctioned CLIProxyAPI proxy lifecycle (HIMMEL-1451): bouncing the proxy
# needs process termination (taskkill / Stop-Process / schtasks /end), all of
# which the deny floor below refuses at command position. The SAFE path is the
# cli-proxy-lane.ps1 -Restart/-Stop verb, which does that termination INTERNALLY
# -- this hook only ever sees the command the agent hands the shell, never a
# script's internals. Permit EXACTLY these literal invocation shapes: a `case`
# on the WHOLE lowercased command with QUOTED (non-glob) alternatives, so the
# match is anchored end-to-end with no wildcards -- a near-miss (a different
# script path, an appended destructive command, or a direct taskkill) does NOT
# inherit a free pass and still hits the deny floor below. powershell and pwsh
# both carry the script (HIMMEL-1432 dual-shell convention). r3 documented the
# combined -Install -Restart [-Force] one-shot pin-roll (.EXAMPLE); r4 added it
# here so the sanctioned forms enumerated below match the documented lifecycle
# (HIMMEL-1451 r4 / glm-4).
#
# codex-1 (CR r4) -- why this carve-out carries NO cwd/repo-root anchor. The
# sanctioned path is RELATIVE, so a roamed shell CWD could in principle resolve
# it to an impostor `scripts/setup/cli-proxy-lane.ps1`. But anchoring THIS
# carve-out cannot close that vector, because the deny floor below INDEPENDENTLY
# allows `powershell/pwsh -NoProfile -File <any relative script>`: no deny rule
# matches (the CMDPOS grammar only arms `-c` as a launcher wrapper, not `-File`,
# and -restart/-stop/-install/-force are not destructive primitives at command
# position). An escaped/impostor relative invocation that does NOT match this
# exact case therefore still passes the floor (rc=0 -- verified empirically: a
# `./`-prefixed path, a `../` escape, and a `cd x; ...` prefix all return rc=0).
# The relative-resolution vector is a FLOOR-LEVEL residual (script-internals
# unseen -- the documented no-general-parser gap, HIMMEL-912 class), not a hole
# this carve-out opens or can close; narrowing the carve-out's text would only
# hide the blessing while the floor keeps allowing the impostor. The carve-out's
# real job is forward-compat stability + explicit blessing of the sanctioned
# shapes (so a future floor rule that DOES match -File/-restart cannot silently
# break the documented lifecycle) -- not gatekeeping the relative path. Closing
# the residual belongs to a HIMMEL-912 floor follow-up, out of scope for r4.
case "$cmd_lc" in
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart -force'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop -force'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart -force')
        exit 0
        ;;
esac

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
# Verb split (HIMMEL-1141): schtasks /query is read-only (the diagnostic the
# clip-pipe cadence investigation was blocked from running), so only the
# mutating verbs are refused — /query and help/no-verb forms stay allowed.
# Mirrors parity_guard.py's schtasks line (lockstep, HIMMEL-754).
if contains "${CMDPOS}"'schtasks(\.exe)?[[:space:]]+(/create|/change|/delete|/end|/run|/config)([^[:alnum:]_.-]|$)'; then
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
