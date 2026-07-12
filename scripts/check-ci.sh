#!/usr/bin/env bash
# check-ci.sh — token-free PR merge-gate watcher (HIMMEL-949).
#
# Friction this prevents: merge-on-green sessions burn tokens re-running
# `gh pr checks` in an agent poll loop. This wraps the whole wait in ONE
# process — all polling happens inside `gh pr checks --watch --fail-fast` —
# so a session launches it once (background Bash) and reads a single exit
# code when it finishes. Exit 0 means BOTH gates passed: every check green
# AND zero unresolved PR review threads (a CR comment left unresolved is a
# merge blocker, same as a red check).
#
# Usage: check-ci.sh [<pr-number|branch|url>] [--grace <sec>] [--settle <sec>] [--threads-only]
#   selector        optional; defaults to the PR for the current branch
#   --threads-only  skip the checks watch entirely and run just the
#                   review-thread gate (used by /pr-check step 4.8 so both
#                   enforcement points share ONE implementation)
#   --grace <sec>   how long to wait for checks to REGISTER before giving up
#                   (default 180). Right after `git push` / `gh pr create`,
#                   `gh pr checks` errors with "no checks reported" until the
#                   CI provider picks up the commit — that window is not a
#                   failure, so we retry through it.
#   --settle <sec>  after the first green verdict, wait this long and watch
#                   once more (default 30; 0 disables). Guards the codex-adv-1
#                   race: check runs register at different times, so the first
#                   watch can go green before a slower workflow has created
#                   its check run at all. One settle round bounds that window;
#                   a workflow that registers even later is out of scope.
#
# The green verdict is bound to the PR head SHA: headRefOid is captured before
# the first watch and re-read before exit 0 — a concurrent push (another live
# session, automation) during the run means the certified commit is not the
# mergeable one, so the script fails closed with exit 2 (re-run).
#
# Exit codes:
#   0 — all checks green AND all review threads resolved (safe to merge)
#   1 — at least one check failed (--fail-fast: returns on the first red)
#   2 — cannot evaluate: usage error / no PR found / no checks registered
#       within --grace / gh error on the probe or the watch / thread-state
#       query failed or returned a malformed page / PR head moved during the run
#   3 — checks green but the review state blocks the merge: unresolved review
#       threads remain, or a review requests changes — address, resolve, re-run
#
# Env:
#   CHECK_CI_POLL_INTERVAL — seconds between grace-window probes (default 10;
#                            tests set 0; non-numeric falls back to default)
#   CHECK_CI_SETTLE        — default for --settle (flag wins)
#
# Un-maskable verdict (HIMMEL-974): every exit path additionally prints
# "check-ci: verdict exit=N" to STDOUT via an EXIT trap installed after arg
# parsing (--help / usage errors stay clean). A caller that pipes the run
# (`check-ci.sh | tail`) gets the PIPE's exit code, not this script's — the
# verdict line keeps the real status readable in any captured output.
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: check-ci.sh [<pr-number|branch|url>] [--grace <sec>] [--settle <sec>] [--threads-only]
exit codes: 0 = checks green + all review threads resolved, 1 = a check failed,
            2 = cannot evaluate (usage / no PR / no checks within --grace / thread query failed / PR head moved),
            3 = checks green but unresolved review threads remain or a review requests changes
EOF
}

THREADS_ONLY=0
GRACE=180
SETTLE="${CHECK_CI_SETTLE:-30}"
POLL="${CHECK_CI_POLL_INTERVAL:-10}"
case "$POLL" in
    ''|*[!0-9]*)
        echo "check-ci: CHECK_CI_POLL_INTERVAL='$POLL' is not a non-negative integer — using 10" >&2
        POLL=10 ;;
esac

