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
(
    cd "$REPO" || exit 1
    git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
    # shellcheck disable=SC2030,SC2031  # per-case isolation, see run() above
    export HOME="$FAKE_HOME" CR_PROFILE=fixturetest CODEX_ADV_OK=1
    export PATH="$STUB_BIN:$PATH"
    export RENDER_LEASE_DIR="$TMP/t7-leases" T7_MARKER="$LIVE_MARKER"
    bash "$SCRIPT"
) >"$TMP/out7.txt" 2>"$TMP/err7.txt"; rc=$?
out=$(cat "$TMP/out7.txt")
assert_rc "T7 rc" 0 "$rc"
assert_exact "T7 stdout still claims a launch when the lane really is live" "$out" \
    "codex adversarial pass launched in background -- harvested in step 3.1 after the critic panel (HIMMEL-1407)"
# Bounded wait for the backgrounded (stubbed) companion to actually start --
# proves this fixture genuinely reached the launch branch rather than a false
# pass from silently landing on the companion-not-configured skip.
marker_seen=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$LIVE_MARKER" ] && { marker_seen=1; break; }
    sleep 0.3
done
if [ "$marker_seen" -eq 1 ]; then pass "T7 background job actually reached the companion"; else fail "T7 background job never reached the companion (fixture did not exercise the live path)"; fi

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
EXPECTED_HEAD="$(git -C "$REPO" rev-parse HEAD)"
out=$(run "$branch" fixturetest 2>"$TMP/err8.txt"); rc=$?
assert_rc "T8 rc" 0 "$rc"
assert_contains "T8 stdout" "$out" "codex adversarial pass dormant"
head_file="$REPO/.git/codex-adv-out/$branch.head"
if [ -s "$head_file" ]; then pass "T8 .head sidecar written"; else fail "T8 .head sidecar missing"; fi
assert_exact "T8 .head content is the launched commit" "$(cat "$head_file" 2>/dev/null)" "$EXPECTED_HEAD"

echo "---"
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "PASS all cases"
exit 0
