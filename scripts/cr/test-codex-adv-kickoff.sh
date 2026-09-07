#!/usr/bin/env bash
# Smoke test for scripts/cr/codex-adv-kickoff.sh (HIMMEL-2226).
#
# Usage: bash scripts/cr/test-codex-adv-kickoff.sh
#
# Exit codes:
#   0 -- all cases passed
#   1 -- at least one case failed
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/codex-adv-kickoff.sh"

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
assert_rc() { if [ "$3" = "$2" ]; then pass "$1 (rc=$3)"; else fail "$1 -- expected rc=$2, got rc=$3"; fi; }
assert_contains() {
    # $1=label $2=haystack $3=needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 -- expected to find '$3' -- got: $2" ;;
    esac
}
assert_exact() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 -- expected exactly '$3' -- got: $2"; fi
}

TMP=$(mktemp -d -t codex-adv-kickoff.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Fixture HOME: (a) guarantees the codex companion glob under
# $HOME/.claude/plugins/... resolves EMPTY regardless of what's actually
# installed on the machine running this test, so no case here can ever reach
# the launch branch and spawn a real node/codex process; (b) render-lease.sh's
# registry root defaults to $HOME/.claude/handover/bridge/render-leases, so
# this also keeps the render-lease probe off the real registry.
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

REPO="$TMP/repo"
mkdir -p "$REPO"
(
    cd "$REPO" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    git commit -q --allow-empty -m init
)

# run <branch> <cr_profile> -- checks out a fresh branch (isolates each case's
# .git/codex-adv-out/<branch> sidecars from the others) and runs the script
# with HOME pinned to the fixture. cr_profile is exported non-empty by every
# caller except T1 so load-dotenv.sh's non-clobbering load (it only fills an
# UNSET or empty var) can never pull a real CR_PROFILE value out of this
# repo's own primary-checkout .env and change which branch of the script
# fires.
run() {
    local branch="$1" cr_profile="$2"
    ( cd "$REPO" || exit 1
      git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
      # Each case runs in its own subshell so HOME/CR_PROFILE/CODEX_ADV_OK
      # cannot leak between cases -- that isolation IS the point, so the
      # "modification is local to the subshell" advice does not apply.
      # shellcheck disable=SC2030,SC2031
      export HOME="$FAKE_HOME" CR_PROFILE="$cr_profile"
      bash "$SCRIPT" )
}

# commit_high_risk_fixture_change <branch> -- HIMMEL-2707: the kickoff now
# gates on high-risk paths (cr_paths_are_high_risk) BEFORE reaching the
# dormant/launch decision the T6/T7/T8 cases below exercise. Without a real
# commit touching a HIGH-RISK path (scripts/hooks/* matches the shared
# predicate in scripts/lib/cr-high-risk-diff.sh), those branches' diff from
# main/origin-main would be EMPTY (no origin remote in this fixture, so the
# base ref falls back to local main; none of T1-T5 above commit anything) and
# get reclassified "not high-risk" -- never reaching the outcomes those cases
# assert. This is a real git operation on the shared fixture repo (like the
# checkout in run() above), so it persists on disk past this call.
commit_high_risk_fixture_change() {
    local branch="$1"
    ( cd "$REPO" || exit 1
      git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
      mkdir -p scripts/hooks
      : > "scripts/hooks/$branch.sh"
      git add "scripts/hooks/$branch.sh"
      git commit -q -m "fixture: high-risk change for $branch" )
}

# --- T1: CR_PROFILE=none -> claude-only skip note, nothing launched. ---
out=$(run t1-profile-none none 2>"$TMP/err1.txt"); rc=$?
assert_rc "T1 rc" 0 "$rc"
assert_exact "T1 stdout" "$out" "claude-only (CR_PROFILE=none) -- codex adversarial pass not launched"

# --- T2: companion absent -> exact skip line, nothing launched. ---
out=$(run t2-companion-absent fixturetest 2>"$TMP/err2.txt"); rc=$?
assert_rc "T2 rc" 0 "$rc"
assert_exact "T2 stdout" "$out" "codex adversarial pass skipped (codex not configured)"

# --- T3: stale COMPLETE prior record (cleanup-rc=0) is removed, kickoff
# proceeds (reaches the companion-not-configured skip, proving it got past
# recovery instead of exiting early).
branch=t3-stale-complete
mkdir -p "$REPO/.git/codex-adv-out"
printf '99997' >"$REPO/.git/codex-adv-out/$branch.pid"
printf 'fake-identity' >"$REPO/.git/codex-adv-out/$branch.pid.identity"
printf '0' >"$REPO/.git/codex-adv-out/$branch.pid.cleanup-rc"
out=$(run "$branch" fixturetest 2>"$TMP/err3.txt"); rc=$?
assert_rc "T3 rc" 0 "$rc"
assert_exact "T3 stdout" "$out" "codex adversarial pass skipped (codex not configured)"
if [ -e "$REPO/.git/codex-adv-out/$branch.pid" ]; then fail "T3 stale .pid not removed"; else pass "T3 stale .pid removed"; fi
if [ -e "$REPO/.git/codex-adv-out/$branch.pid.identity" ]; then fail "T3 stale .identity not removed"; else pass "T3 stale .identity removed"; fi
if [ -e "$REPO/.git/codex-adv-out/$branch.pid.cleanup-rc" ]; then fail "T3 stale .cleanup-rc not removed"; else pass "T3 stale .cleanup-rc removed"; fi

# --- T4: incomplete ownership record (pid file present, identity file
# missing) -> BLOCKS exit 1, sidecars NOT deleted (fail-closed direction).
branch=t4-incomplete
mkdir -p "$REPO/.git/codex-adv-out"
printf '99999' >"$REPO/.git/codex-adv-out/$branch.pid"
out=$(run "$branch" fixturetest 2>"$TMP/err4.txt"); rc=$?
assert_rc "T4 rc" 1 "$rc"
assert_contains "T4 stderr message" "$(cat "$TMP/err4.txt")" "ownership record is incomplete"
if [ -e "$REPO/.git/codex-adv-out/$branch.pid" ]; then pass "T4 pid sidecar preserved"; else fail "T4 pid sidecar was deleted"; fi

# --- T5: pid file present, no cleanup-rc file -> BLOCKS exit 1, sidecars
# NOT deleted.
branch=t5-no-cleanup-rc
mkdir -p "$REPO/.git/codex-adv-out"
printf '99998' >"$REPO/.git/codex-adv-out/$branch.pid"
printf 'fake-identity' >"$REPO/.git/codex-adv-out/$branch.pid.identity"
out=$(run "$branch" fixturetest 2>"$TMP/err5.txt"); rc=$?
assert_rc "T5 rc" 1 "$rc"
assert_contains "T5 stderr message" "$(cat "$TMP/err5.txt")" "cleanup status is missing"
if [ -e "$REPO/.git/codex-adv-out/$branch.pid" ]; then pass "T5 pid sidecar preserved"; else fail "T5 pid sidecar was deleted"; fi
if [ -e "$REPO/.git/codex-adv-out/$branch.pid.identity" ]; then pass "T5 identity sidecar preserved"; else fail "T5 identity sidecar was deleted"; fi

# --- T6 (HIMMEL-2377): companion FOUND, CR_PROFILE != none, CODEX_ADV_OK
# unset -> the lane is dormant (HIMMEL-1957). run-codex-adversarial.sh's own
# dormant gate is the very first thing it checks -- before touching node or
# pwsh at all -- so this fixture needs no process stubs; the backgrounded
# call is inert. Before this fix, kickoff printed "launched in background"
# unconditionally here, while scripts/cr/codex-adv-harvest.sh reports
# "dormant/absent -- not launched" for the exact same run: a reader who
# trusts kickoff's message is simply wrong. This is the assertion that goes
# RED against the pre-HIMMEL-2377 script (see the PR report for the captured
# FAIL line) and GREEN against the fixed one.
mkdir -p "$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts"
: >"$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts/codex-companion.mjs"
branch=t6-dormant-lane
commit_high_risk_fixture_change "$branch"
out=$(
    cd "$REPO" || exit 1
    git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest
    unset CODEX_ADV_OK
    bash "$SCRIPT"
) 2>"$TMP/err6.txt"; rc=$?
assert_rc "T6 rc" 0 "$rc"
assert_exact "T6 stdout truthfully reports the dormant lane, not a launch" "$out" \
    "codex adversarial pass dormant (CODEX_ADV_OK != 1, HIMMEL-1957) -- not launched; harvested as absent in step 3.1, set CODEX_ADV_OK=1 to launch"
case "$out" in
    *"launched in background"*) fail "T6 must not claim a launch while the lane is dormant" ;;
    *) pass "T6 does not claim a launch while the lane is dormant" ;;
