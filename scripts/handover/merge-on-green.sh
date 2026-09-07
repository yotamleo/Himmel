#!/usr/bin/env bash
# handover/merge-on-green.sh — sanctioned auto-merge chokepoint for armed chains.
#
# HIMMEL-1042. Armed/overnight chains build each ticket to a green, CR-clean PR
# and STOP: the merge action the `merge` leg runs itself hits the Opus auto-mode
# classifier ("Merge Without Review") and is denied. arm-resume does NOT relaunch
# with --dangerously-skip-permissions (that would turn off ALL guards), so the
# chain never merges.
#
# This is the narrow, self-gating merge path the operator authorizes via ONE
# specific standing allow-rule — `Bash(bash scripts/handover/merge-on-green.sh:*)`
# — never a raw `gh pr merge` (still classifier-blocked) and never a permission
# widening. It merges ONLY on: opt-in (ARMAUTOMERGE=1) AND a PRIVATE github repo
# AND the PR targets that repo's DEFAULT branch (HIMMEL-1080, coderabbit public
# round: repo-bound alone still let it merge a PR against ANY base, even though
# inject-initiative.sh documents the scope as "squash-merge to PRIVATE main")
# AND check-ci.sh exit 0 (all checks green + all review threads resolved + no
# review requesting changes) AND the certified head SHA is still the PR head at
# merge time (`--match-head-commit`). Public propagation stays operator/bridge.
#
# The base-branch binding is RE-VERIFIED immediately before merging, after the
# check-ci gate (HIMMEL-1080 CR round-1, codex-adv): check-ci.sh watches CI to
# green and can block for minutes, and GitHub allows retargeting a PR's base
# (`gh pr edit --base`) WITHOUT moving its head SHA — so a base checked once,
# early, can go stale during that window, and `--match-head-commit` alone would
# not catch it (it only pins the HEAD). A fresh base/default-branch read that
# disagrees with the certified base fails closed, same as the first check.
#
# RESIDUAL, tracked as HIMMEL-1105 (codex-adv round-2): the re-verification and
# the `gh pr merge` are two separate API calls, so a retarget landing in the
# gap between them still slips through. That window is IRREDUCIBLE client-side
# — `gh pr merge` pins the head (`--match-head-commit`) but offers no
# `--match-base-ref`, so some network round-trip always separates the last read
# from the merge. What the re-verify above buys is the SIZE of the window:
# minutes (a check-ci CI watch) -> one round-trip. Closing the remainder needs
# enforcement at the GitHub merge boundary itself (a repository ruleset or a
# merge queue) — server-side and outside this agent-writable worktree, which is
# also what HIMMEL-1056 wants for this same lever. Not reordering the local
# audit I/O below to shave it further: those are two local file writes against
# a network round-trip, and the MERGING record is deliberately written BEFORE
# the merge so a crash still leaves a durable trace.
#
# The PreToolUse block-unresolved-cr-merge hook fires on the AGENT's Bash call
# (this script), not on the `gh pr merge` this script spawns as a subprocess —
# by design: this wrapper IS the sanctioned gated path and embeds the same
# (stronger, because it WATCHES) predicates via check-ci.sh.
#
# Usage: merge-on-green.sh [<pr-selector>] [--dry-run]
#   selector   optional PR number / branch / url; defaults to the current branch
#   --dry-run  run every gate, print the intended merge, then STOP (no merge)
#
# After a CONFIRMED merge it best-effort prunes the local worktree checked out
# on the PR's head branch (HIMMEL-1970) — plain `git worktree remove`, never
# --force; a dirty, locked, tip-moved or own-cwd tree is reported and kept, and
# an IN-USE tree (a live process holding it, HIMMEL-2227) is now detected up
# front and skipped rather than let git's non-atomic-on-Windows remove gut it —
# a remove that still fails part-way through is reported as `gutted`, never as
# "kept". The outcome rides the MERGED audit line as
# `prune=<outcome> branch=<outcome>` and NEVER changes the exit code.
#
# It also clears the branch's pending CR marker through the sanctioned
# chokepoint `scripts/cr/clear-cr-marker.sh` (HIMMEL-1346) — never a raw `rm`,
# so the ledger/CI gates still decide. Timing is forced: the clear runs right
# after the check-ci gate and BEFORE the merge, because after a squash merge the
# evidence the chokepoint needs is gone — GitHub's deleteBranchOnMerge removes
# the remote head branch, and clear-cr-marker's marker-endpoint binding then
# refuses (exit 16) for every merged branch. At this point the PR is open at the
# certified sha and check-ci is green, i.e. exactly the state that certifies a
# clear; and clear-cr-marker re-validates the branch tip + marker itself, so a
# push racing this window makes it refuse rather than clear something unproven.
# Best-effort for the exit code (an unclearable marker must not block a green
# merge) but LOUD: the outcome rides the MERGED audit line as
# `marker=<cleared|absent|clear-rc=N>`. It also sits BEFORE the base/privacy
# re-verification, which must stay the last thing before `gh pr merge` — so a
# gate that refuses after it (a retarget caught by 3b, a failing merge) leaves
# an already-cleared marker. That is accepted, not overlooked: the clear was
# certified on its own evidence, and the marker gates `gh pr create` for a PR
# that by then already exists; the next push re-mints it.
#
# Exit codes:
#   0   merged (including a confirmed remote merge where gh itself exited
#       non-zero afterwards, and regardless of the post-merge prune outcome),
#       or --dry-run passed, or no PR — nothing to merge
#   10  not opted in (ARMAUTOMERGE unset/false) — refused
#   11  required tool missing (gh / git)
#   12  not a private github repo (public or undeterminable), or the PR's base
#       branch is not the repo's default branch (undeterminable counts too) —
#       refused fail-closed. Also returned by the pre-merge re-verification of
#       the same binding (see above) if the base changed after the gate.
#   13  cannot resolve the PR, its head SHA, or a well-formed metadata line
#       (six pipe-joined fields incl. the head branch) — refused
#   14  check-ci gate not green (unresolved threads / red CI / changes requested)
#   15  merge failed (gh error, incl. a --match-head-commit head-moved abort, a
#       branch-delete error where the PR did NOT reach MERGED, an indeterminate
#       post-merge PR-state query, a MERGED state whose head does not match the
#       certified sha (a different commit merged concurrently — either after
#       gh's own merge call failed, or while a gh-accepted merge sat queued), a
#       MERGED state at the certified sha but a different base (a concurrent
#       retarget — same two windows), or a gh-accepted merge the PR never
#       confirmed as MERGED). Also an INDETERMINATE outcome: a gh FAILURE whose
#       PR was still OPEN through the bounded confirmation poll (HIMMEL-1697 —
#       a merge accepted server-side but reported as failed can still land, so
#       an unproven outcome is reported as pending-unconfirmed, never REFUSED)
#   16  audit sink not writable, or the MERGING record could not be written —
#       refused (an unauditable merge must not proceed)
#
# Environment:
#   ARMAUTOMERGE           Must be truthy (1/true/on/yes) to enable at all.
#   MERGE_ON_GREEN_LOG     Audit-log path override. Default:
#                          "$(git rev-parse --git-dir)/merge-on-green.log".
#
# GATE INTEGRITY (coderabbit): `gh` and `check-ci.sh` are NOT environment-
# overridable — a contaminated/inherited launching environment must not be able
# to swap the merge gate or the SHA pin for a permissive stand-in. `gh` is
# resolved off PATH; `check-ci.sh` is the fixed in-repo sibling. Tests exercise
# the wrapper against stubs by running a COPY of the script tree with a stub `gh`
# on PATH — never via a caller-settable override.
set -uo pipefail
# NOT set -e: this script inspects sub-call exit codes (check-ci, gh) explicitly
# and must fail CLOSED with its own codes, never abort mid-gate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="gh"
CHECK_CI="$SCRIPT_DIR/../check-ci.sh"
# The repo's ONE CodeRabbit-availability answer (scripts/lib/cr-available.sh).
# Fixed in-repo sibling, resolved like CHECK_CI above and for the same reason.
# shellcheck source=scripts/lib/cr-available.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cr-available.sh" 2>/dev/null || true

