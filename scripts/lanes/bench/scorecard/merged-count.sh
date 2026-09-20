#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/merged-count.sh - merged-PR count for a
# [--since, --until) window (HIMMEL-3021).
#
# The public yotamleo/Himmel repo carries no work PRs merged before the
# 2026-09-09 private->public cutover (only dependabot + chore(propagate)
# snapshots) — those PRs live only in the archived private repo's offline
# bundle. A window whose --since is before the cutover therefore unions:
#   - the private bundle's first-parent squash-merge count
#     (`git log --first-parent ... | grep -cE '\(#[0-9]+\)$'`) for
#     [since, min(until, cutover))
#   - the public `gh pr list` count for [max(since, cutover), until),
#     excluding chore(propagate) and dependabot titles/authors
# A window whose --since is on/after the cutover is unchanged: the plain
# public count for [since, until), no exclusion, no bundle read.
#
# Platform guard: no .ps1 twin, by design, same as the rest of this
# directory — POSIX bash 3.2+ plus jq and gh.
#
# Usage: merged-count.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>] [--bundle <path>]
set -u

usage() { echo "usage: merged-count.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>] [--bundle <path>]" >&2; }

SINCE=""; UNTIL=""; REPO="yotamleo/Himmel"; BUNDLE_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        --bundle) BUNDLE_ARG="${2:?--bundle needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "merged-count: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

# HIMMEL-3021: private->public repo cutover. SCORECARD_CUTOVER overrides it
# for hermetic tests; production callers use the default.
CUTOVER="${SCORECARD_CUTOVER:-2026-09-09T09:30:00Z}"
BUNDLE="${BUNDLE_ARG:-${HIMMEL_PRIVATE_BUNDLE:-$HOME/.himmel/private-archive.bundle}}"
# The private bundle only ever holds yotamleo/Himmel's pre-cutover history; a
# straddling --since against any OTHER --repo must not pull it in.
ARCHIVE_REPO="yotamleo/Himmel"

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# ledger-metrics.sh's to_epoch()).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0  # gnu-ok: BSD/macOS fallback on the next line
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "merged-count: bad --since: $SINCE" >&2; exit 2; }
CUTOVER_EPOCH=$(to_epoch "$CUTOVER") || { echo "merged-count: bad cutover: $CUTOVER" >&2; exit 2; }
UNTIL_EPOCH=9999999999
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "merged-count: bad --until: $UNTIL" >&2; exit 2; }
fi

RUN=$(mktemp -d "${TMPDIR:-/tmp}/merged-count.XXXXXX") || { echo "merged-count: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$RUN"' EXIT

# $1=since_epoch $2=until_epoch $3=exclude propagate/dependabot (0/1)
fetch_public() {
    gh pr list -R "$REPO" --state merged --limit 1000 --json number,title,mergedAt,author \
        --jq '.' > "$RUN/public.json" || { echo "merged-count: gh pr list failed" >&2; exit 1; }
    pr_total=$(jq 'length' "$RUN/public.json" 2>/dev/null) || { echo "merged-count: could not parse gh pr list output" >&2; exit 1; }
    if [ "${pr_total:-0}" -ge 1000 ]; then
        echo "merged-count: WARNING: gh pr list returned $pr_total merged PRs (== --limit 1000); older history may be truncated" >&2
    fi
    # HIMMEL-3269: stdout is the bare count (callers capture it), so the coverage
    # of the PR list behind it goes to stderr.
    pr_win=$(jq --argjson s "$1" --argjson u "$2" '
      [.[] | select((.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $s and (.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $u)] | length' "$RUN/public.json") || return 1
    pr_count="$pr_win"
    if [ "$3" -eq 1 ]; then
        pr_count=$(jq --argjson s "$1" --argjson u "$2" '
          [.[] | select((.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $s and (.mergedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $u)
           | select((.title | test("^chore\\(propagate\\)")) | not)
           | select(((.author.login? // "") | test("dependabot"; "i")) | not)] | length' "$RUN/public.json") || return 1
    fi
    pr_trunc=no; [ "${pr_total:-0}" -ge 1000 ] && pr_trunc=yes
    echo "merged-count: coverage: prs discovered=$pr_total parsed=$pr_count skipped=$((pr_total - pr_count)) (out-of-window=$((pr_total - pr_win)) excluded=$((pr_win - pr_count)) limit=1000 truncated=$pr_trunc)" >&2
    echo "$pr_count"
}

if [ "$SINCE_EPOCH" -lt "$CUTOVER_EPOCH" ] && [ "$REPO" = "$ARCHIVE_REPO" ]; then
    [ -f "$BUNDLE" ] || { echo "merged-count: missing private bundle at $BUNDLE (straddling window: --since $SINCE is before the $CUTOVER cutover); set HIMMEL_PRIVATE_BUNDLE or restore the bundle" >&2; exit 2; }
    BUNDLE_UNTIL="$CUTOVER"
    [ "$UNTIL_EPOCH" -lt "$CUTOVER_EPOCH" ] && BUNDLE_UNTIL="$UNTIL"
    CLONE="$RUN/priv.git"
    git clone --bare -q "$BUNDLE" "$CLONE" 2>/dev/null || { echo "merged-count: could not clone private bundle $BUNDLE" >&2; exit 1; }
    bundle_log=$(git -C "$CLONE" log --first-parent --since="$SINCE" --until="$BUNDLE_UNTIL" --format=%s main 2>/dev/null) || { echo "merged-count: git log on private bundle failed" >&2; exit 1; }
    bundle_count=$(printf '%s\n' "$bundle_log" | grep -cE '\(#[0-9]+\)$')
    bundle_lines=$(printf '%s\n' "$bundle_log" | grep -c .)
    echo "merged-count: coverage: bundle-commits discovered=$bundle_lines parsed=$bundle_count skipped=$((bundle_lines - bundle_count)) (no-pr-suffix=$((bundle_lines - bundle_count)))" >&2
    public_count=$(fetch_public "$CUTOVER_EPOCH" "$UNTIL_EPOCH" 1) || { echo "merged-count: could not fetch public PR count" >&2; exit 1; }
    echo $((bundle_count + public_count))
else
    fetch_public "$SINCE_EPOCH" "$UNTIL_EPOCH" 0
fi
