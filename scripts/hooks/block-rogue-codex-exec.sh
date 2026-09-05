#!/usr/bin/env bash
# PreToolUse hook - blocks RAW `codex exec` dispatches (HIMMEL-2023).
#
# WHY: scripts/codex/dispatch-codex-exec.sh is the codex-exec lane's mandatory
# chokepoint (ACL preflight, gpt-5.5 + sandbox pins, --background refusal,
# worktree containment, job registry + fleet reap, and since HIMMEL-2023 the
# watchdog timebox + flow-run-ledger rows). A raw `codex exec` bypasses all of
# it - including the watchdog, so it is exactly the invisible-hang shape
# HIMMEL-1788 is about. The WSL variant has had this guard since HIMMEL-999;
# the native one was the remaining unfenced path. Sibling of
# block-rogue-codex-wsl.sh, same shape, same fail posture.
#
# Fail posture (sized for a Bash|PowerShell-wide matcher - a missing dep
# must never brick every shell call):
#   1. Raw-substring prefilter, NO jq needed: stdin JSON without both
#      "codex"+"exec" -> exit 0 (the ~100% fast path).
#   2. Tokens present + jq -> precise parse of tool_input.command:
#      codex/codex.exe in COMMAND POSITION + an `exec` verb -> exit 2.
#      Tokens inside quoted string data (commit messages, grep patterns) do
#      NOT block.
#   3. Tokens present + jq missing/parse failure -> fail CLOSED (exit 2).
#
# SCOPE: the same TEXTUAL command-position heuristic as the WSL sibling, with
# its limits (HIMMEL-1016 tracks shell-aware tokenization for both). It DOES
# catch a bare `VAR=value ... codex exec` env-assignment prefix and an `exec`
# verb terminated by a shell metacharacter (`codex exec;`, `codex exec|cat`,
# `codex exec>out`). It does NOT close deliberate evasions a textual matcher
# fundamentally cannot (command-prefix wrappers `command/env/sudo codex`,
# `env -S` spellings, a quoted verb, arbitrary obfuscation). The ENFORCED
# boundary is the chokepoint - a raw dispatch that never reaches it gets no
# preflight/pins/registry/ledger/watchdog - and CODEX_EXEC_RAW_OK is the
# documented bypass.
#
# Bypass: CODEX_EXEC_RAW_OK=1 (set in the LAUNCHING shell).
set -uo pipefail

# Drain stdin BEFORE any early exit - exiting with the pipe unread sends the
# writer a SIGPIPE (surfaces as rc 141 under pipefail harnesses).
INPUT="$(cat 2>/dev/null || true)"

[ "${CODEX_EXEC_RAW_OK:-0}" = "1" ] && exit 0
# Case-INSENSITIVE token match: Windows executable names are case-insensitive
# (Codex.exe == codex.exe), so an uppercased raw dispatch must not slip the
# prefilter. The original INPUT is preserved for the jq parse below.
INPUT_LC="$(printf '%s' "$INPUT" | tr '[:upper:]' '[:lower:]')"
case "$INPUT_LC" in
    *codex*) : ;;
    *) exit 0 ;;
esac
case "$INPUT_LC" in
    *exec*) : ;;
    *) exit 0 ;;
esac

_block() {
    echo "block-rogue-codex-exec: raw 'codex exec' refused - dispatch through the chokepoint: bash scripts/codex/dispatch-codex-exec.sh --worktree <path> [--shared-branch <branch>] [args...] (ACL preflight, model/sandbox pins, job registry, watchdog timebox + flow-run-ledger rows). Bypass for a deliberate one-off: CODEX_EXEC_RAW_OK=1 in the launching shell." >&2
    exit 2
}

if ! command -v jq >/dev/null 2>&1; then
    echo "block-rogue-codex-exec: jq missing while the command carries codex+exec tokens - failing closed (install jq, or CODEX_EXEC_RAW_OK=1 for a deliberate raw run)" >&2
    exit 2
fi

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || {
    echo "block-rogue-codex-exec: hook stdin unparseable while carrying codex+exec tokens - failing closed" >&2
    exit 2
}
[ -n "$CMD" ] || exit 0

