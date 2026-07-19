#!/usr/bin/env bash
# test-himmel-update-chain.sh — hermetic tests for the six-item update chain
# (HIMMEL-893): dirty-tree pre-check, per-item status table, and abort-on-
# first-failure semantics in scripts/himmel-update.sh.
#
# Same mock-clone technique as test-himmel-update.sh (himmel-update.sh
# resolves its own repo root via BASH_SOURCE/.. and cd's there, so it's
# tested by copying it into a throwaway clone and running it from inside
# that clone) — extended to COMMIT the copied scaffolding files so the mock
# clone's working tree starts clean (otherwise every apply-mode run would
# trip the new dirty-tree guard on the test harness's own untracked files,
# not a real dirty tree). No real npm/bun/claude/network interaction: the
# mock clone carries no scripts/jira, no scripts/lib/qmd-bin.sh, and no
# HERMES_HOME/LUNA_VAULT_PATH checkout, so those three items skip cleanly by
# construction; the one non-git external tool touched (claude) is replaced
# via HIMMEL_UPDATE_CLAUDE_BIN with a local stub — never the real CLI.
#
# Covers:
#   1. dirty-tree guard fires before any pull, exits non-zero.
#   2. a clean apply run prints the six-item status table (skip/update/
#      up-to-date, never "not-attempted" when nothing failed).
#   3. mid-chain failure (a failing claude stub -> marketplace step) aborts:
#      later items report not-attempted, script exits non-zero.
#   4. --check mode also prints the status table, mutates nothing — verified
#      hermetically (fake HOME + Claude/hermes overrides) via a full HEAD +
#      tracked/untracked working-tree snapshot, not HEAD alone.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -q "$pattern"; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected pattern '$pattern', got: $actual"
    fi
}
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -q "$pattern"; then
        assert_fail "$desc — did NOT expect pattern '$pattern', got: $actual"
    else
        assert_pass "$desc"
    fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected '$expected', got '$actual'"
    fi
}

_repo_counter=0

# Build a mock upstream bare repo + a clone with himmel-update.sh (+ the libs
# it sources) dropped in and COMMITTED, so the working tree starts clean.
# Sets CHECKOUT_DIR.
make_mock_clone() {
    _repo_counter=$((_repo_counter + 1))
    local base="$TMP/repo_${_repo_counter}"
    local bare="$base/upstream.git"
    local clone="$base/checkout"
    mkdir -p "$bare" "$clone"

    git init --bare --quiet "$bare"
    git init --quiet "$clone"
    git -C "$clone" config user.email "test@test.test"
    git -C "$clone" config user.name "Test"
    git -C "$clone" remote add origin "$bare"
    printf 'init\n' > "$clone/file.txt"
    git -C "$clone" add file.txt
    git -C "$clone" commit --quiet -m "init"

    local defbranch
    defbranch=$(git -C "$clone" rev-parse --abbrev-ref HEAD)
    git -C "$clone" push --quiet origin "HEAD:$defbranch" 2>/dev/null
    git -C "$clone" branch --quiet --set-upstream-to="origin/$defbranch" "$defbranch" 2>/dev/null || \
        git -C "$clone" branch --quiet -u "origin/$defbranch" "$defbranch" 2>/dev/null || true

    mkdir -p "$clone/scripts/guardrails" "$clone/scripts/lib"
    cp "$SCRIPT" "$clone/scripts/himmel-update.sh"
    local src_scripts; src_scripts="$(dirname "$SCRIPT")"
    cp "$src_scripts/guardrails/lib.sh"        "$clone/scripts/guardrails/lib.sh"
    cp "$src_scripts/lib/cadence-format.sh"    "$clone/scripts/lib/cadence-format.sh"
    cp "$src_scripts/lib/resolve-hermes-py.sh" "$clone/scripts/lib/resolve-hermes-py.sh"
    cp "$src_scripts/lib/load-dotenv.sh"       "$clone/scripts/lib/load-dotenv.sh"
    # Commit the scaffolding — a clean tree is the precondition every case
    # below actually wants to test, not test-harness noise.
    git -C "$clone" add -A
    git -C "$clone" commit --quiet -m "scaffold"
    CHECKOUT_DIR="$clone"
}

