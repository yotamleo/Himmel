#!/usr/bin/env bash
# scripts/glm/ship-branch.sh - push a reviewed glm branch from the TRUSTED main
# checkout (HIMMEL-750).
#
# The claude-down ship lane's push half. The GLM worker stays FULLY quarantined
# (poisonPushUrl + the worker no-push prompt + the external-writes deny hook are
# UNCHANGED); this script - run from the main checkout, which legitimately owns
# the attestation trailers and push credentials - performs the push AFTER
# pr-check-external.sh recorded external_cr_verdict:pass. A prior adversarial
# design review REJECTED giving the worker push authority (worker-writable grant
# ledger, unanchored push grant -> refspec-to-main smuggle, forged attestation);
# moving the push here keeps the worker with zero git-write authority.
#
# Authorization chain (ALL fail-closed, exit 2):
#   - branch must match glm/* (unless --allow-any-branch)
#   - must run from a real checkout with an origin remote, NOT a .claude/worktrees/ path
#   - external_cr_verdict must start "pass" in <session-dir>/meta.json
#   - the reviewed SHA in that verdict must equal the current branch tip (closes
#     the TOCTOU where commits are added after the panel)
# The normal pre-push gates (attestation, gitleaks) run here in a trusted
# context - correct, the pusher owns the attestations, so NO --no-verify.
# Merge stays operator-only: this NEVER opens a PR and NEVER merges.
#
# Usage: ship-branch.sh <branch> [--session-dir <dir>] [--base <ref>] [--allow-any-branch]
# bash 3.2-safe; node is the JSON tool the cr scripts already depend on.
# Exit: 0 = pushed; 1 = push failed; 2 = usage / authorization refusal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage: ship-branch.sh <branch> [--session-dir <dir>] [--base <ref>] [--allow-any-branch]

