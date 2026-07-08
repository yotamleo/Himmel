#!/usr/bin/env bash
# scripts/copilot/dispatch-copilot.sh - the copilot-cli lane's dispatch
# chokepoint (HIMMEL-772, mirrors the codex chokepoint HIMMEL-781/#1001).
#
# WHY: copilot-cli has permission flags only - no PreToolUse hook surface
# like Claude Code, no hooks.json adapter like codex (HIMMEL-427). Per the
# enforcement doctrine (structural > instructional, HIMMEL-195) it cannot
# route ANY work until a wrapper supplies the missing structure. This script
# IS that structure: the ONLY sanctioned entry point for the copilot-cli free
# lane (lanes.json names it). It:
#   1. Refuses dispatch outside a physical .claude/worktrees/<wt> path
#      (pwd -P, the same containment rule as the codex/GLM chokepoints - a
#      symlink/junction can satisfy a string check while its physical target
#      lives elsewhere).
#   2. ALLOW-LISTS the caller's dash-flags (task-shaping only: -p/--prompt,
#      --model/-m, --print-timeout/--timeout) - deny-listing a CLI's flag
#      surface was proven unwinnable on the codex lane (8 adversarial-CR
#      rounds, #1001); everything else dash-prefixed is refused.
#   3. Composes the permission grants itself (the caller never passes
#      --allow-tool/--deny-*/--add-dir/-c - those are refused by name): a
#      scoped default (--allow-tool 'shell(git:*)' --allow-tool 'write',
#      --deny-url '*', --add-dir <worktree>), with a guarded --allow-all-tools
#      fallback (COPILOT_ALLOW_ALL_FALLBACK=1, off by default) for the case
#      where copilot's headless mode refuses the granular grants (design
#      open question - verify in a live smoke, not here).
#   4. Pins --model auto unless the caller names one (free-bank chores; the
#      full model catalog likely burns the same 2,000-completion bank faster
#      and duplicates paid lanes we already have).
#   5. Egress: himmel-code-only BY CONSTRUCTION. copilot has no declared
#      egress-matrix provider cell (scripts/guardrails/egress-matrix.json) -
#      the preflight here is a containment+class assertion, not a matrix-eval
#      call: a dispatch only ever runs inside a himmel worktree (step 1), and
#      a worktree is always himmel-code corpus. If a future non-code corpus
#      is ever exposed to this lane, that needs a matrix cell first.
#   6. Appends a JSONL line per dispatch to a per-lane ledger (quota
#      visibility - the free banks are the whole point; an invisible bank is
#      an exhausted bank. A failed append WARNs, it is not a security gate).
#
# Usage:
#   dispatch-copilot.sh --worktree <path> [copilot task args...]
#
# Environment:
#   COPILOT_BIN                 Override the copilot CLI (tests inject a stub).
#   COPILOT_LEDGER               Override the ledger path (tests; default
#                                 $HOME/.claude/copilot-dispatch.jsonl).
#   COPILOT_ALLOW_ALL_FALLBACK   1 = swap the granular grants for
#                                 --allow-all-tools (still --add-dir only, no
#                                 --allow-all-paths). Off by default.
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

COPILOT="${COPILOT_BIN:-copilot}"
LEDGER="${COPILOT_LEDGER:-$HOME/.claude/copilot-dispatch.jsonl}"

usage() {
    echo "usage: dispatch-copilot.sh --worktree <path> [copilot task args...]" >&2
    exit 2
}

WORKTREE=""
if [ "${1:-}" = "--worktree" ]; then
    [ -n "${2:-}" ] || usage
    WORKTREE="$2"
    shift 2
fi
[ -n "$WORKTREE" ] || usage
[ -d "$WORKTREE" ] || { echo "dispatch-copilot.sh: worktree not found: $WORKTREE" >&2; exit 2; }