esac
# HIMMEL-2707: dormant no longer arms. Before this fix, the once-per-branch
# marker was written UNCONDITIONALLY ahead of the launch, so this dormant
# no-op run (the lane's default state -- nothing sets CODEX_ADV_OK) would
# permanently burn the branch's one paid allowance on a round that reviewed
# nothing; a later round with CODEX_ADV_OK=1 would then hit the "already ran
# once" skip and never get its paid review at all. The marker's entire
# purpose is to cap PAID runs, so a dormant round must leave it absent.
armed_file="$REPO/.git/codex-adv-out/$branch.armed"
if [ -e "$armed_file" ]; then fail "T6 .armed sidecar must NOT be written on a dormant (no-op) run (HIMMEL-2707)"; else pass "T6 .armed sidecar correctly absent on a dormant run"; fi

# --- T7 (HIMMEL-2377): companion FOUND, CR_PROFILE != none, CODEX_ADV_OK=1
# -> the lane IS live. Negative control for T6: the ORIGINAL "launched in
# background" message must still print, unchanged, when the lane really is
# live. `pwsh` is stubbed (ahead of the real one on PATH) so the real
# launcher's render-lease heartbeat never spawns a real PowerShell process;
# the companion is real `node` running a two-line script that writes a
# marker and exits immediately, so the background job this triggers is
# bounded to well under a second.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/pwsh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB_BIN/pwsh"
LIVE_MARKER="$TMP/t7-companion-started"
rm -f "$LIVE_MARKER"
cat >"$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts/codex-companion.mjs" <<'JS'
import fs from 'node:fs';
fs.writeFileSync(process.env.T7_MARKER, 'x');
JS
branch=t7-live-lane
commit_high_risk_fixture_change "$branch"
(
    cd "$REPO" || exit 1
    git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest CODEX_ADV_OK=1
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export PATH="$STUB_BIN:$PATH"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export RENDER_LEASE_DIR="$TMP/t7-leases" T7_MARKER="$LIVE_MARKER"
    bash "$SCRIPT"
) >"$TMP/out7.txt" 2>"$TMP/err7.txt"; rc=$?
out=$(cat "$TMP/out7.txt")
assert_rc "T7 rc" 0 "$rc"
# HIMMEL-2707: the launched message now also names the launcher's watchdog
# bound and the log path the console can tail -- assert the fixed prefix/
# suffix and the shape of the middle (a numeric bound, then the branch's own
# codex-adv-out log file) rather than one brittle exact string, since the
# exact bound depends on CRITIC_TIMEOUT_SECS (unset here -> 240*2+30=510) and
# the log path's git-common-dir prefix is relative-vs-absolute depending on
# how git resolves it, which is not this test's concern.
case "$out" in
    "codex adversarial pass launched in background (bound "[0-9]*"s, log: "*"codex-adv-out/$branch) -- harvested in step 3.1 after the critic panel (HIMMEL-1407)")
        pass "T7 stdout still claims a launch when the lane really is live, now naming the bound and log path" ;;
    *) fail "T7 stdout still claims a launch when the lane really is live, now naming the bound and log path -- got: $out" ;;
