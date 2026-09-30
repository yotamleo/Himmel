#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# scripts/ci/test-run-shell-tests-manifest.sh — run-shell-tests.sh under
# SUITE_IMPACTED_FROM_BASE + SUITE_MANIFEST (HIMMEL-3897), end to end with
# scripts/ci/shard-manifest-verify.sh: what a PR's fixed shards and the
# shell-unit aggregator do on CI.
#
# A throwaway repo whose refs/remotes/origin/main is BASE, with a COPY of the
# runner, the selection script, a trust list and the selector committed there:
#
#   RM1  a code PR: only the impacted suite runs; the manifest says so; the
#        aggregator's verify passes
#   RM2  a trust-path PR: the FULL sweep runs (both suites)
#   RM3  a docs-only PR: rc 0, nothing runs, manifest + verify still green
#   RM4  the two env vars never reach a suite the runner starts
#   RM5  two shards: the union of their manifests verifies; dropping one
#        shard's `ran` line makes the verify refuse
#   RM6  a shard that records a listed suite as `notfound` is refused
#        (the aggregator's real `--list .` output is the check)
#
# Platform guard: bash-only, no .ps1 twin; the shards run on Linux CI.
#
# Usage: bash scripts/ci/test-run-shell-tests-manifest.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
SB="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$SB" "$SUITE_LOCK_SANDBOX"' EXIT
(
  fixture_enter_git_init_dir "$SB" || exit 1
  git init -q
  git config user.email t@e
  git config user.name t
) || exit 1
g() { git -C "$SB" "$@"; }

# Scan root `.` walks these four trees (HIMMEL-3193); find fails on a missing one.
mkdir -p "$SB/scripts/ci" "$SB/scripts/lib" "$SB/scripts/cr" "$SB/scripts/tools" "$SB/docs" \
         "$SB/templates" "$SB/marketplace" "$SB/packaging"
cp "$RUNNER" "$SB/scripts/ci/run-shell-tests.sh"
cp "$SRC_ROOT/scripts/ci/impacted-selection.sh" "$SB/scripts/ci/impacted-selection.sh"
cp "$SRC_ROOT/scripts/cr/impacted-suites.sh" "$SB/scripts/cr/impacted-suites.sh"
cp "$SRC_ROOT/scripts/cr/anchor-handoff.sh" "$SB/scripts/cr/anchor-handoff.sh"
for lib in proc-tree.sh git-test-env.sh override-env.sh runtime-preflight.sh suite-semaphore.sh chokepoint-seam-guard.sh; do
  cp "$SRC_ROOT/scripts/lib/$lib" "$SB/scripts/lib/$lib"
done
printf '^scripts/ci/\n' > "$SB/scripts/ci/ci-trust-paths.txt"

RM_LOG="$SB/ran.log"
export RM_LOG
# Each suite logs its name plus whether either env var leaked into it (RM4).
mksuite() {
  printf '#!/usr/bin/env bash\n# %s\necho "%s ${SUITE_MANIFEST-unset} ${SUITE_IMPACTED_FROM_BASE-unset}" >> "$RM_LOG"\nexit 0\n' \
    "$3" "$2" > "$SB/$1"
}
printf '# tool\n' > "$SB/scripts/tools/foo.sh"
mksuite scripts/test-foo.sh foo 'drives tools/foo.sh'
mksuite scripts/test-bar.sh bar 'drives nothing that changes'
printf '# doc\n' > "$SB/docs/note.md"
printf 'ran.log\nm/\n' > "$SB/.gitignore"
g add -A; g commit -q -m "chore: base"
BASE=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/main "$BASE"

# pr <name> <file> — a one-commit PR branch off BASE, checked out.
pr() {
  g checkout -q -B "$1" "$BASE"
  printf '# edit\n' >> "$SB/$2"
  g commit -q -am "change $2"
}
RUN="$SB/scripts/ci/run-shell-tests.sh"
VERIFY="$SRC_ROOT/scripts/ci/shard-manifest-verify.sh"

# shard_run <k> <n> — one CI shard: prints the runner's output, sets $rc.
shard_run() {
  out=$(SUITE_IMPACTED_FROM_BASE="$BASE" SUITE_MANIFEST="$SB/m/manifest-shard$1.txt" \
        bash "$RUN" --shard "$1/$2" . 2>&1); rc=$?
}
# aggregate <n> — the aggregator, as ci.yml runs it: recompute the selection,
# list discovery, verify manifests.
aggregate() {
  (cd "$SB" && bash scripts/ci/impacted-selection.sh "$BASE" HEAD) > "$SB/sel.txt"
  bash "$RUN" --list . > "$SB/disc.txt" 2>&1
  vout=$(bash "$VERIFY" --dir "$SB/m" --shards "$1" --selection "$SB/sel.txt" \
         --discovered "$SB/disc.txt" 2>&1); vrc=$?
}
fresh() { rm -rf "$SB/m"; : > "$RM_LOG"; }

