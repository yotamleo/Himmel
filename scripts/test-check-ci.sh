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
# GH_STUB_REVIEWS / GH_STUB_COMMENTS files, unresolved-thread count via
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
    cr-absent|cr-pending|cr-failure|cr-spoofed|cr-query-error|cr-paged)
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
# CR_PROFILE_OVERRIDE=none exercises the CodeRabbit-less-repo opt-out
# (HIMMEL-1072); empty = a normal repo where the signal is required.
CR_PROFILE_OVERRIDE=""
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
    : > "$STUBDIR/reviews"
    : > "$STUBDIR/comments"
    PATH="$STUBDIR:$PATH" \
        GH_STUB_MODE="$mode" \
        GH_STUB_ARGS="$STUBDIR/args.log" \
        GH_STUB_COUNT="$STUBDIR/count" \
        GH_STUB_WATCH="$STUBDIR/watch" \
        GH_STUB_API="$STUBDIR/api" \
        GH_STUB_HEADC="$STUBDIR/headc" \
        GH_STUB_REVIEWS="$STUBDIR/reviews" \
        GH_STUB_COMMENTS="$STUBDIR/comments" \
        GH_STUB_HEAD="$HEAD_OVERRIDE" \
        GH_STUB_DECISION="$DECISION_OVERRIDE" \
        GH_STUB_THREADS="$THREADS_OVERRIDE" \
        CHECK_CI_POLL_INTERVAL="$POLL_OVERRIDE" \
        CHECK_CI_SETTLE="$SETTLE_OVERRIDE" \
        CR_ESCALATE_WAIT="$ESCALATE_WAIT_OVERRIDE" \
        CR_ESCALATE_POLL="$ESCALATE_POLL_OVERRIDE" \
        CR_PROFILE="$CR_PROFILE_OVERRIDE" \
        bash "$SCRIPT" "$@" >"$of" 2>"$ef"
    RC=$?
    OUT=$(cat "$of"); ERR=$(cat "$ef")
    rm -f "$of" "$ef"
    SETTLE_OVERRIDE=0; THREADS_OVERRIDE=0; POLL_OVERRIDE=0; HEAD_OVERRIDE=stable; DECISION_OVERRIDE=null
    ESCALATE_WAIT_OVERRIDE=0; ESCALATE_POLL_OVERRIDE=0
    CR_PROFILE_OVERRIDE=""
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
run body-a2
assert_rc 4 "39 incremental-silent body state rc 4"
assert_err_has "@coderabbitai full review" "39 full-review resolution printed"
assert_verdict 4 "39 un-maskable exit 4 verdict line"

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
run body-a2-escalate --escalate
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
run body-a2-marker --escalate
assert_rc 0 "45 existing marker still evaluates the refreshed review"
posts=$(cat "$STUBDIR/comments" 2>/dev/null); posts=${posts:-0}
if [ "$posts" -eq 0 ]; then pass "45 existing marker suppresses duplicate post"; else fail "45 existing marker suppresses duplicate post" "posts=$posts want 0"; fi
assert_err_has "already requested" "45 existing marker path is surfaced"

# 46 — bounded escalation never turns a missing review object into success.
# A zero-second budget makes the timeout immediate and hermetic.
run body-a2-timeout --escalate
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
run body-a2-escalate --escalate
assert_rc 0 "47 invalid escalation tuning still evaluates"
assert_err_has "CR_ESCALATE_WAIT='soon'" "47 invalid wait warns + falls back"
assert_err_has "CR_ESCALATE_POLL=0 is invalid" "47 zero poll vs positive wait warns + falls back"

# 48 — escalation resolves only unreadability. A refreshed review carrying a
# real outside-diff finding still flows through the normal rc 3 body gate.
run body-a2-escalate-outside --escalate
assert_rc 3 "48 escalated outside-diff finding still blocks"
assert_err_has "outside-diff-range finding" "48 refreshed finding reaches normal evaluation"

# 49 — a full review may also create inline threads after the normal thread
# snapshot. Escalation must re-run that gate before it can certify success.
THREADS_OVERRIDE=escalatethread
run body-a2-escalate --escalate
assert_rc 3 "49 escalated inline finding still blocks"
assert_err_has "unresolved review thread" "49 full-review thread re-check runs"

# 50 — zero is not a valid poll interval for a positive wait budget: it falls
# back before the loop, so the stale-review fixture gets no API-hammering burst.
ESCALATE_WAIT_OVERRIDE=1
ESCALATE_POLL_OVERRIDE=0
run body-a2-timeout --escalate
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
run body-a2-timeout --escalate
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
run body-a2-escalate --escalate
assert_rc 0 "52 leading-zero wait 007 still evaluates"
assert_err_has "waiting up to 7s" "52 wait 007 normalized to decimal 7 (not octal)"

echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
if [ "$COUNT" -ne 53 ]; then echo "CASE-COUNT MISMATCH: ran $COUNT want 53"; exit 1; fi
[ "$FAIL" -eq 0 ] || exit 1
