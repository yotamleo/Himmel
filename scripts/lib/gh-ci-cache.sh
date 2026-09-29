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
# count against any bucket) reads BOTH the core (REST) and graphql buckets; if
# either is under CHECK_CI_API_FLOOR the caller sleeps until the reset (bounded
# by CIC_MAX_WAIT) instead of spending the last calls. A rate-limit error from
# the fetch itself is waited out the same way and retried (max 3), never cached.
#
# Env (all optional):
#   CHECK_CI_CACHE_DIR       state dir (default $HOME/.himmel/state/ci-cache)
#   CHECK_CI_CACHE_ERR_TTL   how long a non-rate-limit error is cached (default 10)
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

# _cic_read <ttl> — a valid entry sets CIC_ROWS/CIC_ERR/CIC_HIT_RC (the fetch's
# own rc: 0 rows, 1 error) and returns 0; rc 1 = miss.
# Valid: same head as the bound one, and younger than <ttl> (an error entry is
# also capped at the short error TTL). A future-dated entry (clock skew) is a miss.
_cic_read() {
    local ttl="$1" line ts head rc now age lim
    [ -f "$CIC_FILE" ] || return 1
    IFS= read -r line < "$CIC_FILE" || return 1
    IFS=$'\t' read -r ts head rc <<EOF
$line
EOF
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    case "$rc" in 0|1) ;; *) return 1 ;; esac
    [ "$head" = "$CIC_HEAD" ] || return 1
    now=$(cic_now)
    age=$((now - ts))
    [ "$age" -ge 0 ] || return 1
    lim=$ttl
    if [ "$rc" = 1 ]; then
        local etl="${CHECK_CI_CACHE_ERR_TTL:-10}"
        case "$etl" in ''|*[!0-9]*) etl=10 ;; esac
        [ "$etl" -lt "$lim" ] && lim=$etl
    fi
    [ "$age" -lt "$lim" ] || return 1
    if [ "$rc" = 0 ]; then CIC_ROWS=$(sed 1d "$CIC_FILE"); CIC_ERR=""; else CIC_ERR=$(sed 1d "$CIC_FILE"); CIC_ROWS=""; fi
    CIC_HIT_RC=$rc
    return 0
}

# _cic_write <rc> — tmp-then-mv, so a reader never sees half an entry.
_cic_write() {
    local tmp="$CIC_FILE.$$.tmp"
    {
        printf '%s\t%s\t%s\n' "$(cic_now)" "$CIC_HEAD" "$1"
        if [ "$1" = 0 ]; then printf '%s\n' "$CIC_ROWS"; else printf '%s\n' "$CIC_ERR" | tr '\n' ' '; echo; fi
    } > "$tmp" 2>/dev/null
    mv -f "$tmp" "$CIC_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
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
    local waited=0 max t now
    max="${CHECK_CI_LOCK_WAIT:-30}"
    case "$max" in ''|*[!0-9]*) max=30 ;; esac
    max=$((max * 5))
    while ! mkdir "$CIC_LOCK" 2>/dev/null; do
        t=$(cat "$CIC_LOCK/t" 2>/dev/null); now=$(cic_now)
        # A lock older than 60 s belongs to a fetch that died: break it.
        case "$t" in ''|*[!0-9]*) ;; *) [ $((now - t)) -gt 60 ] && rm -rf "$CIC_LOCK" 2>/dev/null ;; esac
        waited=$((waited + 1))
        [ "$waited" -ge "$max" ] && return 1
        sleep 0.2
    done
    cic_now > "$CIC_LOCK/t" 2>/dev/null
    CIC_HELD=1
    return 0
}

# _cic_fetch_raw — ONE `gh pr checks --json` call. rc 0 = rows (possibly none),
# 1 = error text in CIC_ERR. gh's own exit status is ignored (it encodes the
# rollup); only the presence of rows / stderr decides.
_cic_fetch_raw() {
    local ef
    ef=$(mktemp "${TMPDIR:-/tmp}/cic-err.XXXXXX") || { CIC_ERR="mktemp failed"; CIC_ROWS=""; return 1; }
    CIC_ROWS=$(_cic_gh checks --json bucket,name --jq '.[] | "\(.bucket)\t\(.name)"' 2>"$ef")
    CIC_ERR=$(tr '\n' ' ' < "$ef" | sed 's/ *$//')
    rm -f "$ef"
    if [ -n "$CIC_ROWS" ]; then CIC_ERR=""; return 0; fi
    [ -n "$CIC_ERR" ] && return 1
    return 0
}

_cic_is_rl() { printf '%s' "${1:-}" | grep -i -E 'rate limit|RATE_LIMITED|abuse detection|secondary rate' >/dev/null 2>&1; }