esac
# Bounded wait for the backgrounded (stubbed) companion to actually start --
# proves this fixture genuinely reached the launch branch rather than a false
# pass from silently landing on the companion-not-configured skip.
marker_seen=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$LIVE_MARKER" ] && { marker_seen=1; break; }
    sleep 0.3
done
if [ "$marker_seen" -eq 1 ]; then pass "T7 background job actually reached the companion"; else fail "T7 background job never reached the companion (fixture did not exercise the live path)"; fi
# HIMMEL-2707: the once-per-branch marker must be written on a genuinely LIVE
# run (CODEX_ADV_OK=1) -- this is the positive control for T6's negative:
# only a run that actually launches gets to consume the branch's allowance.
armed_file7="$REPO/.git/codex-adv-out/$branch.armed"
if [ -s "$armed_file7" ]; then pass "T7 .armed sidecar written on a genuinely live run"; else fail "T7 .armed sidecar missing on a live run"; fi

# --- T8 (HIMMEL-2321/HIMMEL-1175 CR round 4): the head this pass launches
# against is resolved and persisted to a .head sidecar (same
# "${codex_out}.SUFFIX" convention as .pid/.rc/.err) BEFORE the launch
# decision, so codex-adv-harvest.sh can later stamp the CR ledger with the
# commit this pass actually reviewed, never whatever HEAD drifts to by
# harvest time. CODEX_ADV_OK is left UNSET (the dormant default, HIMMEL-1957)
# because the sidecar write sits ahead of the live/dormant branch: it costs
# no companion process to prove, and T7 above covers the live path.
: >"$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts/codex-companion.mjs"
branch=t8-head-persist
commit_high_risk_fixture_change "$branch"
EXPECTED_HEAD="$(git -C "$REPO" rev-parse HEAD)"
out=$(run "$branch" fixturetest 2>"$TMP/err8.txt"); rc=$?
assert_rc "T8 rc" 0 "$rc"
assert_contains "T8 stdout" "$out" "codex adversarial pass dormant"
head_file="$REPO/.git/codex-adv-out/$branch.head"
if [ -s "$head_file" ]; then pass "T8 .head sidecar written"; else fail "T8 .head sidecar missing"; fi
assert_exact "T8 .head content is the launched commit" "$(cat "$head_file" 2>/dev/null)" "$EXPECTED_HEAD"
# HIMMEL-2707: dormant no longer arms. .head is a separate concern
# (HIMMEL-2321/HIMMEL-1175 attribution) and its own guard above is
# unconditional, so it is still written regardless of CODEX_ADV_OK -- but
# CODEX_ADV_OK is unset here (dormant), so .armed must stay absent (was
# previously asserted to equal EXPECTED_HEAD, which was the bug this ticket
# fixes: a dormant no-op used to consume the branch's one paid allowance).
armed_file="$REPO/.git/codex-adv-out/$branch.armed"
if [ -e "$armed_file" ]; then fail "T8 .armed sidecar must NOT be written on a dormant run (HIMMEL-2707)"; else pass "T8 .armed sidecar correctly absent on a dormant run"; fi

