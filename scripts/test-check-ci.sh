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
#   5.  unknown option                       → rc 64, usage, verdict line (HIMMEL-3317)
#   5b. --help                               → rc 0, usage, no verdict line
#   5c. `--pr <n>` (the real-world mistake)  → rc 64 + verdict; a genuine
#       cannot-evaluate (case 1/4) still rc 2 — the false-positive control
#   (1/2/3/11 additionally assert exactly one exact-match
#   "check-ci: verdict exit=N" line — HIMMEL-974)
#   6.  --grace non-numeric                  → rc 64
#   7.  two positional selectors             → rc 64
#   8.  selector is passed through to gh as an exact token
#   9.  settle round catches a late red (green watch 1, red watch 2) → rc 1
#   10. settle round green twice             → rc 0, exactly 2 watch calls
#   11. checks green, 2 unresolved threads   → rc 3
#   12. checks green, thread query fails     → rc 2 (fail-closed gate)
#   13. non-numeric CHECK_CI_POLL_INTERVAL   → warns, falls back, still runs
#   14. --settle non-numeric                 → rc 64
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
#   39. a posted prior-head outside-diff finding still blocks (operator
#       ruling 2026-09-21: best effort covers ABSENCE only, not a posted
#       finding) → rc 3; dispositioned at the governing prior head → rc 0
#   39e-39h. TWO prior heads carry findings (HIMMEL-3365): every prior head
#       governs; the newer one never masks the older → rc 3 until each is
#       dispositioned at the head that raised it, then rc 0
#   43. zero head reviews, no prior finding → rc 0 (PR #1321 benign shape)
#   89. "Review completed" + a PR-wide review present → rc 0 (no false block)
#
#   HIMMEL-3360 retired --escalate, review_freshness_gate's stale-anchor
#   escalation, the review-object-absent panel-carry gate (exit 4), and the
#   PR-wide-review-freshness gate — CodeRabbit's status/review state is
#   advisory-only now (thread + body-findings gates still certify the merge).
#   The former cases 44-52, 77-93 and 3152-a/b/c/d all exercised that removed
#   machinery and are gone, not renumbered; see cases 27-34f, 3360d, 3360e,
#   39, 39b, 39c below for their HIMMEL-3360 replacements.
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
# HIMMEL-3385: the value of the --jq flag among the args ("" if none).
_jq_arg() { while [ $# -gt 0 ]; do if [ "$1" = "--jq" ]; then printf '%s' "${2:-}"; return; fi; shift; done; }
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
        # HIMMEL-3381: the EFFECTIVE required-check set. Rulesets (rules/branches)
        # and classic protection are two separate endpoints; the default is "no
        # rule at all" so every pre-3381 case keeps its verdict untouched.
        repos/octo/demo/rules/branches/main)
            case "${GH_STUB_RULES:-none}" in
                # Like every stub here, this emits the shape AFTER check-ci's --jq
                # (one required context per line), not the raw ruleset JSON.
                none) : ;;
                fail) echo "HTTP 500: rules boom" >&2; exit 1 ;;
                req:*) printf '%s\n' "${GH_STUB_RULES#req:}" | tr ',' '\n' ;;
                # HIMMEL-3385: a RAW ruleset payload run through the --jq expression
                # check-ci.sh actually passed, so a producer id the script's own
                # expression drops stays dropped here too.
                json:*) printf '%s' "${GH_STUB_RULES#json:}" | jq -r "$(_jq_arg "$@")" ;;
            esac
            exit 0 ;;
        repos/octo/demo/branches/main/protection/required_status_checks)
            case "${GH_STUB_CLASSIC:-none}" in
                none) echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
                fail) echo "gh: Must have admin rights to Repository. (HTTP 403)" >&2; exit 1 ;;
                ctx:*) printf '%s\n' "${GH_STUB_CLASSIC#ctx:}" | tr ',' '\n' ;;
                json:*) printf '%s' "${GH_STUB_CLASSIC#json:}" | jq -r "$(_jq_arg "$@")" ;;
            esac
            exit 0 ;;
        repos/octo/demo/commits/sha1/check-runs*)
            # HIMMEL-3385: the producer read. Raw check-runs JSON through the real
            # --jq expression; "fail" is an unreadable read; anything else keeps the
            # old empty payload every pre-3385 caller sees.
            case "${GH_STUB_PRODUCERS:-none}" in
                fail) echo "HTTP 500: check-runs boom" >&2; exit 1 ;;
                json:*) printf '%s' "${GH_STUB_PRODUCERS#json:}" | jq -r "$(_jq_arg "$@")" ;;
                *) echo '{"check_runs":[]}' ;;
            esac
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
                body-outside) echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"> **⚠️ Outside diff range comments (1)**\n> \n> `stub.sh:5`\n> _x_ | _🟡 Minor_ | _y_\n> \n> **A stub outside-diff finding.**"}]' ;;
                body-nitpick) echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"Nitpick comments (1)"}]' ;;
                body-drift)   echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"Outside diff range comments were noted but the count did not survive a format change"}]' ;;
                # HIMMEL-3124: a REAL captured review body (fixture file), one substantive
                # bot review at the head — the per-finding outside-diff reader parses it.
                body-file)    jq -n --rawfile b "$GH_STUB_BODY_FILE" '[{user:{id:136622811,login:"coderabbitai[bot]"},commit_id:"sha1",submitted_at:"2026-07-16T19:10:00Z",id:1,body:$b}]' ;;
                # HIMMEL-3360: a REAL captured review body at a PRIOR head
                # (shaOLD, not the certified sha1) — the governing-prior-head
                # gate reads this via cr_body_outside_findings called with
                # head=shaOLD.
                body-a2-file) jq -n --rawfile b "$GH_STUB_BODY_FILE" '[{user:{id:136622811,login:"coderabbitai[bot]"},commit_id:"shaOLD",submitted_at:"2026-07-16T19:10:00Z",id:1,body:$b}]' ;;
                # HIMMEL-3365: TWO prior heads, each carrying its own REAL captured
                # review body — shaOLD (older, GH_STUB_BODY_FILE) and shaOLD2
                # (newer, GH_STUB_BODY_FILE2); nothing at the certified sha1.
                body-a3-file) jq -n --rawfile b "$GH_STUB_BODY_FILE" --rawfile c "$GH_STUB_BODY_FILE2" '[{user:{id:136622811,login:"coderabbitai[bot]"},commit_id:"shaOLD",submitted_at:"2026-07-16T19:10:00Z",id:1,body:$b},{user:{id:136622811,login:"coderabbitai[bot]"},commit_id:"shaOLD2",submitted_at:"2026-07-16T19:20:00Z",id:2,body:$c}]' ;;
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
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"},{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"> **⚠️ Outside diff range comments (1)**\n> \n> `stub.sh:5`\n> _x_ | _🟡 Minor_ | _y_\n> \n> **A stub outside-diff finding.**"}]'
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
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":"> **⚠️ Outside diff range comments (1)**\n> \n> `stub.sh:5`\n> _x_ | _🟡 Minor_ | _y_\n> \n> **A stub outside-diff finding.**"}]'
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
                # HIMMEL-3123: a bot object AT the head that is a thread REPLY —
                # body empty, one inline comment. It survives the shell filter
                # (comments > 0) but delivers no verdict at the head.
                threadsonly) echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"sha1"},"state":"COMMENTED","body":"","comments":{"totalCount":1}}]}}}}}' ;;
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
        *"baseRefName"*) echo "main"; exit 0 ;;
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
                # HIMMEL-3381: the required gate's own row read ("<bucket><TAB><name>").
                # GH_STUB_CHECKS is a newline list of "<bucket>:<name>".
                case " $* " in
                    *'\(.bucket)\t\(.name)'*)
                        # late:<n>     first read lacks <n>, later reads carry it green
                        # flipfail:<n> first read has <n> pending, later reads carry it failed
                        # pendlate:<n> first read: another check pending and <n> absent (a job
                        #              held by needs:), later reads: all green incl. <n>
                        # pendstuck:<n> another check pending and <n> absent on every read
                        rq=$(cat "$(dirname "$0")/reqrows-count" 2>/dev/null); rq=${rq:-0}
                        echo $((rq+1)) > "$(dirname "$0")/reqrows-count"
                        case "${GH_STUB_CHECKS:-pass:unit-tests}" in
                            late:*) printf 'pass\tunit-tests\n'; [ "$rq" -eq 0 ] || printf 'pass\t%s\n' "${GH_STUB_CHECKS#late:}" ;;
                            pendlate:*) printf 'pass\tunit-tests\n'; if [ "$rq" -eq 0 ]; then printf 'pending\tshard-1\n'; else printf 'pass\tshard-1\npass\t%s\n' "${GH_STUB_CHECKS#pendlate:}"; fi ;;
                            pendstuck:*) printf 'pass\tunit-tests\npending\tshard-1\n' ;;
                            flipfail:*) if [ "$rq" -eq 0 ]; then printf 'pending\t%s\n' "${GH_STUB_CHECKS#flipfail:}"; else printf 'fail\t%s\n' "${GH_STUB_CHECKS#flipfail:}"; fi ;;
                            *) printf '%s\n' "${GH_STUB_CHECKS:-pass:unit-tests}" | while IFS=: read -r b n; do printf '%s\t%s\n' "$b" "$n"; done ;;
                        esac
                        exit 0 ;;
                esac
                # HIMMEL-2907: _pending_checks_report's --jq is a DIFFERENT
                # shape over these SAME --json bucket,name fields —
                # "<count>\n<names>", no CHECKCI_OK sentinel — distinguished
                # here by its unique "length" substring (nested inside the
                # bucket,name match so the plain fail-bucket-count probe,
                # which also says "length" but never "bucket,name", is
                # untouched) so the WAITING/cannot-evaluate naming cases get
                # real pending-check data instead of watch_decidable's shape.
                case " $* " in
                    *"length"*)
                        case "$GH_STUB_MODE" in
                            blocking-cr-decidable) printf '1\nCodeRabbit\n' ;;
                            blocking-cr-substring) printf '1\ncoderabbit-extra\n' ;;
                            *) printf '1\nunit-tests\n' ;;
                        esac
                        exit 0 ;;
                esac
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
            blocking-cr-decidable|blocking-cap-pending|blocking-cr-substring|blocking-cap-extend) echo 0 ;;
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
    body-outside|body-file|body-a2-file|body-a3-file|body-nitpick|body-drift|body-error|body-a2|body-empty|body-a2-escalate|body-a2-marker|body-a2-timeout|body-a2-escalate-outside|body-b2-escalate|body-b2-escalate-outside|body-b2-timeout|body-b2-head-review|body-a2-escalate-empty|body-a2-empty-persisted|body-a2-postfail)
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
    blocking-cap-extend)
        # HIMMEL-2907: round 1 runs past the cap exactly like blocking-cap-
        # pending (a healthy shard still mid-run); round 2 — check-ci.sh's
        # one-time extension — resolves green immediately, the same shape a
        # real slow-but-healthy shard finishing during the extra --max-wait
        # window would produce.
        if [ "$is_watch" -eq 1 ]; then
            w=$(cat "$GH_STUB_WATCH" 2>/dev/null); w=${w:-0}
            echo $((w+1)) > "$GH_STUB_WATCH"
            if [ "$w" -eq 0 ]; then sleep 3; fi
            echo "All checks were successful"; exit 0
        fi
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

