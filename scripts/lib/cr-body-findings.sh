#!/usr/bin/env bash
# cr-body-findings.sh — reads CodeRabbit's REVIEW-BODY findings for a head SHA
# (HIMMEL-1126 / HIMMEL-1147).
#
# WHY THIS EXISTS — S1, the shape the thread gates cannot see:
# cr-merge-gate.sh (HIMMEL-936/1072) and cr-signal.sh (HIMMEL-1058) both gate
# on evidence with its own GraphQL/REST identity: unresolved review THREADS,
# and the commit STATUS. Neither of those surfaces sees findings CodeRabbit
# posts only inside the review BODY's collapsible sections — "Outside diff
# range comments" (findings on lines outside the diff hunk, which CodeRabbit
# cannot anchor as an inline thread at all) and "Nitpick comments" (posted
# inline as regular threads in the same PR-review call, but bucketed into a
# lower-severity section rather than surfaced as a blocking thread). A merge
# gate that only counts unresolved threads is blind to outside-diff findings
# by construction — there is no thread for them to unresolve. That gap is
# what this reader closes: it parses the review BODY TEXT itself, the only
# place these findings are recorded.
#   - HIMMEL-1126: "outside diff range" findings are real, un-actioned
#     defects the thread gate never saw. Callers treat outside>0 as BLOCKING.
#   - HIMMEL-1147: "nitpick" findings are lower-severity by CodeRabbit's own
#     classification. Callers treat nitpick>0 as SURFACED / non-blocking
#     (report it, do not deny the merge on it alone).
#
# IDENTITY (HIMMEL-1058, same rationale as cr-signal.sh): match the review's
# AUTHOR by `.user.id`, never by login. `coderabbitai` (no `[bot]` suffix) is
# a bare-login match that has nearly missed findings twice before — logins
# are mutable and spoofable, the numeric id is not. `.user.id == 136622811`
# is coderabbitai[bot]; anything else is not CodeRabbit, full stop, even if
# the body text is byte-identical (see the identity test case in the paired
# suite).
#
# EMOJI TOLERANCE: CodeRabbit prefixes each section heading with an emoji
# ("⚠️ Outside diff range comments (2)", "🧹 Nitpick comments (1)") that is
# not guaranteed stable across CodeRabbit releases. The match patterns below
# anchor on the WORD, not the emoji, and tolerate an emoji/whitespace prefix
# in front of it by simply never requiring one.
#
# THE TRI-STATE RC CONTRACT — the whole point of this file existing as a
# reader rather than a one-off grep: CodeRabbit's body format is UNVERSIONED
# prose, not a schema. A wording change ("Outside-diff comments", a renamed
# section, a dropped count) would make the count regex below silently stop
# matching — and a silent 0 reads exactly like "CodeRabbit found nothing",
# which is a false ALLOW on the HIMMEL-1126 blocking path. So this reader
# distinguishes two very different kinds of "cannot certify":
#   rc 1 — INFRASTRUCTURE cannot-evaluate: the `gh api` query itself failed,
#     or the payload is not the JSON array shape this endpoint always
#     returns. There is no information here at all — the same fail-closed
#     contract as cr-signal's "paged" state.
#   rc 2 — an ANTI-DRIFT CANARY fired: the query succeeded and the body is
#     right there, but the parser could not make sense of it — POSITIVE
#     evidence of an unparseable finding, not an absence of one. Two
#     independent canaries both land here:
#     1. The chosen head-review body contains the literal phrase (e.g.
#        "Outside diff") but the count regex does NOT match a `(N)` on it ->
#        format drifted out from under the count regex.
#     2. `markers>0` (i.e. CodeRabbit's own `cr-comment:v1:<id>` markers are
#        present in the chosen body) while EVERY section count parsed to 0 ->
#        CodeRabbit said something, this reader parsed nothing: drift, not an
#        empty review.
# Callers must not treat EITHER rc 1 or rc 2 as green — the two-way split
# exists so a caller can apply a different fail posture to "the query broke"
# (rc 1) than to "CodeRabbit said something the parser could not count"
# (rc 2): see check-ci.sh (fails closed on both, identically) and
# cr-merge-gate.sh (fails OPEN on rc 1, BLOCKS on rc 2 — spec §4).
#
# WHAT COUNTS AS "AT HEAD": a review's `.commit_id` is the SHA it reviewed.
# outside/nitpick/additional/markers are derived from the LATEST SUBSTANTIVE
# review at the CALLER's head SHA — NOT summed across every head review
# (HIMMEL-1582). `head_reviews` still counts ALL bot reviews at the head
# (callers rely on head_reviews==0 meaning "no review at head yet"). Reviews
# at any OTHER commit_id (a prior head, before a force-push or fixup) feed
# only `prior_outside` — enough for a caller to apply the HIMMEL-1126
# addendum A2 "stale head" rule (prior_outside>0 with head_reviews==0 ⇒
# cannot certify — an older head had unaddressed outside-diff findings, but
# no review exists yet at the current head) without this reader making that
# policy call itself.
#
# WHY LATEST-SUBSTANTIVE-WINS — not a sum, and not naive latest-wins
# (HIMMEL-1582). The old derivation SUMMED outside/nitpick/additional/markers
# across every review at the head. A sum is monotonically non-decreasing at a
# fixed head SHA, so once a finding enters it a later, cleaner review can never
# clear it — a disproved finding BLOCKS forever unless the head moves. That is
# a false-BLOCK, which this project's Phase 0 exit criterion forbids by name
# alongside false-green. Two measurements settled the shape of the fix:
#   1. Sibling splits do not happen. A census over 60 PRs (16 head-groups with
#      >=2 reviews at one head) found ZERO groups where two reviews at the same
#      head both carry a nonzero section count, and zero where the sum exceeded
#      the max — a synthetic split pushed through the classifier was reported
#      correctly, so the zero is a measurement, not a blind instrument. The
#      sum is therefore never load-bearing: dropping it loses no finding.
#   2. But naive "latest review wins" is UNSAFE. On PR #1583 at head 0b464884
#      the two bot reviews were a substantive one (outside=1) followed by a
#      LATER review with an EMPTY body. A plain latest-wins would read the
#      empty body and report outside=0 — a false-GREEN produced by an empty
#      payload, the worst outcome (a silent 0 reads exactly like "CodeRabbit
#      found nothing", a false ALLOW on the HIMMEL-1126 blocking path).
# So: SUBSTANTIVE = the body is non-empty after trimming whitespace (a review
# object with no body is skipped). LATEST = greatest `.submitted_at`, ties
# broken by greatest `.id` (both present on every review in this payload).
# outside/nitpick/additional/markers come from that ONE review, and the
# anti-drift canaries below are scoped to it too — a stale drifted body at an
# old-but-same-head review is the identical defect shape and must not block
# forever either. If there are head reviews but NONE is substantive (all empty
# bodies), the counts are reported as 0 with a stderr note (NOT silently
# green); the existing markers>0/all-zero canary still governs. prior_outside
# stays a SUM across non-head commits and is untouched. Zero reviews AT HEAD
# is not an error: it is reported (all head counts 0, rc 0) with a stderr
# note, and left to the caller to combine with prior_outside / cr-signal.
#
# cr_body_findings <owner> <name> <pr-number> <head-sha>
#   stdout (rc 0): one line —
#     outside=<n> nitpick=<n> additional=<n> prior_outside=<n> markers=<n> head_reviews=<n> substantive=<n>
#   `head_reviews` counts EVERY bot review at the head; `substantive` counts
#   only those with a non-empty body. A caller asking "did the review I
#   requested actually arrive?" must read `substantive` — CodeRabbit posts
#   empty review objects on incremental passes, so head_reviews>0 alone is
#   satisfied by a review that says nothing (HIMMEL-1959).
#   rc 0 = determined (incl. zero head reviews); rc 1 = INFRASTRUCTURE
#   cannot-evaluate (query failure, non-array payload); rc 2 = an anti-drift
#   canary fired (positive evidence of an unparseable finding).
#
# Env:
#   CR_BOT_USER_ID   creator/author id to trust (default 136622811, via
#                    cr_signal_bot_id — shared with cr-signal.sh so every
#                    gate agrees on what "CodeRabbit" means by construction).
#   GH_CMD           gh override (test seam, matches cr-signal.sh / cr-merge-gate.sh)
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`; does
# not toggle set -e. Each jq command substitution is set -e-safe with a
# trailing `|| true` inside the subshell, matching cr-merge-gate.sh, so a
# `set -e` caller never aborts on a parse failure. bash 3.2-safe (no
# mapfile/assoc arrays).

_cbf_gh() { "${GH_CMD:-gh}" "$@"; }

# The ONE reader for CodeRabbit's identity (HIMMEL-1058). Sourced relative to
# this file so a hook/script can source this reader from any cwd.
# shellcheck source=scripts/lib/cr-signal.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-signal.sh"

# The jq program is a single argument (no embedded single-quotes) so it can
# stay a plain single-quoted string like cr-merge-gate.sh's GraphQL query.
# Every section-count pattern uses `[(]`/`[)]` rather than `\(`/`\)` — inside
# a jq string literal `\(` opens string interpolation, so a backslash-escaped
# literal paren would need to survive an extra layer of escaping for no
# benefit; the bracket form is a plain single character class instead.
# shellcheck disable=SC2016  # this is a jq program, not a shell variable
_CBF_JQ_PROGRAM='
def outside_re: "[Oo]utside diff range comments? [(]([0-9]+)[)]";
def nitpick_re: "[Nn]itpick comments? [(]([0-9]+)[)]";
def additional_re: "[Aa]dditional comments? [(]([0-9]+)[)]";
def marker_re: "cr-comment:v1:[A-Za-z0-9]+";
def loose_outside_re: "[Oo]utside diff";
def loose_nitpick_re: "[Nn]itpick comments?";
def loose_additional_re: "[Aa]dditional comments?";
def sum_matches(re):
  ( [ scan(re) ] | map( (if type=="array" then .[0] else . end) | tonumber ) | add ) // 0;
def count_matches(re):
  ( [ scan(re) ] | length );
def has_content: test("\\S");
( [ .[] | select(.user.id == $uid) ] ) as $bot
| ( [ $bot[] | select(.commit_id == $head) ] ) as $headr
| ( [ $bot[] | select(.commit_id != $head) ] ) as $priorr
# HIMMEL-1582: derive at-head counts from the LATEST SUBSTANTIVE head review,
# not a sum over every head review. $sub = head reviews whose body has any
# non-whitespace; $chosen = the latest such body (greatest submitted_at, ties
# by greatest id), or "" when none is substantive. See header for the why.
| ( [ $headr[] | select((.body // "") | has_content) ] ) as $sub
| ( $sub | sort_by(.submitted_at, .id) | .[-1] | (.body // "") ) as $chosen
| ( [ $priorr[] | (.body // "") ] ) as $pb
| {
    outside:       ( $chosen | sum_matches(outside_re) ),
    nitpick:       ( $chosen | sum_matches(nitpick_re) ),
    additional:    ( $chosen | sum_matches(additional_re) ),
    prior_outside: ( [ $pb[] | sum_matches(outside_re) ]    | add // 0 ),
    markers:       ( $chosen | count_matches(marker_re) ),
    outside_drift:    ( $chosen | (test(loose_outside_re)    and (test(outside_re)|not)) ),
    nitpick_drift:    ( $chosen | (test(loose_nitpick_re)    and (test(nitpick_re)|not)) ),
    additional_drift: ( $chosen | (test(loose_additional_re) and (test(additional_re)|not)) ),
    head_count:  ($headr | length),
    substantive: ($sub | length)
  }
'

cr_body_findings() {
    local owner="$1" name="$2" num="$3" head="$4"
    local uid
    uid=$(cr_signal_bot_id)

    if [ -z "$owner" ] || [ -z "$name" ] || [ -z "$num" ] || [ -z "$head" ]; then return 1; fi
    case "$uid" in ''|*[!0-9]*) return 1 ;; esac
    case "$num" in ''|*[!0-9]*) return 1 ;; esac

    # `--paginate` emits ONE top-level JSON array per page when a PR has more
    # reviews than fit on one page (>30) — NOT one pre-merged array. Capture
    # the raw multi-document stream first (with gh's own failure still
    # `return 1`), THEN flatten with `jq -s 'add'`: slurp-mode reads every
    # top-level value on stdin into an array-of-arrays, `add` concatenates
    # them into one flat array. A single-page (single-array) response slurps
    # to `[[...]]` -> `add` gives back the same array unchanged, so this is a
    # strict superset of the old single-array behavior, not a special case of
    # it. Without this, a >30-review PR fed the raw multi-array stream to the
    # `type=="array"` canary below, which sees a stream of top-level values
    # (not one value) and reads as cannot-evaluate — silently rc 1 on every
    # big PR (codex CR, HIMMEL-1126 follow-up).
    local raw json
    raw=$(_cbf_gh api "repos/$owner/$name/pulls/$num/reviews" --paginate 2>/dev/null) || return 1
    json=$(printf '%s' "$raw" | jq -s 'add // []' 2>/dev/null) || return 1

    # Canary (mirrors cr-signal.sh): a valid payload is a JSON array
    # (possibly empty). An error object or a parse failure is cannot-evaluate,
    # distinct from a well-formed empty array (which is legitimately "no
    # reviews yet").
    local kind
    kind=$(printf '%s' "$json" | jq -r 'if type=="array" then "array" else empty end' 2>/dev/null || true)
    [ "$kind" = "array" ] || return 1

    local result
    result=$(printf '%s' "$json" | jq -c --argjson uid "$uid" --arg head "$head" \
        "$_CBF_JQ_PROGRAM" 2>/dev/null || true)
    [ -n "$result" ] || return 1

    local line outside nitpick additional prior_outside markers head_count substantive outside_drift nitpick_drift additional_drift
    line=$(printf '%s' "$result" | jq -r \
        '[.outside,.nitpick,.additional,.prior_outside,.markers,.head_count,.substantive,(.outside_drift|tostring),(.nitpick_drift|tostring),(.additional_drift|tostring)] | @tsv' \
        2>/dev/null || true)
    [ -n "$line" ] || return 1
    IFS=$'\t' read -r outside nitpick additional prior_outside markers head_count substantive outside_drift nitpick_drift additional_drift <<<"$line"

    case "$outside$nitpick$additional$prior_outside$markers$head_count$substantive" in
        *[!0-9]*|'') return 1 ;;
    esac

    # Anti-drift canaries (see header). Any one firing is POSITIVE evidence
    # of an unparseable finding, not an absence of one -> rc 2, never a
    # silent zero.
    if [ "$outside_drift" = "true" ] || [ "$nitpick_drift" = "true" ] || [ "$additional_drift" = "true" ]; then
        return 2
    fi
    if [ "$markers" -gt 0 ] && [ "$outside" -eq 0 ] && [ "$nitpick" -eq 0 ] && [ "$additional" -eq 0 ]; then
        return 2
    fi

    if [ "$head_count" -eq 0 ]; then
        echo "cr-body-findings: no CodeRabbit review at head $head for PR #$num (owner=$owner name=$name)" >&2
    elif [ "$substantive" -eq 0 ]; then
        # HIMMEL-1582: head reviews exist but NONE is substantive (all empty
        # bodies). Counts are 0, but this is NOT silently green — flag it.
        echo "cr-body-findings: $head_count CodeRabbit review(s) at head $head but none carried a substantive body (all empty) for PR #$num (owner=$owner name=$name)" >&2
    fi

    printf 'outside=%s nitpick=%s additional=%s prior_outside=%s markers=%s head_reviews=%s substantive=%s\n' \
        "$outside" "$nitpick" "$additional" "$prior_outside" "$markers" "$head_count" "$substantive"
    return 0
}