selector=""
while [ $# -gt 0 ]; do
    case "$1" in
        --grace)
            if [ $# -lt 2 ]; then echo "check-ci: --grace needs a value" >&2; usage; exit 2; fi
            GRACE="$2"; shift 2 ;;
        --settle)
            if [ $# -lt 2 ]; then echo "check-ci: --settle needs a value" >&2; usage; exit 2; fi
            SETTLE="$2"; shift 2 ;;
        --threads-only)
            THREADS_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "check-ci: unknown option: $1" >&2; usage; exit 2 ;;
        *)
            if [ -n "$selector" ]; then echo "check-ci: only one PR selector allowed (got '$selector' and '$1')" >&2; usage; exit 2; fi
            selector="$1"; shift ;;
    esac
done

case "$GRACE" in
    ''|*[!0-9]*) echo "check-ci: --grace must be a non-negative integer, got '$GRACE'" >&2; exit 2 ;;
esac
case "$SETTLE" in
    ''|*[!0-9]*) echo "check-ci: --settle must be a non-negative integer, got '$SETTLE'" >&2; exit 2 ;;
esac

# Un-maskable verdict line (HIMMEL-974) — installed only now, after arg
# parsing, so --help and usage errors above stay clean. Prints on EVERY later
# exit path: a piped caller's pipeline exit code is the LAST command's, not
# this script's, so the numeric verdict must survive in the output text.
trap 'echo "check-ci: verdict exit=$?"' EXIT

if ! command -v gh >/dev/null 2>&1; then
    echo "check-ci: gh CLI not found on PATH" >&2
    exit 2
fi

pr_checks() {
    if [ -n "$selector" ]; then gh pr checks "$selector" "$@"; else gh pr checks "$@"; fi
}

pr_view() {
    if [ -n "$selector" ]; then gh pr view "$selector" "$@"; else gh pr view "$@"; fi
}

red_exit() {
    # $1 = gh rc, $2 = elapsed seconds of the failing watch round
    echo "check-ci: checks FAILED (gh rc=$1 after ${2}s)" >&2
    if [ "$2" -le 20 ]; then
        echo "check-ci: hint — all-red within seconds is usually a GitHub Actions billing/permissions block, not a code failure; check the run annotations before debugging the diff" >&2
    fi
    exit 1
}

watch_round() {
    # Runs one `gh pr checks --watch --fail-fast`. stdout stays connected to
    # the terminal (it's the live progress display); stderr is captured to a
    # temp file so a gh-level failure (auth error, cancellation, network) is
    # distinguishable from a genuinely red check — same convention as the
    # probe loop above: a red check's failure list prints to STDOUT with
    # EMPTY stderr; a gh error writes to stderr. Nonzero rc + non-empty
    # stderr → cannot evaluate (exit 2); nonzero rc + empty stderr → red_exit.
    local err_file err
    err_file=$(mktemp) || { echo "check-ci: mktemp failed — cannot evaluate the gate" >&2; exit 2; }
    watch_start=$SECONDS
    pr_checks --watch --fail-fast 2>"$err_file"
    rc=$?
    err=$(cat "$err_file" 2>/dev/null)
    rm -f "$err_file"
    if [ "$rc" -ne 0 ]; then
        if [ -n "$err" ]; then
            echo "check-ci: gh pr checks --watch failed — cannot evaluate the gate: $err" >&2
            exit 2
        fi
        # gh's documented red-check exit code is 1; anything else with empty
        # stderr (8 = pending after an interrupted watch, cancellation codes,
        # timeouts) is NOT a confirmed red — fail closed as cannot-evaluate.
        if [ "$rc" -ne 1 ]; then
            echo "check-ci: gh pr checks --watch exited rc=$rc with no error output — cannot evaluate the gate; re-run" >&2
            exit 2
        fi
        # rc 1 is ALSO gh's generic failure code — confirm the red structurally
        # (at least one check in the "fail" bucket) before reporting exit 1.
        failed=$(pr_checks --json bucket --jq '[.[] | select(.bucket == "fail")] | length' 2>/dev/null)
        case "$failed" in
            ''|*[!0-9]*)
                echo "check-ci: watch reported failure but the structured confirm failed — cannot evaluate the gate; re-run" >&2
                exit 2 ;;
        esac
        if [ "$failed" -eq 0 ]; then
            echo "check-ci: watch exited rc=1 but no check is in the fail bucket — cannot evaluate the gate; re-run" >&2
            exit 2
        fi
        red_exit "$rc" $((SECONDS - watch_start))
    fi
}

