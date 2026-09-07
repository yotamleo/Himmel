#!/usr/bin/env bash
# scripts/console/base-status.sh — HIMMEL-2383 base verification.
#
# Console ruling 66: arm a leg on a fence only when every merged PR that
# touched it already carries its after-report SUMMARY comment. This lists the
# merged PRs on the repo's default branch that touched a given fence and are
# NOT clean: PENDING (no after-report SUMMARY comment yet) or RED (a SUMMARY
# comment with a nonzero FAIL count). A clean PR is not printed — this is a
# "what's blocking the arm" list, not a full status dump.
#
# The after-report this looks for is the LITERAL block
# scripts/ci/run-shell-tests.sh posts (HIMMEL-2383 item 4): a comment
# containing '== Summary ==', a 'PASS:' line, a 'head: <sha>' line
# matching the PR's CURRENT headRefOid exactly (a report from an earlier
# revision does not certify the head that actually merged), AND a
# 'scope: <scan-root>' line that IS this fence or an ancestor of it (round-12
# CR finding codex-1 — a scoped run's clean PASS must not be read as
# certifying an unrelated or narrower fence; checked per touched fence,
# round-13 CR finding codex-1 — a report can cover one of a PR's touched
# fences but not another). A TRUNCATED report (budget-expired run), a
# CHANGED-SINCE report (conditionally filtered suites, round-13 CR finding
# codex-2), or one whose FAIL count cannot be parsed is never read as clean
# either. NOT author-bound (tried and reverted — see the
# comment at the summary match below): this repo's multi-session,
# multi-machine architecture means the poster and the checker need not share
# a gh identity, so author-binding would silently and permanently reject
# legitimate reports; residual risk (another repo collaborator forging the
# exact markers + head) is accepted on this PRIVATE, access-controlled repo.
# Prose that merely TALKS about test results (a hand-written "80/80 pass"
# note, a CodeRabbit review) does not count — PENDING means "the
# machine-posted after-report isn't here yet", not "nobody mentioned tests"
# (HIMMEL-2320: a zero here is real evidence of a gap, not a detection miss
# — verified live against #2085/#2090/#2092, none of which carry the
# literal block yet).
#
# Usage: base-status.sh <fence-path> [<fence-path> ...]
#   fence-path   a repo-relative dir (matches itself and everything under it)
#                or file path, e.g. scripts/hooks or scripts/ci/run-shell-tests.sh
#
# Output (stdout), one line per non-clean PR, greppable:
#   PENDING PR <n> fence=<path> head=<sha>: no after-report SUMMARY comment
#   RED PR <n> fence=<path> head=<sha> FAIL=<n>
# On a query error (stderr): QUERY-ERROR PR <n>: <detail>
#
# Exit: 0 if every PR was queried successfully (whatever PENDING/RED lines
# resulted — that is data, not a failure); nonzero if any PR hit a
# QUERY-ERROR, the merged-PR list may be truncated (HIMMEL-2383 CR: cannot
# certify "every merged PR" was checked), or the repo/default-branch could
# not be resolved (fail-closed, same posture as sweep-cr-threads.sh).
#
# Env: GH_CMD overrides the `gh` binary (test seam, matches
# scripts/console/sweep-cr-threads.sh). GH_TIMEOUT_SECS bounds each `gh`
# call (default 30s) so an unattended arm can't hang indefinitely on a
# GitHub network stall (CodeRabbit round on PR #2099); skipped when
# `timeout` isn't on PATH rather than failing the call outright.
set -uo pipefail

_gh() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "${GH_TIMEOUT_SECS:-30}" "${GH_CMD:-gh}" "$@"
    else
        "${GH_CMD:-gh}" "$@"
    fi
}

command -v jq >/dev/null 2>&1 || { echo "base-status: jq is required" >&2; exit 1; }

if [ "$#" -eq 0 ]; then
    echo "base-status: usage: base-status.sh <fence-path> [<fence-path> ...]" >&2
    exit 1
fi

