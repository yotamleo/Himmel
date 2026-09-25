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
#   + HIMMEL-2104: empty-stdin up-to-date push mints a bound marker from the
#     upstream tracking ref; empty-stdin fallback never downgrades an
#     existing BOUND marker to unbound when no fresh binding can be derived.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-cr-before-push.sh"
# Most cases below deliberately push a feature refspec while the fixture repo
# sits on main — they pin MARKER semantics, not the HIMMEL-1809 foreign-ref
# policy, which would otherwise refuse that shape before any marker work. The
# policy itself has its own section at the bottom, which unsets this.
export PUSH_FOREIGN_REF_OK=1
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

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
TMP_ROOT=$(fixture_mktemp_dir) || exit 1
if command -v cygpath >/dev/null 2>&1; then
    TMP_ROOT=$(cygpath -m "$TMP_ROOT")
fi
SLUG="dpz$$"
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO" || exit 1
(
    fixture_enter_git_init_dir "$REPO" || exit 1
    git init -q --initial-branch=main 2>/dev/null || {
        git init -q
        git symbolic-ref HEAD refs/heads/main || true
    }
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
) || exit 1

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

# HIMMEL-2104: up-to-date push (empty stdin) mints a bound marker ------------

echo "TEST: empty-stdin up-to-date push mints marker binding from upstream (HIMMEL-2104)"
BARE_ORIGIN="$TMP_ROOT/bare-origin.git"
git init -q --bare "$BARE_ORIGIN"
git -C "$REPO" remote add origin "$BARE_ORIGIN" 2>/dev/null || git -C "$REPO" remote set-url origin "$BARE_ORIGIN"
git -C "$REPO" checkout -q -b feat/uptodate-2104 main
printf 'function uptodate() {}\n' > "$REPO/uptodate.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add uptodate.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "uptodate code"
uptodate_sha=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q -u origin feat/uptodate-2104
m_uptodate=$(marker_path feat/uptodate-2104)
rm -f "$m_uptodate"
out=$(run_hook)
if [ -f "$m_uptodate" ]; then
    marker_sha=$(awk -F' [|] ' '{print $2; exit}' "$m_uptodate" 2>/dev/null || true)
    marker_remote=$(awk -F' [|] ' '{print $4; exit}' "$m_uptodate" 2>/dev/null || true)
    marker_remote_ref=$(awk -F' [|] ' '{print $5; exit}' "$m_uptodate" 2>/dev/null || true)
    marker_endpoint=$(awk -F' [|] ' '{print $6; exit}' "$m_uptodate" 2>/dev/null || true)
    if [ "$marker_sha" = "$uptodate_sha" ] && [ "$marker_remote" = "origin" ] &&
       [ "$marker_remote_ref" = "refs/heads/feat/uptodate-2104" ] && [ -n "$marker_endpoint" ]; then
        pass "up-to-date empty-stdin push minted a bound marker from the upstream tracking ref"
    else
        fail "up-to-date marker binding wrong (sha=$marker_sha remote=$marker_remote ref=$marker_remote_ref endpoint=$marker_endpoint)" "out: $out"
    fi
else
    fail "up-to-date empty-stdin push should have written a bound marker" "out: $out"
fi
case "$out" in
    *"reminted the marker binding"*) pass "hook explains the up-to-date remint" ;;
    *) fail "expected up-to-date remint message" "actual: $out" ;;
esac
git -C "$REPO" checkout -q main

# HIMMEL-2104: empty-stdin fallback must not downgrade a BOUND marker -------

echo "TEST: empty-stdin fallback preserves an existing BOUND marker it cannot rebind"
git -C "$REPO" checkout -q -b feat/bound-protect-2104 main
printf 'protect\n' > "$REPO/protect.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add protect.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "protect code"
protect_sha=$(git -C "$REPO" rev-parse HEAD)
m_protect=$(marker_path feat/bound-protect-2104)
mkdir -p "$(dirname "$m_protect")"
printf '2026-08-01T00:00:00+00:00 | %s | full | origin | refs/heads/feat/bound-protect-2104 | https://example.com/repo.git | %s\n' \
    "$protect_sha" "$protect_sha" > "$m_protect"
prior_marker_content=$(cat "$m_protect")
out=$(run_hook)
new_marker_content=$(cat "$m_protect" 2>/dev/null || true)
if [ "$new_marker_content" = "$prior_marker_content" ]; then
    pass "empty-stdin fallback left the existing bound marker untouched"
else
    fail "bound marker should not be overwritten by empty-stdin fallback" \
        "before: $prior_marker_content / after: $new_marker_content / out: $out"
fi
case "$out" in
    *"keeping the existing BOUND CR marker"*) pass "hook explains it kept the bound marker" ;;
    *) fail "expected bound-marker-preserved message" "actual: $out" ;;
esac
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

echo "TEST: explicit-URL push (no named remote) resolves the FORK's OWN base (HIMMEL-3477)"
FX="$TMP_ROOT/forkbase"
git init -q -b main "$FX"
touch "$FX/.single-writer"
(
    cd "$FX"
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "shared init"
    echo 'function forkonly(){}' > fork.sh
    git -c user.email=t@t -c user.name=t add fork.sh
    git -c user.email=t@t -c user.name=t commit -q -m "fork-only commit"
)
fx_fork_tip=$(git -C "$FX" rev-parse --verify main)
fx_origin_tip=$(git -C "$FX" rev-parse --verify main^)
git -C "$FX" update-ref refs/remotes/origin/main "$fx_origin_tip"
FORK_BARE="$TMP_ROOT/fork-explicit.git"
git clone -q --bare "$FX" "$FORK_BARE"
FORK_URL="file://$FORK_BARE"
git -C "$FX" checkout -q -b feat/urlpush main
echo 'leg change' > "$FX/urlfeature.txt"
git -C "$FX" add urlfeature.txt
git -C "$FX" -c user.email=t@t -c user.name=t commit -q -m "leg feature on top of fork base"
fx_feat_sha=$(git -C "$FX" rev-parse --verify feat/urlpush)

