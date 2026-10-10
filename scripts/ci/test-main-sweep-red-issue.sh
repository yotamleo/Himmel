#!/usr/bin/env bash
# scripts/ci/test-main-sweep-red-issue.sh -- suite for
# scripts/ci/main-sweep-red-issue.sh (HIMMEL-3841 slice E / spec T3).
#
# A stub `gh` on PATH serves canned answers from a per-case stub dir and logs
# every invocation, so each case asserts the issue mutations the script chose:
# open, update in place, no false close, and close ONLY after a later sweep
# actually ran (and passed) every job recorded as failed. No network, no auth.
#
# Usage: bash scripts/ci/test-main-sweep-red-issue.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

# grepq <text> [grep-args...] -- `grep -q` over text with NO pipeline (this file
# runs under pipefail, where a pipe into `grep -q` can misreport via SIGPIPE).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/main-sweep-red-issue.sh"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
has()   { if grepq "$2" -e "$1"; then ok "$3"; else bad "$3; log: $2"; fi; }
hasnt() { if grepq "$2" -e "$1"; then bad "$3; log: $2"; else ok "$3"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/main-sweep-red.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# The stub. Answers by argument shape; the STUB dir names the canned files:
#   run.txt       "<sha> <conclusion> <url>"        (actions/runs/<id>)
#   jobs.tsv      "<conclusion>\t<job name>" lines   (actions/runs/<id>/jobs)
#   lastgreen     sha of the last green sweep        (workflows/ci.yml/runs)
#   range.txt     commit lines                       (compare/A...B)
#   open_issue    number of the open main-red issue  (issue list); absent = none
#   issue_body    that issue's body                  (issue view)
#   list_fail     if present, `issue list` exits 1
#   closed_issue  number of the newest CLOSED main-red issue (issue list --state closed)
#   closed_body   that issue's body (issue view <closed_issue>)
#   closed_list_fail  if present, only `issue list --state closed` exits 1
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$STUB/gh.log"
case "$*" in
  "api "*"/jobs"*)          cat "$STUB/jobs.tsv" 2>/dev/null ;;
  "api "*"/check-runs/"*"/annotations"*)
    id="${2#*/check-runs/}"; id="${id%%/*}"; cat "$STUB/ann-$id" 2>/dev/null ;;
  "api "*"/compare/"*)      cat "$STUB/range.txt" 2>/dev/null ;;
  "api "*"/workflows/ci.yml/runs"*)
    if [ -e "$STUB/runs.json" ]; then
      # Apply the caller's real --jq filter to a canned runs list (the filter is the unit under test).
      f=""; prev=""
      for a in "$@"; do [ "$prev" = "--jq" ] && f="$a"; prev="$a"; done
      jq -r "$f" "$STUB/runs.json"
    else
      cat "$STUB/lastgreen" 2>/dev/null
    fi ;;
  "api "*"/actions/runs/"*) cat "$STUB/run.txt" ;;
  "issue list"*"--state closed"*) [ -e "$STUB/closed_list_fail" ] && exit 1; cat "$STUB/closed_issue" 2>/dev/null ;;
  "issue list"*)            [ -e "$STUB/list_fail" ] && exit 1; cat "$STUB/open_issue" 2>/dev/null ;;
  "issue view"*)
    if [ -e "$STUB/closed_body_$3" ]; then cat "$STUB/closed_body_$3"
    elif [ -e "$STUB/closed_issue" ] && [ "$3" = "$(head -n 1 "$STUB/closed_issue")" ]; then cat "$STUB/closed_body" 2>/dev/null
    else cat "$STUB/issue_body" 2>/dev/null; fi ;;
  "issue create"*|"issue edit"*|"issue comment"*|"issue close"*|"label create"*) : ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 99 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"

# newcase <name> -> sets STUB to a fresh dir seeded with a red-run default.
newcase() {
  STUB="$TMP/$1"; mkdir -p "$STUB"; export STUB
  printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa failure https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
  printf '%s\n' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$STUB/lastgreen"
  printf '%s\n' "abc123456 feat(x): [HIMMEL-1] one" "def123456 fix(y): [HIMMEL-2] two" > "$STUB/range.txt"
  : > "$STUB/gh.log"
}
sweep() { # -> $out $rc, log in $log
  out="$(PATH="$BIN:$PATH" GITHUB_REPOSITORY=o/r bash "$SCRIPT" 900 2>&1)"; rc=$?
  log="$(cat "$STUB/gh.log")"
}

tab="$(printf '\t')"