# A `claude` stub that always succeeds/fails, for HIMMEL_UPDATE_CLAUDE_BIN —
# never the real CLI, never touches ~/.claude.
make_claude_stub() {   # <path> <exit-code>
    printf '#!/bin/sh\nexit %s\n' "$2" > "$1"
    chmod +x "$1"
}

# ─── Test 1: dirty-tree guard ────────────────────────────────────────────────
echo "Test 1: dirty tree -> refuses before any pull, exits non-zero"
make_mock_clone
printf 'dirty\n' >> "$CHECKOUT_DIR/file.txt"
claude_ok_1="$TMP/claude-ok-test1"; make_claude_stub "$claude_ok_1" 0
# Isolated like Tests 2-4 (fake HOME + USERPROFILE cleared + explicit
# CLAUDE_USER_SETTINGS + HIMMEL_UPDATE_CLAUDE_BIN stub) — a dirty-tree-guard
# regression that let this run past the check would otherwise read/write the
# developer machine's real ~/.claude instead of staying hermetic.
fake_home_1="$TMP/fake-home-test1"; mkdir -p "$fake_home_1"
rc=0
# HIMMEL_UPDATE_AUTOSTASH='' keeps this hermetic: without it, an operator who
# exported the opt-in (or set it in .env, now bridged) would flip this guard to
# autostash and fail the refusal assertions below on their machine.
out=$(USERPROFILE='' HOME="$fake_home_1" HIMMEL_UPDATE_CLAUDE_BIN="$claude_ok_1" HERMES_HOME="$TMP/no-hermes" \
      HIMMEL_UPDATE_AUTOSTASH='' \
      CLAUDE_USER_SETTINGS="$fake_home_1/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
assert_eq "dirty tree: rc non-zero" "1" "$rc"
assert_contains "dirty tree: refusal message" "refusing to pull into a dirty tree" "$out"
assert_not_contains "dirty tree: never reached the chain" "\\[1/6\\]" "$out"
git -C "$CHECKOUT_DIR" checkout --quiet -- file.txt

# ─── Test 2: clean apply run -> full status table, all six items reported ───
echo "Test 2: clean apply run -> six-item status table, no not-attempted"
claude_ok="$TMP/claude-ok"; make_claude_stub "$claude_ok" 0
# Isolated like Test 4 (fake HOME + USERPROFILE cleared + explicit
# CLAUDE_USER_SETTINGS) — this is an apply-mode run, so without this the
# advisory steps' default $HOME/.claude reads/writes would hit the real
# developer machine's config instead of staying hermetic.
fake_home_2="$TMP/fake-home-test2"; mkdir -p "$fake_home_2"
rc=0
out=$(USERPROFILE='' HOME="$fake_home_2" HIMMEL_UPDATE_CLAUDE_BIN="$claude_ok" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_2/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
assert_eq "clean run: rc 0" "0" "$rc"
assert_contains "clean run: status table header" "==> update chain status" "$out"
for id in pull marketplace jira_cli qmd_fork hermes luna_template; do
    assert_contains "clean run: table lists '$id'" "^ *$id " "$out"
done
assert_contains "clean run: pull is up-to-date (mock clone starts current)" "pull  *up-to-date" "$out"
assert_contains "clean run: marketplace updated via stub" "marketplace  *updated" "$out"
assert_contains "clean run: jira_cli skipped (no scripts/jira in mock clone)" "jira_cli  *skipped" "$out"
assert_contains "clean run: qmd_fork skipped (no qmd-bin.sh in mock clone)" "qmd_fork  *skipped" "$out"
assert_contains "clean run: hermes skipped (HERMES_HOME empty)" "hermes  *skipped" "$out"
assert_contains "clean run: luna_template skipped (no LUNA_VAULT_PATH)" "luna_template  *skipped" "$out"
assert_not_contains "clean run: no not-attempted items" "not-attempted" "$out"

# ─── Test 3: mid-chain failure aborts ────────────────────────────────────────
echo "Test 3: marketplace step fails -> later items not-attempted, rc non-zero"
claude_fail="$TMP/claude-fail"; make_claude_stub "$claude_fail" 3
# report_cadence_stale only prints a header for a runner dir that is actually
# ARMED and stale — the mock clone carries no armed cadence by construction,
# so without a synthetic fixture the step would silently emit nothing and
# there'd be nothing to assert (unlike its neighbors below, which each print
# an UNCONDITIONAL header). Feed it one stale pipeline-cadence runner
# (format v1, current CADENCE_RUNNER_FORMAT_VERSION is 4) via PIPELINE_BAT_DIR.
stale_cadence_dir="$TMP/stale-pipeline-cadence"
mkdir -p "$stale_cadence_dir"
printf '#!/usr/bin/env bash\n# himmel-cadence-runner-format: 1\n' > "$stale_cadence_dir/pipeline-harvest.sh"
# Isolated like Test 4 (fake HOME + USERPROFILE cleared + explicit
# CLAUDE_USER_SETTINGS) — this is an apply-mode run, so without this the
# advisory steps' default $HOME/.claude reads/writes would hit the real
# developer machine's config instead of staying hermetic.
fake_home_3="$TMP/fake-home-test3"; mkdir -p "$fake_home_3"
rc=0
out=$(USERPROFILE='' HOME="$fake_home_3" HIMMEL_UPDATE_CLAUDE_BIN="$claude_fail" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_3/.claude/settings.json" \
      PIPELINE_BAT_DIR="$stale_cadence_dir" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
assert_eq "abort: rc non-zero" "1" "$rc"
assert_contains "abort: marketplace reported failed" "marketplace  *failed" "$out"
assert_contains "abort: jira_cli not-attempted" "jira_cli  *not-attempted" "$out"
assert_contains "abort: qmd_fork not-attempted" "qmd_fork  *not-attempted" "$out"
assert_contains "abort: hermes not-attempted" "hermes  *not-attempted" "$out"
assert_contains "abort: luna_template not-attempted" "luna_template  *not-attempted" "$out"
assert_not_contains "abort: never reached step [3/6]" "\\[3/6\\]" "$out"
# HIMMEL-893 CR fix: a mid-chain failure must NOT skip the pre-existing
# best-effort advisory steps (update_codex, rewire_statusline,
# report_plugin_gap, reconcile_plugins, report_cadence_stale,
# report_guardrail_block) — they predate this ticket and always ran
# regardless of chain outcome. Each prints its own unconditional header, so
# their presence in the output (even after marketplace failed) proves they
# still executed.
assert_contains "abort: advisory step (update_codex) still ran after chain failure" "codex plugin re-sync" "$out"
assert_contains "abort: advisory step (rewire_statusline) still ran after chain failure" "statusLine re-wire" "$out"
assert_contains "abort: advisory step (report_plugin_gap) still ran after chain failure" "plugin install-state" "$out"
assert_contains "abort: advisory step (reconcile_plugins) still ran after chain failure" "lean plugin-set reconcile" "$out"
assert_contains "abort: advisory step (report_guardrail_block) still ran after chain failure" "guardrail-mode block" "$out"
assert_contains "abort: advisory step (report_cadence_stale) still ran after chain failure" "pipeline-cadence runners are STALE" "$out"

# ─── Test 4: --check mode reports the table without mutating ────────────────
# Isolated like Tests 1-3 (HERMES_HOME/HIMMEL_UPDATE_CLAUDE_BIN stubs so no
# real hermes checkout or claude CLI is touched), PLUS a fake HOME (and
# USERPROFILE cleared, same pattern test-himmel-update-hermes.sh's
# cadence_user_home case uses) + an explicit CLAUDE_USER_SETTINGS override —
# the --check dispatch's advisory steps (report_plugin_gap, reconcile_plugins,
# report_guardrail_block, report_cadence_stale) all default to reading under
# $HOME/.claude when no override is given, which without this would read the
# REAL developer machine's ~/.claude instead of staying hermetic.
echo "Test 4: --check -> prints the status table, mutates nothing (repo or ~/.claude)"
fake_home="$TMP/fake-home-check"; mkdir -p "$fake_home"
claude_stub_check="$TMP/claude-check-stub"; make_claude_stub "$claude_stub_check" 0
before_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
# Full tracked+untracked working-tree snapshot, not just HEAD — a --check run
# that left stray untracked/modified files behind (e.g. a lib writing a cache
# file) would pass the HEAD-only check but fail this one.
before_status=$(git -C "$CHECKOUT_DIR" status --porcelain --ignore-submodules)
# Full fake-HOME snapshot (hash of every file under it) — proves --check
# mutates neither the repo NOR user config; a --check run that wrote/edited
# something under $HOME/.claude would pass the repo-only checks above but
# fail this one.
before_home=$(find "$fake_home" \( -type f -exec cksum {} \; -o -type d -print \) 2>/dev/null | sort)
rc=0
out=$(USERPROFILE='' HOME="$fake_home" HERMES_HOME="$TMP/no-hermes" \
      HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_check" \
      CLAUDE_USER_SETTINGS="$fake_home/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
after_head=$(git -C "$CHECKOUT_DIR" rev-parse HEAD)
after_status=$(git -C "$CHECKOUT_DIR" status --porcelain --ignore-submodules)
after_home=$(find "$fake_home" \( -type f -exec cksum {} \; -o -type d -print \) 2>/dev/null | sort)
assert_eq "check: rc 0" "0" "$rc"
assert_contains "check: status table header" "==> update chain status" "$out"
assert_contains "check: marketplace deferred" "marketplace  *skipped" "$out"
assert_eq "check: HEAD unchanged (no pull)" "$before_head" "$after_head"
assert_eq "check: full repo state unchanged (tracked + untracked)" "$before_status" "$after_status"
assert_eq "check: fake HOME unchanged (no config mutation)" "$before_home" "$after_home"

# ─── Test 5: a genuine hermes failure aborts the chain like any other item ──
# HIMMEL-893 CR fix: update_hermes used to swallow a real pull failure as a
# non-aborting warn, so hermes never appeared as "failed" and luna_template
# always ran regardless. Build a REAL NousResearch-named local checkout (bare
# repo, no real network) with a genuine non-fast-forward divergence — a real
# failure, not an absent/offline skip — and assert it aborts the chain
# exactly like Test 3's marketplace failure does.
echo "Test 5: hermes pull failure -> hermes failed, luna_template not-attempted, rc non-zero"
make_mock_clone
claude_ok_5="$TMP/claude-ok-test5"; make_claude_stub "$claude_ok_5" 0
bare5="$TMP/bare5/NousResearch/hermes-agent.git"
mkdir -p "$bare5"; git init --bare --quiet "$bare5"
seed5="$TMP/seed5"
git clone --quiet "$bare5" "$seed5"
git -C "$seed5" config user.email "test@test.test"; git -C "$seed5" config user.name "Test"
printf 'v1\n' > "$seed5/f.txt"; git -C "$seed5" add f.txt; git -C "$seed5" commit --quiet -m v1
defbranch5=$(git -C "$seed5" rev-parse --abbrev-ref HEAD)
git -C "$seed5" push --quiet origin "HEAD:$defbranch5"
hermes_home_5="$TMP/hermes-home-5"
git clone --quiet "$bare5" "$hermes_home_5/hermes-agent"
git -C "$hermes_home_5/hermes-agent" config user.email "test@test.test"
git -C "$hermes_home_5/hermes-agent" config user.name "Test"
printf 'local-edit\n' > "$hermes_home_5/hermes-agent/local.txt"
git -C "$hermes_home_5/hermes-agent" add local.txt
git -C "$hermes_home_5/hermes-agent" commit --quiet -m "local unpushed"
printf 'v2\n' > "$seed5/f.txt"; git -C "$seed5" add f.txt; git -C "$seed5" commit --quiet -m v2
git -C "$seed5" push --quiet origin "HEAD:$defbranch5"
# Isolated like Tests 2-4 — apply-mode run, so a fake HOME keeps the advisory
# steps off the real developer machine's ~/.claude.
fake_home_5="$TMP/fake-home-test5"; mkdir -p "$fake_home_5"
rc=0
out=$(USERPROFILE='' HOME="$fake_home_5" HIMMEL_UPDATE_CLAUDE_BIN="$claude_ok_5" HERMES_HOME="$hermes_home_5" \
      CLAUDE_USER_SETTINGS="$fake_home_5/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
assert_eq "hermes fail: rc non-zero" "1" "$rc"
assert_contains "hermes fail: hermes reported failed" "hermes  *failed" "$out"
assert_contains "hermes fail: luna_template not-attempted" "luna_template  *not-attempted" "$out"
assert_not_contains "hermes fail: never reached step [6/6]" "\\[6/6\\]" "$out"
# Same HIMMEL-893 CR contract as Test 3: the pre-existing best-effort
# advisory steps still run unconditionally even after this mid-chain failure.
assert_contains "hermes fail: advisory step (update_codex) still ran after chain failure" "codex plugin re-sync" "$out"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
