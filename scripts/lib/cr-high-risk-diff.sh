#!/usr/bin/env bash
# cr-high-risk-diff.sh — classify whether a PR diff touches a review gate or
# permission-bearing surface that must not be panel-carried silently
# (HIMMEL-1718).
#
# WHY THIS EXISTS. A clean exact-head critic panel may carry a stale CodeRabbit
# review anchor for ordinary diffs, but the same availability shortcut is too
# quiet for hooks, guardrails, cadence emitters, and the merge/CR gate itself.
# This reader asks GitHub for the PR file list and fails CLOSED when that list
# cannot be certified complete. `gh pr view --json files` returns at most 100
# files with no pagination, which would silently hide a protected path beyond
# the first page on a >100-file PR — so the file list comes from the paginated
# REST endpoint (`gh api --paginate .../pulls/<n>/files`) instead, and the
# flattened count is compared against `changedFiles` (read via a separate
# `pr view` call, itself an unpaginated scalar) before any ordinary verdict is
# trusted.
#
# cr_diff_is_high_risk <owner> <repo> <pr-number>
#   rc 0 = HIGH RISK; stdout is the matched paths (comma-joined, length-capped)
#   rc 1 = ordinary diff; stdout is empty
#   rc 2 = cannot determine; stdout is a short machine reason
#
# Env:
#   GH_CMD  gh override (test seam, matching cr-review-freshness.sh)
#
# Sourceable from check-ci.sh: uses only `return`, never `exit`; does not toggle
# set -e. bash 3.2-safe.

_crhd_gh() { "${GH_CMD:-gh}" "$@"; }

