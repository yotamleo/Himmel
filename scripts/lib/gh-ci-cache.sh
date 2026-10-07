#!/usr/bin/env bash
# gh-ci-cache.sh — shared per-PR CI status cache + API-budget wait (HIMMEL-3850).
#
# Sourced, never executed. bash 3.2-safe.
#
# WHY: every leg waiting on CI ran its own `gh pr checks --watch`, a poll loop
# of GraphQL calls. Seven waiters on one shared 5000/h quota exhausted it twice in
# an hour (403s, legs blind to CI). Waiters on the SAME PR all read the SAME
# rollup, so the first caller in a TTL window fetches it once and the rest read the
# file it wrote.
#
#   cic_init <selector> [head]   bind to one PR: cache key + head sha. rc 1 = the
#                                head is unreadable -> caller keeps its legacy path.
#   cic_get <ttl_s>              CIC_ROWS = "<bucket>\t<name>" lines of the PR's
#                                checks, from the cache when the entry is younger
#                                than <ttl_s> AND was fetched for the SAME head,
#                                else fetched under a lock and cached.
#                                rc 0 ok | 1 error (CIC_ERR) | 2 the API budget
#                                is exhausted and the reset is beyond CIC_MAX_WAIT
#
# The entry is TAGGED with the head sha it was fetched for, and is written only
# when the head read AFTER the fetch still equals the head the caller bound to. A
# push therefore can never be answered with the previous head's green.
#
# Budget: before a fetch, ONE call to `gh api rate_limit` (free — it does not
# count against any bucket) reads the graphql bucket (gh pr view / gh pr checks
# are GraphQL; a drained REST core bucket never stalls this path); if it is
# under CHECK_CI_API_FLOOR the caller sleeps until the reset (bounded
# by CIC_MAX_WAIT) instead of spending the last calls. A rate-limit error from
# the fetch itself is waited out the same way and retried (max 3), never cached.
#
# Env (all optional):
#   CHECK_CI_CACHE_DIR       state dir (default $HOME/.himmel/state/ci-cache)
#   CHECK_CI_API_FLOOR       remaining below this waits for the reset (default 300; 0 = never wait)
#   CHECK_CI_LOCK_WAIT       seconds a waiter waits for the fetch lock (default 30)
#   GH_BUDGET_JITTER_MAX     wake-up jitter seconds, shared with gh-graphql-budget.sh (default 15)
#   CIC_MAX_WAIT             bound on any one budget wait, seconds (0/unset = unbounded)
#   CIC_SLEEP_CMD            sleep seam for the budget wait (default sleep)
#   CIC_CLOCK_FILE           test seam: a file holding the fake "now" (epoch seconds)
#
# ponytail: `gh pr checks --json` is GraphQL, and GraphQL has no conditional
# requests (no ETag / 304), so this cache is TTL-only; the REST check-runs +
# statuses endpoints do support ETag but cannot reproduce gh's own bucket rollup
# (required-vs-optional, skipping, cancel) faithfully, so they are not used —
# revisit if gh grows conditional GraphQL.
# ponytail: the fetch lock is an atomic mkdir, not flock — flock is absent on
# Git Bash / macOS; a lock older than 60 s is broken, and a waiter that times out
# fetches directly (cost, never correctness, degrades).

CIC_ROWS=""
CIC_ERR=""
CIC_SELECTOR=""
CIC_HEAD=""
CIC_FILE=""
CIC_LOCK=""
CIC_HELD=0
CIC_HIT_RC=0
CIC_RUN_ID=""

# Run snapshots share the same TTL, lock and atomic-write machinery as PRs,
# but are REST/core reads keyed by repository + run id (not by selected job).
cic_init_run() {
    local dir repo key
    CIC_RUN_ID="$1"
    CIC_HEAD="run:$CIC_RUN_ID"
    repo="${GH_REPO:-}"
    if [ -z "$repo" ]; then repo=$(git remote get-url origin 2>/dev/null) || return 1; fi
    [ -n "$repo" ] || return 1
    case "$repo" in
        https://*|http://*) repo="${repo#*://}" ;;
        ssh://git@*) repo="${repo#ssh://git@}" ;;
        git@*:*) repo="${repo#git@}"; repo="${repo/:/\/}" ;;
    esac
    repo="${repo%.git}"
    case "$repo" in */*/*) ;; */*) repo="${GH_HOST:-github.com}/$repo" ;; *) return 1 ;; esac
    CIC_RUN_REPO="$repo"
    dir="${CHECK_CI_CACHE_DIR:-${HOME:-/tmp}/.himmel/state/ci-cache}"
    ( umask 077; mkdir -p "$dir" ) 2>/dev/null || return 1
    key=$(printf '%s|%s' "$repo" "$CIC_RUN_ID" | cksum | awk '{print $1}')
    CIC_FILE="$dir/run-$key.rows"
    CIC_LOCK="$CIC_FILE.lock"
    return 0
}