# _cic_budget_wait <force> — read the free rate_limit endpoint; when core or
# graphql is under the floor (or <force>=1 after a rate-limit error), sleep until the reset.
# rc 0 = fine / waited, 2 = the reset is beyond CIC_MAX_WAIT (nothing slept).
_cic_budget_wait() {
    local force="${1:-0}" floor="${CHECK_CI_API_FLOOR:-300}" jmax="${GH_BUDGET_JITTER_MAX:-15}"
    local out core_rem core_reset gql_rem gql_reset reset now wait_s jitter human max="${CIC_MAX_WAIT:-0}"
    local sleeper="${CIC_SLEEP_CMD:-sleep}"
    case "$floor" in ''|*[!0-9]*) floor=300 ;; esac
    case "$jmax" in ''|*[!0-9]*) jmax=15 ;; esac
    case "$max" in ''|*[!0-9]*) max=0 ;; esac
    [ "$floor" -eq 0 ] && [ "$force" != 1 ] && return 0
    out=$(gh api rate_limit --jq '.resources | "\(.core.remaining) \(.core.reset) \(.graphql.remaining) \(.graphql.reset)"' 2>/dev/null) || out=""
    # shellcheck disable=SC2086
    set -- $out
    core_rem="${1:-}"; core_reset="${2:-}"; gql_rem="${3:-}"; gql_reset="${4:-}"
    case "$core_rem$core_reset$gql_rem$gql_reset" in ''|*[!0-9]*) core_rem=""; gql_rem="" ;; esac
    now=$(cic_now)
    if [ -z "$core_rem" ] || [ -z "$gql_rem" ]; then
        # ponytail: an unreadable rate_limit reply means "proceed" for the pre-check (advisory,
        # fails open on cost only); after a 403 the wait is a flat 60 s. Upgrade: none needed.
        [ "$force" = 1 ] || return 0
        core_rem=0; gql_rem=0; core_reset=$((now + 60)); gql_reset=$((now + 60))
    fi
    reset=0
    if [ "$core_rem" -lt "$floor" ] && [ "$core_reset" -gt "$reset" ]; then reset=$core_reset; fi
    if [ "$gql_rem" -lt "$floor" ] && [ "$gql_reset" -gt "$reset" ]; then reset=$gql_reset; fi
    if [ "$reset" -eq 0 ]; then
        [ "$force" = 1 ] || return 0
        reset=$((now + 60))          # a 403 while the counters look healthy: back off a minute
    fi
    wait_s=$((reset - now + 2))
    [ "$wait_s" -lt 2 ] && wait_s=2
    human=$(date -u -d "@$reset" +%H:%M:%SZ 2>/dev/null || date -u -r "$reset" +%H:%M:%SZ 2>/dev/null || echo "epoch $reset")
    if [ "$max" -gt 0 ] && [ "$wait_s" -gt "$max" ]; then
        CIC_ERR="GitHub API budget low (core=$core_rem graphql=$gql_rem, floor=$floor), resets at $human (in ${wait_s}s) — longer than the ${max}s bound; not waiting"
        echo "check-ci: $CIC_ERR" >&"${CIC_NOTICE_FD:-2}"
        return 2
    fi
    jitter=0
    [ "$jmax" -gt 0 ] && jitter=$((RANDOM % (jmax + 1)))
    if [ "$max" -gt 0 ] && [ $((wait_s + jitter)) -gt "$max" ]; then jitter=$((max - wait_s)); fi
    echo "check-ci: gh API budget low (core=$core_rem graphql=$gql_rem, floor=$floor) — sleeping ${wait_s}s (+${jitter}s jitter) until the reset at $human" >&"${CIC_NOTICE_FD:-2}"
    "$sleeper" "$wait_s"
    [ "$jitter" -gt 0 ] && "$sleeper" "$jitter"
    return 0
}

# cic_get <ttl_s> — see the header.
cic_get() {
    local ttl="${1:-60}" rl_tries=0 brc rc head_after locked
    CIC_ROWS=""; CIC_ERR=""
    if _cic_read "$ttl"; then return "$CIC_HIT_RC"; fi
    while :; do
        _cic_budget_wait 0; brc=$?
        [ "$brc" -eq 0 ] || return 2
        locked=0
        if _cic_lock; then
            locked=1
            # The waiter that lost the race finds the winner's entry now.
            if _cic_read "$ttl"; then cic_unlock; return "$CIC_HIT_RC"; fi
        fi
        _cic_fetch_raw; rc=$?
        if [ "$rc" -eq 1 ] && _cic_is_rl "$CIC_ERR"; then
            [ "$locked" -eq 1 ] && cic_unlock
            rl_tries=$((rl_tries + 1))
            [ "$rl_tries" -gt 3 ] && return 1
            _cic_budget_wait 1 || return 2
            continue
        fi
        if [ "$locked" -eq 1 ]; then
            head_after=$(_cic_head_now) || head_after=""
            # Cache only what is provably the bound head's: a push mid-fetch
            # leaves the rows ambiguous, so they are returned but never stored.
            if [ "$head_after" = "$CIC_HEAD" ]; then _cic_write "$rc"; fi
            cic_unlock
        fi
        return "$rc"
    done
}
