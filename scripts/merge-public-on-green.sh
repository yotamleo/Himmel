#!/usr/bin/env bash
# merge-public-on-green.sh — sanctioned auto-merge chokepoint for the PUBLIC
# repo, invoked ONLY by the Telegram bridge's SHA-bound /mergepub command.
#
# HIMMEL-1213. Pairs with scripts/handover/merge-on-green.sh (HIMMEL-1042, the
# PRIVATE chokepoint) but is a DELIBERATELY SEPARATE script: merge-on-green.sh's
# private-only guard is a safety boundary, and a flag that inverts a safety
# boundary is the failure mode this design explicitly avoids — no shared
# "which repo class" switch. This script instead PINS to one public repo.
#
# Authorization model (HIMMEL-1213 design §3): the operator sends a typed,
# non-forwarded `/mergepub <pr> <sha12>` from Telegram; the TRUSTED BRIDGE
# (scripts/telegram/router.ts -> auto-action.ts -> auto-action.sh) — never a
# Claude agent — parses it and invokes this script directly with the PR number
# and the operator-approved head SHA. There is no separate opt-in env var (cf.
# merge-on-green.sh's ARMAUTOMERGE): the authorization IS the bridge's own
# TELEGRAM_AUTO_ACTIONS allow-list + operator-identity check, already enforced
# before this script is ever invoked. No allow-rule for this script (or a
# public `gh pr merge`) is added anywhere — an agent can reach it only through
# the broad `Bash(bash scripts/*)` rule, which gate 0 below refuses on sight.
#
# Usage: merge-public-on-green.sh <pr> <sha> [--dry-run]
#   pr         PR number (required)
#   sha        operator-approved head SHA, >=12 hex chars (required; the ready
#              report emits it — copy-paste, so a long value costs nothing)
#   --dry-run  run every gate, print the intended merge, then STOP (no merge)
#
# Exit codes:
#   0   merged (or --dry-run passed every gate)
#   1   bad usage (missing/malformed args)
#   10  cannot resolve the PR's repo, or it is not the pinned public repo
#   11  required tool missing (gh / git)
#   12  PR is not OPEN (closed/merged/not found), incl. at the pre-merge
#       re-verify — refused
#   13  cannot resolve PR metadata (auth/network) — refused
#   14  PR base is not the repo's default branch — initial gate OR the
#       immediately-pre-merge re-verify (HIMMEL-1080 retarget-race lesson,
#       ported verbatim: a base can be changed without moving the head, so
#       `--match-head-commit` alone would not catch a mid-wait retarget)
#   15  head SHA mismatch — the operator-supplied SHA does not prefix-match
#       the PR's actual head (headRefOid), at the initial read OR the
#       pre-merge re-verify — "head moved", never merge
#   16  check-ci gate not green (CI red / unresolved threads / changes
#       requested / HIMMEL-1126 body findings) — the ONLY pass is exit 0
#   17  audit sink not writable, or the MERGING record could not be written
#       — an unauditable merge must not proceed
#   18  merge failed (gh error, incl. a --match-head-commit head-moved abort
#       caught at the actual merge call, or an accepted merge that never
#       confirmed MERGED)
#   19  refused: invoked from inside a Claude Code session (CLAUDECODE set)
#       — defense-in-depth; the bridge spawns this script's env WITHOUT that
#       marker, so this can only fire on an agent-initiated call
#
# Environment:
#   CR_PUBLIC_REPO             Pinned public repo, owner/name. Default
#                               yotamleo/Himmel — the SAME env var
#                               .claude/commands/cr-public.md uses, so one
#                               override covers both the CR-babysit and the
#                               merge chokepoint.
#   MERGE_PUBLIC_ON_GREEN_LOG   Audit-log path override. Default:
#                               "$(git rev-parse --git-dir)/merge-public-on-green.log".
#
# GATE INTEGRITY: `gh` and `check-ci.sh` are NOT environment-overridable — a
# contaminated/inherited launching environment must not be able to swap the
# merge gate or the SHA pin for a permissive stand-in (same rationale as
# merge-on-green.sh). Tests run a COPY of the script tree with a stub `gh`
# FIRST on PATH — never a caller-settable override.
#
# Accepted env seams (both require control of the BRIDGE's launching env, which
# is already game-over — named here for honesty, per the HIMMEL-1213 gate review):
#   * PATH itself resolves `gh` (line: `GH="gh"` + `command -v`). "gh is not
#     overridable" holds only modulo PATH — auto-action.sh strips the bot token
#     from the child env but inherits PATH; a hardened child PATH is a follow-up.
#   * CR_PUBLIC_REPO redirects the WHOLE chokepoint to any repo the operator's
#     credential can admin-merge; every gate then applies to THAT repo. Shared
#     deliberately with cr-public.md so one override covers both — so "pinned"
#     means "pinned per the bridge's env", not "hardcoded". MERGE_PUBLIC_ON_GREEN_LOG
#     can only VOID the audit (e.g. /dev/null) or append arbitrarily — it can
#     never weaken a merge gate (unwritable -> exit 17).
set -uo pipefail
# NOT set -e — this script inspects sub-call exit codes explicitly and must
# fail CLOSED with its own codes, never abort mid-gate.

