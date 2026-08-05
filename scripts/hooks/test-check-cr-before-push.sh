#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-cr-before-push.sh (HIMMEL-142).
#
# HIMMEL-142 locks the operator decision: pre-push CR is NOT exempted on
# handover/* branches — only handover-STATE-only diffs (handovers/) skip the
# marker. HIMMEL-303 then split the old docs-only skip: reviewable docs
# (docs/, *.md/*.txt outside handovers/) now write a `docs-audit`-lane marker
# (never zero CR), while handover state stays exempt and code still writes a
# `full`-lane marker. The marker's 3rd field carries the lane.
#
# Covers:
#   1. handover/* branch with state-only diff -> NO marker, exit 0.
#   2. handover/* branch with mixed code+state diff -> full-lane marker.
#   3. SKIP_CR=1 short-circuits regardless of branch.
#   4. main branch -> exit 0, no marker.
#   5. feature branch with docs-only diff -> docs-audit-lane marker.
#   6. mixed docs + handover-state (no code) -> docs-audit-lane marker.
#   + ancestor-pref (HIMMEL-295) now keyed on the marker lane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-cr-before-push.sh"

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

# Setup: tmp git repo with main + a branch we can mutate per-test.
TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
SLUG="dpz$$"
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
(
    cd "$REPO"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
)

run_hook() {
    (
        cd "$REPO"
        bash "$HOOK" </dev/null 2>&1
    )
}

run_hook_refs() {
    local refs="$1"
    (
        cd "$REPO"
        bash "$HOOK" origin https://example.com/repo.git <<< "$refs" 2>&1
    )
}

