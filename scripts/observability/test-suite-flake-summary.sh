#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# scripts/observability/test-suite-flake-summary.sh —HIMMEL-5131: the reader
# that surfaces suite-flake ledger rows (written by scripts/ci/run-shell-tests.sh).
#
#   R1  tick format counts this repo's flake rows since the cutoff, with the
#       top suite and its repeat count; other repos, legacy rows (no repo id),
#       non-flake rows, malformed lines and rows before the cutoff are skipped
#   R2  no matching rows reads none; an absent ledger reads none; a ledger
#       that is not a readable file reads ?
#   R3  counts format is "<n><TAB><suite>", most-flaked first, inside --days
#   R4  detail format carries suite, case, sha, run and the suite's repeat count
#   R5  the id the reader derives equals the id the runner writes (drift guard)
#   R6  only the last SUITE_FLAKE_TAIL_ROWS lines are read (bounded)
#
# Usage: bash scripts/observability/test-suite-flake-summary.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/suite-flake-summary.sh"
REPO="$(cd "$HERE/../.." && pwd)"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want [$3] got [$2]"; fi; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/sfs.XXXXXX") || exit 1
trap 'rm -rf "$SB"' EXIT
NOW=1800000000
row() { # <ts> <repo> <suite> <case> [kind]
  printf '{"v":1,"ts":%s,"host":"h","source":"run-shell-tests","kind":"%s","suite":"%s","repo":"%s","case":"%s","rc":1,"sha":"abc123","run":"77"}\n' \
    "$1" "${5:-flake}" "$3" "$2" "$4"
}
L="$SB/ledger.jsonl"
{
  row $((NOW - 100)) repo-a test-x.sh 'not ok 1 - one'
  row $((NOW - 200)) repo-a test-x.sh 'not ok 2 - two'
  row $((NOW - 300)) repo-a test-y.sh 'not ok 1 - y'
  row $((NOW - 100)) repo-b test-x.sh 'other repo'
  row $((NOW - 100)) repo-a test-z.sh 'not a flake' other
  printf '{"v":1,"ts":%s,"suite":"test-legacy.sh","kind":"flake"}\n' $((NOW - 100))
  printf 'this is not json\n'
  printf '{"v":1,"ts":"nope","kind":"flake","repo":"repo-a","suite":"test-bad.sh"}\n'
  row $((NOW - 90000)) repo-a test-old.sh 'old row'
} > "$L"
run() { SUITE_FLAKE_LEDGER="$L" SUITE_FLAKE_REPO_ID=repo-a bash "$SUT" --now "$NOW" "$@" 2>/dev/null; }

echo "== R1: tick format =="
eq "R1: 3 rows / 2 suites / top test-x.sh*2 since the cutoff" "$(run --since $((NOW - 1000)) --format tick)" "3/2@test-x.sh*2"
eq "R1: the window widens to include the old row" "$(run --days 2 --format tick)" "4/3@test-x.sh*2"

echo "== R2: none and ? =="
eq "R2: nothing after the cutoff reads none" "$(run --since $((NOW + 1)) --format tick)" "none"
eq "R2: an absent ledger reads none" "$(SUITE_FLAKE_LEDGER="$SB/absent.jsonl" SUITE_FLAKE_REPO_ID=repo-a bash "$SUT" --now "$NOW" --days 1 --format tick 2>/dev/null)" "none"
mkdir "$SB/adir"
eq "R2: a directory in place of the ledger reads ?" "$(SUITE_FLAKE_LEDGER="$SB/adir" SUITE_FLAKE_REPO_ID=repo-a bash "$SUT" --now "$NOW" --days 1 --format tick 2>/dev/null)" "?"

echo "== R3: counts =="
eq "R3: counts, most-flaked first" "$(run --days 1 --format counts | tr '\t\n' ' ;')" "2 test-x.sh;1 test-y.sh;"

echo "== R4: detail =="
d=$(run --days 1 --format detail | head -n 1)
case "$d" in
  *test-x.sh*'not ok 1 - one'*abc123*77*'x2'*) pass "R4: detail row carries suite, case, sha, run and repeat count" ;;
  *) fail "R4: got [$d]" ;;
esac

echo "== R5: id drift guard =="
rs="$SB/rs"; mkdir -p "$rs/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$rs/scripts/test-pass.sh"
printf '#!/usr/bin/env bash\nc="$(dirname "$0")/n"; n=$(cat "$c" 2>/dev/null || echo 0); echo $((n+1)) > "$c"\n[ "$n" -ge 1 ] || { echo "not ok 1 - drift"; exit 1; }\nexit 0\n' > "$rs/scripts/test-flaky.sh"
chmod +x "$rs/scripts/test-pass.sh" "$rs/scripts/test-flaky.sh"
(cd "$REPO" && env -u SUITE_TIER_MODE -u SUITE_FLAKE_REPO_ID SUITE_FLAKE_LEDGER="$SB/real.jsonl" \
   SUITE_LOCK_DIR="$SB/lock" SUITE_ROTATE_STATE="$SB/rot" bash scripts/ci/run-shell-tests.sh "$rs/scripts" >/dev/null 2>&1)
got=$(env -u SUITE_FLAKE_REPO_ID SUITE_FLAKE_LEDGER="$SB/real.jsonl" bash "$SUT" --now "$(date +%s)" --days 1 --format tick 2>/dev/null)
eq "R5: reader sees the row the runner just wrote for this repo" "$got" "1/1@test-flaky.sh*1"

echo "== R6: bounded tail =="
n=$(SUITE_FLAKE_TAIL_ROWS=2 SUITE_FLAKE_LEDGER="$L" SUITE_FLAKE_REPO_ID=repo-a bash "$SUT" --now "$NOW" --days 2 --format tick 2>/dev/null)
eq "R6: only the last 2 lines are read (the old row and a malformed line)" "$n" "1/1@test-old.sh*1"

echo "== R7: a flag with no value terminates =="
for fl in --days --since --now --format; do
  r=$(SUITE_FLAKE_LEDGER="$L" SUITE_FLAKE_REPO_ID=repo-a timeout 5 bash "$SUT" "$fl" 2>/dev/null; echo "rc=$?")
  case "$r" in *rc=0) pass "R7: trailing $fl exits 0" ;; *) fail "R7: trailing $fl got [$r]" ;; esac
done

echo "== R8: leading-zero epochs read as decimal =="
eq "R8: --now 01800000000 --since 01799999000" "$(SUITE_FLAKE_LEDGER="$L" SUITE_FLAKE_REPO_ID=repo-a bash "$SUT" --now 01800000000 --since 01799999000 --format tick 2>/dev/null)" "3/2@test-x.sh*2"

[ "$failures" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES: $failures"; exit 1