rc=0; out=$(cd "$FX" && bash "$HOOK" "$FORK_URL" "$FORK_URL" <<< "refs/heads/feat/urlpush $fx_feat_sha refs/heads/feat/urlpush $Z40" 2>&1) || rc=$?
fxm="$FX/.git/cr-pending/feat/urlpush"
if [ "$rc" -eq 0 ] && [ -f "$fxm" ]; then
    pass "explicit-URL fork push: marker written (no named remote, no refs/remotes/<url>/main required)"
    fxm_base=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$7); print $7; exit}' "$fxm" 2>/dev/null || true)
    if [ "$fxm_base" = "$fx_fork_tip" ]; then
        pass "explicit-URL fork push: marker base pins the FORK's own HEAD, not origin's"
    else
        fail "explicit-URL fork push: marker base '$fxm_base' != fork tip ($fx_fork_tip)" "out: $out"
    fi
else
    fail "explicit-URL fork push: expected exit 0 + marker at $fxm (got rc=$rc)" "out: $out"
fi

echo "TEST: explicit-URL push to an UNREACHABLE fork -> fail CLOSED naming a satisfiable remedy"
rc=0; out=$(cd "$FX" && bash "$HOOK" "file://$TMP_ROOT/no-such-fork.git" "file://$TMP_ROOT/no-such-fork.git" <<< "refs/heads/feat/urlpush $fx_feat_sha refs/heads/feat/urlpush $Z40" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "unreachable explicit-URL fork -> exit 2 (fail closed)"; else fail "unreachable explicit-URL fork -> expected exit 2 got $rc" "out: $out"; fi
case "$out" in
    *"git fetch file://"*", then retry"*)
        fail "refusal still prints the broken remedy (git fetch <url> can never create refs/remotes/<url>/*)" "out: $out" ;;
    *"could not fetch the default branch from"*)
        pass "refusal names a satisfiable remedy (retry / SKIP_CR / --no-verify), not the broken one" ;;
    *)
        fail "unexpected refusal message" "out: $out" ;;
esac

echo "TEST: explicit-URL push after the fork REWINDS its default branch -> scratch ref still refreshes (HIMMEL-3477 codex-1 round 3)"
# The scratch ref refs/cr/<hash>/fork-head is reused across pushes to the SAME
# fork URL. Rewind the fork's bare "main" backwards (non-fast-forward from the
# ref's currently-fetched value) and push again: an unforced fetch refspec
# would reject this and fail the push closed even though the fork is perfectly
# reachable.
git -C "$FORK_BARE" update-ref refs/heads/main "$fx_origin_tip"
rc=0; out=$(cd "$FX" && bash "$HOOK" "$FORK_URL" "$FORK_URL" <<< "refs/heads/feat/urlpush $fx_feat_sha refs/heads/feat/urlpush $Z40" 2>&1) || rc=$?
fxm_rewind_base=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$7); print $7; exit}' "$fxm" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && [ "$fxm_rewind_base" = "$fx_origin_tip" ]; then
    pass "rewound fork -> scratch ref force-refreshes to the fork's NEW tip, push still succeeds"
else
    fail "rewound fork -> expected exit 0 + base=$fx_origin_tip, got rc=$rc base='$fxm_rewind_base'" "out: $out"
fi

echo "TEST: explicit-URL push does not clobber the caller's own FETCH_HEAD (HIMMEL-3477 CR round 4, CodeRabbit)"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t\tsentinel from a real manual fetch moments earlier\n' > "$FX/.git/FETCH_HEAD"
fetch_head_before=$(cat "$FX/.git/FETCH_HEAD")
rc=0; out=$(cd "$FX" && bash "$HOOK" "$FORK_URL" "$FORK_URL" <<< "refs/heads/feat/urlpush $fx_feat_sha refs/heads/feat/urlpush $Z40" 2>&1) || rc=$?
fetch_head_after=$(cat "$FX/.git/FETCH_HEAD" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && [ "$fetch_head_after" = "$fetch_head_before" ]; then
    pass "explicit-URL push preserves the caller's own FETCH_HEAD"
else
    fail "explicit-URL push clobbered FETCH_HEAD (before='$fetch_head_before' after='$fetch_head_after' rc=$rc)" "out: $out"
fi

echo "TEST: explicit-URL push to an unreachable fork with embedded credentials -> refusal does not leak them"
# Loopback + a closed port (not example.com): a real DNS-resolving host makes
# this suite depend on network availability and can hang (codex-1 CR finding).
# 127.0.0.1 refuses the connection immediately with no external network use.
rc=0; out=$(cd "$FX" && bash "$HOOK" "https://x-access-token:sekrit456@127.0.0.1:1/no-such-fork.git" "https://x-access-token:sekrit456@127.0.0.1:1/no-such-fork.git" <<< "refs/heads/feat/urlpush $fx_feat_sha refs/heads/feat/urlpush $Z40" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "unreachable credentialed fork URL -> exit 2 (fail closed)"; else fail "unreachable credentialed fork URL -> expected exit 2 got $rc" "out: $out"; fi
case "$out" in
    *"sekrit456"*)
        fail "refusal message leaks the embedded credential" "out: $out" ;;
    *"could not fetch the default branch from"*)
        pass "refusal names the scrubbed endpoint, not the raw credentialed URL" ;;
    *)
        fail "unexpected refusal message" "out: $out" ;;
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
sm_remote=$(awk -F' [|] ' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4; exit}' "$sm" 2>/dev/null || true)
if [ "$sm_remote" = "origin" ]; then
    pass "named-remote push: marker field 4 stays the remote NAME (guards the ticket's byte-for-byte-unaffected requirement against the explicit-URL scrub branch scope-creeping onto named remotes)"
