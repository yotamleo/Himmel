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
#
# Each metric is followed by a `coverage:` line (HIMMEL-3269): `coverage: prs
# ...` for the PR list, `coverage: roots=R discovered=D parsed=P skipped=K
# (reason=n ...)` for the transcripts. SCORECARD_PROJECTS_DIR is an explicit
# one-root scope; the default is the primary dir plus its worktree siblings
# (lib/scorecard-lib.sh).
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

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"
sc_roots_check extra-metrics || exit 2
RUN=""
# trap first: a later mktemp failing must not leak what is already created
trap 'rm -rf "$RUN" "$SC_COV"' EXIT
RUN=$(mktemp -d "${TMPDIR:-/tmp}/extra-metrics.XXXXXX") || { echo "extra-metrics: mktemp failed" >&2; exit 1; }
sc_cov_init || exit 1

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
# the PR input's coverage: every fetched PR is parsed (a bad mergedAt fails the
# jq above and exits 1), so the one way this input is silently incomplete is the
# --limit cut - name it beside the number
pr_truncated=no; [ "${merged_count:-0}" -ge 1000 ] && pr_truncated=yes
echo "coverage: prs discovered=${merged_count:-0} parsed=${merged_count:-0} skipped=0 (limit=1000 truncated=$pr_truncated)"

echo "--- operator interventions (console transcripts, window)"
ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | "$2" -1 | cut -d'"' -f4; }

OP_FAILS="$RUN/op-fails.txt"
: > "$OP_FAILS"
OP_COUNTS="$RUN/op-counts.txt"
: > "$OP_COUNTS"
FILES="$RUN/files.txt"
DISC_ERR="$RUN/disc-err.txt"

# A discovery error must not vanish (the agg-burn.sh HIMMEL-2977 rule): the old
# `find 2>/dev/null | while` lost find's errors and status, so a partial input
# set printed as a complete one.
if ! sc_discover "$FILES" "$DISC_ERR"; then
    echo "extra-metrics: transcript discovery failed under the transcript root(s) - refusing to print a partial count:" >&2
    cat "$DISC_ERR" >&2
    exit 1
fi

while IFS= read -r f; do
    case "$f" in */subagents/*) sc_cov subagent; continue ;; esac
    name=$(title_of "$f")
    case "$name" in *-console*) ;; *) sc_cov not-console; continue ;; esac

    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || { sc_cov no-timestamp; continue; }
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || { sc_cov bad-timestamp; continue; }
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || { sc_cov bad-timestamp; continue; }
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || { sc_cov out-of-window; continue; }
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then sc_cov out-of-window; continue; fi

    op_out=$(jq -r --argjson since_epoch "$SINCE_EPOCH" --argjson until_epoch "$UNTIL_EPOCH_ARG" \
      'select(.type=="user" and (.isMeta|not) and (.isSidechain|not))
      | select(.timestamp != null)
      | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since_epoch and (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $until_epoch)
      | .message.content | select(type=="string")
      | select(test("^\\s*<(task-notification|cross-session|system-reminder|local-command|command-name|bash-|user-memory)")|not)
      | select(test("^This session is being continued")|not) | "1"' "$f" 2>/dev/null) || { echo "$f" >> "$OP_FAILS"; sc_cov jq-failed; continue; }
    sc_cov parsed
    printf '%s\n' "$op_out" | grep -c . >> "$OP_COUNTS"
done < "$FILES"
awk '{s+=$1; n++} END{printf "console_sessions=%d operator_msgs=%d per_session=%.1f\n", n, s, (n?s/n:0)}' "$OP_COUNTS"
sc_cov_line "$(wc -l < "$FILES" | tr -d ' ')" "$SC_ROOT_COUNT"

n_op_fail=$(wc -l < "$OP_FAILS")
if [ "$n_op_fail" -gt 0 ]; then
    echo "extra-metrics: WARNING: $n_op_fail transcript(s) skipped due to jq failure in operator-intervention count" >&2
fi
