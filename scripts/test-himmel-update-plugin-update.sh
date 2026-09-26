#!/usr/bin/env bash
# test-himmel-update-plugin-update.sh — hermetic tests for update_installed_plugins
# (HIMMEL-3551): a plugin update may never leave a floor-`false` plugin
# enabled, so `claude plugin update <spec>` for every installed non-@himmel
# plugin must run, and must run BEFORE the lean-floor reconcile.
#
# Same mock-clone technique as test-himmel-update-chain.sh. The `claude` stub
# logs every invocation (with args) to a file so this can assert both WHICH
# specs were updated and, together with the reconcile section header's
# position in stdout, that the update runs before the reconcile. No real
# npm/bun/claude/network interaction — HIMMEL_UPDATE_CLAUDE_BIN always points
# at a local stub, never the real CLI.
#
# Bash 3.2 compatible.

set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# backdate <file> <epoch-seconds> - set a file's mtime to an exact epoch time.
# GNU touch takes `-d @<epoch>` directly; BSD/macOS touch has no epoch form,
# so fall back through BSD `date -r <epoch>` into touch's -t timestamp (same
# shape as backdate() in test-context-fill.sh) — a plain `touch -d '30 hours
# ago'` is not portable to macOS (codex-1, HIMMEL-1846 round 2).
backdate() {
    local file="$1" epoch="$2" ts
    touch -d "@$epoch" "$file" 2>/dev/null && return 0
    ts="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null)" && touch -t "$ts" "$file" 2>/dev/null && return 0
    echo "backdate: cannot set mtime on this platform" >&2
    exit 1
}

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }
assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_pass "$desc"
    else
        assert_fail "$desc — expected pattern '$pattern', got: $actual"
    fi
}
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_fail "$desc — did NOT expect pattern '$pattern', got: $actual"
    else
        assert_pass "$desc"
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
    git -C "$clone" add -A
    git -C "$clone" commit --quiet -m "scaffold"
    CHECKOUT_DIR="$clone"
}

# A `claude` stub that logs every invocation ("$@") to $2 and always exits 0 —
# never the real CLI, never touches ~/.claude.
make_claude_logging_stub() {   # <path> <log-file>
    cat > "$1" <<EOF
#!/bin/sh
echo "\$@" >> "$2"
exit 0
EOF
    chmod +x "$1"
}

echo "Test: update_installed_plugins updates every non-@himmel installed plugin, before the reconcile"
make_mock_clone
fake_home="$TMP/fake-home"
mkdir -p "$fake_home/.claude"
# A settings.json with one @himmel plugin (must NOT be updated) and two
# third-party plugins, one enabled and one floor-disabled (both are
# INSTALLED — a `false` entry is still installed, just disabled — so both
# must be updated).
cat > "$fake_home/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true,
    "codex@openai-codex": false,
    "ponytail@ponytail": true
  }
}
EOF
log="$TMP/claude-invocations.log"
: > "$log"
claude_stub="$TMP/claude-logging-stub"
make_claude_logging_stub "$claude_stub" "$log"