cr_diff_is_high_risk() {
    local owner="${1:-}" repo="${2:-}" num="${3:-}"
    if [ -z "$owner" ] || [ -z "$repo" ]; then
        printf 'invalid-args\n'; return 2
    fi
    case "$num" in ''|*[!0-9]*) printf 'invalid-args\n'; return 2 ;; esac
    command -v jq >/dev/null 2>&1 || { printf 'no-jq\n'; return 2; }

    local pv_json total raw_pages files_json shape received paths path base matched=""
    pv_json=$(_crhd_gh pr view "$num" --repo "$owner/$repo" --json changedFiles 2>/dev/null) || {
        printf 'query-failed\n'; return 2
    }
    total=$(printf '%s' "$pv_json" | jq -r '
        if (.changedFiles | type) == "number"
           and (.changedFiles >= 0)
           and (.changedFiles | floor) == .changedFiles
        then (.changedFiles | floor) else empty end
    ' 2>/dev/null || true)
    case "$total" in ''|*[!0-9]*) printf 'malformed-response\n'; return 2 ;; esac

    # `gh api --paginate` follows every page and writes each page's raw JSON
    # array back to back (not merged into one array), so `jq -s add` slurps the
    # concatenated stream and flattens it into a single array — this works the
    # same regardless of installed gh version, unlike gh's own `--slurp` flag.
    raw_pages=$(_crhd_gh api --paginate "repos/$owner/$repo/pulls/$num/files" 2>/dev/null) || {
        printf 'query-failed\n'; return 2
    }
    files_json=$(printf '%s' "$raw_pages" | jq -s 'add' 2>/dev/null || true)
    if [ -z "$files_json" ] || [ "$files_json" = "null" ]; then
        printf 'malformed-response\n'; return 2
    fi

    shape=$(printf '%s' "$files_json" | jq -r '
        if (type) == "array"
           and ([.[]? | (.filename | type)] | all(. == "string"))
           and ([.[]? | (.status | type)] | all(. == "string"))
           and ([.[]? | select(.status == "renamed") | (.previous_filename | type)] | all(. == "string"))
        then "ok" else empty end
    ' 2>/dev/null || true)
    if [ "$shape" != "ok" ]; then
        printf 'malformed-response\n'; return 2
    fi

    received=$(printf '%s' "$files_json" | jq -r 'length' 2>/dev/null || true)
    case "$received" in ''|*[!0-9]*) printf 'malformed-response\n'; return 2 ;; esac
    if [ "$received" -ne "$total" ]; then
        printf 'truncated-files:%s/%s\n' "$received" "$total"; return 2
    fi

    # A RENAME is unprovable from the new path alone: the file list carries the
    # NEW path only, so a hook or settings file moved OUT of a protected path
    # presents as an ordinary path while the protected one is silently deleted.
    # The REST files endpoint reports rename state as `status` on each file in
    # the same paginated call, so detecting it costs no extra query — but
    # resolving the OLD path's protected-ness from `previous_filename` is
    # deliberately not attempted (see below). Fail closed instead: a renamed
    # file is cannot-determine, which the caller treats as high risk.
    #
    # `status` and, for renames, `previous_filename` are REQUIRED by the shape
    # check above: a page response missing either is malformed (rc 2), not
    # silently treated as "not renamed" — the same fail-loud posture as the
    # prior `gh pr view --json files` reader, applied to the REST shape.
    local renamed
    renamed=$(printf '%s' "$files_json" | jq -r '
        [.[]? | select(.status == "renamed") | .filename] | join(",")
    ' 2>/dev/null || true)
    if [ -n "$renamed" ]; then
        if [ "${#renamed}" -gt 200 ]; then renamed="${renamed:0:197}..."; fi
        printf 'renamed-file:%s\n' "$renamed"; return 2
    fi

    paths=$(printf '%s' "$files_json" | jq -r '.[].filename' 2>/dev/null || true)
    while IFS= read -r path; do
        path=${path%$'\r'}
        [ -n "$path" ] || continue
        base=${path##*/}
        # The whole of scripts/cr/ is in scope, not a hand-picked subset: the
        # panel carry TRUSTS the exact-head ledger evidence, and scripts/cr/
        # is what produces it (critic-panel.sh runs the reviewers,
        # ledger-append.sh persists their findings). Leaving the evidence
        # producers out let a branch edit its own review machinery, be
        # classified ordinary, and use that tampered machinery to manufacture
        # the clean panel evidence that carries a stale review — the diff
        # self-authorizing its own carry. Same reason the pr-check runbook and
        # its codex twin are listed. This matches the repo's existing
        # gate-infrastructure predicate in scripts/cr/pr-check-external.sh
        # (GATE 6, HIMMEL-1224); keep the two in step.
        #
        # merge-on-green.sh IS listed below: it EXECUTES the squash-merge
        # unattended under the ARMAUTOMERGE=1 standing allow (HIMMEL-1042),
        # gating only on a check-ci.sh green plus a certified head SHA — and
        # check-ci.sh itself consults this classifier's panel-carry, so a
        # defect or self-edit there can merge a PR the review gate did not
        # actually clear. The predicate now also covers surfaces that EXECUTE
        # merge/push unattended under a standing allow; a codex counterexample
        # to the prior scope-out was ACCEPTED by the operator (2026-08-12,
        # HIMMEL-1744), superseding the 2026-08-11 ruling on this single path.
        # It is named explicitly because it lives under scripts/handover/, so
        # the scripts/cr/* broadening above does not quietly pull in the rest
        # of that directory.
        #
        # STILL DELIBERATELY ABSENT: the other post-gate merge drivers
        # (scripts/handover/pr-merge.sh, scripts/propagate-public.sh) and the
        # check-ci runbook (.claude/commands/check-ci.md) — same executing-
        # surface class but not yet counter-exampled; tracked for audit by the
        # HIMMEL-1744 follow-up, not added speculatively. The list targets
        # surfaces that GRANT permission, are CONSUMED by the harness, decide
        # what merges, OR now EXECUTE that merge/push unattended under a
        # standing allow — not everything merge-adjacent.
        case "$path" in
            scripts/hooks/*|.claude/settings.json|.claude/settings.local.json|.codex/hooks.json|scripts/guardrails/*|scripts/luna/pipeline-cadence.sh|scripts/check-ci.sh|scripts/cr/*|scripts/lib/cr-*.sh|.claude/commands/pr-check.md|.agents/skills/pr-check/SKILL.md|.pre-commit-config.yaml|marketplace/plugins/*/hooks/hooks.json|scripts/glm/ship-branch.sh|.codex/run-hook.cmd|.codex/run-hook.sh|.codex/codex-hook-adapter.sh|scripts/handover/merge-on-green.sh)
                if [ -n "$matched" ]; then matched="$matched,$path"; else matched="$path"; fi ;;
            *)
                case "$base" in
                    *cadence*)
                        if [ -n "$matched" ]; then matched="$matched,$path"; else matched="$path"; fi ;;
                esac ;;
        esac
    done <<EOF
$paths
EOF

    [ -n "$matched" ] || return 1
    if [ "${#matched}" -gt 500 ]; then matched="${matched:0:497}..."; fi
    printf '%s\n' "$matched"
    return 0
}