marker_path() {
    local branch="$1"
    local git_dir
    # git rev-parse --git-common-dir returns a path relative to the repo
    # toplevel on non-bare repos. Resolve to absolute so the test can
    # `[ -f $path ]` from any cwd.
    git_dir=$(git -C "$REPO" rev-parse --git-common-dir)
    case "$git_dir" in
        /*|?:/*|?:\\*) ;;
        *)             git_dir="$REPO/$git_dir" ;;
    esac
    echo "${git_dir}/cr-pending/${branch}"
}

# Test 1: state-only handover/* branch -> no marker ------------------

echo "TEST: handover/HIMMEL-142 with state-only diff (markdown) -> no marker"
git -C "$REPO" checkout -q -b handover/HIMMEL-142-state-only
mkdir -p "$REPO/handovers/$SLUG"
echo "state" > "$REPO/handovers/$SLUG/state.md"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add handovers/$SLUG/state.md
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "handover: state"

out=$(run_hook)
m=$(marker_path handover/HIMMEL-142-state-only)
if [ -f "$m" ]; then
    fail "no marker written for state-only diff" "marker exists at $m"
else
    pass "no marker written for state-only diff"
fi
case "$out" in
    *"handover-state-only change — skipping marker write"*)
        pass "stdout/stderr explains handover-state-only skip"
        ;;
    *)
        fail "expected handover-state-only-skip message" "actual: $out"
        ;;
esac

# Test 2: mixed code+state diff -> marker written --------------------

echo "TEST: handover/* with mixed code+state diff -> marker written"
echo "function f() {}" > "$REPO/code.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add code.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "code creep"

out=$(run_hook)
if [ -f "$m" ]; then
    pass "marker written when code creeps into handover branch"
    lane_full=$(awk -F' [|] ' '{print $3; exit}' "$m" 2>/dev/null || true)
    if [ "$lane_full" = "full" ]; then
        pass "code+state diff wrote a full-lane marker"
    else
        fail "code marker lane '$lane_full' != full" "out: $out"
    fi
else
    fail "expected marker for code-mixed diff" "out: $out"
fi

# Test 3: SKIP_CR=1 short-circuits -----------------------------------

echo "TEST: SKIP_CR=1 short-circuits"
rm -f "$m"
out=$(
    cd "$REPO"
    SKIP_CR=1 bash "$HOOK" 2>&1
)
if [ -f "$m" ]; then
    fail "SKIP_CR=1 should not write marker" "marker at $m"
else
    pass "SKIP_CR=1 skipped marker write"
fi
case "$out" in
    *"SKIP_CR=1"*) pass "stderr explains SKIP_CR" ;;
    *) fail "expected SKIP_CR message" "actual: $out" ;;
esac

# Test 4: main branch -> exit 0, no marker ---------------------------

echo "TEST: main branch -> exit 0, no marker"
git -C "$REPO" checkout -q main
m_main=$(marker_path main)
rm -f "$m_main"
rc=0
out=$(run_hook) || rc=$?
if [ "$rc" -ne 0 ]; then
    fail "main branch exit non-zero" "rc=$rc out=$out"
else
    pass "main branch exit 0"
fi
if [ -f "$m_main" ]; then
    fail "main branch should not write marker" "marker at $m_main"
else
    pass "main branch wrote no marker"
fi

# HIMMEL-1540: marker identity follows pushed refs, not worktree HEAD --------

echo "TEST: refspec push from main writes marker for pushed branch + local_sha"
git -C "$REPO" checkout -q -b feat/refspec-1540
printf 'function pushed() {}\n' > "$REPO/pushed.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add pushed.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "refspec code"
refspec_sha=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
refspec_line="refs/heads/feat/refspec-1540 $refspec_sha refs/heads/feat/refspec-1540 0000000000000000000000000000000000000000"
out=$(run_hook_refs "$refspec_line")
m_refspec=$(marker_path feat/refspec-1540)
if [ -f "$m_refspec" ]; then
    pass "refspec push from main wrote marker for the pushed branch"
    marker_sha=$(awk -F' [|] ' '{print $2; exit}' "$m_refspec" 2>/dev/null || true)
    marker_lane=$(awk -F' [|] ' '{print $3; exit}' "$m_refspec" 2>/dev/null || true)
    marker_remote=$(awk -F' [|] ' '{print $4; exit}' "$m_refspec" 2>/dev/null || true)
    marker_remote_ref=$(awk -F' [|] ' '{print $5; exit}' "$m_refspec" 2>/dev/null || true)
    if [ "$marker_sha" = "$refspec_sha" ]; then
        pass "refspec marker certifies pushed local_sha, not worktree HEAD"
    else
        fail "refspec marker SHA '$marker_sha' != pushed SHA '$refspec_sha'" "out: $out"
    fi
    if [ "$marker_lane" = "full" ] && [ "$marker_remote" = "origin" ] &&
       [ "$marker_remote_ref" = "refs/heads/feat/refspec-1540" ]; then
        pass "refspec marker classifies code full and binds origin destination ref"
    else
        fail "refspec marker lane/remote binding is wrong ('$marker_lane' '$marker_remote' '$marker_remote_ref')" "out: $out"
    fi
else
    fail "refspec push from main should write pushed-branch marker" "out: $out"
fi

zero_sha=0000000000000000000000000000000000000000

echo "TEST: renamed refspec with absent local destination fails closed"
missing_branch=feat/refspec-absent
m_missing=$(marker_path "$missing_branch")
rm -f "$m_missing"
rc=0
out=$(run_hook_refs "refs/heads/feat/refspec-1540 $refspec_sha refs/heads/$missing_branch $zero_sha") || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "absent local destination -> exit 2 (marker identity cannot be cleared safely)"
else
    fail "absent local destination -> expected exit 2 got $rc" "out: $out"
fi
if [ -f "$m_missing" ]; then
    fail "absent local destination must not write an uncleared marker" "marker at $m_missing"
else
    pass "absent local destination wrote no marker"
fi

echo "TEST: renamed refspec with divergent local destination fails closed"
divergent_branch=feat/refspec-divergent
git -C "$REPO" branch "$divergent_branch" main
divergent_sha=$(git -C "$REPO" rev-parse "refs/heads/$divergent_branch")
m_divergent=$(marker_path "$divergent_branch")
rm -f "$m_divergent"
rc=0
out=$(run_hook_refs "refs/heads/feat/refspec-1540 $refspec_sha refs/heads/$divergent_branch $divergent_sha") || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "divergent local destination -> exit 2 (unreviewed pushed SHA not certified)"
else
    fail "divergent local destination -> expected exit 2 got $rc" "out: $out"
fi
if [ -f "$m_divergent" ]; then
    fail "divergent local destination must not write a destination-keyed marker" "marker at $m_divergent"
else
    pass "divergent local destination wrote no marker, so the unsafe chain cannot clear one"
fi

echo "TEST: delete push writes no marker"
rm -f "$m_refspec"
out=$(run_hook_refs "(delete) $zero_sha refs/heads/feat/refspec-1540 $refspec_sha")
if [ -f "$m_refspec" ]; then
    fail "delete push should not write marker" "out: $out"
else
    pass "delete push wrote no marker"
fi

echo "TEST: pushed default branch writes no marker"
main_sha=$(git -C "$REPO" rev-parse main)
rm -f "$m_main"
out=$(run_hook_refs "refs/heads/main $main_sha refs/heads/main $zero_sha")
if [ -f "$m_main" ]; then
    fail "pushed default branch should not write marker" "out: $out"
else
    pass "pushed default branch wrote no marker"
fi

echo "TEST: multiple pushed refs write one marker per destination branch"
git -C "$REPO" checkout -q -b feat/ref-one main
printf 'one\n' > "$REPO/one.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add one.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "ref one"
ref_one_sha=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b feat/ref-two main
mkdir -p "$REPO/docs"
printf '# two\n' > "$REPO/docs/two.md"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add docs/two.md
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "ref two"
ref_two_sha=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
git -C "$REPO" branch feat/destination-one "$ref_one_sha"
git -C "$REPO" branch feat/destination-two "$ref_two_sha"
multi_refs="refs/heads/feat/ref-one $ref_one_sha refs/heads/feat/destination-one $zero_sha
refs/heads/feat/ref-two $ref_two_sha refs/heads/feat/destination-two $zero_sha"
out=$(run_hook_refs "$multi_refs")
m_one=$(marker_path feat/destination-one)
m_two=$(marker_path feat/destination-two)
if [ -f "$m_one" ] && [ -f "$m_two" ]; then
    pass "multiple pushed refs wrote one marker each"
else
    fail "multiple pushed refs should write both destination markers" "out: $out"
fi
if [ "$(awk -F' [|] ' '{print $2; exit}' "$m_one" 2>/dev/null || true)" = "$ref_one_sha" ] &&
   [ "$(awk -F' [|] ' '{print $2; exit}' "$m_two" 2>/dev/null || true)" = "$ref_two_sha" ]; then
    pass "multiple markers preserve each pushed local_sha"
else
    fail "multiple markers did not preserve their pushed SHAs" "out: $out"
fi

echo "TEST: non-head remote ref is ignored"
m_tag=$(marker_path refs/tags/release-1540)
rm -f "$m_tag"
out=$(run_hook_refs "refs/tags/release-1540 $refspec_sha refs/tags/release-1540 $zero_sha")
if [ -f "$m_tag" ]; then
    fail "tag push should not write a CR marker" "out: $out"
else
    pass "tag push was ignored"
fi

echo "TEST: empty stdin preserves worktree-HEAD fallback"
git -C "$REPO" checkout -q -b feat/empty-stdin main
printf 'fallback\n' > "$REPO/fallback.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add fallback.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "fallback code"
fallback_sha=$(git -C "$REPO" rev-parse HEAD)
m_fallback=$(marker_path feat/empty-stdin)
out=$(run_hook)
if [ -f "$m_fallback" ] && [ "$(awk -F' [|] ' '{print $2; exit}' "$m_fallback" 2>/dev/null || true)" = "$fallback_sha" ]; then
    pass "empty stdin used legacy worktree-HEAD marker path"
else
    fail "empty stdin should preserve worktree-HEAD marker path" "out: $out"
fi
git -C "$REPO" checkout -q main

# Test 5: feature branch with reviewable-docs-only diff -> docs-audit marker (HIMMEL-303)

echo "TEST: feat branch with docs-only diff -> docs-audit marker"
git -C "$REPO" checkout -q -b feat/docs-303
mkdir -p "$REPO/docs"
echo "# guide" > "$REPO/docs/guide.md"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add docs/guide.md
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "docs: add guide"

out=$(run_hook)
m_docs=$(marker_path feat/docs-303)
if [ -f "$m_docs" ]; then
    lane_docs=$(awk -F' [|] ' '{print $3; exit}' "$m_docs" 2>/dev/null || true)
    if [ "$lane_docs" = "docs-audit" ]; then
        pass "docs-only feature diff wrote a docs-audit marker (never zero CR)"
    else
        fail "docs marker lane '$lane_docs' != docs-audit" "out: $out"
    fi
else
    fail "expected docs-audit marker for docs-only feature diff" "out: $out"
fi
case "$out" in
    *"docs-audit marker written"*) pass "stderr explains docs-audit lane" ;;
    *) fail "expected docs-audit-marker message" "actual: $out" ;;
esac
git -C "$REPO" checkout -q main

# Test 6: mixed reviewable-docs + handover-state diff (no code) -> docs-audit (HIMMEL-303)
# Exercises the two-stage filter: a real doc alongside exempt handover state must
# still force the docs-audit lane (the `grep -Ev '^handovers/'` second stage).

echo "TEST: docs + handover-state diff (no code) -> docs-audit marker"
git -C "$REPO" checkout -q -b feat/mixed-docs-handover
mkdir -p "$REPO/docs" "$REPO/handovers/$SLUG"
echo "# m" > "$REPO/docs/mixed.md"
echo "state2" > "$REPO/handovers/$SLUG/state2.md"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add docs/mixed.md handovers/$SLUG/state2.md
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "docs+handover"

out=$(run_hook)
m_mix=$(marker_path feat/mixed-docs-handover)
if [ -f "$m_mix" ]; then
    lane_mix=$(awk -F' [|] ' '{print $3; exit}' "$m_mix" 2>/dev/null || true)
    if [ "$lane_mix" = "docs-audit" ]; then
        pass "mixed docs+handover (no code) -> docs-audit marker (reviewable doc forces audit)"
    else
        fail "mixed-diff marker lane '$lane_mix' != docs-audit" "out: $out"
    fi
else
    fail "expected docs-audit marker for mixed docs+handover diff" "out: $out"
fi
git -C "$REPO" checkout -q main

# ── HIMMEL-297: master-default repo ─────────────────────────────────────────
# A repo whose default branch is `master` (no `main` ref at all). Pre-fix the
# hook diffed against a non-existent `main` and skipped with a WARNING (false
# no-marker). Post-fix default_branch resolves master, so: master branch skips,
# and a feature branch with code writes a full-lane marker against master.

echo "TEST: master-default repo — master branch -> exit 0, no marker"
MREPO="$TMP_ROOT/mrepo"
git init -q --initial-branch=master "$MREPO" 2>/dev/null || {
    git init -q "$MREPO"
    git -C "$MREPO" symbolic-ref HEAD refs/heads/master || true
}
git -C "$MREPO" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
git -C "$MREPO" branch -m master 2>/dev/null || true

run_hook_m() { ( cd "$MREPO" && bash "$HOOK" 2>&1 ); }
mmarker_path() {
    local branch="$1" git_dir
    git_dir=$(git -C "$MREPO" rev-parse --git-common-dir)
    case "$git_dir" in /*|?:/*|?:\\*) ;; *) git_dir="$MREPO/$git_dir" ;; esac
    echo "${git_dir}/cr-pending/${branch}"
}

rc=0
out=$(run_hook_m) || rc=$?
mm=$(mmarker_path master)
if [ "$rc" -eq 0 ] && [ ! -f "$mm" ]; then
    pass "master branch -> exit 0, no marker"
else
    fail "master branch -> expected exit 0 + no marker" "rc=$rc marker=$mm out=$out"
fi

echo "TEST: master-default repo — feat branch with code diff -> full marker (diff_base=master)"
git -C "$MREPO" checkout -q -b feat/on-master
echo "function f() {}" > "$MREPO/code.sh"
git -C "$MREPO" -c user.email=t@test.com -c user.name=test add code.sh
git -C "$MREPO" -c user.email=t@test.com -c user.name=test commit -q -m "code"
out=$(run_hook_m)
mfeat=$(mmarker_path feat/on-master)
if [ -f "$mfeat" ]; then
    lane_m=$(awk -F' [|] ' '{print $3; exit}' "$mfeat" 2>/dev/null || true)
    if [ "$lane_m" = "full" ]; then
        pass "master-default feat+code -> full marker (resolved master as diff base)"
    else
        fail "master-default marker lane '$lane_m' != full" "out: $out"
    fi
else
    fail "expected marker for code diff in master-default repo (proves master base resolved, not skipped)" "out: $out"
fi

# ── HIMMEL-295: ancestor-preference for diff_base ───────────────────────────
#
# Set up a second repo that acts as origin, advance it ahead of local main,
# then verify that the hook diffs against origin/main (the more current ref)
# rather than local main (the stale one). This ensures a docs-only branch
# branched off the current origin tip produces no false-positive marker.

echo "TEST: origin/main ahead of local main -> uses origin/main as diff_base"
REPO2="$TMP_ROOT/repo2"
ORIGIN="$TMP_ROOT/origin.git"

# Create a bare origin from the existing repo.
git clone -q --bare "$REPO" "$ORIGIN"

# Clone fresh working repo from origin so remote tracking is wired up.
git clone -q "$ORIGIN" "$REPO2"
(
    cd "$REPO2"
    git -c user.email=t@test.com -c user.name=t branch -m main 2>/dev/null || true
)

# Advance origin/main by one commit (simulates merged PRs landing after clone).
WORK="$TMP_ROOT/work"
git clone -q "$ORIGIN" "$WORK"
echo "advance" > "$WORK/advance.sh"
git -C "$WORK" -c user.email=t@test.com -c user.name=t add advance.sh
git -C "$WORK" -c user.email=t@test.com -c user.name=t commit -q -m "advance main"
git -C "$WORK" push -q origin HEAD:main

# Fetch into REPO2 so origin/main is ahead of local main (no merge/rebase).
git -C "$REPO2" fetch -q origin

# Now local main is an ancestor of origin/main — the fix must pick origin/main.
# Create a feature branch off origin/main with only docs changes.
git -C "$REPO2" checkout -q -b feat/ancestor-test origin/main
mkdir -p "$REPO2/docs"
echo "# doc" > "$REPO2/docs/note.md"
git -C "$REPO2" -c user.email=t@test.com -c user.name=t add docs/note.md
git -C "$REPO2" -c user.email=t@test.com -c user.name=t commit -q -m "docs only"

# Run hook in REPO2.
hook_out2=$(cd "$REPO2" && bash "$HOOK" 2>&1) || true
m2_dir=$(cd "$REPO2" && git rev-parse --git-common-dir)
case "$m2_dir" in /*|?:/*|?:\\*) ;; *) m2_dir="$REPO2/$m2_dir" ;; esac
m2="${m2_dir}/cr-pending/feat/ancestor-test"
# HIMMEL-303: docs/ now writes a docs-audit marker (no longer skipped). The
# ancestor-pref signal is now the marker LANE: diffing origin/main (correct)
# sees only docs/note.md -> lane "docs-audit"; diffing stale local main (wrong)
# would leak advance.sh (non-docs) -> lane "full". So lane == docs-audit proves
# the right base was chosen.
if [ -f "$m2" ]; then
    lane2=$(awk -F' [|] ' '{print $3; exit}' "$m2" 2>/dev/null || true)
    if [ "$lane2" = "docs-audit" ]; then
        pass "ancestor-pref: docs branch off origin/main -> docs-audit marker (diffed origin/main, not stale local main)"
    else
        fail "ancestor-pref: marker lane '$lane2' != docs-audit — likely diffed stale local main (advance.sh leaked)" "out: $hook_out2"
    fi
else
    fail "ancestor-pref: no marker for docs change (HIMMEL-303 expects a docs-audit marker)" "out: $hook_out2"
fi

echo "TEST: origin/main NOT ancestor of local main -> uses local main as diff_base"
# Simulate a diverged/force-pushed local main (not an ancestor).
REPO3="$TMP_ROOT/repo3"
git clone -q "$ORIGIN" "$REPO3"
# Add a commit to local main that is NOT in origin/main.
echo "local-only" > "$REPO3/localonly.sh"
git -C "$REPO3" -c user.email=t@test.com -c user.name=t add localonly.sh
git -C "$REPO3" -c user.email=t@test.com -c user.name=t commit -q -m "local diverge"
# advance.sh is only in origin — reset local main back so it's diverged.
git -C "$REPO3" fetch -q origin
# Now local main has localonly.sh (not in origin) and origin/main has advance.sh (not in local).
# Neither is ancestor of the other — hook should fall through to diff_base=main (local).
git -C "$REPO3" checkout -q -b feat/diverged-test
echo "code" > "$REPO3/code2.sh"
git -C "$REPO3" -c user.email=t@test.com -c user.name=t add code2.sh
git -C "$REPO3" -c user.email=t@test.com -c user.name=t commit -q -m "code on diverged"

hook_out3=$(cd "$REPO3" && bash "$HOOK" 2>&1) || true
# Should write a marker (code diff) — verifies hook still runs when non-ancestor path taken.
m3_dir=$(cd "$REPO3" && git rev-parse --git-common-dir)
case "$m3_dir" in /*|?:/*|?:\\*) ;; *) m3_dir="$REPO3/$m3_dir" ;; esac
m3="${m3_dir}/cr-pending/feat/diverged-test"
if [ -f "$m3" ]; then
    pass "diverged: marker written (hook ran against local main)"
else
    fail "diverged: expected marker for code diff" "out: $hook_out3"
fi

# ── HIMMEL-323 item 1: fail-CLOSED when no diff base resolves ───────────────
# A repo with no main/master ref and no remote: default_branch falls back to
# "main", which doesn't exist. This hook does no fetch, so an unresolvable base
# is a genuinely-broken state -> fail CLOSED (exit 2), not a silent skip that
# would let an unreviewed change reach `gh pr create` ungated. Bypass: SKIP_CR=1.
echo "TEST: unresolvable diff base -> fail CLOSED (exit 2)"
NB="$TMP_ROOT/nobase"
git init -q -b feat/x "$NB"
(
    cd "$NB"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    echo 'function f(){}' > code.sh
    git -c user.email=t@t -c user.name=t add code.sh
    git -c user.email=t@t -c user.name=t commit -q -m "code"
)
rc=0; out=$(cd "$NB" && bash "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "unresolvable base -> exit 2 (fail closed)"; else fail "unresolvable base -> expected exit 2 got $rc" "out: $out"; fi
rc=0; out=$(cd "$NB" && SKIP_CR=1 bash "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then pass "unresolvable base + SKIP_CR=1 -> exit 0 (bypass)"; else fail "SKIP_CR bypass -> expected exit 0 got $rc" "out: $out"; fi

# ── HIMMEL-323 item 2: branch resolved via lib.sh::_branch ──────────────────
echo "TEST: non-git dir -> rc=2 fail-closed (cannot read branch)"
NG="$TMP_ROOT/nongit"; mkdir -p "$NG"
rc=0; out=$(cd "$NG" && bash "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "non-git dir -> exit 2"; else fail "non-git dir -> expected exit 2 got $rc" "out: $out"; fi

# Regression-PIN, not a fix-prover: `git branch --show-current` is already
# worktree-correct in the natural env (GIT_DIR at the worktree's own gitdir), so
# this passes on old code too. The genuine new-behaviour prover for the _branch
# switch is the non-git-dir rc=2 case above (old code aborted via set -e, rc=128).
echo "TEST: linked worktree (primary on main) -> reads worktree branch, writes marker"
WB="$TMP_ROOT/wtbase"
git init -q -b main "$WB"
( cd "$WB"; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
git -C "$WB" worktree add -q -b feat/wt "$TMP_ROOT/wtbase-wt" >/dev/null 2>&1
(
    cd "$TMP_ROOT/wtbase-wt"
    echo 'function f(){}' > code.sh
    git -c user.email=t@t -c user.name=t add code.sh
    git -c user.email=t@t -c user.name=t commit -q -m "code on worktree"
)
wtgd="$WB/.git/worktrees/$(basename "$TMP_ROOT/wtbase-wt")"
rc=0; out=$(cd "$TMP_ROOT/wtbase-wt" && env GIT_DIR="$wtgd" bash "$HOOK" 2>&1) || rc=$?
wm="$WB/.git/cr-pending/feat/wt"
if [ "$rc" -eq 0 ] && [ -f "$wm" ]; then
    pass "linked worktree: read worktree branch (feat/wt) + wrote marker"
else
    fail "linked worktree: expected exit 0 + marker at $wm got rc=$rc" "out: $out"
fi
git -C "$WB" worktree remove --force "$TMP_ROOT/wtbase-wt" >/dev/null 2>&1 || true

# ── HIMMEL-323 item 1 (CR follow-up): fail-CLOSED when the diff itself errors ──
# An orphan/unrelated-history branch has no merge base, so `git diff base...HEAD`
# exits non-zero. Without the guard `set -e` would abort with git's opaque code;
# the hook now refuses the push with a clear rc=2 so an unreviewable change can't
# slip past the CR marker ungated. Bypass: SKIP_CR=1.
echo "TEST: orphan branch (no merge base) -> fail CLOSED (exit 2)"
OB="$TMP_ROOT/orphan"
git init -q -b main "$OB"
(
    cd "$OB"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git checkout -q --orphan feat/x
    git rm -rfq . 2>/dev/null || true
    echo 'function f(){}' > code.sh
    git -c user.email=t@t -c user.name=t add code.sh
    git -c user.email=t@t -c user.name=t commit -q -m "orphan code"
)
rc=0; out=$(cd "$OB" && bash "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "orphan branch -> exit 2 (fail closed)"; else fail "orphan branch -> expected exit 2 got $rc" "out: $out"; fi
rc=0; out=$(cd "$OB" && SKIP_CR=1 bash "$HOOK" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then pass "orphan branch + SKIP_CR=1 -> exit 0 (bypass)"; else fail "orphan SKIP_CR bypass -> expected exit 0 got $rc" "out: $out"; fi

# ── HIMMEL-1540 R5: identity completion — endpoint E + base B ───────────────
# Per HIMMEL-1554 every case asserts the specific refusal REASON or marker
# binding, never rc alone.

Z40="0000000000000000000000000000000000000000"

# Divergent remotes: the branch's content is ALREADY in origin/main (diff vs
# origin empty — the old base choice would skip the marker entirely), but NOT
# in the pushed remote's main. The pushed remote's base must be chosen, the
# marker written, and field 7 must pin that base's immutable SHA.
echo "TEST: push to non-origin remote diffs against THAT remote's base (divergent histories)"
PB="$TMP_ROOT/pubbase"
git init -q -b main "$PB"
(
    cd "$PB"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    echo 'function shared(){}' > shared.sh
    git -c user.email=t@t -c user.name=t add shared.sh
    git -c user.email=t@t -c user.name=t commit -q -m "shared code"
)
pb_tip=$(git -C "$PB" rev-parse --verify refs/heads/main)
pb_init=$(git -C "$PB" rev-parse --verify "refs/heads/main^")
git -C "$PB" update-ref refs/remotes/origin/main "$pb_tip"
git -C "$PB" update-ref refs/remotes/pubremote/main "$pb_init"
git -C "$PB" checkout -q -b feat/pub
rc=0; out=$(cd "$PB" && bash "$HOOK" pubremote "file:///pubdest.git" <<< "refs/heads/feat/pub $pb_tip refs/heads/feat/pub $Z40" 2>&1) || rc=$?
pm="$PB/.git/cr-pending/feat/pub"
if [ "$rc" -eq 0 ] && [ -f "$pm" ]; then
    pass "pubremote push: marker written (old origin-based diff was empty and would have skipped)"
    pm_endpoint=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit}' "$pm" 2>/dev/null || true)
    pm_base=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$7); print $7; exit}' "$pm" 2>/dev/null || true)
    if [ "$pm_base" = "$pb_init" ]; then
        pass "pubremote push: marker base B pins refs/remotes/pubremote/main's SHA, not origin's"
    else
        fail "pubremote push: marker base '$pm_base' != pubremote/main ($pb_init)" "out: $out"
    fi
    if [ "$pm_endpoint" = "file:///pubdest.git" ]; then
        pass "pubremote push: marker endpoint E carries the pushed URL"
    else
        fail "pubremote push: marker endpoint '$pm_endpoint' != file:///pubdest.git" "out: $out"
    fi
else
    fail "pubremote push: expected exit 0 + marker at $pm (got rc=$rc)" "out: $out"
fi

echo "TEST: push to a remote with NO local tracking ref -> fail CLOSED naming the missing ref"
rc=0; out=$(cd "$PB" && bash "$HOOK" nowhere "file:///nowhere.git" <<< "refs/heads/feat/pub $pb_tip refs/heads/feat/pub $Z40" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "unfetched pushed remote -> exit 2 (fail closed)"; else fail "unfetched pushed remote -> expected exit 2 got $rc" "out: $out"; fi
case "$out" in
    *"no tracking ref refs/remotes/nowhere/main for pushed remote 'nowhere'"*)
        pass "refusal names the missing tracking ref (reason-specific, HIMMEL-1554)" ;;
    *)
        fail "refusal must name refs/remotes/nowhere/main" "out: $out" ;;
esac

echo "TEST: http(s) credentials are scrubbed from the marker endpoint"
git -C "$REPO" checkout -q -b feat/scrub main
echo 'function s(){}' > "$REPO/scrub.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add scrub.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "code"
scrub_sha=$(git -C "$REPO" rev-parse --verify refs/heads/feat/scrub)
rc=0; out=$(cd "$REPO" && bash "$HOOK" origin "https://x-access-token:sekrit123@example.com/repo.git" <<< "refs/heads/feat/scrub $scrub_sha refs/heads/feat/scrub $Z40" 2>&1) || rc=$?
sm=$(marker_path feat/scrub)
sm_endpoint=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit}' "$sm" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && [ "$sm_endpoint" = "https://example.com/repo.git" ]; then
    pass "userinfo stripped: endpoint is https://example.com/repo.git"
else
    fail "expected scrubbed endpoint, got '$sm_endpoint' (rc=$rc)" "out: $out"
fi
if [ -f "$sm" ] && grep -q "sekrit123" "$sm"; then
    fail "marker leaks the credential into plaintext under .git"
else
    pass "marker carries no credential material"
fi

echo "TEST: ref push without an endpoint URL -> fail CLOSED naming the missing binding"
rc=0; out=$(cd "$REPO" && bash "$HOOK" origin <<< "refs/heads/feat/scrub $scrub_sha refs/heads/feat/scrub $Z40" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "missing endpoint URL -> exit 2 (fail closed)"; else fail "missing endpoint URL -> expected exit 2 got $rc" "out: $out"; fi
case "$out" in
    *"no push endpoint URL"*) pass "refusal names the missing endpoint binding (reason-specific)" ;;
    *) fail "refusal must say 'no push endpoint URL'" "out: $out" ;;
esac

# Summary ------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