# 0. Defense-in-depth agent refusal (design gate 7), checked FIRST — before
# any argument parsing, cheapest possible refusal, no API calls. This is what
# backstops the fact that no allow-rule for this script (or a public
# `gh pr merge`) is ever added: an agent reaching this script only through the
# broad `Bash(bash scripts/*)` rule self-refuses right here, even before the
# auto-mode classifier weighs in.
# NOTE (defense-in-depth, not the boundary): `env -u CLAUDECODE bash …` or
# `CLAUDECODE= bash …` clears the marker and sails past this check — but that
# changed command shape no longer prefix-matches `Bash(bash scripts/*)`, so it
# falls to the classifier/prompt instead of auto-approving. The BOUNDARY is
# "no allow-rule exists"; this gate is the cheap backstop behind it.
if [ -n "${CLAUDECODE:-}" ]; then
    echo "merge-public-on-green: refusing — invoked from inside a Claude Code session (CLAUDECODE set). This chokepoint is bridge-only; the public merge stays operator-authorized via Telegram /mergepub, never agent-invoked." >&2
    exit 19
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="gh"
CHECK_CI="$SCRIPT_DIR/check-ci.sh"
REPO="${CR_PUBLIC_REPO:-yotamleo/Himmel}"

pr=""
sha=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "merge-public-on-green: unknown option: $1" >&2; exit 1 ;;
        *)
            if [ -z "$pr" ]; then pr="$1"
            elif [ -z "$sha" ]; then sha="$1"
            else echo "merge-public-on-green: too many arguments (unexpected '$1')" >&2; exit 1
            fi
            shift ;;
    esac
done

if [ -z "$pr" ] || [ -z "$sha" ]; then
    echo "merge-public-on-green: usage: merge-public-on-green.sh <pr> <sha> [--dry-run]" >&2
    exit 1
fi
case "$pr" in
    ''|*[!0-9]*) echo "merge-public-on-green: bad PR number: '$pr'" >&2; exit 1 ;;
esac
# SHA shape: 12-40 lowercase hex. The 12-hex floor (48 bits, was 7=28 bits)
# blunts prefix-grinding — the agent may push public fix-commits, so a 7-hex
# prefix could be ground (~2^28, seconds) to a malicious commit sharing the
# operator-approved prefix, passing both SHA gates AND --match-head-commit even
# against a diligent operator (HIMMEL-1213 Fable gate-review). Anchored `case` —
# NOT `grep -Eq '^…$'`, which matches if ANY line of a multi-line value matches
# (audit-log line-injection: a `$'sha\nFAKE'` would flow into audit() below).
# case matches the WHOLE string, so an embedded newline is a non-hex char here.
case "$sha" in
    *[!0-9a-f]*) echo "merge-public-on-green: bad SHA (non-hex or multi-line): '$sha'" >&2; exit 1 ;;
esac
if [ "${#sha}" -lt 12 ] || [ "${#sha}" -gt 40 ]; then
    echo "merge-public-on-green: bad SHA (expected 12-40 lowercase hex chars): '$sha'" >&2
    exit 1
fi

