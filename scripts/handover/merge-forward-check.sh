#!/usr/bin/env bash
# scripts/handover/merge-forward-check.sh — HIMMEL-4114 (corrects HIMMEL-4112).
# Read-only decision for the leg preface's merge-forward rule. Invariant: a leg
# never merges, or merges forward past, a red its own change introduced.
# Merge-forward cures ONLY a red inherited from a broken base.
#
#   merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file>
#                          --pr-cases <file> --base-cases <file>
#                          --base-sha <sha> --main-base-sha <sha> --latest-sha <sha>
#                          --pr-sha <sha>
#                          [--base-cover <file> --base-cover-sha <sha> --base-cover-from <sha>]
#
# Each job file is one run's job list, one `<job name><TAB><conclusion>` per line
# (e.g. from `gh run view <id> --json jobs`):
#   --pr           the PR's own CI run
#   --main-base    main's push run AT THE PR's MERGE-BASE commit
#   --main-latest  main's latest completed push run
# Each case file lists the failing cases of a run, one `<job><TAB><case>` per
# line, read from the failed-job logs:
#   --pr-cases     the PR run's failing cases      --base-cases  the base run's
# ALLOW only if EVERY red PR job is red on --main-base (so it was inherited),
# every failing case of that PR job is among the base run's failing cases for
# the same job (a PR shard runs only the impacted suites and main shards run the
# full sweep, so a matching job name alone proves nothing: an extra failing case
# is the PR's own red), AND the job is success on --main-latest (so main has
# since been fixed). Everything else REFUSES: a job missing from either main run,
# a job green at the base, a job red on latest main, a PR job with no recorded
# failing case or with a case the base run did not fail.
# The job files carry no commit sha, so the shas are REQUIRED and non-empty:
# --base-sha must equal `git merge-base origin/main HEAD` (computed here, after a
# fetch, from the leg's own repo) and --main-base-sha (the base run's headSha
# from `gh run list --commit`); --latest-sha (the latest run's headSha) must equal
# `git rev-parse origin/main`, so an older run cannot stand in for the base or
# for latest. --pr-sha (the PR run's headSha) must equal `git rev-parse HEAD`, so an
# older PR run cannot stand in for the current head.
# Exit 0 = ALLOW  1 = REFUSE  2 = usage / unreadable input
#      3 = nothing red on the PR; no merge-forward needed
# Red = failure | timed_out | startup_failure.
# HIMMEL-4260: ci.yml's serialised push concurrency replaces a pending main sweep
# with a 0-job cancelled run, so when --main-base is a cancelled run the base
# verdict comes from the next completed push sweep covering the merge-base — the
# same contiguous-range attribution main-sweep-red uses: --base-cover-from (the
# previous completed sweep's headSha) must be a strict ancestor of the merge-base,
# the merge-base an ancestor of --base-cover-sha, and that sha on origin/main;
# --base-cases are then the covering sweep's failing cases. Without the trio
# (--base-cover, --base-cover-sha, --base-cover-from) a cancelled base REFUSEs.
# ponytail: the case lists are extracted from logs by the caller and taken as
# given, so a wrong list can still mislead; upgrade path is parsing the failed
# job logs here if that ever bites.
# ponytail: the script cannot see whether another completed sweep lies inside
# (from, cover], so "next" is taken from the caller; upgrade path is listing the
# push runs with gh here if a wrong cover ever bites.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$SCRIPT_DIR/../lib/git-clean.sh"
git_env_scrub
# a run with no job rows, or only cancelled/skipped rows and at least one cancelled, was cancelled (a superseded pending sweep has 0 jobs)
is_cancelled() { awk -F'\t' 'NF {n++} NF && $2=="cancelled" {c++} NF && $2!="cancelled" && $2!="skipped" {o=1} END {exit !(n==0 || (!o && c))}' "$1"; }
pr=""; base=""; latest=""; prc=""; bc=""; bsha=""; msha=""; lsha=""; psha=""; cover=""; csha=""; cfrom=""; bad=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || { bad=1; break; }; pr="$2"; shift 2 ;;
    --main-base) [ $# -ge 2 ] || { bad=1; break; }; base="$2"; shift 2 ;;
    --main-latest) [ $# -ge 2 ] || { bad=1; break; }; latest="$2"; shift 2 ;;
    --pr-cases) [ $# -ge 2 ] || { bad=1; break; }; prc="$2"; shift 2 ;;
    --base-cases) [ $# -ge 2 ] || { bad=1; break; }; bc="$2"; shift 2 ;;
    --base-sha) [ $# -ge 2 ] || { bad=1; break; }; bsha="$2"; shift 2 ;;
    --main-base-sha) [ $# -ge 2 ] || { bad=1; break; }; msha="$2"; shift 2 ;;
    --latest-sha) [ $# -ge 2 ] || { bad=1; break; }; lsha="$2"; shift 2 ;;
    --pr-sha) [ $# -ge 2 ] || { bad=1; break; }; psha="$2"; shift 2 ;;
    --base-cover) [ $# -ge 2 ] || { bad=1; break; }; cover="$2"; shift 2 ;;
    --base-cover-sha) [ $# -ge 2 ] || { bad=1; break; }; csha="$2"; shift 2 ;;
    --base-cover-from) [ $# -ge 2 ] || { bad=1; break; }; cfrom="$2"; shift 2 ;;
    *) bad=1; break ;;
  esac