if [ "$THREADS_ONLY" -eq 0 ]; then
    # Grace window: probe (non-watch) until the PR has registered checks. gh exit
    # codes on the probe: 0 = all pass, 8 = pending — both mean checks exist, so
    # hand off to the watch. "no checks reported" right after a push is the CI
    # provider not having picked up the head SHA yet — retry through it. "no pull
    # requests found" is terminal. A non-zero rc with EMPTY stderr is a red check
    # (the failure list went to the discarded stdout) — hand off to the watch,
    # which produces the authoritative verdict. Any OTHER stderr (auth, network,
    # rate-limit) is a gate we cannot evaluate — exit 2, never a fake red.
    start=$SECONDS
    while :; do
        err=$(pr_checks 2>&1 >/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 8 ]; then break; fi
        if [ -z "$err" ]; then break; fi
        if printf '%s' "$err" | grep -i 'no pull requests found' >/dev/null; then
            echo "check-ci: $err" >&2
            exit 2
        fi
        if ! printf '%s' "$err" | grep -i 'no checks reported' >/dev/null; then
            echo "check-ci: gh pr checks failed — cannot evaluate the gate: $err" >&2
            exit 2
        fi
        if [ $((SECONDS - start)) -ge "$GRACE" ]; then
            echo "check-ci: no checks registered within ${GRACE}s — is CI configured for this branch, or did the push land?" >&2
            exit 2
        fi
        sleep "$POLL"
    done

    # Bind the verdict to this head: a concurrent push during the run would
    # make the certified commit differ from the one a merge would take.
    head0=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
    if [ -z "$head0" ]; then
        echo "check-ci: cannot read the PR head SHA — cannot bind the verdict; re-run" >&2
        exit 2
    fi

    # Watch round 1: authoritative red/green for the checks registered so far.
    watch_round

    # Settle round (codex-adv-1): give slow-registering check runs time to appear,
    # then watch again — round 2 waits for (or fails fast on) any late arrivals.
    if [ "$SETTLE" -gt 0 ]; then
        sleep "$SETTLE"
        watch_round
    fi
fi

# Thread gate: checks green is not merge-safe while PR review comments sit
# unresolved — every addressed CR finding must have its thread resolved.
# Fail-closed on a query error (exit 2): a gate we cannot evaluate must not
# pass; re-run when gh/API recovers. Owner/repo/number come from the PR's own
# URL so a URL/branch selector pointing at another repo still gates the RIGHT
# repo (github.com only — a GHE host would need gh --hostname, out of scope).
ctx="checks green but "
[ "$THREADS_ONLY" -eq 1 ] && ctx=""
# url + reviewDecision in ONE query: url doubles as the success probe, so a
# failed call can never silently read as "no decision".
pr_json=$(pr_view --json url,reviewDecision --jq '"\(.url)|\(.reviewDecision)"' 2>/dev/null)
pr_url=${pr_json%%|*}
review_decision=${pr_json##*|}
case "$pr_url" in
    https://github.com/*/pull/*) ;;
    *)
        echo "check-ci: ${ctx}cannot resolve the PR (gh pr view gave '${pr_url:-nothing}') — re-run, or verify with gh pr view" >&2
        exit 2 ;;
esac