else
    fail "named-remote push: field 4 changed to '$sm_remote', expected 'origin' unchanged" "out: $out"
fi

echo "TEST: ref push without an endpoint URL -> fail CLOSED naming the missing binding"
rc=0; out=$(cd "$REPO" && bash "$HOOK" origin <<< "refs/heads/feat/scrub $scrub_sha refs/heads/feat/scrub $Z40" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then pass "missing endpoint URL -> exit 2 (fail closed)"; else fail "missing endpoint URL -> expected exit 2 got $rc" "out: $out"; fi
case "$out" in
    *"no push endpoint URL"*) pass "refusal names the missing endpoint binding (reason-specific)" ;;
    *) fail "refusal must say 'no push endpoint URL'" "out: $out" ;;
esac

# HIMMEL-1809: foreign-ref push refusal ------------------------------
# pre-push gates lint the PUSHER'S working tree, so pushing a branch that is not
# the checked-out one has the gates inspect content the push does not carry
# (misattributed findings; fail-OPEN when the touched files are clean on the
# checked-out branch). These cases run with the exemption UNSET.

# run_hook_gated REFS — like run_hook_refs, but with the suite-wide
# PUSH_FOREIGN_REF_OK exemption removed, so the policy itself is under test.
run_hook_gated() {
    local refs="$1"
    (
        cd "$REPO"
        unset PUSH_FOREIGN_REF_OK
        bash "$HOOK" origin https://example.com/repo.git <<< "$refs" 2>&1
    )
}

git -C "$REPO" checkout -q -b feat/foreign-1809 main
echo 'function fr(){}' > "$REPO/foreign.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add foreign.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "code"
foreign_sha=$(git -C "$REPO" rev-parse --verify refs/heads/feat/foreign-1809)
foreign_line="refs/heads/feat/foreign-1809 $foreign_sha refs/heads/feat/foreign-1809 $Z40"

echo "TEST: pushing a branch that is not the checked-out one -> refused (HIMMEL-1809)"
git -C "$REPO" checkout -q main
rc=0; out=$(run_hook_gated "$foreign_line") || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "foreign-ref push -> exit 2 (fail closed)"
else
    fail "foreign-ref push -> expected exit 2 got $rc" "out: $out"
fi
case "$out" in
    *"working tree of 'main'"*"you are pushing 'feat/foreign-1809'"*)
        pass "refusal names BOTH the linted branch and the pushed branch" ;;
    *)
        fail "refusal must name main and feat/foreign-1809" "out: $out" ;;
esac
if [ ! -f "$(marker_path feat/foreign-1809)" ]; then
    pass "refusal happens before any marker work"
else
    fail "a marker was written despite the foreign-ref refusal"
fi

echo "TEST: PUSH_FOREIGN_REF_OK=1 exempts the foreign-ref push"
rc=0; out=$(run_hook_refs "$foreign_line") || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$(marker_path feat/foreign-1809)" ]; then
    pass "PUSH_FOREIGN_REF_OK=1 -> push proceeds and the marker is written"
else
    fail "PUSH_FOREIGN_REF_OK=1 should exempt the refusal (rc=$rc)" "out: $out"
fi
rm -f "$(marker_path feat/foreign-1809)"

echo "TEST: pushing the checked-out branch passes the foreign-ref check"
git -C "$REPO" checkout -q feat/foreign-1809
rc=0; out=$(run_hook_gated "$foreign_line") || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$(marker_path feat/foreign-1809)" ]; then
    pass "same-branch push -> not refused (marker written as usual)"
else
    fail "same-branch push must pass the foreign-ref check (rc=$rc)" "out: $out"
fi

echo "TEST: a delete push names no working-tree content -> exempt"
rc=0; out=$(run_hook_gated "(delete) $Z40 refs/heads/feat/some-other-branch $foreign_sha") || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "delete push (local ref '(delete)') -> not refused"
else
    fail "delete push must be exempt from the foreign-ref refusal (rc=$rc)" "out: $out"
fi
rc=0; out=$(run_hook_gated "refs/heads/feat/some-other-branch $Z40 refs/heads/feat/some-other-branch $foreign_sha") || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "delete push (all-zero local SHA) -> not refused"
else
    fail "zero-SHA delete must be exempt from the foreign-ref refusal (rc=$rc)" "out: $out"
fi

echo "TEST: a raw commit pushed onto a branch is refused even from that branch's worktree"
older_sha=$(git -C "$REPO" rev-parse --verify "refs/heads/feat/foreign-1809^")
rc=0; out=$(run_hook_gated "$older_sha $older_sha refs/heads/feat/foreign-1809 $Z40") || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "sha:refs/heads/<b> push -> exit 2 (the linted tree is not the pushed commit)"
else
    fail "a non-HEAD commit pushed onto a branch must be refused (rc=$rc)" "out: $out"
fi

echo "TEST: a tag push carries no working-tree claim -> exempt"
rc=0; out=$(run_hook_gated "refs/tags/v1809 $foreign_sha refs/tags/v1809 $Z40") || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "tag destination -> not refused"
else
    fail "tag push must be exempt from the foreign-ref refusal (rc=$rc)" "out: $out"
fi

echo "TEST: detached HEAD -> refused (no branch's working tree matches the push)"
git -C "$REPO" checkout -q --detach
rc=0; out=$(run_hook_gated "$foreign_line") || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "detached HEAD -> exit 2 (fail closed)"
else
    fail "detached HEAD -> expected exit 2 got $rc" "out: $out"