# --- T9 (HIMMEL-2707): docs-only diff -> the risk gate SKIPS before ever
# reaching the dormant/launch decision. Branched explicitly off `main` (not
# off whatever T6/T7/T8 left checked out) so the diff is exactly the one
# docs-only file, not also carrying their accumulated scripts/hooks/*
# fixture commits.
branch=t9-docs-only-skip
(
    cd "$REPO" || exit 1
    git checkout -q main
    git checkout -q -b "$branch"
    mkdir -p docs/internals
    echo "docs change" >> docs/internals/enforcement.md
    git add docs/internals/enforcement.md
    git commit -q -m "fixture: docs-only change for $branch"
)
out=$(
    cd "$REPO" || exit 1
    git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest
    unset CODEX_ADV_OK
    bash "$SCRIPT" 2>"$TMP/err9.txt"
); rc=$?
assert_rc "T9 rc" 0 "$rc"
assert_exact "T9 stdout" "$out" "codex adversarial pass skipped: not high-risk (HIMMEL-2707)"
armed_file9="$REPO/.git/codex-adv-out/$branch.armed"
if [ -e "$armed_file9" ]; then fail "T9 .armed sidecar should not exist for a not-high-risk diff"; else pass "T9 .armed sidecar correctly absent"; fi

# --- T10 (HIMMEL-2707): once-per-branch. A high-risk diff whose branch
# already has a (pre-seeded) .armed marker must skip with the "already ran"
# line and never reach the launch decision at all -- proving the marker, not
# the diff content, is what's consulted first.
branch=t10-already-armed-skip
(
    cd "$REPO" || exit 1
    git checkout -q main
    git checkout -q -b "$branch"
    mkdir -p scripts/hooks
    : > "scripts/hooks/$branch.sh"
    git add "scripts/hooks/$branch.sh"
    git commit -q -m "fixture: high-risk change for $branch"
)
mkdir -p "$REPO/.git/codex-adv-out"
printf 'deadbeef\n' > "$REPO/.git/codex-adv-out/$branch.armed"
out=$(
    cd "$REPO" || exit 1
    git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest
    unset CODEX_ADV_OK
    bash "$SCRIPT" 2>"$TMP/err10.txt"
); rc=$?
assert_rc "T10 rc" 0 "$rc"
assert_exact "T10 stdout" "$out" "codex adversarial pass skipped: already ran once for branch '$branch' (HIMMEL-2707)"
assert_exact "T10 .armed content unchanged (no second write)" "$(cat "$REPO/.git/codex-adv-out/$branch.armed" 2>/dev/null)" "deadbeef"
case "$out" in
    *"launched in background"*|*"dormant"*) fail "T10 must not reach the launch decision on an already-armed branch" ;;
    *) pass "T10 does not reach the launch decision on an already-armed branch" ;;
