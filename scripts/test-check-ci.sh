#!/usr/bin/env bash
# Tests for scripts/check-ci.sh (HIMMEL-949).
#
# Hermetic: `gh` is a PATH stub whose behavior is driven by GH_STUB_MODE +
# counter files; CHECK_CI_POLL_INTERVAL=0 removes the grace-window sleeps,
# CHECK_CI_SETTLE=0 disables the settle round unless a case opts in, and the
# escalation wait defaults to 0 so ordinary bounded-loop cases never sleep.
# Never talks to GitHub.
#
# HIMMEL-1953: no case may consume real wall clock waiting on a simulated poll —
# CHECK_CI_SLEEP_CMD=: neutralizes check-ci.sh's three sleeps — and no case may
# run unbounded: each is wrapped in `timeout` (CHECK_CI_CASE_TIMEOUT, default
# 600s), so a stuck case FAILS with its number instead of hanging the suite.
#
# Cases:
#   1.  no PR for branch                     → rc 2, stderr echoes gh error
#   2.  "no checks reported" twice, then registered + watch green,
#       0 unresolved threads                 → rc 0
#   3.  checks registered, watch red         → rc 1, FAILED + fast-red hint
#   4.  checks never register, --grace 0     → rc 2, "no checks registered"
#   5.  unknown option                       → rc 2, usage, no verdict line
#   5b. --help                               → rc 0, usage, no verdict line
#   (1/2/3/11 additionally assert exactly one exact-match
#   "check-ci: verdict exit=N" line — HIMMEL-974)
#   6.  --grace non-numeric                  → rc 2
#   7.  two positional selectors             → rc 2
#   8.  selector is passed through to gh as an exact token
#   9.  settle round catches a late red (green watch 1, red watch 2) → rc 1
#   10. settle round green twice             → rc 0, exactly 2 watch calls
#   11. checks green, 2 unresolved threads   → rc 3
#   12. checks green, thread query fails     → rc 2 (fail-closed gate)
#   13. non-numeric CHECK_CI_POLL_INTERVAL   → warns, falls back, still runs
#   14. --settle non-numeric                 → rc 2
#   15. --threads-only + unresolved threads  → rc 3, and NO gh pr checks calls
#   16. unresolved thread on page TWO        → rc 3 (pagination, codex round 2)
#   17. probe gh error (auth/network)        → rc 2, never a fake red (codex round 3)
#   18. PR head moves during the run         → rc 2 (verdict bound to head SHA)
#   19. CHANGES_REQUESTED review             → rc 3 (codex round 4)
#   20. gh error mid-watch (auth/network)    → rc 2, never a fake red (CR follow-up)
#   21. malformed hasNextPage (not true/false) → rc 2 (CR follow-up)
#   22. hasNextPage true with empty/null cursor → rc 2 (CR follow-up)
#   23. cursor repeats with hasNextPage=true → rc 2 on query two, no infinite loop (CR follow-up)
#   24. non-adjacent A→B→A cursor cycle      → rc 2 via the 50-page cap (codex follow-up)
#   25. watch exits non-1 with empty stderr  → rc 2, only gh rc 1 is a red check (CR follow-up)
#   26. watch rc 1 but zero checks in the fail bucket → rc 2 (structured red confirm, codex)
#   39. incremental-silent body shape       → rc 4 + full-review instruction
#   43. zero head reviews, no prior finding → rc 0 (PR #1321 benign shape)
#   44. --escalate posts once, head review appears → rc 0
#   45. --escalate sees per-head marker      → rc 0, no duplicate post
#   46. --escalate budget expires            → rc 4 + DO-NOT-MERGE
#   47. malformed wait + zero escalation poll → warn + fallback, still evaluates
#   48. escalated review has outside finding → rc 3 (normal evaluation preserved)
#   49. escalated review creates new thread → rc 3 (thread re-check preserved)
#   50. positive wait + zero escalation poll → rc 4, at most 3 body reads
#   51. leading-zero wait 08 (octal crash)  → normalized to 8, rc 4, no arithmetic error
#   52. leading-zero wait 007 (silent octal) → normalized to decimal 7, rc 0
#   77. B2 --escalate refreshes stale anchor → rc 0, full-review marker posted
#   78. B2 escalated review stays stale      → rc 4, STILL not anchored
#   79. B2 escalation budget expires         → rc 4, DO-NOT-MERGE timeout
#   80. B2 without --escalate                → rc 4, zero comment posts
#   81. B2 contradictory head review         → rc 4, zero comment posts
#   82. B2 escalated outside finding         → rc 3, body gate still blocks
#   83. B2 escalation with a concluded head status → rc 0 (unchanged), stderr
#       carries the HIMMEL-1698 benign-anchor NOTE
#   84. --escalate sees only an EMPTY review object → rc 4 (HIMMEL-1959)
#   85. persisted EMPTY review object still escalates → rc 4 (HIMMEL-1959)
#   86. persisted EMPTY review object refuses read-only → rc 4 (HIMMEL-1959)
#   87. "Review completed" + ZERO CodeRabbit reviews PR-wide → rc 2 (HIMMEL-1374)
#   88. rate-limited + zero PR-wide reviews + clean panel → rc 0 (carry intact)
#   89. "Review completed" + a PR-wide review present → rc 0 (no false block)
#   90. a competing claim with a lower id wins → 0 requests from the loser (HIMMEL-1964)
#   91. stranded attempt 1 → one bounded re-request as attempt 2, rc 4
#   92. stranded attempt 2 → rc 4 STRANDED, no third request
#   93. full-review POST fails after the claim → claim rolled back, rc 2
set -uo pipefail

# HIMMEL-1495 — an --automerge-armed launching shell carries ARMAUTOMERGE=1 +
# CR_MERGE_GATE_OK=1 by design; an ambient value in the operator's shell must
# not decide the result (the 34e/34f precedent that lives in THIS file,
# generalized to the armed-session bypass pair). check-ci.sh does not consult
# either var today, so this is defense-in-depth for the day a sourced lib reads
# one — case 58 below pins today's insensitivity.
unset ARMAUTOMERGE CR_MERGE_GATE_OK

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/check-ci.sh"

PASS=0; FAIL=0; COUNT=0; STUBDIR=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$STUBDIR" ] && [ -d "$STUBDIR" ]; then rm -rf "$STUBDIR" 2>/dev/null || true; fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

