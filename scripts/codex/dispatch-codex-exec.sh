#!/usr/bin/env bash
# scripts/codex/dispatch-codex-exec.sh - the codex-exec lane's dispatch
# chokepoint (HIMMEL-781, follow-up to the HIMMEL-741 diagnosis).
#
# WHY: the lane's safety requirements must be structural, not prose (the
# lanes.json row alone cannot enforce them). This wrapper encodes the
# HIMMEL-741 invariants at the single entry point (arg checks run first,
# then the preflight, then codex - nothing reaches codex unchecked):
#   1. ACL preflight: normalize-worktree-acl.sh <worktree> runs before the
#      codex CLI is invoked and aborts the dispatch on failure (Windows
#      aged-worktree SID gap; the preflight is a no-op on other platforms).
#   2. Model pinned to gpt-5.5 unless the caller names one explicitly
#      (codex-variant model names 400 under ChatGPT-plan auth).
#   3. --background refused (upstream: background jobs die silently; use the
#      default --wait behavior + scripts/codex/companion-liveness.sh).
#   4. Workspace-redirect (-C/--cd/--add-dir) and sandbox-widening flags
#      refused - the preflight covers only the dispatched worktree.
#
# Usage:
#   dispatch-codex-exec.sh --worktree <path> [codex exec args...]
#
# Environment:
#   CODEX_BIN            Override the codex CLI (tests inject a stub).
#   CODEX_ACL_NORMALIZE  Override the preflight script path (tests).
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="${CODEX_ACL_NORMALIZE:-$SCRIPT_DIR/normalize-worktree-acl.sh}"
CODEX="${CODEX_BIN:-codex}"

usage() {
    echo "usage: dispatch-codex-exec.sh --worktree <path> [codex exec args...]" >&2
    exit 2
}

WORKTREE=""
if [ "${1:-}" = "--worktree" ]; then
    [ -n "${2:-}" ] || usage
    WORKTREE="$2"
    shift 2
fi
[ -n "$WORKTREE" ] || usage
[ -d "$WORKTREE" ] || { echo "dispatch-codex-exec.sh: worktree not found: $WORKTREE" >&2; exit 2; }

