#!/usr/bin/env bash
# Advisory-then-ratchet cyclomatic-complexity gate (HIMMEL-2154).
#
# Runs `bunx oxlint -A all -W complexity` (oxlint's eslint(complexity) rule)
# over the surface audited for HIMMEL-2154: scripts/lanes scripts/jira/src
# scripts/telegram scripts/luna-vitals scripts/himmel-run, plus the *.mjs/*.js
# files directly under scripts/hooks and scripts/observability. dist/,
# node_modules/ and test fixtures are excluded — they are generated or
# deliberately-shaped inputs, not code this gate is meant to hold a line on.
#
# Ratchet rule: OXLINT_COMPLEXITY_MAX below starts at 81 — the audited
# MAXIMUM function complexity across that surface as of HIMMEL-2154, so
# everything that exists today passes. This only fires on a NEW function
# regressing ABOVE that ceiling; it does not ask anyone to fix what's
# already there. As HIMMEL-2154 simplification work lands and lowers real
# complexity, LOWER this number to match the new maximum — never raise it.
# Raising it papers over a regression instead of fixing it; if a change
# genuinely needs a higher ceiling, that is an operator call, not a
# self-service edit.
#
# Fails OPEN (exit 0, loud WARN) when bunx/oxlint is unavailable or errors
# out for a reason unrelated to a lint finding (e.g. no bun installed, no
# network to fetch oxlint) — a lint gate must not brick commits on a box
# that doesn't have bun.
set -uo pipefail

# ---- config -----------------------------------------------------------
OXLINT_COMPLEXITY_MAX="${OXLINT_COMPLEXITY_MAX:-81}"
# -------------------------------------------------------------------------

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root" || exit 1

if ! command -v bunx >/dev/null 2>&1; then
    echo "WARN check-oxlint-complexity: bunx not found on PATH — skipping complexity gate (fail-open)" >&2
    exit 0
fi

targets="scripts/lanes scripts/jira/src scripts/telegram scripts/luna-vitals scripts/himmel-run"

hook_js=""
for f in scripts/hooks/*.mjs scripts/hooks/*.js scripts/observability/*.mjs scripts/observability/*.js; do
    [ -e "$f" ] && hook_js="$hook_js $f"
done

# shellcheck disable=SC2086 # word-split on purpose: directory/file list
out=$(bunx oxlint -A all -W complexity \
    --ignore-pattern 'dist/**' \
    --ignore-pattern 'node_modules/**' \
    --ignore-pattern '**/fixtures/**' \
    --ignore-pattern '**/__fixtures__/**' \
    $targets $hook_js 2>&1)
rc=$?

lint_lines=$(printf '%s' "$out" | grep -E 'complexity of' || true)
if [ $rc -ne 0 ] && [ -z "$lint_lines" ]; then
    # oxlint didn't produce lint findings at all (crashed, couldn't fetch the
    # package, "No files found to lint", etc) — a tooling failure, not a
    # complexity regression. Fail open rather than block every commit.
    echo "WARN check-oxlint-complexity: oxlint did not run cleanly — skipping (fail-open)" >&2
    echo "$out" >&2
    exit 0
fi

regressions=$(printf '%s\n' "$out" | grep -E 'has a complexity of [0-9]+' | while IFS= read -r line; do
    n=$(printf '%s' "$line" | grep -oE 'complexity of [0-9]+' | grep -oE '[0-9]+')
    if [ -n "$n" ] && [ "$n" -gt "$OXLINT_COMPLEXITY_MAX" ]; then
        printf '%s\n' "$line"
    fi
done)

if [ -n "$regressions" ]; then
    echo "check-oxlint-complexity: function(s) exceed the configured complexity ratchet (max $OXLINT_COMPLEXITY_MAX):" >&2
    printf '%s\n' "$regressions" >&2
    echo "" >&2
    echo "Simplify the function(s) above. If OXLINT_COMPLEXITY_MAX genuinely needs to rise, that's an operator call — lower it as cleanups land, never raise it unilaterally." >&2
    exit 1
fi

exit 0