# 0. Syntax + usage.
if [ -f "$SCRIPT" ] && bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "script missing or syntax error"; fi
PATH="$BIN:$PATH" bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no args -> exit 2"; else bad "no args exit=$rc (expected 2)"; fi

# 1. Red sweep, no open issue -> ONE create, carrying sha, run url and range.
newcase red-open
printf 'success%sbun-suites (ubuntu-latest)\nfailure%slint\nfailure%sshell-unit-shard (ubuntu-latest, 3)\nfailure%sshell-unit (ubuntu-latest)\n' "$tab" "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
sweep
if [ "$rc" -eq 0 ]; then ok "red/no-issue exits 0"; else bad "red/no-issue exit=$rc; out: $out"; fi
has "gh issue create" "$log" "red/no-issue -> creates the issue"
has "--label main-red" "$log" "created with the main-red label"
hasnt "gh issue edit" "$log" "red/no-issue does not edit"
hasnt "gh issue close" "$log" "red never closes"
n_create="$(grep -c 'gh issue create' "$STUB/gh.log")"
if [ "$n_create" -eq 1 ]; then ok "exactly one issue created"; else bad "created $n_create issues"; fi
# The body file is removed by the script; the stub can't read it, so the body
# is asserted through the script's own echo of what it filed.
has "tested sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$out" "report names the tested sha"
has "since last green: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$out" "report names the range since the last green sweep"
has "abc123456 feat(x)" "$out" "report lists the commits in the range"
has "failed: lint" "$out" "report lists a failed job"
has "failed: shell-unit (ubuntu-latest)" "$out" "the aggregator stands for the shards"
hasnt "failed: shell-unit-shard" "$out" "individual shard jobs are collapsed into the aggregator"
hasnt "failed: bun-suites" "$out" "a passing job is not reported failed"

# 2. Red sweep, open issue #7 -> edit + comment in place, never a second issue.
newcase red-update
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
has "gh issue edit 7" "$log" "red/existing -> edits #7 in place"
has "gh issue comment 7" "$log" "red/existing -> adds a still-red comment"
hasnt "gh issue create" "$log" "red/existing never opens a duplicate"
hasnt "gh issue close" "$log" "red/existing never closes"

# 3. Green sweep that RAN AND PASSED the recorded failed job -> close.
newcase green-close
printf 'success%slint\nsuccess%sshell-unit (ubuntu-latest)\n' "$tab" "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'body\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
has "gh issue comment 7" "$log" "green after a passing rerun -> comments"
has "gh issue close 7" "$log" "green sweep that ran the failed job -> closes #7"

# 4. NO FALSE CLOSE: a green sweep in which the recorded failed job did not run
#    (skipped / absent / cancelled) must leave the issue open.
newcase green-no-close-skipped
printf 'success%sshell-unit (ubuntu-latest)\nskipped%slint\n' "$tab" "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'body\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
hasnt "gh issue close" "$log" "green sweep where the failed job was SKIPPED does not close"
newcase green-no-close-absent
printf 'success%sshell-unit (ubuntu-latest)\n' "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'body\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
hasnt "gh issue close" "$log" "green sweep where the failed job is ABSENT does not close"
newcase green-no-close-cancelled
printf 'cancelled%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cancelled https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'body\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
hasnt "gh issue close" "$log" "cancelled job does not close"
hasnt "gh issue create" "$log" "cancelled job does not open a new issue"

# 5. An issue with no recorded failed set (opened by hand) is never auto-closed.
newcase green-no-marker
printf 'success%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'a hand-written issue\n' > "$STUB/issue_body"
sweep
hasnt "gh issue close" "$log" "issue with no recorded failed set is never auto-closed"

# 6. A superseded pending run (cancelled, 0 jobs) is a no-op: no mutation at all.
newcase empty-run
: > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cancelled https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'body\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
if [ "$rc" -eq 0 ]; then ok "0-job run exits 0"; else bad "0-job run exit=$rc"; fi
hasnt "gh issue \(create\|edit\|comment\|close\)" "$log" "0-job run makes no issue mutation"

# 7. Partial clear while still red: a job that now passes drops out of the
#    recorded set, one still failing stays, a new failure joins.
newcase partial
printf 'success%slint\nfailure%ssecret-scan\n' "$tab" "$tab" > "$STUB/jobs.tsv"
printf '7\n' > "$STUB/open_issue"
printf 'body\n<!-- main-red-failed: lint -->\n<!-- main-red-failed: leak-classes -->\n' > "$STUB/issue_body"
sweep
has "failed: secret-scan" "$out" "new failure joins the set"
has "failed: leak-classes" "$out" "a recorded job that did not run stays in the set"
hasnt "failed: lint" "$out" "a recorded job that now passed leaves the set"

