#!/usr/bin/env bash
# Tests for scripts/check-ci.sh (HIMMEL-949).
#
# Hermetic: `gh` is a PATH stub whose behavior is driven by GH_STUB_MODE +
# counter files; CHECK_CI_POLL_INTERVAL=0 removes the grace-window sleeps,
# CHECK_CI_SETTLE=0 disables the settle round unless a case opts in, and the
# escalation wait defaults to 0 so ordinary bounded-loop cases never sleep.
# Never talks to GitHub.
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
# GH_STUB_STATUSES / GH_STUB_REVIEWS / GH_STUB_COMMENTS files, unresolved-thread count via
# GH_STUB_THREADS ("fail" makes the graphql call
# error; "paged" puts the unresolved thread on page two). graphql pages are
# echoed in the script's parsed shape: "<count> <hasNextPage> <endCursor>".
# Args are logged to GH_STUB_ARGS.
echo "$*" >> "$GH_STUB_ARGS"
cmd="${1:-}"
if [ "$cmd" = "api" ]; then
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
                body-a2-timeout)
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
                        echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"shaOLD","body":"Outside diff range comments (2)"},{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"sha1","body":""}]'
                    fi ;;
                body-empty) echo '[]' ;;
                *)          echo '[]' ;;
            esac
            exit 0 ;;
        repos/octo/demo/issues/42/comments*)
            case " $* " in
                *" -f body="*)
                    c=$(cat "$GH_STUB_COMMENTS" 2>/dev/null)
                    c=${c:-0}
                    echo $((c+1)) > "$GH_STUB_COMMENTS"
                    echo '{"id":1001}' ;;
                *)
                    if [ "$GH_STUB_MODE" = "body-a2-marker" ]; then
                        echo '<!-- himmel:cr-escalate:sha1 -->'
                    fi ;;
            esac
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
    case "$*" in
        *"reviews(last:"*)
            case "${GH_STUB_FRESHNESS:-fresh}" in
                fresh)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"sha1"},"state":"COMMENTED"}]}}}}}' ;;
                stale)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"shaOLD"},"state":"COMMENTED"}]}}}}}' ;;
                none)     echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"human","__typename":"User"},"commit":{"oid":"sha1"},"state":"COMMENTED"}]}}}}}' ;;
                paged)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":150,"nodes":[]}}}}}' ;;
                mybot)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"mybot","__typename":"Bot"},"commit":{"oid":"sha1"},"state":"COMMENTED"}]}}}}}' ;;
                nulloid)  echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":null},"state":"COMMENTED"}]}}}}}' ;;
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
        case "$GH_STUB_MODE" in
            zombie-late)
                # First checks --json probe (zombie other_pending snapshot)
                # sees 0; the settle re-probe (and later calls) see 1 late
                # arrival. Count only `pr checks … --json` lines — pr_view's
                # `--json headRefOid` calls land in the same args log.
                njson=$(grep -c "^pr checks .*--json" "$GH_STUB_ARGS" 2>/dev/null); njson=${njson:-1}
                if [ "$njson" -le 1 ]; then echo 0; else echo 1; fi ;;
            red-liar|zombie|zombie-young|zombie-no-status|zombie-status-error) echo 0 ;;
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
    body-outside|body-nitpick|body-drift|body-error|body-a2|body-empty|body-a2-escalate|body-a2-marker|body-a2-timeout|body-a2-escalate-outside)
        # Checks GREEN, threads clean, CodeRabbit CONCLUDED (default statuses
        # fixture) in every one of these — the verdict must turn entirely on
        # the review-BODY findings gate (HIMMEL-1126/1147/1219).
        if [ "$is_watch" -eq 1 ]; then echo "All checks were successful"; exit 0; fi
        exit 0 ;;
    *)
        echo "gh stub: unknown GH_STUB_MODE '$GH_STUB_MODE'" >&2; exit 99 ;;
esac
EOF
chmod +x "$STUBDIR/gh" || { echo "FATAL: chmod on gh stub failed"; exit 1; }
[ -x "$STUBDIR/gh" ] || { echo "FATAL: gh stub not executable"; exit 1; }