# HIMMEL-3381: the merge-block alert sender (MERGE_BLOCK_ALERT_CMD). Records
# "<chat_id> <text>" per call; ALERT_FAIL=1 in its env makes it fail like a dead
# bridge. The operator id comes from a fixture access.json — the FIRST POSITIVE
# allowFrom entry, so the negative group id ahead of it must be skipped.
cat > "$STUBDIR/alert-sender" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$(dirname "$0")/alerts.log"
[ -z "${GH_STUB_ALERT_FAIL:-}" ]
EOF
chmod +x "$STUBDIR/alert-sender" || { echo "FATAL: chmod on alert-sender stub failed"; exit 1; }
printf '{"allowFrom":["-100777","555"],"dmPolicy":"allowlist"}\n' > "$STUBDIR/access.json"
alert_count() { wc -l < "$STUBDIR/alerts.log" | tr -d ' '; }

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
BODY_FILE_OVERRIDE=""
BODY_FILE2_OVERRIDE=""
# HIMMEL-3381: drive the required-check stubs. Defaults = no rule, one green check.
RULES_OVERRIDE=none
CLASSIC_OVERRIDE=none
PRODUCERS_OVERRIDE=none
CHECKS_OVERRIDE="pass:unit-tests"
KEEP_ALERT_STATE=0
ALERT_FAIL_OVERRIDE=""
ACCESS_OVERRIDE="$STUBDIR/access.json"

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
    : > "$STUBDIR/reqrows-count"
    # HIMMEL-3381: alert state resets per run unless a case sets KEEP_ALERT_STATE=1
    # (the dedupe case runs the SAME head twice and must see ONE alert).
    if [ "$KEEP_ALERT_STATE" -ne 1 ]; then : > "$STUBDIR/alerts.log"; rm -rf "$STUBDIR/alert-sentinels"; fi
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
        GH_STUB_BODY_FILE="$BODY_FILE_OVERRIDE" \
        GH_STUB_BODY_FILE2="$BODY_FILE2_OVERRIDE" \
        GH_STUB_RULES="$RULES_OVERRIDE" \
        GH_STUB_CLASSIC="$CLASSIC_OVERRIDE" \
        GH_STUB_PRODUCERS="$PRODUCERS_OVERRIDE" \
        GH_STUB_CHECKS="$CHECKS_OVERRIDE" \
        MERGE_BLOCK_ALERT_DIR="$STUBDIR/alert-sentinels" \
        MERGE_BLOCK_ALERT_CMD="$STUBDIR/alert-sender" \
        TELEGRAM_ACCESS_PATH="$ACCESS_OVERRIDE" \
        GH_STUB_ALERT_FAIL="$ALERT_FAIL_OVERRIDE" \
        CHECK_CI_POLL_INTERVAL="$POLL_OVERRIDE" \
        CHECK_CI_SETTLE="$SETTLE_OVERRIDE" \
        CR_ESCALATE_WAIT="$ESCALATE_WAIT_OVERRIDE" \
        CR_ESCALATE_POLL="$ESCALATE_POLL_OVERRIDE" \
        CR_PROFILE="$CR_PROFILE_OVERRIDE" \
        CR_APP="$CR_APP_OVERRIDE" \
        CR_BOT_LOGINS="$CR_BOT_LOGINS_OVERRIDE" \
        CHECK_CI_SLEEP_CMD="$SLEEP_CMD_OVERRIDE" \
        CHECK_CI_PROBE_INTERVAL=1 \
        GH_BUDGET_PREFLIGHT=0 \
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
    FRESHNESS_OVERRIDE=fresh; FILES_OVERRIDE=README.md; CR_BOT_LOGINS_OVERRIDE=""; MPR_OVERRIDE=none; BODY_FILE_OVERRIDE=""; BODY_FILE2_OVERRIDE=""
    RULES_OVERRIDE=none; CLASSIC_OVERRIDE=none; PRODUCERS_OVERRIDE=none; CHECKS_OVERRIDE="pass:unit-tests"
    KEEP_ALERT_STATE=0; ALERT_FAIL_OVERRIDE=""; ACCESS_OVERRIDE="$STUBDIR/access.json"
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
# Negative assertion (HIMMEL-3376): grep must find NOTHING. rc 1 (absent) passes,
# rc 0 (present) fails with DETAIL, rc >=2 (grep itself errored: bad pattern,
# unreadable file) FAILS — the `if grep …; then fail; else pass; fi` idiom read
# that error as absence. Reads stdin unless GREP_ARGS carries a file operand;
# feed a variable by here-string, NOT a pipe (a pipe runs this in a subshell and
# drops the pass/fail counters).
assert_grep_lacks() {
    local name=$1 detail=$2 grc=0
    shift 2
    grep "$@" >/dev/null || grc=$?
    case $grc in
        1) pass "$name" ;;
        0) fail "$name" "$detail" ;;
        *) fail "$name" "grep errored (rc=$grc): grep $*" ;;
    esac
}
assert_err_lacks() { local name=$1 detail=$2; shift 2; assert_grep_lacks "$name" "$detail" "$@" <<<"$ERR"; }
# Self-test of the helper, with pass/fail captured in a subshell so the suite's
# counters do not move: absent -> PASS, present -> FAIL, forced grep error -> FAIL.
selftest_lacks() { ( pass() { echo PASS; }; fail() { echo FAIL; }; assert_grep_lacks n d "$@" <<<"needle" ) 2>/dev/null; }
if [ "$(selftest_lacks -F -- absent)" = PASS ]; then pass "3376 assert_grep_lacks: absent pattern passes"; else fail "3376 assert_grep_lacks: absent pattern passes"; fi
if [ "$(selftest_lacks -F -- needle)" = FAIL ]; then pass "3376 assert_grep_lacks: present pattern fails"; else fail "3376 assert_grep_lacks: present pattern fails"; fi
if [ "$(selftest_lacks -E '[')" = FAIL ]; then pass "3376 assert_grep_lacks: a grep error (rc 2) fails, not passes"; else fail "3376 assert_grep_lacks: a grep error (rc 2) fails, not passes"; fi
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
    assert_grep_lacks "$1" "verdict line leaked into a pre-trap exit" -F "verdict exit=" <<<"$OUT$ERR"
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
assert_verdict 2 "4 a genuine cannot-evaluate still exits 2 WITH its verdict (HIMMEL-3317 false-positive control)"

# 5 — unknown option: a usage error is rc 64 (EX_USAGE), NOT 2, and it carries the
# un-maskable verdict line too — no gate ran, so a caller must be able to tell (HIMMEL-3317)
run red --bogus
assert_rc 64 "5 unknown option rc 64"
assert_err_has "usage" "5 usage on stderr"
assert_verdict 64 "5 verdict line on usage errors (HIMMEL-3317)"

# 5c — `--pr <n>`: the plausible-but-wrong spelling (the PR number is POSITIONAL) that
# recorded a gate result for a gate that never ran. Distinct code AND a marker line.
run red --pr 1003
assert_rc 64 "5c --pr <n> rc 64, distinct from cannot-evaluate (2)"
assert_err_has "unknown option: --pr" "5c names the rejected flag"
assert_verdict 64 "5c --pr <n> prints its verdict line"

# 5d — a value-taking flag with no value is a usage error too (--grace / --settle)
run red --grace
assert_rc 64 "5d --grace with no value rc 64"
assert_verdict 64 "5d verdict line on a missing --grace value"
run red --settle
assert_rc 64 "5d --settle with no value rc 64"
assert_verdict 64 "5d verdict line on a missing --settle value"

# 5b — --help exits 0 pre-trap: usage only, NO verdict line
run red --help
assert_rc 0 "5b --help rc 0"
assert_err_has "usage" "5b usage on stderr"
assert_no_verdict "5b no verdict line on --help"

# 6 — non-numeric grace
run red --grace soon
assert_rc 64 "6 non-numeric grace rc 64"
assert_err_has "non-negative integer" "6 grace validation message"
assert_verdict 64 "6 verdict line on a bad flag value"

