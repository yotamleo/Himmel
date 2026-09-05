#!/usr/bin/env bash
# PreToolUse hook (Bash|PowerShell) - NARROW data-egress fence for `graphify`
# (HIMMEL-621/622 Phase G-F). Fast-exits 0 for every command that is not a
# graphify invocation; for a graphify command it delegates the corpus x
# provider x purpose decision to scripts/guardrails/graphify-fence.sh and
# propagates its verdict (fence exit 2 = deny, surfaced to Claude via stderr).
#
# Hook I/O contract (mirrors block-read-secrets.sh): input is JSON on stdin.
#   exit 0 - allow (default)
#   exit 2 - block; stderr is shown to Claude and the user
#
# The egress policy + all fail-closed logic live in the fence; this hook only
# does the stdin parse + the word-boundary graphify gate.
set -uo pipefail

# Raw-substring fallback for input we cannot structurally parse (jq missing, or
# malformed JSON). Stay NARROW: fail closed only when the payload mentions
# graphify; otherwise allow (never block unrelated Bash on an unparseable input).
_raw_decide() {
    case "$1" in
        *graphify*)
            echo "block-graphify-egress: unparseable tool input mentions graphify; refusing (fail-closed). Install jq / fix the payload or comment the hook." >&2
            exit 2
            ;;
        *) exit 0 ;;
    esac
}

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
    _raw_decide "$input"
fi

# jq present but the JSON is malformed -> same raw-substring fallback (a graphify
# mention in an unparseable payload fails closed rather than sailing through).
if ! printf '%s' "$input" | jq empty >/dev/null 2>&1; then
    _raw_decide "$input"
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$tool" in
    Bash|PowerShell) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# COMMAND-POSITION `graphify` match (HIMMEL-1180), not "the word appears
# anywhere". The old word-boundary check below matched a bare mention
# ANYWHERE in the command text (`grep -rn graphify .` or a reference left
# over after an unrelated `cd` both tripped it, HIMMEL-1168), which is a
# false-trip source, not a security property this hook actually needs -
# the real decision is delegated to graphify-fence.sh below regardless.
# Anchor to command position instead, sharing the SAME wrapper/assignment
# grammar block-destructive-commands.sh uses (HIMMEL-851: sudo / env / cmd
# [/switches] /c / powershell|pwsh [-flags] -c), so a wrapped invocation
# (`env FOO=1 graphify ...`, `sudo graphify ...`) still matches while an
# unrelated mention does not. Residual (accepted,
# HIMMEL-1180): a quoted-payload wrapper (`bash -c "graphify ..."`) is not
# unwrapped HERE - same documented HIMMEL-851 gap, proportionate for a hook
# guarding accidental agent egress rather than an adversary; graphify-fence.sh
# does its own bash -c unwrap for anything that DOES reach it. CR round 2
# (codex-2, suggestion): for the same "not a general parser" reason, this
# regex is not quote-aware either - a literal `; graphify ...` inside a
# quoted argument (e.g. `printf '; graphify x'`) can spuriously look like a
# new command-position clause and route to the fence. Accepted: an
# over-invocation of the fence on data that merely CONTAINS graphify-shaped
# text is a false-trip in the OPPOSITE direction from HIMMEL-1180's actual
# problem (over-blocking noise on real graphify text vs. an unnecessary
# fence call on a rare quoted string), and the fence itself still evaluates
# correctly - it just runs slightly more often than the ideal.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "block-graphify-egress: cannot source guardrails/lib.sh — refusing to evaluate" >&2
    exit 2
fi
guard_cmdpos_grammar
# CR round 1 (codex-1): the shared CMDPOS wrapper set (sudo/env/cmd/
# powershell|pwsh) does not include `timeout` -- block-destructive-
# commands.sh never wrapped it either (grep its own source: absent). Unlike
# the accepted bash -c residual above, `timeout 10 graphify ...` is NOT a
# quoted-payload case, and the OLD naive substring match DID catch it -- so
# leaving it out here would be a real regression, not the same accepted gap.
# CR round 2 (codex-1): same shape for the TRANSPARENT no-argument wrappers
# `command`/`exec`/`builtin`/`nohup`/`time`/`nice` -- graphify-fence.sh's own
# classify_clause already treats these as pass-through (HIMMEL-621), the
# shared CMDPOS never did, and the old substring match caught them too.
# Rebuild CMDPOS LOCALLY with both alternatives spliced into the same
# wrapper loop, reusing the EXEPFX/ASSIGN pieces guard_cmdpos_grammar
# already set -- kept local to this hook rather than folded into the shared
# function, since widening block-destructive-commands.sh's own grammar is a
# bigger, separately-reviewed change against its own 1000+-case suite, not
# something this ticket's diff should risk.
CMDPOS='(^|[|;&(`])[[:space:]]*(('"$ASSIGN"'|'"$EXEPFX"'(sudo([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|'"$ASSIGN"'))*|timeout([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?))*[[:space:]]+[^-[:space:]][^[:space:]]*|command|exec|builtin|nohup|time|nice|cmd(\.exe)?([[:space:]]+/[[:alnum:]]+(:[[:alnum:]]+)?)*[[:space:]]+/c|(powershell|pwsh)(\.exe)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+-c[[:alnum:]]*))[[:space:]]+)*'"$EXEPFX"
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr '\n\r' ';;')
if ! printf '%s' "$cmd_lc" | grep -Eq "${CMDPOS}graphify(\.exe)?([^[:alnum:]_.-]|\$)"; then
    exit 0
fi

# Tool-call cwd (HIMMEL-779): the command's cwd (.tool_input.cwd) is where the
# agent will actually run it; this hook process's own $PWD is the project root
# and can differ. Thread it to the fence (GRAPHIFY_TOOL_CWD) so relative and
# bare-word targets resolve against the REAL command cwd, not the hook's - a
# relative path into a protected corpus would otherwise resolve under the
# project root and miss (fail-open). Absent on payloads that carry no cwd.
tool_cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)

FENCE="$SCRIPT_DIR/../guardrails/graphify-fence.sh"
[ -f "$FENCE" ] || exit 0   # fence not installed -> do not block

if [ -n "$tool_cwd" ]; then
    export GRAPHIFY_TOOL_CWD="$tool_cwd"
else
    # No-cwd payload: drop any GRAPHIFY_TOOL_CWD inherited from the launching
    # shell's environment, so the fence falls back to its own $PWD (documented
    # behavior) instead of anchoring to a stale leaked value.
    unset GRAPHIFY_TOOL_CWD
fi
exec bash "$FENCE" "$cmd"