done
if [ "$bad" -eq 1 ] || [ ! -f "$pr" ] || [ ! -r "$pr" ] || [ ! -f "$base" ] || [ ! -r "$base" ] || [ ! -f "$latest" ] || [ ! -r "$latest" ] \
   || [ ! -r "$prc" ] || [ ! -r "$bc" ] || [ -z "$bsha" ] || [ -z "$msha" ] || [ -z "$lsha" ] || [ -z "$psha" ]; then
  echo "usage: merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file> --pr-cases <file> --base-cases <file> --base-sha <sha> --main-base-sha <sha> --latest-sha <sha> --pr-sha <sha> [--base-cover <file> --base-cover-sha <sha> --base-cover-from <sha>] (all but the --base-cover trio required, shas non-empty)" >&2
  exit 2
fi
if [ -n "$cover$csha$cfrom" ] && { [ ! -f "$cover" ] || [ ! -r "$cover" ] || [ -z "$csha" ] || [ -z "$cfrom" ]; }; then
  echo "usage: merge-forward-check.sh --pr <file> --main-base <file> --main-latest <file> --pr-cases <file> --base-cases <file> --base-sha <sha> --main-base-sha <sha> --latest-sha <sha> --pr-sha <sha> [--base-cover <file> --base-cover-sha <sha> --base-cover-from <sha>] (all but the --base-cover trio required, shas non-empty; the trio is all-or-none)" >&2
  exit 2
fi
if [ "$bsha" != "$msha" ]; then
  echo "REFUSE — the --main-base run is for $msha, not the PR's merge-base $bsha: it proves nothing about the base. Report BLOCKED; do not merge forward."
  exit 1
fi

for f in "$pr" "$base" "$latest" ${cover:+"$cover"}; do
  if awk -F'\t' 'NF && (NF != 2 || $1 == "" || $2 !~ /^(success|failure|cancelled|skipped|neutral|timed_out|startup_failure|action_required|stale)$/) {exit 1}' "$f"; then :; else
    echo "usage: $f has a malformed row (want <job><TAB><conclusion>): a skipped or misread row could hide a red" >&2
    exit 2
  fi
done
for f in "$prc" "$bc"; do
  if awk -F'\t' 'NF && (NF != 2 || $1 == "" || $2 == "") {exit 1}' "$f"; then :; else
    echo "usage: $f has a malformed row (want <job><TAB><case>): a misread case could hide the PR's own red" >&2
    exit 2
  fi
done

# a parse failure here must not read as "nothing red": it is an input error
if ! reds="$(awk -F'\t' '$2=="failure"||$2=="timed_out"||$2=="startup_failure" {print $1}' "$pr")"; then
  echo "usage: cannot parse $pr: a failed read must not pass as nothing red" >&2
  exit 2
fi
[ -n "$reds" ] || { echo "nothing red on the PR — no merge-forward needed"; exit 3; }

if ! git fetch --quiet origin main 2>/dev/null || ! tip="$(git rev-parse --verify --quiet origin/main)"; then
  echo "usage: cannot fetch origin main from $(pwd): the --latest-sha check needs the leg's own repo" >&2
  exit 2
fi
if [ "$lsha" != "$tip" ]; then
  echo "REFUSE — the --main-latest run is for $lsha, but origin/main is $tip: an older run is not latest main. Fetch the newest completed push run; do not merge forward."
  exit 1
fi

if ! mb="$(git merge-base origin/main HEAD 2>/dev/null)"; then
  echo "usage: cannot compute the merge-base of origin/main and HEAD in $(pwd)" >&2
  exit 2
fi
if [ "$bsha" != "$mb" ]; then
  echo "REFUSE — --base-sha $bsha is not the merge-base of origin/main and HEAD ($mb): the base run must be the one at the real merge-base. Report BLOCKED; do not merge forward."
  exit 1
fi

if ! head="$(git rev-parse --verify --quiet HEAD)"; then
  echo "usage: cannot resolve HEAD in $(pwd)" >&2
  exit 2
fi
if [ "$psha" != "$head" ]; then
  echo "REFUSE — the --pr run is for $psha, but HEAD is $head: an older PR run proves nothing about the current head. Wait for the run of HEAD; do not merge forward."
  exit 1
