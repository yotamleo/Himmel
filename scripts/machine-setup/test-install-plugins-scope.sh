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

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() {
    local _t="$1"; shift
    local _n=$#
    local _pat="${!_n}"
    grep -q "${@:1:$((_n-1))}" -- "$_pat" <<< "$_t"
}

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
grepq "$out" "invalid --scope: bogus" || fail "missing invalid-scope diagnostic"
echo "ok: invalid scope rejected (exit 2)"

# RED (HIMMEL-2699): a trailing value-taking flag with no value must reach
# the script's own usage diagnostic and exit 2, never an unbound-variable
# death from `set -u`.
for flag in --scope --template --himmel-path --settings; do
    set +e
    out=$(bash "$script" "$flag" 2>&1); rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "trailing $flag should exit 2, got $rc (out: $out)"
    grepq "$out" "$flag requires a value" || fail "trailing $flag missing usage diagnostic (out: $out)"
    grepq "$out" "unbound variable" && fail "trailing $flag leaked an unbound-variable death (out: $out)"
    echo "ok: trailing $flag exits 2 with its own diagnostic"
done

# Tests 1 + 2 need the claude + jq preflight to pass.
if ! command -v jq >/dev/null 2>&1 || ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude and/or jq not on PATH — dry-run scope assertions skipped"
    echo "PASS (validation-only)"
    exit 0
fi

assert_scope() {
    local want="$1"; shift
    local out; out=$(bash "$script" --dry-run "$@" 2>&1)
    grepq "$out" "DRY: claude plugin marketplace add .* --scope $want" \
        || fail "marketplace add missing --scope $want (args: $*)"
    grepq "$out" "DRY: claude plugin install .* --scope $want" \
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
    grepq "$out" -F "DRY: set autoUpdate=true for 'himmel' in $sf" \
        || fail "autoUpdate dry line missing/wrong file for scope $want (want $sf)"
    echo "ok: autoUpdate targets $sf for scope '$want'"
}

# A scratch HOME and cwd (HIMMEL-3541): install-plugins.sh leaves an autoUpdate
# entry the settings file already declares alone, so on a machine where himmel
# is installed the real ~/.claude/settings.json would hide the dry line.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/himmel-scope-test.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/proj"
export HOME="$scratch/home"
unset CLAUDE_CONFIG_DIR
cd "$scratch/proj"

assert_scope user                      # default
assert_scope project --scope project
assert_scope local   --scope local

echo "PASS"