rc=0
out=$(USERPROFILE='' HOME="$fake_home" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "run completed (rc=$rc)"
else
    assert_fail "run completed (rc=$rc) — out: $out"
fi

log_content="$(cat "$log")"
assert_contains "updates codex@openai-codex (floor-disabled but installed)" "plugin update codex@openai-codex" "$log_content"
assert_contains "updates ponytail@ponytail (enabled)" "plugin update ponytail@ponytail" "$log_content"
assert_not_contains "never updates the @himmel plugin" "plugin update qmd@himmel" "$log_content"

# Ordering: the catch-up section must print before the reconcile section —
# this is what pins "reconcile runs AFTER every marketplace refresh and
# plugin update step" (HIMMEL-3551 Work step 5b).
catchup_pos="${out%%installed plugin version catch-up*}"
reconcile_pos="${out%%lean plugin-set reconcile*}"
if [ "${#catchup_pos}" -lt "${#reconcile_pos}" ] && [ "${#catchup_pos}" -lt "${#out}" ] && [ "${#reconcile_pos}" -lt "${#out}" ]; then
    assert_pass "plugin update catch-up runs before the lean-floor reconcile"
else
    assert_fail "plugin update catch-up runs before the lean-floor reconcile — out: $out"
fi

echo "Test: --check mode reports what would update, invokes nothing"
make_mock_clone
fake_home_check="$TMP/fake-home-check"
mkdir -p "$fake_home_check/.claude"
cp "$fake_home/.claude/settings.json" "$fake_home_check/.claude/settings.json"
log_check="$TMP/claude-invocations-check.log"
: > "$log_check"
claude_stub_check="$TMP/claude-logging-stub-check"
make_claude_logging_stub "$claude_stub_check" "$log_check"

rc=0
out_check=$(USERPROFILE='' HOME="$fake_home_check" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_check" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_check/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?
assert_contains "check mode: lists ponytail as would-update" "ponytail@ponytail" "$out_check"
check_log_content="$(cat "$log_check")"
if [ -z "$check_log_content" ]; then
    assert_pass "check mode: never invoked claude plugin update"
else
    assert_fail "check mode: never invoked claude plugin update — log: $check_log_content"
fi

echo "Test: apply mode sweeps stale (>24h) temp_git_* dirs from the plugin cache, spares fresh ones (HIMMEL-1846)"
make_mock_clone
fake_home_sweep="$TMP/fake-home-sweep"
mkdir -p "$fake_home_sweep/.claude"
cat > "$fake_home_sweep/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true
  }
}
EOF
cache_sweep="$fake_home_sweep/.claude/plugins/cache"
mkdir -p "$cache_sweep/temp_git_old" "$cache_sweep/temp_git_new" "$cache_sweep/temp_git_boundary"
touch -t 202001010000 "$cache_sweep/temp_git_old"
# 30h old: past the 24h cutoff but short of the ~48h a day-truncated -mtime
# +1 would actually require — pins the boundary -mtime +1 missed (HIMMEL-178).
backdate "$cache_sweep/temp_git_boundary" "$(($(date +%s) - 30 * 3600))"
log_sweep="$TMP/claude-invocations-sweep.log"
: > "$log_sweep"
claude_stub_sweep="$TMP/claude-logging-stub-sweep"
make_claude_logging_stub "$claude_stub_sweep" "$log_sweep"

rc=0
out_sweep=$(USERPROFILE='' HOME="$fake_home_sweep" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_sweep" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_sweep/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" 2>&1) || rc=$?

if [ ! -d "$cache_sweep/temp_git_old" ]; then
    assert_pass "apply mode removes the >24h-old temp_git_* dir"
else
    assert_fail "apply mode removes the >24h-old temp_git_* dir — still present — out: $out_sweep"
fi
if [ -d "$cache_sweep/temp_git_new" ]; then
    assert_pass "apply mode spares the fresh temp_git_* dir"
else
    assert_fail "apply mode spares the fresh temp_git_* dir — was removed"
fi
if [ ! -d "$cache_sweep/temp_git_boundary" ]; then
    assert_pass "apply mode removes a 30h-old temp_git_* dir (24-48h boundary)"
else
    assert_fail "apply mode removes a 30h-old temp_git_* dir (24-48h boundary) — still present — out: $out_sweep"
fi

echo "Test: check mode never sweeps the plugin cache"
make_mock_clone
fake_home_sweep_check="$TMP/fake-home-sweep-check"
mkdir -p "$fake_home_sweep_check/.claude"
cat > "$fake_home_sweep_check/.claude/settings.json" <<'EOF'
{
  "enabledPlugins": {
    "qmd@himmel": true
  }
}
EOF
cache_sweep_check="$fake_home_sweep_check/.claude/plugins/cache"
mkdir -p "$cache_sweep_check/temp_git_old"
touch -t 202001010000 "$cache_sweep_check/temp_git_old"
log_sweep_check="$TMP/claude-invocations-sweep-check.log"
: > "$log_sweep_check"
claude_stub_sweep_check="$TMP/claude-logging-stub-sweep-check"
make_claude_logging_stub "$claude_stub_sweep_check" "$log_sweep_check"

rc=0
out_sweep_check=$(USERPROFILE='' HOME="$fake_home_sweep_check" HIMMEL_UPDATE_CLAUDE_BIN="$claude_stub_sweep_check" HERMES_HOME="$TMP/no-hermes" \
      CLAUDE_USER_SETTINGS="$fake_home_sweep_check/.claude/settings.json" \
      bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --check 2>&1) || rc=$?

if [ -d "$cache_sweep_check/temp_git_old" ]; then
    assert_pass "check mode never removes plugin-cache temp_git_* dirs"
else
    assert_fail "check mode never removes plugin-cache temp_git_* dirs — was removed — out: $out_sweep_check"
fi

echo ""
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