selector=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "merge-on-green: unknown option: $1" >&2; exit 10 ;;
        *)
            if [ -n "$selector" ]; then
                echo "merge-on-green: only one PR selector allowed (got '$selector' and '$1')" >&2
                exit 10
            fi
            selector="$1"; shift ;;
    esac
done

# _truthy — the same truthiness test the leg resolver uses.
_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}

# Resolve the audit sink: MERGE_ON_GREEN_LOG override, else the per-repo git-dir
# log. Empty (no override, no git dir) means stdout-only auditing.
_audit_sink() {
    if [ -n "${MERGE_ON_GREEN_LOG:-}" ]; then printf '%s' "$MERGE_ON_GREEN_LOG"; return; fi
    local gd; gd=$(git rev-parse --git-dir 2>/dev/null || true)
    [ -n "$gd" ] && printf '%s' "$gd/merge-on-green.log"
}

# Structured audit line to stdout (the transcript — always) AND the append log.
# A file-write failure is SURFACED and PROPAGATED as rc 1 (a silent audit gap is
# exactly what the reversible/auditable constraint forbids); the pre-merge
# audit_preflight below turns an unwritable sink into a hard refusal BEFORE any
# merge, and the MERGING call site re-checks rc to close the preflight→write race.
audit() {
    local line ts logf rc=0
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')
    line="$ts merge-on-green $*"
    echo "$line"
    logf=$(_audit_sink)
    if [ -n "$logf" ]; then
        printf '%s\n' "$line" >>"$logf" 2>/dev/null || {
            echo "merge-on-green: WARNING — could not write the audit log at $logf" >&2
            rc=1
        }
    fi
    return "$rc"
}

# Preflight the audit sink before a merge — an unauditable merge must not
# proceed (the ticket's reversible/auditable constraint). A sink that resolves
# to empty (no git dir + no override) is allowed: stdout auditing still records
# to the transcript. rc 1 = configured sink is not writable.
audit_preflight() {
    local logf; logf=$(_audit_sink)
    [ -z "$logf" ] && return 0
    ( printf '' >>"$logf" ) 2>/dev/null && return 0
    return 1
}

# 1. Opt-in guard — the operator's standing authorization (launching shell only).
if ! _truthy "${ARMAUTOMERGE:-}"; then
    echo "merge-on-green: ARMAUTOMERGE not enabled — refusing (set ARMAUTOMERGE=1 in the launching shell to opt in)." >&2
    audit "REFUSED reason=not-opted-in selector=${selector:-<cwd-branch>}"
    exit 10
fi

command -v git >/dev/null 2>&1 || { echo "merge-on-green: required tool 'git' not on PATH" >&2; exit 11; }
command -v "$GH" >/dev/null 2>&1 || { echo "merge-on-green: required tool 'gh' not on PATH" >&2; exit 11; }

# gh helper honoring an optional selector (mirrors check-ci's pr_view shape).
gh_pr_view() {
    if [ -n "$selector" ]; then "$GH" pr view "$selector" "$@"; else "$GH" pr view "$@"; fi
}

# Resolve the PR (state + url + number + head SHA) in ONE query, scoped to the
# selector. The PR's OWN url yields its owner/repo — so the private-repo guard
# below checks the PR's repo, NOT cwd: a public-repo PR URL selector must not
# pass just because cwd happens to be private (codex-1). Capture stderr with
# 2>&1 so "no pull requests found" (a clean no-op) is distinguishable from a
# real auth/network failure (must refuse, never a silent no-op), like check-ci.
meta=""
meta_rc=0
meta=$(gh_pr_view --json state,url,number,headRefOid,baseRefName,headRefName \
        --jq '"\(.state)|\(.url)|\(.number)|\(.headRefOid)|\(.baseRefName)|\(.headRefName)"' 2>&1) || meta_rc=$?
if [ "$meta_rc" -ne 0 ]; then
    if printf '%s' "$meta" | grep -qi 'no pull requests found'; then
        echo "merge-on-green: no open PR for the target — nothing to merge."
        audit "NOOP reason=no-open-pr selector=${selector:-<cwd-branch>}"
        exit 0
    fi
    echo "merge-on-green: could not query the PR (auth/network?): ${meta:-<no output>} — refusing to guess. Re-run." >&2
    audit "REFUSED reason=pr-query-failed selector=${selector:-<cwd-branch>}"
    exit 13