# 8. Lookup failure is never read as "no issue": bail without a duplicate.
newcase lookup-fail
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
: > "$STUB/list_fail"
sweep
if [ "$rc" -eq 1 ]; then ok "red + lookup failure -> exit 1"; else bad "red + lookup failure exit=$rc"; fi
hasnt "gh issue create" "$log" "lookup failure never opens a duplicate"

# 9. Last-green unknown: still opens the issue, states the range is unknown.
newcase no-lastgreen
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
: > "$STUB/lastgreen"
sweep
has "gh issue create" "$log" "no earlier green sweep -> still opens the issue"
has "since last green: unknown" "$out" "range is reported unknown, not invented"

# 10. Last green is the newest green sweep EARLIER than the reported run: a
# delayed reporter for run 900 must not anchor its range on a newer green 950.
if command -v jq >/dev/null 2>&1; then
  newcase earlier-green
  printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
  printf '%s\n' '{"workflow_runs":[{"id":950,"head_sha":"cccccccccccccccccccccccccccccccccccccccc"},{"id":800,"head_sha":"dddddddddddddddddddddddddddddddddddddddd"}]}' > "$STUB/runs.json"
  sweep
  has "since last green: dddddddddddddddddddddddddddddddddddddddd" "$out" "range anchors on the newest green sweep before the reported run"
  if grep -q 'cccccccccccccccccccccccccccccccccccccccc' <<< "$out"; then bad "range anchored on a NEWER green sweep (950 > 900)"; else ok "a newer green sweep is never the range anchor"; fi
else
  ok "SKIP earlier-green case (jq not installed)"
fi

# 11. An operator cancel of a sweep where no job ran (every job `cancelled`, no
# timeout note) is not main's health: no issue may be opened, edited or closed.
newcase cancelled-run
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cancelled https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf 'cancelled%sshell-unit%s11\ncancelled%slint%s12\ncancelled%sdoc-invariants%s13\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
sweep
if [ "$rc" -eq 0 ]; then ok "a cancelled run exits 0"; else bad "a cancelled run exits $rc: $out"; fi
hasnt "issue create" "$log" "a cancelled run with a failed aggregator opens no issue"
hasnt "issue edit" "$log" "a cancelled run edits no issue"
hasnt "issue comment" "$log" "a cancelled run comments on no issue"
hasnt "issue close" "$log" "a cancelled run closes no issue"
hasnt "issue list" "$log" "a cancelled run does not even look up the issue"

# 12. One red shard plus siblings cancelled by fail-fast: the RUN concludes
# `failure`, so it must read as red (an issue opens), never as a cancelled no-op.
newcase failfast-red
printf 'failure%sshell-unit-shard (ubuntu-latest, 3)\ncancelled%sshell-unit-shard (ubuntu-latest, 4)\ncancelled%sshell-unit-shard (ubuntu-latest, 5)\nfailure%sshell-unit (ubuntu-latest)\n' "$tab" "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
sweep
if [ "$rc" -eq 0 ]; then ok "fail-fast red run exits 0"; else bad "fail-fast red run exits $rc: $out"; fi
has "gh issue create" "$log" "a failed run with cancelled sibling shards opens the issue"
has "failed: shell-unit (ubuntu-latest)" "$out" "the aggregator is reported failed"
hasnt "failed: shell-unit-shard (ubuntu-latest, 4)" "$out" "a cancelled sibling is not reported as the failure"

# 13. GitHub reports the RUN as `cancelled` when one job hits timeout-minutes, even
# with a failed aggregator beside it: that must open the issue. A cancelled non-shard
# job whose check-run note says it exceeded the maximum execution time is red too.
newcase timeout-cancelled-run
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cancelled https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf 'cancelled%sshell-unit-shard (ubuntu-latest, 2)%s21\nfailure%sshell-unit (ubuntu-latest)%s22\ncancelled%slint%s23\ncancelled%sdoc-invariants%s24\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
printf 'The job running on runner X has exceeded the maximum execution time of 25 minutes.\n' > "$STUB/ann-23"
sweep
if [ "$rc" -eq 0 ]; then ok "timed-out cancelled run exits 0"; else bad "timed-out cancelled run exits $rc: $out"; fi
has "gh issue create" "$log" "a cancelled run with a timed-out shard and failed aggregator opens the issue"
has "failed: shell-unit (ubuntu-latest)" "$out" "the failed aggregator is reported"
has "failed: lint" "$out" "a timed-out non-shard job is reported failed"
hasnt "failed: doc-invariants" "$out" "a plain cancelled job (no timeout note) is not reported failed"