# Bound even a stalled gh call; run mode refuses a missing timeout rather than
# silently making --max-wait unbounded. The watcher resolves timeout-bin once.
_cic_run_command() {
    local left
    if [ "${CIC_DEADLINE:-0}" -gt 0 ]; then
        left=$((CIC_DEADLINE - SECONDS))
        [ "$left" -gt 0 ] || { CIC_ERR="run read deadline exhausted"; return 1; }
        "$_TIMEOUT_BIN" -k 2 "$left" "$@"
    else
        "$@"
    fi
}

_cic_fetch_run_raw() {
    local ef raw rc
    ef=$(mktemp "${TMPDIR:-/tmp}/cic-run-err.XXXXXX") || { CIC_ERR="mktemp failed"; return 1; }
    raw=$(_cic_run_command gh run view "$CIC_RUN_ID" --repo "$CIC_RUN_REPO" --json databaseId,status,conclusion,jobs 2>"$ef"); rc=$?
    CIC_ERR=$(tr '\n' ' ' < "$ef"); rm -f "$ef"
    if [ "$rc" -ne 0 ]; then
        CIC_ERR="${CIC_ERR:-gh run view exited $rc}"
        return 1
    fi
    # Validate the whole read before deriving buckets. Unknown states and
    # incomplete completed rows must never become vacuous success.
    CIC_ROWS=$(printf '%s\n' "$raw" | jq -er --argjson id "$CIC_RUN_ID" '
        def status_ok: . == "completed" or . == "queued" or . == "in_progress"
            or . == "waiting" or . == "pending" or . == "requested";
        def conclusion_ok: . == "success" or . == "neutral" or . == "skipped"
            or . == "failure" or . == "cancelled" or . == "timed_out"
            or . == "action_required" or . == "startup_failure" or . == "stale";
        def valid: (.status | status_ok) and
            (if .status == "completed" then (.conclusion | conclusion_ok)
             else (.conclusion == "" or .conclusion == null) end);
        def bucket: if .status != "completed" then "pending"
            elif .conclusion == "success" then "pass"
            elif .conclusion == "neutral" or .conclusion == "skipped" then "skipping"
            else "fail" end;
        if type == "object" and .databaseId == $id and valid and
            (.jobs | type == "array") and all(.jobs[];
                valid and (.databaseId | type == "number" and . > 0) and
                (.name | type == "string" and length > 0 and (test("[\\t\\r\\n]") | not)))
        then ([bucket, "workflow", "run"] | join("\t")),
            (.jobs[] | [bucket, .name, "job", (.databaseId | tostring)] | join("\t"))
        else error("malformed or unknown workflow/job state") end
    ' 2>/dev/null) || { CIC_ERR="unreadable workflow run $CIC_RUN_ID: malformed or unknown workflow/job state"; CIC_ROWS=""; return 1; }
    CIC_ERR=""
    return 0
}

cic_now() {
    if [ -n "${CIC_CLOCK_FILE:-}" ] && [ -f "$CIC_CLOCK_FILE" ]; then cat "$CIC_CLOCK_FILE"; else date +%s; fi
}

_cic_gh() {   # _cic_gh <gh pr subcommand> args… — appends the selector when set
    local sub="$1"; shift
    if [ -n "$CIC_SELECTOR" ]; then gh pr "$sub" "$CIC_SELECTOR" "$@"; else gh pr "$sub" "$@"; fi
}

_cic_head_now() { _cic_gh view --json headRefOid --jq .headRefOid 2>/dev/null; }

cic_init() {
    local dir key url branch
    CIC_RUN_ID=""
    CIC_SELECTOR="${1:-}"
    CIC_HEAD="${2:-}"
    [ -n "$CIC_HEAD" ] || CIC_HEAD=$(_cic_head_now) || true
    [ -n "$CIC_HEAD" ] || return 1
    dir="${CHECK_CI_CACHE_DIR:-${HOME:-/tmp}/.himmel/state/ci-cache}"
    ( umask 077; mkdir -p "$dir" ) 2>/dev/null || return 1
    [ -d "$dir" ] && [ -w "$dir" ] || return 1
    url=$(git remote get-url origin 2>/dev/null) || url=""
    branch=""
    [ -n "$CIC_SELECTOR" ] || branch=$(git branch --show-current 2>/dev/null) || branch=""
    key=$(printf '%s|%s|%s' "$url" "$CIC_SELECTOR" "$branch" | cksum | awk '{print $1}')
    CIC_FILE="$dir/pr-$key.rows"
    CIC_LOCK="$CIC_FILE.lock"
    return 0
}

# _cic_read <ttl> — a valid entry sets CIC_ROWS (CIC_HIT_RC is always 0: only
# successful fetches are ever cached) and returns 0; rc 1 = miss.
# Valid: same head as the bound one, and younger than <ttl>. A future-dated entry
# (clock skew) is a miss.
_cic_read() {
    local ttl="$1" line ts head rc now age
    [ -f "$CIC_FILE" ] || return 1
    IFS= read -r line < "$CIC_FILE" || return 1
    IFS=$'\t' read -r ts head rc <<EOF
$line
EOF
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    [ "$rc" = 0 ] || return 1
    [ "$head" = "$CIC_HEAD" ] || return 1
    now=$(cic_now)
    age=$((now - ts))
    [ "$age" -ge 0 ] || return 1
    [ "$age" -lt "$ttl" ] || return 1
    CIC_ROWS=$(sed 1d "$CIC_FILE"); CIC_ERR=""
    CIC_HIT_RC=0
    return 0
}

# _cic_write — tmp-then-mv, so a reader never sees half an entry. A failed write
# (ENOSPC) is never promoted: a truncated row set could read as green.
_cic_write() {
    local tmp="$CIC_FILE.$$.tmp"
    if { printf '%s\t%s\t0\n' "$(cic_now)" "$CIC_HEAD" && printf '%s\n' "$CIC_ROWS"; } > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CIC_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    # Opportunistic prune: another PR's entry untouched for a day is dead.
    find "$(dirname "$CIC_FILE")" -maxdepth 1 -name 'pr-*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
}

# cic_unlock — idempotent; also the helper's TERM/EXIT path.
cic_unlock() {
    if [ "$CIC_HELD" = 1 ]; then rm -rf "$CIC_LOCK" 2>/dev/null; CIC_HELD=0; fi
    return 0
}

# _cic_lock — 0 = held, 1 = gave up waiting (caller fetches directly, uncached).
_cic_lock() {
    local waited=0 notime=0 max t now
    max="${CHECK_CI_LOCK_WAIT:-30}"
    case "$max" in ''|*[!0-9]*) max=30 ;; esac
    max=$((max * 5))
    while ! mkdir "$CIC_LOCK" 2>/dev/null; do
        t=$(cat "$CIC_LOCK/t" 2>/dev/null); now=$(cic_now)
        # A lock older than 60 s belongs to a fetch that died: break it.
        # One that never got its timestamp (the holder died between the mkdir and
        # the write, microseconds apart) is dead after 5 s.
        case "$t" in
            ''|*[!0-9]*) notime=$((notime + 1)); [ "$notime" -lt 25 ] || rm -rf "$CIC_LOCK" 2>/dev/null ;;
            *) notime=0; [ $((now - t)) -le 60 ] || rm -rf "$CIC_LOCK" 2>/dev/null ;;
        esac
        waited=$((waited + 1))
        if [ -n "$CIC_RUN_ID" ] && [ "${CIC_DEADLINE:-0}" -gt 0 ] && [ "$SECONDS" -ge "$CIC_DEADLINE" ]; then return 1; fi
        [ "$waited" -ge "$max" ] && return 1
        sleep 0.2
    done
    cic_now > "$CIC_LOCK/t" 2>/dev/null
    CIC_HELD=1
    return 0
}