# codex-adv r5: an arbitrary existing directory must not become a
# workspace-write codex workspace (the ACL preflight no-ops off-Windows, so it
# is not the path constraint). Canonicalize and require a .claude/worktrees
# path - the same containment rule normalize-worktree-acl.ps1 enforces.
# pwd -P (codex-adv final round): logical pwd would let a symlink/junction
# placed under .claude/worktrees satisfy the string check while the physical
# target lives outside it. Dispatch uses the PHYSICAL path too.
WT_ABS="$(cd "$WORKTREE" 2>/dev/null && pwd -P)" || { echo "dispatch-codex-exec.sh: cannot resolve worktree: $WORKTREE" >&2; exit 2; }
case "$WT_ABS" in
    */.claude/worktrees/*) ;;
    *) echo "dispatch-codex-exec.sh: refusing worktree outside .claude/worktrees: $WT_ABS (the lane dispatches only into repo worktrees)" >&2; exit 2 ;;
esac
WORKTREE="$WT_ABS"

# codex-adv r5/r6: 'codex exec resume' (esp. resume --all) selects sessions
# ACROSS cwds - it can route work into state outside the preflighted
# worktree. Codex accepts options BEFORE the subcommand token (e.g.
# '--json resume --all'), so a first-arg check is bypassable: refuse the
# bare tokens anywhere in the passthrough. (A prompt that is literally the
# single word 'resume'/'review' is refused too - pass a real sentence.)
for a in "$@"; do
    case "$a" in
        resume|review) echo "dispatch-codex-exec.sh: 'codex exec $a' refused - the lane dispatches fresh runs only (resume/review can escape the preflighted worktree)" >&2; exit 2 ;;
    esac
done

# Invariant 3: refuse --background anywhere in the passthrough args.
# Invariant 4 (codex-adv CR round 2): refuse workspace-redirect and
# sandbox-widening flags - otherwise a caller can point codex at a directory
# the ACL preflight never touched (-C/--cd/--add-dir) or drop the sandbox
# entirely, defeating the lane guard this wrapper exists to enforce.
have_model=0
have_sandbox=0
prev=""
for a in "$@"; do
    case "$prev" in
        --sandbox|-s)
            case "$a" in
                danger-full-access) echo "dispatch-codex-exec.sh: '$prev danger-full-access' refused - the lane guard requires a sandboxed run" >&2; exit 2 ;;
            esac
            ;;
    esac
    # ALLOW-LIST (codex-adv final round): deny-listing clap's option surface
    # is unwinnable (attached short forms, --enable/--disable feature flags
    # that rewrite config, future flags). Specific deny cases stay for their
    # actionable messages; EVERYTHING ELSE dash-prefixed is refused by the
    # catch-all. Allowed: --model/-m (all forms), --sandbox/-s with a
    # non-danger value (all forms), --json, and positional prompt words.
    case "$a" in
        --background|--background=*) echo "dispatch-codex-exec.sh: --background refused (upstream silent-death, HIMMEL-741) - use the default wait behavior + companion-liveness.sh" >&2; exit 2 ;;
        -C*|--cd|--cd=*) echo "dispatch-codex-exec.sh: workspace-redirect flag '$a' refused - the wrapper owns the worktree (pass it via --worktree)" >&2; exit 2 ;;
        --add-dir|--add-dir=*) echo "dispatch-codex-exec.sh: --add-dir refused - the ACL preflight covers only the dispatched worktree" >&2; exit 2 ;;
        --dangerously-bypass-approvals-and-sandbox|--yolo) echo "dispatch-codex-exec.sh: sandbox-bypass flag '$a' refused - the lane guard requires a sandboxed run" >&2; exit 2 ;;
        --sandbox=danger-full-access|-s=danger-full-access|-sdanger-full-access) echo "dispatch-codex-exec.sh: sandbox danger-full-access refused - the lane guard requires a sandboxed run" >&2; exit 2 ;;
        -c*|--config|--config=*) echo "dispatch-codex-exec.sh: config-override flag '$a' refused - -c/--config can widen sandbox_permissions past the lane guard" >&2; exit 2 ;;
        -p*|--profile|--profile=*) echo "dispatch-codex-exec.sh: profile flag '$a' refused - a config profile can widen the sandbox past the lane guard" >&2; exit 2 ;;
        --dangerously-bypass-hook-trust|--ignore-rules) echo "dispatch-codex-exec.sh: trust-bypass flag '$a' refused - the lane guard does not vet hook sources or waive execpolicy rules" >&2; exit 2 ;;
        --enable|--enable=*|--disable|--disable=*) echo "dispatch-codex-exec.sh: feature flag '$a' refused - config-equivalent (can disable the hooks feature past the lane guard)" >&2; exit 2 ;;
        -o*|--output-last-message|--output-last-message=*) echo "dispatch-codex-exec.sh: output-file flag '$a' refused - a CLI-level write to a caller-supplied path can escape the worktree" >&2; exit 2 ;;
        --model|--model=*|-m|-m?*) have_model=1 ;;
        --sandbox|--sandbox=*|-s|-s=*|-s?*) have_sandbox=1 ;;
        --json) ;;  # structured output - inert
        -*) echo "dispatch-codex-exec.sh: flag '$a' is not in the lane allow-list (--model/-m, --sandbox/-s safe values, --json) - refused" >&2; exit 2 ;;
    esac
    prev="$a"
done

# Invariant 1: ACL preflight, fail-closed.
if ! bash "$NORMALIZE" "$WORKTREE"; then
    echo "dispatch-codex-exec.sh: ACL preflight failed for $WORKTREE - dispatch aborted (manual recovery: bash scripts/codex/normalize-worktree-acl.sh <worktree>)" >&2
    exit 1
fi

# The codex CLI must resolve before the tail exec (a bare bash "not found"
# line would not name the CODEX_BIN override; CR round-3 finding).
if ! command -v "$CODEX" >/dev/null 2>&1; then
    echo "dispatch-codex-exec.sh: codex CLI not found: $CODEX (install it or set CODEX_BIN)" >&2
    exit 127
fi

# The worktree can vanish between the -d check and here (the preflight takes
# real wall-clock) - name that failure distinctly from a preflight abort.
if ! cd "$WORKTREE"; then
    echo "dispatch-codex-exec.sh: worktree vanished before dispatch: $WORKTREE" >&2
    exit 1
fi

# Invariant 2: pin gpt-5.5 unless the caller named a model explicitly.
# Sandbox pin (codex-adv r4): ambient $CODEX_HOME/config.toml can default the
# sandbox to danger-full-access - always pass an EXPLICIT safe --sandbox when
# the caller did not name one, so ambient config cannot widen the run.
pin_args=""
if [ "$have_model" -eq 1 ]; then
    echo "dispatch-codex-exec.sh: WARN caller-named model overrides the gpt-5.5 pin (codex-variant names 400 on ChatGPT auth)" >&2
else
    pin_args="--model gpt-5.5"
fi
if [ "$have_sandbox" -eq 0 ]; then
    pin_args="$pin_args --sandbox workspace-write"
fi
# shellcheck disable=SC2086  # pin_args is a fixed, space-safe flag list built above
exec "$CODEX" exec $pin_args "$@"