# --- RM1 ---------------------------------------------------------------------
pr code scripts/tools/foo.sh; fresh
shard_run 1 1
ran=$(cut -d' ' -f1 "$RM_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = foo ]; then
  pass "RM1: a code PR runs only its impacted suite"
else fail "RM1: rc=$rc ran='$ran' out: $out"; fi
m=$(cat "$SB/m/manifest-shard1.txt" 2>/dev/null)
if grepq "$m" -x 'mode impacted' && grepq "$m" -x 'shard 1/1' \
   && grepq "$m" -x 'ran 0 scripts/test-foo.sh' && grepq "$m" -x 'skip scripts/test-bar.sh'; then
  pass "RM1: the manifest records the selection and each suite's fate"
else fail "RM1: manifest: $m"; fi
aggregate 1
if [ "$vrc" -eq 0 ]; then pass "RM1: the aggregator verifies it"; else fail "RM1: verify rc=$vrc: $vout"; fi

# --- RM2 ---------------------------------------------------------------------
pr trust scripts/ci/ci-trust-paths.txt; fresh
shard_run 1 1
ran=$(cut -d' ' -f1 "$RM_LOG" | sort | tr '\n' ' ')
m=$(cat "$SB/m/manifest-shard1.txt" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$ran" = "bar foo " ] && grepq "$m" -x 'mode full'; then
  pass "RM2: a trust-path PR runs the FULL sweep"
else fail "RM2: rc=$rc ran='$ran' out: $out manifest: $m"; fi
aggregate 1
if [ "$vrc" -eq 0 ]; then pass "RM2: the aggregator verifies the full sweep"; else fail "RM2: verify rc=$vrc: $vout"; fi

# --- RM3 ---------------------------------------------------------------------
pr docs docs/note.md; fresh
shard_run 1 2; rc1=$rc
shard_run 2 2; rc2=$rc
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ ! -s "$RM_LOG" ]; then
  pass "RM3: a docs-only PR is green on every shard and runs nothing"
else fail "RM3: rc=$rc1/$rc2 log: $(cat "$RM_LOG") out: $out"; fi
aggregate 2
if [ "$vrc" -eq 0 ]; then pass "RM3: the aggregator verifies the empty selection"; else fail "RM3: verify rc=$vrc: $vout"; fi

# --- RM4 ---------------------------------------------------------------------
pr code2 scripts/tools/foo.sh; fresh
shard_run 1 1
if [ "$(cat "$RM_LOG")" = "foo unset unset" ]; then
  pass "RM4: neither env var reaches a suite"
else fail "RM4: suite saw: $(cat "$RM_LOG")"; fi

# --- RM5 ---------------------------------------------------------------------
pr both scripts/tools/foo.sh
printf '# drives tools/foo.sh too\n' >> "$SB/scripts/test-bar.sh"
g commit -q -am "bar drives foo"; fresh
shard_run 1 2; rc1=$rc
shard_run 2 2; rc2=$rc
aggregate 2
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$vrc" -eq 0 ] \
   && [ "$(cut -d' ' -f1 "$RM_LOG" | sort | tr '\n' ' ')" = "bar foo " ]; then
  pass "RM5: two shards split the selection and verify"
else fail "RM5: rc=$rc1/$rc2 vrc=$vrc: $vout log: $(cat "$RM_LOG")"; fi
for k in 1 2; do sed -i.bak '/^ran /d' "$SB/m/manifest-shard$k.txt"; rm -f "$SB/m/manifest-shard$k.txt.bak"; done
aggregate 2
if [ "$vrc" -eq 1 ] && grepq "$vout" 'never ran'; then
  pass "RM5: a shard that drops its ran lines is refused"
else fail "RM5: verify rc=$vrc: $vout"; fi

# --- RM6 ---------------------------------------------------------------------
pr hide scripts/tools/foo.sh; fresh
shard_run 1 1
sed -i.bak 's#^ran 0 scripts/test-foo.sh$#notfound scripts/test-foo.sh#' "$SB/m/manifest-shard1.txt"
rm -f "$SB/m/manifest-shard1.txt.bak"
aggregate 1
if [ "$vrc" -eq 1 ] && grepq "$vout" 'scripts/test-foo.sh never ran.*discovery lists it'; then
  pass "RM6: a shard claiming notfound for a suite the runner lists is refused"
else fail "RM6: verify rc=$vrc: $vout"; fi

rst_tally