# 7 — two selectors
run red 12 34
assert_rc 64 "7 two selectors rc 64"
assert_err_has "only one PR selector" "7 selector message"
assert_verdict 64 "7 verdict line on two selectors"

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
assert_rc 64 "14 non-numeric settle rc 64"
assert_err_has "--settle must be a non-negative integer" "14 settle validation message"

# 15 — --threads-only: thread gate runs, checks watch does not
THREADS_OVERRIDE=2
run red --threads-only
assert_rc 3 "15 threads-only unresolved rc 3"
assert_err_has "2 unresolved review thread(s)" "15 threads-only unresolved message"
assert_grep_lacks "15 threads-only skips gh pr checks" "args.log: $(cat "$STUBDIR/args.log")" -- 'checks' "$STUBDIR/args.log"

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

# --- HIMMEL-3360: CodeRabbit is best effort — its own commit STATUS is
# advisory only, never a block. The old cases 27-30 here pinned exit 2/1 on
# absent/pending/failure/spoofed; they now pin the advisory NOTE + exit 0
# instead. (The HIMMEL-980 "zombie check-run override" this section used to
# also cover keyed off a CodeRabbit CHECK-RUN — which CodeRabbit has never
# posted [it posts a commit STATUS] — and was already unreachable; gone.)

# 27 — the regression that merged #1243 used to require an absent status to
# block. HIMMEL-3360 reversed that: checks green, threads clean, CodeRabbit
# never posted on this head — advisory NOTE, still green.
run cr-absent
assert_rc 0 "27 absent CodeRabbit status is advisory only, not a block (HIMMEL-3360)"
assert_err_has "check-ci: NOTE — CodeRabbit absent on head" "27 absent prints the advisory NOTE"

# 28 — CodeRabbit still reviewing the head: advisory NOTE, never a block.
run cr-pending
assert_rc 0 "28 pending CodeRabbit status is advisory only, not a block (HIMMEL-3360)"
assert_err_has "check-ci: NOTE — CodeRabbit pending on head" "28 pending prints the advisory NOTE"

# 29 — CodeRabbit's own status failed/errored: advisory NOTE, never a block.
run cr-failure
assert_rc 0 "29 failed CodeRabbit status is advisory only, not a block (HIMMEL-3360)"
assert_err_has "check-ci: NOTE — CodeRabbit failure on head" "29 failure prints the advisory NOTE"

# 30 — identity, not display name (HIMMEL-1058): a success status carrying the
# CodeRabbit context but a foreign creator.id does not satisfy the identity
# check, so cr_signal_state reads it as absent — advisory NOTE, not a block.
run cr-spoofed
assert_rc 0 "30 spoofed creator.id reads as absent, which is advisory only (HIMMEL-3360)"

# 31 — a repo with no CodeRabbit opts out explicitly rather than being blocked
# forever: CR_PROFILE=none skips the required-signal gate.
CR_PROFILE_OVERRIDE=none
run cr-absent
assert_rc 0 "31 CR_PROFILE=none allows an absent CodeRabbit"

# 32 — HIMMEL-3360: the status query itself failing is the same advisory NOTE
# as an absent status (state=unreadable), never a block — an unreadable
# advisory signal cannot be a gate outcome. Threads + body findings still gate.
run cr-query-error
assert_rc 0 "32 CodeRabbit status query error is a NOTE, rc 0"
assert_err_has "NOTE — CodeRabbit unreadable" "32 unreadable-status NOTE"

# 34 — coderabbit-2 / HIMMEL-3360: a FULL page of unrelated statuses with no
# CodeRabbit among them ("paged") is indeterminate, and indeterminate is
# advisory too — a NOTE, rc 0. (Numbered 34: a "33" already exists further down.)
run cr-paged
assert_rc 0 "34 full status page without CodeRabbit is a NOTE, rc 0"
assert_err_has "NOTE — CodeRabbit paged" "34 paged NOTE"

# 34b/34c — HIMMEL-1317: a SKIPPED review (state=success, refusal only in
# .description — automatic reviews disabled) used to fail CLOSED; HIMMEL-3360
# made every CodeRabbit-status shape advisory. cr_signal_state's own
# classification (scripts/lib/cr-signal.sh) still projects this payload to
# state=skipped — cr_signal_gate no longer branches on it, it just prints the
# advisory NOTE. 34b proves the skip stays green with the NOTE, 34c proves an
# ordinary review still passes too, so the fix cannot be satisfied by breaking
# `success`.
run cr-skipped
assert_rc 0 "34b skipped CodeRabbit review is advisory only, not a block (HIMMEL-3360)"
assert_err_has "check-ci: NOTE — CodeRabbit skipped on head" "34b skip prints the advisory NOTE"

run cr-completed
assert_rc 0 "34c a genuinely completed review still certifies"

# 34d — glm-1: the skip match must be UNAMBIGUOUS. A completed review worded
# "No review changes requested" contains skip-ish words; the first cut of the
# regex matched it and would have blocked a clean merge. The two error
# directions are not symmetric — a false negative restores the old behaviour,
# a false positive is an outage nobody can clear by re-running.
run cr-nearmiss
assert_rc 0 "34d skip-ish wording on a COMPLETED review does not block"

# 34e/34f — HIMMEL-1354, the SECOND drift of the 34b class, now retired by
# HIMMEL-3360: a rate-limited decline (34e) and a wholly UNENUMERATED success
# wording (34f) both project to the same state=skipped as 34b (cr-signal.sh's
# classification is unchanged; only cr_signal_gate's reaction to it is), so
# both now print the identical advisory NOTE and stay green — enumerated or
# not, CodeRabbit's status never blocks. Pin the DEFAULT allow/deny lists: an
# ambient CR_OK_DESC_RE / CR_SKIP_DESC_RE in the operator's shell must not
# leak into cr-signal.sh's classification of $state.
unset CR_OK_DESC_RE CR_SKIP_DESC_RE

# Exact-head ledger fixtures — still consumed by the HIMMEL-3124 outside-diff
# disposition cases below. The panel-carry mechanism that used to consume
# them here (rate-limited/absent/skip signal carry) was removed by
# HIMMEL-3360: CodeRabbit's status is advisory on its own now, with no panel
# evidence needed to carry it.
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
# HIMMEL-2769: a repo that DECLARES it expects CodeRabbit (a committed
# .coderabbit.yaml) but whose marker was never armed on this clone — the
# CR-UNARMED cases below. No marker at all, distinct from BROKEN_MARKER_REPO.
CR_YAML_UNARMED_REPO=$(mktemp -d "$STUBDIR/cr-yaml-unarmed.XXXXXX") || { echo "FATAL: mktemp -d failed"; exit 1; }
git -C "$CR_YAML_UNARMED_REPO" init --quiet
printf 'reviews:\n  profile: chill\n' > "$CR_YAML_UNARMED_REPO/.coderabbit.yaml"
git -C "$CR_YAML_UNARMED_REPO" add .coderabbit.yaml
git -C "$CR_YAML_UNARMED_REPO" -c user.email=t@t -c user.name=t commit --quiet --no-verify -m seed

# 34e — HIMMEL-3360 required case (b): CI green + 0 threads + CR rate-limited,
# no ledger/panel evidence at all — the exact fixture the old panel-carry
# mechanism needed evidence to certify. It is advisory on its own now.
run_in_repo "$EMPTY_LEDGER_REPO" cr-ratelimited
assert_rc 0 "34e rate-limited CodeRabbit status is advisory only, no panel evidence needed (HIMMEL-3360)"
assert_err_has "check-ci: NOTE — CodeRabbit skipped on head" "34e rate-limited (state=skipped) prints the advisory NOTE"

# 34f — the structural half: a wording NOBODY enumerated. Under the retired
# allow-list this failed closed; HIMMEL-3360 made the status advisory
# regardless of wording, enumerated or not.
run cr-unknownword
assert_rc 0 "34f an UNENUMERATED success wording is advisory only, not a block (HIMMEL-3360)"

# 3152-a/b/c/d (--escalate against a skip-classified/rate-limited status) and
# 34g/34h/34i (the CR_OK_DESC_RE allow-list, its anchoring, and the adversarial
# substring-match follow-ups) are gone: --escalate no longer exists
# (scripts/check-ci.sh brief item 1) and cr_signal_gate no longer reads
# CR_OK_DESC_RE/CR_SKIP_DESC_RE or calls cr_signal_description at all — every
# one of those cases exercised machinery HIMMEL-3360 removed.

# HIMMEL-3360 required case (e): the removed --escalate flag is now an
# unrecognized flag, sysexits EX_USAGE.
run cr-completed --escalate
assert_rc 64 "3360e --escalate is a removed flag, exit 64 usage (HIMMEL-3360)"

# HIMMEL-3360 required case (d): CI green + ONE unresolved coderabbitai
# thread + CR status absent — the thread gate still blocks even though the
# CodeRabbit status gate is advisory-only; the two gates are independent.
# The unconditional review_state_gate call at the top of the script (before
# the watch, before cr_signal_gate ever runs) is what catches this constant
# thread count, so cr_signal_gate's advisory NOTE never gets a chance to
# print here — only a LATE-arriving thread (case 33) reaches it after.
THREADS_OVERRIDE=1
run cr-absent
assert_rc 3 "3360d an unresolved thread still blocks with CR status absent"
assert_err_has "unresolved review thread" "3360d thread-gate reason printed"

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
FIXD="$SCRIPT_DIR/lib/fixtures/cr-body"
BODY_FILE_OVERRIDE="$FIXD/pr-777-outside-diff-blockquote.body.txt"
run_in_repo "$EMPTY_LEDGER_REPO" body-file
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