command -v git >/dev/null 2>&1 || { echo "merge-public-on-green: required tool 'git' not on PATH" >&2; exit 11; }
command -v "$GH" >/dev/null 2>&1 || { echo "merge-public-on-green: required tool 'gh' not on PATH" >&2; exit 11; }

# Audit sink resolution + writer — same shape as merge-on-green.sh (HIMMEL-1042).
_audit_sink() {
    if [ -n "${MERGE_PUBLIC_ON_GREEN_LOG:-}" ]; then printf '%s' "$MERGE_PUBLIC_ON_GREEN_LOG"; return; fi
    local gd; gd=$(git rev-parse --git-dir 2>/dev/null || true)
    [ -n "$gd" ] && printf '%s' "$gd/merge-public-on-green.log"
}
audit() {
    local line ts logf rc=0
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')
    line="$ts merge-public-on-green $*"
    echo "$line"
    logf=$(_audit_sink)
    if [ -n "$logf" ]; then
        printf '%s\n' "$line" >>"$logf" 2>/dev/null || {
            echo "merge-public-on-green: WARNING — could not write the audit log at $logf" >&2
            rc=1
        }
    fi
    return "$rc"
}
audit_preflight() {
    local logf; logf=$(_audit_sink)
    # No durable sink resolvable (not in a git repo AND no MERGE_PUBLIC_ON_GREEN_LOG
    # override) → REFUSE. Was `return 0` (proceed with stdout-only audit), a fail-open
    # gap: an unauditable merge must not proceed (design gate 5 / codex CR-3). The
    # legitimate bridge runs from a git checkout, so a resolvable sink is the norm.
    [ -z "$logf" ] && return 1
    ( printf '' >>"$logf" ) 2>/dev/null && return 0
    return 1
}

# gh helper scoped to the pinned public repo — NEVER cwd-derived (design gate
# 1). This script is invoked from the bridge's HIMMEL_REPO cwd, which is
# typically the PRIVATE checkout, so every gh call below is explicitly
# --repo-scoped rather than relying on the current directory's git remote.
gh_pr_view() { "$GH" pr view "$pr" --repo "$REPO" "$@"; }

# 1. Repo pin — resolve PR metadata scoped to the pinned repo; if PR #<pr>
# doesn't exist THERE, gh errors here (refuse, never guess another repo).
meta=""
meta_rc=0
meta=$(gh_pr_view --json state,url,number,headRefOid,baseRefName \
        --jq '"\(.state)|\(.url)|\(.number)|\(.headRefOid)|\(.baseRefName)"' 2>&1) || meta_rc=$?
if [ "$meta_rc" -ne 0 ]; then
    if printf '%s' "$meta" | grep -qi 'no pull requests found\|could not resolve to a PullRequest'; then
        echo "merge-public-on-green: PR #$pr not found in $REPO — refusing (nothing to merge)." >&2
        audit "REFUSED reason=no-open-pr repo=$REPO pr=#$pr"
        exit 12
    fi
    echo "merge-public-on-green: could not query PR #$pr in $REPO (auth/network?): ${meta:-<no output>} — refusing. Re-run." >&2
    audit "REFUSED reason=pr-query-failed repo=$REPO pr=#$pr"
    exit 13
