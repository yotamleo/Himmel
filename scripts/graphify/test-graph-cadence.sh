#!/usr/bin/env bash
# Smoke test for scripts/graphify/graph-cadence.sh (HIMMEL-2095).
#
# PLATFORM GUARD: no .ps1 twin, matching graph-cadence.sh's own (see that
# script's header) -- this suite tests plain POSIX bash under Git Bash the
# same way test-graph-publish.sh and test-graphmap-cadence.sh's cron half
# already do; there is no separate PowerShell code path to twin against.
#
# Strategy (mirrors test-graph-publish.sh): git operations run for real
# against a LOCAL bare "origin" + a "primary" clone (never real GitHub/
# graphify). `gh` is faked (GH_CMD, same fake shape as test-graph-publish.sh).
# `graphify` itself is faked too (a stub on PATH ahead of anything real) --
# ast-update.sh and graph-publish.sh run FOR REAL against the fixture, but
# nothing this suite does ever shells the real graphify binary or the real
# `gh` CLI (per HIMMEL-2095's brief: never run graphify for real in a test).
# merge-on-green.sh is replaced outright via GRAPH_CADENCE_MERGE_ON_GREEN --
# its own gh/check-ci resolution is deliberately NOT env-overridable (see its
# own header), so a real invocation would need real GitHub; this suite tests
# graph-cadence.sh's ORCHESTRATION of that subprocess (selector, ARMAUTOMERGE,
# rc handling), not merge-on-green.sh's own internals (that script has its own
# suite).
#
# Every scenario pins GRAPH_CADENCE_HIMMEL_ROOT (and usually
# GRAPH_CADENCE_WORKTREE_DIR) to the fixture -- NEVER omitted -- so this suite
# can never fall back to the real primary checkout the way an early manual
# smoke-test run of this same suite once did by accident (caught + cleaned up
# during implementation; see the ticket's report).
#
# Covers:
#   1. Below --threshold: action=skipped, ledger row, rc=0, no worktree
#      created, no ast-update/graph-publish/merge-on-green invoked.
#   1b. origin/main does not track graphify-out/graph.json AT ALL (HIMMEL-2705
#      step 1's permanent steady state) -> the LOCAL AST-only refresh still
#      runs (worktree created, ast-update.sh invoked, action=refreshed,
#      rc=0), while publish/merge cleanly no-op (merge-on-green.sh AND `gh`
#      never invoked) -- distinct from Test 1's below-threshold skip (which
#      creates no worktree at all) and from the _fail/exit-3 path.
#   2. At/above --threshold: full pipeline runs; a real commit lands on the
#      bare origin's chore/graph-publish-<slug> branch; merge-on-green.sh is
#      invoked with that EXACT branch as its selector and ARMAUTOMERGE=1 in
#      its environment; action=merged when the (faked) merge-on-green exits 0.
#   3. merge-on-green.sh exiting non-zero -> action=published (not "failed"):
#      the PR is up, not yet landed -- a legitimate, non-error state.
#   4. A failing ast-update.sh (faked graphify failure) -> action=failed,
#      rc != 0, and the pipeline SHORT-CIRCUITS (graph-publish.sh's PR branch
#      never reaches the bare origin).
#   5. Ledger shape: every field this ticket's brief lists is present in a
#      REAL emitted line (ts/head/graph_head/merges_behind/action/pr/
#      duration_s/error), plus a standard flow-run-ledger end row lands in
#      HIMMEL_FLOW_RUNS_LEDGER.
#   6. The primary checkout is provably untouched by a full run: branch,
#      HEAD, `git status --porcelain`, and `git worktree list` are asserted
#      byte-identical before/after.
#   7. `env -i` (bare hermetic environment, pinned to the fixture) still
#      completes -- proves the PATH self-heal + HOME/getent-fallback
#      resolution the header documents. Also covers the two HANDOVER_DIR
#      controls (HIMMEL-2619 class, no GRAPH_CADENCE_LEDGER_ROOT seam in
#      either): unset -> loud refusal (non-zero rc, real message, a
#      flow-run-ledger error row, and the runner's own per-fire log all
#      carry it, and NO ledger.jsonl is written anywhere); set to a
#      resolvable temp dir -> the ledger lands there normally.
#   8. Usage error (unknown flag, non-numeric --threshold) -> rc=1.
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (mirrors test-graphmap-cadence.sh / test-himmel-doctor.sh's own
# helper of the same name). printf/echo-into-`grep -q` is a trap under this
# file's `set -o pipefail`: grep -q exits the instant it matches, the
# producer then takes SIGPIPE writing the remainder, and pipefail reports
# the PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input, silently inverting an assertion
# instead of tripping it. A here-string is not a pipeline, so the status is
# grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CADENCE="$SCRIPT_DIR/graph-cadence.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317  # invoked via trap; body reachable through it
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then pass "$name"; else fail "$name" "needle '$needle' missing from haystack"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F -- "$needle"; then fail "$name" "needle '$needle' unexpectedly present"; else pass "$name"; fi
}
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name" "expected='$expected' actual='$actual'"; fi
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/graph-cadence-test.XXXXXX") || { echo "FAIL: mktemp -d failed"; exit 1; }

# Hermeticity, and the mirror of this suite-file class one level up
# (CodeRabbit + panel codex-1, PR #2209): flow_run_ledger_path() lets
# $HIMMEL_FLOW_RUNS_LEDGER win over $HOME, so the per-case temp HOME does NOT
# isolate the flow-run ledger -- an operator with that variable exported had
# every un-pinned run_gc case appending FIXTURE rows to their REAL
# ~/.himmel/flow-runs.jsonl. Measured before fixing: 32 rows, while the suite
# reported 111/0 green. flow-run-ledger.sh:176 has a quarantine net for this,
# but it fires only when the variable is EMPTY and only under
# HIMMEL_SUITE_LOCK_HELD -- so an exported value skips it outright, and
# running this suite directly (as CLAUDE.md documents) skips it too. Its own
# comment names the consequence: paged HimmelFlowRunError for runs that never
# happened.
#
# Cleared here so the launching shell cannot reach run_gc, and defaulted
# inside run_gc to a scratch path. The four cases that pin
# HIMMEL_FLOW_RUNS_LEDGER themselves to assert ledger CONTENT still win,
# because the default is applied with :- at the call, after this unset.
unset HIMMEL_FLOW_RUNS_LEDGER
echo "test: TMP_ROOT=$TMP_ROOT"

# --- fake graphify (never the real binary) -----------------------------------
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/graphify" <<'FAKEGRAPHIFY'
#!/usr/bin/env bash
case "$1" in
  update)
    dir="$2"
    if [ "${FAKE_GRAPHIFY_FAIL:-0}" = "1" ]; then
        echo "fake-graphify: simulated failure" >&2
        exit 1
    fi
    # HIMMEL-2654 lock tests: park inside the pipeline (past the destructive
    # sync) until the test releases us, so a rival can race a LIVE holder.
    if [ -n "${FAKE_GRAPHIFY_HOLD_DIR:-}" ]; then
        : > "$FAKE_GRAPHIFY_HOLD_DIR/entered.$$"
        i=0
        while [ ! -e "$FAKE_GRAPHIFY_HOLD_DIR/release" ] && [ "$i" -lt 3000 ]; do
            sleep 0.01; i=$((i + 1))
        done
    fi
    out="$dir/graphify-out"
    mkdir -p "$out"
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)
    printf '{"nodes":[{"id":1}],"v":2,"built_at_commit":"%s"}' "$head" > "$out/graph.json"
    echo "# GRAPH_REPORT v2 (fake, head=$head)" > "$out/GRAPH_REPORT.md"
    echo '{}' > "$out/manifest.json"
    touch "$out/.graphify_root"
    exit 0
    ;;
esac
exit 0
FAKEGRAPHIFY
chmod +x "$FAKE_BIN/graphify"

# --- fake gh (identical shape to test-graph-publish.sh's fake) --------------
FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat > "$FAKE_GH" <<'FAKEGH'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_GH_LOG"
case "$1" in
    pr)
        case "$2" in
            list) printf '%s\n' "${FAKE_GH_PR_LIST:-}"; exit 0 ;;
            create)
                if [ "${FAKE_GH_FAIL:-}" = "create" ]; then
                    echo "fake gh: pr create failure" >&2
                    exit 1
                fi
                echo "https://github.com/test/test/pull/42"
                exit 0
                ;;
            edit) exit 0 ;;
        esac
        ;;
esac
exit 0
FAKEGH
chmod +x "$FAKE_GH"
FAKE_GH_LOG="$TMP_ROOT/gh.log"
: > "$FAKE_GH_LOG"

# --- fake merge-on-green (records its args/env, canned rc) -------------------
FAKE_MERGE="$TMP_ROOT/merge-on-green-fake.sh"
cat > "$FAKE_MERGE" <<'FAKEMERGE'
#!/usr/bin/env bash
{
    echo "args: $*"
    echo "ARMAUTOMERGE=${ARMAUTOMERGE:-unset}"
    echo "cwd=$(pwd)"
} >> "$FAKE_MERGE_LOG"
exit "${FAKE_MERGE_RC:-0}"
FAKEMERGE
chmod +x "$FAKE_MERGE"
FAKE_MERGE_LOG="$TMP_ROOT/merge.log"

