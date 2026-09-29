#!/usr/bin/env bash
# api-budget.sh — one read-only line for a console (HIMMEL-3850):
#
#   gh-api: remaining=4321/5000 reset=14:05Z graphql=4954/5000
#
# remaining/reset = the REST core bucket; graphql = the GraphQL bucket (what
# `gh pr checks` and check-ci actually spend). Reads the `rate_limit` endpoint,
# which does not count against either bucket. rc 0 always prints a line;
# rc 1 + "gh-api: unavailable" when gh cannot answer.
#
# Wiring it into tick.sh is deliberately not done here (PR #1421 owns tick.sh).
set -uo pipefail

out=$(gh api rate_limit --jq '.resources | "\(.core.remaining) \(.core.reset) \(.graphql.remaining) \(.core.limit) \(.graphql.limit)"' 2>/dev/null) || out=""
# shellcheck disable=SC2086
set -- $out
case "${1:-}${2:-}${3:-}" in ''|*[!0-9]*) echo "gh-api: unavailable"; exit 1 ;; esac
rem="$1"; reset="$2"; gql="$3"; lim="${4:-5000}"; glim="${5:-5000}"
case "$lim" in ''|*[!0-9]*) lim=5000 ;; esac
case "$glim" in ''|*[!0-9]*) glim=5000 ;; esac
human=$(date -u -d "@$reset" +%H:%MZ 2>/dev/null || date -u -r "$reset" +%H:%MZ 2>/dev/null || echo "epoch$reset")
echo "gh-api: remaining=$rem/$lim reset=$human graphql=$gql/$glim"
