#!/usr/bin/env bash
# Pre-push hook: refuse to push when the open PR for the current branch
# has mergeable: CONFLICTING (HIMMEL-136).
#
# Pre-commit framework wires this into the pre-push stage. Stdin
# contract: "local_ref local_sha remote_ref remote_sha" per line — same
# as check-push-target.sh.
#
# Behavior:
# - Drains stdin so the pre-commit framework doesn't deadlock when the
#   push contains many refs.
# - Resolves the current branch via `git symbolic-ref HEAD`.
# - Skips on a protected default (main OR master — HIMMEL-297) / detached
#   HEAD (no PR ever opens for the default branch; detached pushes have no
#   head ref to query).
# - Asks forge_pr_mergeable for the branch's open PR. On GitHub that now
#   computes the conflict LOCALLY via `git merge-tree` (HIMMEL-1232) rather
#   than reading GitHub's flaky async `mergeable` field. When no PR exists,
#   exits 0 (nothing to gate on).
# - Refuses (exit 1) when the verdict is `CONFLICTING`, UNLESS it is provably
#   stale (HIMMEL-1074): the base is an ancestor of the local head AND the
#   pushed tree has no conflict markers — i.e. the operator already merged the
#   advanced base in and resolved cleanly, so the verdict (computed against the
#   stale remote head) no longer reflects the push. The refusal message names
#   the sanctioned recovery. See the CONFLICTING branch for the full rationale.
# - Falls back to exit 0 (best-effort) when gh CLI is missing or
#   unauthenticated — a hard refuse would block pushes whenever the
#   operator works offline.
#
# Bypass: SKIP_PR_MERGEABLE=1 git push ... (logs WARNING).
#
# HIMMEL-326: routes through the forge seam (scripts/lib/forge.sh), so it gates
# GitHub and Bitbucket Cloud. On Bitbucket forge_pr_mergeable always returns
# UNKNOWN (no pre-merge mergeable signal — spec §5.1), so this hook never blocks
# a Bitbucket push; the conflict surfaces at merge time instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"

# Drain stdin first so pre-commit doesn't deadlock when push touches
# many refs. We don't actually need stdin content for the mergeable
# check — it's branch-scoped.
while read -r _line; do :; done

if [ "${SKIP_PR_MERGEABLE:-0}" = "1" ]; then
    echo "→ pr-mergeable: SKIP_PR_MERGEABLE=1 — skipping (WARNING: confirm gh pr view --json mergeable is not CONFLICTING before merging)" >&2
    exit 0
fi

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    exit 0
fi

# Determine the forge; without an origin we can't gate — skip best-effort.
if ! forge_detect >/dev/null 2>&1; then
    echo "→ pr-mergeable: cannot determine forge (no github/bitbucket origin) — skipping (best-effort)" >&2
    exit 0
fi

# Best-effort: a hard refuse would block pushes whenever the operator works
# offline or the forge CLI is missing / unauthenticated.
if ! forge_auth_status 2>/dev/null; then
    echo "→ pr-mergeable: forge CLI missing or unauthenticated — skipping (best-effort)" >&2
    exit 0
fi

# Query mergeability for this branch's open PR. forge_pr_mergeable accepts a
# branch ref (the github backend's `gh pr view <branch>` resolves it) and prints
# MERGEABLE / CONFLICTING / UNKNOWN, or empty when no PR exists.
mergeable=$(forge_pr_mergeable "$branch" 2>/dev/null || true)

if [ -z "$mergeable" ] || [ "$mergeable" = "null" ]; then
    # No PR for this branch — nothing to gate on. The pr-open step
    # will create one on the next push.
    exit 0
fi

