#!/usr/bin/env bash
# scripts/handover/merge-forward-check.sh — HIMMEL-4114 (corrects HIMMEL-4112).
# Read-only decision for the leg preface's merge-forward rule. Invariant: a leg
# never merges, or merges forward past, a red its own change introduced.
# Merge-forward cures ONLY a red inherited from a broken base.
#
#   merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file>
#                          [--base-sha <sha> --main-base-sha <sha>]
#
# Each file is one run's job list, one `<job name><TAB><conclusion>` per line
# (e.g. from `gh run view <id> --json jobs`):
#   --pr           the PR's own CI run
#   --main-base    main's push run AT THE PR's MERGE-BASE commit
#   --main-latest  main's latest completed push run
# ALLOW only if EVERY red PR job is red on --main-base (so it was inherited)
# AND success on --main-latest (so main has since been fixed). Everything else
# REFUSES: a job missing from either main run, a job green at the base (that
# red is the PR's own), a job red on latest main.
# The job files carry no commit sha, so the caller proves the base run is the
# right one: pass --base-sha (`git merge-base origin/main HEAD`) and
# --main-base-sha (the base run's headSha from `gh run list --commit`); they
# must be equal. Passing one without the other is a usage error. Omitting both
# leaves the check to the caller (documented in docs/handover/leg-preface.md).
# Exit 0 = ALLOW  1 = REFUSE  2 = usage / unreadable input
#      3 = nothing red on the PR; no merge-forward needed
# Red = failure | timed_out | startup_failure.
# ponytail: inheritance is matched by job name, not by failing case, so a job that
# fails different tests on the base and the PR still reads as inherited. An ALLOW
# is therefore necessary, not sufficient: the leg must also show the PR's failed
# job fails the SAME case as the base run (docs/handover/leg-preface.md); upgrade
# path is a per-case comparison here if that ever bites.
set -uo pipefail
pr=""; base=""; latest=""; bsha=""; msha=""; bad=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || { bad=1; break; }; pr="$2"; shift 2 ;;
    --main-base) [ $# -ge 2 ] || { bad=1; break; }; base="$2"; shift 2 ;;
    --main-latest) [ $# -ge 2 ] || { bad=1; break; }; latest="$2"; shift 2 ;;
    --base-sha) [ $# -ge 2 ] || { bad=1; break; }; bsha="$2"; shift 2 ;;
    --main-base-sha) [ $# -ge 2 ] || { bad=1; break; }; msha="$2"; shift 2 ;;
    *) bad=1; break ;;
  esac
done
if [ "$bad" -eq 1 ] || [ ! -r "$pr" ] || [ ! -r "$base" ] || [ ! -r "$latest" ] \
   || { [ -n "$bsha" ] && [ -z "$msha" ]; } || { [ -z "$bsha" ] && [ -n "$msha" ]; }; then
  echo "usage: merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file> [--base-sha <sha> --main-base-sha <sha>]" >&2
  exit 2
fi
if [ -n "$bsha" ] && [ "$bsha" != "$msha" ]; then
  echo "REFUSE — the --main-base run is for $msha, not the PR's merge-base $bsha: it proves nothing about the base. Report BLOCKED; do not merge forward."
  exit 1
fi

if awk -F'\t' 'NF && (NF != 2 || $2 !~ /^(success|failure|cancelled|skipped|neutral|timed_out|startup_failure|action_required|stale)$/) {exit 1}' "$pr"; then :; else
  echo "usage: --pr file has a malformed row (want <job><TAB><conclusion>): a skipped row could hide a red" >&2
  exit 2
fi

reds="$(awk -F'\t' '$2=="failure"||$2=="timed_out"||$2=="startup_failure" {print $1}' "$pr")"
[ -n "$reds" ] || { echo "nothing red on the PR — no merge-forward needed"; exit 3; }

blocked=""
while IFS= read -r job; do
  # a job name may repeat: base counts if ANY row is red, latest only if EVERY row is success
  b="$(awk -F'\t' -v j="$job" '$1==j && ($2=="failure"||$2=="timed_out"||$2=="startup_failure") {print $2; f=1; exit} $1==j && !s {s=$2} END {if (!f && s) print s}' "$base")"
  l="$(awk -F'\t' -v j="$job" '$1==j && $2!="success" {print $2; f=1; exit} $1==j {s=1} END {if (!f && s) print "success"}' "$latest")"
  case "$b" in failure|timed_out|startup_failure) inherited=1 ;; *) inherited=0 ;; esac
  if [ "$inherited" -ne 1 ]; then
    blocked="${blocked:+$blocked, }$job (base: ${b:-absent} — not inherited, the PR's own red)"
  elif [ "$l" != "success" ]; then
    blocked="${blocked:+$blocked, }$job (latest main: ${l:-absent} — not proven fixed)"
  fi
done <<< "$reds"

if [ -n "$blocked" ]; then
  echo "REFUSE — red not proven inherited-and-fixed: $blocked. Report BLOCKED; do not merge forward."
  exit 1
fi
echo "ALLOW — every red job was red on the merge-base run and is green on latest main: $(paste -sd, - <<< "$reds" | sed 's/,/, /g'). One 'git fetch origin main' + 'git merge origin/main' (merge commit; never rebase or force-push), citing both main run ids in a Results bullet."
exit 0