# --- HIMMEL-3124: outside-diff findings have an adjudicated-deferral path --------
# An outside-diff finding carries no thread, so it used to have NO disposition
# path: exit 3 until a commit moved the head — which discards CodeRabbit's
# review (HIMMEL-1252) and burns an account-wide review slot. A finding is now
# cleared by ONE ledger row at THIS head (recorded through ledger-append.sh's
# existing `finding` interface): verdict deferred with a tracked ticket AND a
# non-empty reason, or verdict disproved with a reason. Every negative below is
# a ONE-FIELD variant of the passing R1 row (a blanket failure would otherwise
# make every negative pass vacuously); the id is cr-od-<12 hex of sha256(file
# US line US title)>, computed independently in the reader suite.
OD_ROW='{"kind":"finding","ts":"2026-09-19T00:00:00Z","branch":"feat/x","head":"sha1","model":"coderabbit-outside","finding_id":"cr-od-39c3193c8945","severity":"sug","file":".pre-commit-config.yaml","line":459,"verdict":"deferred","artifact":"diff","perspective":"off","deferred_to":"HIMMEL-9001","reason":"tracked separately"}'
mk_od_repo() { # mk_od_repo <row-json>... -> prints the repo dir
    local d
    d=$(mktemp -d "$STUBDIR/od-ledger.XXXXXX") || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
    git -C "$d" init --quiet
    git -C "$d" -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet --no-verify
    # ONE `>` write (the ledger has a single append-site owner; /pr-check
    # invariant 7 flags any other `>>`): every row is a call argument.
    printf '%s\n' "$@" > "$d/.git/cr-critic-scores.jsonl"
    printf '%s' "$d"
}
od_variant() { printf '%s' "$OD_ROW" | jq -c "$1"; }
OD_BQ_BODY="$FIXD/pr-777-outside-diff-blockquote.body.txt"

# R2 — no row at all: still exit 3, and the message LISTS the finding and prints
# the exact recipe (id, file:line, title, ledger-append command).
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$EMPTY_LEDGER_REPO" body-file
assert_rc 3 "R2 undispositioned outside-diff finding stays exit 3"
assert_err_has "cr-od-39c3193c8945" "R2 message lists the finding id"
assert_err_has ".pre-commit-config.yaml:459" "R2 message lists file:line"
assert_err_has "Keep \`context7-mcp\` in the description-cap gate." "R2 message lists the title"
assert_err_has "ledger-append.sh finding" "R2 message prints the recording recipe"
assert_err_has "--model coderabbit-outside" "R2 recipe names the model tag"
assert_err_has "--head sha1" "R2 recipe binds the finding to THIS head"
assert_verdict 3 "R2 verdict line exit 3"

# R1 — the passing row (deferred + tracked ticket + reason at THIS head) clears it.
OD_REPO=$(mk_od_repo "$OD_ROW")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$OD_REPO" body-file
assert_rc 0 "R1 dispositioned outside-diff finding allows"
assert_out_has "outside-diff dispositioned=1 (crit=0 imp=0 sug=1)" "R1 success line keeps the severity counts visible"
assert_verdict 0 "R1 verdict line exit 0"
# disproved with a reason clears it too
OD_REPO=$(mk_od_repo "$(od_variant '.verdict="disproved" | del(.deferred_to)')")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$OD_REPO" body-file
assert_rc 0 "R1b disproved-with-reason clears the finding"

