#!/usr/bin/env bash
# gh-graphql-budget.sh — shared GitHub GraphQL budget preflight (HIMMEL-3190).
#
# Sourced, never executed. bash 3.2-safe.
#
# WHY: the GraphQL budget (5000 points/hour, shared by every leg on the box)
# ran out fleet-wide twice in three hours because ~7 legs each held a
# `gh pr checks --watch` (~30 calls/min each). `gh api rate_limit` MISREPORTS
# it (REST core bucket) — the truth is the X-Ratelimit-* headers of a real
# `gh api -i graphql` call, which is what this reads. The probe query is
# `{rateLimit{remaining}}`: measured 0 points, one request.
#
#   ghb_wait_for_budget <max_wait_s> [sleep_cmd]
#     Reads the headers ONCE. Healthy (remaining >= floor) -> return 0 at
#     once. Exhausted -> sleep until X-Ratelimit-Reset (+ a small skew and a
#     per-process jitter, both through <sleep_cmd>, so hermetic suites inject
#     `:` and every leg does not wake in the same second) and return 0 with
#     GHB_WAITED=1. If the reset is further away than <max_wait_s> (0 =
#     unbounded) -> print why and return 1 without sleeping. Callers map rc 1
#     onto their own "cannot evaluate" code; no exit code changes meaning.
#
#   Call it ONCE at start and after a rate-limit error — never per poll round:
#   the preflight is itself a request.
#
# Env (all optional):
#   GH_BUDGET_FLOOR        remaining below this counts as exhausted (default 200)
#   GH_BUDGET_JITTER_MAX   max wake-up jitter seconds (default 15; 0 = none)
#   GH_BUDGET_PREFLIGHT=0  skip the call entirely (test harnesses that count gh calls)
#
# ponytail: an unreadable/absent header set means "proceed" — this preflight is
# advisory and fails OPEN. Nothing here is a gate: the caller's own gh calls
# still fail closed if the budget really is gone.

# shellcheck disable=SC2034  # GHB_* are the caller-facing results of the sourced helper
GHB_REMAINING=""
GHB_RESET=""
GHB_WAITED=0

# ghb_read — ONE real `gh api -i graphql` call. Sets GHB_REMAINING / GHB_RESET
# (epoch seconds). rc 0 = remaining parsed; rc 1 = headers unreadable.
# An exhausted budget makes gh exit non-zero yet still print the headers, so
# the exit status is ignored and only the headers are parsed.
ghb_read() {
    local out
    GHB_REMAINING=""
    GHB_RESET=""
    out=$(gh api -i graphql -f query='{rateLimit{remaining}}' 2>&1 | tr -d '\r') || true
    GHB_REMAINING=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="x-ratelimit-remaining" {print $2; exit}')
    GHB_RESET=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="x-ratelimit-reset" {print $2; exit}')
    case "$GHB_REMAINING" in ''|*[!0-9]*) GHB_REMAINING=""; GHB_RESET=""; return 1 ;; esac
    case "$GHB_RESET" in *[!0-9]*) GHB_RESET="" ;; esac
    return 0
}

# ghb_is_rate_limited <stderr text> — does a gh error read as budget exhaustion?
ghb_is_rate_limited() {
    printf '%s' "${1:-}" | grep -i -E 'rate limit|RATE_LIMITED|abuse detection|secondary rate' >/dev/null 2>&1
}

ghb_wait_for_budget() {
    local max_wait="${1:-0}" sleep_cmd="${2:-sleep}"
    local floor="${GH_BUDGET_FLOOR:-200}" jmax="${GH_BUDGET_JITTER_MAX:-15}"
    local now wait_s jitter human
    GHB_WAITED=0
    [ "${GH_BUDGET_PREFLIGHT:-1}" = 0 ] && return 0
    case "$max_wait" in ''|*[!0-9]*) max_wait=0 ;; esac
    case "$floor" in ''|*[!0-9]*) floor=200 ;; esac
    case "$jmax" in ''|*[!0-9]*) jmax=15 ;; esac

    ghb_read || return 0
    [ "$GHB_REMAINING" -ge "$floor" ] && return 0

    now=$(date +%s)
    if [ -n "$GHB_RESET" ]; then
        wait_s=$((GHB_RESET - now + 2))       # +2 s clock-skew margin
    else
        wait_s=60                             # exhausted, reset header missing
    fi
    [ "$wait_s" -lt 2 ] && wait_s=2

    human=$(date -d "@${GHB_RESET:-$((now + wait_s))}" +%H:%M:%S 2>/dev/null \
        || date -r "${GHB_RESET:-$((now + wait_s))}" +%H:%M:%S 2>/dev/null \
        || echo "epoch ${GHB_RESET:-?}")
    if [ "$max_wait" -gt 0 ] && [ "$wait_s" -gt "$max_wait" ]; then
        echo "gh-budget: GitHub GraphQL budget exhausted (remaining=$GHB_REMAINING, floor=$floor), resets at $human (in ${wait_s}s) — longer than the ${max_wait}s bound; not waiting" >&2
        return 1
    fi

    jitter=0
    [ "$jmax" -gt 0 ] && jitter=$((RANDOM % (jmax + 1)))
    # never let the jitter push the total past the caller's bound
    if [ "$max_wait" -gt 0 ] && [ $((wait_s + jitter)) -gt "$max_wait" ]; then
        jitter=$((max_wait - wait_s))
    fi

    echo "gh-budget: GitHub GraphQL budget exhausted (remaining=$GHB_REMAINING, floor=$floor); sleeping ${wait_s}s + ${jitter}s jitter until the reset at $human" >&2
    "$sleep_cmd" "$wait_s"
    [ "$jitter" -gt 0 ] && "$sleep_cmd" "$jitter"
    GHB_WAITED=1
    return 0
}