# Strip a trailing slash from every fence arg (HIMMEL-2383 CR finding
# codex-4, round 6) — _touches_fence matches `.path == $f` or
# `startswith($f + "/")`; a caller-supplied "scripts/hooks/" (trailing
# slash, a natural way to spell a directory) would match NEITHER
# ("scripts/hooks/" != "scripts/hooks", and startswith("scripts/hooks//")
# never matches a real single-slash path) and silently certify everything
# under it clean. Word-split rebuild (fence paths carry no spaces, same
# assumption arm-resume.sh's own space-separated fence: forwarding makes).
_fence_args=""
for _f in "$@"; do _fence_args="$_fence_args ${_f%/}"; done
# shellcheck disable=SC2086
set -- $_fence_args
unset _fence_args _f

default_branch=$(_gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name // ""' 2>/dev/null) || {
    echo "base-status: 'gh repo view' failed — cannot resolve the default branch, aborting (fail-closed)" >&2
    exit 1
}
[ -n "$default_branch" ] || { echo "base-status: could not determine the repo default branch — aborting" >&2; exit 1; }

# Scope by RECENT merge date, not a raw --limit alone (HIMMEL-2383 CR
# finding codex-1, round 2): an unfiltered --limit 200 hits its cap on ANY
# repo with >=200 merged PRs EVER — this repo already does — so every fence
# would permanently fail certification regardless of its own history. A
# LOOKBACK_DAYS window scopes the query to "recent merge traffic" (this
# ticket's actual concern) instead of cumulative repo history; PR_LIST_LIMIT
# stays as a safety net that only fires on a genuinely exceptional volume
# (>200 merges to $default_branch within the window), not as the everyday
# case. python3 mirrors the portable date-math convention used elsewhere in
# this codebase (e.g. arm-resume.sh's _epoch_hhmm) since GNU `date -d` and
# BSD `date -v` are not compatible; when python3 is unavailable, fall back
# to an unscoped query rather than fail-closed on a working host.
#
# Residual (HIMMEL-2383 CR finding codex-2, round 3, deferred -> HIMMEL-2402):
# a PR merged BEFORE this window that still lacks its after-report is
# silently excluded from the sweep. Deliberate scope tradeoff, not
# reopened here — the ticket's concern is "safe to build on TODAY", and an
# after-report gap that old is unlikely to reflect current suite health.
LOOKBACK_DAYS="${BASE_STATUS_LOOKBACK_DAYS:-30}"
PR_LIST_LIMIT=200
since_date=$(python3 -c \
    'import datetime,sys; print((datetime.date.today() - datetime.timedelta(days=int(sys.argv[1]))).isoformat())' \
    "$LOOKBACK_DAYS" 2>/dev/null)
if [ -n "$since_date" ]; then
    prs_json=$(_gh pr list --state merged --base "$default_branch" --search "merged:>=$since_date" \
        --limit "$PR_LIST_LIMIT" --json number,headRefOid,files 2>&1) || {
        echo "base-status: 'gh pr list' failed — aborting (fail-closed): $prs_json" >&2
        exit 1
    }
else
    echo "base-status: could not compute the ${LOOKBACK_DAYS}-day lookback date (python3 missing?) — falling back to an unscoped merged-PR query, limit $PR_LIST_LIMIT" >&2
    prs_json=$(_gh pr list --state merged --base "$default_branch" --limit "$PR_LIST_LIMIT" \
        --json number,headRefOid,files 2>&1) || {
        echo "base-status: 'gh pr list' failed — aborting (fail-closed): $prs_json" >&2
        exit 1
    }
fi

# Known residual (HIMMEL-2383 CR round 4, deferred -> HIMMEL-2404): this
# matches only each file's CURRENT `.path` from `gh pr list --json files`,
# which is (a) blind to a rename OUT of the fence (the new path is what's
# listed, not the old one) and (b) subject to gh's own per-PR files-list
# truncation on an unusually large PR. Both are narrow edge cases, not
# reopened here (4th panel round on this ticket).
_touches_fence() {
    printf '%s' "$1" | jq -e --arg f "$2" \
        'any(.[]?; .path == $f or (.path | startswith($f + "/")))' >/dev/null 2>&1
}