# _cic_fetch_raw — ONE `gh pr checks --json` call. rc 0 = rows (possibly none),
# 1 = error text in CIC_ERR. gh's own exit status 1 / 8 is ignored (it encodes the
# rollup); the presence of rows / stderr decides, and a status above 8 with neither
# is a death, not "no checks".
_cic_fetch_raw() {
    local ef grc
    ef=$(mktemp "${TMPDIR:-/tmp}/cic-err.XXXXXX") || { CIC_ERR="mktemp failed"; CIC_ROWS=""; return 1; }
    CIC_ROWS=$(_cic_gh checks --json bucket,name --jq '.[] | "\(.bucket)\t\(.name)"' 2>"$ef"); grc=$?
    CIC_ERR=$(tr '\n' ' ' < "$ef" | sed 's/ *$//')
    rm -f "$ef"
    if [ -n "$CIC_ROWS" ]; then CIC_ERR=""; return 0; fi
    [ -n "$CIC_ERR" ] && return 1
    # No rows and no stderr, yet gh died (a kill, a crash): an error, not "no checks".
    # gh's own 1 / 8 encode the rollup, so only a status above that is a death.
    if [ "$grc" -gt 8 ]; then CIC_ERR="gh pr checks exited $grc with no output"; return 1; fi
    return 0
}

