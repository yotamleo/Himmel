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

# HIMMEL-2654 STOP SIGN: graph-cadence.sh now refuses to run at all (exit 2)
# unless GRAPH_CADENCE_BYPASS_2654_GUARD=1 *and* GRAPH_CADENCE_HIMMEL_ROOT are
# both set (see the guard at the top of graph-cadence.sh). Every caller of
# run_gc() already sets GRAPH_CADENCE_HIMMEL_ROOT as an env-prefix before the
# call, so exporting the bypass here -- and ONLY here, inside the test
# harness -- lets the pipeline-logic tests below keep exercising the code the
# guard sits in front of, while the guard itself stays structurally
# unreachable from any real cadence invocation (cron, manual, arm) that never
# sets GRAPH_CADENCE_HIMMEL_ROOT. The dedicated refusal test (below) calls
# graph-cadence.sh directly, NOT through run_gc, so it still sees the
# default-refuses behaviour. Deleted alongside the guard itself when
# HIMMEL-2654 lands (see graph-cadence.sh's own REMOVAL TRIGGER comment).
run_gc() {
    PATH="$FAKE_BIN:$PATH" \
    FORGE=github \
    GH_CMD="$FAKE_GH" \
    FAKE_GH_LOG="$FAKE_GH_LOG" \
    GRAPH_CADENCE_MERGE_ON_GREEN="$FAKE_MERGE" \
    FAKE_MERGE_LOG="$FAKE_MERGE_LOG" \
    GRAPH_CADENCE_BYPASS_2654_GUARD=1 \
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
# Test 2: at/above threshold -> full pipeline, merged
# =============================================================================
echo "TEST: at/above threshold refreshes+publishes+merges (merge-on-green rc=0)"
REPO2="$TMP_ROOT/t2-primary"; BARE2="$TMP_ROOT/t2-origin.git"
HOME2="$TMP_ROOT/t2-home"; LEDGER2="$TMP_ROOT/t2-ledger"
mkdir -p "$HOME2" "$LEDGER2"
seed_repo "$REPO2" "$BARE2" 20
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME2" GRAPH_CADENCE_HIMMEL_ROOT="$REPO2" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER2" FAKE_MERGE_RC=0 \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq        "full-pipeline rc=0" "0" "$rc"
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
        GRAPH_CADENCE_BYPASS_2654_GUARD=1 \
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
        GRAPH_CADENCE_BYPASS_2654_GUARD=1 \
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
        GRAPH_CADENCE_BYPASS_2654_GUARD=1 \
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
        GRAPH_CADENCE_BYPASS_2654_GUARD=1 \
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
        GRAPH_CADENCE_BYPASS_2654_GUARD=1 \
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
rmdir "$PRE_LOCK" 2>/dev/null || true

# --- codex-1 (PR-B panel r2, hardened): a STALE lock (old "acquired" stamp,
# simulating a crashed prior run -- reboot/SIGKILL leaves exactly this
# behind) is TAKEN OVER, not honoured forever. Before this fix a lock with no
# owner/staleness recovery at all would make EVERY subsequent above-threshold
# run report a successful skip while refreshing and publishing nothing --
# forever, since nothing but a clean release ever removed it.
echo "TEST: a STALE pipeline lock (crashed prior run) is taken over, not honoured forever"
REPO4j="$TMP_ROOT/t4j-primary"; BARE4j="$TMP_ROOT/t4j-origin.git"
HOME4j="$TMP_ROOT/t4j-home"; LEDGER4j="$TMP_ROOT/t4j-ledger"
mkdir -p "$HOME4j" "$LEDGER4j"
seed_repo "$REPO4j" "$BARE4j" 20
CORPUS_SLUG4j=$(corpus_slug_of "$REPO4j")
STALE_LOCK="$HOME4j/.claude/graph-cadence/${CORPUS_SLUG4j}.lock"
mkdir -p "$(dirname "$STALE_LOCK")"
mkdir "$STALE_LOCK"
echo "crashed-holder-pid-not-us" > "$STALE_LOCK/owner"
STALE_EPOCH=$(( $(date -u +%s) - 7200 ))
echo "$STALE_EPOCH" > "$STALE_LOCK/acquired"
: > "$FAKE_MERGE_LOG"
rc=0
out=$(HOME="$HOME4j" GRAPH_CADENCE_HIMMEL_ROOT="$REPO4j" GRAPH_CADENCE_LEDGER_ROOT="$LEDGER4j" \
      run_gc --threshold 10 2>&1) || rc=$?
assert_eq "stale-lock takeover run completes normally (not a skip)" "0" "$rc"
assert_contains "run reports taking over the stale lock" "is stale" "$out"
LEDGER_LINE4j=$(tail -n1 "$LEDGER4j/.graph-cadence/ledger.jsonl" 2>/dev/null || echo MISSING)
assert_contains "ledger action=merged -- the run actually refreshed+published+merged, not skipped" '"action":"merged"' "$LEDGER_LINE4j"
assert_not_contains "ledger action is not skipped for a stale-lock takeover" '"action":"skipped"' "$LEDGER_LINE4j"

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
        GRAPH_CADENCE_BYPASS_2654_GUARD=1 \
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
# Test 8: usage errors
# =============================================================================
echo "TEST: usage errors exit 1"
# GRAPH_CADENCE_HIMMEL_ROOT is set here purely to satisfy run_gc()'s
# HIMMEL-2654 bypass double-gate (see run_gc()'s own comment) -- arg parsing
# happens before this script ever reads it for real, so any value works.
rc=0; out=$(GRAPH_CADENCE_HIMMEL_ROOT="$TMP_ROOT" run_gc --threshold not-a-number 2>&1) || rc=$?
assert_eq "non-numeric --threshold rc=1" "1" "$rc"
rc=0; out=$(GRAPH_CADENCE_HIMMEL_ROOT="$TMP_ROOT" run_gc --bogus-flag 2>&1) || rc=$?
assert_eq "unknown flag rc=1" "1" "$rc"

# =============================================================================
# Test 9: HIMMEL-2654 stop sign -- the script refuses to run AT ALL today.
# This test does NOT go through run_gc() (which pins the test-only bypass for
# every OTHER test in this file) -- it calls graph-cadence.sh directly, the
# same way cron or an operator would, to prove the guard is on by default. A
# check for "non-zero rc" alone would pass for any unrelated breakage, so
# this asserts both the exact exit code (2) AND that the message names the
# ticket. When HIMMEL-2654 lands, this test (along with the guard itself and
# the doc note in docs/internals/graph-cadence.md) gets deleted -- see the
# REMOVAL TRIGGER comment at the top of graph-cadence.sh.
# =============================================================================
echo "TEST: HIMMEL-2654 stop sign -- refuses to run today, by default, unconditionally"
rc=0
out=$(env -i PATH="/usr/bin:/bin" bash "$CADENCE" 2>&1) || rc=$?
assert_eq "bare invocation (no args, no special env) refuses with rc=2" "2" "$rc"
assert_contains "the refusal message names HIMMEL-2654" "HIMMEL-2654" "$out"

rc=0
out=$(env -i PATH="/usr/bin:/bin" bash "$CADENCE" --threshold 5 2>&1) || rc=$?
assert_eq "refusal fires even with a valid --threshold (before arg parsing runs anything)" "2" "$rc"
assert_contains "the --threshold-args refusal message also names HIMMEL-2654" "HIMMEL-2654" "$out"

# GRAPH_CADENCE_HIMMEL_ROOT ALONE is not enough -- the bypass is double-gated
# exactly like the existing GRAPH_CADENCE_DOTENV_ROOT seam, so accidentally
# having HIMMEL_ROOT set (as every other test in this file does, via run_gc's
# callers) does not, by itself, punch a hole in the default refusal.
rc=0
out=$(env -i PATH="/usr/bin:/bin" GRAPH_CADENCE_HIMMEL_ROOT="$TMP_ROOT" bash "$CADENCE" 2>&1) || rc=$?
assert_eq "GRAPH_CADENCE_HIMMEL_ROOT alone (no bypass var) still refuses with rc=2" "2" "$rc"
assert_contains "still names HIMMEL-2654 with HIMMEL_ROOT set alone" "HIMMEL-2654" "$out"

# The MIRROR RED control (02R console ruling, N16b): the bypass var ALONE,
# with GRAPH_CADENCE_HIMMEL_ROOT unset, must also still refuse. Without this
# row the suite proves only one half of the double gate -- a future edit that
# collapsed the `||` to test the bypass var alone would leave every assertion
# above green while turning the stop sign into a single-variable off switch
# that any environment could flip. This is the row that makes the SEAM itself
# inert outside a fixture, not merely the guard present.
rc=0
out=$(env -i PATH="/usr/bin:/bin" GRAPH_CADENCE_BYPASS_2654_GUARD=1 bash "$CADENCE" 2>&1) || rc=$?
assert_eq "the bypass var alone (no GRAPH_CADENCE_HIMMEL_ROOT) still refuses with rc=2" "2" "$rc"
assert_contains "still names HIMMEL-2654 with the bypass var set alone" "HIMMEL-2654" "$out"

# The twin positive control: proves the bypass this file relies on for every
# OTHER test actually works, and works only when BOTH seams are present --
# i.e. proves run_gc()'s escape hatch is real, not a no-op that happens to
# not matter because those tests would pass anyway. TMP_ROOT is not a git
# checkout, so this run fails for some OTHER reason once past the guard --
# HOME is pinned (not left to getent-fallback) purely so that later, unrelated
# failure cannot write anything into real operator state; this test does not
# care how it fails, only that it is not THIS refusal.
HOME9="$TMP_ROOT/t9-positive-home"; mkdir -p "$HOME9"
rc=0
out=$(env -i PATH="/usr/bin:/bin" HOME="$HOME9" GRAPH_CADENCE_HIMMEL_ROOT="$TMP_ROOT" GRAPH_CADENCE_BYPASS_2654_GUARD=1 bash "$CADENCE" 2>&1) || rc=$?
assert_not_contains "both seams together actually bypass the stop sign (positive control)" "HIMMEL-2654 (unresolved)" "$out"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