Pushes a reviewed glm/* branch from the trusted main checkout after
pr-check-external.sh recorded external_cr_verdict:pass. Never opens a PR or
merges. Fail-closed on every authorization check (exit 2).
EOF
}

BRANCH=""
SESSION_DIR=""
ALLOW_ANY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --session-dir)      [ $# -ge 2 ] || { echo "ship-branch: --session-dir needs an argument" >&2; exit 2; }; SESSION_DIR="$2"; shift 2 ;;
        --base)             [ $# -ge 2 ] || { echo "ship-branch: --base needs an argument" >&2; exit 2; }; shift 2 ;;  # reserved for signature parity; the base is not used by the push
        --allow-any-branch) ALLOW_ANY=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        -*)                 echo "ship-branch: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [ -z "$BRANCH" ]; then
                BRANCH="$1"
            else
                echo "ship-branch: unexpected extra arg: $1" >&2; usage >&2; exit 2
            fi
            shift ;;
    esac
done

[ -n "$BRANCH" ] || { echo "ship-branch: <branch> required" >&2; usage >&2; exit 2; }

# --- Authorization: branch scope (glm/* only unless widened) ----------------
case "$BRANCH" in
    glm/*) : ;;
    *)
        if [ "$ALLOW_ANY" -ne 1 ]; then
            echo "ship-branch: refusing non-glm branch '$BRANCH' (pass --allow-any-branch to override)" >&2
            exit 2
        fi ;;
esac

# --- Authorization: run from the main checkout, not a worker worktree -------
_in_worktree() { case "$1" in *".claude/worktrees/"*) return 0 ;; esac; return 1; }
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$toplevel" ] || { echo "ship-branch: not inside a git repository" >&2; exit 2; }
if _in_worktree "$toplevel" || _in_worktree "$PWD"; then
    echo "ship-branch: refusing to run from a .claude/worktrees/ path - ship FROM the main checkout, not a worker worktree" >&2
    exit 2
fi
if ! git remote get-url origin >/dev/null 2>&1; then
    echo "ship-branch: no 'origin' remote - must run from a real himmel checkout" >&2
    exit 2
fi

# --- Precondition 1: branch exists locally or on origin ---------------------
if ! git rev-parse --verify --quiet "$BRANCH" >/dev/null 2>&1 \
   && ! git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
    echo "ship-branch: branch '$BRANCH' not found locally or on origin" >&2
    exit 2
fi

# --- Precondition 2: external_cr_verdict:pass is the authorization -----------
[ -n "$SESSION_DIR" ] || { echo "ship-branch: --session-dir required (the external_cr_verdict is the ship authorization)" >&2; exit 2; }
META="$SESSION_DIR/meta.json"
[ -f "$META" ] || { echo "ship-branch: no meta.json at $META" >&2; exit 2; }
verdict="$(node -e 'const fs=require("fs");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(String(m.external_cr_verdict||""));' "$META" 2>/dev/null || true)"
case "$verdict" in
    pass*) : ;;
    *)
        echo "ship-branch: external_cr_verdict is not 'pass' (got: ${verdict:-<absent>}) - run pr-check-external.sh first" >&2
        exit 2 ;;
esac

# --- Precondition 3: reviewed SHA == current tip (closes the TOCTOU) ---------
verdict_sha="$(printf '%s' "$verdict" | sed -n 's/.*sha=\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p')"
[ -n "$verdict_sha" ] || { echo "ship-branch: no sha= in verdict '$verdict' - re-run pr-check-external.sh" >&2; exit 2; }
tip_full="$(git rev-parse "$BRANCH" 2>/dev/null || true)"
[ -n "$tip_full" ] || { echo "ship-branch: cannot resolve tip for $BRANCH" >&2; exit 2; }
tip_short="$(git rev-parse --short "$BRANCH" 2>/dev/null || echo "$tip_full")"
# verdict_sha is the reviewed FULL sha: it must EXACTLY equal the current tip.
# An authorization gate uses exact equality - a short-prefix match would let a
# commit grafted after the panel (accidentally, or ground to collide on the
# stored prefix) pass as reviewed (CR [codex-1]).
if [ "$verdict_sha" != "$tip_full" ]; then
    echo "ship-branch: branch tip $tip_short ($tip_full) != reviewed SHA $verdict_sha - unreviewed commits added after the panel; re-run pr-check-external.sh" >&2
    exit 2
fi

# --- Push (trusted context; pre-push gates run here; no --no-verify) ---------
echo "ship-branch: pushing $BRANCH ($tip_short) to origin (reviewed SHA $verdict_sha) ..." >&2
if ! git push -u origin "$BRANCH"; then
    echo "ship-branch: git push failed (pre-push gate / attestation trailers?) - not clearing marker" >&2
    exit 1
fi
pushed_sha="$tip_full"

# --- Clear the CR marker ONLY IF its SHA matches the pushed SHA --------------
git_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
marker_state="no (marker dir unresolved)"
if [ -n "$git_dir" ]; then
    case "$git_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;                 # already absolute (POSIX or Windows drive)
        *) git_dir="$(pwd)/$git_dir" ;;
    esac
    marker="${git_dir}/cr-pending/${BRANCH}"
    if [ -f "$marker" ]; then
        # Marker format (check-cr-before-push.sh): "<iso> | <full-sha> | <lane>".
        marker_sha="$(awk -F' [|] ' '{print $2; exit}' "$marker" 2>/dev/null || true)"
        if [ "$marker_sha" = "$pushed_sha" ]; then
            rm -f "$marker"
            marker_state="cleared (SHA bound to pushed tip)"
        else
            echo "ship-branch: marker SHA ($marker_sha) != pushed SHA ($pushed_sha) - leaving marker in place" >&2
            marker_state="retained (SHA mismatch)"
        fi
    else
        marker_state="no marker present"
    fi
fi

# Suggest the exact next command; merge stays operator-only.
default_base="main"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    default_base="$(default_branch 2>/dev/null || echo main)"
fi

echo "ship-branch: pushed $BRANCH @ $tip_short (full $pushed_sha)"
echo "ship-branch: CR marker: $marker_state"
echo "ship-branch: NEXT (operator-only) - open the PR with:"
# %q emits a shell-safe token: a branch name carrying ANY shell metacharacter,
# including an embedded single quote (only reachable via --allow-any-branch;
# real glm/<slug> names are sanitized to [a-zA-Z0-9-] by spawn-glm), cannot
# inject when the operator copy-pastes this line. Hand-built single-quoting does
# not survive an embedded ' - use the printf primitive instead (CR [codex-1/2]).
# tip_short is a hex short-sha (always safe) so %s is fine for it.
printf "  gh pr create --head %q --base %q --title '<title>' --body 'external_cr_verdict: pass (%s)'\n" "$BRANCH" "$default_base" "$tip_short"
exit 0