# 14. HIMMEL-5113: main has no push runs, so the range anchor is the newest earlier
# green non-PR run on main, and a pull_request run whose head branch is named
# `main` (a fork) is never the anchor.
if command -v jq >/dev/null 2>&1; then
  newcase cron-anchor
  printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
  printf '%s\n' '{"workflow_runs":[{"id":850,"event":"pull_request","head_sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},{"id":800,"event":"schedule","head_sha":"dddddddddddddddddddddddddddddddddddddddd"}]}' > "$STUB/runs.json"
  sweep
  has "since last green: dddddddddddddddddddddddddddddddddddddddd" "$out" "range anchors on the newest earlier cron run, not a PR run"
  hasnt "event=push" "$log" "the range lookup no longer filters on event=push"
else
  ok "SKIP cron-anchor case (jq not installed)"
fi

# 15. The nightly is also swept now: its windows legs (continue-on-error by
# design) and the schedule-only guard-corpus-full job are not main's health.
newcase nightly-only-jobs
printf 'failure%sshell-unit (windows-latest)\nfailure%sbun-suites (windows-latest)\nfailure%sguard-corpus-full\nsuccess%sshell-unit (ubuntu-latest)\n' "$tab" "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
sweep
if [ "$rc" -eq 0 ]; then ok "nightly-only reds exit 0"; else bad "nightly-only reds exit=$rc; out: $out"; fi
hasnt "gh issue create" "$log" "a red windows leg / guard-corpus-full opens no main-red issue"

# 16. HIMMEL-5113 judge R1: the nightly (any `(windows-latest` job, or a
# non-skipped guard-corpus-full) runs the tier=all shell-unit, whose extended-only
# reds are not main's fast-sweep health and go to shell-extended-nightly-issue.sh.
# A red nightly opens nothing; a green nightly never closes an open main-red.
newcase nightly-red
printf 'success%sbun-suites (windows-latest)\nsuccess%sguard-corpus-full\nfailure%sshell-unit (ubuntu-latest)\n' "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
sweep
if [ "$rc" -eq 0 ]; then ok "red nightly exits 0"; else bad "red nightly exit=$rc; out: $out"; fi
hasnt "gh issue create" "$log" "a red nightly (tier=all shell-unit) opens no main-red issue"

newcase nightly-green-open
printf 'success%sbun-suites (windows-latest)\nsuccess%sshell-unit (ubuntu-latest)\nsuccess%slint\n' "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-failed: shell-unit (ubuntu-latest) -->\n' > "$STUB/issue_body"
sweep
hasnt "gh issue close" "$log" "a green nightly never closes an open main-red issue"
hasnt "gh issue comment" "$log" "a green nightly never touches the issue"

newcase nightly-red-open
printf 'failure%sshell-unit (ubuntu-latest)\nsuccess%sguard-corpus-full\n' "$tab" "$tab" > "$STUB/jobs.tsv"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
hasnt "gh issue edit" "$log" "a red nightly does not refresh an open issue"

# A guard-corpus-full that was SKIPPED (the main sweep) does not make a run the
# nightly; the filed body records the run id for the ordering guard below.
newcase sweep-skipped-corpus
printf 'skipped%sguard-corpus-full\nfailure%sshell-unit (ubuntu-latest)\n' "$tab" "$tab" > "$STUB/jobs.tsv"
sweep
has "gh issue create" "$log" "a red sweep with a skipped guard-corpus-full still opens the issue"
has "main-red-run: 900" "$out" "the report records the run id marker"

# 17. HIMMEL-5113 judge R1b: an older run finishing late never closes or
# refreshes a newer red (marker run id compared numerically).
newcase order-older-green
printf 'success%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-run: 950 -->\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
hasnt "gh issue close" "$log" "an older green run does not close a newer red"
hasnt "gh issue comment" "$log" "an older run does not touch the issue"

newcase order-older-red
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-run: 950 -->\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
hasnt "gh issue edit" "$log" "an older red run does not overwrite a newer report"

newcase order-newer-green
printf 'success%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-run: 800 -->\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
has "gh issue close 7" "$log" "a newer green run closes the older red"

# 18. HIMMEL-5129: a newer green sweep CLOSED the issue before an older red
# sweep finished. The close stamps its run id; the older red run must find that
# marker on the newest closed issue and open nothing.
newcase closed-newer-green
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '6\n' > "$STUB/closed_issue"
printf 'old body\n<!-- main-red-run: 800 -->\n<!-- main-red-failed: lint -->\n\n<!-- main-red-closed-run: 950 -->\n' > "$STUB/closed_body"
sweep
if [ "$rc" -eq 0 ]; then ok "older red after a newer close exits 0"; else bad "older red after a newer close exit=$rc; out: $out"; fi
hasnt "gh issue create" "$log" "an older red run does not reopen a report a newer green closed"

