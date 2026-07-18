#!/usr/bin/env bash
# ci-green-gate.sh — shared predicate for the HIMMEL-1043 CI-green merge gate.
#
# ci_green_gate <pr-selector> [<owner/repo>]
#   rc 0 = allow; rc 2 = block, one-line reason on stdout.
#   rc 3 = allow, but the SELECTOR did not resolve to a PR (gh pr view failed)
#          — callers that extracted the selector heuristically (the PreToolUse
#          hook) should retry once with a better-anchored selector (the cwd
#          branch) so quoted/mis-tokenized selectors cannot dodge the gate
#          (same re-anchor contract as cr_merge_gate, HIMMEL-936). Top-level
#          consumers treat any non-2 rc as allow.
#   Deny ONLY on positive evidence: a NON-GREEN CI state on the PR's head SHA
#   among NON-CodeRabbit check-runs — either a check-run with a RED conclusion
#   (failure, timed_out, cancelled, action_required, startup_failure, stale), a
#   check-run still PENDING (status != completed) — or a NON-CodeRabbit commit
#   status (newest per context) of failure/error/pending. CodeRabbit is EXCLUDED
#   from BOTH (the CR gate, HIMMEL-936/1072, owns CodeRabbit; this
#   gate owns the tests/lint/build CI the repo otherwise has no guard for — see
#   brief WHY "a red or still-running non-CodeRabbit check", and it keeps a hung
#   CodeRabbit review from false-blocking here — which, until HIMMEL-1072, it did
#   NOT: the exclusion was written against check-runs CodeRabbit never posts,
#   while its real commit STATUS rode the combined aggregate straight into the
#   pending block). This repo has NO branch
#   protection, so GitHub will not otherwise block `gh pr merge` over red/pending
#   CI (HIMMEL-1043). EVERYTHING else (gh/jq missing, gh pr view failure, API
#   error, parse failure, a check-less PR with zero check-runs AND zero statuses)
#   fails OPEN (rc 0/3) with a "ci-green-gate: degraded (...) - failing open"
#   stderr note. CI_MERGE_GATE_OK=1 skips the gate entirely (rc 0). NOT coupled
#   to CR_PROFILE (the CI gate is independent of the CodeRabbit gate).
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`;
# does not toggle set -e. bash 3.2-safe. Each `jq` command substitution is
# made set -e-safe with a trailing `|| true` inside the subshell so that a
# caller running `set -e` (pr-merge.sh) does not abort on a jq parse failure
# (a parse failure is a normal fail-open input here, not a hard error).
# HIMMEL-1043. Mirrors scripts/lib/cr-merge-gate.sh in structure + conventions.

_cig_degrade() { echo "ci-green-gate: degraded ($*) - failing open" >&2; }

# Shared CodeRabbit identity (HIMMEL-1072) — this gate EXCLUDES CodeRabbit's own
# status from the CI aggregate it owns, and must agree with cr-merge-gate on what
# that identity is. Sourced relative to this file so a hook can source it from
# any cwd.
# shellcheck source=scripts/lib/cr-signal.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-signal.sh"

ci_green_gate() {
    [ "${CI_MERGE_GATE_OK:-0}" = "1" ] && return 0

    local sel="${1:-}" repo="${2:-}"
    if [ -z "$sel" ]; then _cig_degrade "no PR selector"; return 0; fi
    command -v gh >/dev/null 2>&1 || { _cig_degrade "gh not on PATH"; return 0; }
    command -v jq >/dev/null 2>&1 || { _cig_degrade "jq not on PATH"; return 0; }

    local meta url num head owner name
    if [ -n "$repo" ]; then
        meta=$(gh pr view "$sel" --repo "$repo" --json number,headRefOid,url 2>/dev/null) || { _cig_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    else
        meta=$(gh pr view "$sel" --json number,headRefOid,url 2>/dev/null) || { _cig_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    fi
    num=$(printf '%s' "$meta" | jq -r '.number // empty' 2>/dev/null || true)
    head=$(printf '%s' "$meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
    url=$(printf '%s' "$meta" | jq -r '.url // empty' 2>/dev/null || true)
    if [ -z "$num" ] || [ -z "$head" ] || [ -z "$url" ]; then _cig_degrade "pr metadata incomplete"; return 0; fi
    # url shape: https://github.com/OWNER/NAME/pull/N
    owner=$(printf '%s' "$url" | sed -n 's|^https://[^/]*/\([^/]*\)/.*|\1|p')
    name=$(printf '%s' "$url"  | sed -n 's|^https://[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
    if [ -z "$owner" ] || [ -z "$name" ]; then _cig_degrade "cannot parse owner/name from $url"; return 0; fi

    # 1) check-runs on the head SHA. RED conclusions block; PENDING (status !=
    # completed) block. GREEN = success/neutral/skipped (or any non-RED
    # conclusion on a completed run — block ONLY on positive evidence).
    #
    # Layering with the CR gate (HIMMEL-936): CodeRabbit check-runs are the CR
    # gate's domain (it owns CodeRabbit threads + the in_progress/zombie
    # override, HIMMEL-980). The CI gate evaluates NON-CodeRabbit check-runs
    # only — the tests/lint/build CI this repo otherwise has no guard for
    # (brief WHY: "a red or still-running non-CodeRabbit check"). This also
    # keeps a hung CodeRabbit check-run (a known CodeRabbit quirk the zombie
    # override exists for) from false-blocking here. The combined commit STATUS
    # below is still evaluated in full (it is the overall aggregate).
    local runs runs_count red red_names pending
    runs=$(gh api "repos/$owner/$name/commits/$head/check-runs?per_page=100" 2>/dev/null) || { _cig_degrade "check-runs query failed"; return 0; }
    # runs_count (ALL check-runs, incl. CodeRabbit) doubles as the parse canary
    # AND feeds the checkless-PR check: a CodeRabbit-only repo has runs_count>0
    # so it is NOT noisy-"checkless"; its non-CodeRabbit CI is vacuously green.
    runs_count=$(printf '%s' "$runs" | jq -r '.check_runs | length' 2>/dev/null || true)
    if [ -z "$runs_count" ]; then _cig_degrade "check-runs parse failed"; return 0; fi
    # >100 check-runs: this single page cannot certify green — a failing or
    # pending run may sit on an unread page 2. A merge SAFETY gate must not pass
    # on that uncertainty, so BLOCK (fail-closed on the page limit, same stance
    # as cr-merge-gate's thread paging, HIMMEL-980). `.total_count` is the total
    # across all pages; the `.check_runs` array is capped at per_page=100.
    runs_total=$(printf '%s' "$runs" | jq -r '.total_count // 0' 2>/dev/null || true)
    if [ -z "$runs_total" ]; then _cig_degrade "check-runs total_count parse failed"; return 0; fi
    if [ "${runs_total:-0}" -gt "${runs_count:-0}" ] 2>/dev/null; then
        echo "BLOCK: PR #$num head $head has $runs_total check-runs (> one page of $runs_count) — cannot certify CI green from a single page. Bypass: CI_MERGE_GATE_OK=1."
        return 2
    fi
    red=$(printf '%s' "$runs" | jq -r \
        '[.check_runs[]? | select(.name!="CodeRabbit") | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled" or .conclusion=="action_required" or .conclusion=="startup_failure" or .conclusion=="stale")] | length' \
        2>/dev/null || true)
    if [ -z "$red" ]; then _cig_degrade "check-runs parse failed (red)"; return 0; fi
    if [ "$red" -gt 0 ] 2>/dev/null; then
        red_names=$(printf '%s' "$runs" | jq -r \
            '[.check_runs[]? | select(.name!="CodeRabbit") | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled" or .conclusion=="action_required" or .conclusion=="startup_failure" or .conclusion=="stale") | .name // "?"] | join(", ")' \
            2>/dev/null || true)
        echo "BLOCK: PR #$num head $head has failing checks [${red_names:-?}] — CI not green. Bypass: CI_MERGE_GATE_OK=1."
        return 2
    fi
    pending=$(printf '%s' "$runs" | jq -r \
        '[.check_runs[]? | select(.name!="CodeRabbit") | select(.status!="completed")] | length' \
        2>/dev/null || true)
    if [ -z "$pending" ]; then _cig_degrade "check-runs parse failed (pending)"; return 0; fi
    if [ "$pending" -gt 0 ] 2>/dev/null; then
        echo "BLOCK: PR #$num head $head has $pending check(s) still running — wait for green. Bypass: CI_MERGE_GATE_OK=1."
        return 2
    fi

    # 2) commit statuses on the head SHA — the legacy contexts never surfaced as
    # check-runs.
    #
    # This used to read the COMBINED /status endpoint and block on its aggregate
    # .state. That silently defeated the CodeRabbit exclusion this gate documents
    # above: CodeRabbit publishes a commit STATUS (see cr-signal.sh), the combined
    # .state folds every context together, so a pending CodeRabbit review turned
    # the aggregate pending and false-blocked HERE — precisely the "hung
    # CodeRabbit must not block the CI gate" case the .check_runs exclusion was
    # written for (and which that exclusion never handled, since CodeRabbit posts
    # no check-run to exclude).
    #
    # So: read the LIST endpoint, drop CodeRabbit's own statuses by IDENTITY
    # (creator.id, shared with the CR gate via cr_signal_bot_id), and aggregate
    # what's left. GitHub returns statuses newest-first and a context can carry
    # many over its lifetime, so reduce to the NEWEST per context — an old
    # `pending` superseded by `success` must not block.
    local statuses kind total latest red_ctx pending_ctx uid ctx
    uid=$(cr_signal_bot_id)
    ctx=$(cr_signal_context)
    statuses=$(gh api "repos/$owner/$name/commits/$head/statuses?per_page=100" 2>/dev/null) || { _cig_degrade "status query failed"; return 0; }
    # Canary: a valid payload is an array (empty for a status-less commit); an
    # error object or parse failure yields empty -> degrade, fail open.
    kind=$(printf '%s' "$statuses" | jq -r 'if type=="array" then "array" else empty end' 2>/dev/null || true)
    if [ "$kind" != "array" ]; then _cig_degrade "status parse failed"; return 0; fi
    total=$(printf '%s' "$statuses" | jq -r 'length' 2>/dev/null || true)
    if [ -z "$total" ]; then _cig_degrade "status length parse failed"; return 0; fi
    # Page-limit guard (coderabbit-1): this single page cannot certify green — a
    # failing or pending status may sit on an unread page 2 (the endpoint returns
    # every status for the SHA, undeduped, so a repo with many contexts x updates
    # overflows one page). A merge SAFETY gate must not pass on that uncertainty:
    # BLOCK, exactly as the >100 check-runs guard above does.
    if [ "${total:-0}" -ge 100 ] 2>/dev/null; then
        echo "BLOCK: PR #$num head $head has $total commit statuses (at or over the single page limit of 100) — cannot certify CI green from a single page. Bypass: CI_MERGE_GATE_OK=1."
        return 2
    fi
    # Reduce to the NEWEST status per context. `first(…)` over the array in its
    # returned order is the whole mechanism: GitHub DOCUMENTS statuses as
    # reverse-chronological, so the first match per context is its current state.
    #
    # Deliberately NOT `group_by(.context) | map(.[0])` (codex-1): that is
    # correct only because jq's group_by happens to be stable within a group —
    # verified true on jq 1.8.2, but the manual documents group_by's ordering of
    # the GROUPS, not the order WITHIN one. A merge gate should not rest on an
    # unguaranteed jq property across the mac/Linux/Windows jq builds himmel
    # supports, so the dependency is removed rather than commented.
    latest=$(printf '%s' "$statuses" | jq -c --arg ctx "$ctx" --argjson uid "$uid" \
        '[ .[]? | select((.creator.id == $uid and .context == $ctx) | not) ] as $rest
         | [ $rest[].context ] | unique
         | map(. as $c | first($rest[] | select(.context == $c)))' 2>/dev/null || true)
    if [ -z "$latest" ]; then _cig_degrade "status aggregate parse failed"; return 0; fi
    red_ctx=$(printf '%s' "$latest" | jq -r \
        '[.[] | select(.state=="failure" or .state=="error") | .context // "?"] | join(", ")' \
        2>/dev/null || true)
    if [ -n "$red_ctx" ]; then
        echo "BLOCK: PR #$num head $head has failing commit status(es) [$red_ctx] — CI not green. Bypass: CI_MERGE_GATE_OK=1."
        return 2
    fi
    pending_ctx=$(printf '%s' "$latest" | jq -r \
        '[.[] | select(.state=="pending") | .context // "?"] | join(", ")' \
        2>/dev/null || true)
    if [ -n "$pending_ctx" ]; then
        echo "BLOCK: PR #$num head $head has pending commit status(es) [$pending_ctx] — wait for green. Bypass: CI_MERGE_GATE_OK=1."
        return 2
    fi

    # 3) No red/pending evidence. A PR with ZERO check-runs AND zero commit
    # statuses is checkless (no CI configured for the repo/branch) — fail open
    # with a note, do NOT block (operator rule: block ONLY on positive evidence).
    if [ "$runs_count" -eq 0 ] 2>/dev/null && [ "$total" -eq 0 ] 2>/dev/null; then
        _cig_degrade "no check-runs and no commit statuses on head $head (checkless PR?)"
        return 0
    fi
    return 0
}
