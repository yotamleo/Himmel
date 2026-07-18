#!/usr/bin/env bash
# cr-merge-gate.sh — shared predicate for the HIMMEL-936 CR merge gate.
#
# cr_merge_gate <pr-selector> [<owner/repo>]
#   rc 0 = allow; rc 2 = block, one-line reason on stdout.
#   rc 3 = allow, but the SELECTOR did not resolve to a PR (gh pr view failed)
#          — callers that extracted the selector heuristically (the PreToolUse
#          hook) should retry once with a better-anchored selector (the cwd
#          branch) so quoted/mis-tokenized selectors cannot dodge the gate
#          (codex-1 / codex-adv-1, HIMMEL-936 CR round). Top-level consumers
#          treat any non-2 rc as allow.
#   Deny on:
#     - an unresolved PR review thread whose first comment is by coderabbitai
#     - a CodeRabbit commit status on the head SHA that is pending/failure/error
#     - NO CodeRabbit status on the head SHA at all ("absent")
#   That last one is a deliberate break from the old "deny ONLY on positive
#   evidence" stance (HIMMEL-1072, operator call 2026-07-16): an unreviewed head
#   reading as green is what merged #1243 with 6 unresolved threads. Absence of a
#   review is now positive evidence of an unreviewed head, not a pass. A repo with
#   no CodeRabbit sets CR_PROFILE=none (the established switch) — otherwise this
#   gate blocks every merge there.
#   INFRASTRUCTURE failures (gh missing, API error, no PR, parse failure) still
#   fail OPEN (rc 0/3) with a "cr-merge-gate: degraded (...) - failing open" note
#   — a broken query is not evidence of anything.
#   CR_MERGE_GATE_OK=1 or CR_PROFILE=none skip the gate entirely (rc 0).
#
#   The HIMMEL-980 zombie override is GONE: it keyed off a CodeRabbit check-run
#   that does not exist, so it had never run. Reviving it on the status would mean
#   waving through a >90m pending review on age alone — the same "uncertainty
#   reads as green" bug in a new coat. A genuinely stuck review blocks; use
#   CR_MERGE_GATE_OK=1. CR_ZOMBIE_CHECKRUN_MINS is therefore no longer read.
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`;
# does not toggle set -e. bash 3.2-safe. Each `jq` command substitution is
# made set -e-safe with a trailing `|| true` inside the subshell so that a
# caller running `set -e` (pr-merge.sh) does not abort on a jq parse failure
# (a parse failure is a normal fail-open input here, not a hard error).
# HIMMEL-936.

_cmg_degrade() { echo "cr-merge-gate: degraded ($*) - failing open" >&2; }

# The ONE reader for CodeRabbit's verdict (HIMMEL-1072). Sourced relative to this
# file so a hook can source this gate from any cwd.
# shellcheck source=scripts/lib/cr-signal.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-signal.sh"

cr_merge_gate() {
    [ "${CR_MERGE_GATE_OK:-0}" = "1" ] && return 0
    [ "${CR_PROFILE:-}" = "none" ] && return 0

    local sel="${1:-}" repo="${2:-}"
    if [ -z "$sel" ]; then _cmg_degrade "no PR selector"; return 0; fi
    command -v gh >/dev/null 2>&1 || { _cmg_degrade "gh not on PATH"; return 0; }
    command -v jq >/dev/null 2>&1 || { _cmg_degrade "jq not on PATH"; return 0; }

    local meta url num head owner name
    if [ -n "$repo" ]; then
        meta=$(gh pr view "$sel" --repo "$repo" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    else
        meta=$(gh pr view "$sel" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    fi
    num=$(printf '%s' "$meta" | jq -r '.number // empty' 2>/dev/null || true)
    head=$(printf '%s' "$meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
    url=$(printf '%s' "$meta" | jq -r '.url // empty' 2>/dev/null || true)
    if [ -z "$num" ] || [ -z "$head" ] || [ -z "$url" ]; then _cmg_degrade "pr metadata incomplete"; return 0; fi
    # url shape: https://github.com/OWNER/NAME/pull/N
    owner=$(printf '%s' "$url" | sed -n 's|^https://[^/]*/\([^/]*\)/.*|\1|p')
    name=$(printf '%s' "$url"  | sed -n 's|^https://[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
    if [ -z "$owner" ] || [ -z "$name" ]; then _cmg_degrade "cannot parse owner/name from $url"; return 0; fi

    # 1) CodeRabbit's verdict on the head SHA (HIMMEL-1072).
    #
    # This runs BEFORE the thread query, and the order is load-bearing
    # (coderabbit-10). Threads-first loses a race: snapshot threads (clean at
    # T0) -> CodeRabbit posts its findings at T0.5 and flips its status to
    # success at T1 -> read the verdict (success) -> the gate passes over
    # threads it never saw. Reading the verdict first inverts that: once the
    # status says success CodeRabbit has CONCLUDED, so the thread set is final
    # and the query below sees all of it. Same principle as check-ci's
    # post-watch re-verification (codex-adv 980-r2) — establish that the
    # reviewer is done, THEN snapshot what it said.
    #
    # This block used to read `select(.name=="CodeRabbit")` over `.check_runs[]`
    # — which matched NOTHING, on every PR, since the day it shipped: CodeRabbit
    # publishes a commit STATUS, not a check-run (verified on 5 consecutive PRs;
    # see scripts/lib/cr-signal.sh). So this gate had never once blocked on an
    # in-flight review, and the HIMMEL-980 zombie override below it was
    # unreachable. The fixtures mocked CodeRabbit as a check-run, so the suite
    # confirmed the wrong shape rather than catching it.
    #
    # It now reads the real signal, identity-matched on creator.id, and treats
    # ABSENT as a blocker: "CodeRabbit has said nothing about this SHA" is the
    # exact state that let #1243 merge with 6 unresolved threads (HIMMEL-1072).
    # Absence of evidence is not evidence of a pass.
    # A FAILED status query must not return early (codex-1): doing so would skip
    # the thread query below and fail open over positive unresolved-thread
    # evidence the independent GraphQL call would have caught — and a transient
    # 503 on this endpoint is real (observed live 2026-07-17). So a degraded
    # verdict is REMEMBERED, not acted on: the threads are still read, positive
    # evidence still blocks, and the fail-open only happens at the end when
    # nothing blocked. Ordering is preserved for every non-degraded path.
    local cr_state cr_degraded=0
    cr_state=$(cr_signal_state "$owner" "$name" "$head") || cr_degraded=1
    if [ "$cr_degraded" -eq 0 ]; then
        case "$cr_state" in
            success)
                : ;; # concluded — the thread set below is now final
            pending)
                echo "BLOCK: CodeRabbit is still reviewing head $head of PR #$num (status=pending). Wait for it, then re-check threads. Bypass: CR_MERGE_GATE_OK=1."
                return 2 ;;
            failure|error)
                echo "BLOCK: CodeRabbit reported '$cr_state' on head $head of PR #$num — its review did not complete. Re-trigger it, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
            absent)
                echo "BLOCK: CodeRabbit has not reviewed head $head of PR #$num (no status on this SHA) — an unreviewed head must not merge (HIMMEL-1072). Wait for the review; if this repo has no CodeRabbit, set CR_PROFILE=none. Bypass: CR_MERGE_GATE_OK=1."
                return 2 ;;
            paged)
                # Indeterminate, not absent (coderabbit-2): page one was full and
                # held no CodeRabbit status, so its verdict may be on an unread page.
                # BLOCKS rather than degrades — a degrade fails OPEN, and "we could
                # not see the review" must never merge. Same stance as the >100
                # thread page-cap below.
                echo "BLOCK: head $head of PR #$num has more commit statuses than one API page (100) and none of them is CodeRabbit's — cannot certify the review. Check manually, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
        esac
    fi

    # 2) unresolved coderabbitai review threads — read only now that CodeRabbit
    # has concluded, so the set is complete. Still read when the verdict query
    # degraded (see above): its evidence is independent and blocks on its own.
    local threads unresolved threads_page_complete
    # shellcheck disable=SC2016  # GraphQL variables ($owner/$name/$number) are literal here
    threads=$(gh api graphql \
        -f owner="$owner" -f name="$name" -F number="$num" \
        -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved path line comments(first:1){nodes{author{login}}}}}}}}' \
        2>/dev/null) || { _cmg_degrade "reviewThreads query failed"; return 0; }
    # Page-completeness marker (HIMMEL-980 codex-adv-1): this single-page query
    # is the hook's ONLY thread evidence, so "zero unresolved on page one" is a
    # pass ONLY when page one was the whole story. It now feeds exactly one
    # consumer: the >100-thread BLOCK below (coderabbit-5 — it used to gate the
    # zombie override, which HIMMEL-1072 removed).
    # `== false` on purpose (coderabbit 980-r2): only an EXPLICIT
    # hasNextPage:false proves completeness — a missing/null pageInfo yields
    # "false" here (so an unprovable page blocks). jq's `//` operator cannot
    # express this: `hasNextPage // true` swallows a legitimate false.
    threads_page_complete=$(printf '%s' "$threads" | jq -r \
        '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false' \
        2>/dev/null || echo false)
    unresolved=$(printf '%s' "$threads" | jq -r \
        '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i"))] | length' \
        2>/dev/null || true)
    if [ -z "$unresolved" ]; then _cmg_degrade "reviewThreads parse failed"; return 0; fi
    # >100 threads with zero unresolved ON PAGE ONE is not a pass — it is
    # positive evidence of threads this single-page query never counted
    # (coderabbit 980-r3). Unlike an API/parse failure (degrade, fail open),
    # this blocks: the state is knowable, just not from one page. A real PR
    # with 100+ CodeRabbit threads is pathological — check manually or bypass.
    if [ "$unresolved" -eq 0 ] 2>/dev/null && [ "$threads_page_complete" != "true" ]; then
        echo "BLOCK: PR #$num has more review threads than the gate's single page (100) — cannot certify zero unresolved CodeRabbit threads. Check threads manually, or bypass with CR_MERGE_GATE_OK=1."
        return 2
    fi
    if [ "$unresolved" -gt 0 ] 2>/dev/null; then
        # List the offending threads (path:line) so the block is actionable and
        # the bypass is front-and-center (false-block trust erosion mitigation,
        # plan-critic #5).
        local locs
        locs=$(printf '%s' "$threads" | jq -r \
            '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i")) | "\(.path // "?"):\(.line // "?")"] | join(", ")' \
            2>/dev/null || true)
        echo "BLOCK: $unresolved unresolved CodeRabbit review thread(s) on PR #$num [$locs]. Fix + RESOLVE each thread (operator rule 2026-07-12), or bypass with CR_MERGE_GATE_OK=1 in the launching shell if already adjudicated."
        return 2
    fi

    # Nothing blocked. If the verdict query itself degraded, THIS is where we
    # fail open (codex-1) — only after the independent thread evidence above had
    # its say. A broken query is not evidence; unresolved threads are.
    if [ "$cr_degraded" -eq 1 ]; then
        _cmg_degrade "CodeRabbit status query failed"
        return 0
    fi

    return 0
}