newcase closed-older-green
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '6\n' > "$STUB/closed_issue"
printf 'old body\n<!-- main-red-run: 700 -->\n<!-- main-red-closed-run: 800 -->\n' > "$STUB/closed_body"
sweep
has "gh issue create" "$log" "a red run newer than the closing run still opens the issue"

# A hand-closed issue has no closed-run marker; its last red run still orders.
newcase closed-by-hand-newer
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '6\n' > "$STUB/closed_issue"
printf 'body\n<!-- main-red-run: 950 -->\n<!-- main-red-failed: lint -->\n' > "$STUB/closed_body"
sweep
hasnt "gh issue create" "$log" "an older red run does not reopen over a hand-closed newer report"

# A real closed report from before the markers existed (yotamleo/Himmel#2262,
# fetched verbatim) carries neither marker, so it never blocks a new red.
newcase closed-real-premarker
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '2262\n' > "$STUB/closed_issue"
cat > "$STUB/closed_body" <<'REAL'
**Automated main-red report** -- maintained in place by main-sweep-red.yml. Do not open duplicates; this issue is refreshed each completed push-to-main sweep and is closed automatically only after a later sweep runs and passes every job listed below.

Policy (CI red triage): a green merge followed by a red main means **fix main**. Find the owning PR from the range below and bisect by the failed jobs.

- tested sha: f343c0e266336aee395f2612d8f62ca3b927528f
- sweep: https://github.com/yotamleo/Himmel/actions/runs/37964772913
- last red sweep: 2026-10-09 18:25 UTC
- since last green: a1c73a992bd541e611a63ae8d639748ffc30d651

Failed jobs (still unresolved):
- failed: shell-unit (ubuntu-latest)

<!-- main-red-failed: shell-unit (ubuntu-latest) -->
REAL
sweep
has "gh issue create" "$log" "a pre-marker closed report does not block a new red"

# The closed-issue lookup failing is never read as "no closed issue".
newcase closed-lookup-fail
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
: > "$STUB/closed_list_fail"
sweep
if [ "$rc" -eq 1 ]; then ok "red + closed lookup failure -> exit 1"; else bad "red + closed lookup failure exit=$rc"; fi
hasnt "gh issue create" "$log" "closed lookup failure never opens a report"

# The close itself records the closing run id (and edits before it closes).
newcase close-records-run
printf 'success%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'body\n<!-- main-red-run: 800 -->\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
has "main-red-closed-run: 900" "$out" "the close records the closing run id in the body"
has "gh issue edit 7" "$log" "the close edits the body"
has "gh issue close 7" "$log" "the close still closes"

# A closed-issue listing is by CREATION order, so the newest-created report need
# not hold the newest marker. #9 (newest created) is old; #6 holds run 950.
newcase closed-two-order-differs
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '9\n6\n' > "$STUB/closed_issue"
printf 'b\n<!-- main-red-run: 700 -->\n<!-- main-red-closed-run: 750 -->\n' > "$STUB/closed_body_9"
printf 'b\n<!-- main-red-run: 800 -->\n<!-- main-red-closed-run: 950 -->\n' > "$STUB/closed_body_6"
sweep
hasnt "gh issue create" "$log" "the highest marker across closed reports wins, not the newest-created"

newcase closed-two-all-older
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '9\n6\n' > "$STUB/closed_issue"
printf 'b\n<!-- main-red-closed-run: 750 -->\n' > "$STUB/closed_body_9"
printf 'b\n<!-- main-red-closed-run: 800 -->\n' > "$STUB/closed_body_6"
sweep
has "gh issue create" "$log" "every closed report older than this run still opens the issue"

# 19. HIMMEL-5129: a re-run of the SAME run id (ordering guard is strict -gt)
# must refresh the open issue, not be ignored as older.
newcase order-equal-red
printf 'failure%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-run: 900 -->\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
has "gh issue edit 7" "$log" "a re-run of the same run id refreshes the issue"

newcase order-equal-green
printf 'success%slint\n' "$tab" > "$STUB/jobs.tsv"
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa success https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf '7\n' > "$STUB/open_issue"
printf 'old body\n<!-- main-red-run: 900 -->\n<!-- main-red-failed: lint -->\n' > "$STUB/issue_body"
sweep
has "gh issue close 7" "$log" "a green re-run of the same run id still closes"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