# An explicit CHANGES_REQUESTED review is a merge blocker. Approval is NOT
# required — single-operator repos carry no GitHub approval objects (the CR
# flow is the approval gate); only the affirmative "do not merge" signal blocks.
if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
    echo "check-ci: ${ctx}a review requests changes on this PR — address it (and resolve its threads), then re-run" >&2
    exit 3
fi
num=${pr_url##*/}
nwo=${pr_url#https://github.com/}
owner=${nwo%%/*}
repo_rest=${nwo#*/}
repo=${repo_rest%%/*}

# Paginate: first:100 alone would let unresolved threads beyond page one slip
# through the gate. Each page reports "<unresolved-count> <hasNextPage> <endCursor>".
unresolved=0
cursor=""
pages=0
while :; do
    # Hard page cap: bounds EVERY malformed-pagination shape (incl. non-adjacent
    # cursor cycles like A→B→A that a last-cursor comparison can't see) at
    # 50 pages = 5000 threads — far beyond any real PR. Fail closed past it.
    pages=$((pages + 1))
    if [ "$pages" -gt 50 ]; then
        echo "check-ci: ${ctx}the review-thread query did not terminate within 50 pages (cursor cycle?) — check threads manually on PR #$num" >&2
        exit 2
    fi
    # Positional args are free after option parsing — reuse them for the
    # conditional cursor without an unquoted expansion.
    sent_cursor="$cursor"
    set -- -f o="$owner" -f r="$repo" -F n="$num"
    [ -n "$cursor" ] && set -- "$@" -f c="$cursor"
    # shellcheck disable=SC2016  # $o/$r/$n/$c are GraphQL variables — literal on purpose
    page=$(gh api graphql \
        -f query='query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}' \
        "$@" \
        --jq '.data.repository.pullRequest.reviewThreads | "\([.nodes[] | select(.isResolved | not)] | length) \(.pageInfo.hasNextPage) \(.pageInfo.endCursor)"' 2>/dev/null)
    page_count=${page%% *}
    rest=${page#* }
    has_next=${rest%% *}
    cursor=${rest#* }
    case "$page_count" in
        ''|*[!0-9]*)
            echo "check-ci: ${ctx}the review-thread query failed — re-run, or check threads manually on PR #$num" >&2
            exit 2 ;;
    esac
    case "$has_next" in
        true|false) ;;
        *)
            echo "check-ci: ${ctx}the review-thread query returned a malformed page (hasNextPage='$has_next') — re-run, or check threads manually on PR #$num" >&2
            exit 2 ;;
    esac
    if [ "$has_next" = "true" ] && { [ -z "$cursor" ] || [ "$cursor" = "null" ]; }; then
        echo "check-ci: ${ctx}the review-thread query returned a malformed page (hasNextPage=true with no cursor) — re-run, or check threads manually on PR #$num" >&2
        exit 2
    fi
    # A repeated cursor with hasNextPage=true would loop forever — fail closed.
    if [ "$has_next" = "true" ] && [ "$cursor" = "$sent_cursor" ]; then
        echo "check-ci: ${ctx}the review-thread query returned a malformed page (cursor did not advance) — re-run, or check threads manually on PR #$num" >&2
        exit 2
    fi
    unresolved=$((unresolved + page_count))
    [ "$has_next" = "true" ] || break
done
if [ "$unresolved" -gt 0 ]; then
    echo "check-ci: ${ctx}$unresolved unresolved review thread(s) on PR #$num — address each comment, resolve its thread, re-run" >&2
    exit 3
fi

if [ "$THREADS_ONLY" -eq 1 ]; then
    echo "check-ci: all review threads resolved (PR #$num)"
    exit 0
fi

# Re-read the head: the green verdict only holds for the SHA we watched.
head1=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
if [ "$head1" != "$head0" ]; then
    echo "check-ci: PR head moved during the run (${head0} → ${head1:-unreadable}) — checks certified a different commit; re-run" >&2
    exit 2
fi

echo "check-ci: all checks green + all review threads resolved (PR #$num @ $head0)"
exit 0