fi

base_note=""
if is_cancelled "$base"; then
  if [ -z "$cover" ]; then
    echo "REFUSE — the merge-base run at $bsha was cancelled and no completed sweep covering it was given (--base-cover, --base-cover-sha, --base-cover-from): a cancelled run proves nothing about the base. Report BLOCKED; do not merge forward."
    exit 1
  fi
  if is_cancelled "$cover"; then
    echo "REFUSE — the covering sweep at $csha was cancelled too: it proves nothing about the base. Use the next COMPLETED push sweep; do not merge forward."
    exit 1
  fi
  # resolve both range ends to full shas: --is-ancestor is reflexive, so a short sha, S^0 or HEAD~1
  # naming the merge-base must not slip past a string compare; the ALLOW line names the resolved sha too
  if ! rcsha="$(git rev-parse --verify --quiet "$csha^{commit}")" || ! rcfrom="$(git rev-parse --verify --quiet "$cfrom^{commit}")"; then
    echo "REFUSE — cannot resolve --base-cover-sha $csha or --base-cover-from $cfrom to a commit: a covering range that cannot be read proves nothing. Do not merge forward."
    exit 1
  fi
  if ! git merge-base --is-ancestor "$rcsha" "$tip" 2>/dev/null; then
    echo "REFUSE — the covering sweep at $rcsha is not on origin/main ($tip): only a main push sweep can stand in for the base. Do not merge forward."
    exit 1
  fi
  if [ "$rcfrom" = "$bsha" ] || ! git merge-base --is-ancestor "$rcfrom" "$bsha" 2>/dev/null || ! git merge-base --is-ancestor "$bsha" "$rcsha" 2>/dev/null; then
    echo "REFUSE — the covering sweep's range ($rcfrom, $rcsha] does not cover the merge-base $bsha: it is not the next completed sweep after the cancelled run. Do not merge forward."
    exit 1
  fi
  base="$cover"
  base_note=" — base verdict from the next completed covering sweep at $rcsha (range $rcfrom..$rcsha), since the merge-base run at $bsha was cancelled"
elif [ -n "$cover" ]; then
  echo "usage: the merge-base run at $bsha is not cancelled: its own verdict stands; drop --base-cover" >&2
  exit 2
fi

blocked=""
while IFS= read -r job; do
  # a job name may repeat: base counts if ANY row is red, latest only if EVERY row is success
  b="$(J="$job" awk -F'\t' '($1 "")==(ENVIRON["J"] "") && ($2=="failure"||$2=="timed_out"||$2=="startup_failure") {print $2; f=1; exit} ($1 "")==(ENVIRON["J"] "") && !s {s=$2} END {if (!f && s) print s}' "$base")"
  l="$(J="$job" awk -F'\t' '($1 "")==(ENVIRON["J"] "") && $2!="success" {print $2; f=1; exit} ($1 "")==(ENVIRON["J"] "") {s=1} END {if (!f && s) print "success"}' "$latest")"
  case "$b" in failure|timed_out|startup_failure) inherited=1 ;; *) inherited=0 ;; esac
  if [ "$inherited" -ne 1 ]; then
    blocked="${blocked:+$blocked, }$job (base: ${b:-absent} — not inherited, the PR's own red)"
    continue
  elif [ "$l" != "success" ]; then
    blocked="${blocked:+$blocked, }$job (latest main: ${l:-absent} — not proven fixed)"
    continue
  fi
  pcases="$(J="$job" awk -F'\t' '($1 "")==(ENVIRON["J"] "") {print $2}' "$prc")"
  if [ -z "$pcases" ]; then
    blocked="${blocked:+$blocked, }$job (no failing case recorded for the PR's job — cannot prove it inherited)"
    continue
  fi
  extra=""
  while IFS= read -r c; do
    J="$job" C="$c" awk -F'\t' '($1 "")==(ENVIRON["J"] "") && ($2 "")==(ENVIRON["C"] "") {f=1} END {exit !f}' "$bc" || extra="${extra:+$extra; }$c"
  done <<< "$pcases"
  if [ -n "$extra" ]; then
    blocked="${blocked:+$blocked, }$job (failing case not failing at the base: $extra — the PR's own red)"
  fi
done <<< "$reds"

if [ -n "$blocked" ]; then
  echo "REFUSE — red not proven inherited-and-fixed: $blocked$base_note. Report BLOCKED; do not merge forward."
  exit 1
fi
echo "ALLOW — every red job was red on the merge-base run with the same failing cases and is green on latest main: $(paste -sd, - <<< "$reds" | sed 's/,/, /g')$base_note. One 'git merge $tip' (the origin/main tip just validated and fetched; never 'origin/main' again, it may have moved; merge commit; never rebase or force-push), citing both main run ids in a Results bullet."
exit 0