esac

# --- T11 (HIMMEL-2707): the diff cannot be classified at all (no resolvable
# base ref) -> fails OPEN (arms) rather than silently skipping, and says so
# on stderr with the required "armed: diff undeterminable (fail-open,
# capped)" prefix so a reader can tell this apart from a genuinely
# high-risk diff. Uses a SEPARATE throwaway repo (not $REPO) whose only
# branch is "trunk" -- no "main"/"master" and no origin remote, so
# default_branch()'s own hardcoded 'main' fallback names a branch that does
# not exist here, and codex_adv_is_high_risk's base-ref resolution comes up
# empty. Isolated so this can't disturb any of $REPO's other cases.
REPO2="$TMP/repo2"
mkdir -p "$REPO2"
(
    cd "$REPO2" || exit 1
    git init -q -b trunk .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    git commit -q --allow-empty -m init
)
out=$(
    cd "$REPO2" || exit 1
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest
    unset CODEX_ADV_OK
    bash "$SCRIPT" 2>"$TMP/err11.txt"
); rc=$?
assert_rc "T11 rc" 0 "$rc"
assert_contains "T11 stdout still reaches the dormant/launch decision (fail-open armed it)" "$out" "codex adversarial pass dormant"
assert_contains "T11 stderr carries the required fail-open prefix" "$(cat "$TMP/err11.txt")" "armed: diff undeterminable (fail-open, capped)"
assert_contains "T11 stderr names the unresolved base ref" "$(cat "$TMP/err11.txt")" "could not be resolved"
# HIMMEL-2707: dormant no longer arms, even on the fail-open path -- fail-open
# only decides whether the diff is TREATED as high-risk; CODEX_ADV_OK is still
# unset here, so the run stays dormant and must not spend the branch's one
# paid allowance on a no-op.
armed_file11="$REPO2/.git/codex-adv-out/trunk.armed"
if [ -e "$armed_file11" ]; then fail "T11 .armed sidecar must NOT be written on a dormant run, even fail-open (HIMMEL-2707)"; else pass "T11 .armed sidecar correctly absent on a dormant fail-open run"; fi

