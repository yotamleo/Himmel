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
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$STUB/gh.log"
case "$*" in
  "api "*"/jobs"*)          cat "$STUB/jobs.tsv" 2>/dev/null ;;
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
  "issue list"*)            [ -e "$STUB/list_fail" ] && exit 1; cat "$STUB/open_issue" 2>/dev/null ;;
  "issue view"*)            cat "$STUB/issue_body" 2>/dev/null ;;
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

# 11. A CANCELLED sweep (operator cancel) is not main's health: the shell-unit
# aggregator runs under if: always() and fails on a cancelled rollup, but the
# run's own conclusion is `cancelled`, so no issue may be opened, edited or closed.
newcase cancelled-run
printf '%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cancelled https://github.com/o/r/actions/runs/900" > "$STUB/run.txt"
printf 'failure%sshell-unit\ncancelled%slint\nsuccess%sdoc-invariants\n' "$tab" "$tab" "$tab" > "$STUB/jobs.tsv"
sweep
if [ "$rc" -eq 0 ]; then ok "a cancelled run exits 0"; else bad "a cancelled run exits $rc: $out"; fi
hasnt "issue create" "$log" "a cancelled run with a failed aggregator opens no issue"
hasnt "issue edit" "$log" "a cancelled run edits no issue"
hasnt "issue comment" "$log" "a cancelled run comments on no issue"
hasnt "issue close" "$log" "a cancelled run closes no issue"
hasnt "issue list" "$log" "a cancelled run does not even look up the issue"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
