#!/usr/bin/env bash
# PreToolUse hook - blocks RAW `wsl ... codex exec` dispatches (HIMMEL-999).
#
# WHY: scripts/codex/dispatch-codex-wsl.sh is the WSL lane's mandatory
# chokepoint (containment, mutex, pins, quota preflight, ledger). A raw
# in-distro codex exec bypasses all of it; this hook makes the chokepoint
# structural (HIMMEL-195 second-drift escalation, block-backend-tier family).
#
# Fail posture (sized for a Bash|PowerShell-wide matcher - a missing dep
# must never brick every shell call):
#   1. Raw-substring prefilter, NO jq needed: stdin JSON without all of
#      "wsl"+"codex"+"exec" -> exit 0 (the ~100% fast path).
#   2. Tokens present + jq -> precise parse of tool_input.command:
#      wsl/wsl.exe in COMMAND POSITION + a `codex exec` verb + not the
#      chokepoint path -> exit 2. Tokens inside quoted string data (commit
#      messages, grep patterns) do NOT block.
#   3. Tokens present + jq missing/parse failure -> fail CLOSED (exit 2).
#
# SCOPE (HIMMEL-1016): a TEXTUAL command-position heuristic. It catches every
# NATURAL raw shape - unquoted/cased wsl, quoted command names ('wsl'/"wsl"),
# path-qualified basenames, subshell / command-subst / backtick openers - and
# does NOT false-block benign args (echo wsl codex exec). It does NOT close
# DELIBERATE evasions a textual matcher fundamentally cannot (command-prefix
# wrappers `command/env/sudo wsl`, a quoted `"codex"` verb, arbitrary
# obfuscation): the ENFORCED boundary is the chokepoint (a raw dispatch that
# never reaches it gets no containment/mutex/quota/ledger) and CODEX_WSL_RAW_OK
# is the documented bypass. Shell-aware tokenization (the complete fix) is
# tracked in HIMMEL-1016.
#
# Bypass: CODEX_WSL_RAW_OK=1 (set in the LAUNCHING shell).
set -uo pipefail

# Drain stdin BEFORE any early exit - exiting with the pipe unread sends the
# writer a SIGPIPE (surfaces as rc 141 under pipefail harnesses).
INPUT="$(cat 2>/dev/null || true)"

[ "${CODEX_WSL_RAW_OK:-0}" = "1" ] && exit 0
# Case-INSENSITIVE token match: Windows executable names are case-insensitive
# (WSL.exe == wsl.exe == Wsl), so an uppercased raw dispatch must not slip the
# prefilter (codex-adv HIMMEL-999). tr is a coreutil (present wherever this
# hook's sed/grep are); the original INPUT is preserved for the jq parse below.
INPUT_LC="$(printf '%s' "$INPUT" | tr '[:upper:]' '[:lower:]')"
case "$INPUT_LC" in
    *wsl*) : ;;
    *) exit 0 ;;
esac
case "$INPUT_LC" in
    *codex*) : ;;
    *) exit 0 ;;
esac
case "$INPUT_LC" in
    *exec*) : ;;
    *) exit 0 ;;
esac

_block() {
    echo "block-rogue-codex-wsl: raw 'wsl ... codex exec' refused - dispatch through the chokepoint: bash scripts/codex/dispatch-codex-wsl.sh --distro <name> --clone <in-distro-path> [--brief-file <path>] [args...] (containment, mutex, quota preflight, ledger). Bypass for a deliberate one-off: CODEX_WSL_RAW_OK=1 in the launching shell. (HIMMEL-999)" >&2
    exit 2
}

if ! command -v jq >/dev/null 2>&1; then
    echo "block-rogue-codex-wsl: jq missing while the command carries wsl+codex+exec tokens - failing closed (install jq, or CODEX_WSL_RAW_OK=1 for a deliberate raw run)" >&2
    exit 2
fi

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || {
    echo "block-rogue-codex-wsl: hook stdin unparseable while carrying wsl+codex+exec tokens - failing closed" >&2
    exit 2
}
[ -n "$CMD" ] || exit 0

# NO chokepoint-substring exemption: `# dispatch-codex-wsl.sh` in a comment
# must not whitelist a raw dispatch. A genuine chokepoint invocation is
# `bash .../dispatch-codex-wsl.sh ...` - wsl is never in command position
# there ("wsl" inside the script NAME fails the word-boundary regex), so
# the command-position rule below already allows it.

# Strip quoted string DATA so tokens inside commit messages / grep patterns
# never put wsl in command position (s55 false-positive class). This also
# erases a quoted command NAME ('wsl' ...), so the quoted-name checks below
# run on the ORIGINAL text to catch that (panel HIMMEL-999).
STRIPPED="$(printf '%s' "$CMD" | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g")"

# Command-position detection composed from shared fragments (case-INSENSITIVE,
# WSL.exe == wsl.exe on Windows):
#   _SEP      opener: line start (+ leading whitespace), or a separator
#             (| ; & && ||) / group / command-subst opener ( or backtick, each
#             optionally followed by whitespace. NOT bare whitespace - that
#             blocked benign `echo wsl codex exec` (panel codex-2 HIMMEL-999).
#   _WSL_BASE the wsl basename, path-qualified via an optional leading run
#             ending in / or \ (/path/wsl.exe, C:\...\wsl.exe).
#   _END      token end (whitespace or end of line).
# Three checks: unquoted wsl on the STRIPPED text (covers subshell `(wsl ...)`,
# command-subst `x=$(wsl ...)`, backtick, absolute path - codex-adv); plus a
# QUOTED command name 'wsl'/"wsl" on the ORIGINAL text - a quoted string whose
# ENTIRE content is (path-)wsl(.exe), which a quoted DATA string
# ("...wsl codex...") never matches (its close quote does not fall right after
# the basename) - panel HIMMEL-999. Values expand literally, so the backtick/$
# inside them never re-interpret; the double-quoted composition is safe.
# shellcheck disable=SC2016 # regex fragment: the ` and $ are ERE metachars, not shell expansion.
_SEP='(^[[:space:]]*|[|;&(`][[:space:]]*)'
# shellcheck disable=SC2016
_WSL_BASE='([^[:space:]|;&()`]*[/\\])?(wsl|wsl\.exe)'
_END='([[:space:]]|$)'
if printf '%s' "$STRIPPED" | grep -Eiq "${_SEP}${_WSL_BASE}${_END}" \
   || printf '%s' "$CMD" | grep -Eiq "${_SEP}'${_WSL_BASE}'${_END}" \
   || printf '%s' "$CMD" | grep -Eiq "${_SEP}\"${_WSL_BASE}\"${_END}"; then
    # `codex exec` verb on the ORIGINAL command - the raw shape carries its
    # payload inside the quoted bash -lc string, which stripping would erase.
    if printf '%s' "$CMD" | grep -Eiq 'codex([[:space:]]+[^|;&]*)?[[:space:]]exec([[:space:]]|$)|codex[[:space:]]+exec([[:space:]]|$)'; then
        _block
    fi
fi
exit 0