# seed_repo <primary-dir> <bare-origin> <n-filler-commits> -- a "primary"
# repo on main with graphify-out/{graph.json,GRAPH_REPORT.md} committed +
# pushed to a local bare "origin", graph.json carrying a real
# built_at_commit, then N filler commits pushed on top (the staleness gap
# graph-cadence.sh is meant to measure). Mirrors test-graph-publish.sh's
# seed_repo.
seed_repo() {
    local repo="$1" bare="$2" n="$3" first_sha
    git init -q --bare "$bare" >/dev/null 2>&1
    git init -q --initial-branch=main "$repo" 2>/dev/null || git init -q "$repo"
    git -C "$repo" config user.email t@test.com
    git -C "$repo" config user.name test
    mkdir -p "$repo/graphify-out"
    printf 'graphify-out/*\n!graphify-out/graph.json\n!graphify-out/GRAPH_REPORT.md\n' > "$repo/.gitignore"
    echo "seed" > "$repo/README.md"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "chore: seed"
    first_sha=$(git -C "$repo" rev-parse HEAD)
    printf '{"nodes":[],"v":1,"built_at_commit":"%s"}' "$first_sha" > "$repo/graphify-out/graph.json"
    echo '# GRAPH_REPORT v1' > "$repo/graphify-out/GRAPH_REPORT.md"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "chore: seed graph"
    git -C "$repo" remote add origin "$bare"
    git -C "$repo" push -q origin main
    echo '{}' > "$repo/graphify-out/manifest.json"
    local i
    for i in $(seq 1 "$n"); do
        echo "line$i" >> "$repo/README.md"
        git -C "$repo" add -A
        git -C "$repo" commit -q -m "chore: filler $i"
    done
    git -C "$repo" push -q origin main
}

