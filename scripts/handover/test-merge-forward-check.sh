#!/usr/bin/env bash
# scripts/handover/test-merge-forward-check.sh — HIMMEL-4114. Fixture-driven
# coverage of merge-forward-check.sh: ALLOW only a red inherited from the
# merge-base, failing the same cases, and fixed on latest main; a red the PR
# introduced never passes.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MF="${MF:-$HERE/merge-forward-check.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-forward-check.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '    got: %s\n' "$2"; fail=1; }

# a hook may export repo-location variables; they must not redirect the fixture's git calls
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

# a repo whose origin/main the script fetches and compares against --latest-sha
git init -q --bare -b main "$tmp/origin.git"
git init -q -b main "$tmp/work"
git -C "$tmp/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$tmp/work" remote add origin "$tmp/origin.git"
git -C "$tmp/work" push -q origin main 2>/dev/null
TIP="$(git -C "$tmp/work" rev-parse HEAD)"

# runraw <desc> <expected-rc> <expected-ere> [args] -- uses $tmp/{pr,base,latest,pr-cases,base-cases}
runraw() {
  local d="$1" want="$2" re="$3" out rc
  shift 3
  out=$(cd "$tmp/work" && bash "$MF" --pr "$tmp/pr" --main-base "$tmp/base" --main-latest "$tmp/latest" --pr-cases "$tmp/pr-cases" --base-cases "$tmp/base-cases" --main-base-conclusion failure "$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && grep -Eq -- "$re" <<< "$out"; then ok "$d"; else bad "$d (rc=$rc, want $want)" "$out"; fi
}
# run = runraw with valid sha flags; later flags in "$@" override these
run() { local d="$1" want="$2" re="$3" mb; shift 3; mb="$(git -C "$tmp/work" merge-base origin/main HEAD)"; runraw "$d" "$want" "$re" --base-sha "$mb" --main-base-sha "$mb" --latest-sha "$TIP" --pr-sha "$(git -C "$tmp/work" rev-parse HEAD)" "$@"; }
# set3 writes the three job files; each red row gets the one case `c1` in the case files
set3() {
  printf '%b' "$1" > "$tmp/pr"; printf '%b' "$2" > "$tmp/base"; printf '%b' "$3" > "$tmp/latest"
  awk -F'\t' '$2=="failure"||$2=="timed_out"||$2=="startup_failure" {print $1"\tc1"}' "$tmp/pr" > "$tmp/pr-cases"
  awk -F'\t' '$2=="failure"||$2=="timed_out"||$2=="startup_failure" {print $1"\tc1"}' "$tmp/base" > "$tmp/base-cases"
}

# the defect (HIMMEL-4114): green at base, red on the PR, green on latest = the PR's own red
set3 'shell-tests\tfailure\nlint\tsuccess\n' 'shell-tests\tsuccess\nlint\tsuccess\n' 'shell-tests\tsuccess\nlint\tsuccess\n'
run "green at base + red on PR + green on latest: REFUSE (the PR's own red)" 1 'REFUSE.*shell-tests.*not inherited'

set3 'shell-tests\tfailure\nlint\tsuccess\n' 'shell-tests\tfailure\nlint\tsuccess\n' 'shell-tests\tsuccess\nlint\tsuccess\n'
run "red at base + red on PR + green on latest: ALLOW" 0 'ALLOW.*shell-tests'

set3 'a\ttimed_out\n' 'a\tstartup_failure\n' 'a\tsuccess\n'
run "timed_out on PR, startup_failure at base, green on latest: ALLOW" 0 'ALLOW.*a'

set3 'a\tfailure\nb\tfailure\n' 'a\tfailure\nb\tsuccess\n' 'a\tsuccess\nb\tsuccess\n'
run "one of two reds green at base: REFUSE" 1 'REFUSE.*b.*not inherited'

set3 'a\tfailure\n' 'other\tfailure\n' 'a\tsuccess\n'
run "red job absent from the base run: REFUSE" 1 'REFUSE.*a.*absent'

set3 'a\tfailure\n' 'a\tfailure\n' 'other\tsuccess\n'
run "red job absent from the latest run: REFUSE" 1 'REFUSE.*a.*absent'

set3 'a\tfailure\n' 'a\tfailure\n' 'a\tfailure\n'
run "red on latest main too: REFUSE" 1 'REFUSE.*a.*not proven fixed'

set3 'a\tsuccess\nb\tskipped\n' 'a\tsuccess\n' 'a\tsuccess\n'
run "nothing red: no merge-forward needed" 3 'nothing red'

# HIMMEL-4113: awk skips a directory with rc 0, which would read as "nothing red"
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
rm -f "$tmp/pr"; mkdir "$tmp/pr"
run "PR job file is a directory (unparseable): usage, never 'nothing red'" 2 'usage'
rmdir "$tmp/pr"

# F1: the base run sha check is mandatory
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
run "base run sha differs from the merge-base: REFUSE" 1 'REFUSE.*merge-base' --base-sha abc123 --main-base-sha def456
runraw "no sha flags at all: usage, never ALLOW" 2 'usage'
runraw "empty --base-sha and --main-base-sha: usage, never ALLOW" 2 'usage' --base-sha '' --main-base-sha '' --latest-sha "$TIP"
runraw "--base-sha without --main-base-sha: usage" 2 'usage' --base-sha abc123 --latest-sha "$TIP"
runraw "--main-base-sha without --base-sha: usage" 2 'usage' --main-base-sha abc123 --latest-sha "$TIP"

# the stated base must be the real merge-base of origin/main and HEAD, not any equal pair
run "--base-sha and --main-base-sha agree but are not the merge-base: REFUSE" 1 'REFUSE.*not the merge-base' --base-sha abc123 --main-base-sha abc123

# the PR run must be the run of HEAD, not an older one that predates the PR's own red
run "--pr-sha is not HEAD: REFUSE (an older PR run)" 1 'REFUSE.*--pr run is for deadbeef' --pr-sha deadbeef
runraw "--pr-sha omitted: usage, never ALLOW" 2 'usage' --base-sha abc123 --main-base-sha abc123 --latest-sha "$TIP"
runraw "--pr-sha empty: usage, never ALLOW" 2 'usage' --base-sha abc123 --main-base-sha abc123 --latest-sha "$TIP" --pr-sha ''

# F3 (HIMMEL-5124): the latest run must be ON origin/main and at or after the verdict run;
# main CI is a cron, so it is usually behind the tip
runraw "--latest-sha omitted: usage, never ALLOW" 2 'usage' --base-sha abc123 --main-base-sha abc123
runraw "--latest-sha empty: usage, never ALLOW" 2 'usage' --base-sha abc123 --main-base-sha abc123 --latest-sha ''
run "--latest-sha is a full sha that is not a commit here: REFUSE (a foreign run posing as latest)" 1 'REFUSE.*not on origin/main' --latest-sha dddddddddddddddddddddddddddddddddddddddd
run "--latest-sha is a ref, not a 40-hex sha: usage (origin/main would always pass)" 2 'usage' --latest-sha origin/main
git -C "$tmp/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
git -C "$tmp/work" push -q origin main 2>/dev/null
run "latest run predates the merge-base: REFUSE (it proves nothing about the base being fixed)" 1 'REFUSE.*does not descend'
TIP="$(git -C "$tmp/work" rev-parse HEAD)"
run "--latest-sha equals the fetched origin/main: ALLOW" 0 'ALLOW'
run "ALLOW names the validated tip to merge, not a fresh origin/main" 0 "git merge $TIP"
# the cron world: origin/main moved on after the latest completed run, which still descends from the base
git clone -q "$tmp/origin.git" "$tmp/other"
git -C "$tmp/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m three
git -C "$tmp/other" push -q origin main 2>/dev/null
TIP3="$(git -C "$tmp/other" rev-parse HEAD)"
run "latest run is behind origin/main but descends from the merge-base: ALLOW, names the tip" 0 "ALLOW.*git merge $TIP3"
out=$(cd "$tmp" && bash "$MF" --pr "$tmp/pr" --main-base "$tmp/base" --main-latest "$tmp/latest" --pr-cases "$tmp/pr-cases" --base-cases "$tmp/base-cases" --base-sha a --main-base-sha a --latest-sha "$TIP" --pr-sha p --main-base-conclusion failure 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'cannot fetch origin main' <<< "$out"; then ok "outside a repo with origin/main: repo check fails, usage, never ALLOW"; else bad "outside a repo exits 2 on the fetch check (rc=$rc)" "$out"; fi

# F2: a shard that fails the base's case AND one of its own is the PR's own red
set3 'shard-3\tfailure\n' 'shard-3\tfailure\n' 'shard-3\tsuccess\n'
printf 'shard-3\tX\nshard-3\tY\n' > "$tmp/pr-cases"; printf 'shard-3\tX\n' > "$tmp/base-cases"
run "PR shard fails X (inherited) and Y (its own), base fails only X: REFUSE" 1 'REFUSE.*shard-3.*Y'
printf 'shard-3\tX\n' > "$tmp/pr-cases"
run "PR shard fails exactly the base's case: ALLOW" 0 'ALLOW.*shard-3'
printf 'shard-3\tX\n' > "$tmp/pr-cases"; printf 'shard-3\tX\nshard-3\tZ\n' > "$tmp/base-cases"
run "PR cases a subset of the base's (base fails more): ALLOW" 0 'ALLOW.*shard-3'
printf 'shard-3\tY\n' > "$tmp/pr-cases"; printf 'shard-3\tX\n' > "$tmp/base-cases"
run "PR fails a different case than the base: REFUSE" 1 'REFUSE.*shard-3.*Y'
: > "$tmp/pr-cases"
run "no failing case recorded for the red PR job: REFUSE" 1 'REFUSE.*shard-3.*no failing case'
printf 'shard-3\tX\n' > "$tmp/pr-cases"; printf 'other-shard\tX\n' > "$tmp/base-cases"
run "the base's case belongs to another job: REFUSE" 1 'REFUSE.*shard-3.*X'
printf 'shard-3\tX\nbroken\n' > "$tmp/pr-cases"
run "malformed PR case row: usage error, never ALLOW" 2 'malformed'
printf 'shard-3\tX\n' > "$tmp/pr-cases"; printf 'shard-3\t\n' > "$tmp/base-cases"
run "empty case name at base: usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
rm -f "$tmp/pr-cases"
run "PR case file missing: usage error, never ALLOW" 2 'usage'
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
rm -f "$tmp/base-cases"
run "base case file missing: usage error, never ALLOW" 2 'usage'

# awk -v would read a literal \101 as A: names must be compared as written
set3 'shard-3\tfailure\n' 'shard-3\tfailure\n' 'shard-3\tsuccess\n'
printf 'shard-3\t\\101\n' > "$tmp/pr-cases"; printf 'shard-3\tA\n' > "$tmp/base-cases"
run "PR case literal \\101 vs base case A: REFUSE (no escape processing)" 1 'REFUSE.*shard-3'
printf 'shard-3\t\\101\n' > "$tmp/pr-cases"; printf 'shard-3\t\\101\n' > "$tmp/base-cases"
run "PR case literal \\101 equal to the base's literal \\101: ALLOW" 0 'ALLOW.*shard-3'
printf 'j\\101\tfailure\n' > "$tmp/pr"; printf 'jA\tfailure\n' > "$tmp/base"; printf 'jA\tsuccess\nj\\101\tsuccess\n' > "$tmp/latest"
printf 'j\\101\tc1\n' > "$tmp/pr-cases"; printf 'jA\tc1\n' > "$tmp/base-cases"
run "PR job literal j\\101 vs base job jA: REFUSE (no escape processing)" 1 'REFUSE.*absent'

# numeric-looking names must compare as strings: case 01 is not case 1, job 01 is not job 1
set3 'shard-3\tfailure\n' 'shard-3\tfailure\n' 'shard-3\tsuccess\n'
printf 'shard-3\t01\n' > "$tmp/pr-cases"; printf 'shard-3\t1\n' > "$tmp/base-cases"
run "PR case 01 vs base case 1: REFUSE (string compare)" 1 'REFUSE.*shard-3.*01'
printf '01\tfailure\n' > "$tmp/pr"; printf '1\tfailure\n' > "$tmp/base"; printf '1\tsuccess\n01\tsuccess\n' > "$tmp/latest"
printf '01\tc1\n' > "$tmp/pr-cases"; printf '1\tc1\n' > "$tmp/base-cases"
run "PR job 01 vs base job 1: REFUSE (string compare)" 1 'REFUSE.*01'

# HIMMEL-4260: the merge-base run was cancelled (a newer merge replaced the pending
# sweep), so the verdict comes from the next completed sweep covering it. History
# P -- S -- C -- T on main: P the previous completed sweep, S the merge-base
# (cancelled run), C the covering sweep, T the tip; HEAD is a leg branch off S.
git init -q --bare -b main "$tmp/cov-origin.git"
git init -q -b main "$tmp/cov"
cc() { git -C "$tmp/cov" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; git -C "$tmp/cov" rev-parse HEAD; }
CP="$(cc p)"; CS="$(cc s)"; CC="$(cc c)"; CT="$(cc t)"
git -C "$tmp/cov" remote add origin "$tmp/cov-origin.git"
git -C "$tmp/cov" push -q origin main 2>/dev/null
git -C "$tmp/cov" checkout -q -b leg "$CS"
CH="$(cc leg)"
# runcov <desc> <rc> <ere> [args] -- the cov repo, valid sha flags for S and T
runcov() {
  local d="$1" want="$2" re="$3" out rc
  shift 3
  out=$(cd "$tmp/cov" && bash "$MF" --pr "$tmp/pr" --main-base "$tmp/base" --main-latest "$tmp/latest" --pr-cases "$tmp/pr-cases" --base-cases "$tmp/base-cases" --base-sha "$CS" --main-base-sha "$CS" --latest-sha "$CT" --pr-sha "$CH" --main-base-conclusion failure "$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && grep -Eq -- "$re" <<< "$out"; then ok "$d"; else bad "$d (rc=$rc, want $want)" "$out"; fi
}
# the cancelled exact run has 0 jobs; the covering sweep's jobs go in $tmp/cover
set3 'a\tfailure\n' '' 'a\tsuccess\n'
printf 'a\tfailure\n' > "$tmp/cover"; printf 'a\tc1\n' > "$tmp/base-cases"
runcov "cancelled merge-base run + red covering sweep (same case) + green latest: ALLOW, says so" 0 "ALLOW.*a.*covering main run at $CC.*no completed run" \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
printf 'a\tcancelled\n' > "$tmp/base"
runcov "merge-base run cancelled mid-flight (jobs cancelled) + red covering sweep: ALLOW" 0 "ALLOW.*covering main run" \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
: > "$tmp/base"
printf 'a\tsuccess\n' > "$tmp/cover"; : > "$tmp/base-cases"
runcov "cancelled merge-base run + GREEN covering sweep: REFUSE (the PR's own red)" 1 'REFUSE.*a.*not inherited' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
printf 'a\tfailure\n' > "$tmp/cover"; printf 'a\tc1\n' > "$tmp/base-cases"; printf 'a\tfailure\n' > "$tmp/latest"
runcov "cancelled merge-base run + red covering sweep + red latest: REFUSE" 1 'REFUSE.*a.*not proven fixed' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
printf 'a\tsuccess\n' > "$tmp/latest"
runcov "cancelled merge-base run, no covering sweep given: REFUSE" 1 'REFUSE.*no completed main run.*no completed run covering.*next cron or dispatch'
# HIMMEL-5124: main CI is a cron, so the latest completed run is behind the tip and the covering run may be it
runcov "latest run is the covering run, behind the tip: ALLOW" 0 "ALLOW.*covering main run at $CC" \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP" --latest-sha "$CC"
runcov "latest run resolves and descends from the base but is OFF origin/main (the leg's own commit): REFUSE" 1 'REFUSE.*not on origin/main' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP" --latest-sha "$CH"
runcov "latest run predates the covering run: REFUSE" 1 'REFUSE.*does not descend.*'"$CC" \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP" --latest-sha "$CS"
runcov "latest run predates the merge-base: REFUSE" 1 'REFUSE.*does not descend' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP" --latest-sha "$CP"
runcov "covering run range starts AT the merge-base (does not cover it): REFUSE" 1 'REFUSE.*does not cover' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CS"
runcov "covering run sha is before the merge-base: REFUSE" 1 'REFUSE.*does not cover' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CP" --base-cover-from "$CP"
runcov "covering run sha not on origin/main: REFUSE" 1 'REFUSE.*not on origin/main' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CH" --base-cover-from "$CP"
: > "$tmp/cover"
runcov "covering run was itself cancelled: REFUSE" 1 'REFUSE.*covering run.*cancelled' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
printf 'a\tfailure\n' > "$tmp/cover"
runcov "--base-cover without its shas: usage" 2 'usage' --base-cover "$tmp/cover" --base-cover-conclusion failure
runcov "--base-cover without --base-cover-conclusion: usage (a cancelled run's rows read as a red)" 2 'usage' \
  --base-cover "$tmp/cover" --base-cover-sha "$CC" --base-cover-from "$CP"
runcov "--main-base-conclusion omitted: usage, never ALLOW" 2 'usage' --main-base-conclusion ''
runcov "unknown run conclusion: usage" 2 'usage.*conclusion' --main-base-conclusion failed
# the range start is the merge-base under another spelling: (S, C] does not contain S
runcov "cover-from is a short sha of the merge-base: REFUSE" 1 'REFUSE.*does not cover' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "${CS:0:8}"
runcov "cover-from is S^0: REFUSE" 1 'REFUSE.*does not cover' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CS^0"
runcov "cover-from is HEAD~1 (resolves to the merge-base): REFUSE" 1 'REFUSE.*does not cover' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "HEAD~1"
runcov "cover-from does not resolve: REFUSE" 1 'REFUSE.*cannot resolve' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from nosuchref
runcov "cover-sha does not resolve: REFUSE" 1 'REFUSE.*cannot resolve' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha nosuchref --base-cover-from "$CP"
runcov "cover-sha given as origin/main: ALLOW names the resolved sha, not the ref" 0 "ALLOW.*covering main run at $CT.*range $CP\.\.$CT" \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha origin/main --base-cover-from "$CP"
# a non-regular file reads as empty, i.e. cancelled: it must never open the cover path
runcov "--main-base /dev/null with a cover: usage, not ALLOW" 2 'usage' \
  --main-base /dev/null --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
runcov "--main-base a directory with a cover: usage, not ALLOW" 2 'usage' \
  --main-base "$tmp" --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
runcov "--main-base a green run via process substitution: usage, not ALLOW" 2 'usage' \
  --main-base <(printf 'a\tsuccess\n') --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
runcov "--main-latest /dev/null: usage" 2 'usage' --main-latest /dev/null
runcov "--base-cover /dev/null: usage" 2 'usage' \
  --base-cover /dev/null --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
printf 'a\tfailure\n' > "$tmp/base"
runcov "merge-base run completed: its own verdict stands, a cover is a usage error" 2 'usage.*not cancelled' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
runcov "merge-base run completed red, no cover: ALLOW as before" 0 'ALLOW.*a'

# HIMMEL-5137: only success|failure are completed verdicts; none must come with an empty file
runcov "base conclusion none with NON-empty rows, no cover: REFUSE (rows contradict none)" 1 'REFUSE.*none' --main-base-conclusion none
runcov "base conclusion none with NON-empty rows + cover: REFUSE" 1 'REFUSE.*none' --main-base-conclusion none \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
for c in timed_out neutral stale skipped startup_failure action_required; do
  runcov "base conclusion $c with failure rows, no cover: REFUSE (not a completed verdict)" 1 "REFUSE.*$c" --main-base-conclusion "$c"
done
: > "$tmp/base"
runcov "base conclusion none with an EMPTY file + red cover: ALLOW (the honest no-run flow)" 0 'ALLOW.*covering main run' --main-base-conclusion none \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP"
runcov "cover conclusion none with rows: REFUSE (a nonexistent run is not a completed cover)" 1 'REFUSE.*none' \
  --base-cover "$tmp/cover" --base-cover-conclusion none --base-cover-sha "$CC" --base-cover-from "$CP"
for c in timed_out neutral stale skipped startup_failure action_required; do
  runcov "cover conclusion $c with failure rows: REFUSE (not a completed verdict)" 1 "REFUSE.*$c" \
    --base-cover "$tmp/cover" --base-cover-conclusion "$c" --base-cover-sha "$CC" --base-cover-from "$CP"
done
printf 'a\tfailure\n' > "$tmp/base"

# HIMMEL-5124 real-environment rows. The merge-base de9b2a8e8 (main after PR 2277) has NO CI run:
#   gh run list --commit de9b2a8e82ecdc393fa7b5619525ff80107f5b61 --json databaseId,event,conclusion  ->  []
# so --main-base is an empty file. Cover = job rows of run 38014176513 (main push 34d7d3d31, CI,
# real `gh run view --json jobs --jq '.jobs[]|[.name,.conclusion]|@tsv'` output) with a real
# `failure` row; latest = rows of run 38002387566 (main push 3b31ceaa5, all green).
cat > "$tmp/real-cover" <<'ROWS'
bun-suites (ubuntu-latest)	cancelled
bwk-awk-mktemp-gate	success
claude-startup	success
commit-lint	success
doc-invariants	success
git-env-scrub	cancelled
guard-corpus-full	skipped
guardrail-matrices	cancelled
jira-cli-smoke	success
lanes-and-trust-suites	cancelled
leak-classes	cancelled
lint	cancelled
node-suites (bitbucket)	cancelled
node-suites (ci-orchestrator)	cancelled
node-suites (himmel-bus, marketplace/plugins/himmel-bus, 24)	cancelled
node-suites (himmel-gh, plugins/himmel-gh)	success
node-suites (himmel-jira, plugins/himmel-jira)	cancelled
node-suites (himmel-run)	success
node-suites (jira)	cancelled
plugin-version-bump	skipped
secret-scan	success
security-scan	success
shell-unit-shard (ubuntu-latest, 1)	cancelled
shell-unit-shard (ubuntu-latest, 2)	cancelled
shell-unit-shard (ubuntu-latest, 3)	cancelled
shell-unit-shard (ubuntu-latest, 4)	cancelled
shell-unit-shard (ubuntu-latest, 5)	cancelled
shell-unit-shard (ubuntu-latest, 6)	cancelled
shell-unit-shard (ubuntu-latest, 7)	cancelled
shell-unit-shard (ubuntu-latest, 8)	cancelled
shell-unit (ubuntu-latest)	failure
unchecked-mktemp-range	skipped
ROWS
cat > "$tmp/real-latest" <<'ROWS'
lint	success
bwk-awk-mktemp-gate	success
guardrail-matrices	success
leak-classes	success
commit-lint	success
git-env-scrub	success
lanes-and-trust-suites	success
doc-invariants	success
bun-suites (ubuntu-latest)	success
claude-startup	success
security-scan	success
secret-scan	success
jira-cli-smoke	success
plugin-version-bump	skipped
unchecked-mktemp-range	skipped
guard-corpus-full	skipped
shell-unit (ubuntu-latest)	success
ROWS
printf 'shell-unit (ubuntu-latest)\tfailure\n' > "$tmp/pr"; printf 'shell-unit (ubuntu-latest)\tc1\n' > "$tmp/pr-cases"; printf 'shell-unit (ubuntu-latest)\tc1\n' > "$tmp/base-cases"
: > "$tmp/base"; cp "$tmp/real-cover" "$tmp/cover"; cp "$tmp/real-latest" "$tmp/latest"
# run 38014176513 has conclusion=cancelled: its only failure row is the aggregator failing because
# every shard was cancelled, so the rows alone read as a real red. The run conclusion is what refuses it.
runcov "real rows: the covering run's conclusion is cancelled though its rows show a failure: REFUSE" 1 'REFUSE.*covering run.*cancelled' \
  --base-cover "$tmp/cover" --base-cover-conclusion cancelled --base-cover-sha "$CC" --base-cover-from "$CP" --latest-sha "$CC"
runcov "real rows: the merge-base run's conclusion is cancelled though its rows show a failure, no cover: REFUSE" 1 'REFUSE.*cancelled' \
  --main-base "$tmp/cover" --main-base-conclusion cancelled
# a genuinely completed red main run: 37964772913 (conclusion failure)
cat > "$tmp/real-red" <<'ROWS'
lint	success
shell-unit-shard (ubuntu-latest, 6)	success
shell-unit-shard (ubuntu-latest, 7)	success
shell-unit-shard (ubuntu-latest, 8)	failure
unchecked-mktemp-range	skipped
guard-corpus-full	skipped
plugin-version-bump	skipped
shell-unit (ubuntu-latest)	failure
ROWS
cp "$tmp/real-red" "$tmp/cover"
runcov "real rows: no run at the merge-base, COMPLETED red covering run, green latest behind the tip: ALLOW" 0 'ALLOW.*shell-unit \(ubuntu-latest\).*covering main run' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP" --latest-sha "$CC"
printf 'lint\tfailure\n' > "$tmp/pr"; printf 'lint\tc1\n' > "$tmp/pr-cases"
runcov "real rows: PR red job was cancelled/green on the covering run: REFUSE (the PR's own red)" 1 'REFUSE.*lint.*not inherited' \
  --base-cover "$tmp/cover" --base-cover-conclusion failure --base-cover-sha "$CC" --base-cover-from "$CP" --latest-sha "$CC"

# input errors
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
rm -f "$tmp/base"
run "base file missing: usage error, never ALLOW" 2 'usage'
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
rm -f "$tmp/latest"
run "latest file missing: usage error, never ALLOW" 2 'usage'

# shellcheck source=../lib/timeout-bin.sh
. "$HERE/../lib/timeout-bin.sh"
if [ -n "$_TIMEOUT_BIN" ]; then
  "$_TIMEOUT_BIN" 5 bash "$MF" --pr "$tmp/pr" --main-base "$tmp/pr" --main-latest >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then ok "trailing --main-latest without a value exits 2 (no hang)"; else bad "trailing --main-latest without a value exits 2 (rc=$rc)"; fi
else
  echo "SKIP: trailing --main-latest no-hang row (no timeout binary)"
fi

# a malformed PR row must not be silently ignored (it could hide a red)
set3 'a\tfailure\nb failure\n' 'a\tfailure\nb\tfailure\n' 'a\tsuccess\nb\tsuccess\n'
run "malformed PR row (no tab): usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\nb\tfailure \n' 'a\tfailure\nb\tfailure\n' 'a\tsuccess\nb\tsuccess\n'
run "malformed conclusion (trailing space): usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\nb\tfailed\n' 'a\tfailure\nb\tfailure\n' 'a\tsuccess\nb\tsuccess\n'
run "unknown conclusion value: usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\tfailure\n'
run "malformed latest row (three fields): usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\n' 'a failure\n' 'a\tsuccess\n'
run "malformed base row (no tab): usage error, never REFUSE-by-accident" 2 'malformed'

# an empty job name must not hide a red as "nothing red"
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
printf '\tfailure\n' > "$tmp/pr"
run "PR row with an empty job name: usage error, never nothing-red" 2 'malformed'

# duplicate job names: one green row on latest must not hide a red one
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\na\tfailure\n'
run "duplicate job on latest, one row red: REFUSE" 1 'REFUSE.*a.*not proven fixed'
set3 'a\tfailure\n' 'a\tsuccess\na\tfailure\n' 'a\tsuccess\n'
run "duplicate job at base, one row red: inherited, ALLOW" 0 'ALLOW.*a'

bash "$MF" --pr "$tmp/pr" --main "$tmp/pr" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok "the old 2-file --main form is refused (exit 2)"; else bad "the old --main form exits 2 (rc=$rc)"; fi

[ "$fail" -eq 0 ] && echo "PASS: merge-forward-check" || echo "FAIL: merge-forward-check"
exit "$fail"
