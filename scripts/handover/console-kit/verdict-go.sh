#!/usr/bin/env bash
# scripts/handover/console-kit/verdict-go.sh - one call from a
# judge's verdict to the persisted verdict, the GO, the Results bullet and the
# board. The console used to spend 8 to 9 full-context turns on that
# bookkeeping per verdict; this runs the same sanctioned
# steps in order and prints the message to send the leg.
#
# Usage: verdict-go.sh <qid> <GO|NO-GO> <head> --pr <n> --evidence-file <path>
#                      [--trust] [--leg <label>] [--doc <console doc>] [--prior <GO|NO-GO>]
#
#   1. write-verdict.sh <qid> <answer> <head> --pr <n> --evidence-file <path> [--prior <GO|NO-GO>]
#   2. GO only: go.sh [--trust-reviewed <qid>] <n> <head>   (--trust adds the flag;
#      go.sh's own ready-check is never bypassed)
#   3. with --doc: append-results.sh <doc> "<qid> answer: <answer> · GO <n> <head8>"
#   4. GO with --doc: node board.mjs --doc <doc> --changed. A render failure only
#      warns: the GO is already written.
#   5. GO: prints the leg message (GO <n> <head> and the merge command). The
#      script never sends it: SendMessage is the console's, and the leg's token
#      is quoted by the console in that message.
#
# A NO-GO runs steps 1 and 3 only. Without --doc steps 3 and 4 are skipped.
# An evidence line that leaves a residual unfiled (residual-lines.sh) is refused
# before step 1, exit 2, exactly as write-verdict.sh refuses it.
# Each step runs as a subprocess from this directory; none is modified here.
# The script stops at the first failure, names the step on stderr and exits
# with that step's own exit code (go.sh's 3, 4, 5 and write-verdict.sh's 2 to 5
# pass through unchanged). Its own usage errors exit 2, before anything runs.
#
# Run it as the console, from the checkout /pr-check wrote the ledger in (go.sh's
# ready-check reads the cwd), exactly where go.sh is run by hand.
#
# Platform guard: POSIX bash 3.2+; the console kit is Linux-only (needs node for the board).
# git-env-ok: the one git call is a read-only rev-parse whose path only fills a printed message; it decides nothing
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "usage: verdict-go.sh <qid> <GO|NO-GO> <head> --pr <n> --evidence-file <path> [--trust] [--leg <label>] [--doc <console doc>] [--prior <GO|NO-GO>]" >&2
    exit 2
}

[ "$#" -ge 3 ] || usage
QID="$1"; ANSWER="$2"; HEAD_SHA="$3"; shift 3
PR=""; EVIDENCE=""; TRUST=0; LEG=""; DOC=""; PRIOR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pr)            [ "$#" -ge 2 ] || usage; PR="$2"; shift 2 ;;
        --evidence-file) [ "$#" -ge 2 ] || usage; EVIDENCE="$2"; shift 2 ;;
        --leg)           [ "$#" -ge 2 ] || usage; LEG="$2"; shift 2 ;;
        --doc)           [ "$#" -ge 2 ] || usage; DOC="$2"; shift 2 ;;
        --prior)         [ "$#" -ge 2 ] || usage; PRIOR="$2"; shift 2 ;;
        --trust)         TRUST=1; shift ;;
        *)               usage ;;
    esac
done

case "$ANSWER" in GO|NO-GO) ;; *) echo "verdict-go: the answer must be GO or NO-GO (got '$ANSWER')" >&2; usage ;; esac
case "$PR" in ''|0*|*[!0123456789]*) echo "verdict-go: --pr <n> is required (digits, no leading zero)" >&2; usage ;; esac
[ -n "$EVIDENCE" ] || { echo "verdict-go: --evidence-file <path> is required" >&2; usage; }
case "$HEAD_SHA" in *[!0123456789abcdef]*) HEAD_OK=0 ;; *) HEAD_OK=1 ;; esac
if [ "$HEAD_OK" -ne 1 ] || [ "${#HEAD_SHA}" -ne 40 ]; then
    echo "verdict-go: head must be the full 40-char lowercase hex sha (got '$HEAD_SHA')" >&2
    usage
fi

# shellcheck source=scripts/handover/console-kit/residual-lines.sh
. "$HERE/residual-lines.sh"
if [ -r "$EVIDENCE" ]; then
    unfiled="$(unfiled_residual_section_lines "$EVIDENCE")"
    if [ -n "$unfiled" ]; then
        while IFS= read -r unfiled_line; do
            echo "verdict-go: unfiled residual: $unfiled_line" >&2
        done <<< "$unfiled"
        echo "verdict-go: file each residual (HIMMEL-<n> on the line) or mark it 'no-ticket: <reason>' - nothing ran" >&2
        exit 2
    fi
fi

step_fail() { # step_fail <script> <rc>
    echo "verdict-go: $1 failed (exit $2) - stopped; later steps did not run" >&2
    exit "$2"
}

bash "$HERE/write-verdict.sh" "$QID" "$ANSWER" "$HEAD_SHA" --pr "$PR" --evidence-file "$EVIDENCE" \
    ${PRIOR:+--prior "$PRIOR"} || step_fail write-verdict.sh $?

if [ "$ANSWER" = "GO" ]; then
    if [ "$TRUST" -eq 1 ]; then
        bash "$HERE/go.sh" --trust-reviewed "$QID" "$PR" "$HEAD_SHA" || step_fail go.sh $?
    else
        bash "$HERE/go.sh" "$PR" "$HEAD_SHA" || step_fail go.sh $?
    fi
fi

if [ -n "$DOC" ]; then
    bash "$HERE/append-results.sh" "$DOC" "$QID answer: $ANSWER · $ANSWER $PR ${HEAD_SHA:0:8}" \
        || step_fail append-results.sh $?
    if [ "$ANSWER" = "GO" ]; then
        node "$HERE/board.mjs" --doc "$DOC" --changed >/dev/null \
            || echo "verdict-go: board render failed (non-fatal; the GO is written)" >&2
    fi
fi

if [ "$ANSWER" = "GO" ]; then
    # The primary checkout holds the merge script the leg's allow rule names; a
    # worktree copy of this file still resolves it through the git common dir.
    ANCHOR="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    ANCHOR="${ANCHOR%/.git}"
    [ -n "$ANCHOR" ] || ANCHOR="$(cd "$HERE/../../.." && pwd)"
    echo
    echo "--- leg message (send to ${LEG:-the leg}; add its token) ---"
    printf 'GO %s %s - merge with: bash %q --jira-transition\n' "$PR" "$HEAD_SHA" "$ANCHOR/scripts/handover/merge-on-green.sh"
fi
exit 0