# R3..R8 — each is R1's row with exactly ONE field changed.
for v in \
    'R3 different-line|.line=460' \
    'R4 different-file|.file="other/file.yaml"' \
    'R5 different-head|.head="sha2"' \
    'R6 empty-reason|.reason=""' \
    'R6b whitespace-reason|.reason="   "' \
    'R7 deferred-without-ticket|del(.deferred_to)' \
    'R7b deferred-bad-ticket|.deferred_to="not-a-ticket"' \
    'R8 verdict-fixed|.verdict="fixed"' \
    'R8b verdict-agreed|.verdict="agreed"' \
    'R8c different-id|.finding_id="cr-od-000000000000"'; do
    OD_NAME=${v%%|*}; OD_FILTER=${v#*|}
    OD_REPO=$(mk_od_repo "$(od_variant "$OD_FILTER")")
    BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$OD_REPO" body-file
    assert_rc 3 "$OD_NAME does not clear the finding (exit 3)"
done

# R9 — two findings, only one dispositioned: still exit 3, and the message names
# ONLY the other one.
OD_LEGACY_BODY="$FIXD/pr-1261-outside-diff-2.body.txt"
OD_REPO=$(mk_od_repo "$(od_variant '.finding_id="cr-od-eeba561a5fa4" | .file="scripts/codex/sanitize-plugin-hooks.ps1" | .line="7-20"')")
BODY_FILE_OVERRIDE="$OD_LEGACY_BODY"; run_in_repo "$OD_REPO" body-file
assert_rc 3 "R9 one of two findings dispositioned stays exit 3"
assert_err_has "cr-od-588006168ade" "R9 message names the undispositioned finding"
assert_err_lacks "R9 message lists only the undispositioned finding" "R9 message must not list the dispositioned finding: listed" -F "cr-od-eeba561a5fa4"
OD_REPO=$(mk_od_repo \
    "$(od_variant '.finding_id="cr-od-eeba561a5fa4" | .file="scripts/codex/sanitize-plugin-hooks.ps1" | .line="7-20"')" \
    "$(od_variant '.finding_id="cr-od-588006168ade" | .file="scripts/codex/sanitize-plugin-hooks.sh" | .line="4-20"')")
BODY_FILE_OVERRIDE="$OD_LEGACY_BODY"; run_in_repo "$OD_REPO" body-file
assert_rc 0 "R9b both findings dispositioned allows"
assert_out_has "outside-diff dispositioned=2 (crit=0 imp=0 sug=2)" "R9b success line counts both"

# Range line (#777): the LINE is the literal token 80-91, compared as a string;
# the header is the "Outside the diff (N)" variant, counted now (it used to read
# outside=0 and trip the markers canary by accident).
OD_RANGE_BODY="$FIXD/pr-777-outside-the-diff-range.body.txt"
BODY_FILE_OVERRIDE="$OD_RANGE_BODY"; run_in_repo "$EMPTY_LEDGER_REPO" body-file
assert_rc 3 "R13 Outside-the-diff header is counted and blocks (exit 3, not the drift exit 2)"
assert_err_has "marketplace/plugins/himmel-ops/README.md:80-91" "R13 message shows the range line"
OD_REPO=$(mk_od_repo "$(od_variant '.finding_id="cr-od-2b1a31ba0692" | .severity="imp" | .file="marketplace/plugins/himmel-ops/README.md" | .line="80-91"')")
BODY_FILE_OVERRIDE="$OD_RANGE_BODY"; run_in_repo "$OD_REPO" body-file
assert_rc 0 "R13b range-line disposition clears (string match)"
assert_out_has "(crit=0 imp=1 sug=0)" "R13b Major finding counted as imp on the success line"
OD_REPO=$(mk_od_repo "$(od_variant '.finding_id="cr-od-2b1a31ba0692" | .file="marketplace/plugins/himmel-ops/README.md" | .line=80')")
BODY_FILE_OVERRIDE="$OD_RANGE_BODY"; run_in_repo "$OD_REPO" body-file
assert_rc 3 "R13c a disposition at the range START alone does not clear the range"

# Full path, not the summary basename (#888 layout).
BODY_FILE_OVERRIDE="$FIXD/pr-888-outside-diff-basename.body.txt"
OD_REPO=$(mk_od_repo "$(od_variant '.finding_id="cr-od-8ed0fb1cf579" | .severity="imp" | .file="templates/luna-second-brain/scripts/upgrade.sh" | .line=427')")
run_in_repo "$OD_REPO" body-file
assert_rc 0 "R14 disposition keyed on the FULL path clears (not the basename)"
BODY_FILE_OVERRIDE="$FIXD/pr-888-outside-diff-basename.body.txt"
OD_REPO=$(mk_od_repo "$(od_variant '.finding_id="cr-od-8ed0fb1cf579" | .severity="imp" | .file="upgrade.sh" | .line=427')")
run_in_repo "$OD_REPO" body-file
assert_rc 3 "R14b a basename-keyed disposition does not clear"

# R10 — header count != extracted findings = format drift: exit 2 (cannot
# certify), NOT a recipe for findings that never parsed. The pre-existing
# count-only body ("Outside diff range comments (2)", no finding bodies) is
# exactly that shape.
printf '%s' 'Outside diff range comments (2)' > "$STUBDIR/od-hdronly.txt"
BODY_FILE_OVERRIDE="$STUBDIR/od-hdronly.txt"; run body-file
assert_rc 2 "R10 header count without parseable findings cannot certify"
assert_err_has "check the PR body manually" "R10 tells the operator to check manually"
assert_err_lacks "R10 no recipe for findings that did not parse" "R10 must not print a recipe: recipe printed" -F "ledger-append.sh"
sed 's/Outside diff range comments (1)/Outside diff range comments (2)/' "$OD_BQ_BODY" > "$STUBDIR/od-count2.txt"
OD_REPO=$(mk_od_repo "$OD_ROW")
BODY_FILE_OVERRIDE="$STUBDIR/od-count2.txt"; run_in_repo "$OD_REPO" body-file
assert_rc 2 "R10b real body with header (2) but one finding cannot certify, even with a row"

# R17 — the printed recipe is PASTE-READY: the path and the title come from a
# bot review body (untrusted) and may hold an apostrophe, which would close the
# single quotes around --file / --text and hand the rest to the shell. Both must
# be emitted with the standard '\'' escape.
sed -e "s/\.pre-commit-config\.yaml:459/x'y.yaml:459/g" -e "s/Keep \`context7-mcp\` in the description-cap gate\./Don't keep \`context7-mcp\`./" "$OD_BQ_BODY" > "$STUBDIR/od-apos.txt"
BODY_FILE_OVERRIDE="$STUBDIR/od-apos.txt"; run_in_repo "$EMPTY_LEDGER_REPO" body-file
assert_rc 3 "R17 apostrophe path+title finding is still undispositioned exit 3"
assert_err_has "--file 'x'\\''y.yaml'" "R17 recipe escapes an apostrophe in the file path"
assert_err_has "--text 'Don'\\''t keep" "R17 recipe escapes an apostrophe in the title"

# Gate integrity: the ledger is read from the FIXED per-repo path. An ambient
# CR_LEDGER pointing at a forged ledger must not clear the finding.
FORGED_LEDGER="$STUBDIR/forged-ledger.jsonl"; printf '%s\n' "$OD_ROW" > "$FORGED_LEDGER"
export CR_LEDGER="$FORGED_LEDGER"
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$EMPTY_LEDGER_REPO" body-file
unset CR_LEDGER
assert_rc 3 "R15 an env-pointed forged ledger does not clear the finding"

# No silent inheritance: an amend --set head= must not re-key a cr-od row onto
# a later head. The row was written at sha0 and amended to sha1 (the head here).
OD_REPO=$(mk_od_repo \
    "$(od_variant '.head="sha0"')" \
    '{"kind":"amend","ts":"2026-09-19T00:00:01Z","target_head":"sha0","finding_id":"cr-od-39c3193c8945","artifact":"diff","perspective":"off","set":{"head":"sha1"},"reason":"re-key"}')
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$OD_REPO" body-file
assert_rc 3 "R16 amend --set head= does not carry a disposition to the new head"

# 39 — operator ruling (2026-09-21): best effort covers ABSENCE only. CodeRabbit
# concluded on sha1 but emitted no review object there, while a PRIOR head
# (shaOLD) carries a real outside-diff finding CodeRabbit DID post. That
# finding still blocks until dispositioned — the gate now reads the governing
# prior review (shaOLD) instead of the silent current head.
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$EMPTY_LEDGER_REPO" body-a2-file
assert_rc 3 "39 a posted prior-head outside-diff finding still blocks (HIMMEL-3360 operator ruling)"
assert_err_has "not dispositioned" "39 message reports the finding as not dispositioned"
assert_err_has "latest review at prior head shaOLD" "39 message names the governing prior head"
assert_err_has "--head shaOLD" "39 recipe binds the finding to the governing prior head"
assert_err_has "cr-od-39c3193c8945" "39 message lists the finding id"

# 39a — the prior body is unparseable (header count present, no per-finding
# items) — format drift, cannot certify, same as any other cannot-count shape.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2
assert_rc 2 "39a unparseable prior body cannot certify (format drift)"
assert_err_has "format drift" "39a message names format drift"

# 39b — the SAME prior-head finding, but with a ledger disposition recorded at
# the governing prior head (shaOLD, not sha1): allows, and the NOTE explains
# why the current head carries no review of its own.
OD_REPO=$(mk_od_repo "$(od_variant '.head="shaOLD"')")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$OD_REPO" body-a2-file
assert_rc 0 "39b a disposition at the governing prior head allows"
assert_verdict 0 "39b un-maskable exit 0 verdict line"
assert_err_has "NOTE — CodeRabbit posted no review at head sha1" "39b NOTE explains the absent current-head review"
assert_err_has "all dispositioned" "39b NOTE confirms the prior review is fully dispositioned"

# 39b2 — a `fixed` row whose sha cannot be verified against this head (stub
# head sha1 is not a commit) stays blocked; the positive fixed-disposition
# path (a reason sha that resolves and is an ancestor of the current head) is
# covered in scripts/lib/test-cr-ledger-evidence.sh, not here.
OD_REPO=$(mk_od_repo "$(od_variant '.head="shaOLD" | .verdict="fixed" | .reason="fixed in deadbeef1234"')")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$OD_REPO" body-a2-file
assert_rc 3 "39b2 a fixed row whose sha cannot be verified against this head stays blocked"

# 39b3 — the disposition sits at the WRONG head (sha1, the certified head that
# carries no review) instead of the governing prior head (shaOLD): still blocks.
OD_REPO=$(mk_od_repo "$(od_variant '.head="sha1"')")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$OD_REPO" body-a2-file
assert_rc 3 "39b3 a disposition at the wrong head does not clear the finding"

# 39d — an unrelated ledger (LEDGER_REPO carries only an avail row, no finding
# for this id) does not disposition the finding either.
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; run_in_repo "$LEDGER_REPO" body-a2-file
assert_rc 3 "39d unrelated ledger rows do not disposition the finding"

# 39e..39h — HIMMEL-3365: TWO prior heads carry outside-diff findings (shaOLD
# older, shaOLD2 newer; sha1 has no review). Every prior head governs, each
# finding dispositioned at the head that raised it — the newer prior review
# never masks the older one's findings.
OD_A3_ROW_OLD=$(od_variant '.head="shaOLD"')
OD_A3_ROW_NEW=$(od_variant '.finding_id="cr-od-2b1a31ba0692" | .severity="imp" | .file="marketplace/plugins/himmel-ops/README.md" | .line="80-91" | .head="shaOLD2"')
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; BODY_FILE2_OVERRIDE="$OD_RANGE_BODY"
run_in_repo "$EMPTY_LEDGER_REPO" body-a3-file
assert_rc 3 "39e two prior heads, nothing dispositioned, blocks"
assert_err_has "cr-od-39c3193c8945" "39e message lists the older head's finding"
assert_err_has "cr-od-2b1a31ba0692" "39e message lists the newer head's finding"
assert_err_has "--head shaOLD --branch" "39e recipe binds the older finding to shaOLD"
assert_err_has "--head shaOLD2 --branch" "39e recipe binds the newer finding to shaOLD2"

OD_REPO=$(mk_od_repo "$OD_A3_ROW_NEW")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; BODY_FILE2_OVERRIDE="$OD_RANGE_BODY"; run_in_repo "$OD_REPO" body-a3-file
assert_rc 3 "39f only the newer prior head dispositioned: the older head's finding still blocks"
assert_err_has "cr-od-39c3193c8945" "39f message names the older head's undispositioned finding"
assert_err_lacks "39f message lists only the undispositioned finding" "39f message must not list the dispositioned newer finding: listed" -F "cr-od-2b1a31ba0692"

OD_REPO=$(mk_od_repo "$OD_A3_ROW_OLD")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; BODY_FILE2_OVERRIDE="$OD_RANGE_BODY"; run_in_repo "$OD_REPO" body-a3-file
assert_rc 3 "39g only the older prior head dispositioned: the newer head's finding still blocks"
assert_err_has "cr-od-2b1a31ba0692" "39g message names the newer head's undispositioned finding"

OD_REPO=$(mk_od_repo "$OD_A3_ROW_OLD" "$OD_A3_ROW_NEW")
BODY_FILE_OVERRIDE="$OD_BQ_BODY"; BODY_FILE2_OVERRIDE="$OD_RANGE_BODY"; run_in_repo "$OD_REPO" body-a3-file
assert_rc 0 "39h both prior heads dispositioned allows"
assert_verdict 0 "39h un-maskable exit 0 verdict line"
assert_err_has "all dispositioned" "39h NOTE confirms every prior head is dispositioned"
assert_err_has "shaOLD2" "39h NOTE names the newer prior head"
BODY_FILE_OVERRIDE=; BODY_FILE2_OVERRIDE=

# 39c — unresolved threads still block this same body shape; the thread gate
# is untouched by HIMMEL-3360 and stays orthogonal to CodeRabbit's status.
THREADS_OVERRIDE=2
run_in_repo "$LEDGER_REPO" body-a2
assert_rc 3 "39c unresolved threads still block despite an incremental-silent body"
assert_err_has "2 unresolved review thread(s)" "39c unresolved-thread reason is unchanged"
THREADS_OVERRIDE=

# 40 — --threads-only now ALSO runs the body gate (previously skipped head
# binding entirely, S1 was invisible here too): an outside-diff finding
# blocks this path exactly like the full run, and still never touches
# `gh pr checks`.
run body-outside --threads-only
assert_rc 3 "40 threads-only outside-diff body finding blocks"
assert_err_has "outside-diff-range finding" "40 threads-only outside-diff reason printed"
assert_grep_lacks "40 threads-only still skips gh pr checks" "args.log: $(cat "$STUBDIR/args.log")" -- 'checks' "$STUBDIR/args.log"

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
assert_grep_lacks "41 threads-only late-thread case still skips gh pr checks" "args.log: $(cat "$STUBDIR/args.log")" -- 'checks' "$STUBDIR/args.log"

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

# 87/88 (HIMMEL-1374/HIMMEL-1465) are gone: both exercised
# review_freshness_gate's `none` (zero-reviews-ever) discrimination, which
# HIMMEL-3360 removed along with the rest of the freshness gate — a
# "completed" status with zero PR-wide reviews is now advisory the same as
# every other shape, cannot-evaluate no longer applies.

# 89 — a "Review completed" status stays green regardless of PR-wide review
# history (the freshness discrimination 87/88 used to add is gone).
run cr-completed
assert_rc 0 "89 completed status with a PR-wide review present stays green"

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
assert_grep_lacks "57 disarmed gate is silent about CodeRabbit" "output mentioned CodeRabbit: $ERR" -i "coderabbit" <<<"$OUT$ERR"

# 58 — HIMMEL-1495 hermeticity canary. This certifier does not consult the
# armed-session bypass env (ARMAUTOMERGE/CR_MERGE_GATE_OK), so a block fixture
# STILL blocks (rc 2) with both exported into the suite's env — pinning that
# insensitivity so a future change wiring either var into check-ci.sh fails
# HERE (the block-case reads rc 0) rather than failing every block-case open.
# The startup unset above is the matching defense-in-depth.
# HIMMEL-3360: cr-absent no longer blocks (CodeRabbit status is advisory), so
# it can no longer serve as this canary's block-case; a thread-query failure
# (cannot-evaluate, rc 2) is orthogonal to CR status and still blocks.
export ARMAUTOMERGE=1 CR_MERGE_GATE_OK=1
THREADS_OVERRIDE=fail
run register-then-green
assert_rc 2 "58 armed bypass env does not open a block-case (HIMMEL-1495)"
unset ARMAUTOMERGE CR_MERGE_GATE_OK

# ── HIMMEL-2062: bounded watch — early exit + --max-wait cap ─────────────────

# 94 — --max-wait validation: non-integer
run red --max-wait soon
assert_rc 64 "94 non-numeric --max-wait rc 64"
assert_err_has "--max-wait must be a non-negative integer" "94 max-wait validation message"
assert_verdict 64 "94 verdict line on a bad --max-wait"

# 95 — --max-wait validation: no value
run red --max-wait
assert_rc 64 "95 --max-wait with no value rc 64"
assert_err_has "--max-wait needs a value" "95 max-wait needs-a-value message"
assert_verdict 64 "95 verdict line on a missing --max-wait value"

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
assert_err_lacks "102 does not fall through to the cap path" "stderr: $ERR" -iF -- "watch cap reached"

# 103 — same shape for the gh-error (cannot-evaluate) path: a near-instant
# auth/network failure must reach exit 2 via gh's REAL stderr, not get
# silently swallowed by the cap and re-evaluated structurally instead.
run watch-error --max-wait 5
assert_rc 2 "103 fast gh-error still resolves via the real-verdict path"
assert_err_has "cannot evaluate the gate" "103 real gh stderr reaches the caller"
assert_err_lacks "103 does not fall through to the cap path" "stderr: $ERR" -iF -- "watch cap reached"

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

# --- HIMMEL-2907: a cap reached with nothing failed extends ONCE for one more
# full --max-wait round before refusing — a slow-but-healthy shard (shell-unit
# shard 7, 12m16s-12m45s) must not read as "cannot evaluate" on the first cap.

# 2907-a — RED control: the pending shard finishes during the one-time
# extension (round 1 hits the cap with the check still running; round 2 —
# the extension — resolves green). Today this is rc 2; after the fix rc 0,
# with the WAITING notice naming the count and the still-pending job.
run blocking-cap-extend --max-wait 1
assert_rc 0 "2907-a a slow-but-healthy shard resolves after the one-time extension"
assert_err_has "WAITING 1 pending (unit-tests) — extending once (HIMMEL-2907)" "2907-a WAITING notice names the pending count and job"
assert_out_has "all checks green + all review threads resolved" "2907-a eventual green verdict"

# 2907-b — negative control: a check that stays pending PAST the extension
# (blocking-cap-pending, same stub cases 97/100/101 exercise) must still exit
# 2 — exactly ONE "WAITING" notice is emitted, proving the extension is not
# infinite — and the final cannot-evaluate line names the pending job.
run blocking-cap-pending --max-wait 1
assert_rc 2 "2907-b a check that never resolves still exits 2 after the one extension"
waiting_count=$(printf '%s' "$ERR" | grep -c "WAITING")
if [ "$waiting_count" -eq 1 ]; then
    pass "2907-b extends exactly once, not infinitely"
else
    fail "2907-b extends exactly once, not infinitely" "WAITING appeared $waiting_count times, want 1"
fi
assert_err_has "still pending (unit-tests)" "2907-b the exit-2 line names the pending job"

# 2907-c — negative control: a FAILED check alongside a pending one at cap
# must red_exit immediately (the failed-bucket probe is checked before the
# extend decision) — no WAITING notice, no extension.
run blocking-cap-red --max-wait 1
assert_rc 1 "2907-c a failed check at cap still exits 1 immediately"
assert_err_lacks "2907-c no WAITING notice on a genuinely red cap" "stderr: $ERR" -iF -- "WAITING"

# 2907-d — the default --max-wait is now 900s, covering the measured slowest
# shell-unit shard (12m16s-12m45s) with margin.
if grep -Fq 'CHECK_CI_MAX_WAIT:-900' "$SCRIPT"; then
    pass "2907-d default --max-wait raised to 900s"
else
    fail "2907-d default --max-wait raised to 900s" "MAX_WAIT default is not 900 in $SCRIPT"
fi

# --- HIMMEL-2278: the machine-generated-PR class ----------------------------
#
# Baseline for every case here: `cr-absent` — checks green, threads clean, and
# CodeRabbit posted NO status on the head. That used to be rc 2 for every PR
# except the two machine-generated shapes a `machine_pr_gate()` classifier
# carved out (bot-authored dependency bump, pure regenerated-artifact publish).
#
# HIMMEL-3360 changed the baseline itself: cr_signal_gate no longer fails
# closed on ANY CodeRabbit status (absent/pending/failure/skipped/paged/
# unreadable) for ANY PR, machine-generated or not — that gate is advisory-only
# across the board, so the classifier had nothing left to decide and was
# DELETED from check-ci.sh. The negative controls below (2278-c/d/e/f/g/h/l/m/
# o/p), which used to prove an ORDINARY PR still fails closed where a
# machine-classified one doesn't, now all read rc 0: there is no observable
# difference between a machine-shaped and an ordinary PR. They are kept
# (flipped to their true rc) as coverage that the plain `run cr-absent`/
# `cr-failure`/`cr-pending` path is unaffected by the MPR_OVERRIDE probe
# replies; 2278-i/j/k/q remain the real assertions of record (threads/
# red-check/CHANGES_REQUESTED/body-findings stay armed regardless of diff shape).

# 2278-a — dependabot dep bump + no App review → rc 0 (the #2013 shape).
MPR_OVERRIDE=dependabot
run cr-absent
assert_rc 0 "2278-a dependabot PR passes with no CodeRabbit review"
assert_err_has "NOTE — CodeRabbit absent" "2278-a absent status is the plain NOTE (classifier deleted, HIMMEL-3360)"

# 2278-b — a graph-publish artifact PR + no App review → rc 0 (the #2035 shape).
MPR_OVERRIDE=graph
run cr-absent
assert_rc 0 "2278-b graphify-artifact PR passes with no CodeRabbit review"
assert_err_has "NOTE — CodeRabbit absent" "2278-b absent status is the plain NOTE (classifier deleted, HIMMEL-3360)"

# 2278-c — the former spoof control (artifact paths PLUS a code path). No
# longer distinguishable from the positives at the cr_signal_gate exit code
# (HIMMEL-3360: absent is advisory for every diff shape) — kept to pin that a
# misclassification-prone probe reply still doesn't crash or mis-exit.
MPR_OVERRIDE=graph-plus-code
run cr-absent
assert_rc 0 "2278-c artifact paths PLUS a code path — advisory now regardless of shape (HIMMEL-3360)"

# 2278-d — an ordinary human code PR with no App review: advisory now too.
MPR_OVERRIDE=none
run cr-absent
assert_rc 0 "2278-d ordinary code PR is advisory-only on an absent review (HIMMEL-3360)"

# 2278-e — a human account whose login merely LOOKS like the bot's. is_bot is
# GitHub's; the impostor stays outside the class, but that no longer changes
# the exit code either way (HIMMEL-3360).
MPR_OVERRIDE=dep-impostor
run cr-absent
assert_rc 0 "2278-e dependabot login without is_bot — advisory regardless (HIMMEL-3360)"

# 2278-f — the classifier's own probe erroring is not evidence of anything;
# no longer observable via cr_signal_gate's exit code (HIMMEL-3360).
MPR_OVERRIDE=probe-fail
run cr-absent
assert_rc 0 "2278-f an erroring author/files probe — advisory regardless (HIMMEL-3360)"

# 2278-g — a response missing the MPR_OK sentinel must not parse as a bot
# author with zero files; no longer observable via the exit code (HIMMEL-3360).
MPR_OVERRIDE=garbage
run cr-absent
assert_rc 0 "2278-g a sentinel-less probe response — advisory regardless (HIMMEL-3360)"

# 2278-h — a single file literally named `*`. Comparing in the wrong direction
# would glob-match it into the class; no longer observable via the exit code.
MPR_OVERRIDE=globname
run cr-absent
assert_rc 0 "2278-h a glob-named path — advisory regardless (HIMMEL-3360)"

# 2278-l — an empty changed-file list is not "all paths are artifacts"; no
# longer observable via the exit code (HIMMEL-3360).
MPR_OVERRIDE=empty
run cr-absent
assert_rc 0 "2278-l an empty file list — advisory regardless (HIMMEL-3360)"

# 2278-m — a truncated-but-rc-0 probe: it advertises 3 files but emits only
# the two artifact paths; no longer observable via the exit code (HIMMEL-3360).
MPR_OVERRIDE=truncated
run cr-absent
assert_rc 0 "2278-m a truncated file list — advisory regardless (HIMMEL-3360)"

# --- HIMMEL-2278 CR round 2: the class tolerates SILENCE, and only silence ---
#
# codex-1 disproved the first cut's blanket `CR_ARMED=0`: it also silenced
# cr_body_gate and review_freshness_gate, so on the day the App DOES review a
# machine-class PR its outside-diff-range body findings — which carry no
# thread, and so are invisible to every other gate — would have been dropped.
# 2278-n is the positive (the #2035 rate-limited shape is tolerated); n+1..n+3
# are the controls that the narrowing actually narrowed.

# 2278-n — the #2035 shape verbatim: state=success with a rate-limited
# description. rc 0 — advisory for every PR now (HIMMEL-3360), not just this
# class.
MPR_OVERRIDE=dependabot
run cr-ratelimited
assert_rc 0 "2278-n a rate-limited App is advisory, for every PR (HIMMEL-3360)"

# 2278-o — a FAILED App status: HIMMEL-3360 made failure/error advisory-only
# for every PR (not just this class) — rc 0, an advisory NOTE, never a block.
MPR_OVERRIDE=dependabot
run cr-failure
assert_rc 0 "2278-o a failed App status is advisory-only now, for every PR (HIMMEL-3360)"

# 2278-p — nor is a PENDING one: also advisory now, for every PR (HIMMEL-3360).
MPR_OVERRIDE=dependabot
run cr-pending
assert_rc 0 "2278-p a pending App review is advisory-only now, for every PR (HIMMEL-3360)"

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
assert_grep_lacks "2380-b a real adopter still hears nothing about CodeRabbit" "output mentioned CodeRabbit: $ERR" -i "coderabbit" <<<"$OUT$ERR"

# 2380-c — precedence, and the noise it suppresses. CR_PROFILE=none is read
# before the marker (cr_app_state keeps cr_app_configured's order), so an
# operator who already opted out is not told about a typo in a marker their own
# setting overrides. State is `disabled`, not `broken`: no warning.
CR_APP_OVERRIDE=""
CR_PROFILE_OVERRIDE=none
run_in_repo "$BROKEN_MARKER_REPO" cr-absent
assert_rc 0 "2380-c CR_PROFILE=none over a broken marker is still green"
assert_err_lacks "2380-c an explicit opt-out suppresses the broken-marker warning" "warned anyway: $ERR" -F "himmel.coderabbit marker holds a value"

# ── HIMMEL-2769: CR-UNARMED — a declared-CodeRabbit repo left unarmed fails
# loud instead of certifying a review nobody armed. `not-configured` is the
# adopter's silent steady state (case 2380-b) ONLY when the repo never
# declared CodeRabbit in the first place; a committed .coderabbit.yaml is
# that declaration, so an unarmed marker alongside it is a clone nobody ran
# `git config --local himmel.coderabbit true` on, not an adopter.

# 2769-a — THE red this ticket adds: yaml present, no marker anywhere ->
# CR-UNARMED, exit non-zero, never a silent green.
CR_APP_OVERRIDE=""
run_in_repo "$CR_YAML_UNARMED_REPO" cr-absent
assert_rc 2 "2769-a a declared-CodeRabbit repo left unarmed fails loud (CR-UNARMED)"
assert_err_has "CR-UNARMED" "2769-a the summary line names CR-UNARMED"
assert_err_has "git config --local himmel.coderabbit true" "2769-a the line carries the fix"

# 2769-b — the sole bypass (kept its existing meaning): CR_APP=0 makes
# cr_app_state report 'disabled', never 'not-configured', so the new block
# cannot fire — pin the precedence rather than assume it.
CR_APP_OVERRIDE=0
run_in_repo "$CR_YAML_UNARMED_REPO" cr-absent
assert_rc 0 "2769-b CR_APP=0 bypasses CR-UNARMED even with .coderabbit.yaml present"

# 2769-c — NEGATIVE CONTROL: no .coderabbit.yaml at all (case 2380-b's real
# adopter) must keep today's default-disarmed green. This ticket closes a
# vacuous-green class; it must not turn every unarmed adopter into a blocked
# one (case 5 in test-cr-available.sh, pinned there).
CR_APP_OVERRIDE=""
run_in_repo "$EMPTY_LEDGER_REPO" cr-absent
assert_rc 0 "2769-c an adopter with no .coderabbit.yaml stays default-disarmed (no CR-UNARMED)"
assert_err_lacks "2769-c no .coderabbit.yaml -> no CR-UNARMED line" "printed anyway: $ERR" -F "CR-UNARMED"

# --- 2704: CodeRabbit is the App, and check-ci NEVER consults a CLI ----------
# HIMMEL-2704 retired the CodeRabbit CLI. check-ci.sh was always App-only, and
# these two cases PIN that rather than assuming it.
#
# Why a planted binary and not an empty PATH: "no coderabbit on PATH" is a
# VACUOUS control — a gate that shells out to a missing binary and silently
# swallows the failure passes it just as happily as a gate that never tries. So
# plant an EXECUTABLE `coderabbit` first on PATH (run() prepends $STUBDIR) that
# records every invocation. If check-ci ever consults a CLI, the marker file
# appears and both cases fail.
#
# The pair is the RED control the ticket asks for, and only the THREAD state
# differs between them:
#   2704-a  all threads resolved   -> rc 0  (green)
#   2704-b  one unresolved thread  -> rc 3  (refused)
# Same repo, same checks, same planted binary. A regression that stopped
# reading threads flips 2704-b to 0; one that started shelling out to a CLI
# trips the marker in both.
cat > "$STUBDIR/coderabbit" <<'CRBINEOF'
#!/usr/bin/env bash
printf 'invoked: %s\n' "$*" >> "${CR_CLI_MARKER:?}"
exit 0
CRBINEOF
chmod +x "$STUBDIR/coderabbit"
CR_CLI_MARKER="$STUBDIR/coderabbit-invoked"
export CR_CLI_MARKER
: > "$CR_CLI_MARKER"

# 2704-a — all threads resolved, App status concluded -> green, CLI untouched.
THREADS_OVERRIDE=0
run register-then-green
assert_rc 0 "2704-a all threads resolved is green"
if [ -s "$CR_CLI_MARKER" ]; then
    fail "2704-a check-ci never shells out to a coderabbit CLI" "CLI was invoked: $(cat "$CR_CLI_MARKER")"
else
    pass "2704-a check-ci never shells out to a coderabbit CLI"
fi

# 2704-b — ONE unresolved thread -> refused (rc 3), still no CLI. This is the
# PR #2209 shape: the checks are GREEN and the rollup would read `pass`; the
# only thing standing between this PR and a merge is the thread query.
: > "$CR_CLI_MARKER"
THREADS_OVERRIDE=1
run register-then-green
assert_rc 3 "2704-b one unresolved thread refuses despite green checks"
assert_err_has "1 unresolved review thread(s)" "2704-b refusal names the thread count"
if [ -s "$CR_CLI_MARKER" ]; then
    fail "2704-b the refusal comes from the thread query, not a CLI" "CLI was invoked: $(cat "$CR_CLI_MARKER")"
else
    pass "2704-b the refusal comes from the thread query, not a CLI"
fi

rm -f "$STUBDIR/coderabbit" "$CR_CLI_MARKER"
unset CR_CLI_MARKER

# --- 3381: GitHub blocks the merge -> fail fast, distinct exit, ONE alert -----
# A required check that never reports, a required check that FAILED, and an
# unreadable required set are each a merge GitHub will refuse. None may be waited
# on past a stated bound (--grace) and each must fire exactly ONE operator alert
# per (repo, PR, head). Every case pair varies ONE thing against a green control.

# 3381-a — required check absent after --grace: exit 5 naming it, one DM to the
# FIRST POSITIVE allowFrom id (555, not the group id ahead of it).
RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests"
run cr-completed --grace 0
assert_rc 5 "3381-a a required check that never reports exits 5"
assert_verdict 5 "3381-a exactly one verdict line, exit=5"
assert_err_has "codeowner-review-gate" "3381-a the refusal names the missing required check"
assert_err_has "MERGE-BLOCKED" "3381-a the operator-visible MERGE-BLOCKED line is printed"
if [ "$(alert_count)" = 1 ]; then pass "3381-a exactly one alert sent"; else fail "3381-a exactly one alert sent" "count=$(alert_count)"; fi
if grep -q '^555 MERGE-BLOCKED octo/demo#42 @sha1: .*codeowner-review-gate' "$STUBDIR/alerts.log"; then
    pass "3381-a the DM goes to the first positive allowFrom id and names repo/PR/head/rule"
else
    fail "3381-a the DM goes to the first positive allowFrom id and names repo/PR/head/rule" "$(cat "$STUBDIR/alerts.log")"
fi

# 3381-b — control: the same rule, the check IS registered and green -> exit 0, NO alert.
RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests
pass:codeowner-review-gate"
run cr-completed --grace 0
assert_rc 0 "3381-b control: the required check reported green -> exit 0"
if [ "$(alert_count)" = 0 ]; then pass "3381-b control: no alert on a green PR"; else fail "3381-b control: no alert on a green PR" "count=$(alert_count)"; fi

# 3381-c — the required set is read from BOTH endpoints: a check required only by
# classic protection (not the ruleset) is missing too.
RULES_OVERRIDE=none; CLASSIC_OVERRIDE="ctx:legacy-required"; CHECKS_OVERRIDE="pass:unit-tests"
run cr-completed --grace 0
assert_rc 5 "3381-c a classic-protection-only required check is read (union) and its absence exits 5"
assert_err_has "legacy-required" "3381-c the refusal names the classic-protection check"

# 3381-d — an unreadable ruleset endpoint FAILS CLOSED (never an empty set).
RULES_OVERRIDE=fail
run cr-completed --grace 0
assert_rc 5 "3381-d an unreadable ruleset read fails closed with exit 5"
assert_err_has "required-set unreadable" "3381-d the refusal says the required set is unreadable"
if [ "$(alert_count)" = 1 ]; then pass "3381-d one alert for an unreadable set"; else fail "3381-d one alert for an unreadable set" "count=$(alert_count)"; fi

# 3381-e — an unreadable classic endpoint (403) fails closed too; only a 404
# "Branch not protected" means "no classic rule".
CLASSIC_OVERRIDE=fail
run cr-completed --grace 0
assert_rc 5 "3381-e a 403 on classic protection fails closed (only 404 means none)"
assert_err_has "required-set unreadable" "3381-e names the unreadable set"

# 3381-f — a required check FAILED before the watch: exit 1 at once (no watch, no
# sleep), naming the check, one alert.
RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests
fail:codeowner-review-gate"
SLEEP_CMD_OVERRIDE="$STUBDIR/counting-sleep"
run cr-completed
assert_rc 1 "3381-f a FAILED required check exits 1"
assert_err_has "codeowner-review-gate" "3381-f the refusal names the failed required check"
if [ "$(wc -l < "$STUBDIR/sleepcount" | tr -d ' ')" = 0 ]; then pass "3381-f a failed required check is never slept on"; else fail "3381-f a failed required check is never slept on" "sleeps=$(wc -l < "$STUBDIR/sleepcount")"; fi
if [ "$(alert_count)" = 1 ]; then pass "3381-f one alert for a failed required check"; else fail "3381-f one alert for a failed required check" "count=$(alert_count)"; fi

# 3381-g — dedupe: the SAME head refused twice sends ONE alert; the printed line
# still appears both times.
KEEP_ALERT_STATE=0
RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests"
run cr-completed --grace 0
KEEP_ALERT_STATE=1; RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests"
run cr-completed --grace 0
assert_rc 5 "3381-g the second run is refused the same way"
assert_err_has "MERGE-BLOCKED" "3381-g the second run still prints the MERGE-BLOCKED line"
if [ "$(alert_count)" = 1 ]; then pass "3381-g one DM per (repo, PR, head) across two runs"; else fail "3381-g one DM per (repo, PR, head) across two runs" "count=$(alert_count)"; fi

# 3381-h — a dead bridge NEVER changes the exit code.
ALERT_FAIL_OVERRIDE=1; RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests"
run cr-completed --grace 0
assert_rc 5 "3381-h a failing alert sender leaves the exit code at 5"
assert_err_has "DM delivery failed" "3381-h the delivery failure is reported, not swallowed"

# 3381-i — no readable operator id: no DM, exit unchanged, the printed line is the alert.
ACCESS_OVERRIDE="$STUBDIR/does-not-exist.json"; RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests"
run cr-completed --grace 0
assert_rc 5 "3381-i no readable access.json leaves the exit code at 5"
if [ "$(alert_count)" = 0 ]; then pass "3381-i no DM without an operator chat id"; else fail "3381-i no DM without an operator chat id" "count=$(alert_count)"; fi

# 3381-j — a required check that registers LATE inside --grace is waited for (the
# bound), not refused: the first row read lacks it, the next has it.
RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="late:codeowner-review-gate"
run cr-completed --grace 30
assert_rc 0 "3381-j a required check that registers within --grace is not refused"

# 3381-k — the wait is BOUNDED: with --grace 1 and a real 1s poll, a check that
# never appears is refused after the bound, not looped on.
RULES_OVERRIDE="req:codeowner-review-gate"; CHECKS_OVERRIDE="pass:unit-tests"
SLEEP_CMD_OVERRIDE="$STUBDIR/counting-sleep"; POLL_OVERRIDE=1
run cr-completed --grace 1
assert_rc 5 "3381-k a never-appearing required check is refused once --grace elapses"
if [ "$(wc -l < "$STUBDIR/sleepcount" | tr -d ' ')" -le 3 ]; then pass "3381-k the wait stayed within the grace bound"; else fail "3381-k the wait stayed within the grace bound" "sleeps=$(wc -l < "$STUBDIR/sleepcount")"; fi

# 3381-l — a required check that FAILS during the watch (red_exit) alerts once too.
RULES_OVERRIDE="req:unit-tests"; CHECKS_OVERRIDE="flipfail:unit-tests"
run red
assert_rc 1 "3381-l a required check failing in the watch exits 1"
if [ "$(alert_count)" = 1 ]; then pass "3381-l one alert for a required check that failed in the watch"; else fail "3381-l one alert for a required check that failed in the watch" "count=$(alert_count)"; fi

# 3381-m — a required check GitHub has not registered YET because it is held by
# needs: (an aggregator behind pending shards) is not refused while any other check
# is still pending, even with --grace 0: the watch settles the shards first.
RULES_OVERRIDE="req:agg"; CHECKS_OVERRIDE="pendlate:agg"
run cr-completed --grace 0
assert_rc 0 "3381-m a missing required check is not refused while another check is pending"
if [ "$(alert_count)" = 0 ]; then pass "3381-m no alert for a check held behind pending jobs"; else fail "3381-m no alert for a check held behind pending jobs" "count=$(alert_count)"; fi

# 3381-n — control: the same check STILL absent after the watch is refused (the
# deferral never certifies a green GitHub would block).
RULES_OVERRIDE="req:agg"; CHECKS_OVERRIDE="pendstuck:agg"
run cr-completed --grace 0
assert_rc 5 "3381-n a required check still missing after the watch exits 5"
assert_err_has "agg" "3381-n the refusal names the missing required check"

# --- 3385: a required check carrying a producer id is matched on the producer --
# The ruleset's integration_id / classic protection's app_id say WHICH app must
# report the check. A same-named check from another app satisfies `gh pr checks`
# (which exposes no app id) but not GitHub. Raw payloads go through the --jq
# expression check-ci.sh really passes, so an id its expression drops stays dropped.
_rule_id='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"codeowner-review-gate","integration_id":15368}]}}]'
_rule_noid='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"codeowner-review-gate"}]}}]'
_runs_wrong='{"check_runs":[{"name":"codeowner-review-gate","status":"completed","conclusion":"success","app":{"id":99}}]}'
_runs_right='{"check_runs":[{"name":"codeowner-review-gate","status":"completed","conclusion":"success","app":{"id":15368}}]}'
_runs_red='{"check_runs":[{"name":"codeowner-review-gate","status":"completed","conclusion":"failure","app":{"id":15368}}]}'
_both_checks="pass:unit-tests
pass:codeowner-review-gate"

# 3385-a — the name is on the PR but the WRONG app produced it: GitHub counts the
# required check as missing, so the gate must too (exit 5, names it, one alert).
RULES_OVERRIDE="json:$_rule_id"; CHECKS_OVERRIDE="$_both_checks"; PRODUCERS_OVERRIDE="json:$_runs_wrong"
run cr-completed --grace 0
assert_rc 5 "3385-a a same-named check from the wrong app does not satisfy a required check with an integration id"
assert_err_has "codeowner-review-gate" "3385-a the refusal names the required check"
if [ "$(alert_count)" = 1 ]; then pass "3385-a one alert for the wrong-producer refusal"; else fail "3385-a one alert for the wrong-producer refusal" "count=$(alert_count)"; fi

# 3385-b — control: the RIGHT app produced it -> exit 0, no alert.
RULES_OVERRIDE="json:$_rule_id"; CHECKS_OVERRIDE="$_both_checks"; PRODUCERS_OVERRIDE="json:$_runs_right"
run cr-completed --grace 0
assert_rc 0 "3385-b control: the required check from the right app is satisfied"
if [ "$(alert_count)" = 0 ]; then pass "3385-b control: no alert"; else fail "3385-b control: no alert" "count=$(alert_count)"; fi

# 3385-c — control: a required entry with NO id stays a name-only match, whichever
# app produced the check.
RULES_OVERRIDE="json:$_rule_noid"; CHECKS_OVERRIDE="$_both_checks"; PRODUCERS_OVERRIDE="json:$_runs_wrong"
run cr-completed --grace 0
assert_rc 0 "3385-c control: a required entry without an id still matches by name"

# 3385-d — the right app's run FAILED: a failed required check, exit 1.
RULES_OVERRIDE="json:$_rule_id"; CHECKS_OVERRIDE="$_both_checks"; PRODUCERS_OVERRIDE="json:$_runs_red"
run cr-completed --grace 0
assert_rc 1 "3385-d a failed run from the required app exits 1"
assert_err_has "codeowner-review-gate" "3385-d the refusal names the failed required check"

# 3385-e — the producer read is unreadable: FAIL CLOSED (exit 5), one alert, never
# a name-only fallback that would certify the wrong producer.
RULES_OVERRIDE="json:$_rule_id"; CHECKS_OVERRIDE="$_both_checks"; PRODUCERS_OVERRIDE=fail
run cr-completed --grace 0
assert_rc 5 "3385-e an unreadable producer read fails closed with exit 5"
assert_err_has "producer" "3385-e the refusal says the producer read failed"
if [ "$(alert_count)" = 1 ]; then pass "3385-e one alert for an unreadable producer read"; else fail "3385-e one alert for an unreadable producer read" "count=$(alert_count)"; fi

# 3385-f — classic protection carries the id as app_id; its deprecated `contexts`
# list repeats the same name id-less and must not weaken it back to name-only.
RULES_OVERRIDE=none; CLASSIC_OVERRIDE='json:{"contexts":["codeowner-review-gate"],"checks":[{"context":"codeowner-review-gate","app_id":15368}]}'
CHECKS_OVERRIDE="$_both_checks"; PRODUCERS_OVERRIDE="json:$_runs_wrong"
run cr-completed --grace 0
assert_rc 5 "3385-f a classic-protection app_id is honoured; the id-less contexts repeat does not weaken it"

# 3385-g — control: classic app_id -1 means "any source" — name-only.
RULES_OVERRIDE=none; CLASSIC_OVERRIDE='json:{"contexts":["codeowner-review-gate"],"checks":[{"context":"codeowner-review-gate","app_id":-1}]}'
CHECKS_OVERRIDE="$_both_checks"; PRODUCERS_OVERRIDE="json:$_runs_wrong"
run cr-completed --grace 0
assert_rc 0 "3385-g control: classic app_id -1 (any source) stays a name-only match"

echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
if [ "$COUNT" -ne 158 ]; then echo "CASE-COUNT MISMATCH: ran $COUNT want 158"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
