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
# cr_review_walkthrough <owner> <repo> <pr-number> <head-sha>
#   CodeRabbit's SECOND delivery channel (HIMMEL-1824). A pass that finds
#   nothing mints NO review object at all: its entire delivery is the
#   head-anchored commit status plus an in-place EDIT of the walkthrough issue
#   comment. So an anchor test over review OBJECTS is structurally blind exactly
#   when there is nothing wrong — and the advertised remedy ("request a full
#   review") is then an infinite loop that burns one included review per turn
#   and can never mint the object the gate demands (measured on PR #1708:
#   three clean passes, zero objects, four same-head review commands).
#   stdout: "clean" | "dirty" | "none"   rc 0
#     clean  the walkthrough says it reviewed UP TO this head and generated no
#            actionable comments
#     dirty  a walkthrough exists for this head but reports actionable comments
#     none   no walkthrough comment names this head (says nothing either way)
#   rc 1 = cannot evaluate (query/parse failure).
#
# cr_review_freshness <owner> <repo> <pr-number> <head-sha>
#   stdout (single line):
#     "fresh <login> <oid>"  the latest bot review is anchored to <head-sha>
#     "fresh-clean-no-object <login> <oid>"
#                            no review OBJECT at head, but the walkthrough
#                            certifies the head was reviewed with no actionable
#                            comments (HIMMEL-1824).
#                            CALLER PRECONDITION (CR round 6): accept this state
#                            ONLY after certifying the bot's head STATUS is
#                            `success` (cr-signal.sh). Unlike `fresh`, whose
#                            evidence is a review OBJECT that exists because a
#                            pass completed, this state's evidence is TEXT, and
#                            text alone cannot say the current pass concluded.
#                            Concretely: a clean pass at H writes "up to H", a
#                            later re-review of H FAILS, and the walkthrough
#                            still reads clean — a caller that skips the status
#                            would pass a head whose latest review failed. This
#                            reader stays status-INDEPENDENT by design (see the
#                            three-readers note above), so the check belongs to
#                            the caller and is pinned by the consumer canary in
#                            test-cr-review-freshness.sh. The App itself reviewed
#                            this head, so this is real App evidence — no
#                            panel carry is involved, and it holds for a
#                            high-risk diff.
#                            <oid> is the stale object anchor, kept for the log.
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
#   CR_WALK_MAX_PAGES  how many 100-comment pages cr_review_walkthrough may
#                   read before giving up (default 5). The cap is what keeps
#                   the walkthrough lookup bounded; there is no unbounded
#                   --paginate anywhere in this lib.
#   CR_GH_TIMEOUT   hard per-call ceiling in seconds (default 20). Every gh call
#                   in this lib is wrapped: a wedged network call returns
#                   non-zero instead of hanging the caller, which is the whole
#                   point of keeping this reader a bounded script (HIMMEL-1949).
#                   Ignored when `timeout` is unavailable.
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`; does
# not toggle set -e. bash 3.2-safe (no mapfile, no associative arrays). Every
# `$(... | jq ...)` substitution is `|| true`-guarded so a caller running
# `set -e` never aborts on a parse failure. Requires SYSTEM jq — callers
# enforce its availability (this lib just `return 1`s if parsing fails).

# Hard ceiling on every call. `timeout` is absent on some boxes (stock macOS
# without coreutils); there the call runs unbounded rather than not at all —
# the ceiling is best-effort, the non-zero-on-failure contract is not.
_crf_gh() {
    local t="${CR_GH_TIMEOUT:-20}"
    case "$t" in ''|*[!0-9]*) t=20 ;; esac
    # GNU `timeout 0` means NO limit — the exact hang this wrapper exists to
    # prevent, reachable through a value that passes the digit check above.
    # Arithmetic, not string comparison, so 0 / 00 / 000 are all caught
    # (same guard HIMMEL-1953 needed for CASE_TIMEOUT_SECS).
    [ "$t" -ge 1 ] 2>/dev/null || t=20
    if command -v timeout >/dev/null 2>&1; then
        timeout "$t" "${GH_CMD:-gh}" "$@"
    else
        "${GH_CMD:-gh}" "$@"
    fi
}

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
    # HIMMEL-1824: drop empty review SHELLS. `chat.auto_reply` replies and
    # CodeRabbit incremental passes both mint COMMENTED objects with an empty
    # body and zero comments (two such at 12:18:00 on PR #1708). They carry no
    # verdict, so counting them lets an empty payload fake FRESH as easily as
    # it can bury a real review under a newer nothing.
    | select(((.body // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "")) != ""
             or ((.comments.totalCount // 0) > 0))
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

# The walkthrough comment is edit-in-place and machine readable. One bounded
# page of issue comments: the walkthrough is created with CodeRabbit's first
# pass and only ever EDITED afterwards, so it sits near the start of the
# comment list even on a long-running PR.
# PAGINATED under a hard cap, in creation order (CR rounds 2-3).
#
# MEASURED, because the obvious fix does not work: the PER-ISSUE comments
# endpoint SILENTLY IGNORES sort/direction. Against the live API, the id
# sequence for ?per_page=100 and ?per_page=100&sort=updated&direction=desc is
# byte-identical, so round 2 shipped a no-op. (The REPOSITORY-level endpoint
# /repos/O/R/issues/comments DOES honour sort -- verified the same way -- but it
# orders across EVERY issue in the repo, so on a busy repo page 1 can hold zero
# comments from the PR we are asking about. That trades a rare miss for a
# routine one.)
#
# So: walk this issue own comments, at most CR_WALK_MAX_PAGES pages of 100,
# stopping at the first page that carries the walkthrough or at a short page
# (which is the last one). At most 5 bounded calls, each under CR_GH_TIMEOUT.
# ponytail: 500 comments. Beyond that the walkthrough reads "none" and the
# caller stays fail-closed; raise the cap if a PR ever exceeds it.
#
# IDENTITY (HIMMEL-1058 stance, same as the review filter above): the
# walkthrough is only evidence when the BOT wrote it. Selecting on the marker
# text alone would let any user post a comment containing that string and flip
# a genuine stale-anchor BLOCK into a pass — the marker is public, visible in
# every CodeRabbit walkthrough on every PR. So require `user.type == "Bot"` AND
# a configured login. REST spells the login `coderabbitai[bot]` where GraphQL
# says `coderabbitai` (the landmine documented above), so normalize both sides
# with the same rule.
# shellcheck disable=SC2016  # jq program, not a shell variable
_CRF_WALK_JQ='
def norm: ascii_downcase | sub("\\[bot\\]$"; "");
($bots | split(" ") | map(select(length > 0))) as $set
| [ .[]?
    | select(.user.type == "Bot")
    | select((.user.login // "" | norm) as $l | $set | index($l) != null)
    | select(((.body // "") | contains("summarize by coderabbit.ai"))) ]
  | last | (.body // "")
'

cr_review_walkthrough() {
    local owner="$1" repo="$2" num="$3" head="$4"
    if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$num" ] || [ -z "$head" ]; then return 1; fi
    case "$num" in ''|*[!0-9]*) return 1 ;; esac

    local json body kind tok page maxp cnt bots
    bots=$(cr_review_bot_logins)
    maxp="${CR_WALK_MAX_PAGES:-5}"
    case "$maxp" in ''|*[!0-9]*) maxp=5 ;; esac
    [ "$maxp" -ge 1 ] || maxp=1

    body=""
    page=1
    while [ "$page" -le "$maxp" ]; do
        json=$(_crf_gh api "repos/$owner/$repo/issues/$num/comments?per_page=100&page=$page" 2>/dev/null) || return 1

        # Same canary posture as cr_review_freshness: a valid payload is an
        # array (possibly empty). An error object is cannot-evaluate, not "no
        # comments" — a page we could not read must never read as "absent".
        kind=$(printf '%s' "$json" | jq -r 'if type == "array" then "array" else empty end' 2>/dev/null || true)
        [ "$kind" = "array" ] || return 1

        body=$(printf '%s' "$json" | jq -r --arg bots "$bots" "$_CRF_WALK_JQ" 2>/dev/null || true)
        [ -n "$body" ] && [ "$body" != "null" ] && break
        body=""

        # A short page is the last page — stop rather than spend the cap.
        cnt=$(printf '%s' "$json" | jq -r 'length' 2>/dev/null || true)
        case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
        [ "$cnt" -lt 100 ] && break
        page=$((page + 1))
    done
    if [ -z "$body" ]; then printf 'none\n'; return 0; fi

    # Is THIS head the commit the walkthrough says it reviewed UP TO?
    #
    # Read only the two fields that carry that claim — "between <base> and
    # <oid>" and "up to `<short-oid>`" — never every hex token in the body
    # (CR round 4). A walkthrough is long prose that can name other commits in
    # passing; scanning it whole would let an incidental mention of the head
    # certify a review that never covered it, which is the same
    # evidence-means-something-else failure this whole change exists to remove.
    # Within a field a PREFIX test is right and safe: CodeRabbit abbreviates
    # there, and a 7+ hex prefix of this head is this head by git's own rule.
    local named=0 cands
    # `|| true`: grep exits 1 on no match, and a caller running with pipefail
    # must not see that as a lib failure (this file's stated convention).
    cands=$(
        {
            printf '%s' "$body" | grep -oE 'and [0-9a-f]{7,40}' 2>/dev/null
            printf '%s' "$body" | grep -oE 'up to [^0-9a-f]?[0-9a-f]{7,40}' 2>/dev/null
        } | grep -oE '[0-9a-f]{7,40}' 2>/dev/null
    ) || true
    for tok in $cands; do
        case "$head" in "$tok"*) named=1; break ;; esac
    done
    [ "$named" -eq 1 ] || { printf 'none\n'; return 0; }

    case "$body" in
        *"No actionable comments were generated"*) printf 'clean\n' ;;
        *) printf 'dirty\n' ;;
    esac
    return 0
}

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
        -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(last:100){totalCount nodes{author{login __typename} commit{oid} state body comments(first:1){totalCount}}}}}}' \
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
        fresh\ *) printf '%s\n' "$result"; return 0 ;;
        stale\ *)
            # HIMMEL-1824: no OBJECT at head is not the same claim as "the head
            # was not reviewed". Before reporting stale, ask the channel a clean
            # pass actually uses. A walkthrough that names this head and reports
            # no actionable comments IS the App's verdict on this head.
            # Fail-closed: an unreadable walkthrough leaves the stale verdict
            # exactly as it was, so this can only ever turn a false BLOCK into a
            # pass, never a real block into one.
            #
            # ONLY the stale arm needs this, and that is not an oversight (CR
            # round 1 read it as one). "stale" is the sole BLOCKING state: the
            # caller self-skips on "none" (absence of a bot review is not
            # evidence of staleness, and cr-signal.sh already required a
            # concluded status), so a PR with no review object but a clean
            # walkthrough at head already passes. Consulting the walkthrough
            # there would spend a call to change nothing.
            # Minting this state does NOT assert the pass concluded — see the
            # caller precondition in the header. Every current consumer gates
            # on the bot status before it reaches this state, and the canary
            # keeps it that way.
            local walk
            walk=$(cr_review_walkthrough "$owner" "$repo" "$num" "$head" 2>/dev/null || true)
            if [ "$walk" = "clean" ]; then
                printf 'fresh-clean-no-object %s\n' "${result#stale }"
                return 0
            fi
            printf '%s\n' "$result"; return 0 ;;
        *) return 1 ;;
    esac
}