fi
pr_state=${meta%%|*}; _rest=${meta#*|}
pr_url=${_rest%%|*}; _rest=${_rest#*|}
pr_num=${_rest%%|*}; _rest=${_rest#*|}
head_sha=${_rest%%|*}; pr_base=${_rest#*|}

# Defense-in-depth: the API's OWN reported number should equal what we asked
# for (we queried BY this exact pr). A mismatch would mean gh (or a stubbed/
# contaminated PATH) answered for a DIFFERENT PR than requested — refuse
# rather than silently proceeding against the wrong target.
if [ "$pr_num" != "$pr" ]; then
    echo "merge-public-on-green: gh answered for PR #$pr_num, not the requested #$pr — refusing." >&2
    audit "REFUSED reason=pr-number-mismatch requested=#$pr got=#$pr_num repo=$REPO"
    exit 13
fi

# The PR's OWN url must resolve to the pinned repo — never trust the --repo
# flag alone (mirrors merge-on-green's codex-1 fix: the repo binding comes
# from the PR's own identity, not the query args, so a gh config/alias
# redirect can't silently widen the target).
case "$pr_url" in
    https://github.com/*/pull/*) ;;
    *)
        echo "merge-public-on-green: cannot resolve PR #$pr's repo from its URL ('${pr_url:-<empty>}') — refusing." >&2
        audit "REFUSED reason=bad-pr-url url=${pr_url:-empty} pr=#$pr"
        exit 10 ;;
esac
owner=$(printf '%s' "$pr_url" | sed -n 's|^https://[^/]*/\([^/]*\)/.*|\1|p')
name=$(printf '%s' "$pr_url"  | sed -n 's|^https://[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
nwo="$owner/$name"
if [ -z "$owner" ] || [ -z "$name" ]; then
    echo "merge-public-on-green: cannot parse owner/repo from '$pr_url' — refusing." >&2
    audit "REFUSED reason=bad-pr-url url=$pr_url pr=#$pr"
    exit 10
fi
if [ "$nwo" != "$REPO" ]; then
    echo "merge-public-on-green: PR #$pr resolves to $nwo, not the pinned repo $REPO — refusing. This lever only merges PRs in $REPO." >&2
    audit "REFUSED reason=wrong-repo pr_repo=$nwo pinned_repo=$REPO pr=#$pr"
    exit 10
fi
if [ -z "$head_sha" ]; then
    echo "merge-public-on-green: cannot read PR #$pr's head SHA — cannot certify a merge target. Re-run." >&2
    audit "REFUSED reason=no-head-sha repo=$REPO pr=#$pr"
    exit 13
fi

# 2. PR must be OPEN.
case "$pr_state" in
    OPEN) ;;
    *)
        echo "merge-public-on-green: PR #$pr is ${pr_state:-<unknown>} (not OPEN) — nothing to merge." >&2
        audit "REFUSED reason=no-open-pr state=${pr_state:-unknown} repo=$REPO pr=#$pr"
        exit 12 ;;
esac

# 2b. Base-branch gate — PR base must equal the repo's default branch. Fail
# CLOSED on an undeterminable default branch, never guess (HIMMEL-1080 lesson).
default_branch=$("$GH" repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name // ""' 2>/dev/null || true)
if [ -z "$pr_base" ] || [ -z "$default_branch" ]; then
    echo "merge-public-on-green: cannot determine PR #$pr's base ('${pr_base:-<empty>}') or $REPO's default branch ('${default_branch:-<empty>}') — refusing. Re-run." >&2
    audit "REFUSED reason=base-branch-undeterminable pr_base=${pr_base:-empty} default_branch=${default_branch:-empty} repo=$REPO pr=#$pr"
    exit 14
fi
if [ "$pr_base" != "$default_branch" ]; then
    echo "merge-public-on-green: PR #$pr targets '$pr_base', not $REPO's default branch '$default_branch' — refusing." >&2
    audit "REFUSED reason=wrong-base-branch pr_base=$pr_base authorized_branch=$default_branch repo=$REPO pr=#$pr"
    exit 14
fi

# 3. Head identity — the operator-supplied SHA must PREFIX-match the PR's
# actual head (headRefOid). Mismatch = refuse, "head moved", never merge —
# this is the SHA-pinned TOCTOU guarantee the design's §3 chain of identity
# depends on: ship's byte-verify proves branch==private head -> check-ci
# certifies that head CR-clean+CI-green -> the ready report names that head ->
# the operator's /mergepub echoes it -> THIS gate refuses any drift.
case "$head_sha" in
    "$sha"*) ;;
    *)
        echo "merge-public-on-green: PR #$pr's head is $head_sha, which does not match the operator-approved SHA $sha — head moved. Refusing; request a fresh ready report." >&2
        audit "REFUSED reason=head-moved approved_sha=$sha actual_head=$head_sha repo=$REPO pr=#$pr"
        exit 15 ;;
esac

# 4. Green gate — check-ci.sh exit 0 is the ONLY pass (CI green + zero
# unresolved threads + no changes-requested + the HIMMEL-1126 body/outside-
# diff gate). check-ci.sh resolves its selector via cwd's git remote when
# given a bare PR number, but this script runs from the bridge's HIMMEL_REPO
# cwd (typically the PRIVATE checkout) — so it MUST be pointed at the PR by
# its own full URL, which is cwd-independent, never the bare number.
if [ ! -f "$CHECK_CI" ]; then
    echo "merge-public-on-green: check-ci.sh not found at $CHECK_CI — cannot certify green. Refusing." >&2
    audit "REFUSED reason=no-check-ci repo=$REPO pr=#$pr"
    exit 16
fi
ci_rc=0
bash "$CHECK_CI" "$pr_url" || ci_rc=$?
if [ "$ci_rc" -ne 0 ]; then
    echo "merge-public-on-green: check-ci gate did not pass (exit $ci_rc) — not merging. Address the gate, then re-send /mergepub." >&2
    audit "REFUSED reason=gate-not-green gate=check-ci:$ci_rc repo=$REPO pr=#$pr sha=$sha"
    exit 16
fi

# 4b. Re-verify FRESH, immediately before merging (HIMMEL-1080 retarget-race
# lesson, ported verbatim): check-ci.sh above WATCHES CI and can block for
# minutes; gh allows retargeting a PR's base without moving its head, so the
# base checked at gate 2b can go stale during that window — `--match-head-
# commit` only pins the HEAD, so a stale base would still land the certified
# SHA into a newly-selected base. Re-query state/base/head fresh right before
# merging; never reuse pr_state/pr_base/head_sha captured above.
fresh=$(gh_pr_view --json state,baseRefName,headRefOid \
        --jq '"\(.state)|\(.baseRefName)|\(.headRefOid)"' 2>/dev/null || true)
fresh_state=${fresh%%|*}; _rest=${fresh#*|}
fresh_base=${_rest%%|*}; fresh_head=${_rest#*|}
if [ "$fresh_state" != "OPEN" ]; then
    echo "merge-public-on-green: PR #$pr is no longer OPEN ('${fresh_state:-<unknown>}') right before merging — refusing." >&2
    audit "REFUSED reason=no-open-pr-premerge state=${fresh_state:-unknown} repo=$REPO pr=#$pr"
    exit 12
fi
# INTENTIONAL divergence from merge-on-green.sh (which re-reads the default
# branch fresh here): we compare against `default_branch` captured BEFORE the
# CI wait. If the repo's default were renamed/switched mid-wait while the PR
# base stayed put, this refuses rather than following the moved default — it
# pins to what the operator saw at report time, which is STRICTER against an
# attacker-moved default, not weaker.
if [ -z "$fresh_base" ] || [ "$fresh_base" != "$default_branch" ]; then
    echo "merge-public-on-green: PR #$pr's base changed since the gate (was '$pr_base', now '${fresh_base:-<empty>}', default '$default_branch') — refusing." >&2
    audit "REFUSED reason=base-branch-changed pr_base_at_gate=$pr_base pr_base_now=${fresh_base:-empty} default_branch=$default_branch repo=$REPO pr=#$pr"
    exit 14
fi
case "$fresh_head" in
    "$sha"*) ;;
    *)
        echo "merge-public-on-green: PR #$pr's head changed since the gate (was $head_sha, now ${fresh_head:-<empty>}) — refusing. Head moved during the CI wait; request a fresh ready report." >&2
        audit "REFUSED reason=head-moved-premerge approved_sha=$sha actual_head=${fresh_head:-empty} repo=$REPO pr=#$pr"
        exit 15 ;;
esac

# 4c. Fresh REVIEW-STATE re-check, immediately before merging (HIMMEL-1213
# codex-adv). check-ci at gate 4 certified reviews, but a reviewer can request
# changes or open an unresolved thread AFTER that returned WITHOUT moving the
# head — `--match-head-commit` would still pass and `--admin` would bypass the
# branch protection that catches it, merging code whose approval was effectively
# revoked. Re-run ONLY the thread / changes-requested gate (`--threads-only`, no
# CI re-watch) fresh here; the residual window is the single final round-trip
# (irreducible, same class as the head/base races above). Same URL selector +
# exit-16 refusal as gate 4.
threads_rc=0
bash "$CHECK_CI" "$pr_url" --threads-only || threads_rc=$?
if [ "$threads_rc" -ne 0 ]; then
    echo "merge-public-on-green: review state changed since the gate (check-ci --threads-only exit $threads_rc: unresolved thread / changes-requested) — refusing. Re-send /mergepub after it clears." >&2
    audit "REFUSED reason=review-blocked-premerge gate=threads-only:$threads_rc repo=$REPO pr=#$pr sha=$sha"
    exit 16
fi

# 5. Audit preflight — an unauditable merge must not proceed. Runs after every
# gate (so a gate refusal short-circuits first) and before the dry-run exit /
# the real merge.
if ! audit_preflight; then
    logf=$(_audit_sink)
    if [ -z "$logf" ]; then
        echo "merge-public-on-green: no durable audit sink resolvable (not in a git repo and MERGE_PUBLIC_ON_GREEN_LOG unset) — refusing (an unauditable merge must not proceed). Set MERGE_PUBLIC_ON_GREEN_LOG to a writable path." >&2
        audit "REFUSED reason=audit-sink-unresolvable repo=$REPO pr=#$pr sha=$sha"
    else
        echo "merge-public-on-green: audit sink '$logf' is not writable — refusing (an unauditable merge must not proceed). Set MERGE_PUBLIC_ON_GREEN_LOG to a writable path." >&2
        audit "REFUSED reason=audit-sink-unwritable sink=$logf repo=$REPO pr=#$pr sha=$sha"
    fi
    exit 17
fi

if [ "$DRY_RUN" -eq 1 ]; then
    audit "DRYRUN would-merge repo=$REPO pr=#$pr sha=$sha gate=check-ci:0"
    echo "merge-public-on-green: [dry-run] gates passed — would squash-merge PR #$pr @ $fresh_head (repo $REPO). Not merging."
    exit 0
fi

# Record the merge INTENT before executing — a crash or lost record between
# here and the MERGED line still leaves a durable trace of what was attempted
# on which certified SHA.
if ! audit "MERGING repo=$REPO pr=#$pr sha=$sha gate=check-ci:0"; then
    echo "merge-public-on-green: could not record the MERGING audit record at $(_audit_sink) — refusing (an unauditable merge must not proceed)." >&2
    exit 17
fi

pr_state_now() { "$GH" pr view "$pr" --repo "$REPO" --json state --jq .state 2>/dev/null || true; }

# 6. Atomic merge — pinned to the freshly re-verified head (gate 4b), which
# already proved it prefix-matches the operator-approved SHA. `--match-head-
# commit` is the final, gh-enforced backstop: it aborts if the head moved in
# the one unavoidable round-trip between the fresh read and this call (the
# residual, irreducible TOCTOU window — see merge-on-green.sh's header for the
# same lesson). `--admin` is correct here: public main is protected and the
# operator's own admin credential is entitled to bypass it (cr-public.md).
merge_rc=0
merge_out=$("$GH" pr merge "$pr" --repo "$REPO" --squash --admin --match-head-commit "$fresh_head" 2>&1) || merge_rc=$?
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
        audit "MERGED repo=$REPO pr=#$pr sha=$sha gate=check-ci:0"
        echo "merge-public-on-green: merged PR #$pr @ $fresh_head (repo $REPO, squash). ${merge_out:-}"
        exit 0
    fi
    echo "merge-public-on-green: gh accepted the merge but PR #$pr is '${final_state:-<unreadable>}' (not MERGED) after polling — refusing to report an unconfirmed merge. Check the PR; do NOT retry via a different command path." >&2
    audit "REFUSED reason=merge-unconfirmed state=${final_state:-unreadable} repo=$REPO pr=#$pr sha=$sha"
    exit 18
fi

# A non-zero merge rc includes a --match-head-commit abort (head moved since
# the gate) — that is the safe path, not an error to route around.
echo "merge-public-on-green: merge failed (gh rc=$merge_rc): ${merge_out:-<no output>}" >&2
echo "merge-public-on-green: if the head moved since the gate, this is the --match-head-commit safeguard — request a fresh ready report; do NOT retry via a different command path." >&2
audit "REFUSED reason=merge-failed gh_rc=$merge_rc repo=$REPO pr=#$pr sha=$sha"
exit 18
