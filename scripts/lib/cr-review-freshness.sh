#!/usr/bin/env bash
# cr-review-freshness.sh — is the latest bot REVIEW object anchored to the PR
# head, or was the head never actually re-reviewed? (HIMMEL-1181, B2.)
#
# WHY THIS EXISTS — the hole "0 unresolved threads" cannot see:
# GitHub auto-resolves (outdates) a review thread when a later commit changes
# its lines. So a head CodeRabbit never re-reviewed can carry ZERO unresolved
# threads and read "App-clean" even though nobody looked at the current code
# (live instance: PR #1273, 2026-07 week). check-ci's full-mode run already
# certifies that the bot's commit STATUS concluded on the head SHA
# (cr_signal_gate / scripts/lib/cr-signal.sh, HIMMEL-1072) — but a concluded
# STATUS is not the same claim as an anchored REVIEW OBJECT: CodeRabbit can
# post `state=success` on an incremental run that created no new review at
# all, leaving the last real review (and everything it said) sitting on a
# stale commit. This reader answers the narrower, load-bearing question: is
# the most recent bot REVIEW anchored to head, or not?
#
# INDEPENDENCE FROM THE OTHER TWO CR READERS (do not fold this into either):
#   - cr-signal.sh certifies "the bot CONCLUDED on this SHA" (a commit STATUS).
#   - cr-body-findings.sh (HIMMEL-1126/1147/1148, already shipped — see the
#     deviation note below) certifies "these outside-diff/nitpick/additional
#     findings are recorded at this SHA" (a review BODY, read via REST +
#     `.user.id` identity).
#   - THIS reader certifies "the review OBJECT ITSELF — the thing whose
#     threads and body the other two readers examine — is anchored to this
#     SHA" (via GraphQL + Bot-typename identity, HIMMEL-1058 spoof-resistance
#     stance). None of the three subsumes another; keep all three.
#
# SPEC DEVIATION (recorded for the reviewer, HIMMEL-1181): the design spec
# this lib was built from (consolidation-2026-07-17/specs/review-freshness-
# spec.md) predates cr-body-findings.sh (landed 2026-07-19 under HIMMEL-1126,
# refined 2026-08-05 under HIMMEL-1582) and specified this lib ALSO summing
# nitpick/outside-diff/additional counts from the review body, duplicating
# what that reader already delivers end-to-end (wired into both check-ci.sh
# and cr-merge-gate.sh). Re-deriving the same counts here via a SEPARATE
# identity mechanism (GraphQL Bot-typename vs REST `.user.id`) would give two
# call sites a chance to disagree about the same PR and duplicate a reader
# that already has its own anti-drift canaries (HIMMEL-1126) and a hard-won
# latest-substantive-review fix (HIMMEL-1582). So this lib is FRESHNESS ONLY;
# body-finding surfacing stays entirely owned by cr-body-findings.sh.
#
# THE LANDMINE (HIMMEL-1147): the same bot has DIFFERENT logins per API — the
# GraphQL `PullRequestReview.author.login` for a GitHub App is `coderabbitai`
# (no suffix); the REST `user.login` is `coderabbitai[bot]`. Filtering on a
# bare `coderabbitai` against the WRONG api silently returns empty and reads
# as "no findings" — nearly missed twice in one session. This lib is GraphQL
# throughout, and normalizes BOTH sides (configured logins and API logins) by
# lowercasing + stripping a trailing `[bot]`, so either spelling in
# CR_BOT_LOGINS works. Spoof resistance (HIMMEL-1058): a review only counts as
# a bot review when `author.__typename == "Bot"` — a human account renamed
# "coderabbitai" is typename `User` and never matches.
#
# cr_review_bot_logins
#   stdout: normalized (lowercase, "[bot]" suffix stripped), space-joined set
#   of logins that count as "the bot". Default: coderabbitai.
#
# cr_review_freshness <owner> <repo> <pr-number> <head-sha>
#   stdout (single line):
#     "fresh <login> <oid>"  the latest bot review is anchored to <head-sha>
#     "stale <login> <oid>"  the latest bot review is anchored to a
#                            NON-head commit — the head was never re-reviewed
#     "none"                 zero bot reviews on the whole PR (self-skip:
#                            absence of a bot review is not evidence of
#                            staleness — callers should already have gated on
#                            an absent/pending bot STATUS before reaching
#                            here, via cr-signal.sh)
#     "paged"                 totalCount > 100 and none of the newest 100 is
#                            the bot's — the bot's latest review may sit
#                            outside this window; indeterminate, callers fail
#                            CLOSED (mirrors cr-signal.sh's "paged")
#   rc 0 = state determined (fresh/stale/none/paged); rc 1 = cannot evaluate
#   (query/parse failure, OR the latest bot review's commit anchor is null/
#   empty — "malformed": a review object without a resolvable commit cannot
#   be certified fresh OR stale). The caller decides open/closed; this reader
#   does not.
#
# Body-finding counts are deliberately NOT read here (see the deviation note
# above) — a stale review's findings are superseded by definition anyway (a
# stale latest review already blocks in the caller before any count would
# matter), and CodeRabbit's PR-level walkthrough ISSUE comment stays out of
# scope for the same reason cr-body-findings.sh leaves it out (HIMMEL-1147:
# "Consider...", recorded as deferred).
#
# Env:
#   CR_BOT_LOGINS   comma/space-separated review-author logins that count as
#                   the bot (default coderabbitai; a trailing "[bot]" on any
#                   entry is stripped, so either spelling works)
#   GH_CMD          gh override (test seam, matches cr-signal.sh / cr-body-
#                   findings.sh / cr-merge-gate.sh)
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`; does
# not toggle set -e. bash 3.2-safe (no mapfile, no associative arrays). Every
# `$(... | jq ...)` substitution is `|| true`-guarded so a caller running
# `set -e` never aborts on a parse failure. Requires SYSTEM jq — callers
# enforce its availability (this lib just `return 1`s if parsing fails).

_crf_gh() { "${GH_CMD:-gh}" "$@"; }

cr_review_bot_logins() {
    printf '%s\n' "${CR_BOT_LOGINS:-coderabbitai}" | tr ',' ' ' | tr '[:upper:]' '[:lower:]' \
        | sed 's/\[bot\]//g'
}

# The jq program is a single-quoted literal (no embedded single-quotes) so it
# survives being passed as one argument, matching cr-merge-gate.sh's GraphQL
# query convention.
# shellcheck disable=SC2016  # this is a jq program, not a shell variable
_CRF_JQ_PROGRAM='
def norm: ascii_downcase | sub("\\[bot\\]$"; "");
($bots | split(" ") | map(select(length > 0))) as $set
| .data.repository.pullRequest.reviews as $r
| [ $r.nodes[]?
    | select(.state != "PENDING")
    | select(.author.__typename == "Bot")
    | select((.author.login // "" | norm) as $l | $set | index($l) != null) ]
  as $bot
| if ($bot | length) == 0 then
    (if $r.totalCount > 100 then "paged" else "none" end)
  else
    ($bot | last) as $latest
    | ($latest.commit.oid // "") as $oid
    | if $oid == "" then "malformed"
      elif $oid != $head then "stale \($latest.author.login) \($oid)"
      else "fresh \($latest.author.login) \($oid)"
      end
  end
'

cr_review_freshness() {
    local owner="$1" repo="$2" num="$3" head="$4"
    if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$num" ] || [ -z "$head" ]; then return 1; fi
    case "$num" in ''|*[!0-9]*) return 1 ;; esac

    local bots json
    bots=$(cr_review_bot_logins)

    # last:100 returns the 100 NEWEST reviews in ASCENDING order, so the last
    # matching node in the filtered array is the latest bot review by
    # construction — no client-side sort needed. No --jq here (raw JSON):
    # system jq does the extraction so a stubbed `gh` returning fixture JSON
    # still exercises the real parser (matches cr-signal.sh's canary style).
    # shellcheck disable=SC2016  # $o/$r/$n are GraphQL variables — literal on purpose
    json=$(_crf_gh api graphql \
        -f o="$owner" -f r="$repo" -F n="$num" \
        -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(last:100){totalCount nodes{author{login __typename} commit{oid} state}}}}}' \
        2>/dev/null) || return 1

    # Canary first, exactly like cr-signal.sh / cr-body-findings.sh: a valid
    # payload's reviews.nodes is a JSON array (possibly empty). Anything else
    # (error object, malformed response) is cannot-evaluate, distinct from a
    # well-formed empty array (which is legitimately "no reviews yet").
    local kind
    kind=$(printf '%s' "$json" | jq -r \
        'if (.data.repository.pullRequest.reviews.nodes | type) == "array" then "array" else empty end' \
        2>/dev/null || true)
    [ "$kind" = "array" ] || return 1

    local result
    result=$(printf '%s' "$json" | jq -r --arg head "$head" --arg bots "$bots" \
        "$_CRF_JQ_PROGRAM" 2>/dev/null || true)
    [ -n "$result" ] || return 1

    case "$result" in
        malformed) return 1 ;;
        none|paged) printf '%s\n' "$result"; return 0 ;;
        fresh\ *|stale\ *) printf '%s\n' "$result"; return 0 ;;
        *) return 1 ;;
    esac
}
