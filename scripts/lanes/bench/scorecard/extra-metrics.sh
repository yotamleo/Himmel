#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/extra-metrics.sh - P0.1 scorecard recipe (HIMMEL-2977).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ plus jq and gh,
# both available under git bash unchanged; the transcripts it reads are the
# same JSONL on every platform.
#
# Adapted from the HIMMEL-2977 baseline Appendix B (extra-metrics.sh, leg
# N207, 2026-09-12):
#  (g) fix-forward/revert within 48h: merged PR B whose title ticket-id(s)
#      intersect an earlier merged PR A's, merged within 48h after A, or
#      whose title starts with "Revert".
#  (h) operator interventions: console transcripts, user entries whose
#      content is a plain string (not tool_result) and not a harness
#      envelope (<task-notification>, <cross-session...>, <system...>).
# The baseline's (g) fetched a fixed-window PR list and (h) read a
# precomputed burn.tsv for console transcripts; this takes --since/--until
# for the PR fetch and walks console-role transcripts directly for (h).
#
# Usage: extra-metrics.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>]
set -u

usage() { echo "usage: extra-metrics.sh --since <ISO8601> [--until <ISO8601>] [--repo <owner/repo>]" >&2; }

SINCE=""; UNTIL=""; REPO="yotamleo/Himmel"
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "extra-metrics: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

PROJECTS="${SCORECARD_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-home-overlord-Documents-github-himmel}"
[ -d "$PROJECTS" ] || { echo "extra-metrics: transcript root not found: $PROJECTS" >&2; exit 2; }
RUN=$(mktemp -d "${TMPDIR:-/tmp}/extra-metrics.XXXXXX")
trap 'rm -rf "$RUN"' EXIT

# GNU `date -d` first; BSD/macOS `date -j -f` fallback (same convention as
# leg-burn.sh's backdate()/transcript_mtime GNU-first/BSD-fallback comment).
to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "extra-metrics: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "extra-metrics: bad --until: $UNTIL" >&2; exit 2; }
fi
UNTIL_EPOCH_ARG="${UNTIL_EPOCH:-9999999999}"

# (g) fix-forward/revert within 48h, over the whole merged history so an
# in-window PR B can still be matched against an out-of-window earlier PR A.
gh pr list -R "$REPO" --state merged --limit 1000 --json number,title,mergedAt \
    --jq '.' > "$RUN/merged-titles.json" || { echo "extra-metrics: gh pr list failed" >&2; exit 1; }
merged_count=$(jq 'length' "$RUN/merged-titles.json" 2>/dev/null) || { echo "extra-metrics: could not parse gh pr list output" >&2; exit 1; }
if [ "${merged_count:-0}" -ge 1000 ]; then
    echo "extra-metrics: WARNING: gh pr list returned $merged_count merged PRs (== --limit 1000); older history may be truncated and followups_48h can miss matches" >&2
fi
jq -r --argjson since_epoch "$SINCE_EPOCH" --argjson until_epoch "$UNTIL_EPOCH_ARG" '
  def tix: [.title | scan("HIMMEL-[0-9]+")];
  def epoch: (.mergedAt | fromdateiso8601);
  . as $all
  | [ $all[] | select(epoch >= $since_epoch and epoch < $until_epoch) ] as $win
  | [ $win[] as $b
      | [ $all[] as $a
          | select($a.number != $b.number)
          | select(($b|epoch) > ($a|epoch) and ($b|epoch) - ($a|epoch) <= 172800)
          | select(([$a|tix[]] - ([$a|tix[]] - [$b|tix[]])) | length > 0)
          | $a.number ] as $hits
      | select(($hits|length) > 0 or ($b.title|test("^[Rr]evert")))
      | "#\($b.number) <- \($hits|map("#"+tostring)|join(",")) \($b.title[0:90])" ]
  | ("followups_48h=\(length) of window=\($win|length)"), .[]' "$RUN/merged-titles.json" \
    || { echo "extra-metrics: fix-forward/revert analysis failed" >&2; exit 1; }

echo "--- operator interventions (console transcripts, window)"
title_of() { grep -o '"customTitle":"[^"]*"' "$1" 2>/dev/null | tail -1 | sed 's/.*:"//; s/"$//'; }
ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | "$2" -1 | cut -d'"' -f4; }

find "$PROJECTS" -name '*.jsonl' -type f 2>/dev/null | while IFS= read -r f; do
    case "$f" in */subagents/*) continue ;; esac
    name=$(title_of "$f")
    case "$name" in *-console*) ;; *) continue ;; esac

    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || continue
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || continue
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || continue
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || continue
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then continue; fi

    jq -r --argjson since_epoch "$SINCE_EPOCH" --argjson until_epoch "$UNTIL_EPOCH_ARG" \
      'select(.type=="user" and (.isMeta|not) and (.isSidechain|not))
      | select(.timestamp != null)
      | select((.timestamp | fromdateiso8601) >= $since_epoch and (.timestamp | fromdateiso8601) < $until_epoch)
      | .message.content | select(type=="string")
      | select(test("^\\s*<(task-notification|cross-session|system-reminder|local-command|command-name|bash-|user-memory)")|not)
      | select(test("^This session is being continued")|not) | "1"' "$f" 2>/dev/null | wc -l
done | awk '{s+=$1; n++} END{printf "console_sessions=%d operator_msgs=%d per_session=%.1f\n", n, s, (n?s/n:0)}'