# Fail closed on stub setup: a missing/broken stub would fall through to the
# REAL gh on PATH and turn this "hermetic" suite into live GitHub calls.
STUBDIR=$(mktemp -d) || { echo "FATAL: mktemp -d failed"; exit 1; }
if [ -z "$STUBDIR" ] || [ ! -d "$STUBDIR" ]; then echo "FATAL: no stub dir"; exit 1; fi
cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub for test-check-ci.sh — checks behavior via GH_STUB_MODE, probe/watch/
# api/review/comment counters via GH_STUB_COUNT / GH_STUB_WATCH / GH_STUB_API /
# GH_STUB_STATUSES / GH_STUB_REVIEWS / GH_STUB_FRESHNESS_READS /
# GH_STUB_COMMENTS files, escalation-claim state via GH_STUB_CLAIMS (posted
# claims, replayed by later comment lists) + GH_STUB_MARKERS (claims a previous
# invocation left behind: "seed:<id>:<attempt>" always listed,
# "race:<id>:<attempt>" listed only once this run posted a claim),
# unresolved-thread count via
# GH_STUB_THREADS ("fail" makes the graphql call
# error; "paged" puts the unresolved thread on page two). graphql pages are
# echoed in the script's parsed shape: "<count> <hasNextPage> <endCursor>".
# Args are logged to GH_STUB_ARGS.
echo "$*" >> "$GH_STUB_ARGS"
cmd="${1:-}"
if [ "$cmd" = "api" ]; then
    case " $* " in
        *" --paginate repos/octo/demo/pulls/42/files "*)
            case "${GH_STUB_FILES:-README.md}" in
                fail) echo "files boom" >&2; exit 1 ;;
                malformed) echo '{not-json' ;;
                truncated) jq -nc '[{filename:"README.md",status:"modified"}]' ;;
                renamed:*)
                    rename_spec=${GH_STUB_FILES#renamed:}
                    previous=${rename_spec%%:*}
                    filename=${rename_spec#*:}
                    jq -nc --arg filename "$filename" --arg previous "$previous" \
                        '[{filename:$filename,status:"renamed",previous_filename:$previous}]' ;;
                *) jq -nc --arg filename "${GH_STUB_FILES:-README.md}" '[{filename:$filename,status:"modified"}]' ;;
            esac
            exit 0 ;;
    esac
    case "${2:-}" in
        repos/octo/demo/commits/sha1/check-runs*)
            echo '{"check_runs":[]}'
            exit 0 ;;
        # CodeRabbit's REAL shape: a commit STATUS on the head SHA, carrying
        # creator identity (HIMMEL-1072/1058). The list endpoint is newest-first.
        # 136622811 = coderabbitai[bot].
        repos/octo/demo/commits/sha1/statuses*)
            case "$GH_STUB_MODE" in
                cr-absent)      echo '[]' ;;
                cr-pending)     echo '[{"context":"CodeRabbit","state":"pending","created_at":"2026-07-16T19:08:46Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                cr-failure)     echo '[{"context":"CodeRabbit","state":"failure","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                cr-spoofed)     echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":999999,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                cr-query-error) echo "statuses boom" >&2; exit 1 ;;
                # HIMMEL-1317: the REAL payload a repo with automatic reviews
                # disabled gets on every untriggered PR. state=success, and the
                # refusal lives ONLY in .description — which this reader used to
                # drop, making a declined review byte-identical to a clean one.
                cr-skipped)     echo '[{"context":"CodeRabbit","state":"success","description":"Review skipped: automatic reviews are disabled","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                cr-desc-error)
                    s=$(cat "$GH_STUB_STATUSES" 2>/dev/null)
                    s=${s:-0}
                    echo $((s+1)) > "$GH_STUB_STATUSES"
                    if [ "$s" -eq 0 ]; then
                        echo '[{"context":"CodeRabbit","state":"success","description":"Review skipped: automatic reviews are disabled","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]'
                    else
                        echo "statuses boom" >&2; exit 1
                    fi ;;
                # The positive control for the pair: the SAME state with a real
                # review. Without it the skip assertion could be satisfied by
                # breaking `success` outright, which would pass while making the
                # gate useless — the parent lesson's instance #6, in this suite.
                cr-completed)   echo '[{"context":"CodeRabbit","state":"success","description":"Review completed","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                # glm-1: a COMPLETED review whose wording merely CONTAINS
                # skip-ish words. The first cut of the skip regex carried a bare
                # `no review` alternative, which matches this and would have
                # blocked a clean merge — a false positive fails toward RED and
                # cannot be cleared by re-running, unlike a false negative which
                # merely restores the old behaviour. Pins the regex to
                # unambiguous phrasings.
                cr-nearmiss)    echo '[{"context":"CodeRabbit","state":"success","description":"No review changes requested","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                # HIMMEL-1354: the REAL payload observed on PR #1456 @ 46358386
                # on 2026-07-28 when CodeRabbit declined for rate limiting.
                # state=success again, refusal again only in .description — and
                # this wording matched NONE of the HIMMEL-1317 deny-list
                # alternatives, so it classified as a clean success and check-ci
                # printed "all checks green" + "verdict exit=0" on a head that
                # had no review at all.
                cr-ratelimited) echo '[{"context":"CodeRabbit","state":"success","description":"Review rate limited","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                # HIMMEL-1354: a wording NOBODY has enumerated, in either list.
                # Under the old deny-list this passed as clean by default; under
                # the allow-list it fails CLOSED. This is the structural point of
                # the inversion — it asserts behaviour on the UNKNOWN case, which
                # is the one that keeps producing incidents.
                cr-unknownword) echo '[{"context":"CodeRabbit","state":"success","description":"Review deferred for reasons we have never seen","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                # CR follow-up (HIMMEL-1354 R2): jq's test() is an UNANCHORED
                # search, so an unanchored allow-list SUBSTRING-matches this
                # description ("No review completed" contains "review
                # completed") and would read as a clean success — reopening
                # the exact hole HIMMEL-1354 exists to close. Pins that the
                # built-in default is anchored so only an EXACT allow-listed
                # description passes.
                cr-substrmatch) echo '[{"context":"CodeRabbit","state":"success","description":"No review completed","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
                # A full page with no CodeRabbit on it: indeterminate, not
                # absent — the verdict may be on page two (coderabbit-2).
                cr-paged)       jq -nc '[range(100) | {context: "ci/ctx\(.)", state: "success", created_at: "2026-07-16T19:10:05Z", creator: {id: 1, login: "ci", type: "Bot"}}]' ;;
                # body-* modes: CodeRabbit CONCLUDED success on this head
                # (default case below already covers it); only the reviews
                # fixture below differs per mode.
                *)              echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
            esac
            exit 0 ;;
        # CodeRabbit's review-BODY findings (HIMMEL-1126/1147) — a separate
        # endpoint from the commit status above; head-independent (the real
        # API lists every review on the PR, filtering by commit_id is the
        # reader's job). Default '[]' (no review posted yet) keeps every
        # UNRELATED case above reaching this point rc-0/all-zero, so their
        # assertions stay exactly as they were before this gate existed.
        repos/octo/demo/pulls/42/reviews*)
            case "$GH_STUB_MODE" in
                body-outside) echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"Outside diff range comments (2)"}]' ;;
                body-nitpick) echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"Nitpick comments (1)"}]' ;;
                body-drift)   echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"Outside diff range comments were noted but the count did not survive a format change"}]' ;;
                body-error)   echo "reviews boom" >&2; exit 1 ;;
                # Incremental-silent shape: a prior review carries outside-diff
                # findings while the concluded current head has no review object.
                body-a2)
                    echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"}]' ;;
                body-a2-timeout|body-a2-postfail)
                    a=$(cat "$GH_STUB_REVIEWS" 2>/dev/null)
                    a=${a:-0}
                    echo $((a+1)) > "$GH_STUB_REVIEWS"
                    echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"}]' ;;
                # Escalation modes expose the same stale shape on the first read,
                # then a clean review object at sha1 on the bounded re-read.
                body-a2-escalate|body-a2-marker|body-a2-escalate-outside)
                    a=$(cat "$GH_STUB_REVIEWS" 2>/dev/null)
                    a=${a:-0}
                    echo $((a+1)) > "$GH_STUB_REVIEWS"
                    if [ "$a" -eq 0 ]; then
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"}]'
                    elif [ "$GH_STUB_MODE" = "body-a2-escalate-outside" ]; then
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"},{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"Outside diff range comments (1)"}]'
                    else
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"},{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"**Actionable comments posted: 0**"}]'
                    fi ;;
                # HIMMEL-1959: the escalation request lands, but the ONLY
                # thing that ever appears at the head is an EMPTY incremental
                # review object. That is review evidence at the head which is
                # NOT the requested full review — head_reviews>0 while
                # substantive==0 — so the poll must not accept it.
                # HIMMEL-1959 CR round 1: the SECOND invocation. The empty
                # review object from a prior escalation has PERSISTED at the
                # head, so it is present on the very first read of this run.
                # A2 must still fire — keying its entry on head_reviews made
                # this run skip escalation entirely and exit 0 on a review
                # that never arrived.
                body-a2-empty-persisted)
                    echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"},{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":""}]' ;;
                body-a2-escalate-empty)
                    a=$(cat "$GH_STUB_REVIEWS" 2>/dev/null)
                    a=${a:-0}
                    echo $((a+1)) > "$GH_STUB_REVIEWS"
                    if [ "$a" -eq 0 ]; then
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"}]'
                    else
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"},{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":""}]'
                    fi ;;
                # B2 starts with no head review and no prior body finding, so A2
                # stays dormant. The bounded re-read then exposes the full review.
                body-b2-escalate|body-b2-escalate-outside)
                    a=$(cat "$GH_STUB_REVIEWS" 2>/dev/null)
                    a=${a:-0}
                    echo $((a+1)) > "$GH_STUB_REVIEWS"
                    if [ "$a" -eq 0 ]; then
                        echo '[]'
                    elif [ "$GH_STUB_MODE" = "body-b2-escalate-outside" ]; then
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"Outside diff range comments (1)"}]'
                    else
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"**Actionable comments posted: 0**"}]'
                    fi ;;
                body-b2-timeout) echo '[]' ;;
                body-b2-head-review) echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":""}]' ;;
                body-empty) echo '[]' ;;
                *)          echo '[]' ;;
            esac
            exit 0 ;;
        repos/octo/demo/issues/42/comments*)
            case " $* " in
                *" -f body="*)
                    # The full-review REQUEST fails while claims still succeed:
                    # the partial-failure shape case 93 pins (HIMMEL-1964).
                    if [ "$GH_STUB_MODE" = "body-a2-postfail" ]; then
                        case " $* " in
                            *"body=@coderabbitai"*) echo "comment post boom" >&2; exit 1 ;;
                        esac
                    fi
                    # HIMMEL-1964: ids ascend with the post order (as GitHub's
                    # do — that ordering IS the single-flight tie-break), and a
                    # posted CLAIM is remembered so a later list replays it.
                    c=$(cat "$GH_STUB_COMMENTS" 2>/dev/null)
                    c=${c:-0}
                    c=$((c+1))
                    echo "$c" > "$GH_STUB_COMMENTS"
                    for a in "$@"; do
                        case "$a" in
                            body=*himmel:cr-escalate:*) printf '%s %s\n' "$((1000+c))" "${a#body=}" >> "$GH_STUB_CLAIMS" ;;
                        esac
                    done
                    # --jq '.id' shape: the caller reads a bare number.
                    echo "$((1000+c))" ;;
                *)
                    # List shape after the caller's --jq: "<comment-id> <marker>".
                    # GH_STUB_MARKERS seeds markers a PREVIOUS invocation left
                    # behind: "seed:<id>:<attempt>" is always listed;
                    # "race:<id>:<attempt>" appears only once a claim has been
                    # posted in this run — a competing caller whose claim landed
                    # concurrently with ours and got the lower id.
                    if [ "$GH_STUB_MODE" = "body-a2-marker" ]; then
                        # The pre-HIMMEL-1964 marker: no attempt= field.
                        echo '900 <!-- himmel:cr-escalate:sha1 -->'
                    fi
                    oldifs=$IFS; IFS=,
                    for spec in ${GH_STUB_MARKERS:-}; do
                        [ -n "$spec" ] || continue
                        kind=${spec%%:*}; rest=${spec#*:}
                        mid=${rest%%:*}; att=${rest#*:}
                        if [ "$kind" = "race" ] && [ ! -s "$GH_STUB_CLAIMS" ]; then continue; fi
                        echo "$mid <!-- himmel:cr-escalate:sha1 attempt=$att -->"
                    done
                    IFS=$oldifs
                    if [ -s "$GH_STUB_CLAIMS" ]; then cat "$GH_STUB_CLAIMS"; fi ;;
            esac
            exit 0 ;;
        repos/octo/demo/issues/comments/*)
            # Claim rollback (HIMMEL-1964): DELETE of a single comment by id.
            exit 0 ;;
    esac
    # CodeRabbit's review-FRESHNESS query (HIMMEL-1181) — a separate GraphQL
    # query from the reviewThreads one below (both are `gh api graphql`, so
    # this MUST be intercepted first on query text, before the GH_STUB_THREADS
    # fallthrough — the reviews query must not consume the GH_STUB_API
    # counters the thread-pagination modes use). Default 'fresh' (anchored to
    # sha1) keeps every UNRELATED case above reaching this point unaffected —
    # same "default keeps old assertions" convention as the body-findings
    # gate's default '[]'.
    #
    # Every BOT node carries a non-empty `body` and a non-zero
    # `comments.totalCount` on purpose: HIMMEL-1824 taught the reader to DROP
    # empty review shells (`chat.auto_reply` and incremental passes mint
    # COMMENTED objects with neither), so a bodyless fixture classifies as
    # `none` no matter which oid it names — silently disarming both the
    # `fresh` default and every `stale` case here (HIMMEL-1374, 2026-08-20).
    case "$*" in
        *"reviews(last:"*)
            case "${GH_STUB_FRESHNESS:-fresh}" in
                fresh)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"sha1"},"state":"COMMENTED","body":"fixture review body","comments":{"totalCount":1}}]}}}}}' ;;
                stale)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"shaOLD"},"state":"COMMENTED","body":"fixture review body","comments":{"totalCount":1}}]}}}}}' ;;
                staleflip)
                    a=$(cat "$GH_STUB_FRESHNESS_READS" 2>/dev/null)
                    a=${a:-0}
                    echo $((a+1)) > "$GH_STUB_FRESHNESS_READS"
                    if [ "$a" -eq 0 ]; then
                        echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"shaOLD"},"state":"COMMENTED","body":"fixture review body","comments":{"totalCount":1}}]}}}}}'
                    else
                        echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":2,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"sha1"},"state":"COMMENTED","body":"fixture review body","comments":{"totalCount":1}}]}}}}}'
                    fi ;;
                none)     echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"human","__typename":"User"},"commit":{"oid":"sha1"},"state":"COMMENTED","body":"fixture review body","comments":{"totalCount":1}}]}}}}}' ;;
                paged)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":150,"nodes":[]}}}}}' ;;
                mybot)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"mybot","__typename":"Bot"},"commit":{"oid":"sha1"},"state":"COMMENTED","body":"fixture review body","comments":{"totalCount":1}}]}}}}}' ;;
                nulloid)  echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":null},"state":"COMMENTED","body":"fixture review body","comments":{"totalCount":1}}]}}}}}' ;;
                fail)     echo "reviews boom" >&2; exit 1 ;;
            esac
            exit 0 ;;
    esac
    if [ "${GH_STUB_THREADS:-0}" = "fail" ]; then echo "graphql boom" >&2; exit 1; fi
    if [ "${GH_STUB_THREADS:-0}" = "badnext" ]; then echo "0 banana cursor1"; exit 0; fi
    if [ "${GH_STUB_THREADS:-0}" = "nullcursor" ]; then echo "0 true null"; exit 0; fi
    if [ "${GH_STUB_THREADS:-0}" = "repeatcursor" ]; then echo "0 true cursor1"; exit 0; fi
    if [ "${GH_STUB_THREADS:-0}" = "cyclecursor" ]; then
        a=$(cat "$GH_STUB_API" 2>/dev/null)
        a=${a:-0}
        echo $((a+1)) > "$GH_STUB_API"
        # alternate cursorA / cursorB forever: A→B→A cycle, hasNextPage always true
        if [ $((a % 2)) -eq 0 ]; then echo "0 true cursorA"; else echo "0 true cursorB"; fi
        exit 0
    fi
    if [ "${GH_STUB_THREADS:-0}" = "latethread" ]; then
        # First thread query (pre-watch gate) is clean; every later query
        # (the post-watch re-verification) reports one unresolved thread —
        # a review comment that landed DURING the watch (codex-adv 980-r2).
        a=$(cat "$GH_STUB_API" 2>/dev/null)
        a=${a:-0}
        echo $((a+1)) > "$GH_STUB_API"
        if [ "$a" -eq 0 ]; then echo "0 false null"; else echo "1 false null"; fi
        exit 0
    fi
    if [ "${GH_STUB_THREADS:-0}" = "escalatethread" ]; then
        # The first thread snapshot is clean; every query from the second onward
        # (including the post-full-review re-check) reports the inline finding
        # escalation created - so the re-check observes it regardless of how
        # many queries the flow makes, not only when it lands on query >=3.
        a=$(cat "$GH_STUB_API" 2>/dev/null)
        a=${a:-0}
        echo $((a+1)) > "$GH_STUB_API"
        if [ "$a" -eq 0 ]; then echo "0 false null"; else echo "1 false null"; fi
        exit 0
    fi
    if [ "${GH_STUB_THREADS:-0}" = "paged" ]; then
        a=$(cat "$GH_STUB_API" 2>/dev/null)
        a=${a:-0}
        echo $((a+1)) > "$GH_STUB_API"
        if [ "$a" -eq 0 ]; then
            echo "0 true cursor1"
        else
            # page two is only valid when the caller sent page one's cursor
            case " $* " in
                *"cursor1"*) echo "1 false null" ;;
                *) echo "gh stub: page-two request missing cursor1" >&2; exit 99 ;;
            esac
        fi
        exit 0
    fi
    echo "${GH_STUB_THREADS:-0} false null"; exit 0
fi
if [ "$cmd" = "pr" ] && [ "${2:-}" = "view" ]; then
    # a repo with no PR fails pr view too — keep the stub's no-pr mode honest
    if [ "$GH_STUB_MODE" = "no-pr" ]; then
        echo 'no pull requests found for branch "feat/x"' >&2; exit 1
    fi
    case " $* " in
        *"--json changedFiles"*)
            case "${GH_STUB_FILES:-README.md}" in
                fail) echo '{"changedFiles":1}' ;;
                malformed) echo '{"changedFiles":1}' ;;
                truncated) echo '{"changedFiles":101}' ;;
                *) echo '{"changedFiles":1}' ;;
            esac
            exit 0 ;;
        # HIMMEL-2278: the machine-generated-PR classifier's ONE probe. Emits
        # check-ci.sh's parsed shape: sentinel, author login, author is_bot,
        # file count, then one line per changed path. The DEFAULT (`none`) is a
        # deliberately ordinary human code PR, so every pre-2278 case in this
        # suite now runs the classifier for real and must be unaffected by it —
        # that is the byte-unchanged negative control, applied ~120 times.
        *"author,files"*)
            case "${GH_STUB_MPR:-none}" in
                none)       printf 'MPR_OK\noctocat\nfalse\n1\nREADME.md\n' ;;
                dependabot) printf 'MPR_OK\ndependabot[bot]\ntrue\n2\npackage.json\npackage-lock.json\n' ;;
                # A human account merely NAMED like the bot: is_bot is GitHub's
                # word, not the author's, so this must stay out of the class.
                dep-impostor) printf 'MPR_OK\ndependabot[bot]\nfalse\n1\nscripts/check-ci.sh\n' ;;
                graph)      printf 'MPR_OK\nyotamleo\nfalse\n2\ngraphify-out/graph.json\ngraphify-out/GRAPH_REPORT.md\n' ;;
                # codex-2, HIMMEL-2278 CR round 2: only graph.json changed this
                # publish (GRAPH_REPORT.md came out byte-identical), so the PR
                # diff is ONE artifact path. Still the class.
                graph-single) printf 'MPR_OK\nyotamleo\nfalse\n1\ngraphify-out/graph.json\n' ;;
                # THE spoof control: the artifact pair PLUS one code path. One
                # path outside the two-element set ejects the PR from the class.
                graph-plus-code) printf 'MPR_OK\nyotamleo\nfalse\n3\ngraphify-out/graph.json\ngraphify-out/GRAPH_REPORT.md\nscripts/check-ci.sh\n' ;;
                # A file literally named `*`: the artifact paths must be the
                # case PATTERNS and the changed path the subject, never the
                # reverse, or one glob-named file matches the whole class.
                globname)   printf 'MPR_OK\nyotamleo\nfalse\n1\n*\n' ;;
                # codex-1, HIMMEL-2278 CR round 1: an rc=0 probe that ADVERTISES
                # 3 files but was truncated after emitting only its two artifact
                # paths. Reading a partial file list as a complete one would
                # classify a code PR into the class.
                truncated)  printf 'MPR_OK\nyotamleo\nfalse\n3\ngraphify-out/graph.json\ngraphify-out/GRAPH_REPORT.md\n' ;;
                empty)      printf 'MPR_OK\nyotamleo\nfalse\n0\n' ;;
                garbage)    printf 'not-the-sentinel\ndependabot[bot]\ntrue\n0\n' ;;
                probe-fail) echo "author/files boom" >&2; exit 1 ;;
                *)          printf 'MPR_OK\noctocat\nfalse\n1\nREADME.md\n' ;;
            esac
            exit 0 ;;
        *"headRefOid"*)
            if [ "${GH_STUB_HEAD:-stable}" = "moving" ]; then
                h=$(cat "$GH_STUB_HEADC" 2>/dev/null)
                h=${h:-0}
                echo $((h+1)) > "$GH_STUB_HEADC"
                echo "sha$((h+1))"
            else
                echo "sha1"
            fi
            exit 0 ;;
        *) echo "https://github.com/octo/demo/pull/42|${GH_STUB_DECISION:-null}"; exit 0 ;;
    esac
fi
# remaining: gh pr checks ...
is_watch=0
case " $* " in *" --watch "*) is_watch=1 ;; esac
# structured red confirm (--json bucket): the script's --jq yields a bare count
case " $* " in
    *" --json "*)
        # HIMMEL-2062: watch_decidable's probe is a DIFFERENT --json shape
        # (bucket,name) from the fail-bucket-count probe below — branch on the
        # field list before falling into the bare-count logic, or a blocking
        # mode's decidable check would get a bare number instead of its
        # "CHECKCI_OK\n<pending names>" shape.
        case " $* " in
            *"bucket,name"*)
                case "$GH_STUB_MODE" in
                    blocking-cr-decidable) printf 'CHECKCI_OK\nCodeRabbit\n' ;;
                    # codex-2, HIMMEL-2062 CR round 1: a pending check whose
                    # name merely CONTAINS "coderabbit" (not an exact match)
                    # must NOT be read as the ignorable rollup — proves
                    # watch_decidable's case is an exact match, not a glob.
                    blocking-cr-substring) printf 'CHECKCI_OK\ncoderabbit-extra\n' ;;
                    blocking-cap-pending|blocking-cap-red) printf 'CHECKCI_OK\nunit-tests\n' ;;
                    # Every OTHER mode reports a still-pending NON-CodeRabbit
                    # check by default, so watch_decidable() reliably reads
                    # false and never races the backgrounded --watch job:
                    # every pre-existing mode's --watch arm exits fast on its
                    # own (none of them sleep), so the supervising loop's
                    # "kill -0" naturally sees it finish and takes the
                    # unmodified rc-handling path exactly as before this
                    # ticket — a decidable/cap-report default here would win
                    # that race unpredictably and short-circuit ~90 pre-
                    # existing assertions onto the bounded-stop path instead.
                    *) printf 'CHECKCI_OK\nunit-tests\n' ;;
                esac
                exit 0 ;;
        esac
        case "$GH_STUB_MODE" in
            zombie-late)
                # First checks --json probe (zombie other_pending snapshot)
                # sees 0; the settle re-probe (and later calls) see 1 late
                # arrival. Count only `pr checks … --json` lines — pr_view's
                # `--json headRefOid` calls land in the same args log.
                njson=$(grep -c "^pr checks .*--json" "$GH_STUB_ARGS" 2>/dev/null); njson=${njson:-1}
                if [ "$njson" -le 1 ]; then echo 0; else echo 1; fi ;;
            red-liar|zombie|zombie-young|zombie-no-status|zombie-status-error) echo 0 ;;
            # HIMMEL-2062: blocking-cr-decidable/blocking-cap-pending are GREEN
            # shapes (0 failed) — the cap/decidable path must not misread the
            # generic default (1 failed, meant for the red-confirm caller) as
            # a red verdict. blocking-cap-red is the one case that IS red.
            blocking-cr-decidable|blocking-cap-pending|blocking-cr-substring) echo 0 ;;
            blocking-cap-red) echo 1 ;;
            *) echo 1 ;;
        esac
        exit 0 ;;
esac
case "$GH_STUB_MODE" in
    no-pr)
        echo 'no pull requests found for branch "feat/x"' >&2; exit 1 ;;
    register-then-green)
        n=$(cat "$GH_STUB_COUNT" 2>/dev/null)
        n=${n:-0}
        echo $((n+1)) > "$GH_STUB_COUNT"
        if [ "$n" -lt 2 ]; then
            echo "no checks reported on the 'feat/x' branch" >&2; exit 1
        fi
        if [ "$is_watch" -eq 1 ]; then echo "All checks were successful"; exit 0; fi
        exit 8 ;;
    red)
        if [ "$is_watch" -eq 1 ]; then echo "X ci fail"; exit 1; fi
        exit 8 ;;
    probe-error)
        echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1 ;;
    green-then-red)
        if [ "$is_watch" -eq 1 ]; then
            w=$(cat "$GH_STUB_WATCH" 2>/dev/null)
            w=${w:-0}
            echo $((w+1)) > "$GH_STUB_WATCH"
            if [ "$w" -eq 0 ]; then echo "All checks were successful"; exit 0; fi
            echo "X late check failed"; exit 1
        fi
        exit 8 ;;
    never-register)
        echo "no checks reported on the 'feat/x' branch" >&2; exit 1 ;;
    watch-pending)
        if [ "$is_watch" -eq 1 ]; then exit 8; fi
        exit 8 ;;
    red-liar)
        # rc 1 with EMPTY stdout+stderr — gh's generic failure masquerading as red
        if [ "$is_watch" -eq 1 ]; then exit 1; fi
        exit 8 ;;
    watch-error)
        if [ "$is_watch" -eq 1 ]; then echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1; fi
        exit 8 ;;
    cr-absent|cr-pending|cr-failure|cr-spoofed|cr-query-error|cr-paged|cr-skipped|cr-desc-error|cr-completed|cr-nearmiss|cr-ratelimited|cr-unknownword|cr-substrmatch)
        # Checks are GREEN and threads are clean in every one of these — the
        # verdict must turn entirely on CodeRabbit's status (HIMMEL-1072).
        if [ "$is_watch" -eq 1 ]; then echo "All checks were successful"; exit 0; fi
        exit 0 ;;
    body-outside|body-nitpick|body-drift|body-error|body-a2|body-empty|body-a2-escalate|body-a2-marker|body-a2-timeout|body-a2-escalate-outside|body-b2-escalate|body-b2-escalate-outside|body-b2-timeout|body-b2-head-review|body-a2-escalate-empty|body-a2-empty-persisted|body-a2-postfail)
        # Checks GREEN, threads clean, CodeRabbit CONCLUDED (default statuses
        # fixture) in every one of these — the verdict must turn entirely on
        # the review-BODY findings gate (HIMMEL-1126/1147/1219).
        if [ "$is_watch" -eq 1 ]; then echo "All checks were successful"; exit 0; fi
        exit 0 ;;
    # HIMMEL-2062: blocking modes — the --watch arm sleeps a BOUNDED few
    # seconds so a supervision bug cannot hang the suite; check-ci.sh's own
    # background+decidable/cap logic is expected to kill it well before that
    # sleep completes. The plain (non-watch, non-json) probe just says
    # "pending" (rc 8), the same convention every other mode uses to clear
    # the grace loop on its first try.
    blocking-cr-decidable)
        if [ "$is_watch" -eq 1 ]; then sleep 3; echo "All checks were successful"; exit 0; fi
        exit 8 ;;
    blocking-cap-pending)
        # HIMMEL-2206 case 104: record this stub's own pid (colocated with the
        # stub itself, same idiom as counting-sleep above — $STUBDIR is not in
        # this process's env) so the test can confirm it actually dies when
        # check-ci.sh stops the watch early, instead of being left orphaned.
        # codex-2, CR round 4: kill -0 on that pid is NOT proof of death — this
        # very ticket establishes kill -0 succeeds on a killed-but-unreaped
        # zombie too, so case 104 also drops a SEPARATE marker file right
        # after the sleep (the natural-completion side effect an orphaned
        # process would still produce); the test asserts that marker never
        # appears, which a zombie's lingering process-table entry cannot fake.
        if [ "$is_watch" -eq 1 ]; then
            echo $$ > "$(dirname "$0")/watch-pid"
            sleep 3
            touch "$(dirname "$0")/completed-naturally"
            echo "All checks were successful"; exit 0
        fi
        exit 8 ;;
    blocking-cr-substring)
        if [ "$is_watch" -eq 1 ]; then sleep 3; echo "All checks were successful"; exit 0; fi
        exit 8 ;;
    blocking-cap-red)
        if [ "$is_watch" -eq 1 ]; then sleep 3; echo "X ci fail"; exit 1; fi
        exit 8 ;;
    *)
        echo "gh stub: unknown GH_STUB_MODE '$GH_STUB_MODE'" >&2; exit 99 ;;
esac
EOF
chmod +x "$STUBDIR/gh" || { echo "FATAL: chmod on gh stub failed"; exit 1; }
[ -x "$STUBDIR/gh" ] || { echo "FATAL: gh stub not executable"; exit 1; }

# counting-sleep — a CHECK_CI_SLEEP_CMD that logs one line per call (to a
# fixed file next to itself, not baked-in $STUBDIR, so it stays correct if
# STUBDIR is ever relocated) and still really sleeps its argument (HIMMEL-2062
# CR round 2, case 101): proving the POLL=0 floor fix needs an ACTUAL per-call
# delay, or the loop would spin just as fast with or without the floor.
cat > "$STUBDIR/counting-sleep" <<'EOF'
#!/usr/bin/env bash
echo x >> "$(dirname "$0")/sleepcount"
exec sleep "$1"
EOF
chmod +x "$STUBDIR/counting-sleep" || { echo "FATAL: chmod on counting-sleep stub failed"; exit 1; }

OUT=""; ERR=""; RC=0
# Per-case opt-in overrides, reset after every run:
SETTLE_OVERRIDE=0; THREADS_OVERRIDE=0; POLL_OVERRIDE=0; HEAD_OVERRIDE=stable; DECISION_OVERRIDE=null
ESCALATE_WAIT_OVERRIDE=0; ESCALATE_POLL_OVERRIDE=0
# SLEEP_CMD_OVERRIDE drives CHECK_CI_SLEEP_CMD (HIMMEL-1953). `:` — no case may
# burn real wall clock on a simulated poll — is the default and the invariant.
# A case OPTS BACK IN to a real sleep only when the interval itself is what it
# measures (case 50 counts re-reads per interval; against a no-op that count
# becomes a function of how fast the host forks, which is not a contract).
SLEEP_CMD_OVERRIDE=":"
# MARKERS_OVERRIDE seeds escalation-claim comments a PREVIOUS invocation left on
# the PR (HIMMEL-1964); empty = a head nobody has claimed yet.
MARKERS_OVERRIDE=""
# FRESHNESS_OVERRIDE drives GH_STUB_FRESHNESS (HIMMEL-1181). Default 'fresh'
# matches every case that doesn't care about the review-freshness gate.
FRESHNESS_OVERRIDE=fresh
FILES_OVERRIDE=README.md
CR_BOT_LOGINS_OVERRIDE=""
# CR_PROFILE_OVERRIDE=none exercises the CodeRabbit-less-repo opt-out
# (HIMMEL-1072); empty = a normal repo where the signal is required.
CR_PROFILE_OVERRIDE=""
# CR_APP_OVERRIDE pins the HIMMEL-1125 availability probe EXPLICITLY. Default 1
# = "this repo has CodeRabbit", which is what every pre-1125 case assumed. It is
# set rather than left to the probe on purpose: the probe reads the checkout's
# repo-local `git config himmel.coderabbit` (NOT the committed .coderabbit.yaml
# — rejected as a signal, see cr-available.sh), so an un-pinned suite would
# silently flip the meaning of ~30 cases with the arming state of whichever
# clone the tests happen to run from.
# CR_APP_OVERRIDE=0 = the adopter WITHOUT CodeRabbit (cases 35+).
CR_APP_OVERRIDE=1
# MPR_OVERRIDE drives the stub's author/files reply for the HIMMEL-2278
# machine-generated-PR classifier. Default `none` = an ordinary human code PR,
# so every pre-existing case runs the classifier for real and asserts, by
# keeping its old verdict, that it changed nothing for them.
MPR_OVERRIDE=none

# --- HIMMEL-1953: no real sleeping, and no unbounded case -------------------
#
# SLEEP_CMD_OVERRIDE (default `:`, see above) is passed as check-ci.sh's
# CHECK_CI_SLEEP_CMD below, turning its three wall-clock waits into no-ops.
# Cases 47/50/51/52 deliberately drive the CR_ESCALATE_POLL=0 validation, whose
# 120s fallback used to be slept for real — case 47 alone cost two minutes.
#
# The per-case bound is the backstop for everything the seam does not cover: a
# stub that blocks on a read, a loop that never converges. `timeout` reports 124
# on expiry, no assertion matches it, and the case FAILS carrying its own number
# — a deterministic failure instead of a suite that hangs and looks merely slow.
# -k escalates to SIGKILL for a check-ci.sh caught in its exit trap.
#
# The default is DELIBERATELY generous. This bound exists to turn an infinite
# hang into a verdict, not to police slowness — and a bound that fires on a
# legitimate case is worse than no bound, because it teaches everyone to ignore
# it. Measured: an ordinary case here runs in ~10s on a healthy box, but case 78
# blew past 120s on a loaded one (a Git-Bash host whose /tmp had accumulated
# ~150k entries, which taxes every mktemp the fixtures make). 600s is ~60x the
# healthy case and still bounds a hang to ten minutes; raise it per-run rather
# than editing tests.
#
# GNU `timeout 0` DISABLES the limit rather than expiring instantly, so a zero
# or malformed override falls back to the default instead of silently removing
# the bound it was asked to tighten.
CHECK_CI_CASE_TIMEOUT="${CHECK_CI_CASE_TIMEOUT:-600}"
case "$CHECK_CI_CASE_TIMEOUT" in
    ''|*[!0-9]*) CHECK_CI_CASE_TIMEOUT=600 ;;
    *) [ "$CHECK_CI_CASE_TIMEOUT" -ge 1 ] || CHECK_CI_CASE_TIMEOUT=600 ;;
esac
# `env` is the no-op wrapper on a host without coreutils `timeout` (macOS ships
# none) — same call shape, no bound, and one loud line saying so.
CASE_RUNNER="$(command -v timeout 2>/dev/null)" || CASE_RUNNER=""
if [ -n "$CASE_RUNNER" ]; then
    CASE_RUNNER_ARGS="-k 5 $CHECK_CI_CASE_TIMEOUT"
else
    CASE_RUNNER="env"
    CASE_RUNNER_ARGS=""
    echo "NOTE: 'timeout' not found — per-case bounds disabled; a stuck case will hang this suite" >&2
fi

# run <mode> [args...]
run() {
    local mode="$1"; shift
    COUNT=$((COUNT+1))
    local of ef
    if ! of=$(mktemp "$STUBDIR/out.XXXXXX"); then echo "FATAL: mktemp for stdout capture failed" >&2; exit 1; fi
    if ! ef=$(mktemp "$STUBDIR/err.XXXXXX"); then rm -f "$of"; echo "FATAL: mktemp for stderr capture failed" >&2; exit 1; fi
    : > "$STUBDIR/args.log"
    : > "$STUBDIR/sleepcount"
    : > "$STUBDIR/count"
    : > "$STUBDIR/watch"
    : > "$STUBDIR/api"
    : > "$STUBDIR/headc"
    : > "$STUBDIR/statuses"
    : > "$STUBDIR/reviews"
    : > "$STUBDIR/freshness-reads"
    : > "$STUBDIR/comments"
    : > "$STUBDIR/claims"
    # SC2086: $CASE_RUNNER_ARGS must word-split — this script builds it itself
    # out of digits, and an array is not bash-3.2 safe under set -u.
    # shellcheck disable=SC2086
    PATH="$STUBDIR:$PATH" \
        GH_STUB_MODE="$mode" \
        GH_STUB_ARGS="$STUBDIR/args.log" \
        GH_STUB_COUNT="$STUBDIR/count" \
        GH_STUB_WATCH="$STUBDIR/watch" \
        GH_STUB_API="$STUBDIR/api" \
        GH_STUB_HEADC="$STUBDIR/headc" \
        GH_STUB_STATUSES="$STUBDIR/statuses" \
        GH_STUB_REVIEWS="$STUBDIR/reviews" \
        GH_STUB_FRESHNESS_READS="$STUBDIR/freshness-reads" \
        GH_STUB_COMMENTS="$STUBDIR/comments" \
        GH_STUB_CLAIMS="$STUBDIR/claims" \
        GH_STUB_MARKERS="$MARKERS_OVERRIDE" \
        GH_STUB_HEAD="$HEAD_OVERRIDE" \
        GH_STUB_DECISION="$DECISION_OVERRIDE" \
        GH_STUB_THREADS="$THREADS_OVERRIDE" \
        GH_STUB_FRESHNESS="$FRESHNESS_OVERRIDE" \
        GH_STUB_FILES="$FILES_OVERRIDE" \
        GH_STUB_MPR="$MPR_OVERRIDE" \
        CHECK_CI_POLL_INTERVAL="$POLL_OVERRIDE" \
        CHECK_CI_SETTLE="$SETTLE_OVERRIDE" \
        CR_ESCALATE_WAIT="$ESCALATE_WAIT_OVERRIDE" \
        CR_ESCALATE_POLL="$ESCALATE_POLL_OVERRIDE" \
        CR_PROFILE="$CR_PROFILE_OVERRIDE" \
        CR_APP="$CR_APP_OVERRIDE" \
        CR_BOT_LOGINS="$CR_BOT_LOGINS_OVERRIDE" \
        CHECK_CI_SLEEP_CMD="$SLEEP_CMD_OVERRIDE" \
        "$CASE_RUNNER" $CASE_RUNNER_ARGS bash "$SCRIPT" "$@" >"$of" 2>"$ef"
    RC=$?
    if [ "$RC" -eq 124 ] && [ "$CASE_RUNNER" != env ]; then
        echo "  TIMEOUT: case $COUNT ($mode) exceeded ${CHECK_CI_CASE_TIMEOUT}s and was killed — its assertions FAIL below"
    fi
    OUT=$(cat "$of"); ERR=$(cat "$ef")
    rm -f "$of" "$ef"
    SETTLE_OVERRIDE=0; THREADS_OVERRIDE=0; POLL_OVERRIDE=0; HEAD_OVERRIDE=stable; DECISION_OVERRIDE=null
    ESCALATE_WAIT_OVERRIDE=0; ESCALATE_POLL_OVERRIDE=0; MARKERS_OVERRIDE=""; SLEEP_CMD_OVERRIDE=":"
    CR_PROFILE_OVERRIDE=""; CR_APP_OVERRIDE=1
    FRESHNESS_OVERRIDE=fresh; FILES_OVERRIDE=README.md; CR_BOT_LOGINS_OVERRIDE=""; MPR_OVERRIDE=none
}

run_in_repo() {
    local repo="$1" previous="$PWD"; shift
    cd "$repo" || { echo "FATAL: cannot cd to ledger fixture repo" >&2; exit 1; }
    run "$@"
    cd "$previous" || { echo "FATAL: cannot cd back from ledger fixture repo" >&2; exit 1; }
}

assert_rc()      { if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$2" "rc=$RC want $1"; fi; }
assert_out_has() { if printf '%s' "$OUT" | grep -iF -- "$1" >/dev/null; then pass "$2"; else fail "$2" "stdout missing: $1"; fi; }
assert_err_has() { if printf '%s' "$ERR" | grep -iF -- "$1" >/dev/null; then pass "$2"; else fail "$2" "stderr missing: $1"; fi; }
# Exactly ONE verdict line, exact-match to the expected code (HIMMEL-974) —
# a substring check would pass on a double-fired trap or a wrong-code line.
assert_verdict() {
    local n
    n=$(printf '%s\n' "$OUT" | grep -c -x "check-ci: verdict exit=$1")
    local total
    total=$(printf '%s\n' "$OUT" | grep -c "check-ci: verdict exit=")
    if [ "$n" -eq 1 ] && [ "$total" -eq 1 ]; then
        pass "$2"
    else
        fail "$2" "want exactly 1 'verdict exit=$1' line, got $n (total verdict lines: $total)"
    fi
}
assert_no_verdict() {
    if printf '%s' "$OUT$ERR" | grep -F "verdict exit=" >/dev/null; then
        fail "$1" "verdict line leaked into a pre-trap exit"
    else
        pass "$1"
    fi
}

echo "test-check-ci.sh"

# 1 — no PR
run no-pr
assert_rc 2 "1 no PR rc 2"
assert_err_has "no pull requests found" "1 no PR gh error surfaced"
assert_verdict 2 "1 un-maskable verdict line (HIMMEL-974)"

# 2 — registers after two probes, watch green, threads resolved
run register-then-green
assert_rc 0 "2 register-then-green rc 0"
assert_out_has "all checks green + all review threads resolved" "2 green verdict on stdout"
assert_verdict 0 "2 un-maskable verdict line (HIMMEL-974)"

# 3 — red (fast) → rc 1 + billing-block hint
run red
assert_rc 1 "3 red rc 1"
assert_err_has "checks FAILED" "3 FAILED on stderr"
assert_err_has "billing" "3 fast-red hint present"
assert_verdict 1 "3 un-maskable verdict line (HIMMEL-974)"

# 4 — never registers, grace 0
run never-register --grace 0
assert_rc 2 "4 never-register rc 2"
assert_err_has "no checks registered within 0s" "4 grace-timeout message"

# 5 — unknown option (pre-trap usage error: NO verdict line)
run red --bogus
assert_rc 2 "5 unknown option rc 2"
assert_err_has "usage" "5 usage on stderr"
assert_no_verdict "5 no verdict line on usage errors"

# 5b — --help exits 0 pre-trap: usage only, NO verdict line
run red --help
assert_rc 0 "5b --help rc 0"
assert_err_has "usage" "5b usage on stderr"
assert_no_verdict "5b no verdict line on --help"

# 6 — non-numeric grace
run red --grace soon
assert_rc 2 "6 non-numeric grace rc 2"
assert_err_has "non-negative integer" "6 grace validation message"

# 7 — two selectors
run red 12 34
assert_rc 2 "7 two selectors rc 2"
assert_err_has "only one PR selector" "7 selector message"

# 8 — selector passed through to gh as an exact token (not a prefix match)
run red 123
assert_rc 1 "8 selector run rc 1"
if grep -Eq '^pr checks 123($|[[:space:]])' "$STUBDIR/args.log"; then
    pass "8 selector forwarded to gh"
else
    fail "8 selector forwarded to gh" "args.log: $(cat "$STUBDIR/args.log")"
fi

# 9 — settle round catches a late red (codex-adv-1 race)
SETTLE_OVERRIDE=1
run green-then-red
assert_rc 1 "9 settle late-red rc 1"
assert_err_has "checks FAILED" "9 late red FAILED on stderr"

# 10 — settle round green twice → rc 0 with exactly two watch calls
SETTLE_OVERRIDE=1
run register-then-green
assert_rc 0 "10 settle green rc 0"
watch_calls=$(grep -c -- '--watch' "$STUBDIR/args.log")
if [ "$watch_calls" -eq 2 ]; then
    pass "10 settle round ran a second watch"
else
    fail "10 settle round ran a second watch" "watch calls=$watch_calls want 2"
fi

# 11 — checks green but unresolved threads → rc 3
THREADS_OVERRIDE=2
run register-then-green
assert_rc 3 "11 unresolved threads rc 3"
assert_err_has "2 unresolved review thread(s)" "11 unresolved-thread message"
assert_verdict 3 "11 un-maskable verdict line (HIMMEL-974)"

# 12 — thread query failure → rc 2 (gate cannot be evaluated, fail-closed)
THREADS_OVERRIDE=fail
run register-then-green
assert_rc 2 "12 thread query failure rc 2"
assert_err_has "review-thread query failed" "12 query-failure message"

# 13 — non-numeric poll interval warns and falls back (red mode: no sleeps hit)
POLL_OVERRIDE=abc
run red
assert_rc 1 "13 non-numeric poll still runs (rc 1 red)"
assert_err_has "CHECK_CI_POLL_INTERVAL" "13 poll fallback warning"

# 14 — non-numeric settle
run red --settle later
assert_rc 2 "14 non-numeric settle rc 2"
assert_err_has "--settle must be a non-negative integer" "14 settle validation message"

# 15 — --threads-only: thread gate runs, checks watch does not
THREADS_OVERRIDE=2
run red --threads-only
assert_rc 3 "15 threads-only unresolved rc 3"
assert_err_has "2 unresolved review thread(s)" "15 threads-only unresolved message"
if grep -- 'checks' "$STUBDIR/args.log" >/dev/null; then
    fail "15 threads-only skips gh pr checks" "args.log: $(cat "$STUBDIR/args.log")"
else
    pass "15 threads-only skips gh pr checks"
fi

# 16 — pagination: page one clean + hasNextPage, unresolved thread on page two
THREADS_OVERRIDE=paged
run register-then-green
assert_rc 3 "16 page-two unresolved rc 3"
assert_err_has "1 unresolved review thread(s)" "16 page-two unresolved counted"

# 17 — probe gh error (auth/network) → rc 2, never a fake red
run probe-error
assert_rc 2 "17 probe error rc 2 (not 1)"
assert_err_has "cannot evaluate the gate" "17 probe-error message"

# 18 — PR head moves between watch and verdict → rc 2 (verdict bound to SHA)
HEAD_OVERRIDE=moving
run register-then-green
assert_rc 2 "18 head moved rc 2"
assert_err_has "PR head moved during the run" "18 head-moved message"
# ordering: capture BEFORE the watch, re-read AFTER — both reads on one side
# of the watch would pass the SHA-change assert while guarding nothing
first_head=$(grep -n 'headRefOid' "$STUBDIR/args.log" | head -1 | cut -d: -f1)
last_head=$(grep -n 'headRefOid' "$STUBDIR/args.log" | tail -1 | cut -d: -f1)
watch_line=$(grep -n -- '--watch' "$STUBDIR/args.log" | head -1 | cut -d: -f1)
if [ -n "$first_head" ] && [ -n "$watch_line" ] && [ -n "$last_head" ] \
    && [ "$first_head" -lt "$watch_line" ] && [ "$watch_line" -lt "$last_head" ]; then
    pass "18 head reads straddle the watch"
else
    fail "18 head reads straddle the watch" "first_head=$first_head watch=$watch_line last_head=$last_head"
fi

# 19 — CHANGES_REQUESTED review → rc 3 (affirmative do-not-merge signal)
DECISION_OVERRIDE=CHANGES_REQUESTED
run register-then-green
assert_rc 3 "19 changes-requested rc 3"
assert_err_has "requests changes" "19 changes-requested message"

# 20 — gh error mid-watch (auth/network) → rc 2, never a fake red
run watch-error
assert_rc 2 "20 watch-error rc 2"
assert_err_has "cannot evaluate the gate" "20 watch-error message"

# 21 — malformed hasNextPage (neither true nor false) → rc 2, after exactly ONE query
THREADS_OVERRIDE=badnext
run register-then-green
assert_rc 2 "21 malformed hasNextPage rc 2"
assert_err_has "malformed page" "21 malformed hasNextPage message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 1 ]; then pass "21 exactly one thread query"; else fail "21 exactly one thread query" "api calls=$api_calls want 1"; fi

# 22 — hasNextPage true with an empty/null cursor → rc 2 (must not loop or stop early)
THREADS_OVERRIDE=nullcursor
run register-then-green
assert_rc 2 "22 hasNextPage true empty cursor rc 2"
assert_err_has "malformed page" "22 hasNextPage true empty cursor message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 1 ]; then pass "22 exactly one thread query"; else fail "22 exactly one thread query" "api calls=$api_calls want 1"; fi

# 23 — cursor repeats with hasNextPage=true → rc 2 after the SECOND query (no infinite loop)
THREADS_OVERRIDE=repeatcursor
run register-then-green
assert_rc 2 "23 repeated cursor rc 2"
assert_err_has "cursor did not advance" "23 repeated-cursor message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 2 ]; then pass "23 exactly two thread queries"; else fail "23 exactly two thread queries" "api calls=$api_calls want 2"; fi

# 24 — non-adjacent cursor cycle (A→B→A, hasNextPage always true) → the page cap
#      fails closed at 50 queries instead of looping forever
THREADS_OVERRIDE=cyclecursor
run register-then-green
assert_rc 2 "24 cursor cycle rc 2"
assert_err_has "did not terminate within 50 pages" "24 page-cap message"
api_calls=$(grep -c '^api graphql' "$STUBDIR/args.log")
if [ "$api_calls" -eq 50 ]; then pass "24 capped at 50 thread queries"; else fail "24 capped at 50 thread queries" "api calls=$api_calls want 50"; fi

# 25 — watch exits non-1 with EMPTY stderr (e.g. rc 8 pending after an
#      interrupted watch) → cannot evaluate, never a fake red
run watch-pending
assert_rc 2 "25 watch rc!=1 empty stderr rc 2"
assert_err_has "with no error output" "25 non-red watch message"

# 26 — watch exits rc 1 silently but NO check is in the fail bucket (gh's
#      generic failure code masquerading as red) → cannot evaluate
run red-liar
assert_rc 2 "26 red-liar rc 2"
assert_err_has "no check is in the fail bucket" "26 structured-confirm message"

# --- HIMMEL-1072: the CodeRabbit signal is REQUIRED, not evaluated-if-present ---
# The old cases 27-32 here exercised the HIMMEL-980 "zombie check-run override".
# That override keyed off a CodeRabbit CHECK-RUN — which CodeRabbit has never
# posted (it posts a commit STATUS; verified on 5 consecutive live PRs). The
# override was unreachable and these fixtures were the only place its trigger
# shape existed. Both are gone; the status is read directly instead.

# 27 — the regression that merged #1243: checks green, threads clean, but
# CodeRabbit never posted on this head. Absent is NOT green.
run cr-absent
assert_rc 2 "27 absent CodeRabbit status rc 2"
assert_err_has "has posted NO status" "27 absent reports the missing review"

# 28 — CodeRabbit still reviewing the head: not green YET (re-run), never 0.
run cr-pending
assert_rc 2 "28 pending CodeRabbit status rc 2"

# 29 — CodeRabbit's own status failed/errored → a failed check (rc 1).
run cr-failure
assert_rc 1 "29 failed CodeRabbit status rc 1"

# 30 — identity, not display name (HIMMEL-1058): a success status carrying the
# CodeRabbit context but a foreign creator.id must not satisfy the gate.
run cr-spoofed
assert_rc 2 "30 spoofed creator.id does not satisfy the gate"

# 31 — a repo with no CodeRabbit opts out explicitly rather than being blocked
# forever: CR_PROFILE=none skips the required-signal gate.
CR_PROFILE_OVERRIDE=none
run cr-absent
assert_rc 0 "31 CR_PROFILE=none allows an absent CodeRabbit"

# 32 — the status query itself failing is cannot-evaluate, never a pass.
run cr-query-error
assert_rc 2 "32 CodeRabbit status query error rc 2"

# 34 — coderabbit-2: a FULL page of unrelated statuses with no CodeRabbit among
# them is indeterminate (its verdict may be on page two), not absent — and
# certainly not green. (Numbered 34: a "33" already exists further down.)
run cr-paged
assert_rc 2 "34 full status page without CodeRabbit rc 2"
assert_err_has "more commit statuses than one API page" "34 page-limit reason"

# 34b/34c — HIMMEL-1317: a SKIPPED review is not a clean one. With automatic
# reviews disabled CodeRabbit posts state=success on every untriggered PR and
# puts the refusal in .description alone, so reading only .state certified exit 0
# on a PR nobody had reviewed (reproduced on PR #1429, 2026-07-27) — and
# merge-on-green, which gates solely on check-ci:0, would have squash-merged it.
# The pair is deliberate: 34b proves the skip BLOCKS, 34c proves an ordinary
# review still PASSES, so the fix cannot be satisfied by breaking `success`.
run cr-skipped
assert_rc 2 "34b skipped CodeRabbit review is not certifiable"
assert_err_has "SKIPPED the review" "34b skip reason surfaced"
assert_err_has "@coderabbitai review" "34b skip names the remedy"

run cr-completed
assert_rc 0 "34c a genuinely completed review still certifies"

# 34d — glm-1: the skip match must be UNAMBIGUOUS. A completed review worded
# "No review changes requested" contains skip-ish words; the first cut of the
# regex matched it and would have blocked a clean merge. The two error
# directions are not symmetric — a false negative restores the old behaviour,
# a false positive is an outage nobody can clear by re-running.
run cr-nearmiss
assert_rc 0 "34d skip-ish wording on a COMPLETED review does not block"

# 34e/34f — HIMMEL-1354, the SECOND drift of the 34b class. HIMMEL-1317 closed
# the "automatic reviews are disabled" wording with a DENY-LIST of known-bad
# descriptions. On 2026-07-28 CodeRabbit declined for RATE LIMITING and said so
# in a wording that matched none of those alternatives, so it classified as a
# clean success: `gh pr checks` bucketed it `pass` and check-ci printed
# "all checks green" + "verdict exit=0" on PR #1456 @ 46358386 — a head whose
# own cr-body-findings line, printed one line earlier, said there was NO
# CodeRabbit review. A missed skip does not "degrade to yesterday": it certifies
# unreviewed code as merge-ready.
#
# 34e pins that exact payload. 34f is the structural half and matters more: it
# asserts the behaviour on a wording NOBODY enumerated. A deny-list is silent on
# the unknown case by construction and passes it as clean; the allow-list fails
# it closed. Without 34f this fix would be one more entry in a list that leaks
# again the next time CodeRabbit invents a phrase.
# Pin the DEFAULT allow/deny lists for 34e/34f. Both assert cr-signal.sh's
# built-in fail-closed behaviour, so an ambient CR_OK_DESC_RE / CR_SKIP_DESC_RE
# in the operator's shell must not leak in and decide the result — a
# permissive inherited value would let these pass without exercising the
# default at all. (CR review of this branch, 2026-07-28.)
unset CR_OK_DESC_RE CR_SKIP_DESC_RE

# Exact-head ledger fixtures for every panel-carry shape below. The empty repo
# proves no rows preserve the existing fail-closed verdict; the clean repo has
# one responder at the fixture head and no blocking finding.
EMPTY_LEDGER_REPO=$(mktemp -d "$STUBDIR/empty-ledger.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
git -C "$EMPTY_LEDGER_REPO" init --quiet
git -C "$EMPTY_LEDGER_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet --no-verify
: > "$EMPTY_LEDGER_REPO/.git/cr-critic-scores.jsonl"
LEDGER_REPO=$(mktemp -d "$STUBDIR/clean-ledger.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
git -C "$LEDGER_REPO" init --quiet
git -C "$LEDGER_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet --no-verify
printf '%s\n' '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"sha1","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' > "$LEDGER_REPO/.git/cr-critic-scores.jsonl"

# HIMMEL-2380: a repo whose himmel.coderabbit marker git cannot parse as a
# boolean. `ture` is a real typo, not a synthetic value — and the failure it
# provokes is git's own: `git config --bool --get` exits 128 with "bad boolean
# config value", where an UNSET key exits 1. Both leave cr-available.sh's
# capture empty, which is why the two states were indistinguishable before
# cr_app_state and why this fixture must use a value the real git binary
# rejects rather than a stub. Cases 2380-a / 2380-c run here.
BROKEN_MARKER_REPO=$(mktemp -d "$STUBDIR/broken-marker.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
git -C "$BROKEN_MARKER_REPO" init --quiet
git -C "$BROKEN_MARKER_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet --no-verify
git -C "$BROKEN_MARKER_REPO" config --local himmel.coderabbit ture
: > "$BROKEN_MARKER_REPO/.git/cr-critic-scores.jsonl"
# Prove the fixture actually IS broken before any case trusts it (HIMMEL-2320:
# a zero is not evidence without a positive control). If a future git parsed
# `ture`, 2380-a would pass for the wrong reason — it would be asserting a
# warning about a repo that is merely unarmed.
if git -C "$BROKEN_MARKER_REPO" config --bool --local --get himmel.coderabbit >/dev/null 2>&1; then
    echo "FATAL: the broken-marker fixture is not broken — this git parses 'ture' as a boolean"; exit 1
fi
DIRTY_LEDGER_REPO=$(mktemp -d "$STUBDIR/dirty-ledger.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
git -C "$DIRTY_LEDGER_REPO" init --quiet
git -C "$DIRTY_LEDGER_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet --no-verify
printf '%s\n' \
    '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"sha1","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' \
    '{"kind":"finding","ts":"2026-08-03T00:00:01Z","branch":"feat/x","head":"sha1","finding_id":"H1506-test","severity":"crit","verdict":"confirmed","artifact":"diff","perspective":"off"}' \
    > "$DIRTY_LEDGER_REPO/.git/cr-critic-scores.jsonl"

# HIMMEL-1506: automatic-reviews-disabled wording is panel-carriable at the
# exact head, but an explicitly empty ledger preserves the existing exit-2
# message and remedy.
run_in_repo "$EMPTY_LEDGER_REPO" cr-skipped
assert_rc 2 "34b2 disabled wording with no ledger rows stays blocked"
assert_err_has "@coderabbitai review" "34b2 disabled-wording remedy is unchanged"
run_in_repo "$LEDGER_REPO" cr-skipped
assert_rc 0 "34b3 disabled wording with a clean exact-head panel is carried"
assert_out_has "reports automatic reviews are disabled" "34b3 distinct disabled-signal carry line surfaced"
assert_out_has "carried responders=1 models=codex" "34b3 carry evidence surfaced"

# A description read failure is also an absent App signal: clean exact-head
# panel evidence carries it; no ledger rows keep the prior cannot-evaluate path.
run_in_repo "$EMPTY_LEDGER_REPO" cr-desc-error
assert_rc 2 "34b4 unreadable description with no ledger rows stays blocked"
assert_err_has "description could not be read" "34b4 unreadable-description message is unchanged"
run_in_repo "$LEDGER_REPO" cr-desc-error
assert_rc 0 "34b5 unreadable description with a clean exact-head panel is carried"
assert_out_has "description is unreadable" "34b5 distinct unreadable-description carry line surfaced"
assert_out_has "carried responders=1 models=codex" "34b5 carry evidence surfaced"

run_in_repo "$EMPTY_LEDGER_REPO" cr-ratelimited
assert_rc 2 "34e rate-limited CodeRabbit review with no panel evidence is not certifiable"
assert_err_has "rate-limited" "34e rate-limit reason surfaced"
assert_err_has "did NOT carry the gate" "34e names the missing panel evidence (HIMMEL-1465)"

# 34e2 (HIMMEL-1465) — the SAME rate-limited decline, but a CLEAN critic panel
# recorded at the head in the CR ledger: the panel carries the gate and the
# verdict certifies. The exact audit line is pinned byte-for-byte.
run_in_repo "$LEDGER_REPO" cr-ratelimited
assert_rc 0 "34e2 rate-limited App with a clean panel at the head is panel-carried (HIMMEL-1465)"
assert_out_has "check-ci: CodeRabbit is rate-limited on head sha1 of PR #42; the critic panel carries the gate (carried responders=1 models=codex) — not failing the verdict on the App (HIMMEL-1465)." "34e2 existing rate-limit carry line is byte-identical"

run cr-unknownword
assert_rc 2 "34f an UNENUMERATED success wording fails closed, not open"
assert_err_has "does not say the review completed" "34f allow-list reason surfaced"
run_in_repo "$LEDGER_REPO" cr-unknownword
assert_rc 0 "34f2 unenumerated skip wording with a clean exact-head panel is carried"
assert_out_has "posted skip-classified wording" "34f2 distinct generic-skip carry line surfaced"

# 34g — the escape hatch that makes the allow-list safe to ship. If CodeRabbit
# renames its success description, every PR blocks at once; the operator must be
# able to clear that without a code change. Widening CR_OK_DESC_RE re-certifies
# the otherwise-unknown wording from 34f.
# Set + export explicitly rather than `VAR=x run ...`: `run` is a shell
# function, and a prefix assignment on a function has version-dependent
# persistence in bash. cr-signal.sh reads CR_OK_DESC_RE at SOURCE time in the
# child, so it must be exported before the child starts.
export CR_OK_DESC_RE='review completed|review deferred for reasons'
run cr-unknownword
assert_rc 0 "34g CR_OK_DESC_RE widens the allow-list without a code change"
unset CR_OK_DESC_RE

# 34h — CR follow-up (HIMMEL-1354 R2): the allow-list is consumed via jq's
# test(), which is an UNANCHORED search, not a full-string match. A future
# decline wording that merely CONTAINS an allow-listed phrase — e.g. "No
# review completed" contains "review completed" — would substring-match the
# allow-list and read as a clean success, reopening the exact hole this file
# exists to close. Pins that the built-in DEFAULT is anchored (^...$) so only
# an exact allow-listed description passes; CR_OK_DESC_RE (34g) stays a
# free-form operator override, unaffected by anchoring the default.
unset CR_OK_DESC_RE CR_SKIP_DESC_RE
run cr-substrmatch
assert_rc 2 "34h a description merely CONTAINING an allow-listed phrase fails closed"
assert_err_has "SKIPPED the review" "34h substring-match reason surfaced"
assert_err_has "does not say the review completed" "34h allow-list reason surfaced"

# 34i — codex adversarial follow-up (HIMMEL-1354 R2): anchoring only the
# built-in DEFAULT (34h) left the escape hatch itself unanchored, and
# CR_OK_DESC_RE REPLACES the default's regex verbatim — so an operator who
# widens the allow-list during an outage using the OLD documented recipe
# (no anchors) re-admits the exact substring hole 34h just closed, on the
# recovery path most likely to be exercised during that same drift. The
# documented recipe (scripts/lib/cr-signal.sh's OUTAGE ESCAPE HATCH block) is
# fixed here to carry its own ^(...)$ anchors; CR_OK_DESC_RE stays unanchored
# IN CODE — forcing
# an anchor there would break 34g's already-shipped loose partial-phrase
# widening (a bare keyword matching an unenumerated FULL sentence), so the
# anchors live in the recipe operators copy, not in code. Pins that following
# the CURRENT documented recipe verbatim still fails closed on a description
# that merely contains an allow-listed phrase.
export CR_OK_DESC_RE='^(review completed|no review changes requested|review finished)$'
run cr-substrmatch
assert_rc 2 "34i the anchored documented recipe still fails closed on a substring match"
unset CR_OK_DESC_RE

# 33 — an unresolved thread landing DURING the watch (head SHA unmoved) is
# caught by the post-watch review-state re-verification, not certified from
# the stale pre-watch snapshot (codex-adv 980-r2).
THREADS_OVERRIDE=latethread
run register-then-green
assert_rc 3 "33 late thread post-watch blocks"
assert_err_has "unresolved review thread" "33 late-thread reason printed"

# --- HIMMEL-1126/1147: review-BODY findings (S1) — checks green, threads
# clean, CodeRabbit concluded success in every case below; only the reviews
# fixture differs, so these isolate the NEW body gate ---

# 35 — an outside-diff-range finding in the review body blocks, same rank as
# an unresolved thread (rc 3), even though no thread exists for it at all.
run body-outside
assert_rc 3 "35 outside-diff body finding blocks"
assert_err_has "outside-diff-range finding" "35 outside-diff reason printed"

# 36 — a nitpick-only body is non-blocking; its count rides the success line.
run body-nitpick
assert_rc 0 "36 nitpick-only body allows"
assert_out_has "nitpick=1" "36 nitpick count surfaced on the success line"

# 37 — anti-drift canary (body SHOWS "Outside diff" but the count won't
# parse): check-ci is the CERTIFIER, so this fails CLOSED (rc 2) same as
# every other cannot-evaluate path here.
run body-drift
assert_rc 2 "37 drift-canary body cannot certify"
assert_err_has "cannot count" "37 drift-canary reason printed"

# 38 — the reviews query itself fails (infrastructure, reader rc 1): unlike
# cr-merge-gate's fail-OPEN on this code, check-ci fails CLOSED on it too —
# the certifier never has a fail-open path.
run body-error
assert_rc 2 "38 body-findings query failure cannot certify"
assert_err_has "could not read CodeRabbit's review-body findings" "38 body-query-failure reason printed"

# 39 — incremental-silent: CodeRabbit concluded on sha1 but emitted no review
# object there, while a prior head carries outside-diff findings. This is the
# resolvable rc 4 state, not the genuinely unreadable rc 2 state.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2
assert_rc 4 "39 incremental-silent body state rc 4"
assert_err_has "@coderabbitai full review" "39 full-review resolution printed"
assert_verdict 4 "39 un-maskable exit 4 verdict line"

# HIMMEL-1502/1506: when the current-head review object is the ONLY missing
# signal, resolved threads + a clean exact-head panel carry the gate. Either
# unresolved threads or absent panel evidence preserves the prior block.
run_in_repo "$LEDGER_REPO" body-a2
assert_rc 0 "39b absent head review object with resolved threads and clean panel is carried"
assert_out_has "check-ci: review object absent at head sha1 of PR #42; threads resolved; panel carries — HIMMEL-1502/1506 (carried responders=1 models=codex)." "39b exit-4 carry line byte-identical"
assert_out_has "carried responders=1 models=codex" "39b exit-4 carry evidence surfaced"
THREADS_OVERRIDE=2
run_in_repo "$LEDGER_REPO" body-a2
assert_rc 3 "39c unresolved threads still block despite clean panel evidence"
assert_err_has "2 unresolved review thread(s)" "39c unresolved-thread reason is unchanged"
THREADS_OVERRIDE=
run_in_repo "$DIRTY_LEDGER_REPO" body-a2
assert_rc 4 "39d a blocking panel finding keeps the absent-review-object arm blocked"
assert_err_has "@coderabbitai full review" "39d dirty-ledger exit-4 remedy is unchanged"

# 40 — --threads-only now ALSO runs the body gate (previously skipped head
# binding entirely, S1 was invisible here too): an outside-diff finding
# blocks this path exactly like the full run, and still never touches
# `gh pr checks`.
run body-outside --threads-only
assert_rc 3 "40 threads-only outside-diff body finding blocks"
assert_err_has "outside-diff-range finding" "40 threads-only outside-diff reason printed"
if grep -- 'checks' "$STUBDIR/args.log" >/dev/null; then
    fail "40 threads-only still skips gh pr checks" "args.log: $(cat "$STUBDIR/args.log")"
else
    pass "40 threads-only still skips gh pr checks"
fi

# 41 — codex CR: --threads-only must RE-verify threads AFTER CodeRabbit
# concludes (cr_signal_gate/cr_body_gate), not just the pre-conclude snapshot
# from the unconditional review_state_gate call at the top of the script.
# GH_STUB_THREADS=latethread reports clean on the FIRST graphql query and one
# unresolved thread on every query after — so this only goes rc 3 if the
# threads-only branch actually re-queries post-conclude, mirroring the full
# path's case 33.
THREADS_OVERRIDE=latethread
run register-then-green --threads-only
assert_rc 3 "41 threads-only re-verifies threads after CodeRabbit concludes"
assert_err_has "unresolved review thread" "41 threads-only late-thread reason printed"
if grep -- 'checks' "$STUBDIR/args.log" >/dev/null; then
    fail "41 threads-only late-thread case still skips gh pr checks" "args.log: $(cat "$STUBDIR/args.log")"
else
    pass "41 threads-only late-thread case still skips gh pr checks"
fi

# 42 — codex CR: --threads-only must re-bind the head before reporting
# success — a push during this (admittedly short) run must not certify a
# stale SHA, mirroring the full path's case 18. HEAD_OVERRIDE=moving returns
# a new SHA on every headRefOid read; this path reads it twice (head0 before
# cr_signal_gate/cr_body_gate, head1 just before success).
HEAD_OVERRIDE=moving
run register-then-green --threads-only
assert_rc 2 "42 threads-only head moved during the run rc 2"
assert_err_has "PR head moved during the run" "42 threads-only head-moved message"

# 43 — the real PR #1321 shape stays green: CodeRabbit status succeeded at the
# head, no review object exists there, and no prior outside-diff finding exists.
run body-empty
assert_rc 0 "43 benign zero-head-review shape stays green"
assert_out_has "all checks green + all review threads resolved" "43 benign shape reaches normal success"

# 87 (HIMMEL-1374) — the PR #1463 shape: CodeRabbit's status says "Review
# completed" while the PR carries ZERO CodeRabbit reviews, at any head, ever
# (freshness `none`), and no walkthrough certifies the head. "Completed" cannot
# be incremental when there is nothing to be incremental TO, so the two signals
# contradict each other: cannot evaluate (2), never the exit 0 this certified
# before. This is the HIMMEL-1354 class one layer up — each component was
# individually right, and nothing asked "was there ever a review at all?".
FRESHNESS_OVERRIDE=none
run cr-completed
assert_rc 2 "87 completed status with zero PR-wide reviews cannot be evaluated (HIMMEL-1374)"
assert_err_has "no CodeRabbit review object at any head" "87 refusal names the zero-reviews-ever shape"
assert_err_has "full review" "87 refusal names the remedy"

# 88 — the composition guard the fix must NOT break (HIMMEL-1465, live on PRs
# #1759/#1760 on 2026-08-20): a RATE-LIMITED App also has zero reviews PR-wide,
# but it never claimed a completed review — cr_signal_gate leaves that shape
# through the panel carry, not through `success` — so the clean exact-head
# critic panel still carries the gate and the verdict certifies.
FRESHNESS_OVERRIDE=none
run_in_repo "$LEDGER_REPO" cr-ratelimited
assert_rc 0 "88 rate-limited App with zero PR-wide reviews is still panel-carried"
assert_out_has "the critic panel carries the gate" "88 rate-limit carry line still surfaced"

# 89 — the discriminator's negative control: the SAME "Review completed" status
# and the SAME zero review objects at the head (the REST reviews fixture is
# empty), but a bot review DOES exist on the PR (freshness `fresh`). That is
# the ordinary incremental case — there IS something to be incremental to — so
# it must stay green. Without this, case 87 could be satisfied by blocking
# every zero-at-head PR, which is the false-BLOCK half of the same failure.
run cr-completed
assert_rc 0 "89 completed status with a PR-wide review present stays green"

# 44 — opt-in escalation CLAIMS the head, wins (no competing claim), and then
# posts exactly one full-review request; a clean review object appears on the
# immediate bounded re-read. Two comments now, not one (HIMMEL-1964): the claim
# marker is its own comment posted BEFORE the request, which is what makes the
# request single-flight.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate --escalate
assert_rc 0 "44 escalation resolves incremental-silent state"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 2 ]; then pass "44 escalation posts one claim + one request"; else fail "44 escalation posts one claim + one request" "posts=$posts want 2"; fi
claim_ln=$(grep -n -F -- '<!-- himmel:cr-escalate:sha1 attempt=1 -->' "$STUBDIR/args.log" | head -1 | cut -d: -f1)
req_ln=$(grep -n -F -- 'body=@coderabbitai full review' "$STUBDIR/args.log" | head -1 | cut -d: -f1)
if [ -n "$claim_ln" ] && [ -n "$req_ln" ] && [ "$claim_ln" -lt "$req_ln" ]; then
    pass "44 claim marker is posted BEFORE the full-review request"
else
    fail "44 claim marker is posted BEFORE the full-review request" "args.log: $(cat "$STUBDIR/args.log")"
fi

# 45 — a retry on the same head sees the exact marker and waits without
# posting again; the subsequent read can still complete the normal gate.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-marker --escalate
assert_rc 0 "45 existing marker still evaluates the refreshed review"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 0 ]; then pass "45 existing marker suppresses duplicate post"; else fail "45 existing marker suppresses duplicate post" "posts=$posts want 0"; fi
assert_err_has "already requested" "45 existing marker path is surfaced"
# The fixture marker is the PRE-HIMMEL-1964 shape (no attempt= field); it must
# read as attempt 1 so an in-flight head from an older check-ci keeps its one
# remaining retry rather than starting the pair over.
assert_err_has "(attempt 1)" "45 legacy attempt-less marker reads as attempt 1"

# 46 — bounded escalation never turns a missing review object into success.
# A zero-second budget makes the timeout immediate and hermetic.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-timeout --escalate
assert_rc 4 "46 escalation timeout rc 4"
assert_err_has "DO-NOT-MERGE" "46 timeout is loud and merge-blocking"
assert_verdict 4 "46 timeout prints exit 4 verdict"

# 47 — tuning knobs are not gate inputs: a malformed wait warns and falls back
# at the case-guard, and a zero poll against the resulting positive wait budget
# is caught by the cross-check, while the immediate refreshed review still
# reaches normal evaluation. CR_ESCALATE_POLL=0 (no sleep between re-reads) is
# what makes the case exercise this validation path fast rather than waiting on
# the fallen-back 120s poll (HIMMEL-1219).
ESCALATE_WAIT_OVERRIDE=soon
ESCALATE_POLL_OVERRIDE=0
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate --escalate
assert_rc 0 "47 invalid escalation tuning still evaluates"
assert_err_has "CR_ESCALATE_WAIT='soon'" "47 invalid wait warns + falls back"
assert_err_has "CR_ESCALATE_POLL=0 is invalid" "47 zero poll vs positive wait warns + falls back"

# 48 — escalation resolves only unreadability. A refreshed review carrying a
# real outside-diff finding still flows through the normal rc 3 body gate.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate-outside --escalate
assert_rc 3 "48 escalated outside-diff finding still blocks"
assert_err_has "outside-diff-range finding" "48 refreshed finding reaches normal evaluation"

# 49 — a full review may also create inline threads after the normal thread
# snapshot. Escalation must re-run that gate before it can certify success.
THREADS_OVERRIDE=escalatethread
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate --escalate
assert_rc 3 "49 escalated inline finding still blocks"
assert_err_has "unresolved review thread" "49 full-review thread re-check runs"

# 50 — zero is not a valid poll interval for a positive wait budget: it falls
# back before the loop, so the stale-review fixture gets no API-hammering burst.
ESCALATE_WAIT_OVERRIDE=1
ESCALATE_POLL_OVERRIDE=0
# The one case that opts back into a REAL sleep (HIMMEL-1953): the read count
# below is reads-per-interval, which only means anything against an interval
# that passes. The budget is 1 second, so that is all this costs.
SLEEP_CMD_OVERRIDE="sleep"
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-timeout --escalate
assert_rc 4 "50 zero escalation poll still times out"
assert_err_has "CR_ESCALATE_POLL=0 is invalid" "50 zero escalation poll warns + falls back"
reads=$(cat "$STUBDIR/reviews" 2>/dev/null); reads=${reads:-0}
if [ "$reads" -ge 2 ] && [ "$reads" -le 3 ]; then
    pass "50 zero escalation poll bounds body reads"
else
    fail "50 zero escalation poll bounds body reads" "reads=$reads want 2..3"
fi

# 51 — leading-zero waits PASS the all-digits guard but crash the budget
# arithmetic: bash reads a leading 0 as OCTAL in $(( )), so without the
# base-10 normalization $((08 - elapsed)) aborts with "value too great for
# base". body-a2-timeout drives the loop through that arithmetic, so this
# case proves 08 reaches a normal rc 4 timeout instead of erroring (HIMMEL-1219).
ESCALATE_WAIT_OVERRIDE=08
ESCALATE_POLL_OVERRIDE=0
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-timeout --escalate
assert_rc 4 "51 leading-zero wait 08 evaluates (no octal crash)"
assert_err_has "waiting up to 8s" "51 wait 08 normalized to decimal 8"
if printf '%s' "$ERR" | grep -F -- "value too great for base" >/dev/null; then
    fail "51 wait 08 did not crash the budget arithmetic" "stderr leaked a bash arithmetic error"
else
    pass "51 wait 08 did not crash the budget arithmetic"
fi

# 52 — 007 carries no 8/9 digit so it never crashes, yet read as octal it is
# silently 7 — coincidentally right for 007, wrong for any 01x value. The
# base-10 normalization forces decimal interpretation, so the budget reports
# 7s rather than the literal "007s" (HIMMEL-1219).
ESCALATE_WAIT_OVERRIDE=007
ESCALATE_POLL_OVERRIDE=0
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate --escalate
assert_rc 0 "52 leading-zero wait 007 still evaluates"
assert_err_has "waiting up to 7s" "52 wait 007 normalized to decimal 7 (not octal)"

# ── HIMMEL-1125: the availability gate ────────────────────────────────────────
# CR_APP=0 stubs "CodeRabbit is not configured for this repo" (no CLI, no App),
# which is the acceptance criterion's adopter. The contract these cases pin:
# the CodeRabbit-SPECIFIC requirement disarms; every generic gate stays armed.

# 53 — THE adopter case. No CodeRabbit, so no CodeRabbit status will EVER exist
# on any head. Pre-1125 this exited 2 on every merge, forever, unless the
# adopter discovered CR_PROFILE=none. Now it is simply green.
CR_APP_OVERRIDE=0
run cr-absent
assert_rc 0 "53 adopter without CodeRabbit: absent status is not a blocker"

# 54 — the deviation from the ticket's literal step 1, pinned deliberately.
# The ticket asked to skip "the thread gate" when CodeRabbit is absent. But
# review_state_gate is NOT a CodeRabbit gate — it blocks on ANY reviewer's
# unresolved thread, humans included. Skipping it would DELETE a live block for
# every adopter who uses human reviewers, contradicting the same ticket's
# "identical behaviour to today". So it stays armed with CodeRabbit absent.
CR_APP_OVERRIDE=0
THREADS_OVERRIDE=2
run register-then-green
assert_rc 3 "54 without CodeRabbit, unresolved HUMAN threads still block"

# 55 — fail-closed survives the disarm: "cannot evaluate" is never "clean", and
# that rule is not CodeRabbit's to own. An adopter gets it too.
CR_APP_OVERRIDE=0
THREADS_OVERRIDE=fail
run register-then-green
assert_rc 2 "55 without CodeRabbit, an unreadable thread state still blocks (fail-closed)"

# 56 — /pr-check step 4.8's path (--threads-only) is unaffected by the disarm.
CR_APP_OVERRIDE=0
THREADS_OVERRIDE=2
run red --threads-only
assert_rc 3 "56 without CodeRabbit, --threads-only still blocks on unresolved threads"

# 57 — "an adopter must not notice it exists". A disarmed gate must not narrate
# itself: no CodeRabbit word anywhere in the output of a clean adopter run.
CR_APP_OVERRIDE=0
run cr-absent
# Assert the run SUCCEEDED before reading its silence (coderabbit-6): a failing
# run that happens not to say "CodeRabbit" would otherwise pass this case.
assert_rc 0 "57 adopter clean run succeeds"
if printf '%s%s' "$OUT" "$ERR" | grep -i "coderabbit" >/dev/null; then
    fail "57 disarmed gate is silent about CodeRabbit" "output mentioned CodeRabbit: $ERR"
else
    pass "57 disarmed gate is silent about CodeRabbit"
fi

# 58 — HIMMEL-1495 hermeticity canary. This certifier does not consult the
# armed-session bypass env (ARMAUTOMERGE/CR_MERGE_GATE_OK), so a block fixture
# STILL blocks (rc 2) with both exported into the suite's env — pinning that
# insensitivity so a future change wiring either var into check-ci.sh fails
# HERE (the block-case reads rc 0) rather than failing every block-case open.
# The startup unset above is the matching defense-in-depth.
export ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1
run cr-absent
assert_rc 2 "58 armed bypass env does not open a block-case (HIMMEL-1495)"
unset ARMAUTOMERGE CR_MERGE_GATE_OK

# ── HIMMEL-1181 (B2): review-freshness gate — checks/threads/body all clean
# on every mode below (body-empty: watch green, CR status success, 0
# unresolved threads, no body findings), so these exercise the freshness
# gate in isolation. Base mode is body-empty rather than the earlier cr-*
# modes because the freshness READER itself is driven by GH_STUB_FRESHNESS,
# independent of GH_STUB_MODE — any clean base mode works. ──────────────────

# 59 — threads-only, fresh: rc 0, success line names the anchored review.
FRESHNESS_OVERRIDE=fresh
run body-empty --threads-only
assert_rc 0 "59 threads-only fresh review: rc 0"
assert_out_has "fresh coderabbitai review @ sha1" "59 success line names the fresh anchor"

# 60 — threads-only, stale: rc 4, remedy names both the stale and head SHAs
# and is DISTINCT wording from rc 3 (no thread to resolve here).
FRESHNESS_OVERRIDE=stale
run body-empty --threads-only
assert_rc 4 "60 threads-only stale review: rc 4"
assert_err_has "shaOLD" "60 stale reason names the stale anchor"
assert_err_has "sha1" "60 stale reason names the head"
assert_err_has "never re-reviewed" "60 stale reason names the remedy"

# 61 — full mode: freshness blocks even when the checks + CR status gates
# both already passed (the exact PR #1273 shape — "green" was not enough).
FRESHNESS_OVERRIDE=stale
run body-empty
assert_rc 4 "61 full mode stale review blocks after checks+status pass"

# 62 — threads-only, none (zero bot reviews on the whole PR, at any head,
# ever). HIMMEL-1374: this used to self-skip to rc 0, which is precisely the
# PR #1463 defect — `body-empty` posts a genuine "review completed" status, so
# a self-skip here certifies a PR nobody ever reviewed. With no walkthrough to
# certify the head either, the two signals contradict: rc 2. The self-skip
# survives only where nothing CLAIMS a review happened (case 88, the
# panel-carried rate-limit). --threads-only runs the same gate, so /pr-check
# step 4.8 gets the same protection as the full run.
FRESHNESS_OVERRIDE=none
run body-empty --threads-only
assert_rc 2 "62 threads-only zero-reviews-ever with a completed status: rc 2 (HIMMEL-1374)"
assert_err_has "no CodeRabbit review object at any head" "62 refusal names the zero-reviews-ever shape"

# 63 — threads-only, the freshness query itself fails: fail CLOSED, rc 2.
FRESHNESS_OVERRIDE=fail
run body-empty --threads-only
assert_rc 2 "63 threads-only freshness query failure: rc 2 (fail-closed)"

# 64 — threads-only, paged (>100 reviews, no bot match in the newest 100):
# indeterminate, fail CLOSED, rc 2 — never silently "none".
FRESHNESS_OVERRIDE=paged
run body-empty --threads-only
assert_rc 2 "64 threads-only paged freshness window: rc 2 (fail-closed)"

# 65 — CR_PROFILE=none skips the freshness gate together with the other
# CodeRabbit gates: a stale fixture must not block, and no reviews(last:)
# call should even be made (fully skipped, not merely tolerated).
FRESHNESS_OVERRIDE=stale
CR_PROFILE_OVERRIDE=none
run body-empty --threads-only
assert_rc 0 "65 CR_PROFILE=none skips the freshness gate too"
if grep -q "reviews(last:" "$STUBDIR/args.log" 2>/dev/null; then
    fail "65 CR_PROFILE=none still queried review freshness"
else
    pass "65 CR_PROFILE=none made no reviews(last:) call"
fi
if grep -q -- "--json changedFiles" "$STUBDIR/args.log" 2>/dev/null \
   || grep -q -- "--paginate repos/octo/demo/pulls/42/files" "$STUBDIR/args.log" 2>/dev/null; then
    fail "65 CR_PROFILE=none still queried the changed-file list"
else
    pass "65 CR_PROFILE=none made no changed-file-list call"
fi

# 66 — CR_BOT_LOGINS honors a configured non-default bot login.
FRESHNESS_OVERRIDE=mybot
CR_BOT_LOGINS_OVERRIDE=mybot
run body-empty --threads-only
assert_rc 0 "66 CR_BOT_LOGINS=mybot: configured bot recognized as fresh"

# 67 — CR_BOT_LOGINS normalizes case AND a trailing [bot] suffix: the fixture
# itself is unchanged (still the default 'coderabbitai' fresh shape); only
# the configured spelling varies.
FRESHNESS_OVERRIDE=fresh
CR_BOT_LOGINS_OVERRIDE="CodeRabbitAI[bot]"
run body-empty --threads-only
assert_rc 0 "67 CR_BOT_LOGINS normalizes case + [bot] suffix"

# 68 — a review with a null/empty commit anchor cannot be certified fresh OR
# stale: fail CLOSED, rc 2 (distinct from 'none' — a review object EXISTS,
# it just cannot be anchored).
FRESHNESS_OVERRIDE=nulloid
run body-empty --threads-only
assert_rc 2 "68 threads-only unanchored (null oid) review: rc 2 (fail-closed)"

# 69 — thread gate wins over freshness: unresolved threads AND a stale
# review both hold, but rc 3 (fix the thread) is the reported remedy, not
# rc 4 (the thread gate runs before the freshness gate in both modes).
FRESHNESS_OVERRIDE=stale
THREADS_OVERRIDE=2
run body-empty --threads-only
assert_rc 3 "69 unresolved threads + stale review: rc 3 (thread gate first)"

# ── HIMMEL-1718/2162: a stale review is carried by the EXISTING exact-head
# ledger evidence — the DEFAULT for this shape regardless of risk classification
# (HIMMEL-2162 retired the interim CHECK_CI_FRESHNESS_CARRY_HIGH_RISK knob: it
# only ever gated whether a high-risk diff could reach the panel-carry check,
# never bypassed the need for real panel evidence, so making the check
# unconditional left it with no remaining job). FAIL-CLOSED PRESERVED: no
# panel row at THIS head still exits 4, high-risk or not. ────────────────────

# 70 — no panel evidence preserves exit 4 and names the exact full-review remedy.
FRESHNESS_OVERRIDE=stale
run_in_repo "$EMPTY_LEDGER_REPO" body-empty --threads-only
assert_rc 4 "70 stale review + empty ledger stays rc 4"
assert_err_has "shaOLD" "70 stale refusal names the stale anchor"
assert_err_has "sha1" "70 stale refusal names the head"
assert_err_has "@coderabbitai full review" "70 stale refusal names the full-review remedy"

# 71 — ordinary diff + clean exact-head panel carries freshness, with provenance.
FRESHNESS_OVERRIDE=stale
FILES_OVERRIDE=README.md
run_in_repo "$LEDGER_REPO" body-empty --threads-only
assert_rc 0 "71 stale review + clean panel + ordinary diff is carried"
assert_out_has "FRESHNESS panel carry stale_anchor=shaOLD head=sha1" "71 freshness carry names stale and head anchors"
assert_out_has "responders=1 models=codex" "71 freshness carry surfaces responders and models"
assert_out_has "freshness panel-carried stale shaOLD -> head sha1" "71 success line names the freshness carry"

# 72 — a HIGH-RISK diff is carried too, by DEFAULT (HIMMEL-2162 — no knob
# needed). The suite's top-level unset proves no ambient operator value
# decides this; the loud line still names the risk classification for audit.
FRESHNESS_OVERRIDE=stale
FILES_OVERRIDE=scripts/hooks/foo.sh
run_in_repo "$LEDGER_REPO" body-empty --threads-only
assert_rc 0 "72 stale review + high-risk diff is carried by default"
assert_out_has "LOUD" "72 high-risk carry is loudly audited"
assert_out_has "scripts/hooks/foo.sh" "72 loud carry line names the high-risk path"
assert_out_has "HIMMEL-2162" "72 loud carry line cites the ticket"

# 73 — blocking ledger evidence never carries an otherwise ordinary diff.
FRESHNESS_OVERRIDE=stale
FILES_OVERRIDE=README.md
run_in_repo "$DIRTY_LEDGER_REPO" body-empty --threads-only
assert_rc 4 "73 stale review + dirty panel stays rc 4"
assert_err_has "blocking:" "73 dirty-panel refusal surfaces the ledger reason"

# 74 — an unreadable file-list classification (query failure) no longer
# blocks the carry: risk classification is diagnostic only now (HIMMEL-2162).
FRESHNESS_OVERRIDE=stale
FILES_OVERRIDE=fail
run_in_repo "$LEDGER_REPO" body-empty --threads-only
assert_rc 0 "74 unreadable changed-file list is carried by a clean panel"
assert_out_has "LOUD" "74 unreadable-classification carry is loudly audited"

# 75 — gh silently caps files at 100; a truncated changedFiles list is
# likewise diagnostic-only now, not a block, when the panel carries.
FRESHNESS_OVERRIDE=stale
FILES_OVERRIDE=truncated
run_in_repo "$LEDGER_REPO" body-empty --threads-only
assert_rc 0 "75 truncated changed-file list is carried by a clean panel"
assert_out_has "LOUD" "75 truncated-classification carry is loudly audited"

# ── HIMMEL-1698: B2 stale-anchor escalation ───────────────────────────────────

# 77 — --escalate posts the full-review request once, then the independent
# body + freshness re-reads both expose a review anchored at the head.
FRESHNESS_OVERRIDE=staleflip
run_in_repo "$EMPTY_LEDGER_REPO" body-b2-escalate --threads-only --escalate
assert_rc 0 "77 B2 escalation refreshes the stale anchor"
if grep -F -- '@coderabbitai full review' "$STUBDIR/args.log" >/dev/null \
    && grep -F -- '<!-- himmel:cr-escalate:sha1 attempt=1 -->' "$STUBDIR/args.log" >/dev/null; then
    pass "77 B2 escalation body carries command + head claim marker"
else
    fail "77 B2 escalation body carries command + head claim marker" "args.log: $(cat "$STUBDIR/args.log")"
fi
assert_out_has "(escalated)" "77 success line identifies the escalated freshness review"

# 78 — a review object can land at the head while the freshness reader still
# reports a stale latest anchor. That contradiction stays fail-closed.
FRESHNESS_OVERRIDE=stale
run_in_repo "$EMPTY_LEDGER_REPO" body-b2-escalate --threads-only --escalate
assert_rc 4 "78 B2 escalated review still stale rc 4"
assert_err_has "STILL not anchored" "78 stale post-escalation anchor is explicit"

# 79 — if no review object lands inside the budget, reuse the helper's existing
# loud timeout rather than falling through to stale-anchor tolerance.
FRESHNESS_OVERRIDE=stale
ESCALATE_WAIT_OVERRIDE=0
run_in_repo "$EMPTY_LEDGER_REPO" body-b2-timeout --threads-only --escalate
assert_rc 4 "79 B2 escalation timeout rc 4"
assert_err_has "DO-NOT-MERGE — no substantive CodeRabbit review is visible" "79 B2 timeout uses the existing merge-blocking message"

# 80 — without explicit opt-in, B2 remains a read-only observer.
FRESHNESS_OVERRIDE=stale
run_in_repo "$EMPTY_LEDGER_REPO" body-empty --threads-only
assert_rc 4 "80 B2 without escalation stays rc 4"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 0 ]; then pass "80 B2 default path posts no comments"; else fail "80 B2 default path posts no comments" "posts=$posts want 0"; fi

# 81 — a body review already exists at the head while freshness calls another
# review latest: escalation cannot repair that contradiction, so spend nothing.
FRESHNESS_OVERRIDE=stale
run_in_repo "$EMPTY_LEDGER_REPO" body-b2-head-review --threads-only --escalate
assert_rc 4 "81 B2 contradictory head review stays rc 4"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 0 ]; then pass "81 contradictory B2 shape posts no comments"; else fail "81 contradictory B2 shape posts no comments" "posts=$posts want 0"; fi

# 82 — the full review can reveal a body-only outside-diff finding. The explicit
# cr_body_gate re-run must preserve its rc 3 block before freshness can certify.
FRESHNESS_OVERRIDE=staleflip
run_in_repo "$EMPTY_LEDGER_REPO" body-b2-escalate-outside --threads-only --escalate
assert_rc 3 "82 B2 escalated outside-diff finding blocks"
assert_err_has "outside-diff-range finding" "82 refreshed B2 finding reaches the body gate"

# 83 — HIMMEL-1698: cr_signal_gate concludes success on head sha1 (the stub's
# default statuses shape, same as case 77), so a B2 escalation on that head
# must surface the benign-stale-anchor NOTE on stderr — DIAGNOSTIC ONLY, the
# escalation still fires and the exit code stays the rc 0 case 77 already
# pins (a NOTE that changed the verdict would be exactly the gate-condition
# regression the header on review_freshness_gate forbids).
FRESHNESS_OVERRIDE=staleflip
run_in_repo "$EMPTY_LEDGER_REPO" body-b2-escalate --threads-only --escalate
assert_rc 0 "83 B2 escalation with concluded head status stays rc 0"
assert_err_has "NOTE — CodeRabbit's status on head sha1 already reads a completed review" "83 benign-stale-anchor note is emitted"

# 84 — HIMMEL-1959: an EMPTY review object at the head is review evidence, but
# it is not the full review the escalation asked for. Before the fix the poll
# exited on head_reviews>0 and this returned rc 0 — a false GREEN certified off
# a review that said nothing, while the requested full review was still pending
# or had failed. The race is pre-existing in the A2 path (HIMMEL-1126); B2
# (HIMMEL-1698) widens exposure to it rather than introducing it.
ESCALATE_WAIT_OVERRIDE=1
ESCALATE_POLL_OVERRIDE=0
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate-empty --escalate
assert_rc 4 "84 empty review object at head does not satisfy the escalation"
assert_err_has "an empty incremental review is not the full review that was requested" \
    "84 refusal names the empty-object shape"

# 85 — HIMMEL-1959 CR round 1: the empty review object PERSISTS across
# invocations. Case 84 covers one run; this covers the next one, where that
# object is already at the head on the first read. Keying A2's entry on
# head_reviews made run 2 skip escalation, read outside=0 from a body that does
# not exist, and let the freshness gate certify the empty object as
# head-anchored — exit 0 on a full review that never arrived. Entry is keyed on
# `substantive` so both ends of the guard agree on what counts as a review.
ESCALATE_WAIT_OVERRIDE=1
ESCALATE_POLL_OVERRIDE=0
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-empty-persisted --escalate
assert_rc 4 "85 persisted empty review still triggers escalation"

# 86 — the same persisted state without --escalate stays a read-only rc 4
# rather than falling through to a green verdict.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-empty-persisted
assert_rc 4 "86 persisted empty review refuses without escalation"
assert_err_has "none carrying a body" \
    "86 refusal names the empty-object shape"

# ── HIMMEL-1964: single-flight claim + bounded retry ──────────────────────────

# 90 — TWO callers, ONE request. Our claim lands (id 1001) and the re-read of
# the claims at this attempt exposes a competing claim with a LOWER id (1000) —
# the caller that got there first. The loser must NOT spend a second full
# review out of account-wide CodeRabbit capacity; it drops straight into the
# poll and rides the winner's review, which is what makes the two-caller
# outcome identical to the one-caller outcome.
MARKERS_OVERRIDE="race:1000:1"
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate --escalate
assert_rc 0 "90 losing claimant still evaluates the winner's review"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 1 ]; then pass "90 losing claimant posts its claim and nothing else"; else fail "90 losing claimant posts its claim and nothing else" "posts=$posts want 1"; fi
if grep -F -- 'body=@coderabbitai full review' "$STUBDIR/args.log" >/dev/null; then
    fail "90 losing claimant never posts the full-review request" "args.log: $(cat "$STUBDIR/args.log")"
else
    pass "90 losing claimant never posts the full-review request"
fi
assert_err_has "claim #1000 beats #1001" "90 lost race names both claim ids"
# The losing claim is WITHDRAWN: left behind it would read as a spent attempt to
# every later invocation and cost the head one of its two requests.
if grep -F -- '-X DELETE repos/octo/demo/issues/comments/1001' "$STUBDIR/args.log" >/dev/null; then
    pass "90 losing claimant withdraws its claim"
else
    fail "90 losing claimant withdraws its claim" "args.log: $(cat "$STUBDIR/args.log")"
fi

# 91 — the STRAND, first half. A previous invocation claimed attempt 1 and its
# request never produced a substantive review; this run's own poll window
# expires on that claim too. Before HIMMEL-1964 the marker was permanent and
# every later run timed out forever on the same dead request. One controlled
# re-request is now allowed: claim attempt 2, post the command once, exit 4.
MARKERS_OVERRIDE="seed:900:1"
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-timeout --escalate
assert_rc 4 "91 stranded attempt 1 re-requests and stays merge-blocking"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 2 ]; then pass "91 strand retry posts one claim + one request"; else fail "91 strand retry posts one claim + one request" "posts=$posts want 2"; fi
if grep -F -- '<!-- himmel:cr-escalate:sha1 attempt=2 -->' "$STUBDIR/args.log" >/dev/null; then
    pass "91 strand retry claims attempt 2"
else
    fail "91 strand retry claims attempt 2" "args.log: $(cat "$STUBDIR/args.log")"
fi
assert_err_has "attempt 2" "91 strand retry names the attempt in its refusal"

# 92 — the STRAND, terminal half. Attempt 2 has also gone a full window without
# a substantive review, so the head is stranded: refuse LOUDLY, name the manual
# remedy, and spend NOTHING — two requests per head is the cap, and a third
# would be the unbounded loop this ticket exists to prevent.
MARKERS_OVERRIDE="seed:900:2"
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-timeout --escalate
assert_rc 4 "92 stranded attempt 2 stays merge-blocking"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 0 ]; then pass "92 stranded head requests no third review"; else fail "92 stranded head requests no third review" "posts=$posts want 0"; fi
assert_err_has "STRANDED" "92 strand is named, not silently timed out"
assert_err_has "Push a new commit" "92 strand refusal names the manual remedy"

# 93 — the partial failure INSIDE the claim (codex panel r1): the claim wins,
# then the full-review POST fails. Leaving that claim behind would consume one
# of the two attempts while spending no request at all — this ticket's own bug,
# one layer in — so the claim is rolled back before the fail-closed exit 2.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-postfail --escalate
assert_rc 2 "93 failed full-review post cannot evaluate the gate"
if grep -F -- '-X DELETE repos/octo/demo/issues/comments/1001' "$STUBDIR/args.log" >/dev/null; then
    pass "93 failed request rolls its claim back"
else
    fail "93 failed request rolls its claim back" "args.log: $(cat "$STUBDIR/args.log")"
fi

# ── HIMMEL-2062: bounded watch — early exit + --max-wait cap ─────────────────

# 94 — --max-wait validation: non-integer
run red --max-wait soon
assert_rc 2 "94 non-numeric --max-wait rc 2"
assert_err_has "--max-wait must be a non-negative integer" "94 max-wait validation message"

# 95 — --max-wait validation: no value
run red --max-wait
assert_rc 2 "95 --max-wait with no value rc 2"
assert_err_has "--max-wait needs a value" "95 max-wait needs-a-value message"

# 96 — early exit: the watch would otherwise block (the stub's --watch arm
# sleeps), but --json bucket,name reports only a CodeRabbit-named row still
# pending and CodeRabbit's own gate status is already terminal (the default
# statuses fixture: state=success) — the watch is stopped WITHOUT waiting it
# out, and the run gives the SAME exit code the equivalent instant-green mode
# (register-then-green) gives. --max-wait 0 (unbounded) isolates this from the
# cap so only the decidable early-exit path can produce rc 0 here.
run blocking-cr-decidable --max-wait 0
assert_rc 0 "96 early decidable exit rc 0 (matches instant-green)"
assert_err_has "ending the watch early (HIMMEL-2062)" "96 early-exit message printed"

# 97 — cap: a NON-CodeRabbit check is still pending when --max-wait elapses —
# cannot certify green over unfinished work even though nothing has failed.
run blocking-cap-pending --max-wait 1
assert_rc 2 "97 cap with non-CodeRabbit pending rc 2"
assert_err_has "watch cap reached (1s)" "97 cap message printed"
assert_err_has "non-CodeRabbit checks still pending" "97 cap-with-pending refusal"

# 98 — cap + red: the structured probe finds a failed check once the cap is
# reached — reported the same as an ordinary red (red_exit), not the
# cap-with-pending refusal (failed>0 is checked first).
run blocking-cap-red --max-wait 1
assert_rc 1 "98 cap with a failed check rc 1"
assert_err_has "watch cap reached (1s)" "98 cap message printed on the red path too"
assert_err_has "checks FAILED" "98 red_exit fires after the bounded watch"

# 99 — a POLL configured LARGER than --max-wait must not make the cap
# overshoot by a full POLL interval (codex-1, HIMMEL-2062 CR round 1): the
# supervisor now checks the deadline BEFORE sleeping and clamps the sleep to
# the remaining budget, so a 50s poll against a 1s cap still returns in
# roughly 1s, not roughly 50s. Opts into a REAL sleep (like case 50) — the
# elapsed-time signal this proves does not exist against the `:` no-op seam.
POLL_OVERRIDE=50
SLEEP_CMD_OVERRIDE="sleep"
t0=$SECONDS
run blocking-cap-pending --max-wait 1
t_elapsed=$((SECONDS - t0))
assert_rc 2 "99 cap still fires with a POLL larger than --max-wait"
assert_err_has "watch cap reached (1s)" "99 cap message printed despite the large poll"
if [ "$t_elapsed" -le 10 ]; then
    pass "99 max-wait does not overshoot by a full POLL interval"
else
    fail "99 max-wait does not overshoot by a full POLL interval" "elapsed=${t_elapsed}s want <=10s (POLL=50s)"
fi

# 100 — a pending check whose name merely CONTAINS "coderabbit" (not an exact
# match) must not be misread as the ignorable rollup (codex-2, HIMMEL-2062 CR
# round 1): watch_decidable stays false, so the watch runs to the cap instead
# of short-circuiting green through the decidable path.
run blocking-cr-substring --max-wait 1
assert_rc 2 "100 substring-named pending check keeps watch_decidable false"
assert_err_has "watch cap reached (1s)" "100 cap message printed, not an early decidable exit"
assert_err_has "non-CodeRabbit checks still pending" "100 cap-with-pending refusal"

# 101 — CHECK_CI_POLL_INTERVAL=0 must not turn the supervisor loop into a
# sleep-fork storm (codex-1, HIMMEL-2062 CR round 2): the floor makes an
# unfloored `sleep 0` behave as a 1s poll, so the watch, sleep command call
# count over a --max-wait 2 window stays roughly bounded by MAX_WAIT (a
# handful) rather than however many iterations a real-time-based cap loop can
# spin in ~2s with no per-call delay (hundreds+). counting-sleep is the ONE
# stub in this suite that really sleeps (see its definition above) — without
# a real per-call delay, pre- and post-fix would spin identically fast and
# this count could never tell them apart.
# HIMMEL-2267: --max-wait must stay strictly BELOW the blocking-cap-pending
# stub's 3s sleep (same margin cases 98-100 rely on) — at --max-wait 3 the cap
# and the stub's green verdict race, and on a quiet/fast box the stub's rc=0
# lands first, failing the assert_rc 2 below nondeterministically. Do not
# raise this back to 3.
POLL_OVERRIDE=0
SLEEP_CMD_OVERRIDE="$STUBDIR/counting-sleep"
run blocking-cap-pending --max-wait 2
assert_rc 2 "101 POLL=0 still reaches the cap-with-pending refusal"
sleeps=$(wc -l < "$STUBDIR/sleepcount" 2>/dev/null); sleeps=${sleeps:-0}
if [ "$sleeps" -ge 1 ] && [ "$sleeps" -le 6 ]; then
    pass "101 POLL=0 does not sleep-fork-storm (floored to ~1/s)"
else
    fail "101 POLL=0 does not sleep-fork-storm (floored to ~1/s)" "sleep calls=$sleeps want 1..6 for a 2s cap"
fi

# ── HIMMEL-2206: kill -0 is not a valid liveness probe for a backgrounded
# job — once it exits it is a zombie until reaped, and kill -0 on a zombie
# SUCCEEDS (confirmed on this very host: a plain `true &` still answers
# kill -0 across several unyielded loop iterations with no intervening
# `wait`). watch_round now polls a child-written rc sentinel file instead.
# That race is exactly what let every round on Windows run out the
# --max-wait cap and silently discard gh's real rc/stderr, no matter how
# fast gh itself actually finished. A hermetic stub cannot force the OS-level
# zombie-vs-reaped race deterministically either way (it depends on host
# scheduling, not on anything this suite controls) — cases 102/103 instead
# pin the OBSERVABLE contract the fix must uphold: a near-instantly resolving
# `gh pr checks --watch` reaches the real-verdict path even under a tight
# --max-wait, never the cap's discard-the-verdict path. Case 105 (structural)
# additionally pins that the broken mechanism itself — kill -0 as the loop's
# liveness test — is gone.

# 102 — a red check that resolves near-instantly must still take the
# real-verdict path (stopped="") under a tight --max-wait; the reported bug
# instead ran out the cap and silently dropped gh's real rc/stderr.
run red --max-wait 5
assert_rc 1 "102 fast red still resolves via the real-verdict path"
assert_err_has "checks FAILED" "102 red_exit fires (rc/stderr not discarded)"
if printf '%s' "$ERR" | grep -iF -- "watch cap reached" >/dev/null; then
    fail "102 does not fall through to the cap path" "stderr: $ERR"
else
    pass "102 does not fall through to the cap path"
fi

# 103 — same shape for the gh-error (cannot-evaluate) path: a near-instant
# auth/network failure must reach exit 2 via gh's REAL stderr, not get
# silently swallowed by the cap and re-evaluated structurally instead.
run watch-error --max-wait 5
assert_rc 2 "103 fast gh-error still resolves via the real-verdict path"
assert_err_has "cannot evaluate the gate" "103 real gh stderr reaches the caller"
if printf '%s' "$ERR" | grep -iF -- "watch cap reached" >/dev/null; then
    fail "103 does not fall through to the cap path" "stderr: $ERR"
else
    pass "103 does not fall through to the cap path"
fi

# 104 — orphan guard: when the watch IS stopped early (cap), the real gh
# process must actually die, not just a wrapper around it. Wrapping gh in a
# subshell to read its rc off a sentinel file (the fix here) means $wpid is
# the SUBSHELL, not gh itself — killing only $wpid on early stop would leave
# gh running detached, still writing to the terminal after this gate has
# already moved on to a structural verdict (the orphan-on-early-stop
# regression flagged in review). blocking-cap-pending's stub records its own
# pid to $STUBDIR/watch-pid (same idiom as counting-sleep — this process has
# no $STUBDIR in its env) before it sleeps.
#
# codex-2, HIMMEL-2206 CR round 4: kill -0 alone is NOT proof of death — this
# very ticket establishes it also succeeds against a killed-but-unreaped
# zombie, so asserting "dead" via kill -0 here would be exactly the
# unreliable signal this change replaces. The stub also drops a SEPARATE
# marker (completed-naturally) right after its sleep, the same point it
# would print its success line — an orphaned (not actually killed) process
# still reaches that line 3s in; a genuinely killed one never does. Poll well
# past that 3s mark and assert the marker never appears — a zombie's
# lingering process-table entry cannot fake an absent side effect.
: > "$STUBDIR/watch-pid"
rm -f "$STUBDIR/completed-naturally"
run blocking-cap-pending --max-wait 1
assert_rc 2 "104 cap still fires"
watch_pid=$(cat "$STUBDIR/watch-pid" 2>/dev/null)
orphan_leaked=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    [ -e "$STUBDIR/completed-naturally" ] && { orphan_leaked=1; break; }
    sleep 0.2
done
if [ -n "$watch_pid" ] && [ "$orphan_leaked" -eq 0 ]; then
    pass "104 early stop does not leave the inner gh process running"
else
    fail "104 early stop does not leave the inner gh process running" "watch_pid=${watch_pid:-<missing>}; completed-naturally marker leaked=$orphan_leaked (orphan kept running past its sleep)"
fi

# 105 — structural: pin that kill -0 is gone as watch_round's liveness test
# and that the atomic sentinel-file write/poll pattern (tmp + same-dir mv -f)
# is in place. Not timing-dependent by design (see the section header above).
# shellcheck disable=SC2016  # literal text to grep for in $SCRIPT, not a shell expansion
if grep -Eq 'while +kill -0 "\$wpid"' "$SCRIPT"; then
    fail "105 kill -0 removed as watch_round's liveness probe" "kill -0 \"\$wpid\" still gates the poll loop in $SCRIPT"
else
    pass "105 kill -0 removed as watch_round's liveness probe"
fi
# shellcheck disable=SC2016  # literal text to grep for in $SCRIPT, not a shell expansion
if grep -Fq 'while [ ! -f "$rc_file" ]' "$SCRIPT" && grep -Fq 'mv -f "$rc_file.tmp" "$rc_file"' "$SCRIPT"; then
    pass "105b watch_round polls an atomically-written rc sentinel file"
else
    fail "105b watch_round polls an atomically-written rc sentinel file" "sentinel write/poll pattern not found in $SCRIPT"
fi

# 106 — HIMMEL-2206 CR round 5 (REJECTED deferral, fixed in-branch): the
# pid-SIDECAR FILE never appearing must not leave gh orphaned — the earlier
# fix only closed the pid-write RACE (sidecar lands late), not the FAILURE
# (sidecar never lands at all: write error, or the wrapper dies before the
# write). watch_round now also arms `trap 'kill "$gh_pid" 2>/dev/null' TERM`
# on the wrapper, independent of the sidecar file entirely, so the parent's
# `kill "$wpid"` (which sends TERM) reaches the real gh through the trap even
# when the sidecar was never written. Structural pin first, then a functional
# proof that reproduces watch_round's exact subshell/trap shape against a
# REAL backgrounded process with the pid-sidecar step DELETED — the failure
# case itself, not a timing race — and confirms killing only the wrapper
# still kills the real process.
# shellcheck disable=SC2016  # literal text to grep for in $SCRIPT, not a shell expansion
if grep -Fq 'trap '"'"'kill "$gh_pid" 2>/dev/null'"'"' TERM' "$SCRIPT"; then
    pass "106 watch_round arms a TERM trap on gh independent of the pid sidecar"
else
    fail "106 watch_round arms a TERM trap on gh independent of the pid sidecar" "TERM trap on \$gh_pid not found in $SCRIPT"
fi
rm -f "$STUBDIR/completed-naturally" "$STUBDIR/watch-pid" "$STUBDIR/term-trap-fired"
(
    gh_rc=1
    trap 'printf "%s\n" "$gh_rc" >/dev/null 2>&1' EXIT
    (
        GH_STUB_MODE=blocking-cap-pending GH_STUB_ARGS="$STUBDIR/args.log" \
        PATH="$STUBDIR:$PATH" \
        exec gh pr checks --watch --fail-fast
    ) 2>/dev/null &
    gh_pid=$!
    # codex-1, HIMMEL-2206 CR round 6: the trap-fired marker is TEST-ONLY
    # instrumentation (production's trap is exactly `kill "$gh_pid"
    # 2>/dev/null`, unmodified) — it directly proves the trap itself
    # executes on TERM, since this platform can independently propagate a
    # kill to a directly-exec'd 2-level child on its own (observed: even
    # WITHOUT this trap, killing only the outer wrapper still kills gh here),
    # which would otherwise let this test pass for the wrong reason.
    trap 'kill "$gh_pid" 2>/dev/null; : > "$STUBDIR/term-trap-fired"' TERM
    # Deliberately NO pid-sidecar write here — this is the failure case
    # (sidecar never appears), not the race the earlier fix already covers.
    wait "$gh_pid"; gh_rc=$?
    exit "$gh_rc"
) &
no_sidecar_wpid=$!
sleep 0.3
kill "$no_sidecar_wpid" 2>/dev/null
# codex-1, HIMMEL-2206 CR round 6: poll well PAST the stub's 3s sleep (same
# margin as case 104) — the earlier fixed 2s wait checked before the 3s mark,
# so a genuinely leaked process could still pass this test by not having
# reached the marker YET, not because it was actually killed.
no_sidecar_leaked=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    [ -e "$STUBDIR/completed-naturally" ] && { no_sidecar_leaked=1; break; }
    sleep 0.2
done
wait "$no_sidecar_wpid" 2>/dev/null
if [ "$no_sidecar_leaked" -eq 0 ]; then
    pass "106 TERM trap kills gh even with no pid sidecar at all"
else
    fail "106 TERM trap kills gh even with no pid sidecar at all" "completed-naturally marker leaked — gh survived the wrapper with no sidecar to fall back on"
fi
if [ -e "$STUBDIR/term-trap-fired" ]; then
    pass "106b the TERM trap itself actually executes on early stop"
else
    fail "106b the TERM trap itself actually executes on early stop" "term-trap-fired marker never appeared — the trap did not run"
fi

# --- HIMMEL-2278: the machine-generated-PR class ----------------------------
#
# Baseline for every case here: `cr-absent` — checks green, threads clean, and
# CodeRabbit posted NO status on the head. That is case 27's shape, and it is
# rc 2 forever today. The class fix turns rc 2 into rc 0 for EXACTLY two PR
# shapes and must leave it at rc 2 for everything else; the negative controls
# below (2278-c/d/e/f/g/h/l) are the actual deliverable, not the two positives.

# 2278-a — dependabot dep bump + no App review → rc 0 (the #2013 shape).
MPR_OVERRIDE=dependabot
run cr-absent
assert_rc 0 "2278-a dependabot PR passes with no CodeRabbit review"
assert_out_has "machine-generated PR (dependabot dependency bump)" "2278-a audit line names the class"

# 2278-b — a graph-publish artifact PR + no App review → rc 0 (the #2035 shape).
MPR_OVERRIDE=graph
run cr-absent
assert_rc 0 "2278-b graphify-artifact PR passes with no CodeRabbit review"
assert_out_has "regenerated graphify-out artifacts only" "2278-b audit line names the diff-shape class"

# 2278-c — THE SPOOF CONTROL. The same two artifact paths PLUS one code path.
# If the class were a label or a title marker this would pass; because it is
# the diff shape, one path outside the artifact set fails closed exactly as
# before. This is the case that carries the whole ticket's risk.
MPR_OVERRIDE=graph-plus-code
run cr-absent
assert_rc 2 "2278-c artifact paths PLUS a code path still fail closed"
assert_err_has "has posted NO status" "2278-c fails with the unchanged absent-review message"

# 2278-d — an ordinary human code PR with no App review: byte-unchanged rc 2.
MPR_OVERRIDE=none
run cr-absent
assert_rc 2 "2278-d ordinary code PR still fails closed on an absent review"

# 2278-e — a human account whose login merely LOOKS like the bot's. is_bot is
# GitHub's, so the impostor stays outside the class.
MPR_OVERRIDE=dep-impostor
run cr-absent
assert_rc 2 "2278-e dependabot login without is_bot is not the class"

# 2278-f — the classifier's own probe erroring is not evidence of anything:
# fail closed, never classify.
MPR_OVERRIDE=probe-fail
run cr-absent
assert_rc 2 "2278-f an erroring author/files probe fails closed"

# 2278-g — a response missing the MPR_OK sentinel must not parse as a bot
# author with zero files (the shape an empty/garbled reply would otherwise take).
MPR_OVERRIDE=garbage
run cr-absent
assert_rc 2 "2278-g a sentinel-less probe response fails closed"

# 2278-h — a single file literally named `*`. Comparing in the wrong direction
# (artifact list as subject, path as pattern) would glob-match it into the class.
MPR_OVERRIDE=globname
run cr-absent
assert_rc 2 "2278-h a glob-named path cannot glob its way into the class"

# 2278-l — an empty changed-file list is not "all paths are artifacts".
MPR_OVERRIDE=empty
run cr-absent
assert_rc 2 "2278-l an empty file list fails closed"

# 2278-m — a truncated-but-rc-0 probe: it advertises 3 files but emits only the
# two artifact paths. Every path it DID emit is an artifact, so a classifier
# that trusted the path lines alone would let it in; the count check is what
# makes "fail closed on an unparsable probe" true for a PARTIAL one too.
MPR_OVERRIDE=truncated
run cr-absent
assert_rc 2 "2278-m a truncated file list fails closed"

# --- HIMMEL-2278 CR round 2: the class tolerates SILENCE, and only silence ---
#
# codex-1 disproved the first cut's blanket `CR_ARMED=0`: it also silenced
# cr_body_gate and review_freshness_gate, so on the day the App DOES review a
# machine-class PR its outside-diff-range body findings — which carry no
# thread, and so are invisible to every other gate — would have been dropped.
# 2278-n is the positive (the #2035 rate-limited shape is tolerated); n+1..n+3
# are the controls that the narrowing actually narrowed.

# 2278-n — the #2035 shape verbatim: state=success with a rate-limited
# description. Skip-classified means the App said nothing, which for this class
# is expected. rc 0.
MPR_OVERRIDE=dependabot
run cr-ratelimited
assert_rc 0 "2278-n a rate-limited App is expected silence for the class"

# 2278-o — a FAILED App status is not silence: it still blocks at rc 1.
MPR_OVERRIDE=dependabot
run cr-failure
assert_rc 1 "2278-o a failed App status still blocks a machine-generated PR"

# 2278-p — nor is a PENDING one: rc 2, re-run when it concludes.
MPR_OVERRIDE=dependabot
run cr-pending
assert_rc 2 "2278-p a pending App review still blocks a machine-generated PR"

# 2278-q — THE codex-1 control. The App reviewed this machine PR after all and
# posted an outside-diff-range body finding, which carries no thread to resolve.
# Under the blanket disarm this returned rc 0 and the finding vanished; the
# narrowed flag leaves cr_body_gate armed, so it blocks at rc 3.
MPR_OVERRIDE=dependabot
run body-outside
assert_rc 3 "2278-q an outside-diff body finding still blocks a machine-generated PR"
assert_err_has "outside-diff-range finding" "2278-q the body-finding reason is still printed"

# 2278-r — codex-2: graph-publish commits both artifacts, but when only
# graph.json actually changed the PR diff is ONE file. The rule is "every
# changed path is one of the two artifacts", not "both are present", so the
# singleton is in the class. Pins the shape the prose used to overstate.
MPR_OVERRIDE=graph-single
run cr-absent
assert_rc 0 "2278-r a single-artifact diff is still the class"

# 2278-i — NOT a merge bypass: the unresolved-thread gate stays armed for the
# class. Two unresolved threads on a dependabot PR still block at rc 3.
MPR_OVERRIDE=dependabot
THREADS_OVERRIDE=2
run cr-absent
assert_rc 3 "2278-i unresolved threads still block a machine-generated PR"

# 2278-j — nor a checks bypass: a red check on a machine-generated PR is rc 1.
MPR_OVERRIDE=dependabot
run red
assert_rc 1 "2278-j a red check still blocks a machine-generated PR"

# 2278-k — nor a review bypass: CHANGES_REQUESTED still blocks at rc 3.
MPR_OVERRIDE=dependabot
DECISION_OVERRIDE=CHANGES_REQUESTED
run cr-absent
assert_rc 3 "2278-k CHANGES_REQUESTED still blocks a machine-generated PR"


# ── HIMMEL-2380: the honest line, and the silence it must not break ──────────
# Console ruling 88. HIMMEL-2380 asked for an unconditional "CodeRabbit: not
# configured" line on every disarmed run; case 57 above forbids the word
# "CodeRabbit" anywhere in a clean adopter run, and cr-available.sh's header
# calls that silence the point ("an adopter must not notice it exists"). The
# ruling narrowed the line to the states where a review was actually EXPECTED,
# so a pass is called vacuous only when something is genuinely missing.
#
# NOTE ON THE FIXTURES: these three are the first cases here to leave
# CR_APP_OVERRIDE EMPTY. Every other case pins it (see its comment at the top)
# so ~30 pre-1125 cases cannot flip with the arming state of whichever clone the
# suite runs from. That pin is also what makes case 57's adopter a SEAM rather
# than a real adopter — CR_APP=0 short-circuits before the git config is read at
# all. Running in a fixture repo with the override empty exercises the marker
# path itself, which is the only way to reach `broken`.

# 2380-a — THE case the predicate exists for. The marker IS set, to a value git
# cannot parse, so the gates are disarmed and any green here certifies a
# CodeRabbit review nobody ever checked for. rc 0 pins WARN-NOT-BLOCK: the
# `cr-absent` mode exits 2 when the gate is armed (case 58) and 0 when it is
# not, so an accidental arming fails this case rather than passing it quietly.
CR_APP_OVERRIDE=""
run_in_repo "$BROKEN_MARKER_REPO" cr-absent
assert_rc 0 "2380-a a broken himmel.coderabbit marker warns but never blocks"
assert_err_has "himmel.coderabbit marker holds a value git cannot parse" \
    "2380-a the warning names the actual cause"
assert_err_has "git config --local --unset himmel.coderabbit" \
    "2380-a the warning carries the fix for a repo that has no CodeRabbit"

# 2380-b — NEGATIVE CONTROL, and the one that matters most: case 57's invariant
# re-proved against a FAITHFUL adopter (a real repo, no marker, no CR_APP seam).
# This is precisely what the ticket's literal wording would have broken.
CR_APP_OVERRIDE=""
run_in_repo "$EMPTY_LEDGER_REPO" cr-absent
assert_rc 0 "2380-b real adopter (no marker, no override) is still green"
if printf '%s%s' "$OUT" "$ERR" | grep -i "coderabbit" >/dev/null; then
    fail "2380-b a real adopter still hears nothing about CodeRabbit" "output mentioned CodeRabbit: $ERR"
else
    pass "2380-b a real adopter still hears nothing about CodeRabbit"
fi

# 2380-c — precedence, and the noise it suppresses. CR_PROFILE=none is read
# before the marker (cr_app_state keeps cr_app_configured's order), so an
# operator who already opted out is not told about a typo in a marker their own
# setting overrides. State is `disabled`, not `broken`: no warning.
CR_APP_OVERRIDE=""
CR_PROFILE_OVERRIDE=none
run_in_repo "$BROKEN_MARKER_REPO" cr-absent
assert_rc 0 "2380-c CR_PROFILE=none over a broken marker is still green"
if printf '%s' "$ERR" | grep -F "himmel.coderabbit marker holds a value" >/dev/null; then
    fail "2380-c an explicit opt-out suppresses the broken-marker warning" "warned anyway: $ERR"
else
    pass "2380-c an explicit opt-out suppresses the broken-marker warning"
fi
echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
if [ "$COUNT" -ne 142 ]; then echo "CASE-COUNT MISMATCH: ran $COUNT want 142"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
