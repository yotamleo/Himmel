#!/usr/bin/env bash
# Zero-violation oxlint bug-class hardening gate (HIMMEL-2163).
#
# Runs oxlint with a fixed set of bug-class rules (correctness rules that are
# OFF by default in oxlint's own default config, across the oxc/eslint/promise
# plugins, plus unicorn/prefer-node-protocol) over the same surface audited
# for HIMMEL-2154: scripts/lanes scripts/jira/src scripts/telegram
# scripts/luna-vitals scripts/himmel-run, plus the *.mjs/*.js files directly
# under scripts/hooks and scripts/observability. dist/, node_modules/ and
# test fixtures are excluded — they are generated or deliberately-shaped
# inputs, not code this gate is meant to hold a line on.
#
# Unlike the complexity ratchet next to this file, this is a ZERO-tolerance
# gate: HIMMEL-2163's audit found only one-line fixes for every real hit in
# this rule set (already fixed/annotated on the branch that added this gate),
# so any NEW hit is a regression, full stop — there is no ceiling to lower.
# Adding a rule here is an operator call (it needs an audit pass first to
# confirm it is bug-class and near-zero-violation); this script does not
# self-select rules.
#
# Fails OPEN (exit 0, loud WARN) when bunx/oxlint is unavailable or errors
# out for a reason unrelated to a lint finding (e.g. no bun installed, no
# network to fetch oxlint) — a lint gate must not brick commits on a box
# that doesn't have bun.
set -uo pipefail

# ---- rule set (HIMMEL-2163 audit) --------------------------------------
# oxc/bad-bitwise-operator and eslint/no-throw-literal each had exactly one
# hit in-scope, both VERIFIED FALSE POSITIVES (annotated with an
# oxlint-disable, not "fixed") — see scripts/hooks/guardrail-block.mjs:880
# and scripts/jira/src/mcp.test.ts:87. eslint/array-callback-return had one
# genuine one-liner, fixed. Every other rule below was already at zero
# violations in-scope.
RULES="unicorn/prefer-node-protocol oxc/bad-bitwise-operator no-self-compare no-constructor-return no-unreachable-loop no-unmodified-loop-condition no-fallthrough no-inner-declarations no-prototype-builtins no-new-wrappers no-proto accessor-pairs no-return-assign oxc/misrefactored-assign-op oxc/no-this-in-exported-function promise/no-multiple-resolved promise/no-promise-in-callback promise/no-return-wrap unicorn/no-instanceof-builtins unicorn/no-object-as-default-parameter unicorn/no-new-buffer no-throw-literal array-callback-return"
# -------------------------------------------------------------------------

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root" || exit 1

if ! command -v bunx >/dev/null 2>&1; then
    echo "WARN check-oxlint-hardening: bunx not found on PATH — skipping hardening gate (fail-open)" >&2
    exit 0
fi

targets="scripts/lanes scripts/jira/src scripts/telegram scripts/luna-vitals scripts/himmel-run"

hook_js=""
for f in scripts/hooks/*.mjs scripts/hooks/*.js scripts/observability/*.mjs scripts/observability/*.js; do
    [ -e "$f" ] && hook_js="$hook_js $f"
done

warn_flags=""
for r in $RULES; do
    warn_flags="$warn_flags -W $r"
done

# shellcheck disable=SC2086 # word-split on purpose: rule flags + directory/file list
out=$(bunx oxlint -A all $warn_flags --promise-plugin \
    --disable-nested-config \
    --ignore-pattern 'dist/**' \
    --ignore-pattern 'node_modules/**' \
    --ignore-pattern '**/fixtures/**' \
    --ignore-pattern '**/__fixtures__/**' \
    $targets $hook_js 2>&1)
rc=$?

# oxlint exits 0 even when warnings were found (only --deny-warnings or an
# actual error changes that) — so exit code alone can't distinguish "clean"
# from "violations found". Match check-oxlint-complexity.sh's approach:
# grep the output for an actual lint-finding line, not a tooling message
# ("No files found to lint", a crash, etc).
lint_lines=$(printf '%s' "$out" | grep -E 'warning (eslint|oxc|promise|unicorn)\(' || true)

if [ $rc -ne 0 ] && [ -z "$lint_lines" ]; then
    # oxlint didn't produce lint findings at all (crashed, couldn't fetch the
    # package, "No files found to lint", etc) — a tooling failure, not a
    # rule violation. Fail open rather than block every commit.
    echo "WARN check-oxlint-hardening: oxlint did not run cleanly — skipping (fail-open)" >&2
    echo "$out" >&2
    exit 0
fi

if [ -n "$lint_lines" ]; then
    echo "check-oxlint-hardening: bug-class rule violation(s) in the zero-tolerance set:" >&2
    printf '%s\n' "$lint_lines" >&2
    echo "" >&2
    echo "Fix the violation(s) above (they're one-liners by construction — this set was audited for that). If a hit is a genuine false positive, annotate it with a targeted oxlint-disable comment naming the reason, don't change behavior to satisfy the linter." >&2
    exit 1
fi

exit 0