OUT=""; ERR=""; RC=0
# Per-case opt-in overrides, reset after every run:
SETTLE_OVERRIDE=0; THREADS_OVERRIDE=0; POLL_OVERRIDE=0; HEAD_OVERRIDE=stable; DECISION_OVERRIDE=null
ESCALATE_WAIT_OVERRIDE=0; ESCALATE_POLL_OVERRIDE=0
# FRESHNESS_OVERRIDE drives GH_STUB_FRESHNESS (HIMMEL-1181). Default 'fresh'
# matches every case that doesn't care about the review-freshness gate.
FRESHNESS_OVERRIDE=fresh
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
# run <mode> [args...]
run() {
    local mode="$1"; shift
    COUNT=$((COUNT+1))
    local of ef
    if ! of=$(mktemp "$STUBDIR/out.XXXXXX"); then echo "FATAL: mktemp for stdout capture failed" >&2; exit 1; fi
    if ! ef=$(mktemp "$STUBDIR/err.XXXXXX"); then rm -f "$of"; echo "FATAL: mktemp for stderr capture failed" >&2; exit 1; fi
    : > "$STUBDIR/args.log"
    : > "$STUBDIR/count"
    : > "$STUBDIR/watch"
    : > "$STUBDIR/api"
    : > "$STUBDIR/headc"
    : > "$STUBDIR/statuses"
    : > "$STUBDIR/reviews"
    : > "$STUBDIR/comments"
    PATH="$STUBDIR:$PATH" \
        GH_STUB_MODE="$mode" \
        GH_STUB_ARGS="$STUBDIR/args.log" \
        GH_STUB_COUNT="$STUBDIR/count" \
        GH_STUB_WATCH="$STUBDIR/watch" \
        GH_STUB_API="$STUBDIR/api" \
        GH_STUB_HEADC="$STUBDIR/headc" \
        GH_STUB_STATUSES="$STUBDIR/statuses" \
        GH_STUB_REVIEWS="$STUBDIR/reviews" \
        GH_STUB_COMMENTS="$STUBDIR/comments" \
        GH_STUB_HEAD="$HEAD_OVERRIDE" \
        GH_STUB_DECISION="$DECISION_OVERRIDE" \
        GH_STUB_THREADS="$THREADS_OVERRIDE" \
        GH_STUB_FRESHNESS="$FRESHNESS_OVERRIDE" \
        CHECK_CI_POLL_INTERVAL="$POLL_OVERRIDE" \
        CHECK_CI_SETTLE="$SETTLE_OVERRIDE" \
        CR_ESCALATE_WAIT="$ESCALATE_WAIT_OVERRIDE" \
        CR_ESCALATE_POLL="$ESCALATE_POLL_OVERRIDE" \
        CR_PROFILE="$CR_PROFILE_OVERRIDE" \
        CR_APP="$CR_APP_OVERRIDE" \
        CR_BOT_LOGINS="$CR_BOT_LOGINS_OVERRIDE" \
        bash "$SCRIPT" "$@" >"$of" 2>"$ef"
    RC=$?
    OUT=$(cat "$of"); ERR=$(cat "$ef")
    rm -f "$of" "$ef"
    SETTLE_OVERRIDE=0; THREADS_OVERRIDE=0; POLL_OVERRIDE=0; HEAD_OVERRIDE=stable; DECISION_OVERRIDE=null
    ESCALATE_WAIT_OVERRIDE=0; ESCALATE_POLL_OVERRIDE=0
    CR_PROFILE_OVERRIDE=""; CR_APP_OVERRIDE=1
    FRESHNESS_OVERRIDE=fresh; CR_BOT_LOGINS_OVERRIDE=""
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
EMPTY_LEDGER_REPO=$(mktemp -d "$STUBDIR/empty-ledger.XXXXXX")
git -C "$EMPTY_LEDGER_REPO" init --quiet
git -C "$EMPTY_LEDGER_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet --no-verify
: > "$EMPTY_LEDGER_REPO/.git/cr-critic-scores.jsonl"
LEDGER_REPO=$(mktemp -d "$STUBDIR/clean-ledger.XXXXXX")
git -C "$LEDGER_REPO" init --quiet
git -C "$LEDGER_REPO" -c user.email=t@t -c user.name=t commit --allow-empty -m seed --quiet --no-verify
printf '%s\n' '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"sha1","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' > "$LEDGER_REPO/.git/cr-critic-scores.jsonl"
DIRTY_LEDGER_REPO=$(mktemp -d "$STUBDIR/dirty-ledger.XXXXXX")
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

# 44 — opt-in escalation posts one full-review request carrying the per-head
# marker, then a clean review object appears on the immediate bounded re-read.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-escalate --escalate
assert_rc 0 "44 escalation resolves incremental-silent state"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 1 ]; then pass "44 escalation posts exactly once"; else fail "44 escalation posts exactly once" "posts=$posts want 1"; fi
if grep -F -- '@coderabbitai full review' "$STUBDIR/args.log" >/dev/null \
    && grep -F -- '<!-- himmel:cr-escalate:sha1 -->' "$STUBDIR/args.log" >/dev/null; then
    pass "44 escalation body carries command + head marker"
else
    fail "44 escalation body carries command + head marker" "args.log: $(cat "$STUBDIR/args.log")"
fi

# 45 — a retry on the same head sees the exact marker and waits without
# posting again; the subsequent read can still complete the normal gate.
run_in_repo "$EMPTY_LEDGER_REPO" body-a2-marker --escalate
assert_rc 0 "45 existing marker still evaluates the refreshed review"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 0 ]; then pass "45 existing marker suppresses duplicate post"; else fail "45 existing marker suppresses duplicate post" "posts=$posts want 0"; fi
assert_err_has "already requested" "45 existing marker path is surfaced"

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

# 62 — threads-only, none (zero bot reviews on the whole PR): self-skip, rc 0.
FRESHNESS_OVERRIDE=none
run body-empty --threads-only
assert_rc 0 "62 threads-only no bot review: self-skip rc 0"
assert_out_has "freshness self-skipped" "62 self-skip note present"

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

echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
if [ "$COUNT" -ne 87 ]; then echo "CASE-COUNT MISMATCH: ran $COUNT want 87"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
