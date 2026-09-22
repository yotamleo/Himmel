#!/usr/bin/env bash
# Tests for scripts/cr/impacted-suites.sh --runner / --runner-check
# (HIMMEL-3436): the CI-equivalent runner command for a JS/TS suite path, read
# off .github/workflows/ci.yml rather than guessed. Lives here rather than
# alongside scripts/cr/test-impacted-suites.sh because scripts/cr is off
# limits to this change beyond impacted-suites.sh itself (a concurrent leg is
# wiring an anchor hand-off into the other gate writers there) — impacted-suites.sh's
# own basename-matching still finds this suite (it references the changed
# file's basename).
#
# Usage: bash scripts/lib/test-impacted-suites-runner.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
IS="$REPO_ROOT/scripts/cr/impacted-suites.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

assert_runner() {
    local label="$1" path="$2" expect="$3" out rc
    out=$(bash "$IS" --runner "$path" 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$expect" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc out='$out' want='$expect')"
    fi
}

assert_runner "scripts/hooks .test.mjs -> node --test" \
    "scripts/hooks/run-hook-with-bash.test.mjs" \
    "node --test scripts/hooks/run-hook-with-bash.test.mjs"

assert_runner "scripts/lib .test.mjs -> node --test" \
    "scripts/lib/foo.test.mjs" \
    "node --test scripts/lib/foo.test.mjs"

assert_runner "scripts/lanes/tests .test.mjs -> node --test" \
    "scripts/lanes/tests/foo.test.mjs" \
    "node --test scripts/lanes/tests/foo.test.mjs"

assert_runner "scripts/lanes/tests nested .test.mjs -> node --test" \
    "scripts/lanes/tests/sub/foo.test.mjs" \
    "node --test scripts/lanes/tests/sub/foo.test.mjs"

assert_runner "scripts/trust/tests .test.mjs -> node --test" \
    "scripts/trust/tests/foo.test.mjs" \
    "node --test scripts/trust/tests/foo.test.mjs"

assert_runner "scripts/jira .test.ts -> vitest, cwd scripts/jira" \
    "scripts/jira/src/commands/foo.test.ts" \
    "cd scripts/jira && npx vitest run src/commands/foo.test.ts"

assert_runner "scripts/bitbucket .test.ts -> vitest, cwd scripts/bitbucket" \
    "scripts/bitbucket/src/foo.test.ts" \
    "cd scripts/bitbucket && npx vitest run src/foo.test.ts"

assert_runner "scripts/himmel-run .test.ts -> vitest, cwd scripts/himmel-run" \
    "scripts/himmel-run/tests/foo.test.ts" \
    "cd scripts/himmel-run && npx vitest run tests/foo.test.ts"

assert_runner "scripts/ci-orchestrator .test.ts -> vitest, cwd scripts/ci-orchestrator" \
    "scripts/ci-orchestrator/tests/foo.test.ts" \
    "cd scripts/ci-orchestrator && npx vitest run tests/foo.test.ts"

assert_runner "scripts/luna-vitals .test.mjs -> bun test, cwd scripts/luna-vitals" \
    "scripts/luna-vitals/tests/foo.test.mjs" \
    "cd scripts/luna-vitals && bun test tests/foo.test.mjs"

assert_runner "scripts/telegram .test.ts -> bun test --dots, repo root" \
    "scripts/telegram/foo.test.ts" \
    "bun test scripts/telegram/foo.test.ts --dots"

assert_runner "scripts/vault/tests .test.ts -> bun test --dots, repo root" \
    "scripts/vault/tests/foo.test.ts" \
    "bun test scripts/vault/tests/foo.test.ts --dots"

assert_runner "marketplace/plugins/luna-correlate .test.ts -> bun test, own cwd" \
    "marketplace/plugins/luna-correlate/tests/foo.test.ts" \
    "cd marketplace/plugins/luna-correlate && bun test tests/foo.test.ts"

# --- unmapped path: refuse, never guess -----------------------------------
out=$(bash "$IS" --runner scripts/fleet-control/tests/foo.test.mjs 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
    pass "unmapped path refuses (rc=$rc) with a message"
else
    fail "unmapped path should refuse non-zero with a message (rc=$rc out='$out')"
fi

# --- --runner requires a path ----------------------------------------------
out=$(bash "$IS" --runner 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ]; then
    pass "--runner with no path refuses"
else
    fail "--runner with no path should refuse (rc=$rc)"
fi

# --- drift check: every JS/TS test invocation ci.yml runs today has a mapping
if (cd "$REPO_ROOT" && bash "$IS" --runner-check >/dev/null 2>&1); then
    pass "--runner-check: current ci.yml is fully mapped"
else
    fail "--runner-check: ci.yml has a JS/TS test invocation --runner cannot map"
fi

echo ""
if [ "$failures" -eq 0 ]; then
    echo "PASS: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