# corpus_slug_of <path> -- mirrors graph-cadence.sh's own CORPUS_SLUG
# derivation EXACTLY (basename, then tr -c, then dash-collapse/trim via sed).
# `basename ... | tr` (a raw pipe, not a newline-stripping command
# substitution first) would feed tr the trailing newline basename prints,
# which -c then transliterates into a STRAY trailing dash -- this helper
# avoids that trap the same way the script itself does (command substitution
# first, then `printf '%s'`, never a raw pipe from basename).
corpus_slug_of() {
    local b s
    b=$(basename "$1")
    s=$(printf '%s' "$b" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
    [ -n "$s" ] || s="repo"
    printf '%s' "$s"
}

run_gc() {
    PATH="$FAKE_BIN:$PATH" \
    FORGE=github \
    GH_CMD="$FAKE_GH" \
    FAKE_GH_LOG="$FAKE_GH_LOG" \
    GRAPH_CADENCE_MERGE_ON_GREEN="$FAKE_MERGE" \
    FAKE_MERGE_LOG="$FAKE_MERGE_LOG" \
    HIMMEL_FLOW_RUNS_LEDGER="${HIMMEL_FLOW_RUNS_LEDGER:-$TMP_ROOT/run-gc-flow-runs.jsonl}" \
    bash "$CADENCE" "$@"
}

# =============================================================================
# Test 1: below threshold -> skipped, no side effects
# =============================================================================
echo "TEST: below --threshold skips, ledger row shape, no worktree created"
REPO="$TMP_ROOT/t1-primary"; BARE="$TMP_ROOT/t1-origin.git"
HOME1="$TMP_ROOT/t1-home"; LEDGER1="$TMP_ROOT/t1-ledger"
mkdir -p "$HOME1" "$LEDGER1"
seed_repo "$REPO" "$BARE" 3
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME1" GRAPH_CADENCE_HIMMEL_ROOT="$REPO" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER1" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq        "below-threshold rc=0" "0" "$rc"
assert_contains  "below-threshold message" "skipping" "$out"
if [ -d "$HOME1/.claude/graph-cadence" ] && [ -n "$(find "$HOME1/.claude/graph-cadence" -mindepth 1 2>/dev/null)" ]; then
    fail "below-threshold created a worktree" "$(ls "$HOME1/.claude/graph-cadence" 2>/dev/null)"
else
    pass "below-threshold created no worktree"
fi
assert_eq "below-threshold never invoked merge-on-green" "" "$(cat "$FAKE_MERGE_LOG")"
LEDGER_LINE=$(tail -n1 "$LEDGER1/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger line present" '"action":"skipped"' "$LEDGER_LINE"
for field in '"ts":' '"head":' '"graph_head":' '"merges_behind":' '"action":' '"pr":null' '"duration_s":' '"error":null'; do
    assert_contains "ledger field $field" "$field" "$LEDGER_LINE"
done
# seed_repo's built_at_commit points at the SEED commit, one BEFORE the
# commit that adds graph.json itself (mirrors the real repo: built_at_commit
# names the commit graphify ran against, not the commit that published the
# result) -- so the true distance is n_filler + 1 (the graph-adding commit
# itself, plus the n filler commits). 3 filler commits -> 4.
assert_contains "ledger merges_behind is the true distance (seed-graph commit + 3 filler = 4)" '"merges_behind":4' "$LEDGER_LINE"

# =============================================================================
# Test 1b (HIMMEL-2705 step 1): origin/main does not track
# graphify-out/graph.json at all -> the LOCAL AST-only refresh still runs
# (worktree created, ast-update.sh invoked, action=refreshed, rc=0), while
# publish/merge cleanly no-op (merge-on-green.sh AND `gh` never invoked) --
# not a clean skip and not _fail/exit-3. This is the PERMANENT steady state
# after graphify-out/ was retired from the git tree and gitignored outright --
# unlike Test 1's below-threshold skip, there is no graph.json on origin/main
# to diff against in the first place.
# =============================================================================
echo "TEST: origin/main missing graphify-out/graph.json entirely -> local refresh still runs, publish/merge cleanly no-op (HIMMEL-2705)"
REPO1B="$TMP_ROOT/t1b-primary"; BARE1B="$TMP_ROOT/t1b-origin.git"
HOME1B="$TMP_ROOT/t1b-home"; LEDGER1B="$TMP_ROOT/t1b-ledger"
mkdir -p "$HOME1B" "$LEDGER1B"
git init -q --bare "$BARE1B" >/dev/null 2>&1
git init -q --initial-branch=main "$REPO1B" 2>/dev/null || git init -q "$REPO1B"
git -C "$REPO1B" config user.email t@test.com
git -C "$REPO1B" config user.name test
echo "seed" > "$REPO1B/README.md"
git -C "$REPO1B" add -A
git -C "$REPO1B" commit -q -m "chore: seed, no graphify-out at all"
git -C "$REPO1B" remote add origin "$BARE1B"
git -C "$REPO1B" push -q origin main
: > "$FAKE_MERGE_LOG"
: > "$FAKE_GH_LOG"
rc=0
out=$(HOME="$HOME1B" GRAPH_CADENCE_HIMMEL_ROOT="$REPO1B" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER1B" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq        "untracked-graph rc=0 (local refresh + clean no-op, not a failure)" "0" "$rc"
assert_contains  "untracked-graph message names HIMMEL-2705" "HIMMEL-2705" "$out"
assert_contains  "untracked-graph message" "does not track graphify-out/graph.json" "$out"
CORPUS_SLUG1B=$(corpus_slug_of "$REPO1B")
WT1B="$HOME1B/.claude/graph-cadence/$CORPUS_SLUG1B"
if [ -d "$WT1B" ]; then
    pass "untracked-graph run DOES create the dedicated worktree (local refresh is no longer unreachable)"
else
    fail "untracked-graph run created no worktree -- local refresh (step 5) is still unreachable" "$(ls "$HOME1B/.claude/graph-cadence" 2>/dev/null)"
fi
if [ -f "$WT1B/graphify-out/graph.json" ]; then
    pass "the local ast-update.sh refresh actually ran (graphify-out/graph.json written into the worktree)"
else
    fail "no graphify-out/graph.json found in the worktree -- ast-update.sh never ran" "$(ls "$WT1B/graphify-out" 2>/dev/null)"
fi
assert_eq "untracked-graph run never invoked merge-on-green (nothing to merge)" "" "$(cat "$FAKE_MERGE_LOG")"
assert_eq "untracked-graph run never invoked gh (nothing to publish)" "" "$(cat "$FAKE_GH_LOG")"
LEDGER_LINE1B=$(tail -n1 "$LEDGER1B/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=refreshed (real work happened, not a skip)" '"action":"refreshed"' "$LEDGER_LINE1B"
assert_not_contains "ledger action is not skipped" '"action":"skipped"' "$LEDGER_LINE1B"
assert_contains "ledger error=null (not the _fail/exit-3 path)" '"error":null' "$LEDGER_LINE1B"

# =============================================================================
# Test 1c (CodeRabbit, PR #2272): origin/main does not RESOLVE at all (empty
# remote, no main branch ever pushed) -> must _fail/exit 3, never the Test 1b
# clean-skip path. `cat-file -e origin/main:<path>` alone cannot distinguish
# "path absent" from "ref absent"; this proves the ref-resolution check added
# in graph-cadence.sh actually gates that distinction.
# =============================================================================
echo "TEST: origin/main itself unresolvable -> _fail, rc=3 (not misreported as skip)"
REPO1C="$TMP_ROOT/t1c-primary"; BARE1C="$TMP_ROOT/t1c-origin.git"
HOME1C="$TMP_ROOT/t1c-home"; LEDGER1C="$TMP_ROOT/t1c-ledger"
mkdir -p "$HOME1C" "$LEDGER1C"
git init -q --bare "$BARE1C" >/dev/null 2>&1
git init -q --initial-branch=main "$REPO1C" 2>/dev/null || git init -q "$REPO1C"
git -C "$REPO1C" config user.email t@test.com
git -C "$REPO1C" config user.name test
echo "seed" > "$REPO1C/README.md"
git -C "$REPO1C" add -A
git -C "$REPO1C" commit -q -m "chore: seed, remote has no main at all"
git -C "$REPO1C" remote add origin "$BARE1C"
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME1C" GRAPH_CADENCE_HIMMEL_ROOT="$REPO1C" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER1C" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq        "unresolvable-origin/main rc=3 (_fail, not a skip)" "3" "$rc"
assert_contains  "unresolvable-origin/main message" "does not resolve" "$out"
LEDGER_LINE1C=$(tail -n1 "$LEDGER1C/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=failed" '"action":"failed"' "$LEDGER_LINE1C"

# =============================================================================
# Test 1d (PR #2272 round-3, HIMMEL-2824): origin/main:graphify-out/graph.json
# IS listed in the tree (unlike Test 1b's genuinely-retired path) but its blob
# object cannot be read -- `git cat-file -e` alone cannot distinguish "path
# absent" from "object unreadable" (corrupt/partial clone, missing objects).
# The blob is also part of origin/main's tree that step 5 checks the dedicated
# worktree out to, so a real corrupt clone still ends in a hard failure
# (worktree add cannot materialize a tree with a missing object) -- this test
# is NOT about avoiding that failure, only about the diagnostic step 2 branch
# (PUBLISH_POSSIBLE=0) naming the real cause instead of misreporting it as the
# permanent HIMMEL-2705 retired-path skip on the way there.
# =============================================================================
echo "TEST: origin/main lists graphify-out/graph.json but its blob object is unreadable -> loud warning names the object-read failure, not the retired-path message"
REPO1D="$TMP_ROOT/t1d-primary"; BARE1D="$TMP_ROOT/t1d-origin.git"
HOME1D="$TMP_ROOT/t1d-home"; LEDGER1D="$TMP_ROOT/t1d-ledger"
mkdir -p "$HOME1D" "$LEDGER1D"
git init -q --bare "$BARE1D" >/dev/null 2>&1
git init -q --initial-branch=main "$REPO1D" 2>/dev/null || git init -q "$REPO1D"
git -C "$REPO1D" config user.email t@test.com
git -C "$REPO1D" config user.name test
mkdir -p "$REPO1D/graphify-out"
printf '{"nodes":[],"v":1,"built_at_commit":"seed"}' > "$REPO1D/graphify-out/graph.json"
git -C "$REPO1D" add -A
git -C "$REPO1D" commit -q -m "chore: seed with graph.json"
git -C "$REPO1D" remote add origin "$BARE1D"
git -C "$REPO1D" push -q origin main
# Simulate a corrupt/partial clone: delete the LOOSE object backing the
# blob's content while origin/main's tree stays intact -- `git fetch origin`
# (graph-cadence.sh's own step 1) negotiates by ref SHA, not object
# completeness, so a no-op fetch (same SHA already known) never
# replenishes it. `ls-tree` only reads the tree object and keeps listing
# the path; only reading the blob's own content fails.
BLOB_SHA1D=$(git -C "$REPO1D" rev-parse HEAD:graphify-out/graph.json)
BLOB_PATH1D="$REPO1D/.git/objects/${BLOB_SHA1D:0:2}/${BLOB_SHA1D:2}"
[ -f "$BLOB_PATH1D" ] || { echo "FAIL: fixture setup: expected loose object $BLOB_PATH1D not found (packed?)"; exit 1; }
rm -f "$BLOB_PATH1D"
: > "$FAKE_MERGE_LOG"
: > "$FAKE_GH_LOG"
rc=0
out=$(HOME="$HOME1D" GRAPH_CADENCE_HIMMEL_ROOT="$REPO1D" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER1D" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq        "unreadable-object still fails closed downstream (worktree add cannot check out a tree with a missing object)" "3" "$rc"
assert_contains  "unreadable-object message names the object-read failure" "object could not be read" "$out"
assert_not_contains "unreadable-object message is NOT the retired-path skip message" "does not track graphify-out/graph.json" "$out"
assert_eq "unreadable-object run never invoked merge-on-green (publish gated off)" "" "$(cat "$FAKE_MERGE_LOG")"
assert_eq "unreadable-object run never invoked gh (publish gated off)" "" "$(cat "$FAKE_GH_LOG")"
LEDGER_LINE1D=$(tail -n1 "$LEDGER1D/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=failed" '"action":"failed"' "$LEDGER_LINE1D"

# =============================================================================
# Test 2: at/above threshold -> full pipeline, merged
# =============================================================================
echo "TEST: at/above threshold refreshes+publishes+merges (merge-on-green rc=0)"
REPO2="$TMP_ROOT/t2-primary"; BARE2="$TMP_ROOT/t2-origin.git"
HOME2="$TMP_ROOT/t2-home"; LEDGER2="$TMP_ROOT/t2-ledger"
mkdir -p "$HOME2" "$LEDGER2"
seed_repo "$REPO2" "$BARE2" 20
: > "$FAKE_MERGE_LOG"
: > "$FAKE_GH_LOG"
BARE2_MAIN_BEFORE=$(git --git-dir="$BARE2" rev-parse main)
BARE2_REFS_BEFORE=$(git --git-dir="$BARE2" for-each-ref --format='%(refname)')
rc=0
out=$(HOME="$HOME2" GRAPH_CADENCE_HIMMEL_ROOT="$REPO2" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER2" FAKE_MERGE_RC=0 \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq        "full-pipeline rc=0" "0" "$rc"
# OPERATOR REQUIREMENT (HIMMEL-2654): graph updates land ONLY via a PR --
# never a direct push to main. origin/main is byte-identical after a full
# publish+merge run, the ONLY new ref is the publish branch, a PR was opened
# for it, and the merge went through merge-on-green.sh (the PR merge gate).
assert_eq "origin/main NOT moved by the run (no direct push to main)" "$BARE2_MAIN_BEFORE" "$(git --git-dir="$BARE2" rev-parse main)"
BARE2_NEW_REFS=$(comm -13 <(printf '%s\n' "$BARE2_REFS_BEFORE" | sort) <(git --git-dir="$BARE2" for-each-ref --format='%(refname)' | sort))
assert_eq "the only ref pushed is the publish branch" "refs/heads/chore/graph-publish-$(corpus_slug_of "$REPO2")" "$BARE2_NEW_REFS"
assert_contains "a PR was opened for the publish branch" "gh pr create" "$(cat "$FAKE_GH_LOG")"
CORPUS_SLUG=$(corpus_slug_of "$REPO2")
assert_contains "graph-publish committed to the predicted branch" "chore/graph-publish-${CORPUS_SLUG}" "$out"
# The commit actually reached the bare origin.
bare_graph_sha=$(git --git-dir="$BARE2" rev-parse --verify --quiet "chore/graph-publish-${CORPUS_SLUG}:graphify-out/graph.json" 2>/dev/null || echo MISSING)
assert_not_contains "published branch landed on the bare origin" "MISSING" "$bare_graph_sha"
merge_log=$(cat "$FAKE_MERGE_LOG")
assert_contains "merge-on-green invoked with the predicted branch selector" "args: chore/graph-publish-${CORPUS_SLUG}" "$merge_log"
assert_contains "merge-on-green invoked with ARMAUTOMERGE=1" "ARMAUTOMERGE=1" "$merge_log"
LEDGER_LINE2=$(tail -n1 "$LEDGER2/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=merged" '"action":"merged"' "$LEDGER_LINE2"
assert_contains "ledger pr field populated" '"pr":"https://github.com/test/test/pull/42"' "$LEDGER_LINE2"
# Worktree dirname equals the corpus slug (HIMMEL-2095: must match, or
# merge-on-green's selector would target a branch graph-publish.sh never
# created -- see the script's header).
if [ -d "$HOME2/.claude/graph-cadence/$CORPUS_SLUG" ]; then
    pass "worktree dirname matches the predicted corpus slug"
else
    fail "worktree dirname does not match corpus slug" "$(ls "$HOME2/.claude/graph-cadence" 2>/dev/null)"
fi

# =============================================================================
# Test 3: merge-on-green declines with a genuine DEFERRAL code (14, check-ci
# gate not green) -> action=published, NOT failed
# =============================================================================
echo "TEST: merge-on-green rc=14 (check-ci not green -- a genuine deferral) -> action=published (not an error)"
REPO3="$TMP_ROOT/t3-primary"; BARE3="$TMP_ROOT/t3-origin.git"
HOME3="$TMP_ROOT/t3-home"; LEDGER3="$TMP_ROOT/t3-ledger"
mkdir -p "$HOME3" "$LEDGER3"
seed_repo "$REPO3" "$BARE3" 20
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME3" GRAPH_CADENCE_HIMMEL_ROOT="$REPO3" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER3" FAKE_MERGE_RC=14 \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq "not-yet-mergeable rc=0 (not a failure)" "0" "$rc"
LEDGER_LINE3=$(tail -n1 "$LEDGER3/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=published on a non-landing merge-on-green" '"action":"published"' "$LEDGER_LINE3"

# =============================================================================
# Test 3b (PR-B panel r1, codex-7): merge-on-green fails with an EXECUTION
# failure code (12, repo/base misconfigured -- NOT a time-resolving
# deferral) -> action=failed, rc!=0. Before this fix EVERY non-zero
# merge-on-green rc read as "published" -- a permanently broken merge leg
# (missing gh, misconfigured base, unwritable audit sink) would have reported
# healthy forever.
# =============================================================================
echo "TEST: merge-on-green rc=12 (execution/environment failure, not a deferral) -> action=failed, rc!=0"
REPO3b="$TMP_ROOT/t3b-primary"; BARE3b="$TMP_ROOT/t3b-origin.git"
HOME3b="$TMP_ROOT/t3b-home"; LEDGER3b="$TMP_ROOT/t3b-ledger"
mkdir -p "$HOME3b" "$LEDGER3b"
seed_repo "$REPO3b" "$BARE3b" 20
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME3b" GRAPH_CADENCE_HIMMEL_ROOT="$REPO3b" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER3b" FAKE_MERGE_RC=12 \
      run_gc --threshold 10 2>&1) || rc=$?
if [ "$rc" != "0" ]; then pass "merge execution failure returns non-zero rc (got $rc)"; else fail "merge execution failure returned rc=0"; fi
LEDGER_LINE3b=$(tail -n1 "$LEDGER3b/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=failed on a merge execution failure (not published)" '"action":"failed"' "$LEDGER_LINE3b"
assert_not_contains "ledger action is not published for an execution failure" '"action":"published"' "$LEDGER_LINE3b"
assert_not_contains "ledger action is not failed" '"action":"failed"' "$LEDGER_LINE3"

# =============================================================================
# Test 4: ast-update.sh fails -> action=failed, rc!=0, pipeline short-circuits
# =============================================================================
echo "TEST: a failing structural refresh -> action=failed, non-zero rc, no publish/merge attempted"
REPO4="$TMP_ROOT/t4-primary"; BARE4="$TMP_ROOT/t4-origin.git"
HOME4="$TMP_ROOT/t4-home"; LEDGER4="$TMP_ROOT/t4-ledger"
mkdir -p "$HOME4" "$LEDGER4"
seed_repo "$REPO4" "$BARE4" 20
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME4" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4" FAKE_GRAPHIFY_FAIL=1 \
      run_gc --threshold 10 2>&1) || rc=$?
if [ "$rc" != "0" ]; then pass "failing refresh returns non-zero rc (got $rc)"; else fail "failing refresh returned rc=0"; fi
LEDGER_LINE4=$(tail -n1 "$LEDGER4/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=failed" '"action":"failed"' "$LEDGER_LINE4"
assert_not_contains "ledger error field is not null on failure" '"error":null' "$LEDGER_LINE4"
assert_eq "failing refresh never invoked merge-on-green" "" "$(cat "$FAKE_MERGE_LOG")"
CORPUS_SLUG4=$(corpus_slug_of "$REPO4")
bare_branch4=$(git --git-dir="$BARE4" rev-parse --verify --quiet "chore/graph-publish-${CORPUS_SLUG4}" 2>/dev/null || echo MISSING)
assert_eq "failing refresh never reached the bare origin's publish branch" "MISSING" "$bare_branch4"

# =============================================================================
# Test 5: standard flow-run-ledger row lands too
# =============================================================================
echo "TEST: the standard flow-run-ledger start/end pair is also written"
FLOW_LEDGER5="$TMP_ROOT/t5-flow-runs.jsonl"
REPO5="$TMP_ROOT/t5-primary"; BARE5="$TMP_ROOT/t5-origin.git"
HOME5="$TMP_ROOT/t5-home"; LEDGER5="$TMP_ROOT/t5-ledger"
mkdir -p "$HOME5" "$LEDGER5"
seed_repo "$REPO5" "$BARE5" 3
rc=0
HOME="$HOME5" GRAPH_CADENCE_HIMMEL_ROOT="$REPO5" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER5" \
    HIMMEL_FLOW_RUNS_LEDGER="$FLOW_LEDGER5" \
    run_gc --threshold 10 >/dev/null 2>&1 || rc=$?
assert_eq "flow-run test rc=0" "0" "$rc"
flow_content=$(cat "$FLOW_LEDGER5" 2>/dev/null || echo MISSING)
assert_contains "flow-run start row" '"ev":"start"' "$flow_content"
assert_contains "flow-run end row"   '"ev":"end"'   "$flow_content"
assert_contains "flow-run flow name is graph-publish-<slug>" "graph-publish-" "$flow_content"

# =============================================================================
# Test 6: primary checkout provably untouched by a full run
# =============================================================================
echo "TEST: primary checkout branch/HEAD/status/worktree-list unchanged after a full run"
REPO6="$TMP_ROOT/t6-primary"; BARE6="$TMP_ROOT/t6-origin.git"
HOME6="$TMP_ROOT/t6-home"; LEDGER6="$TMP_ROOT/t6-ledger"
mkdir -p "$HOME6" "$LEDGER6"
seed_repo "$REPO6" "$BARE6" 20
branch_before=$(git -C "$REPO6" rev-parse --abbrev-ref HEAD)
head_before=$(git -C "$REPO6" rev-parse HEAD)
status_before=$(git -C "$REPO6" status --porcelain)
# The PRIMARY's own row in `git worktree list` (path + HEAD + branch) --
# NOT the whole table, whose column padding shifts once a second (longer)
# path is added, which would make even an UNCHANGED primary row compare
# unequal byte-for-byte. What must not change is the primary's OWN entry.
primary_row_before=$(git -C "$REPO6" worktree list --porcelain | grep -A2 "^worktree $REPO6\$")
rc=0
HOME="$HOME6" GRAPH_CADENCE_HIMMEL_ROOT="$REPO6" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER6" \
    run_gc --threshold 10 >/dev/null 2>&1 || rc=$?
assert_eq "primary-untouched run rc=0" "0" "$rc"
branch_after=$(git -C "$REPO6" rev-parse --abbrev-ref HEAD)
head_after=$(git -C "$REPO6" rev-parse HEAD)
status_after=$(git -C "$REPO6" status --porcelain)
primary_row_after=$(git -C "$REPO6" worktree list --porcelain | grep -A2 "^worktree $REPO6\$")
assert_eq "primary branch unchanged"  "$branch_before"  "$branch_after"
assert_eq "primary HEAD unchanged"    "$head_before"     "$head_after"
assert_eq "primary status unchanged (still clean)" "$status_before" "$status_after"
assert_eq "primary's OWN worktree-list row unchanged" "$primary_row_before" "$primary_row_after"
# The dedicated cadence worktree IS expected to appear as a NEW row -- that
# is the sanctioned mechanism (git worktree add run FROM the primary, which
# never touches the primary's own HEAD/index/branch, asserted above). Assert
# it is EXACTLY the dedicated path, not some other mutation.
CORPUS_SLUG6=$(corpus_slug_of "$REPO6")
wt_list6=$(git -C "$REPO6" worktree list --porcelain)
if grepq "$wt_list6" -F "worktree $HOME6/.claude/graph-cadence/$CORPUS_SLUG6"; then
    pass "the only new worktree row is the dedicated cadence worktree"
else
    fail "no dedicated cadence worktree row found" "$(git -C "$REPO6" worktree list)"
fi

# =============================================================================
# Test 7: env -i (hermetic environment), pinned to the fixture -- proves the
# PATH self-heal + HANDOVER_DIR-via-.env + HOME/getent-fallback resolution.
# =============================================================================
echo "TEST: env -i (no inherited PATH/HOME) still completes, pinned to the fixture"
REPO7="$TMP_ROOT/t7-primary"; BARE7="$TMP_ROOT/t7-origin.git"
HOME7="$TMP_ROOT/t7-home"; LEDGER7="$TMP_ROOT/t7-ledger"
mkdir -p "$HOME7" "$LEDGER7"
seed_repo "$REPO7" "$BARE7" 20
: > "$FAKE_MERGE_LOG"
rc=0
out=$(env -i \
        HOME="$HOME7" \
        PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
        FORGE=github \
        GH_CMD="$FAKE_GH" \
        FAKE_GH_LOG="$FAKE_GH_LOG" \
        GRAPH_CADENCE_MERGE_ON_GREEN="$FAKE_MERGE" \
        FAKE_MERGE_LOG="$FAKE_MERGE_LOG" \
        GRAPH_CADENCE_HIMMEL_ROOT="$REPO7" \
        GRAPH_CADENCE_LEDGER_ROOT="$LEDGER7" \
        bash "$CADENCE" --threshold 10 2>&1) || rc=$?
assert_eq "env -i (with PATH/HOME given) rc=0" "0" "$rc"
LEDGER_LINE7=$(tail -n1 "$LEDGER7/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "env -i run still writes a ledger row" '"action":"merged"' "$LEDGER_LINE7"

echo "TEST: env -i with NO PATH at all -- self-heal fallback resolves git/coreutils"
REPO7b="$TMP_ROOT/t7b-primary"; BARE7b="$TMP_ROOT/t7b-origin.git"
HOME7b="$TMP_ROOT/t7b-home"; LEDGER7b="$TMP_ROOT/t7b-ledger"
mkdir -p "$HOME7b" "$LEDGER7b"
seed_repo "$REPO7b" "$BARE7b" 3
rc=0
out=$(env -i \
        HOME="$HOME7b" \
        GRAPH_CADENCE_HIMMEL_ROOT="$REPO7b" \
        GRAPH_CADENCE_LEDGER_ROOT="$LEDGER7b" \
        bash "$CADENCE" --threshold 10 2>&1) || rc=$?
assert_eq "env -i with no PATH still completes (below-threshold path needs only git)" "0" "$rc"
assert_contains "env -i no-PATH run reaches the skip decision (git resolved via self-heal)" "skipping" "$out"

echo "TEST: env -i with NO HOME at all -- getent fallback resolves a real HOME"
REPO7c="$TMP_ROOT/t7c-primary"; BARE7c="$TMP_ROOT/t7c-origin.git"
LEDGER7c="$TMP_ROOT/t7c-ledger"
FLOW_LEDGER7c="$TMP_ROOT/t7c-flow-runs.jsonl"
mkdir -p "$LEDGER7c"
seed_repo "$REPO7c" "$BARE7c" 3
# PR-B panel r2, codex-5: HOME is deliberately left unset here so the script
# falls back to getent (a REAL passwd lookup, resolving the REAL operator's
# HOME) -- but the flow-run ledger and the dedicated worktree BOTH default
# off that same resolved HOME, and this case previously pinned neither. The
# flow-run write happens unconditionally, early (before the threshold check
# even runs), so every case run wrote a start/end pair into the REAL
# operator's ~/.himmel/flow-runs.jsonl -- a test writing into real state,
# exactly the class PR-A spent three rounds on. Same fix that finally held
# there: extend the SAME env -i allowlist this case already uses (it is
# already the right shape) rather than leaving any HOME-derived default
# unpinned. GRAPH_CADENCE_WORKTREE_DIR is pinned too, belt-and-suspenders --
# this fixture's low commit count keeps the run below --threshold today so
# it never reaches worktree creation, but nothing here should depend on that
# staying true.
GRAPH_CADENCE_WORKTREE_DIR_7c="$TMP_ROOT/t7c-worktree"
rc=0
out=$(env -i \
        PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
        GRAPH_CADENCE_HIMMEL_ROOT="$REPO7c" \
        GRAPH_CADENCE_LEDGER_ROOT="$LEDGER7c" \
        GRAPH_CADENCE_WORKTREE_DIR="$GRAPH_CADENCE_WORKTREE_DIR_7c" \
        HIMMEL_FLOW_RUNS_LEDGER="$FLOW_LEDGER7c" \
        bash "$CADENCE" --threshold 10 2>&1) || rc=$?
assert_eq "env -i with no HOME still completes (getent fallback)" "0" "$rc"
assert_not_contains "env -i no-HOME run does not report HOME unresolvable" "HOME is unset/unresolvable" "$out"
flow7c=$(cat "$FLOW_LEDGER7c" 2>/dev/null || echo MISSING)
assert_contains "flow-run ledger lands in the FIXTURE, not real operator state" '"ev":"start"' "$flow7c"

# --- HANDOVER_DIR unset (no test-seam GRAPH_CADENCE_LEDGER_ROOT either) -----
# HIMMEL-2619 class: cron gives no login shell, so HANDOVER_DIR is exactly
# the variable that goes missing there. This is the control that proves the
# runner fails LOUDLY instead of silently falling back to himmel's own
# handovers/ Mode-A stub (which would write the cadence ledger straight into
# the git repo it publishes -- this happened once for real during this
# ticket's implementation, caught before commit).
echo "TEST: env -i with HANDOVER_DIR unset and no ledger-root seam -> loud refusal, non-zero rc, flow-run error row"
REPO7d="$TMP_ROOT/t7d-primary"; BARE7d="$TMP_ROOT/t7d-origin.git"
HOME7d="$TMP_ROOT/t7d-home"
FLOW_LEDGER7d="$TMP_ROOT/t7d-flow-runs.jsonl"
# Empty, dedicated (never real) dotenv root -- PR-B panel r1 codex-5: this
# checkout's own REPO_ROOT/.env happening to carry no HANDOVER_DIR is an
# ACCIDENT of this worktree's disk state, not something this test asserts.
# Pin GRAPH_CADENCE_DOTENV_ROOT to an empty dir the same way graphmap-
# cadence.sh's own credential-check tests pin GRAPHMAP_DOTENV_ROOT, so this
# control is hermetic by construction, not by luck -- matching the PR-A
# lesson (explicit env -i allowlist, never an incidental absence).
DOTENV_ROOT7d="$TMP_ROOT/t7d-dotenv-empty"
mkdir -p "$HOME7d" "$DOTENV_ROOT7d"
seed_repo "$REPO7d" "$BARE7d" 20
rc=0
out=$(env -i \
        HOME="$HOME7d" \
        PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
        GRAPH_CADENCE_HIMMEL_ROOT="$REPO7d" \
        GRAPH_CADENCE_DOTENV_ROOT="$DOTENV_ROOT7d" \
        HIMMEL_FLOW_RUNS_LEDGER="$FLOW_LEDGER7d" \
        bash "$CADENCE" --threshold 10 2>&1) || rc=$?
if [ "$rc" != "0" ]; then pass "HANDOVER_DIR-unset refusal returns non-zero rc (got $rc)"; else fail "HANDOVER_DIR-unset run returned rc=0"; fi
assert_contains "HANDOVER_DIR-unset refusal names the variable" "HANDOVER_DIR is unset" "$out"
assert_contains "HANDOVER_DIR-unset refusal explains the Mode-A risk" "handovers/ stub" "$out"
assert_not_contains "no ledger.jsonl written anywhere under HOME (no silent Mode-A fallback)" '"action"' "$(find "$HOME7d" -name 'ledger.jsonl' -exec cat {} \; 2>/dev/null)"
flow_content7d=$(cat "$FLOW_LEDGER7d" 2>/dev/null || echo MISSING)
assert_contains "flow-run ledger STILL records the refusal (start row)" '"ev":"start"' "$flow_content7d"
assert_contains "flow-run ledger STILL records the refusal (end row, outcome=error)" '"ev":"end"' "$flow_content7d"
assert_contains "flow-run end row outcome is error" '"outcome":"error"' "$flow_content7d"
# The runner's own per-fire log also carries the refusal (WORKTREE_DIR.log,
# next to the never-created worktree -- see the script's LOG_FILE derivation).
CORPUS_SLUG7d=$(corpus_slug_of "$REPO7d")
log7d="$HOME7d/.claude/graph-cadence/${CORPUS_SLUG7d}.log"
if [ -f "$log7d" ] && grep -qF "HANDOVER_DIR is unset" "$log7d"; then
    pass "the runner's own per-fire log also carries the refusal"
else
    fail "per-fire log missing/does not carry the refusal" "$log7d: $(cat "$log7d" 2>/dev/null || echo ABSENT)"
fi

# --- HANDOVER_DIR set to a real (temp) dir, no ledger-root seam -------------
# The twin control: with HANDOVER_DIR actually resolvable, the SAME env -i
# scenario completes normally and the ledger lands under it.
echo "TEST: env -i with HANDOVER_DIR set to a resolvable dir (no ledger-root seam) -> ledger lands there"
REPO7e="$TMP_ROOT/t7e-primary"; BARE7e="$TMP_ROOT/t7e-origin.git"
HOME7e="$TMP_ROOT/t7e-home"; HANDOVER7e="$TMP_ROOT/t7e-handover"
mkdir -p "$HOME7e" "$HANDOVER7e"
seed_repo "$REPO7e" "$BARE7e" 20
: > "$FAKE_MERGE_LOG"
rc=0
out=$(env -i \
        HOME="$HOME7e" \
        PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
        FORGE=github \
        GH_CMD="$FAKE_GH" \
        FAKE_GH_LOG="$FAKE_GH_LOG" \
        GRAPH_CADENCE_MERGE_ON_GREEN="$FAKE_MERGE" \
        FAKE_MERGE_LOG="$FAKE_MERGE_LOG" \
        GRAPH_CADENCE_HIMMEL_ROOT="$REPO7e" \
        HANDOVER_DIR="$HANDOVER7e" \
        bash "$CADENCE" --threshold 10 2>&1) || rc=$?
assert_eq "HANDOVER_DIR-set (no seam) run rc=0" "0" "$rc"
ledger7e=$(tail -n1 "$HANDOVER7e/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger lands under the resolvable HANDOVER_DIR, not the seam" '"action":"merged"' "$ledger7e"

# =============================================================================
# PR-B panel r1 tests (codex-1 through codex-6)
# =============================================================================

# --- codex-3: --corpus-root refuses anything but the resolved primary ------
echo "TEST: --corpus-root pointing at a DIFFERENT repo is refused (rc=1), never silently publishes the wrong corpus"
REPO_A="$TMP_ROOT/corpus-a"; BARE_A="$TMP_ROOT/corpus-a-origin.git"
REPO_B="$TMP_ROOT/corpus-b"; BARE_B="$TMP_ROOT/corpus-b-origin.git"
seed_repo "$REPO_A" "$BARE_A" 20
seed_repo "$REPO_B" "$BARE_B" 3
LEDGER_CORPUS_A="$TMP_ROOT/corpus-a-ledger"
mkdir -p "$LEDGER_CORPUS_A" "$TMP_ROOT/corpus-refusal-home" "$TMP_ROOT/corpus-ok-home"
rc=0
out=$(HOME="$TMP_ROOT/corpus-refusal-home" GRAPH_CADENCE_HIMMEL_ROOT="$REPO_A" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER_CORPUS_A" \
      run_gc --threshold 10 --corpus-root "$REPO_B" 2>&1) || rc=$?
assert_eq "mismatched --corpus-root rc=1" "1" "$rc"
assert_contains "refusal names the flag" "--corpus-root" "$out"
assert_contains "refusal says himmel is the only wired corpus" "only corpus this script is wired for" "$out"

echo "TEST: --corpus-root equal to the resolved primary is accepted (the only value that works today)"
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$TMP_ROOT/corpus-ok-home" GRAPH_CADENCE_HIMMEL_ROOT="$REPO_A" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER_CORPUS_A" \
      run_gc --threshold 10 --corpus-root "$REPO_A" 2>&1) || rc=$?
assert_eq "matching --corpus-root proceeds normally" "0" "$rc"
assert_not_contains "matching --corpus-root is not refused" "only corpus this script is wired for" "$out"

# --- codex-2: identity check refuses a foreign checkout at WORKTREE_DIR ----
echo "TEST: a foreign (non-worktree) git checkout squatting at WORKTREE_DIR is refused, never destroyed"
REPO4c="$TMP_ROOT/t4c-primary"; BARE4c="$TMP_ROOT/t4c-origin.git"
HOME4c="$TMP_ROOT/t4c-home"; LEDGER4c="$TMP_ROOT/t4c-ledger"
mkdir -p "$HOME4c" "$LEDGER4c"
seed_repo "$REPO4c" "$BARE4c" 20
CORPUS_SLUG4c=$(corpus_slug_of "$REPO4c")
FOREIGN_WT="$HOME4c/.claude/graph-cadence/$CORPUS_SLUG4c"
mkdir -p "$(dirname "$FOREIGN_WT")"
git init -q "$FOREIGN_WT" >/dev/null 2>&1
git -C "$FOREIGN_WT" config user.email t@test.com
git -C "$FOREIGN_WT" config user.name test
echo "unrelated, uncommitted, precious work" > "$FOREIGN_WT/precious-uncommitted-file.txt"
rc=0
out=$(HOME="$HOME4c" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4c" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4c" \
      run_gc --threshold 10 2>&1) || rc=$?
if [ "$rc" != "0" ]; then pass "foreign checkout at WORKTREE_DIR is refused (non-zero rc, got $rc)"; else fail "foreign checkout run returned rc=0"; fi
assert_contains "refusal names the missing ownership marker" "no graph-cadence ownership marker" "$out"
if [ -f "$FOREIGN_WT/precious-uncommitted-file.txt" ]; then
    pass "the foreign checkout's uncommitted file survives untouched"
else
    fail "the foreign checkout's file was destroyed -- this is exactly the class codex-2 exists to prevent"
fi
foreign_content=$(cat "$FOREIGN_WT/precious-uncommitted-file.txt" 2>/dev/null || echo MISSING)
assert_contains "the foreign checkout's file content is byte-identical (no reset/clean ran)" "unrelated, uncommitted, precious work" "$foreign_content"
LEDGER_LINE4c=$(tail -n1 "$LEDGER4c/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger records this as failed, not a silent skip" '"action":"failed"' "$LEDGER_LINE4c"

# --- codex-2 (PR-B panel r2, hardened): the round-1 regression case. A
# SIBLING WORKTREE of the SAME repo -- not a foreign clone -- squatting at
# WORKTREE_DIR. Round 1's --git-common-dir check would have PASSED this
# (same repo!) and gone on to checkout/reset/clean it, destroying whatever
# that sibling worktree had uncommitted. This is the exact gap the panel
# named as "the single most dangerous item on either PR".
echo "TEST: a SIBLING WORKTREE of the SAME repo squatting at WORKTREE_DIR is refused too (round-1's exact gap)"
REPO4g="$TMP_ROOT/t4g-primary"; BARE4g="$TMP_ROOT/t4g-origin.git"
HOME4g="$TMP_ROOT/t4g-home"; LEDGER4g="$TMP_ROOT/t4g-ledger"
mkdir -p "$HOME4g" "$LEDGER4g"
seed_repo "$REPO4g" "$BARE4g" 20
CORPUS_SLUG4g=$(corpus_slug_of "$REPO4g")
SIBLING_WT="$HOME4g/.claude/graph-cadence/$CORPUS_SLUG4g"
mkdir -p "$(dirname "$SIBLING_WT")"
# A REAL worktree of REPO4g -- git worktree add, not git init. Its
# --git-common-dir genuinely matches REPO4g's own, so it would have passed
# round 1's check outright.
git -C "$REPO4g" worktree add -q "$SIBLING_WT" -b some-other-feature-branch >/dev/null 2>&1
echo "sibling worktree's own uncommitted, precious work" > "$SIBLING_WT/sibling-precious-file.txt"
rc=0
out=$(HOME="$HOME4g" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4g" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4g" \
      run_gc --threshold 10 2>&1) || rc=$?
if [ "$rc" != "0" ]; then pass "sibling worktree squatting at WORKTREE_DIR is refused (non-zero rc, got $rc)"; else fail "sibling-worktree run returned rc=0 -- ROUND-1's EXACT GAP IS STILL OPEN"; fi
assert_contains "refusal names the missing ownership marker" "no graph-cadence ownership marker" "$out"
sibling_content=$(cat "$SIBLING_WT/sibling-precious-file.txt" 2>/dev/null || echo MISSING)
assert_contains "the sibling worktree's file survives byte-identical (no reset/clean ran)" "sibling worktree's own uncommitted, precious work" "$sibling_content"
sibling_branch=$(git -C "$SIBLING_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo MISSING)
assert_eq "the sibling worktree's own branch is untouched (not switched to graph-cadence-work)" "some-other-feature-branch" "$sibling_branch"
git -C "$REPO4g" worktree remove --force "$SIBLING_WT" >/dev/null 2>&1 || true

# --- codex-2 (cont.): WORKTREE_DIR resolving to the PRIMARY CHECKOUT ITSELF
# -- the single most catastrophic instance -- rejected explicitly.
echo "TEST: WORKTREE_DIR resolving to the PRIMARY checkout itself is refused explicitly"
REPO4h="$TMP_ROOT/t4h-primary"; BARE4h="$TMP_ROOT/t4h-origin.git"
HOME4h="$TMP_ROOT/t4h-home"; LEDGER4h="$TMP_ROOT/t4h-ledger"
mkdir -p "$HOME4h" "$LEDGER4h"
seed_repo "$REPO4h" "$BARE4h" 20
rc=0
out=$(HOME="$HOME4h" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4h" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4h" \
      GRAPH_CADENCE_WORKTREE_DIR="$REPO4h" \
      run_gc --threshold 10 2>&1) || rc=$?
if [ "$rc" != "0" ]; then pass "WORKTREE_DIR=primary is refused (non-zero rc, got $rc)"; else fail "WORKTREE_DIR=primary run returned rc=0"; fi
assert_contains "refusal names the primary-checkout case explicitly" "resolves to the PRIMARY checkout itself" "$out"
primary_branch4h=$(git -C "$REPO4h" rev-parse --abbrev-ref HEAD 2>/dev/null || echo MISSING)
assert_eq "the primary checkout's own branch is untouched" "main" "$primary_branch4h"

# --- codex-2 (cont.): the ownership marker persists across runs (re-stamped
# after clean -fdx, which would otherwise wipe it as untracked) -- a SECOND
# legitimate run against the SAME dedicated worktree must succeed, not be
# refused as "foreign" by its own prior run's cleanup.
echo "TEST: a second run against the SAME dedicated worktree succeeds (ownership marker survives clean -fdx)"
REPO4i="$TMP_ROOT/t4i-primary"; BARE4i="$TMP_ROOT/t4i-origin.git"
HOME4i="$TMP_ROOT/t4i-home"; LEDGER4i="$TMP_ROOT/t4i-ledger"
mkdir -p "$HOME4i" "$LEDGER4i"
seed_repo "$REPO4i" "$BARE4i" 20
: > "$FAKE_MERGE_LOG"
rc=0
run_gc_env4i() {
    HOME="$HOME4i" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4i" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4i" run_gc --threshold 10
}
out1=$(run_gc_env4i 2>&1) || rc=$?
assert_eq "first run against a fresh worktree succeeds" "0" "$rc"
assert_not_contains "first run is not refused as foreign (it just created the worktree)" "no graph-cadence ownership marker" "$out1"
rc=0
out2=$(run_gc_env4i 2>&1) || rc=$?
assert_eq "second run against the SAME worktree also succeeds (marker survived)" "0" "$rc"
assert_not_contains "second run is not refused as foreign" "no graph-cadence ownership marker" "$out2"

# --- codex-1: pipeline lock serializes overlapping runs ---------------------
echo "TEST: a held pipeline lock makes an overlapping run skip cleanly, never touching the worktree"
REPO4d="$TMP_ROOT/t4d-primary"; BARE4d="$TMP_ROOT/t4d-origin.git"
HOME4d="$TMP_ROOT/t4d-home"; LEDGER4d="$TMP_ROOT/t4d-ledger"
mkdir -p "$HOME4d" "$LEDGER4d"
seed_repo "$REPO4d" "$BARE4d" 20
CORPUS_SLUG4d=$(corpus_slug_of "$REPO4d")
PRE_LOCK="$HOME4d/.claude/graph-cadence/${CORPUS_SLUG4d}.lock"
mkdir -p "$(dirname "$PRE_LOCK")"
mkdir "$PRE_LOCK"
# A LIVE holder (this test shell) on this host -- a dead one is refused, not
# skipped (HIMMEL-2654; see the stale-lock case further down).
echo "$$" > "$PRE_LOCK/pid"
uname -n > "$PRE_LOCK/host"
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME4d" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4d" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4d" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq "lock-contended run exits 0 (skip, not a failure)" "0" "$rc"
assert_contains "run reports the pipeline lock" "pipeline lock" "$out"
LEDGER_LINE4d=$(tail -n1 "$LEDGER4d/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=skipped on lock contention" '"action":"skipped"' "$LEDGER_LINE4d"
assert_eq "lock-contended run never invoked merge-on-green" "" "$(cat "$FAKE_MERGE_LOG")"
if [ -d "$HOME4d/.claude/graph-cadence/$CORPUS_SLUG4d" ]; then
    fail "lock-contended run created the worktree anyway" "$(ls "$HOME4d/.claude/graph-cadence/$CORPUS_SLUG4d" 2>/dev/null)"
else
    pass "lock-contended run never created/touched the worktree"
fi
rm -rf "$PRE_LOCK"

# (A STALE lock -- crashed prior run -- was TAKEN OVER here until HIMMEL-2654;
# it now blocks every fire loudly until a human removes it. Covered by the
# HIMMEL-2654 "STALE lock blocks and is reported" case below.)

# --- codex-3: a `git clean -fdx` failure aborts the pipeline (hard failure,
# never a silent `|| true` that lets refresh/publish proceed on an unproven
# tree). Isolated to `clean` specifically: an untracked, permission-locked
# subdirectory blocks `clean -fdx` from removing it while leaving `checkout
# -B`/`reset --hard` (which never touch untracked files) unaffected --
# proving THIS step's own failure is what aborts the run, not some other
# unrelated breakage.
echo "TEST: a git clean -fdx failure on the dedicated worktree aborts the pipeline (never a silent skip)"
REPO4k="$TMP_ROOT/t4k-primary"; BARE4k="$TMP_ROOT/t4k-origin.git"
HOME4k="$TMP_ROOT/t4k-home"; LEDGER4k="$TMP_ROOT/t4k-ledger"
mkdir -p "$HOME4k" "$LEDGER4k"
seed_repo "$REPO4k" "$BARE4k" 20
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME4k" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4k" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4k" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq "first run (establishes the dedicated worktree) succeeds" "0" "$rc"
CORPUS_SLUG4k=$(corpus_slug_of "$REPO4k")
WT4k="$HOME4k/.claude/graph-cadence/$CORPUS_SLUG4k"
mkdir -p "$WT4k/locked-untracked-dir"
touch "$WT4k/locked-untracked-dir/blocks-removal"
chmod 000 "$WT4k/locked-untracked-dir"
# CodeRabbit (PR #2209) + panel codex, four raises across three rounds
# (HIMMEL-2655 item 5). `chmod 000` is this case's ENTIRE mechanism, and it
# only denies a non-root user on a POSIX filesystem: root ignores the bits and
# Windows Git Bash does not enforce them on traversal or deletion. Where it
# does not bite, `clean -fdx` SUCCEEDS, the run exits 0, and the assertions
# below report a pipeline defect that does not exist -- a red test for an
# environment reason, which is the mirror of the green-but-meaningless tests
# this branch spent three rounds removing.
#
# Probe the FIXTURE, not the platform: ask whether this directory is actually
# unreadable to US right now. That covers root, Git Bash, an exotic
# filesystem, and anything else we have not thought of, without enumerating
# them -- and it cannot drift out of step with the mechanism the way an
# `id -u` / $OSTYPE check would. Same shape as the C33 unreadable-ledger case
# in scripts/test-himmel-doctor.sh, which probes with `tail` for the same
# reason.
if ls "$WT4k/locked-untracked-dir" >/dev/null 2>&1; then
    echo "  SKIP: clean -fdx failure case — chmod 000 does not deny this user/filesystem, so the fixture cannot be built"
    chmod 755 "$WT4k/locked-untracked-dir" 2>/dev/null || true
else
    rc=0
    out2=$(HOME="$HOME4k" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4k" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4k" \
           run_gc --threshold 10 2>&1) || rc=$?
    chmod 755 "$WT4k/locked-untracked-dir" 2>/dev/null || true
    if [ "$rc" != "0" ]; then pass "clean -fdx failure aborts the pipeline (non-zero rc, got $rc)"; else fail "clean -fdx failure run returned rc=0"; fi
    assert_contains "failure names git clean specifically" "clean -fdx failed" "$out2"
    LEDGER_LINE4k=$(tail -n1 "$LEDGER4k/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
    assert_contains "ledger action=failed on a clean -fdx failure" '"action":"failed"' "$LEDGER_LINE4k"
fi
rm -rf "$WT4k/locked-untracked-dir" 2>/dev/null || true

# --- codex-5: GRAPH_CADENCE_DOTENV_ROOT actually redirects (positive control)
echo "TEST: GRAPH_CADENCE_DOTENV_ROOT redirects the HANDOVER_DIR read for real (not just a no-op seam)"
REPO4e="$TMP_ROOT/t4e-primary"; BARE4e="$TMP_ROOT/t4e-origin.git"
HOME4e="$TMP_ROOT/t4e-home"
DOTENV4e="$TMP_ROOT/t4e-dotenv"; HANDOVER4e="$TMP_ROOT/t4e-handover"
mkdir -p "$HOME4e" "$DOTENV4e" "$HANDOVER4e"
printf 'HANDOVER_DIR=%s\n' "$HANDOVER4e" > "$DOTENV4e/.env"
seed_repo "$REPO4e" "$BARE4e" 3
rc=0
out=$(env -i \
        HOME="$HOME4e" \
        PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
        GRAPH_CADENCE_HIMMEL_ROOT="$REPO4e" \
        GRAPH_CADENCE_DOTENV_ROOT="$DOTENV4e" \
        bash "$CADENCE" --threshold 10 2>&1) || rc=$?
assert_eq "dotenv-supplied HANDOVER_DIR is honoured, no refusal" "0" "$rc"
assert_not_contains "no HANDOVER_DIR-unset refusal when the seam supplies one" "HANDOVER_DIR is unset" "$out"
ledger4e=$(tail -n1 "$HANDOVER4e/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "the ledger lands under the .env-supplied HANDOVER_DIR" '"action":"skipped"' "$ledger4e"

# --- codex-6: a failed ledger.jsonl append is a hard failure (exit 4) ------
echo "TEST: a failed append to ledger.jsonl is surfaced as exit 4, never masked by a successful flow-run write"
REPO4f="$TMP_ROOT/t4f-primary"; BARE4f="$TMP_ROOT/t4f-origin.git"
HOME4f="$TMP_ROOT/t4f-home"; LEDGER4f="$TMP_ROOT/t4f-ledger"
FLOW_LEDGER4f="$TMP_ROOT/t4f-flow-runs.jsonl"
mkdir -p "$HOME4f" "$LEDGER4f/.graph-cadence"
# ledger.jsonl is a DIRECTORY, not a file -- the `>>` append inside
# _write_ledger will fail with "Is a directory".
mkdir "$LEDGER4f/.graph-cadence/ledger.jsonl"
seed_repo "$REPO4f" "$BARE4f" 3
rc=0
out=$(HOME="$HOME4f" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4f" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4f" \
      HIMMEL_FLOW_RUNS_LEDGER="$FLOW_LEDGER4f" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq "failed ledger append exits 4" "4" "$rc"
assert_contains "failure names the ledger append" "UNRECORDED" "$out"
flow4f=$(cat "$FLOW_LEDGER4f" 2>/dev/null || echo MISSING)
assert_contains "the flow-run end row's own outcome is ALSO error (not masked)" '"outcome":"error"' "$flow4f"

# =============================================================================
# HIMMEL-2654: the pipeline lock is single-winner -- mkdir is the whole
# protocol (scripts/luna/qmd-cadence.sh precedent). A PATH-stub `git` counts
# every `reset --hard` (the first destructive step) -- a stub, never a code
# seam, so the SAME fixture drives the pre-fix code as its RED control. The
# fake graphify holds each run that gets past the sync (FAKE_GRAPHIFY_HOLD_DIR),
# so a holder is provably LIVE while its rival decides.
# =============================================================================
LOCKBIN="$TMP_ROOT/lockbin"
mkdir -p "$LOCKBIN"
REAL_GIT=$(command -v git)
cat > "$LOCKBIN/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" reset --hard "*) [ -n "\${LOCKTEST_RESET_LOG:-}" ] && echo "reset \$PPID" >> "\$LOCKTEST_RESET_LOG" ;; esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$LOCKBIN/git"

# wait_for <path-glob> <max-centiseconds> -- bounded poll; rc 1 on timeout.
wait_for() {
    local i=0
    # shellcheck disable=SC2086  # the glob is the point
    until ls $1 >/dev/null 2>&1; do
        [ "$i" -lt "$2" ] || return 1
        sleep 0.01; i=$((i + 1))
    done
}
# lock_fixture <n> -- seed a repo, establish its dedicated worktree with one
# clean run, and export REPO_L/HOME_L/LOCK_L/HOLD_L/RESETS_L for case <n>.
lock_fixture() {
    REPO_L="$TMP_ROOT/tl$1-primary"; HOME_L="$TMP_ROOT/tl$1-home"
    HOLD_L="$TMP_ROOT/tl$1-hold"; RESETS_L="$TMP_ROOT/tl$1-resets.log"
    mkdir -p "$HOME_L" "$HOLD_L" "$TMP_ROOT/tl$1-ledger-a" "$TMP_ROOT/tl$1-ledger-b"
    seed_repo "$REPO_L" "$TMP_ROOT/tl$1-origin.git" 20
    HOME="$HOME_L" GRAPH_CADENCE_HIMMEL_ROOT="$REPO_L" GRAPH_CADENCE_LEDGER_ROOT="$TMP_ROOT/tl$1-ledger-a" \
        run_gc --threshold 10 >/dev/null 2>&1 || true
    LOCK_L="$HOME_L/.claude/graph-cadence/$(corpus_slug_of "$REPO_L").lock"
    : > "$RESETS_L"
}
# lock_run <n> <a|b> -- one backgrounded run of case <n>; pid in LOCK_PID.
lock_run() {
    HOME="$HOME_L" GRAPH_CADENCE_HIMMEL_ROOT="$REPO_L" GRAPH_CADENCE_LEDGER_ROOT="$TMP_ROOT/tl$1-ledger-$2" \
        PATH="$LOCKBIN:$PATH" LOCKTEST_RESET_LOG="$RESETS_L" FAKE_GRAPHIFY_HOLD_DIR="$HOLD_L" \
        run_gc --threshold 10 > "$TMP_ROOT/tl$1-$2.out" 2>&1 &
    LOCK_PID=$!
}
# lock_fire <n> <ledger-suffix> -- one foreground run; sets rc and out.
lock_fire() {
    rc=0
    out=$(HOME="$HOME_L" GRAPH_CADENCE_HIMMEL_ROOT="$REPO_L" GRAPH_CADENCE_LEDGER_ROOT="$TMP_ROOT/tl$1-ledger-$2" \
          PATH="$LOCKBIN:$PATH" LOCKTEST_RESET_LOG="$RESETS_L" run_gc --threshold 10 2>&1) || rc=$?
}
# wait_exit_or_resets <pid> <n-resets> <max-centiseconds> -- until the run
# exits (it lost) or the reset count reaches n (it got in).
wait_exit_or_resets() {
    local i=0
    while kill -0 "$1" 2>/dev/null && [ "$(wc -l < "$RESETS_L")" -lt "$2" ]; do
        [ "$i" -lt "$3" ] || return 1
        sleep 0.01; i=$((i + 1))
    done
}
# A pid that provably belonged to a process that has exited.
true & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
LOCK_HOST=$(uname -n)

echo "TEST (HIMMEL-2654): two CONCURRENT runs -- a live (and old-looking) holder is never evicted"
lock_fixture 2
lock_run 2 b; PID_B=$LOCK_PID
wait_for "$HOLD_L/entered.*" 3000 || fail "holder never entered the pipeline"
# Make the live holder's lock look old by every age signal it carries.
for _f in acquired heartbeat; do
    [ -e "$LOCK_L/$_f" ] && echo "$(( $(date -u +%s) - 7200 ))" > "$LOCK_L/$_f"
done
lock_run 2 a; PID_A=$LOCK_PID
wait_exit_or_resets "$PID_A" 2 3000 || true
: > "$HOLD_L/release"
rc_a=0; wait "$PID_A" 2>/dev/null || rc_a=$?
wait "$PID_B" 2>/dev/null || true
assert_eq "exactly ONE run reached reset --hard (the destructive step)" "1" "$(wc -l < "$RESETS_L" | tr -d ' ')"
assert_eq "the contender exits 0 (a live holder is a benign skip)" "0" "$rc_a"
ledger_a=$(tail -n1 "$TMP_ROOT/tl2-ledger-a/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "the contender skipped" '"action":"skipped"' "$ledger_a"
assert_contains "the skip names the live holder" "is alive" "$(cat "$TMP_ROOT/tl2-a.out")"
if [ -d "$LOCK_L" ]; then fail "holder left its lock behind" "$(ls "$LOCK_L")"; else pass "holder released its lock on exit"; fi

echo "TEST (HIMMEL-2654): a STALE lock blocks and is reported loudly, never taken over"
lock_fixture 1
mkdir "$LOCK_L"
echo "crashed-holder" > "$LOCK_L/owner"
echo "$DEAD_PID" > "$LOCK_L/pid"
echo "$LOCK_HOST" > "$LOCK_L/host"
echo "$(( $(date -u +%s) - 7200 ))" > "$LOCK_L/acquired"
echo "$(( $(date -u +%s) - 7200 ))" > "$LOCK_L/heartbeat"
for _fire in a b; do
    lock_fire 1 "$_fire"
    assert_eq "fire $_fire: refuses non-zero (rc 3)" "3" "$rc"
    assert_contains "fire $_fire: names the dead holder" "stale: holder pid $DEAD_PID dead" "$out"
    assert_contains "fire $_fire: names the lock path" "$LOCK_L" "$out"
    assert_contains "fire $_fire: names the lock's age" "acquired 720" "$out"
    ledger=$(tail -n1 "$TMP_ROOT/tl1-ledger-$_fire/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
    assert_contains "fire $_fire: ledger records action=failed" '"action":"failed"' "$ledger"
    assert_contains "fire $_fire: ledger names the stale holder" "stale: holder pid $DEAD_PID dead" "$ledger"
done
assert_eq "nothing destructive ran while the stale lock stood" "0" "$(wc -l < "$RESETS_L" | tr -d ' ')"
assert_eq "the stale lock is left untouched for the operator" "crashed-holder" "$(cat "$LOCK_L/owner" 2>/dev/null)"
# The operator removes it by hand; the next fire runs normally.
rm -rf "$LOCK_L"
lock_fire 1 c
assert_eq "after a human removes the lock, the next fire completes" "0" "$rc"
assert_eq "...and reaches reset --hard exactly once" "1" "$(wc -l < "$RESETS_L" | tr -d ' ')"

echo "TEST (HIMMEL-2654): a stamp-less lock (holder died between mkdir and its pid write) is reported, never taken over"
lock_fixture 5
mkdir "$LOCK_L"
touch -t 202001010000 "$LOCK_L"
lock_fire 5 a
assert_eq "stamp-less lock: refuses non-zero (rc 3)" "3" "$rc"
assert_contains "stamp-less lock: reported stale with an unknown holder" "stale: holder pid unknown dead" "$out"
assert_eq "stamp-less lock: nothing destructive ran" "0" "$(wc -l < "$RESETS_L" | tr -d ' ')"
if [ -d "$LOCK_L" ] && [ -z "$(ls -A "$LOCK_L")" ]; then pass "stamp-less lock: left untouched"; else fail "stamp-less lock: was modified or removed" "$(ls -A "$LOCK_L" 2>&1)"; fi
rm -rf "$LOCK_L"

echo "TEST (HIMMEL-2654): a fresh HEARTBEAT keeps another host's lock (pid not checkable here) a benign skip"
lock_fixture 3
mkdir "$LOCK_L"
echo "holder-on-another-host" > "$LOCK_L/owner"
echo "1" > "$LOCK_L/pid"
echo "some-other-host" > "$LOCK_L/host"
echo "$(( $(date -u +%s) - 7200 ))" > "$LOCK_L/acquired"
date -u +%s > "$LOCK_L/heartbeat"
lock_fire 3 a
assert_eq "heartbeat-live lock: contender exits 0" "0" "$rc"
assert_eq "heartbeat-live lock: nothing destructive ran" "0" "$(wc -l < "$RESETS_L" | tr -d ' ')"
assert_contains "heartbeat-live lock: the skip names the heartbeat" "last heartbeat" "$out"
assert_eq "heartbeat-live lock: the holder's lock is untouched" "holder-on-another-host" "$(cat "$LOCK_L/owner" 2>/dev/null)"
rm -rf "$LOCK_L"

echo "TEST (HIMMEL-2654): the holder's heartbeat ADVANCES, and its EXIT trap removes only its OWN lock"
lock_fixture 4
HOME="$HOME_L" GRAPH_CADENCE_HIMMEL_ROOT="$REPO_L" GRAPH_CADENCE_LEDGER_ROOT="$TMP_ROOT/tl4-ledger-b" \
    GRAPH_CADENCE_LOCK_HEARTBEAT_SECONDS=1 FAKE_GRAPHIFY_HOLD_DIR="$HOLD_L" \
    run_gc --threshold 10 > "$TMP_ROOT/tl4-b.out" 2>&1 &
PID_B=$!
wait_for "$HOLD_L/entered.*" 3000 || fail "holder never entered the pipeline"
echo "0" > "$LOCK_L/heartbeat"
_i=0
while [ "$(cat "$LOCK_L/heartbeat" 2>/dev/null)" = "0" ] && [ "$_i" -lt 500 ]; do sleep 0.01; _i=$((_i + 1)); done
_hb=$(cat "$LOCK_L/heartbeat" 2>/dev/null || echo 0)
if [ "$(( $(date -u +%s) - _hb ))" -lt 10 ]; then pass "heartbeat was re-stamped by the live holder"; else fail "heartbeat never advanced" "heartbeat=$_hb"; fi
_lpid=$(cat "$LOCK_L/pid" 2>/dev/null || echo none)
if kill -0 "$_lpid" 2>/dev/null; then pass "lock records a LIVE holder pid"; else fail "lock pid is not a live process" "pid=$_lpid"; fi
: > "$HOLD_L/release"
rc=0; wait "$PID_B" || rc=$?
assert_eq "heartbeating holder completes normally" "0" "$rc"
if [ -d "$LOCK_L" ]; then fail "holder left its lock behind" "$(ls "$LOCK_L")"; else pass "holder released its lock on exit"; fi
# Same holder shape, but its lock is replaced mid-run (removed by hand and
# re-created by another run): its exit must leave the other instance alone.
rm -rf "$HOLD_L"; mkdir -p "$HOLD_L"
HOME="$HOME_L" GRAPH_CADENCE_HIMMEL_ROOT="$REPO_L" GRAPH_CADENCE_LEDGER_ROOT="$TMP_ROOT/tl4-ledger-b" \
    FAKE_GRAPHIFY_HOLD_DIR="$HOLD_L" run_gc --threshold 10 > "$TMP_ROOT/tl4-c.out" 2>&1 &
PID_C=$!
wait_for "$HOLD_L/entered.*" 3000 || fail "second holder never entered the pipeline"
echo "another-instance" > "$LOCK_L/owner"
: > "$HOLD_L/release"
wait "$PID_C" 2>/dev/null || true
assert_eq "a lock this run did not create survives its exit" "another-instance" "$(cat "$LOCK_L/owner" 2>/dev/null)"
rm -rf "$LOCK_L"

# =============================================================================
# Test 8: usage errors
# =============================================================================
echo "TEST: usage errors exit 1"
# GRAPH_CADENCE_HIMMEL_ROOT is pinned so a run that got past arg parsing
# could never fall back to the real primary checkout.
rc=0; out=$(GRAPH_CADENCE_HIMMEL_ROOT="$TMP_ROOT" run_gc --threshold not-a-number 2>&1) || rc=$?
assert_eq "non-numeric --threshold rc=1" "1" "$rc"
rc=0; out=$(GRAPH_CADENCE_HIMMEL_ROOT="$TMP_ROOT" run_gc --bogus-flag 2>&1) || rc=$?
assert_eq "unknown flag rc=1" "1" "$rc"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