case "$mergeable" in
    CONFLICTING)
        # Only GitHub yields CONFLICTING here — Bitbucket's
        # forge_pr_mergeable is hardcoded UNKNOWN (spec §5.1) — so the base
        # read and the recovery hints below stay gh-flavored.
        #
        # HIMMEL-1074 — a CONFLICTING verdict can be STALE. forge_pr_mergeable
        # computes it as `git merge-tree <base> <remote-head>` against the PR's
        # headRefOid: the commit ALREADY on the remote, NOT the local head
        # being pushed. When the base advanced under the PR and the operator
        # resolved the conflict locally (merging the new base in), the verdict
        # still describes the OLD remote head — so the push that would land the
        # resolution is refused. The gate blocked its own recovery path.
        #
        # Carve-out: allow the push when we can prove LOCALLY the verdict is
        # stale — the base is an ANCESTOR of the local head (the operator
        # merged it in) AND the pushed tree carries no leftover conflict
        # markers (the merge was resolved, not left half-done). Both are local,
        # verifiable facts. If either is inconclusive, REFUSE — a genuinely
        # conflicted tree must never be waved through, and inconclusive
        # evidence defaults to the safe refusal. No new bypass; the carve-out
        # is evidence-gated, not flag-gated.
        base=$(_gh pr view "$branch" --json baseRefName \
                 --jq '.baseRefName' 2>/dev/null || true)
        stale_ok=0
        # HIMMEL-1074 CR round: `origin/$base` is a LOCALLY CACHED
        # remote-tracking ref — if it wasn't fetched since the real base
        # advanced further, the ancestor check below could pass against a
        # stale cached base while the CURRENT remote base still genuinely
        # conflicts, incorrectly allowing the push on outdated local state.
        # Refresh it first. The push itself already requires network
        # reachability to origin, so this adds no new requirement; a failed
        # fetch is itself inconclusive evidence and falls through to the
        # refuse path below (fail-closed), same as an unresolved base name.
        if [ -n "$base" ]; then
            git fetch origin "$base" >/dev/null 2>&1 || base=""
        fi
        if [ -n "$base" ] \
           && git merge-base --is-ancestor "origin/$base" HEAD >/dev/null 2>&1; then
            # The base is merged into the local head — the CONFLICTING verdict
            # (computed against the stale remote head) is stale by construction.
            # Guard against a botched resolution that left conflict markers in
            # the pushed files.
            #
            # CONFLICT-MARKER HEURISTIC (limitation documented, NOT exact):
            # scoped to the push's own diff — `git diff origin/<base>...HEAD`
            # (only what this push introduces). Flagged only when BOTH the
            # `<<<<<<<` start AND the `>>>>>>>` end delimiter appear as added
            # lines: a real unresolved conflict always has both, while a
            # doc/fixture illustrating a single marker typically does not, so a
            # legitimate push is not blocked by an isolated marker in a code
            # fence. A file that legitimately pairs the delimiters (e.g. a
            # fixture for a conflict-marker parser) WOULD trip this and fall
            # back to the refuse-with-recovery path below — the safe direction,
            # never a silent allow. The ancestor check above is the conclusive
            # evidence; this guard only tightens it. It runs ONLY in the
            # CONFLICTING path, so a MERGEABLE PR carrying such a fixture is
            # never inspected. Here-strings (not printf|grep) avoid the
            # pipefail/SIGPIPE trap (HIMMEL-1430).
            # HIMMEL-1074 CR round: `2>/dev/null || true` alone would swallow a
            # genuine `git diff` failure into an empty string — no markers found
            # in empty output reads as "clean" and stale_ok=1, allowing the push
            # on INCONCLUSIVE evidence (the diff never actually ran). Capture the
            # exit status explicitly so a failed diff falls through to refuse,
            # matching the documented fail-closed contract above.
            diff_rc=0
            push_diff=$(git diff "origin/$base...HEAD" 2>/dev/null) || diff_rc=$?
            if [ "$diff_rc" -eq 0 ] \
               && ! { grep -qE '^\+<<<<<<< ' <<< "$push_diff" \
                      && grep -qE '^\+>>>>>>> ' <<< "$push_diff"; }; then
                stale_ok=1
            fi
        fi

        if [ "$stale_ok" = "1" ]; then
            echo "→ pr-mergeable: PR for '$branch' reads CONFLICTING, but the verdict is provably stale — origin/$base is an ancestor of HEAD and the pushed tree has no conflict markers. Allowing the push." >&2
            exit 0
        fi

        # Refuse: the verdict is current (base not yet merged in) or the
        # evidence was inconclusive (no base / unresolvable origin/<base> /
        # leftover markers). Lead with the sanctioned recovery so the flow is
        # a documented one-liner rather than an operator interrupt.
        cat >&2 <<EOF
ERROR: the open PR for branch '$branch' is in CONFLICTING state.

       The verdict is computed against the remote head already on the server,
       so the ONLY way to clear a genuine conflict is to resolve it locally and
       push the resolution — this gate runs on exactly that push.

       Sanctioned recovery (clears a genuine conflict; also unblocks a stale one):
         git fetch origin
         git merge origin/${base:-main}   # or rebase onto it; resolve conflicts
         git push                         # origin/${base:-main} is now an ancestor of HEAD

       Inspect:  gh pr view $branch --json mergeable,mergeStateStatus
       Bypass:   SKIP_PR_MERGEABLE=1 git push ...   (operator-set; denied in auto-mode)
EOF
        exit 1
        ;;
    MERGEABLE|UNKNOWN|*)
        # MERGEABLE: clearly OK. UNKNOWN: a tooling gap (git < 2.38, base/head
        # refs unavailable — GitHub) or no pre-merge signal (Bitbucket). Let it
        # through best-effort — the merge gate (scripts/handover/pr-merge.sh)
        # runs the same local check again and blocks at merge time if it is
        # actually conflicting. Anything else: be lenient.
        exit 0
        ;;
esac