_cic_is_rl() { printf '%s' "${1:-}" | grep -i -E 'rate limit|RATE_LIMITED|abuse detection|secondary rate' >/dev/null 2>&1; }

# _cic_budget_wait <force> — read the free rate_limit endpoint; when the
# graphql bucket is under the floor (or <force>=1 after a rate-limit error), sleep until the reset.
# rc 0 = fine / waited, 2 = the reset is beyond CIC_MAX_WAIT (nothing slept).
_cic_budget_wait() {
    local force="${1:-0}" floor="${CHECK_CI_API_FLOOR:-300}" jmax="${GH_BUDGET_JITTER_MAX:-15}"
    local out core_rem core_reset gql_rem gql_reset reset now wait_s jitter human max="${CIC_MAX_WAIT:-0}"
    local bucket=graphql rem bucket_reset
    local sleeper="${CIC_SLEEP_CMD:-sleep}"
    case "$floor" in ''|*[!0-9]*) floor=300 ;; esac
    case "$jmax" in ''|*[!0-9]*) jmax=15 ;; esac
    case "$max" in ''|*[!0-9]*) max=0 ;; esac
    [ "$floor" -eq 0 ] && [ "$force" != 1 ] && return 0
    if [ -n "$CIC_RUN_ID" ] && [ "${CIC_DEADLINE:-0}" -gt 0 ]; then
        max=$((CIC_DEADLINE - SECONDS))
        if [ "$max" -le 0 ]; then CIC_ERR="run budget deadline exhausted"; return 2; fi
    fi
    if [ -n "$CIC_RUN_ID" ]; then
        out=$(_cic_run_command gh api --hostname "${CIC_RUN_REPO%%/*}" rate_limit --jq '.resources | "\(.core.remaining) \(.core.reset) \(.graphql.remaining) \(.graphql.reset)"' 2>&1) || { CIC_ERR="cannot read REST core budget: $out"; return 2; }
    else
        out=$(gh api rate_limit --jq '.resources | "\(.core.remaining) \(.core.reset) \(.graphql.remaining) \(.graphql.reset)"' 2>/dev/null) || out=""
    fi
    # shellcheck disable=SC2086
    set -- $out
    core_rem="${1:-}"; core_reset="${2:-}"; gql_rem="${3:-}"; gql_reset="${4:-}"
    case "$core_rem$core_reset$gql_rem$gql_reset" in ''|*[!0-9]*) core_rem=""; gql_rem="" ;; esac
    now=$(cic_now)
    if [ -z "$core_rem" ] || [ -z "$gql_rem" ]; then
        if [ -n "$CIC_RUN_ID" ]; then CIC_ERR="cannot parse REST core budget"; return 2; fi
        # ponytail: an unreadable rate_limit reply means "proceed" for the pre-check (advisory,
        # fails open on cost only); after a 403 the wait is a flat 60 s. Upgrade: none needed.
        [ "$force" = 1 ] || return 0
        core_rem=0; gql_rem=0; core_reset=$((now + 60)); gql_reset=$((now + 60))
    fi
    reset=0
    # PR checks spend GraphQL; gh run view spends REST/core. Never wait on
    # the unused bucket (run mode does not rotate PR reads to REST).
    rem="$gql_rem"; bucket_reset="$gql_reset"
    if [ -n "$CIC_RUN_ID" ]; then bucket=core; rem="$core_rem"; bucket_reset="$core_reset"; fi
    if [ "$rem" -lt "$floor" ] && [ "$bucket_reset" -gt "$reset" ]; then reset=$bucket_reset; fi
    if [ "$reset" -eq 0 ]; then
        [ "$force" = 1 ] || return 0
        reset=$((now + 60))          # a 403 while the counters look healthy: back off a minute
    fi
    wait_s=$((reset - now + 2))
    [ "$wait_s" -lt 2 ] && wait_s=2
    human=$(date -u -d "@$reset" +%H:%M:%SZ 2>/dev/null || date -u -r "$reset" +%H:%M:%SZ 2>/dev/null || echo "epoch $reset")
    # The pre-check is advisory: with the reset beyond the bound, fetch and spend what is left
    # (as the legacy path does); only a real rate-limit error (force=1) refuses to proceed.
    if [ "$max" -gt 0 ] && [ "$wait_s" -gt "$max" ] && [ "$force" != 1 ]; then return 0; fi
    if [ "$max" -gt 0 ] && [ "$wait_s" -gt "$max" ]; then
        CIC_ERR="GitHub API budget low ($bucket=$rem, floor=$floor), resets at $human (in ${wait_s}s) — longer than the ${max}s bound; not waiting"
        echo "check-ci: $CIC_ERR" >&"${CIC_NOTICE_FD:-2}"
        return 2
    fi
    jitter=0
    [ "$jmax" -gt 0 ] && jitter=$((RANDOM % (jmax + 1)))
    if [ "$max" -gt 0 ] && [ $((wait_s + jitter)) -gt "$max" ]; then jitter=$((max - wait_s)); fi
    echo "check-ci: gh API budget low ($bucket=$rem, floor=$floor) — sleeping ${wait_s}s (+${jitter}s jitter) until the reset at $human" >&"${CIC_NOTICE_FD:-2}"
    "$sleeper" "$wait_s"
    [ "$jitter" -gt 0 ] && "$sleeper" "$jitter"
    return 0
}

