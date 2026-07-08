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

# Word-boundary `graphify` match (a path-invoked `.../graphify` still matches;
# `mygraphify` / `graphifyx` do not). Pad so leading/trailing boundaries work.
case " $cmd " in
    *[!A-Za-z0-9_]graphify[!A-Za-z0-9_]*) ;;
    *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FENCE="$SCRIPT_DIR/../guardrails/graphify-fence.sh"
[ -f "$FENCE" ] || exit 0   # fence not installed -> do not block

exec bash "$FENCE" "$cmd"