fi
pr_state=${meta%%|*}; _rest=${meta#*|}
pr_url=${_rest%%|*}; _rest=${_rest#*|}
pr_num=${_rest%%|*}; _rest=${_rest#*|}
sha=${_rest%%|*}; _rest=${_rest#*|}
# headRefName is parsed LAST (HIMMEL-1970): git allows `|` in a branch name, so
# the trailing field absorbs any separator the head branch happens to carry
# rather than truncating it — base branches here are the repo default and never
# contain one.
pr_base=${_rest%%|*}; head_branch=${_rest#*|}
case "$pr_state" in
    OPEN) ;;
    ''|*)
        echo "merge-on-green: PR is ${pr_state:-<unknown>} (not OPEN) — nothing to merge."
        audit "NOOP reason=pr-not-open state=${pr_state:-unknown} selector=${selector:-<cwd-branch>}"
        exit 0 ;;
esac
# The PR's repo comes from its OWN url — a URL selector pointing at another repo
# is gated on THAT repo, not cwd.
case "$pr_url" in
    https://github.com/*/pull/*) ;;
    *)
        echo "merge-on-green: cannot resolve the PR's repo from its URL ('${pr_url:-<empty>}') — refusing. Re-run." >&2
        audit "REFUSED reason=bad-pr-url url=${pr_url:-empty}"
        exit 13 ;;
esac
owner=$(printf '%s' "$pr_url" | sed -n 's|^https://[^/]*/\([^/]*\)/.*|\1|p')
name=$(printf '%s' "$pr_url"  | sed -n 's|^https://[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
nwo="$owner/$name"
if [ -z "$owner" ] || [ -z "$name" ]; then
    echo "merge-on-green: cannot parse owner/repo from '$pr_url' — refusing." >&2
    audit "REFUSED reason=bad-pr-url url=$pr_url"
    exit 13
fi
if [ -z "$sha" ]; then
    echo "merge-on-green: cannot read the PR head SHA — cannot certify a merge target. Re-run." >&2
    audit "REFUSED reason=no-head-sha repo=$nwo"
    exit 13
fi

# The metadata line is six pipe-joined fields. Anything shorter means a field
# went missing (a gh/jq change, a truncated read) and `head_branch` silently
# collapses onto `pr_base` — which would then be handed to the post-merge
# worktree prune as a branch name. Require the shape (>=5 separators, so a `|`
# INSIDE the head branch still passes — it is parsed last) and a non-empty head
# branch. Fail closed, before any gate spends time or the merge fires.
meta_shape_ok=0
case "$meta" in *'|'*'|'*'|'*'|'*'|'*) meta_shape_ok=1 ;; esac
if [ "$meta_shape_ok" -ne 1 ] || [ -z "$head_branch" ]; then
    echo "merge-on-green: PR metadata line is malformed (expected six pipe-joined fields, got '$meta') — cannot certify a merge target. Re-run." >&2
    audit "REFUSED reason=malformed-meta repo=$nwo pr=#$pr_num"
    exit 13
fi

# 2a. Same-repo guard — bind the merge target to the CURRENT checkout's repo
# (codex-adv-2). The standing authorization must NOT reach PRs in OTHER private
# repos the credentials can see: refuse any selector whose PR lives outside the
# repo this wrapper was invoked from. (The default no-selector path is already
# the cwd branch's PR, so this only ever refuses an explicit cross-repo selector.)
cwd_nwo=$("$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -z "$cwd_nwo" ]; then
    echo "merge-on-green: cannot resolve the current checkout's repo — refusing (cannot bind the merge target)." >&2
    audit "REFUSED reason=no-cwd-repo pr=#$pr_num"
    exit 12
fi
if [ "$nwo" != "$cwd_nwo" ]; then
    echo "merge-on-green: PR repo $nwo is not the current checkout ($cwd_nwo) — refusing. This lever only merges PRs in the repo it is invoked from." >&2
    audit "REFUSED reason=cross-repo pr_repo=$nwo cwd_repo=$cwd_nwo pr=#$pr_num"
    exit 12
fi


# 2b. Private-repo guard — on the (now cwd-bound) repo, fail CLOSED. Public or
# undeterminable ⇒ refuse; public propagation stays an operator/bridge step.
# Folds the default branch into this SAME query (HIMMEL-1080, coderabbit): the
# base-branch guard below needs it too, and this avoids a second API round-trip.
# defaultBranchRef is NULLABLE (a repo can have no default branch) — coalesce
# to "" (CodeRabbit) so a null field reads as "undeterminable" below instead of
# jq's literal "null" string slipping past the -z check as a non-empty value.
repo_meta=$("$GH" repo view "$nwo" --json isPrivate,defaultBranchRef \
        --jq '"\(.isPrivate)|\(.defaultBranchRef.name // "")"' 2>/dev/null || true)
is_private=${repo_meta%%|*}
default_branch=${repo_meta#*|}
if [ "$is_private" != "true" ]; then
    echo "merge-on-green: repo $nwo is not confirmed PRIVATE (isPrivate='${is_private:-<unknown>}') — refusing. Public propagation stays an operator/bridge step." >&2
    audit "REFUSED reason=not-private repo=$nwo isPrivate=${is_private:-unknown}"
    exit 12
fi

# 2c. Base-branch guard (HIMMEL-1080, coderabbit public round) — this lever was
# repo-bound but NOT base-branch-bound: it would merge ANY open PR in the
# private repo regardless of base, even though inject-initiative.sh:236
# documents the scope as "squash-merge to PRIVATE main". Fail CLOSED: an
# empty/unreadable PR base or repo default branch must refuse, never guess.
if [ -z "$pr_base" ] || [ -z "$default_branch" ]; then
    echo "merge-on-green: cannot determine the PR base branch ('${pr_base:-<empty>}') or the repo default branch ('${default_branch:-<empty>}') — refusing. Re-run." >&2
    audit "REFUSED reason=base-branch-undeterminable pr_base=${pr_base:-empty} default_branch=${default_branch:-empty} repo=$nwo pr=#$pr_num"
    exit 12
fi
if [ "$pr_base" != "$default_branch" ]; then
    echo "merge-on-green: PR #$pr_num targets '$pr_base', not the repo's default branch '$default_branch' — refusing. This lever only merges PRs against $default_branch." >&2
    audit "REFUSED reason=wrong-base-branch pr_base=$pr_base authorized_branch=$default_branch repo=$nwo pr=#$pr_num"
    exit 12
fi

# 3. Green gate — check-ci.sh exit 0 is the only pass. It watches CI to green,
# then re-verifies review state + head binding. Any other rc = not merge-safe.
# No flags passed, so the watch is bounded by CHECK_CI_MAX_WAIT (default 540s,
# HIMMEL-2062) the same as every other caller — that same env var tunes both.
if [ ! -f "$CHECK_CI" ]; then
    echo "merge-on-green: check-ci.sh not found at $CHECK_CI — cannot certify green. Refusing." >&2
    audit "REFUSED reason=no-check-ci repo=$nwo pr=#$pr_num"
    exit 14
fi
# CodeRabbit availability, for the DURABLE record (HIMMEL-2380). Read
# IMMEDIATELY before check-ci.sh, and deliberately not earlier (codex-1, CR
# round 1): check-ci.sh runs this same probe at its own startup, so the value
# recorded here is only honest to the extent that the two reads see the same
# config. Taken back at guard 2a it sat ~45 lines and two `gh` round-trips
# ahead of the gate, and a `himmel.coderabbit` change landing in that window
# would have stamped the audit line with a configuration the gate never
# evaluated — the precise dishonesty this field exists to remove. Adjacent, the
# window is the sub-second gap before check-ci's own probe.
#
# Still after guard 2a, which is what makes the answer meaningful at all: before
# that binding proved the PR's repo IS this checkout, the local config might
# describe a different repo entirely, and a merge record naming the wrong repo's
# reviewer coverage is worse than one naming none.
#
# NOT closed, and not claimed to be: two processes reading the same config a
# moment apart can still disagree. Closing it needs check-ci.sh to hand its OWN
# resolved state back rather than each side probing — which means capturing its
# stdout, and that would end the streaming this script relies on to put the
# gate's output in front of an operator live. The narrowing is the honest trade;
# the residual is recorded here rather than papered over.
#
# This is the honesty half of HIMMEL-2380 for the UNATTENDED path. check-ci.sh
# streams to this script's stdout, so an operator watching a live run already
# sees whatever it says — but an ARMAUTOMERGE chain merges with nobody watching,
# and the audit log is the only thing anyone reads afterwards. `gate=check-ci:0`
# alone cannot distinguish "CodeRabbit reviewed this and passed" from "there is
# no CodeRabbit here", and those are very different merges to have made.
# Recorded on every state, including `armed` — a field that appears only on bad
# news is one nobody learns to look for.
CR_STATE=$(cr_app_state "$PWD" 2>/dev/null) || CR_STATE=""
CR_STATE=${CR_STATE:-unknown}

ci_rc=0
if [ -n "$selector" ]; then
    bash "$CHECK_CI" "$selector"
else
    bash "$CHECK_CI"
fi || ci_rc=$?
if [ "$ci_rc" -ne 0 ]; then
    echo "merge-on-green: check-ci gate did not pass (exit $ci_rc) — not merging. Address the gate, then re-run." >&2
    audit "REFUSED reason=gate-not-green gate=check-ci:$ci_rc repo=$nwo pr=#$pr_num sha=$sha"
    exit 14
fi

# MARKER CLEAR (HIMMEL-1346) — a merge used to leave the branch's cr-pending
# marker behind, and because the marker lives in the SHARED git-common-dir while
# check-cr-marker-on-pr-create.sh resolves the branch from the session cwd, that
# stale marker then HARD-BLOCKED `gh pr create` on unrelated branches (19 such
# markers accumulated in this checkout by 2026-08-20).
#
# Always through clear-cr-marker.sh, never a raw `rm` (HIMMEL-1064): the ledger
# + CI gates must still decide, and a bare `rm` is the self-declare-clean pattern
# the auto-mode classifier flags. Ordering: HERE — after the green gate, before
# the merge — not after it. Post-merge the chokepoint cannot pass at all: the
# repo's deleteBranchOnMerge deletes the remote head branch, so its marker
# endpoint binding (gate 2) refuses with exit 16 for every merged branch. This
# is also before the base re-verification below, which must stay the LAST thing
# before `gh pr merge` (clear-cr-marker can run its own check-ci, i.e. minutes).
#
# Best-effort for the exit code — a merge that passed every gate must not be
# refused because a marker could not be tidied — but the outcome is recorded on
# the MERGED audit line and any failure is printed.
MARKER_RESULT="not-attempted"
clear_cr_marker_for_branch() {
    local branch="$1"
    MARKER_RESULT="not-attempted"
    [ -n "$branch" ] || { MARKER_RESULT="no-head-branch"; return 0; }

    local common
    common=$(git rev-parse --git-common-dir 2>/dev/null) || { MARKER_RESULT="no-repo"; return 0; }
    [ -n "$common" ] || { MARKER_RESULT="no-repo"; return 0; }
    # No marker => nothing to clear. Checked here rather than left to the
    # chokepoint's own no-op so the common case does not pay for its gates
    # (which include a second check-ci watch). Reading the path is not clearing
    # it — the delete still only ever happens inside clear-cr-marker.sh.
    if [ ! -f "$common/cr-pending/$branch" ]; then MARKER_RESULT="absent"; return 0; fi

    local clearer="$SCRIPT_DIR/../cr/clear-cr-marker.sh"
    if [ ! -f "$clearer" ]; then
        MARKER_RESULT="no-clearer"
        echo "merge-on-green: clear-cr-marker.sh not found at $clearer — the CR marker for '$branch' stays pending." >&2
        return 0
    fi
    local rc=0
    bash "$clearer" "$branch" || rc=$?
    if [ "$rc" -eq 0 ]; then
        MARKER_RESULT="cleared"
    else
        MARKER_RESULT="clear-rc=$rc"
        echo "merge-on-green: could not clear the CR marker for '$branch' (clear-cr-marker exit $rc) — it stays in $common/cr-pending and will block \`gh pr create\` for any branch resolved from a session cwd in this checkout until it is cleared (HIMMEL-1346)." >&2
    fi
    return 0
}
# Not on --dry-run: clearing is a real mutation, and --dry-run must change
# nothing.
[ "$DRY_RUN" -eq 1 ] || clear_cr_marker_for_branch "$head_branch"

# 3b. Base-branch re-verification (HIMMEL-1080 CR round-1, codex-adv) — guard 2c
# above only proved the base binding at QUERY time, but check-ci.sh just above
# WATCHES CI and can block for minutes. GitHub allows retargeting a PR's base
# (`gh pr edit --base`) WITHOUT moving its head SHA, so the base checked at
# guard 2c can go stale during that window; `--match-head-commit` below only
# pins the HEAD, so the merge would still land the certified SHA into the newly
# selected base, defeating guard 2c entirely — the same staleness class the
# head SHA already gets `--match-head-commit` for. Re-query the base,
# default-branch AND privacy values fresh (never reuse $pr_base /
# $default_branch / $is_private captured at guard 2b/2c) right before
# merging; placed here, before the DRY_RUN branch, so the dry-run path is
# covered too — everything from here to the merge is local/fast, so this is
# effectively "immediately before merging". Same nullable-defaultBranchRef
# coalesce as guard 2b (CodeRabbit).
#
# HIMMEL-1080 CR round-3 (coderabbit): fold isPrivate into the SAME pre-merge
# repo view call as the default branch (no extra round-trip, mirroring guard
# 2b's combined query). The private-only boundary (guard 2b) is subject to the
# SAME CI-wait staleness window as the base binding — a repo made PUBLIC during
# the check-ci watch would otherwise merge on the stale guard-2b isPrivate.
fresh_base=$("$GH" pr view "$pr_num" --repo "$nwo" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
fresh_repo_meta=$("$GH" repo view "$nwo" --json isPrivate,defaultBranchRef \
        --jq '"\(.isPrivate)|\(.defaultBranchRef.name // "")"' 2>/dev/null || true)
fresh_private=${fresh_repo_meta%%|*}
fresh_default=${fresh_repo_meta#*|}
if [ -z "$fresh_base" ] || [ -z "$fresh_default" ]; then
    echo "merge-on-green: cannot re-verify the PR base branch ('${fresh_base:-<empty>}') or the repo default branch ('${fresh_default:-<empty>}') right before merging — refusing. Re-run." >&2
    audit "REFUSED reason=base-branch-undeterminable pr_base=${fresh_base:-empty} default_branch=${fresh_default:-empty} repo=$nwo pr=#$pr_num"
    exit 12
fi
if [ "$fresh_private" != "true" ]; then
    echo "merge-on-green: repo $nwo is no longer confirmed PRIVATE (isPrivate='${fresh_private:-<unknown>}') right before merging — refusing. A repo made public during the CI wait must not auto-merge." >&2
    audit "REFUSED reason=not-private-premerge repo=$nwo isPrivate=${fresh_private:-unknown} pr=#$pr_num"
    exit 12
fi
if [ "$fresh_base" != "$fresh_default" ] || [ "$fresh_base" != "$pr_base" ]; then
    echo "merge-on-green: PR #$pr_num base branch changed since the gate (was '$pr_base', now '$fresh_base', repo default '$fresh_default') — refusing. The base binding must hold from certification to merge." >&2
    audit "REFUSED reason=base-branch-changed pr_base_at_gate=$pr_base pr_base_now=$fresh_base default_branch_now=$fresh_default repo=$nwo pr=#$pr_num"
    exit 12
fi

# Audit-sink preflight — an unauditable merge must not proceed. Runs after the
# gates (so a gate refusal short-circuits first) and before the merge/dry-run.
if ! audit_preflight; then
    logf=$(_audit_sink)
    echo "merge-on-green: audit sink '$logf' is not writable — refusing (an unauditable merge must not proceed). Set MERGE_ON_GREEN_LOG to a writable path." >&2
    audit "REFUSED reason=audit-sink-unwritable sink=$logf repo=$nwo pr=#$pr_num sha=$sha"
    exit 16
fi

# 4. Atomic merge — pinned to the certified SHA. gh aborts if the head moved
# (concurrent push) since the gate, so the only outcomes are "merge the certified
# green SHA" or "benign abort → re-run" — never a merge of an ungated SHA.
if [ "$DRY_RUN" -eq 1 ]; then
    audit "DRYRUN would-merge repo=$nwo pr=#$pr_num sha=$sha gate=check-ci:0 cr=$CR_STATE"
    echo "merge-on-green: [dry-run] gates passed — would squash-merge PR #$pr_num @ $sha (repo $nwo). Not merging."
    exit 0
fi

# Record the merge INTENT before executing (coderabbit): a crash or lost-record
# between here and the MERGED line still leaves a durable trace of what was
# attempted on which certified SHA. The write is CHECKED, not assumed: the
# preflight above proves the sink was writable a moment ago, but a sink that
# fails right here (disk full, removed underneath us) must abort the merge —
# the durable intent record is a precondition, not a courtesy.
if ! audit "MERGING repo=$nwo pr=#$pr_num sha=$sha gate=check-ci:0 cr=$CR_STATE"; then
    echo "merge-on-green: could not record the MERGING audit record at $(_audit_sink) — refusing (an unauditable merge must not proceed)." >&2
    exit 16
fi

# Re-query state TOGETHER with headRefOid + baseRefName (codex-adv review,
# HIMMEL-1394): shared by BOTH the failure-recovery path AND the success-path
# confirmation poll below. Callers decide whether an API failure means
# unconfirmed or indeterminate; do not collapse it into an empty state,
# because that would turn an unreadable result into a false conclusion.
#
# Failure-recovery use: when `gh pr merge --match-head-commit` itself FAILS,
# gh never confirmed which commit matched OR which base it landed on — a
# MERGED state read afterward could belong to a DIFFERENT commit a concurrent
# actor merged in the gap between gh's failure and this re-query (headRefOid),
# or the SAME certified sha merged after a concurrent retarget (baseRefName) —
# the exact staleness class the pre-merge guard above (3b, HIMMEL-1080)
# re-verifies for the primary merge attempt; the recovery path needs the same
# check on ITS OWN re-query, since --match-head-commit pins only the head,
# never the base.
#
# Success-path use (codex-adv review, HIMMEL-1394): a zero `gh pr merge` exit
# means --match-head-commit confirmed $sha at ACCEPTANCE time, but under a
# merge queue that acceptance is not the merge itself — the PR can sit queued
# (see the poll comment further down), and a concurrent retarget or a
# different commit merging into the queue in that window can land a MERGED
# state that does not actually belong to the certified sha/base. The poll
# needs the SAME head/base confirmation the failure-recovery path already
# does, not just a bare `state` read.
#
# Pinned to the PR identity resolved above (#number + repo), NEVER the
# selector-less cwd-branch resolution (HIMMEL-1694): `gh` resolves a bare
# `pr view` from the CURRENT branch, and a post-merge checkout switch (or a
# cwd that is not the PR's worktree) would make the re-query miss — or hit a
# different PR — after the merge already landed.
pr_state_and_head_now() {
    "$GH" pr view "$pr_num" --repo "$nwo" --json state,headRefOid,baseRefName --jq '"\(.state) \(.headRefOid) \(.baseRefName)"'
}

# Bounded confirmation poll over that re-query, shared by the success path and
# (HIMMEL-1697) the failure-recovery path. A merge can be accepted server-side
# and only reflected moments later — under a merge queue, or when gh reports a
# failure for a request that actually landed (a lost/timed-out response). One
# re-query cannot tell "not merged" from "not merged YET", so both callers poll:
# OPEN (or an unreadable read) keeps waiting, MERGED or any other state stops.
# Sets POLL_STATE / POLL_HEAD / POLL_BASE and POLL_QUERY_RC (the LAST attempt's
# query status, so a persistent API failure is distinguishable from a genuine
# OPEN read — a single transient failure mid-poll just retries). Always 0.
POLL_STATE=""; POLL_HEAD=""; POLL_BASE=""; POLL_QUERY_RC=0
# Sleep seam (HIMMEL-1953), same shape as check-ci.sh's CHECK_CI_SLEEP_CMD: the
# only wall-clock wait in this script, so a hermetic suite injects `:` and pays
# nothing for a simulated poll. The cost was already distorting the tests — case
# 11e of test-merge-on-green.sh drives the not-MERGED branch with CLOSED rather
# than the realistic OPEN precisely because OPEN would sit out the full 30-try
# budget. One command word, no argument splitting.
MERGE_ON_GREEN_SLEEP_CMD="${MERGE_ON_GREEN_SLEEP_CMD:-sleep}"
poll_merge_state() {
    local max="$1" tries=0 line rest
    POLL_STATE=""; POLL_HEAD=""; POLL_BASE=""; POLL_QUERY_RC=0
    while [ "$tries" -lt "$max" ]; do
        line=$(pr_state_and_head_now 2>/dev/null); POLL_QUERY_RC=$?
        if [ "$POLL_QUERY_RC" -ne 0 ]; then
            POLL_STATE=""
        else
            POLL_STATE=${line%% *}
            rest=${line#* }
            POLL_HEAD=${rest%% *}
            POLL_BASE=${rest#* }
        fi
        case "$POLL_STATE" in
            MERGED) break ;;
            OPEN|'') ;;   # queued / not yet reflected, or a failed query — keep waiting
            *) break ;;   # CLOSED or unexpected — stop; the callers handle it
        esac
        tries=$((tries + 1))
        [ "$tries" -lt "$max" ] && "$MERGE_ON_GREEN_SLEEP_CMD" 2
    done
    return 0
}

# HIMMEL-2227 — worktree_in_use / worktree_intact, shared with clean-garden.sh
# (the OTHER caller of a non-atomic-on-Windows `git worktree remove`; see the
# measured repro table and reasoning in that file's header).
# shellcheck source=scripts/lib/worktree-inuse.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/worktree-inuse.sh"

# HIMMEL-1970 — close the worktree lifecycle loop at the merge itself. A merged
# ticket's worktree used to outlive its PR until someone remembered to run
# `/clean`, so new-and-dead trees piled up within days of a garden sweep. This
# is the same prune `/clean` (scripts/clean-garden.sh) would do later, applied
# to exactly ONE tree — the one whose checked-out branch IS this PR's head
# branch — and it keeps clean-garden's safety rules verbatim:
#   * plain `git worktree remove`, NEVER --force: git itself refuses on
#     uncommitted or untracked work, so a dirty tree is reported and kept —
#     BUT that atomicity assumption does not hold for an IN-USE tree on
#     Windows (HIMMEL-2227): git-for-Windows deletes with POSIX semantics, so
#     an open handle does not stop the delete, it only stops the final rmdir —
#     after the contents and the admin entry are already gone. That is why
#     `worktree_in_use` probes BEFORE the remove, and `worktree_intact` checks
#     AFTER a failed remove, rather than trusting a bare non-zero rc to mean
#     "refused up front, unchanged";
#   * a LOCKED worktree is left alone — `git worktree lock` is the only
#     machine-readable exempt mechanism /clean honours (the 2026-08-17 garden
#     KEEP list uses it), so it must gate this path too;
#   * the local branch tip must equal the merged sha, clean-garden's
#     exact-head-match rule — commits pushed after the squash merge (the
#     HIMMEL-1410 loss mode) keep the tree.
# Sets PRUNE_RESULT / PRUNE_BRANCH for the MERGED audit line and ALWAYS returns
# 0: a merge that landed must never be reported as failed because a local
# directory could not be tidied up.
# HIMMEL-2517 — is a shell-test runner executing INSIDE this worktree right now?
#
# Two distinct populations have to be caught, and only one of them is in the
# suite lock's owner file (`$TMPDIR/himmel-shell-suite-<slug>.lock/owner`):
#
#   * the LOCK HOLDER — a run currently executing suites; and
#   * a QUEUED runner — one waiting out SUITE_LOCK_WAIT, which owns no lock and
#     has executed nothing, but whose cwd is already the worktree. That is the
#     04:50 instance on PR #2150: the tree was pruned while its runner sat in
#     the wait loop, so it started executing against paths that no longer
#     existed. Reading only the owner file would have missed it.
#
# So the oracle is the PROCESS TABLE, not the lock: any live process whose argv
# names run-shell-tests.sh or quiet-run.sh AND which is anchored to this
# worktree — by cwd, or by naming the worktree path in its own argv (a runner
# invoked by absolute path from elsewhere). Both are checked; either is enough.
#
# /proc is the only cwd oracle available here and it is Linux-only. Everywhere
# else this returns "no live run" and the existing prune path decides exactly as
# before — no worse than today, and the incident this closes is a Linux one.
# `ps` was considered and rejected: it reports argv but not cwd, so it cannot
# see the case above where the runner was launched with relative paths.
#
# Deliberately CONSERVATIVE in the same direction as worktree_in_use: a false
# positive leaves a merged tree for `/clean`, which costs nothing; a false
# negative is the 422-red artifact.
#
# Probe-then-act, not a lock — the SAME residual TOCTOU window worktree_in_use
# documents for itself, already tracked as HIMMEL-2229 (round-7 CR finding
# codex-1 raised it against this function too). A runner starting between this
# check and the `git worktree remove` below is not caught. That window is
# milliseconds, and it is a different event from the one this closes: every
# instance on 2026-09-05 had a runner that had been live for MINUTES or HOURS —
# in the #2150 case, queued on the suite lock — when the merge pruned under it.
# Closing the remainder needs a lock held across probe and remove, which is
# 2229's scope for both callers, not a second mechanism here.
SUITE_RUN_PID=""
SUITE_RUN_CMD=""
worktree_has_live_suite_run() {
    local path="$1"
    SUITE_RUN_PID=""
    SUITE_RUN_CMD=""
    [ -n "$path" ] || return 1
    [ -d /proc/self ] || return 1

    # argv is read ARGUMENT BY ARGUMENT, on its own NUL boundaries, rather than
    # flattened to a string and pattern-matched (round-6 CR finding codex-2).
    # Three consecutive rounds argued about where to put the boundaries in that
    # flattened form — first the trailing edge (round-2 codex-5: a run inside
    # `…-prune-race-2` retained `…-prune-race`), then the leading edge (round-5
    # codex-2: `/backup<worktree>/scripts` retained the original) — which is the
    # signal that the string was the wrong instrument, not that the pattern
    # needed a fourth arm. Reading the delimiters the kernel already provides
    # makes every one of those cases a plain string comparison with nothing left
    # to bound. Round 6's own stated mechanism does not hold as written —
    # `tr '\0' ' '` separates arguments, it does not concatenate them — but the
    # residual it points at is real: an argument that CONTAINS a space is
    # indistinguishable from two arguments once flattened, and this removes that
    # too.
    local entry pid cwd arg cand argv0 runner matched argc
    for entry in /proc/[0-9]*; do
        # An unmatched glob leaves the literal pattern; the -r test below rejects
        # it. No nullglob (this is sourced into whatever shell the caller has,
        # and setting shell options here would leak).
        pid="${entry#/proc/}"
        # Never count ourselves or our own shell: merge-on-green does not run
        # suites, but a test harness driving it could carry either name in argv.
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        [ -r "$entry/cmdline" ] || continue
        # Read BEFORE the argv walk, because a relative argument is only
        # meaningful against it (see the resolution inside the loop).
        # The loop is already gated on /proc/self, i.e. Linux, where readlink -f
        # is coreutils' own and always present. There is no BSD path to be
        # portable to: without /proc there is no cwd to read at all and the
        # function has already returned 1.
        cwd=$(readlink -f "$entry/cwd" 2>/dev/null) || cwd=""  # gnu-ok: /proc-gated, Linux-only by construction
        # First pass: identify. Which runner name matched is ALL that is reported
        # below (round-2 CR finding codex-6) — the full argv would put a
        # stranger's command line, flags and tokens included, into an audit
        # message, and "which runner" is the only part an operator acts on; the
        # pid is printed alongside, so `ps -p <pid>` recovers the rest.
        runner=""; argv0=""; matched=0; argc=0
        while IFS= read -r -d '' arg; do
            [ "$argc" -eq 0 ] && argv0="$arg"
            argc=$((argc + 1))
            if [ -z "$runner" ]; then
                case "$arg" in
                    run-shell-tests.sh|*/run-shell-tests.sh) runner=run-shell-tests.sh ;;
                    quiet-run.sh|*/quiet-run.sh)             runner=quiet-run.sh ;;
                esac
            fi
        done < "$entry/cmdline"
        [ -n "$runner" ] || continue
        # Naming a runner is not RUNNING one (round-4 CR finding codex-3):
        # `vim scripts/ci/run-shell-tests.sh` or a grep for it, opened inside the
        # worktree, carries the same token and would pin a merged tree open — and
        # someone editing that very file in that very worktree is exactly who
        # trips it. A real runner is always a shell executing a script, so argv[0]
        # has to be a shell or the runner itself. The launch wrappers the
        # overnight docs prescribe (`setsid nohup env … bash …/quiet-run.sh`) are
        # excluded by this and that is fine: the bash they exec is the process
        # whose cwd is in the tree, and it matches.
        case "$argv0" in
            bash|*/bash|sh|*/sh|run-shell-tests.sh|*/run-shell-tests.sh|quiet-run.sh|*/quiet-run.sh) ;;
            *) continue ;;
        esac
        if [ -n "$cwd" ]; then
            case "$cwd" in
                "$path"|"$path"/*)
                    SUITE_RUN_PID="$pid"; SUITE_RUN_CMD="$runner"; return 0 ;;
            esac
        fi
        # Second pass: resolve. Only a confirmed runner whose cwd did NOT match
        # gets here — typically none, at most a couple on a busy box — which is
        # what makes it affordable to CANONICALIZE each argument rather than
        # compare the raw string.
        #
        # Both rounds that found a false negative here found it in the gap
        # between "the string a caller typed" and "the directory it names".
        # Round 8's codex-2: a runner launched from OUTSIDE the tree naming it
        # relatively (`bash wt/scripts/ci/run-shell-tests.sh wt/scripts` from the
        # parent) is invisible to both the cwd check and a literal comparison,
        # while the scan root it walks is inside the worktree. Round 9's codex-2:
        # prefixing the cwd is not enough either, because `..`, `.` and symlink
        # components still name the tree without spelling it. `readlink -m`
        # answers both — it canonicalizes without requiring the path to exist,
        # and $path is itself already the physical (cd + pwd) form, so the two
        # sides are comparable. A false negative is the one direction this
        # detector may not have; a fork per argument of an actual runner is a
        # cheap price for removing a whole class of them.
        while IFS= read -r -d '' arg; do
            case "$arg" in
                # gnu-ok: /proc-gated above, so this is Linux and coreutils
                # readlink is present; -m is what allows a not-yet-existing path.
                /*) cand=$(readlink -m "$arg" 2>/dev/null) || cand="" ;;
                *)  if [ -n "$cwd" ]; then
                        cand=$(readlink -m "$cwd/$arg" 2>/dev/null) || cand=""
                    else
                        cand=""
                    fi ;;
            esac
            # Quoted so a path containing glob metacharacters is compared
            # literally rather than matched as a pattern.
            case "$cand" in
                "") ;;
                "$path"|"$path"/*) matched=1; break ;;
            esac
        done < "$entry/cmdline"
        if [ "$matched" -eq 1 ]; then
            SUITE_RUN_PID="$pid"; SUITE_RUN_CMD="$runner"; return 0
        fi
    done
    return 1
}

PRUNE_RESULT="not-attempted"
PRUNE_BRANCH="kept"
prune_merged_worktree() {
    local branch="$1" merged_sha="$2"
    PRUNE_RESULT="not-found"
    PRUNE_BRANCH="kept"
    [ -n "$branch" ] || { PRUNE_RESULT="no-head-branch"; return 0; }

    local common primary
    common=$(git rev-parse --git-common-dir 2>/dev/null) || { PRUNE_RESULT="no-repo"; return 0; }
    [ -n "$common" ] || { PRUNE_RESULT="no-repo"; return 0; }
    primary=$(cd "$(dirname "$common")" 2>/dev/null && pwd) || { PRUNE_RESULT="no-repo"; return 0; }

    # Find the worktree checked out on this PR's head branch. `locked` follows
    # `branch` inside a record, so buffer per record and decide on the blank
    # separator line.
    local line cur="" cur_br="" cur_lock=0 path="" locked=0
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)          cur="${line#worktree }"; cur_br=""; cur_lock=0 ;;
            "branch refs/heads/"*) cur_br="${line#branch refs/heads/}" ;;
            "locked"*)             cur_lock=1 ;;
            "")
                if [ -n "$cur" ] && [ "$cur_br" = "$branch" ]; then
                    path="$cur"; locked="$cur_lock"
                fi
                cur=""; cur_br=""; cur_lock=0 ;;
        esac
    done < <(git -C "$primary" worktree list --porcelain 2>/dev/null; printf '\n')
    [ -n "$path" ] || return 0

    local path_norm
    path_norm=$(cd "$path" 2>/dev/null && pwd) || path_norm="$path"
    # Defensive: the primary checkout is never a prune candidate (it would be,
    # if a PR were ever opened from the branch the primary has checked out).
    if [ "$path_norm" = "$primary" ]; then PRUNE_RESULT="primary-skipped"; return 0; fi
    if [ "$locked" -eq 1 ]; then PRUNE_RESULT="locked-kept"; return 0; fi

    local tip
    tip=$(git -C "$primary" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null || true)
    if [ "$tip" != "$merged_sha" ]; then PRUNE_RESULT="tip-differs-kept"; return 0; fi

    # merge-on-green is normally invoked FROM the worktree it just merged.
    # Removing the caller's own cwd is not a prune, it is a broken shell: on
    # Windows the directory is locked by the parent process anyway (so the
    # remove would fail and be reported as dirty), and an armed chain's
    # remaining legs would run inside a deleted tree. Defer with the exact
    # follow-up instead.
    local here
    here=$(git rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$here" ] && here=$(cd "$here" 2>/dev/null && pwd)
    if [ -n "$here" ] && [ "$here" = "$path_norm" ]; then
        PRUNE_RESULT="own-cwd-deferred"
        echo "merge-on-green: this run's cwd IS the merged worktree — not removing it out from under the caller. Prune it from the primary checkout with: git -C '$primary' worktree remove '$path_norm' && git -C '$primary' branch -D '$branch'   (or just run: bash '$primary/scripts/clean.sh')"
        return 0
    fi

    # HIMMEL-2517 — a live shell-suite run INSIDE the tree is its own refusal,
    # checked before the HIMMEL-2227 rename probe because that probe cannot see
    # this case at all: on POSIX a process's cwd blocks neither the rename nor
    # the rmdir, so the probe returns "free to remove" and the prune succeeds —
    # deleting every suite path out from under a running
    # `scripts/ci/run-shell-tests.sh`. Measured twice on 2026-09-05 (PRs #2133,
    # #2134): the runner kept going against vanished paths and rendered
    # PASS 6 / FAIL 422, of which 421 were rc=127. The runner posts its own
    # after-report (HIMMEL-2383), so a merged, green PR can acquire a permanent
    # 422-red record from a race that has nothing to do with its diff.
    if worktree_has_live_suite_run "$path_norm"; then
        PRUNE_RESULT="suite-running-kept"
        echo "merge-on-green: merged worktree '$path_norm' is running a shell-test suite ($SUITE_RUN_CMD, pid $SUITE_RUN_PID — 'ps -p $SUITE_RUN_PID' for its full command) — NOT pruned; the merge itself is unaffected. Run scripts/clean.sh once that run has finished." >&2
        return 0
    fi

    # HIMMEL-2227 — in-use detection BEFORE the remove, because the remove is
    # NOT atomic. Measured on Windows (git-for-Windows deletes with POSIX
    # semantics, so open handles do NOT stop it): with a native process holding
    # a directory inside the tree, `git worktree remove` deletes the CONTENTS,
    # deregisters the admin entry, and only then fails the final rmdir — leaving
    # exactly the HIMMEL-2227 wreck (directory present, empty, no `.git`, no
    # `worktree list` row). The old code called that "left in place".
    if worktree_in_use "$path_norm"; then
        PRUNE_RESULT="$WORKTREE_INUSE_RESULT"
        echo "merge-on-green: merged worktree '$path_norm' could not be safely removed (likely in use by a live process) — skipped. $WORKTREE_INUSE_DETAIL Run scripts/clean.sh once nothing is running in it." >&2
        return 0
    fi

    if ! git -C "$primary" worktree remove "$path_norm" >/dev/null 2>&1; then
        # Never report a removal outcome without LOOKING. A refusal git makes up
        # front leaves the tree whole; a failure part-way through leaves a
        # gutted tree that still answers `git ls-files` with confident zeroes.
        if worktree_intact "$primary" "$path_norm"; then
            PRUNE_RESULT="dirty-kept"
            echo "merge-on-green: merged worktree '$path_norm' was not removed (uncommitted work or untracked files) — git refused the removal; the worktree is still registered with its .git link present. Run scripts/clean.sh once it is clean." >&2
        else
            PRUNE_RESULT="gutted"
            echo "merge-on-green: removal of merged worktree '$path_norm' FAILED PARTWAY — the tree may be GUTTED (its .git link and/or its 'git worktree list' entry is gone). Do NOT trust anything measured inside it: git commands there report an empty repo. Recover from the primary checkout, in order: 1) git -C '$primary' worktree prune  2) make sure '$path_norm' is empty or removed -- 'git worktree add' refuses a non-empty destination, and remnants can survive exactly this partial-remove case  3) git -C '$primary' worktree add '$path_norm' '$branch'" >&2
        fi
        return 0
    fi
    PRUNE_RESULT="removed"
    # `-d` refuses a squash-merged branch ("not fully merged"), which is every
    # branch here — so fall back to `-D`, which the tip == merged-sha check
    # above has already proven lossless: the tip is byte-for-byte the commit
    # GitHub merged. This mirrors clean-garden.sh's own post-remove branch -D.
    if git -C "$primary" branch -d "$branch" >/dev/null 2>&1 \
       || git -C "$primary" branch -D "$branch" >/dev/null 2>&1; then
        PRUNE_BRANCH="deleted"
    fi
    return 0
}

# AFTER-REPORT PENDING MARKER (HIMMEL-2383) — a merge lands well before the
# covering scoped suite's SUMMARY necessarily reaches the PR as a comment (the
# suite can still be running, or a closed parent session never got to post
# it — the HIMMEL-2360/2371 incident this ticket exists to structurally
# catch). scripts/console/base-status.sh's live gh query is the authoritative
# PENDING/RED detector; this is a durable LOCAL trace of the same gap at
# merge time, same marker-dir shape as the cr-pending marker above, so a
# console tick has a fallback even if this doesn't stay abreast of every
# gh-side comment race. Best-effort — the exit code never depends on it — and
# recorded on the MERGED audit line as `after-report=<result>`.
AFTER_REPORT_RESULT="not-attempted"
record_after_report_pending_marker() {
    local branch="$1" pr="$2" pr_sha="$3"
    AFTER_REPORT_RESULT="not-attempted"
    [ -n "$branch" ] || { AFTER_REPORT_RESULT="no-head-branch"; return 0; }

    local common
    common=$(git rev-parse --git-common-dir 2>/dev/null) || { AFTER_REPORT_RESULT="no-repo"; return 0; }
    [ -n "$common" ] || { AFTER_REPORT_RESULT="no-repo"; return 0; }

    # Same detection as base-status.sh: the runner's literal '== Summary =='
    # + 'PASS:' block, never prose that merely mentions test results — AND
    # bound to the certified merge SHA (HIMMEL-2383 CR finding codex-5,
    # round 2): without the head check, a stale report from an EARLIER
    # revision of this PR would clear the local pending marker for the sha
    # that actually merged, same staleness class base-status.sh's own
    # head-binding closes.
    # `gh --jq` takes exactly one argument (the jq program) — it has no
    # --arg passthrough the way the real jq binary does, so the SHA is
    # bound via a SEPARATE `jq --arg` pass over the raw JSON (`gh`'s own
    # --jq flag would parse a literal `--arg` as the jq program itself).
    # Bounded (GH_TIMEOUT_SECS, default 30s) so a GitHub network stall can't
    # hang the audit-marker path indefinitely (CodeRabbit round on PR #2099);
    # skipped when `timeout` isn't on PATH rather than failing the query
    # outright.
    local _gh_view_cmd=("$GH" pr view "$pr" --repo "$nwo" --comments --json comments)
    command -v timeout >/dev/null 2>&1 && _gh_view_cmd=(timeout "${GH_TIMEOUT_SECS:-30}" "${_gh_view_cmd[@]}")
    local n_summaries=""
    n_summaries=$("${_gh_view_cmd[@]}" 2>/dev/null \
        | jq -r --arg sha "$pr_sha" \
            '[.comments[]?.body | select(contains("== Summary ==") and test("PASS:") and contains("head: " + $sha))] | length' \
            2>/dev/null)
    case "$n_summaries" in
        [1-9]*)
            rm -f "$common/after-report-pending/$branch" 2>/dev/null
            AFTER_REPORT_RESULT="posted"
            return 0
            ;;
    esac

    # mkdir the branch's OWN parent dir (not just after-report-pending/
    # itself) — a slash-bearing branch name like feat/foo needs
    # after-report-pending/feat/ to exist first, same as cr-pending's own
    # marker write (check-cr-before-push.sh).
    mkdir -p "$(dirname "$common/after-report-pending/$branch")" 2>/dev/null
    if printf 'pr=%s sha=%s\n' "$pr" "$pr_sha" >"$common/after-report-pending/$branch" 2>/dev/null; then
        AFTER_REPORT_RESULT="pending"
    else
        AFTER_REPORT_RESULT="pending-unrecorded"
    fi
    return 0
}

# The merge is pinned to the same resolved identity. No --delete-branch
# (HIMMEL-1679): every branch here is worktree-held, so gh's local-branch
# delete failed on every real merge and turned a landed merge into a
# cleanup-failed record; the remote head branch is deleted by the repo's own
# deleteBranchOnMerge setting, and the local worktree + branch are pruned
# after a CONFIRMED merge by prune_merged_worktree above (HIMMEL-1970) —
# best-effort, with `/clean` still the catch-all for whatever it defers.
merge_rc=0
merge_out=""
merge_out=$("$GH" pr merge "$pr_num" --repo "$nwo" --squash --match-head-commit "$sha" 2>&1) || merge_rc=$?
# A non-zero gh status is not authoritative: gh can merge remotely and then fail
# afterwards (network blip, post-merge bookkeeping). Re-read the remote PR state
# for EVERY non-zero status rather than keying correctness to one gh error
# phrase. MERGED at the certified sha/base is success because the requested
# operation landed. An unreadable state is explicitly indeterminate — never
# reinterpret an API failure as evidence that no merge ran.
if [ "$merge_rc" -ne 0 ]; then
    # HIMMEL-1697 (codex adversarial review, HIMMEL-1394 round 4): POLL, do not
    # single-shot. A gh failure at the same moment the request was accepted
    # server-side (queued behind branch protection, or a lost response) leaves
    # the PR OPEN for a while and then MERGED — one re-query would classify that
    # as REFUSED, a false negative on a merge that is still landing. A SHORTER
    # bound than the success path's: this path's common case is the
    # --match-head-commit head-moved abort, a definite non-merge that must not
    # sit here for a minute before its (safe) verdict.
    poll_merge_state 5
    post_state=$POLL_STATE
    post_head=$POLL_HEAD
    post_base=$POLL_BASE
    post_state_rc=$POLL_QUERY_RC
    if [ "$post_state" != "MERGED" ] && [ "$post_state_rc" -ne 0 ]; then
        echo "merge-on-green: gh exited $merge_rc and the PR state re-query failed (exit $post_state_rc) after polling — merge outcome is INDETERMINATE. Check the PR; do NOT retry until its state is known." >&2
        audit "INDETERMINATE reason=merge-state-query-failed gh_rc=$merge_rc state_query_rc=$post_state_rc repo=$nwo pr=#$pr_num sha=$sha"
        exit 15
    fi
    if [ "$post_state" = "MERGED" ] && [ "$post_head" != "$sha" ]; then
        # gh's own merge call FAILED, so --match-head-commit never confirmed
        # $sha — the MERGED state belongs to a commit a concurrent actor
        # merged in the gap before this re-query. Do not attribute it to $sha.
        echo "merge-on-green: PR is MERGED but the merged head ($post_head) does not match the certified sha ($sha) — a different commit merged concurrently; NOT crediting this run. Check the PR manually." >&2
        audit "REFUSED reason=merge-state-head-mismatch repo=$nwo pr=#$pr_num sha=$sha merged_head=$post_head gh_rc=$merge_rc"
        exit 15
    fi
    if [ "$post_state" = "MERGED" ] && [ "$post_base" != "$pr_base" ]; then
        # Same certified sha, but it landed on a DIFFERENT base than the one
        # guard 3b re-verified right before this merge attempt — a concurrent
        # retarget-then-merge (`gh pr edit --base` does not move the head).
        # --match-head-commit only pins the head, never the base, so this
        # recovery path needs its own base check exactly like guard 3b's.
        echo "merge-on-green: PR is MERGED at the certified sha but landed on base '$post_base', not the authorized '$pr_base' — a concurrent retarget-then-merge; NOT crediting this run. Check the PR manually." >&2
        audit "REFUSED reason=merge-state-base-mismatch repo=$nwo pr=#$pr_num sha=$sha authorized_base=$pr_base merged_base=$post_base gh_rc=$merge_rc"
        exit 15
    fi
    if [ "$post_state" = "MERGED" ]; then
        prune_merged_worktree "$head_branch" "$sha"
        record_after_report_pending_marker "$head_branch" "$pr_num" "$sha"
        audit "MERGED repo=$nwo pr=#$pr_num sha=$sha gate=check-ci:0 gh-exit=$merge_rc prune=$PRUNE_RESULT branch=$PRUNE_BRANCH marker=$MARKER_RESULT after-report=$AFTER_REPORT_RESULT cr=$CR_STATE"
        echo "merge-on-green: merged PR #$pr_num @ $sha (repo $nwo, squash); MERGED at the certified sha/base although gh exited $merge_rc: ${merge_out:-<no output>}"
        exit 0
    fi
    if [ "$post_state" = "OPEN" ]; then
        # HIMMEL-1697: still OPEN after the poll. That is NOT proof the merge was
        # refused — a request accepted server-side can sit queued past this
        # window — so report the outcome as unproven rather than claiming a
        # refusal. Same fail-closed exit; the difference is what the operator is
        # told to check. (If gh aborted on --match-head-commit, the head moved
        # since the gate and re-running the armed cycle is the fix.)
        echo "merge-on-green: gh exited $merge_rc and PR #$pr_num is still OPEN after polling — the merge outcome is INDETERMINATE (gh: ${merge_out:-<no output>}). It may have been accepted server-side and still be pending, or gh may have aborted on --match-head-commit because the head moved since the gate. Check the PR before doing anything else; do NOT retry via a different command path." >&2
        audit "INDETERMINATE reason=merge-pending-unconfirmed gh_rc=$merge_rc state=$post_state repo=$nwo pr=#$pr_num sha=$sha"
        exit 15
    fi
    merge_out="$merge_out [PR confirmed ${post_state:-<empty>}, not MERGED]"
fi
# CONFIRM the merge landed before reporting it (coderabbit): a zero rc from
# `gh pr merge` means "accepted", which under a merge queue can still be a PR
# sitting in the queue. exit 0 must mean MERGED, never merely accepted — so poll
# the remote until it reports MERGED, and refuse to claim success otherwise.
# (The cosmetic path above already confirmed MERGED; this re-query returns it
# immediately in that case.)
#
# Poll head+base too (codex-adv review, HIMMEL-1394), not just state: while
# queued, --match-head-commit's acceptance-time confirmation is no longer
# proof of what actually lands — a concurrent retarget or a different commit
# merging into the queue in that window must not be credited to this run,
# exactly like the failure-recovery path above.
if [ "$merge_rc" -eq 0 ]; then
    final_state=""
    final_head=""
    final_base=""
    # Track the LAST poll attempt's query status separately from final_state
    # (critic-panel codex-1, HIMMEL-1394): a query failure must not collapse
    # into the same "OPEN/not yet reflected" bucket as a genuine read, or a
    # persistent post-acceptance API failure gets misreported as merely
    # "unconfirmed" below instead of INDETERMINATE — the same distinction the
    # failure-recovery path above already makes on ITS OWN re-query failure.
    # A single transient failure mid-poll still just retries (final_state
    # stays empty, same as an OPEN/not-yet-reflected read); only the LAST
    # attempt's status decides indeterminate-vs-unconfirmed after the loop.
    final_query_rc=0
    poll_merge_state 30
    final_state=$POLL_STATE
    final_head=$POLL_HEAD
    final_base=$POLL_BASE
    final_query_rc=$POLL_QUERY_RC
    if [ "$final_state" != "MERGED" ] && [ "$final_query_rc" -ne 0 ]; then
        echo "merge-on-green: gh accepted the merge but the post-merge state re-query failed (exit $final_query_rc) after polling — merge outcome is INDETERMINATE. Check the PR; do NOT retry until its state is known." >&2
        audit "INDETERMINATE reason=merge-state-query-failed repo=$nwo pr=#$pr_num sha=$sha"
        exit 15
    fi
    if [ "$final_state" = "MERGED" ] && [ "$final_head" != "$sha" ]; then
        # gh's own merge call ACCEPTED $sha (queue admission), but the queue's
        # actual merge landed a different head — a concurrent actor merged in
        # the gap while this run was queued. Do not attribute it to $sha.
        echo "merge-on-green: PR #$pr_num reached MERGED but the merged head ($final_head) does not match the certified sha ($sha) — a different commit merged concurrently while queued; NOT crediting this run. Check the PR manually." >&2
        audit "REFUSED reason=merge-state-head-mismatch repo=$nwo pr=#$pr_num sha=$sha merged_head=$final_head"
        exit 15
    fi
    if [ "$final_state" = "MERGED" ] && [ "$final_base" != "$pr_base" ]; then
        # Same certified sha, but it landed on a DIFFERENT base than guard 3b
        # re-verified right before the merge attempt — a concurrent
        # retarget-then-merge while queued (`gh pr edit --base` does not move
        # the head, so --match-head-commit alone cannot catch this).
        echo "merge-on-green: PR #$pr_num reached MERGED at the certified sha but landed on base '$final_base', not the authorized '$pr_base' — a concurrent retarget while queued; NOT crediting this run. Check the PR manually." >&2
        audit "REFUSED reason=merge-state-base-mismatch repo=$nwo pr=#$pr_num sha=$sha authorized_base=$pr_base merged_base=$final_base"
        exit 15
    fi
    if [ "$final_state" = "MERGED" ]; then
        prune_merged_worktree "$head_branch" "$sha"
        record_after_report_pending_marker "$head_branch" "$pr_num" "$sha"
        audit "MERGED repo=$nwo pr=#$pr_num sha=$sha gate=check-ci:0 prune=$PRUNE_RESULT branch=$PRUNE_BRANCH marker=$MARKER_RESULT after-report=$AFTER_REPORT_RESULT cr=$CR_STATE"
        echo "merge-on-green: merged PR #$pr_num @ $sha (repo $nwo, squash). ${merge_out:-}"
        exit 0
    fi
    echo "merge-on-green: gh accepted the merge but PR #$pr_num is '${final_state:-<unreadable>}' (not MERGED) after polling — refusing to report an unconfirmed merge. Check the PR; do NOT retry via a different command path." >&2
    audit "REFUSED reason=merge-unconfirmed state=${final_state:-unreadable} repo=$nwo pr=#$pr_num sha=$sha"
    exit 15
fi

# A non-zero merge rc includes a --match-head-commit abort (head moved since the
# gate) — that is the safe path, not an error to route around. Do NOT retry via
# another command path (the classifier flags that as evasion).
echo "merge-on-green: merge failed (gh rc=$merge_rc): ${merge_out:-<no output>}" >&2
echo "merge-on-green: if the head moved since the gate, this is the --match-head-commit safeguard — re-run the armed cycle; do NOT retry via a different command path." >&2
audit "REFUSED reason=merge-failed gh_rc=$merge_rc repo=$nwo pr=#$pr_num sha=$sha"
exit 15
