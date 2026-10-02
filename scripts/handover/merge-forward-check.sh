#!/usr/bin/env bash
# scripts/handover/merge-forward-check.sh — HIMMEL-4112. Read-only decision for
# the leg preface's merge-forward rule: may a leg whose PR is red merge
# origin/main in without a console ruling?
#
#   merge-forward-check.sh --pr <file> --main <file>
#
# Each file is the job list of one run, one `<job name><TAB><conclusion>` per
# line (e.g. from `gh run view <id> --json jobs`). main = origin/main's latest
# push run.
# Exit 0 = ALLOW   every red PR job is `success` on main's run
#        1 = REFUSE a red PR job is also red on main, or missing from it
#        2 = usage / unreadable input
#        3 = nothing red on the PR; no merge-forward needed
# Red = failure | timed_out | startup_failure.
set -uo pipefail
pr=""; main=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || { pr=""; break; }; pr="$2"; shift 2 ;;
    --main) [ $# -ge 2 ] || { main=""; break; }; main="$2"; shift 2 ;;
    *) pr=""; break ;;
  esac
done
if [ ! -r "$pr" ] || [ ! -r "$main" ]; then
  echo "usage: merge-forward-check.sh --pr <file> --main <file>" >&2
  exit 2
fi

reds="$(awk -F'\t' '$2=="failure"||$2=="timed_out"||$2=="startup_failure" {print $1}' "$pr")"
[ -n "$reds" ] || { echo "nothing red on the PR — no merge-forward needed"; exit 3; }

blocked=""
while IFS= read -r job; do
  concl="$(awk -F'\t' -v j="$job" '$1==j {print $2; exit}' "$main")"
  [ "$concl" = "success" ] || blocked="${blocked:+$blocked, }$job (main: ${concl:-absent})"
done <<< "$reds"

if [ -n "$blocked" ]; then
  echo "REFUSE — red on main too, or unproven there: $blocked. Report BLOCKED; do not merge forward."
  exit 1
fi
echo "ALLOW — every red job is green on main: $(paste -sd, - <<< "$reds" | sed 's/,/, /g'). One 'git fetch origin main' + 'git merge origin/main' (merge commit; never rebase or force-push), citing the main run id in a Results bullet."
exit 0
