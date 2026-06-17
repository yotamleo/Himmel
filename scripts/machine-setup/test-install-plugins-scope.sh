#!/usr/bin/env bash
# test-install-plugins-scope.sh — smoke tests for the --scope flag added to
# scripts/machine-setup/install-plugins.sh (dual-scope install).
#
# Drives the real script in --dry-run so no plugin is actually installed,
# and asserts the chosen scope threads through to BOTH the
# `claude plugin marketplace add` and `claude plugin install` calls.
#
# install-plugins.ps1 carries the same -Scope param as a PowerShell
# ValidateSet — that twin is NOT covered here; keep both in lockstep when
# changing either (sanity-check with `pwsh install-plugins.ps1 -DryRun
# -Scope project`).
#
# Covers:
#   1. Default (no flag) → `--scope user` on install + marketplace add.
#   2. `--scope project` → `--scope project` on both.
#   3. Invalid `--scope bogus` → exit 2 (validation rejects before preflight).
#   4. autoUpdate patch (HIMMEL-365) → dry-run emits the autoUpdate intent for a
#      template-flagged marketplace, targeting the scope-correct settings file.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# Test 3 first — validation runs before the claude/jq preflight, so it works
# even on a host without the CLI.
set +e
out=$(bash "$script" --dry-run --scope bogus 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid scope should exit 2, got $rc"
printf '%s' "$out" | grep -q "invalid --scope: bogus" || fail "missing invalid-scope diagnostic"
echo "ok: invalid scope rejected (exit 2)"

# Tests 1 + 2 need the claude + jq preflight to pass.
if ! command -v jq >/dev/null 2>&1 || ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude and/or jq not on PATH — dry-run scope assertions skipped"
    echo "PASS (validation-only)"
    exit 0
fi

assert_scope() {
    local want="$1"; shift
    local out; out=$(bash "$script" --dry-run "$@" 2>&1)
    printf '%s' "$out" | grep -q "DRY: claude plugin marketplace add .* --scope $want" \
        || fail "marketplace add missing --scope $want (args: $*)"
    printf '%s' "$out" | grep -q "DRY: claude plugin install .* --scope $want" \
        || fail "plugin install missing --scope $want (args: $*)"
    echo "ok: scope '$want' threads through (args: ${*:-<default>})"

    # autoUpdate (HIMMEL-365): dry-run prints the patch intent for a flagged
    # marketplace (himmel) against the scope-correct settings file. $HOME/$PWD
    # are inherited by the child script, so they match what it computes.
    local sf
    case "$want" in
      user)    sf="$HOME/.claude/settings.json" ;;
      project) sf="$PWD/.claude/settings.json" ;;
      local)   sf="$PWD/.claude/settings.local.json" ;;
    esac
    printf '%s' "$out" | grep -qF "DRY: set autoUpdate=true for 'himmel' in $sf" \
        || fail "autoUpdate dry line missing/wrong file for scope $want (want $sf)"
    echo "ok: autoUpdate targets $sf for scope '$want'"
}

assert_scope user                      # default
assert_scope project --scope project
assert_scope local   --scope local

echo "PASS"