fi
case "$out" in
    *"working tree of 'detached HEAD'"*)
        pass "detached-HEAD refusal says so instead of naming an empty branch" ;;
    *)
        fail "detached-HEAD refusal must name 'detached HEAD'" "out: $out" ;;
esac
git -C "$REPO" checkout -q main

# HIMMEL-1558: the CR marker lock ------------------------------------
# The marker has exactly two writers — this hook and clear-cr-marker.sh — and
# the second validates for minutes before unlinking. Both hold ONE
# branch-scoped lock while they touch the file; these cases pin what this side
# does when it cannot have it. Each asserts the specific REASON, not merely a
# non-zero rc (HIMMEL-1554): a fail-closed bug and a fail-closed feature share
# an exit code.
LOCK_LIB="$SCRIPT_DIR/../lib/shared-branch-lock.sh"

# lock_root — the CR-marker lock namespace under this repo's git COMMON dir
# (same relative-path handling as marker_path above). The lock DIRECTORY name
# is the lib's business, so it is discovered by glob rather than re-deriving
# the slug rule here.
lock_root() {
    local git_dir
    git_dir=$(git -C "$REPO" rev-parse --git-common-dir)
    case "$git_dir" in
        /*|?:/*|?:\\*) ;;
        *)             git_dir="$REPO/$git_dir" ;;
    esac
    echo "${git_dir}/himmel-cr-marker"
}

git -C "$REPO" checkout -q -b feat/lock-1558 main
echo 'function locked(){}' > "$REPO/locked.sh"
git -C "$REPO" -c user.email=t@test.com -c user.name=test add locked.sh
git -C "$REPO" -c user.email=t@test.com -c user.name=test commit -q -m "code"
lock_sha=$(git -C "$REPO" rev-parse --verify refs/heads/feat/lock-1558)
lock_line="refs/heads/feat/lock-1558 $lock_sha refs/heads/feat/lock-1558 $Z40"
m_lock=$(marker_path feat/lock-1558)

echo "TEST: a held marker lock refuses the push instead of overwriting the marker"
rm -f "$m_lock"
SHARED_BRANCH_LOCK_NS=himmel-cr-marker bash "$LOCK_LIB" \
    acquire "$REPO" feat/lock-1558 clear-cr-marker >/dev/null 2>&1
export CR_MARKER_LOCK_WAIT_SECONDS=1
rc=0; out=$(run_hook_refs "$lock_line") || rc=$?
unset CR_MARKER_LOCK_WAIT_SECONDS
if [ "$rc" -eq 2 ]; then
    pass "held marker lock -> exit 2 (fail closed)"
else
    fail "held marker lock -> expected exit 2 got $rc" "out: $out"
fi
case "$out" in
    *"holds the CR marker lock"*)
        pass "the refusal names the lock, not a generic marker-write failure" ;;
    *)
        fail "held-lock refusal must name the lock" "out: $out" ;;
esac
# The holder block the lock lib prints (owner.json) precedes the hook's own
# line, so the two are asserted independently rather than in one ordered glob.
case "$out" in
    *'"lane":"clear-cr-marker"'*)
        pass "the refusal names the holder (owner.json), not just a timeout" ;;
    *)
        fail "held-lock refusal must name the holder" "out: $out" ;;
esac
if [ -f "$m_lock" ]; then
    fail "a push that could not take the lock must not write the marker anyway" "marker at $m_lock"
else
    pass "no marker written while another writer holds the lock"
fi

echo "TEST: a stale marker lock is reclaimed, not waited out forever"
# The holder died without releasing (a killed /pr-check). Its recorded age is
# past the TTL, so the write reclaims the lock rather than wedging every push
# on this branch.
lockdir=""
for d in "$(lock_root)"/*.lock; do
    if [ -d "$d" ]; then lockdir="$d"; break; fi
done
if [ -n "$lockdir" ]; then
    printf '{"pid":1,"lane":"clear-cr-marker","branch":"feat/lock-1558","acquired_at":"2026-01-01T00:00:00Z","acquired_epoch":%s}\n' \
        "$(( $(date +%s) - 4000 ))" > "$lockdir/owner.json"
    pass "stale-lock fixture prepared"
else
    fail "stale-lock fixture: no lock dir under $(lock_root)"
fi
rc=0; out=$(run_hook_refs "$lock_line") || rc=$?
if [ "$rc" -eq 0 ]; then
    pass "stale marker lock -> reclaimed, push proceeds"
else
    fail "stale marker lock -> expected exit 0 got $rc" "out: $out"
fi
case "$out" in
    *"RECLAIMING a stale lock"*)
        pass "the reclaim leaves a loud trail" ;;
    *)
        fail "a reclaimed stale lock must be announced, not silent" "out: $out" ;;
esac
if [ -f "$m_lock" ]; then
    pass "the marker is written after the reclaim"
else
    fail "reclaimed lock: the marker should have been written" "out: $out"
fi
if [ -d "$lockdir" ]; then
    fail "the marker lock must be released after the write" "still at $lockdir"
else
    pass "the marker lock is released after the write"
fi

echo "TEST: an EMPTY holder record after acquire refuses the push before the marker is written"
# HIMMEL-1994. acquire creates owner.json by redirect and keeps rc 0 when the
# printf fails (a full disk), so the lock can be HELD with a zero-byte record —
# and that record is what every ownership check downstream compares against. An
# empty one is no evidence of exclusion at all, so the write must not happen.
# The state is unreachable from outside (the write lives INSIDE acquire), so
# this case runs the hook from a copied tree whose lock lib is the real one
# plus a truncate; the hook and the guardrail lib are byte-identical copies.
stub_tree="$TMP_ROOT/emptyowner"
stub_lock_root=$(lock_root)
mkdir -p "$stub_tree/scripts/hooks" "$stub_tree/scripts/guardrails" "$stub_tree/scripts/lib"
cp "$HOOK" "$stub_tree/scripts/hooks/check-cr-before-push.sh"
cp "$SCRIPT_DIR/../guardrails/lib.sh" "$stub_tree/scripts/guardrails/lib.sh"
cp "$LOCK_LIB" "$stub_tree/scripts/lib/shared-branch-lock-real.sh"
cat > "$stub_tree/scripts/lib/shared-branch-lock.sh" <<STUB
#!/usr/bin/env bash
rc=0
bash "$stub_tree/scripts/lib/shared-branch-lock-real.sh" "\$@" || rc=\$?
if [ "\$rc" -eq 0 ] && { [ "\$1" = "acquire" ] || [ "\$1" = "acquire-wait" ]; }; then
    for d in "$stub_lock_root"/*.lock; do
        [ -d "\$d" ] && : > "\$d/owner.json"
    done
fi
exit \$rc
STUB
rm -f "$m_lock"
rc=0
out=$(cd "$REPO" && bash "$stub_tree/scripts/hooks/check-cr-before-push.sh" \
    origin https://example.com/repo.git <<< "$lock_line" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
    pass "empty holder record -> exit 2 (fail closed)"
else
    fail "empty holder record -> expected exit 2 got $rc" "out: $out"
fi
case "$out" in
    *"holder record is EMPTY"*)
        pass "the refusal names the unreadable holder record, not a generic lock timeout" ;;
    *)
        fail "empty-record refusal must name the holder record" "out: $out" ;;
esac
if [ -f "$m_lock" ]; then
    fail "a push whose exclusion cannot be proven must not write the marker" "marker at $m_lock"
else
    pass "no marker written when the holder record is empty"
fi
# With no record, a release cannot tell this run's lock from a replacement
# holder's — so the lock is deliberately left in place for the TTL.
lockdir=""
for d in "$stub_lock_root"/*.lock; do
    if [ -d "$d" ]; then lockdir="$d"; break; fi
done
if [ -n "$lockdir" ]; then
    pass "the lock is LEFT ALONE rather than released without ownership evidence"
    rm -rf "$lockdir"
else
    fail "empty holder record: the lock must not be released on an unprovable ownership"
fi
git -C "$REPO" checkout -q main

# ── HIMMEL-3634 P1: the CR pre-push gate must judge against origin's REAL
#    default branch, never a base the pusher can make empty ────────────────
#
# resolve_diff_base's bases (an explicit-URL fork's fetched HEAD, or a local
# refs/remotes/<remote>/$db tracking ref) are both values the pusher
# controls. An empty diff(base...local_sha) only proves the content needs no
# review when the base itself is trustworthy. verify_empty_diff_is_reviewed
# closes this: before honoring an empty-diff skip it freshly fetches
# origin's real default branch and refuses unless local_sha is reachable
# from it.

echo "TEST: HIMMEL-3634 P1(a) — fork base already contains the tip -> refused, not skipped"
ORIGIN_P1="$TMP_ROOT/p1-origin.git"
git init -q --bare -b main "$ORIGIN_P1"
ATT="$TMP_ROOT/p1-attacker"
git init -q -b main "$ATT"
git -C "$ATT" -c user.email=a@t -c user.name=a commit -q --allow-empty -m "shared init"
git -C "$ATT" push -q "$ORIGIN_P1" main
git -C "$ATT" remote add origin "$ORIGIN_P1"
git -C "$ATT" fetch -q origin
# Checked out on feat/sneaky itself (not main) so the pushed branch name
# matches the linted working tree -- a mismatch trips the UNRELATED
# HIMMEL-1809 foreign-ref refusal before resolve_diff_base ever runs.
git -C "$ATT" checkout -q -b feat/sneaky main
echo 'function sneaky(){}' > "$ATT/sneaky.sh"
git -C "$ATT" add sneaky.sh
git -C "$ATT" -c user.email=a@t -c user.name=a commit -q -m "sneaky, never sent to origin"
sneaky_sha=$(git -C "$ATT" rev-parse HEAD)
# The pusher's own fork already has this exact commit as its default-branch
# HEAD (they pushed it there first) -- diffing against the FORK's base is
# empty even though origin has never seen it. Cloning while feat/sneaky is
# checked out makes the bare fork's HEAD symref point at feat/sneaky too, so
# `git fetch <fork> HEAD:scratch_ref` (resolve_diff_base) lands exactly on
# sneaky_sha.
P1_FORK="$TMP_ROOT/p1-fork.git"
git clone -q --bare "$ATT" "$P1_FORK"
P1_FORK_URL="file://$P1_FORK"
rc=0
out=$(cd "$ATT" && bash "$HOOK" "$P1_FORK_URL" "$P1_FORK_URL" <<< "refs/heads/feat/sneaky $sneaky_sha refs/heads/feat/sneaky $Z40" 2>&1) || rc=$?
sneaky_marker="$ATT/.git/cr-pending/feat/sneaky"
if [ "$rc" -eq 2 ] && [ ! -f "$sneaky_marker" ]; then
    pass "P1(a): fork-base-contains-tip is refused, not silently skipped"
else
    fail "P1(a): expected exit 2 + no marker" "rc=$rc marker=$([ -f "$sneaky_marker" ] && echo present || echo absent) / out: $out"
fi
case "$out" in
    *"NOT reachable from"*"main"*) pass "P1(a) refusal names the real reason (unreachable from origin)" ;;
    *) fail "P1(a) refusal should name origin-unreachability" "out: $out" ;;
esac

echo "TEST: HIMMEL-3634 P1(b) — locally rewritten refs/remotes/origin/main -> refused, not skipped"
B2="$TMP_ROOT/p1-b2"
git clone -q "$ORIGIN_P1" "$B2"
git -C "$B2" branch -m main 2>/dev/null || true
# Checked out on feat/sneaky2 itself so the pushed branch name matches the
# linted working tree (see the feat/sneaky note above).
git -C "$B2" checkout -q -b feat/sneaky2 main
echo 'function sneaky2(){}' > "$B2/sneaky2.sh"
git -C "$B2" add sneaky2.sh
git -C "$B2" -c user.email=b@t -c user.name=b commit -q -m "sneaky2, never sent to origin"
sneaky2_sha=$(git -C "$B2" rev-parse HEAD)
# Falsify the LOCAL cache of origin/main to make it look like origin already
# has this commit -- no network call needed to do this.
git -C "$B2" update-ref refs/remotes/origin/main "$sneaky2_sha"
rc=0
out=$(cd "$B2" && bash "$HOOK" origin "$ORIGIN_P1" <<< "refs/heads/feat/sneaky2 $sneaky2_sha refs/heads/feat/sneaky2 $Z40" 2>&1) || rc=$?
sneaky2_marker="$B2/.git/cr-pending/feat/sneaky2"
if [ "$rc" -eq 2 ] && [ ! -f "$sneaky2_marker" ]; then
    pass "P1(b): locally-rewritten origin/main tracking ref is refused, not silently skipped"
else
    fail "P1(b): expected exit 2 + no marker" "rc=$rc marker=$([ -f "$sneaky2_marker" ] && echo present || echo absent) / out: $out"
fi
case "$out" in
    *"NOT reachable from"*"main"*"freshly fetched"*) pass "P1(b) refusal names the real reason (unreachable from origin, after a fresh re-fetch)" ;;
    *) fail "P1(b) refusal should name origin-unreachability" "out: $out" ;;
esac

echo "TEST: HIMMEL-3634 P1(c)/codex-1 — forged origin/main tracking ref survives a fetch whose remote.origin.fetch has been cleared -> still refused"
B2C="$TMP_ROOT/p1-b2c"
git clone -q "$ORIGIN_P1" "$B2C"
git -C "$B2C" branch -m main 2>/dev/null || true
git -C "$B2C" checkout -q -b feat/sneaky2c main
echo 'function sneaky2c(){}' > "$B2C/sneaky2c.sh"
git -C "$B2C" add sneaky2c.sh
git -C "$B2C" -c user.email=b@t -c user.name=b commit -q -m "sneaky2c, never sent to origin"
sneaky2c_sha=$(git -C "$B2C" rev-parse HEAD)
git -C "$B2C" update-ref refs/remotes/origin/main "$sneaky2c_sha"
# The codex-1 vector: a bare `git fetch origin main` only refreshes
# refs/remotes/origin/main as a side effect of a MATCHING
# remote.origin.fetch refspec. Clearing it (no network needed, same
# tampering class as the update-ref forgery above) makes that refresh a
# silent no-op, leaving the forged tracking ref untouched -- unless the
# fetch targets a dedicated scratch ref via an explicit destination
# refspec, which git always writes regardless of configured refspecs.
git -C "$B2C" config --unset-all remote.origin.fetch || true
rc=0
out=$(cd "$B2C" && bash "$HOOK" origin "$ORIGIN_P1" <<< "refs/heads/feat/sneaky2c $sneaky2c_sha refs/heads/feat/sneaky2c $Z40" 2>&1) || rc=$?
sneaky2c_marker="$B2C/.git/cr-pending/feat/sneaky2c"
if [ "$rc" -eq 2 ] && [ ! -f "$sneaky2c_marker" ]; then
    pass "P1(c)/codex-1: cleared remote.origin.fetch does not resurrect the forged-tracking-ref bypass"
else
    fail "P1(c)/codex-1: expected exit 2 + no marker" "rc=$rc marker=$([ -f "$sneaky2c_marker" ] && echo present || echo absent) / out: $out"
fi

echo "TEST: HIMMEL-3634 round-2 codex-1 — fetchurl/pushurl divergence: refreshing origin/main via a repointed FETCH url must not launder a push whose real destination is untouched -> refused, not skipped"
# repro shape: remote.origin.url (what `git fetch origin` resolves) is
# repointed at an attacker fork pre-seeded with the exact unreviewed SHA on
# its default branch; an ordinary `git fetch origin` then makes the LOCAL
# origin/main tracking ref agree with that SHA too. But the actual PUSH
# destination -- git's own pre-push argv $2, which honors
# remote.origin.pushurl / url.<base>.pushInsteadOf and can diverge from the
# fetch url -- is the real, untouched origin. verify_empty_diff_is_reviewed
# must re-fetch by the argv-attested push destination, not by the mutable
# "origin" name, or this empty-diff safety net re-validates against the
# wrong repository's history.
R2_ORIGIN="$TMP_ROOT/r2-real-origin.git"
git init -q --bare -b main "$R2_ORIGIN"
R2_SEED="$TMP_ROOT/r2-seed"
git init -q -b main "$R2_SEED"
git -C "$R2_SEED" -c user.email=a@t -c user.name=a commit -q --allow-empty -m "shared init"
git -C "$R2_SEED" push -q "$R2_ORIGIN" main
PUSHER="$TMP_ROOT/r2-pusher"
git clone -q "$R2_ORIGIN" "$PUSHER"
git -C "$PUSHER" checkout -q -b feat/r2sneaky main
echo 'function r2sneaky(){}' > "$PUSHER/r2sneaky.sh"
git -C "$PUSHER" add r2sneaky.sh
git -C "$PUSHER" -c user.email=b@t -c user.name=b commit -q -m "r2sneaky, never reviewed"
r2_sha=$(git -C "$PUSHER" rev-parse HEAD)
R2_FORK="$TMP_ROOT/r2-fork.git"
git init -q --bare -b main "$R2_FORK"
git -C "$PUSHER" push -q "$R2_FORK" feat/r2sneaky:main
# Repoint the FETCH url at the fork and refresh the local tracking ref --
# an ordinary, unremarkable local action, no network trust required.
git -C "$PUSHER" remote set-url origin "$R2_FORK"
git -C "$PUSHER" fetch -q origin
# But git's own pre-push argv $2 for THIS push is the real, untouched
# origin (a pushurl/pushInsteadOf override, or an explicit destination).
rc=0
out=$(cd "$PUSHER" && bash "$HOOK" origin "$R2_ORIGIN" <<< "refs/heads/feat/r2sneaky $r2_sha refs/heads/feat/r2sneaky $Z40" 2>&1) || rc=$?
r2_marker="$PUSHER/.git/cr-pending/feat/r2sneaky"
if [ "$rc" -eq 2 ] && [ ! -f "$r2_marker" ]; then
    pass "round-2 codex-1: fetchurl(fork)/pushurl(real-origin) divergence is refused, not silently skipped"
else
    fail "round-2 codex-1: expected exit 2 + no marker" "rc=$rc marker=$([ -f "$r2_marker" ] && echo present || echo absent) / out: $out"
fi
case "$out" in
    *"NOT reachable from"*"main (freshly fetched from the actual push destination)"*) pass "round-2 codex-1 refusal names re-fetch from the actual push destination, not the mutable origin name" ;;
    *) fail "round-2 codex-1 refusal should name a fetch from the actual push destination" "out: $out" ;;
esac

echo "TEST: HIMMEL-3634 round-2.5 — explicit-URL push to a fork whose OWN default branch (not just HEAD) is forged to the tip -> refused, not skipped"
# P1(a) above proves this shape for the fork's HEAD symref, but its fixture
# clone-order makes HEAD and the fork's actual "main" branch agree by
# accident. This row forges the fork's named default branch directly (an
# ordinary push the attacker fully controls, no clone-order artifact) to
# confirm verify_empty_diff_is_reviewed's safety net does not degrade to
# re-checking the same attacker-controlled repository it already failed to
# get an independent answer from (round-2 regression: an earlier fix that
# always re-fetched push_remote_url reintroduced exactly this bypass).
R25_ORIGIN="$TMP_ROOT/r25-real-origin.git"
git init -q --bare -b main "$R25_ORIGIN"
R25_SEED="$TMP_ROOT/r25-seed"
git init -q -b main "$R25_SEED"
git -C "$R25_SEED" -c user.email=a@t -c user.name=a commit -q --allow-empty -m "shared init"
git -C "$R25_SEED" push -q "$R25_ORIGIN" main
R25_PUSHER="$TMP_ROOT/r25-pusher"
git clone -q "$R25_ORIGIN" "$R25_PUSHER"
git -C "$R25_PUSHER" checkout -q -b feat/r25sneaky main
echo 'function r25sneaky(){}' > "$R25_PUSHER/r25sneaky.sh"
git -C "$R25_PUSHER" add r25sneaky.sh
git -C "$R25_PUSHER" -c user.email=b@t -c user.name=b commit -q -m "r25sneaky, never reviewed"
r25_sha=$(git -C "$R25_PUSHER" rev-parse HEAD)
R25_FORK="$TMP_ROOT/r25-fork.git"
git init -q --bare -b main "$R25_FORK"
# Attacker pushes their unreviewed branch straight onto the fork's OWN main --
# an ordinary push to a repo they fully control, not a clone-order side effect.
git -C "$R25_PUSHER" push -q "$R25_FORK" feat/r25sneaky:main
rc=0
out=$(cd "$R25_PUSHER" && bash "$HOOK" "$R25_FORK" "$R25_FORK" <<< "refs/heads/feat/r25sneaky $r25_sha refs/heads/feat/r25sneaky $Z40" 2>&1) || rc=$?
r25_marker="$R25_PUSHER/.git/cr-pending/feat/r25sneaky"
if [ "$rc" -eq 2 ] && [ ! -f "$r25_marker" ]; then
    pass "round-2.5: explicit-URL push to a fork whose own main is forged to the tip is refused, not silently skipped"
else
    fail "round-2.5: expected exit 2 + no marker" "rc=$rc marker=$([ -f "$r25_marker" ] && echo present || echo absent) / out: $out"
fi
case "$out" in
    *"NOT reachable from origin's main"*) pass "round-2.5 refusal names origin (not the push target) as the re-fetch authority" ;;
    *) fail "round-2.5 refusal should name origin as the re-fetch authority, not the push target" "out: $out" ;;
esac

echo "TEST: control — a normal push with a real (non-empty) diff still reviews the same range"
B3="$TMP_ROOT/p1-b3"
git clone -q "$ORIGIN_P1" "$B3"
git -C "$B3" branch -m main 2>/dev/null || true
git -C "$B3" checkout -q -b feat/p1-control main
echo 'function control(){}' > "$B3/control.sh"
git -C "$B3" add control.sh
git -C "$B3" -c user.email=c@t -c user.name=c commit -q -m "control code"
control_sha=$(git -C "$B3" rev-parse HEAD)
rc=0
out=$(cd "$B3" && bash "$HOOK" origin "$ORIGIN_P1" <<< "refs/heads/feat/p1-control $control_sha refs/heads/feat/p1-control $Z40" 2>&1) || rc=$?
control_marker="$B3/.git/cr-pending/feat/p1-control"
if [ "$rc" -eq 0 ] && [ -f "$control_marker" ]; then
    marker_sha_ctl=$(awk -F' [|] ' '{print $2; exit}' "$control_marker" 2>/dev/null || true)
    if [ "$marker_sha_ctl" = "$control_sha" ]; then
        pass "control: normal non-empty-diff push is unaffected -- marker written, correct SHA"
    else
        fail "control: marker SHA mismatch" "expected $control_sha got $marker_sha_ctl / out: $out"
    fi
else
    fail "control: normal push should still write a marker" "rc=$rc out=$out"
fi

echo "TEST: HIMMEL-3634 round-3 CodeRabbit — an origin tag sharing the default branch's name must not redirect the re-fetch authority"
# git's remote-ref DWIM order for an unqualified fetch source tries
# refs/tags/<name> before refs/heads/<name> (confirmed empirically: a bare
# "main" fetch resolved to a same-named TAG, not the branch, in a scratch
# probe). A tag pusher -- often a lower bar than branch-push rights -- could
# otherwise redirect verify_empty_diff_is_reviewed's whole authority to
# content they control, by pushing a tag named exactly "$db".
R3_ORIGIN="$TMP_ROOT/r3-real-origin.git"
git init -q --bare -b main "$R3_ORIGIN"
R3_SEED="$TMP_ROOT/r3-seed"
git init -q -b main "$R3_SEED"
git -C "$R3_SEED" -c user.email=a@t -c user.name=a commit -q --allow-empty -m "shared init"
git -C "$R3_SEED" push -q "$R3_ORIGIN" main
R3_PUSHER="$TMP_ROOT/r3-pusher"
git clone -q "$R3_ORIGIN" "$R3_PUSHER"
git -C "$R3_PUSHER" branch -m main 2>/dev/null || true
git -C "$R3_PUSHER" checkout -q -b feat/r3sneaky main
echo 'function r3sneaky(){}' > "$R3_PUSHER/r3sneaky.sh"
git -C "$R3_PUSHER" add r3sneaky.sh
git -C "$R3_PUSHER" -c user.email=b@t -c user.name=b commit -q -m "r3sneaky, never reviewed"
r3_push_sha=$(git -C "$R3_PUSHER" rev-parse HEAD)
# Attacker pushes their OWN unreviewed commit to origin as a same-named TAG --
# a lower bar than pushing to the protected branch, and refs/heads/main on
# origin never sees it. A DWIM-vulnerable re-fetch of the bare name "main"
# would resolve to THIS tag (which trivially satisfies its own ancestor
# check), not the real refs/heads/main.
git -C "$R3_PUSHER" push -q "$R3_ORIGIN" "$r3_push_sha:refs/tags/main"
# Falsify the LOCAL origin/main tracking ref to make resolve_diff_base see an
# empty diff (same forging technique as P1(b)) -- what's under test here is
# ONLY which ref verify_empty_diff_is_reviewed's re-fetch resolves to.
git -C "$R3_PUSHER" update-ref refs/remotes/origin/main "$r3_push_sha"
rc=0
out=$(cd "$R3_PUSHER" && bash "$HOOK" origin "$R3_ORIGIN" <<< "refs/heads/feat/r3sneaky $r3_push_sha refs/heads/feat/r3sneaky $Z40" 2>&1) || rc=$?
r3_marker="$R3_PUSHER/.git/cr-pending/feat/r3sneaky"
if [ "$rc" -eq 2 ] && [ ! -f "$r3_marker" ]; then
    pass "round-3 CodeRabbit: a same-named origin tag does not launder the empty-diff check -- refused, not skipped"
else
    fail "round-3 CodeRabbit: expected exit 2 + no marker" "rc=$rc marker=$([ -f "$r3_marker" ] && echo present || echo absent) / out: $out"
fi
case "$out" in
    *"NOT reachable from"*"main"*) pass "round-3 CodeRabbit refusal names origin's main (the branch) as unreachable" ;;
    *) fail "round-3 CodeRabbit refusal should name origin's main as unreachable" "out: $out" ;;
esac

# M1: the fork fetch (resolve_diff_base) and the new origin re-fetch
# (verify_empty_diff_is_reviewed) must both be timeout-bounded. Prove the
# wrap is actually wired by resolving $_TIMEOUT_BIN to a logging stub and
# replaying the P1(a) fixture, which exercises both call sites in one push
# (the fork fetch resolves the base, then the empty diff triggers the
# origin re-fetch).
echo "TEST: HIMMEL-3634 M1 — fork fetch and origin re-fetch both run through \$_TIMEOUT_BIN"
M1_BIN="$TMP_ROOT/m1-bin"
mkdir -p "$M1_BIN"
M1_LOG="$TMP_ROOT/m1-timeout-calls.log"
: > "$M1_LOG"
cat > "$M1_BIN/timeout" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then
    echo "timeout (stub) 1.0"
    exit 0
fi
echo "called: \$*" >> "$M1_LOG"
shift
exec "\$@"
STUB
chmod +x "$M1_BIN/timeout"
out=$(cd "$ATT" && PATH="$M1_BIN:$PATH" bash "$HOOK" "$P1_FORK_URL" "$P1_FORK_URL" <<< "refs/heads/feat/sneaky $sneaky_sha refs/heads/feat/sneaky $Z40" 2>&1) || true
call_count=$(grep -c "git fetch" "$M1_LOG" 2>/dev/null || true)
if [ "${call_count:-0}" -ge 2 ]; then
    pass "M1: both the fork fetch and the origin re-fetch ran through the resolved timeout binary"
else
    fail "M1: expected >=2 timeout-wrapped git-fetch calls (fork fetch + origin re-fetch), got ${call_count:-0}" "log: $(cat "$M1_LOG" 2>/dev/null) / out: $out"
fi

# M2 (refs/cr/* scratch-ref comment correction) and M3 (named-remote-equals-
# own-URL ponytail note) are comment-only changes with no behavioural delta
# -- no test row, per the contract's "where testable".

# Summary ------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
