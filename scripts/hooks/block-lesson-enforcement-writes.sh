#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell) - thin
# wrapper for the lesson-loop enforcement-path write-fence (HIMMEL-767
# deliverable 3). The self-evolving loop (lessons -> tickets/draft-PRs) is
# PROPOSE-ONLY; this hook is the delivery surface that structurally denies it
# enforcement-path writes. Mirrors block-graphify-egress.sh structurally
# (env fast-exit -> stdin parse -> delegate to a fence script), but with two
# DELIBERATE deviations - both because this hook only ever runs inside a
# lesson-loop worker (gated on HIMMEL_LESSON_LOOP=1), never a normal
# interactive session:
#
#   1. STRICT vs NARROW fallback. block-graphify-egress falls back to a
#      narrow substring match (deny only if the unparseable payload mentions
#      "graphify") when jq is missing or the JSON is malformed, because that
#      hook is always-on and must not false-block ordinary Bash calls it
#      cannot parse. This hook is already scoped by the env gate below - by
#      the time we get here we know we are inside a fully-automated loop
#      worker, and there is no human to mis-serve by failing closed. So:
#      active + jq missing OR JSON malformed -> DENY, unconditionally.
#
#   2. Fence-missing polarity. block-graphify-egress ALLOWS when its fence
#      sibling is not installed (a missing fence must not block ordinary
#      Bash in a normal session). Here the polarity is inverted: fence file
#      missing while ACTIVE -> DENY. A lesson-loop session that is active
#      (HIMMEL_LESSON_LOOP=1) but has lost its fence sibling has lost its
#      entire structural backstop - exactly the failure this fence exists to
#      prevent - so the safe outcome is to refuse the write, not silently
#      let it through.
#
# Hook I/O contract: input is JSON on stdin. exit 0 = allow, exit 2 = block
# (stderr shown to Claude/the user).
set -uo pipefail

# Fast-exit: zero cost for every normal (non-loop) session. Nothing below
# this line runs unless we are inside a lesson-loop worker.
[ "${HIMMEL_LESSON_LOOP:-0}" = "1" ] || exit 0

input=$(cat)

# Active + jq missing OR malformed JSON -> DENY (strict; see header point 1).
if ! command -v jq >/dev/null 2>&1; then
    echo "block-lesson-enforcement-writes: jq not found on PATH while HIMMEL_LESSON_LOOP=1 is active; refusing (fail-closed)." >&2
    exit 2
fi
if ! printf '%s' "$input" | jq empty >/dev/null 2>&1; then
    echo "block-lesson-enforcement-writes: malformed JSON payload while HIMMEL_LESSON_LOOP=1 is active; refusing (fail-closed)." >&2
    exit 2
fi

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell) ;;
    *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FENCE="$SCRIPT_DIR/../guardrails/lesson-write-fence.sh"

# Fence sibling missing while ACTIVE -> DENY (see header point 2: opposite
# polarity from block-graphify-egress's fence-not-installed allow).
if [ ! -f "$FENCE" ]; then
    echo "block-lesson-enforcement-writes: fence script missing at $FENCE while HIMMEL_LESSON_LOOP=1 is active; refusing (fail-closed) - a loop session without its fence must not run." >&2
    exit 2
fi

printf '%s' "$input" | bash "$FENCE"
exit $?
