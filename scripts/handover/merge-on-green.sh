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
# Exit codes:
#   0   merged (or --dry-run passed, or no PR — nothing to merge)
#   10  not opted in (ARMAUTOMERGE unset/false) — refused
#   11  required tool missing (gh / git)
#   12  not a private github repo (public or undeterminable), or the PR's base
#       branch is not the repo's default branch (undeterminable counts too) —
#       refused fail-closed. Also returned by the pre-merge re-verification of
#       the same binding (see above) if the base changed after the gate.
#   13  cannot resolve the PR or its head SHA — refused
#   14  check-ci gate not green (unresolved threads / red CI / changes requested)
#   15  merge failed (gh error, incl. a --match-head-commit head-moved abort, a
#       branch-delete error where the PR did NOT reach MERGED, or a gh-accepted
#       merge the PR never confirmed as MERGED)
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
meta=$(gh_pr_view --json state,url,number,headRefOid,baseRefName \
        --jq '"\(.state)|\(.url)|\(.number)|\(.headRefOid)|\(.baseRefName)"' 2>&1) || meta_rc=$?
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
sha=${_rest%%|*}; pr_base=${_rest#*|}
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
if [ ! -f "$CHECK_CI" ]; then
    echo "merge-on-green: check-ci.sh not found at $CHECK_CI — cannot certify green. Refusing." >&2
    audit "REFUSED reason=no-check-ci repo=$nwo pr=#$pr_num"
    exit 14
fi
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
fresh_base=$(gh_pr_view --json baseRefName --jq '.baseRefName' 2>/dev/null || true)
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
    audit "DRYRUN would-merge repo=$nwo pr=#$pr_num sha=$sha gate=check-ci:0"
    echo "merge-on-green: [dry-run] gates passed — would squash-merge PR #$pr_num @ $sha (repo $nwo). Not merging."
    exit 0
fi

# Record the merge INTENT before executing (coderabbit): a crash or lost-record
# between here and the MERGED line still leaves a durable trace of what was
# attempted on which certified SHA. The write is CHECKED, not assumed: the
# preflight above proves the sink was writable a moment ago, but a sink that
# fails right here (disk full, removed underneath us) must abort the merge —
# the durable intent record is a precondition, not a courtesy.
if ! audit "MERGING repo=$nwo pr=#$pr_num sha=$sha gate=check-ci:0"; then
    echo "merge-on-green: could not record the MERGING audit record at $(_audit_sink) — refusing (an unauditable merge must not proceed)." >&2
    exit 16
fi

# Re-query the PR's state, scoped to the selector. Used by both post-merge
# confirmations below — an unreadable state prints empty (treated as unconfirmed).
pr_state_now() {
    if [ -n "$selector" ]; then
        "$GH" pr view "$selector" --json state --jq .state 2>/dev/null || true
    else
        "$GH" pr view --json state --jq .state 2>/dev/null || true
    fi
}

merge_rc=0
merge_out=""
if [ -n "$selector" ]; then
    merge_out=$("$GH" pr merge "$selector" --squash --delete-branch --match-head-commit "$sha" 2>&1) || merge_rc=$?
else
    merge_out=$("$GH" pr merge --squash --delete-branch --match-head-commit "$sha" 2>&1) || merge_rc=$?
fi
# Cosmetic held-worktree local branch-delete failure — the REMOTE PR merged
# anyway (deleteBranchOnMerge also removes the remote head branch). An armed
# chain merges from INSIDE its own worktree, so this is the expected shape here.
# But "branch cleanup failed" does NOT by itself prove the merge landed
# (coderabbit): CONFIRM the remote reached MERGED before accepting success —
# never infer a merge from the cleanup error alone. A real merge failure (e.g. a
# --match-head-commit head-moved abort) errors BEFORE the branch-delete, so its
# output never matches this phrase.
if [ "$merge_rc" -ne 0 ] && printf '%s' "$merge_out" | grep -qE "is already used by worktree"; then
    post_state=$(pr_state_now)
    if [ "$post_state" = "MERGED" ]; then
        merge_rc=0
        merge_out="$merge_out [local branch-delete cosmetic-fail; PR confirmed MERGED]"
    else
        echo "merge-on-green: branch-delete error but PR state is '${post_state:-<unreadable>}' (not MERGED) — treating as FAILED." >&2
        merge_out="$merge_out [PR state '${post_state:-<unreadable>}' != MERGED after branch-delete error]"
    fi
fi
# CONFIRM the merge landed before reporting it (coderabbit): a zero rc from
# `gh pr merge` means "accepted", which under a merge queue can still be a PR
# sitting in the queue. exit 0 must mean MERGED, never merely accepted — so poll
# the remote until it reports MERGED, and refuse to claim success otherwise.
# (The cosmetic path above already confirmed MERGED; this re-query returns it
# immediately in that case.)
if [ "$merge_rc" -eq 0 ]; then
    final_state=""
    tries=0
    while [ "$tries" -lt 30 ]; do
        final_state=$(pr_state_now)
        case "$final_state" in
            MERGED) break ;;
            OPEN|'') ;;   # queued / not yet reflected — keep waiting
            *) break ;;   # CLOSED or unexpected — stop; handled below
        esac
        tries=$((tries + 1))
        [ "$tries" -lt 30 ] && sleep 2
    done
    if [ "$final_state" = "MERGED" ]; then
        audit "MERGED repo=$nwo pr=#$pr_num sha=$sha gate=check-ci:0"
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