# cic_get <ttl_s> — see the header.
cic_get() {
    local ttl="${1:-60}" rl_tries=0 brc rc head_after locked left
    CIC_ROWS=""; CIC_ERR=""
    if _cic_read "$ttl"; then return "$CIC_HIT_RC"; fi
    while :; do
        if [ -n "$CIC_RUN_ID" ] && [ "${CIC_DEADLINE:-0}" -gt 0 ]; then
            left=$((CIC_DEADLINE - SECONDS))
            if [ "$left" -le 0 ]; then CIC_ERR="run read deadline exhausted"; return 1; fi
            CIC_MAX_WAIT="$left"
        fi
        _cic_budget_wait 0; brc=$?
        [ "$brc" -eq 0 ] || return 2
        locked=0
        if _cic_lock; then
            locked=1
            # The waiter that lost the race finds the winner's entry now.
            if _cic_read "$ttl"; then cic_unlock; return "$CIC_HIT_RC"; fi
        fi
        if [ -n "$CIC_RUN_ID" ]; then _cic_fetch_run_raw; else _cic_fetch_raw; fi
        rc=$?
        if [ "$rc" -eq 1 ] && _cic_is_rl "$CIC_ERR"; then
            [ "$locked" -eq 1 ] && cic_unlock
            rl_tries=$((rl_tries + 1))
            [ "$rl_tries" -gt 3 ] && return 1
            _cic_budget_wait 1 || return 2
            continue
        fi
        if [ "$locked" -eq 1 ]; then
            if [ -n "$CIC_RUN_ID" ]; then head_after="$CIC_HEAD"; else head_after=$(_cic_head_now) || head_after=""; fi
            # Cache only what is provably the bound head's: a push mid-fetch
            # leaves the rows ambiguous, so they are returned but never stored.
            # An error is never cached: one waiter's failure (a network blip, a bad token)
            # must not become another waiter's exit 2.
            if [ "$head_after" = "$CIC_HEAD" ] && [ "$rc" -eq 0 ]; then _cic_write; fi
            cic_unlock
        fi
        return "$rc"
    done
}