# NO chokepoint-substring exemption (sibling's lesson): `# dispatch-codex-exec.sh`
# in a comment must not whitelist a raw dispatch. A genuine chokepoint
# invocation is `bash .../dispatch-codex-exec.sh ...` - codex is never in
# command position there (the `codex` inside the DIRECTORY name is followed by
# `/`, and the one inside the script NAME by `-`, so neither ends a token),
# so the command-position rule below already allows it.

# Strip quoted string DATA so tokens inside commit messages / grep patterns
# never put codex in command position. This also erases a quoted command NAME
# ('codex' ...), so the quoted-name checks below run on the ORIGINAL text.
STRIPPED="$(printf '%s' "$CMD" | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g")"

# Command-position detection composed from the same shared fragments as the
# WSL sibling (case-INSENSITIVE, Codex.exe == codex.exe on Windows):
#   _SEP        opener: line start (+ leading whitespace), or a separator
#               (| ; & && ||) / group / command-subst opener ( or backtick,
#               each optionally followed by whitespace. NOT bare whitespace -
#               that would block benign `echo codex exec`.
#   _ENVPFX     an optional run of shell VAR=value assignments between the
#               opener and the command name. `CODEX_HOME=... codex exec` is a
#               NATURAL raw shape, not an evasion, and without this arm it
#               slipped the command-position rule entirely (panel codex-1).
#               Deliberately narrow: only bare `NAME=value` words, so `env -S`
#               and friends stay on the documented not-closed list above (the
#               enumeration trap HIMMEL-1813 names).
#   _CODEX_BASE the codex basename, path-qualified via an optional leading run
#               ending in / or \ (/path/codex, C:\...\codex.exe).
#   _END        token end (whitespace or end of line).
# shellcheck disable=SC2016 # regex fragment: the ` and $ are ERE metachars, not shell expansion.
#   _VERB      the `exec` verb in CODEX'S OWN segment: optional flags that
#              cannot cross a separator (`[^|;&]*`), then the verb, then a
#              token end that also accepts a shell metacharacter (`codex
#              exec;`, `codex exec|cat`, `codex exec>out` are real dispatches
#              an ([[:space:]]|$) tail let through). The leading `[[:space:]]`
#              is inside the optional group's alternative, so a bare
#              `codex exec` matches with no flags.
#
# ONE regex, not two greps (panel r3): matching command position and the verb
# INDEPENDENTLY was wrong in both directions. It false-blocked
# `codex --version && echo codex exec` (the opener matched the first codex,
# the verb matched a later benign one), and it let `'codex' exec` through (the
# opener accepted the quoted name on $CMD while the verb ran on $STRIPPED,
# where quote-stripping had already erased that name). Requiring both halves
# in a SINGLE match closes both: the verb has to belong to the same
# command-position codex that opened the match.
# shellcheck disable=SC2016 # regex fragment: the ` and $ are ERE metachars, not shell expansion.
_SEP='(^[[:space:]]*|[|;&(`][[:space:]]*)'
# shellcheck disable=SC2016
_ENVPFX='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
# shellcheck disable=SC2016
_CODEX_BASE='([^[:space:]|;&()`]*[/\\])?(codex|codex\.exe)'
_VERB='([[:space:]]+[^|;&]*)?[[:space:]]exec([[:space:];&|<>()]|$)'
# Three arms: a bare command name on the quote-stripped text, and a quoted
# command NAME on the ORIGINAL (a quoted string whose ENTIRE content is
# (path-)codex(.exe), which a quoted DATA string like "codex exec x" never
# matches - its close quote does not fall right after the basename).
if printf '%s' "$STRIPPED" | grep -Eiq "${_SEP}${_ENVPFX}${_CODEX_BASE}${_VERB}" \
   || printf '%s' "$CMD" | grep -Eiq "${_SEP}${_ENVPFX}'${_CODEX_BASE}'${_VERB}" \
   || printf '%s' "$CMD" | grep -Eiq "${_SEP}${_ENVPFX}\"${_CODEX_BASE}\"${_VERB}"; then
    _block
fi
exit 0