# Physical-path containment (pwd -P): a symlink/junction placed under
# .claude/worktrees could satisfy a string check while its physical target
# lives outside it (the codex-adv final-round lesson, #1001).
WT_ABS="$(cd "$WORKTREE" 2>/dev/null && pwd -P)" || { echo "dispatch-copilot.sh: cannot resolve worktree: $WORKTREE" >&2; exit 2; }
case "$WT_ABS" in
    */.claude/worktrees/*) ;;
    *) echo "dispatch-copilot.sh: refusing worktree outside .claude/worktrees: $WT_ABS (the lane dispatches only into repo worktrees)" >&2; exit 2 ;;
esac
WORKTREE="$WT_ABS"

# ALLOW-LIST (never a deny-list - the codex convergence lesson, HIMMEL-781):
# specific BANNED flags get their own actionable message BEFORE the generic
# dash catch-all. Positional (non-dash) task args pass through untouched.
have_model=0
model_field="auto"
prev=""
for a in "$@"; do
    case "$prev" in
        --model|-m) model_field="$a" ;;
    esac
    case "$a" in
        --allow-all-tools|--allow-all-tools=*) echo "dispatch-copilot.sh: --allow-all-tools refused - the wrapper composes granular grants (set COPILOT_ALLOW_ALL_FALLBACK=1 for the guarded fallback)" >&2; exit 2 ;;
        --allow-all|--allow-all=*) echo "dispatch-copilot.sh: --allow-all refused - the wrapper composes granular grants" >&2; exit 2 ;;
        --allow-all-paths|--allow-all-paths=*) echo "dispatch-copilot.sh: --allow-all-paths refused - containment is --add-dir only" >&2; exit 2 ;;
        --allow-all-urls|--allow-all-urls=*) echo "dispatch-copilot.sh: --allow-all-urls refused - the lane guard denies network egress by default" >&2; exit 2 ;;
        --yolo|--yolo=*) echo "dispatch-copilot.sh: --yolo refused - the lane guard requires the composed permission grants" >&2; exit 2 ;;
        --no-ask-user|--no-ask-user=*) echo "dispatch-copilot.sh: --no-ask-user refused - the lane guard requires the composed permission grants" >&2; exit 2 ;;
        --allow-tool|--allow-tool=*) echo "dispatch-copilot.sh: --allow-tool refused - the caller must not pass permission args, the wrapper composes the tool grant set" >&2; exit 2 ;;
        --deny-tool|--deny-tool=*|--deny-url|--deny-url=*) echo "dispatch-copilot.sh: $a refused - the caller must not pass permission args, the wrapper composes the deny set" >&2; exit 2 ;;
        --add-dir|--add-dir=*) echo "dispatch-copilot.sh: --add-dir refused - the wrapper owns the worktree dir grant" >&2; exit 2 ;;
        -c|-c=*|-c?*|--config|--config=*) echo "dispatch-copilot.sh: $a refused - config overrides can widen permissions past the lane guard" >&2; exit 2 ;;
        --allow-*|--deny-*) echo "dispatch-copilot.sh: $a refused - permission flag not in the lane allow-list, the wrapper composes all permission args" >&2; exit 2 ;;
        -p|--prompt|-p?*|--prompt=*) ;;  # the prompt - allowed
        --model|--model=*|-m|-m?*)
            have_model=1
            case "$a" in
                --model=*) model_field="${a#*=}" ;;
                -m?*) model_field="${a#-m}" ;;
            esac
            ;;
        --print-timeout|--timeout|--print-timeout=*|--timeout=*) ;;  # caller-supplied run bound - allowed
        -*) echo "dispatch-copilot.sh: flag '$a' is not in the lane allow-list (-p/--prompt, --model/-m, --print-timeout/--timeout) - refused" >&2; exit 2 ;;
    esac
    prev="$a"
done

# The copilot CLI must resolve before the tail exec (a bare bash "not found"
# line would not name the COPILOT_BIN override).
if ! command -v "$COPILOT" >/dev/null 2>&1; then
    echo "dispatch-copilot.sh: copilot CLI not found: $COPILOT (install it or set COPILOT_BIN)" >&2
    exit 127
fi

# The worktree can vanish between the -d check and here - name that failure
# distinctly from every other exit-2 refusal above.
if ! cd "$WORKTREE"; then
    echo "dispatch-copilot.sh: worktree vanished before dispatch: $WORKTREE" >&2
    exit 1
fi

# Permission COMPOSITION: the wrapper grants, never the caller. Built as an
# array (not a word-split string) so a worktree path containing spaces still
# reaches --add-dir intact.
allow_all_fallback=0
grant_args=(--add-dir "$WORKTREE" --deny-url "*")
if [ "${COPILOT_ALLOW_ALL_FALLBACK:-0}" = "1" ]; then
    allow_all_fallback=1
    echo "dispatch-copilot.sh: WARN COPILOT_ALLOW_ALL_FALLBACK=1 - granting --allow-all-tools (reduced containment: --add-dir only, no --allow-all-paths)" >&2
    grant_args+=(--allow-all-tools)
else
    grant_args+=(--allow-tool "shell(git:*)" --allow-tool "write")
fi

# Model pin: free-bank chores pin auto unless the caller named one explicitly.
model_args=()
if [ "$have_model" -eq 1 ]; then
    echo "dispatch-copilot.sh: WARN caller-named model overrides the auto pin (free-bank chores pin --model auto)" >&2
else
    model_args=(--model auto)
fi

# Ledger: visibility aid, not a security gate - a failed append WARNs only.
LEDGER_DIR="$(dirname "$LEDGER")"
if mkdir -p "$LEDGER_DIR" 2>/dev/null; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fallback_json="false"
    [ "$allow_all_fallback" -eq 1 ] && fallback_json="true"
    # model_field is caller-controlled (--model/-m) - escape before it lands
    # in JSONL (a bare quote or newline would emit a malformed ledger line).
    model_json="$model_field"
    model_json="${model_json//\\/\\\\}"
    model_json="${model_json//\"/\\\"}"
    model_json="${model_json//$'\n'/\\n}"
    model_json="${model_json//$'\r'/\\r}"
    model_json="${model_json//$'\t'/\\t}"
    if ! printf '{"ts":"%s","worktree":"%s","model":"%s","allow_all_fallback":%s}\n' \
        "$ts" "$WORKTREE" "$model_json" "$fallback_json" >> "$LEDGER" 2>/dev/null; then
        echo "dispatch-copilot.sh: WARN ledger append failed: $LEDGER (visibility only, dispatch continues)" >&2
    fi
else
    echo "dispatch-copilot.sh: WARN cannot create ledger dir: $LEDGER_DIR (visibility only, dispatch continues)" >&2
fi

exec "$COPILOT" "${grant_args[@]+"${grant_args[@]}"}" "${model_args[@]+"${model_args[@]}"}" "$@"