# --- T12 (HIMMEL-2707): the literal `0` regression this ticket fixes. Before
# the fix, the launcher's own watchdog (run-codex-adversarial.sh's 6th
# positional, timeout-seconds) always got a hardcoded `0`, which DISARMS it
# entirely -- so an orphaned paid node process (harvest never runs: an
# aborted /pr-check, a dead session) could run forever with no Linux reaper.
# This asserts the ARGUMENT kickoff actually hands the launcher is non-zero
# and numeric, which is the one fact that would have caught the regression at
# its source rather than at whatever downstream symptom eventually surfaced
# it. No production seam needed: `bash -x` traces the real backgrounded
# launcher invocation (kickoff always makes this call, live or dormant --
# HIMMEL-2377) with every variable already expanded, so the 6th argument on
# that trace line is exactly what run-codex-adversarial.sh receives.
# CODEX_ADV_OK is left UNSET (HIMMEL-1957 dormant default) so the launcher
# exits immediately after its own dormant check, before ever touching node --
# this case needs only the launch ARGUMENTS, not a live companion process
# (T7 above already covers the live path).
: >"$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts/codex-companion.mjs"
branch=t12-nonzero-bound
commit_high_risk_fixture_change "$branch"
out=$(
    cd "$REPO" || exit 1
    git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest
    unset CODEX_ADV_OK
    bash -x "$SCRIPT" 2>"$TMP/trace12.txt"
); rc=$?
assert_rc "T12 rc" 0 "$rc"
launcher_line=$(grep -F "run-codex-adversarial.sh" "$TMP/trace12.txt" 2>/dev/null | tail -1)
launcher_timeout_arg=$(printf '%s\n' "$launcher_line" | awk '{print $(NF-1)}')
case "$launcher_timeout_arg" in
    ''|*[!0-9]*|0) fail "T12 kickoff must pass a non-zero numeric bound to the launcher -- got '$launcher_timeout_arg' (trace line: $launcher_line)" ;;
    *) pass "T12 kickoff passes a non-zero bound ($launcher_timeout_arg) to the launcher" ;;
esac

# --- T13 (HIMMEL-2707): the actual user-visible bug this ticket fixes. A
# dormant round (CODEX_ADV_OK unset -- the default; nothing in the repo sets
# it) on a branch must NOT burn that branch's once-per-branch allowance: a
# LATER round on the SAME branch (same commit, no new push) with
# CODEX_ADV_OK=1 must still reach the launch path, instead of hitting the
# "already ran once" skip that a dormant no-op would have wrongly earned
# before this fix -- which is exactly what happened on the live branch this
# ticket was filed against.
branch=t13-allowance-not-burned
commit_high_risk_fixture_change "$branch"
armed_file13="$REPO/.git/codex-adv-out/$branch.armed"

# Round 1: dormant.
out13a=$(
    cd "$REPO" || exit 1
    git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest
    unset CODEX_ADV_OK
    bash "$SCRIPT" 2>"$TMP/err13a.txt"
); rc13a=$?
assert_rc "T13 round 1 (dormant) rc" 0 "$rc13a"
assert_contains "T13 round 1 stdout is dormant" "$out13a" "codex adversarial pass dormant"
if [ -e "$armed_file13" ]; then fail "T13 round 1 (dormant) must not write .armed"; else pass "T13 round 1 (dormant) correctly leaves .armed absent"; fi

# Round 2: live, SAME branch, no new commit -- must still reach the launch
# path, proving round 1's dormant no-op did not burn the allowance.
LIVE_MARKER13="$TMP/t13-companion-started"
rm -f "$LIVE_MARKER13"
cat >"$FAKE_HOME/.claude/plugins/cache/openai-codex/codex/1.0.0/scripts/codex-companion.mjs" <<'JS'
import fs from 'node:fs';
fs.writeFileSync(process.env.T13_MARKER, 'x');
JS
(
    cd "$REPO" || exit 1
    git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest CODEX_ADV_OK=1
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export PATH="$STUB_BIN:$PATH"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export RENDER_LEASE_DIR="$TMP/t13-leases" T13_MARKER="$LIVE_MARKER13"
    bash "$SCRIPT"
) >"$TMP/out13b.txt" 2>"$TMP/err13b.txt"; rc13b=$?
out13b=$(cat "$TMP/out13b.txt")
assert_rc "T13 round 2 (live) rc" 0 "$rc13b"
case "$out13b" in
    *"already ran once"*) fail "T13 round 2 (live) must NOT hit the already-ran skip -- round 1's dormant no-op must not have burned the allowance -- got: $out13b" ;;
    *"launched in background"*) pass "T13 round 2 (live) reaches the launch path -- the allowance survived the dormant round" ;;
    *) fail "T13 round 2 (live) did not claim a launch -- got: $out13b" ;;