# A tested scan root COVERS a fence only when it IS the fence or an ancestor
# of it (round-12 CR finding codex-1) — same prefix semantics as
# _touches_fence above, just in the other direction: a scoped `--pr` run
# (e.g. scan root scripts/ci) must not be read as certifying an unrelated
# fence (scripts/handover) just because SOME run against this head passed.
_scope_covers_fence() {
    [ "$1" = "$2" ] && return 0
    case "$2" in
        "$1"/*) return 0 ;;
    esac
    return 1
}

had_error=0
# 'if type=="array" then length else "not-an-array" end' (HIMMEL-2383 CR
# finding codex-3, round 6) — a bare `jq 'length'` also accepts a
# wrong-SHAPED but syntactically valid response (`{}`, `null`): both parse
# fine and `length` reads 0, so the round-2 malformed-JSON check below (unparseable
# text only) missed this case and would have certified an empty, clean
# sweep on a genuinely broken response.
count=$(printf '%s' "$prs_json" | jq 'if type == "array" then length else "not-an-array" end' 2>/dev/null)
case "$count" in
    ''|*[!0-9]*)
        # Malformed JSON, or valid-but-wrong-shaped JSON, on a successful
        # `gh` exit must not read as "0 PRs, all clean" (HIMMEL-2383 CR
        # finding codex-4 round 2 / codex-3 round 6) — the documented
        # contract is a QUERY-ERROR + nonzero exit on anything that isn't a
        # genuine, parseable ARRAY result.
        echo "base-status: 'gh pr list' returned unparseable or wrong-shaped JSON — aborting (fail-closed)" >&2
        exit 1
        ;;
esac

if [ "$count" -eq "$PR_LIST_LIMIT" ]; then
    echo "QUERY-ERROR: merged-PR list hit the $PR_LIST_LIMIT-result limit — older merged PRs on this fence were not checked, cannot certify clean" >&2
    had_error=1
fi

# Known residual (HIMMEL-2383 CR finding codex-2, round 8, deferred ->
# HIMMEL-2404): only the top-level array shape is validated above. A single
# entry with a missing/null `files`, `number`, or `headRefOid` (a
# malformed per-PR record within an otherwise well-formed array — rare)
# reads as "doesn't touch the fence" via _touches_fence's own null-safe
# `?`, rather than a QUERY-ERROR. Same "per-entry data completeness" theme
# as HIMMEL-2404's rename/truncation gaps; not split into a separate
# ticket.
i=0
while [ "$i" -lt "$count" ]; do
    pr=$(printf '%s' "$prs_json" | jq -c ".[$i]")
    num=$(printf '%s' "$pr" | jq -r '.number')
    head=$(printf '%s' "$pr" | jq -r '.headRefOid')
    files=$(printf '%s' "$pr" | jq -c '.files')
    i=$((i + 1))

    # ALL touched fences are collected (round-13 CR finding codex-1) — not
    # just the first match. A PR can touch two of the fences passed on the
    # command line, and a scope-limited report might cover one but not the
    # other; checking only the first match let the other go uncertified.
    matched_fences=""
    for f in "$@"; do
        if _touches_fence "$files" "$f"; then
            matched_fences="$matched_fences$f
"
        fi
    done
    [ -n "$matched_fences" ] || continue

    comments_json=$(_gh pr view "$num" --comments --json comments 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "QUERY-ERROR PR $num: could not read comments: $comments_json" >&2
        had_error=1
        continue
    fi

    # Bound to THIS PR's head (round-1 CR finding codex-3): a summary posted
    # against an earlier revision of the PR must not certify the
    # subsequently-merged head. The runner embeds 'head: <full sha>' in
    # every summary it posts (scripts/ci/run-shell-tests.sh) — require it to
    # literally match this PR's headRefOid, not just carry the generic
    # markers.
    #
    # NOT author-bound (tried in round 2, reverted in round 3 — HIMMEL-2383
    # CR finding codex-3, round 3): binding to "whoever gh is currently
    # authenticated as" assumes the SAME identity posts the report and later
    # checks it, which this system does not guarantee — merge-on-green.sh,
    # run-shell-tests.sh --pr, and any console/leg session running
    # base-status.sh can each authenticate as a different account across
    # different machines (this repo's whole architecture is multi-session,
    # multi-machine). Author-binding would silently and PERMANENTLY reject a
    # legitimate report posted under a different identity, which is a worse
    # failure than the spoofing risk it defended against (round-2 codex-1's
    # own point: failing open on an unresolved identity reopens the same
    # hole anyway). On this PRIVATE, access-controlled repo, the head-SHA
    # binding above is the load-bearing protection; residual risk is a
    # comment from another repo collaborator forging the exact literal
    # markers + the real 40-hex head — accepted for now, not hardened
    # further here.
    # jq's own exit code (not just its output) is checked (HIMMEL-2383 CR
    # finding codex-3, round 5): a successful `gh` exit carrying malformed
    # comments JSON must be a QUERY-ERROR, not silently folded into the
    # same PENDING outcome an empty/no-match comments list gets — same
    # contract as the pr-list malformed-JSON fix above (codex-4, round 2).
    summary_rc=0
    summary=$(printf '%s' "$comments_json" | jq -r --arg head "$head" \
        '[.comments[]?.body | select(contains("== Summary ==") and test("PASS:") and contains("head: " + $head))] | last // ""' \
        2>/dev/null) || summary_rc=$?
    if [ "$summary_rc" -ne 0 ]; then
        echo "QUERY-ERROR PR $num: comments JSON did not parse" >&2
        had_error=1
        continue
    fi
    if [ -z "$summary" ] || [ "$summary" = "null" ]; then
        printf '%s' "$matched_fences" | while IFS= read -r mf; do
            [ -n "$mf" ] || continue
            echo "PENDING PR $num fence=$mf head=$head: no after-report SUMMARY comment at this head"
        done
        continue
    fi

    # A truncated run (HIMMEL-2383 CR finding codex-4) is not evidence of
    # clean, whatever its FAIL count says — some suites never ran.
    case "$summary" in
        *TRUNCATED:*)
            printf '%s' "$matched_fences" | while IFS= read -r mf; do
                [ -n "$mf" ] || continue
                echo "PENDING PR $num fence=$mf head=$head: after-report is TRUNCATED (budget-expired run), not certified clean"
            done
            continue
            ;;
    esac

    # A --changed-since run (round-13 CR finding codex-2) conditionally
    # skipped suites unrelated to that diff, so a clean-looking scope
    # covering the whole scan root does not mean every suite under it
    # actually ran — same "not full evidence" class as TRUNCATED above.
    case "$summary" in
        *CHANGED-SINCE:*)
            printf '%s' "$matched_fences" | while IFS= read -r mf; do
                [ -n "$mf" ] || continue
                echo "PENDING PR $num fence=$mf head=$head: after-report used --changed-since (conditionally filtered), not certified clean"
            done
            continue
            ;;
    esac

    # An unparseable FAIL count (HIMMEL-2383 CR finding codex-5) must not
    # default to clean — a malformed/manually-copied comment that happens to
    # carry the marker strings + this head's SHA but no real FAIL: N is
    # suspect, not proof of a passing run.
    fail_n=$(printf '%s\n' "$summary" | grep -oE 'FAIL: *[0-9]+' | tail -1 | grep -oE '[0-9]+')
    if [ -z "$fail_n" ]; then
        printf '%s' "$matched_fences" | while IFS= read -r mf; do
            [ -n "$mf" ] || continue
            echo "PENDING PR $num fence=$mf head=$head: after-report carries no parseable FAIL count, not certified clean"
        done
        continue
    fi

    # A SUMMARY with no scope line, or a scope that doesn't cover a given
    # fence (round-12 CR finding codex-1), is not evidence THAT fence is
    # clean — it may certify only an unrelated or narrower subtree. A
    # missing scope (an older-format report, posted before this field
    # existed) fails closed rather than being read as "scope unknown,
    # assume covered". Checked PER FENCE (round-13 CR finding codex-1): a
    # scope-limited report can cover one touched fence but not another.
    scope=$(printf '%s\n' "$summary" | grep -oE 'scope: [^ ]+' | tail -1 | cut -d' ' -f2)
    printf '%s' "$matched_fences" | while IFS= read -r mf; do
        [ -n "$mf" ] || continue
        if [ -z "$scope" ]; then
            echo "PENDING PR $num fence=$mf head=$head: after-report carries no scope line, cannot certify this fence"
            continue
        fi
        if ! _scope_covers_fence "$scope" "$mf"; then
            echo "PENDING PR $num fence=$mf head=$head: after-report only covers scope=$scope, not this fence"
            continue
        fi
        if [ "$fail_n" -gt 0 ]; then
            echo "RED PR $num fence=$mf head=$head FAIL=$fail_n"
        fi
    done
    # else: a clean SUMMARY at this exact head — not printed, this is a
    # what's-blocking-the-arm list.
done

exit "$had_error"