esac
marker13_seen=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$LIVE_MARKER13" ] && { marker13_seen=1; break; }
    sleep 0.3
done
if [ "$marker13_seen" -eq 1 ]; then pass "T13 round 2 background job actually reached the companion"; else fail "T13 round 2 background job never reached the companion (fixture did not exercise the live path)"; fi
if [ -s "$armed_file13" ]; then pass "T13 round 2 (live) writes .armed once it genuinely launches"; else fail "T13 round 2 (live) .armed sidecar missing"; fi

# --- T14 (HIMMEL-2707): a RENAME out of a protected path must classify
# HIGH RISK, not ordinary. With git's rename detection on, `git diff
# --name-only` reports only the DESTINATION of a rename -- so moving
# scripts/hooks/<x>.sh to docs/<x>.sh would surface only the harmless
# docs/ path and silently skip the pass on a change that DELETED a hook.
# Commit the hook file on `main` FIRST (so it exists to be moved), then on
# the branch `git mv` it to docs/ in its own commit -- the branch diff
# against main is then exactly that one rename, identical content, single
# commit, which is what git needs to detect it as a rename rather than an
# unrelated delete+add pair.
branch=t14-rename-out-of-protected-skip
(
    cd "$REPO" || exit 1
    git checkout -q main
    mkdir -p scripts/hooks
    printf '#!/usr/bin/env bash\necho hook\n' > scripts/hooks/t14-mover.sh
    git add scripts/hooks/t14-mover.sh
    git commit -q -m "fixture: seed protected file for $branch"
)
(
    cd "$REPO" || exit 1
    git checkout -q -b "$branch"
    mkdir -p docs
    git mv scripts/hooks/t14-mover.sh docs/t14-mover.sh
    git commit -q -m "fixture: rename protected file out of scripts/hooks/ for $branch"
)
# Evidence the fixture genuinely exercises the gap: with rename detection on,
# --name-only shows only the new docs/ path; with --no-renames it shows both
# the old (deleted) protected path and the new (added) one. These two outputs
# must differ, or T14 (and its RED control) prove nothing.
diff_with_renames=$(cd "$REPO" && git diff --name-only "main...$branch")
diff_no_renames=$(cd "$REPO" && git diff --no-renames --name-only "main...$branch")
echo "T14 fixture evidence: git diff --name-only main...$branch -> [$diff_with_renames]"
echo "T14 fixture evidence: git diff --no-renames --name-only main...$branch -> [$diff_no_renames]"
if [ "$diff_with_renames" = "$diff_no_renames" ]; then
    fail "T14 fixture did not produce a git-detected rename (--name-only and --no-renames --name-only agree) -- RED control would pass for the wrong reason"
else
    pass "T14 fixture genuinely produces a git-detected rename (--name-only and --no-renames --name-only differ)"
fi
out=$(
    cd "$REPO" || exit 1
    git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest
    unset CODEX_ADV_OK
    bash "$SCRIPT" 2>"$TMP/err14.txt"
); rc=$?
assert_rc "T14 rc" 0 "$rc"
assert_contains "T14 stdout reaches the dormant/launch decision (classified HIGH RISK, not skipped)" "$out" "codex adversarial pass dormant"
case "$out" in
    *"not high-risk"*) fail "T14 must not classify a rename out of a protected path as not-high-risk -- got: $out" ;;
    *) pass "T14 does not hit the not-high-risk skip for a rename out of a protected path" ;;
esac
armed_file14="$REPO/.git/codex-adv-out/$branch.armed"
if [ -e "$armed_file14" ]; then fail "T14 .armed sidecar should not exist for a dormant run"; else pass "T14 .armed sidecar correctly absent"; fi

echo "---"
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "PASS all cases"
exit 0
