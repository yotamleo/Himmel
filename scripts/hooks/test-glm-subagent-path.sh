#!/usr/bin/env bash
# Red-path test for the glm-subagent agent (HIMMEL-726): prove the NEW in-session
# reach path (Agent tool -> glm-subagent -> spawn-glm chokepoint) CANNOT bypass
# the GLM fences. Structural assertions over the agent md, the spawn-glm guard
# chain, and the lane registry. The hook-level red path (the deny hook honoring
# GLM_SESSION_DIR/grants.jsonl on the GLM lane) already lives in
# test-block-glm-external-writes.sh - ASSERTed here as present + executable, NOT
# duplicated. The bypass checks are a structural DENYLIST of known signatures;
# a novel-signature bypass is inherently out of its reach - the deny hook is
# the behavioral backstop.
#
# Usage: bash scripts/hooks/test-glm-subagent-path.sh
# Exit codes: 0 - all assertions passed; 1 - at least one FAILED
# Bash 3.2-safe (no mapfile/assoc arrays), ASCII only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AGENT="marketplace/plugins/himmel-ops/agents/glm-subagent.md"
SPAWN_GLM="scripts/telegram/spawn-glm.ts"
DENY_HOOK="scripts/hooks/block-glm-external-writes.sh"
DENY_HOOK_TEST="scripts/hooks/test-block-glm-external-writes.sh"
LANES="scripts/lanes/lanes.json"

FAILED=0
CASES=0
EXPECTED_CASES=15

# assert <label> <0|1>   (0 = pass, 1 = fail)
assert() {
    local label="$1" rc="$2"
    CASES=$((CASES + 1))
    if [ "$rc" -eq 0 ]; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        FAILED=$((FAILED + 1))
    fi
}

# Self-heal exec bits the way the precedent (test-block-glm-external-writes.sh)
# does: a runtime chmod, git-invisible when core.fileMode is off. Asserted below.
[ -x "$REPO_ROOT/$DENY_HOOK_TEST" ] || chmod +x "$REPO_ROOT/$DENY_HOOK_TEST" 2>/dev/null || true

# --- (a) agent file exists + routes ONLY through spawn-glm (no bypass literals) ---
if [ -f "$REPO_ROOT/$AGENT" ]; then assert "(a) agent file exists ($AGENT)" 0; else assert "(a) agent file exists ($AGENT)" 1; fi
# The agent must NOT carry a bypass signature: a hand-rolled Z.ai endpoint, an
# ANTHROPIC_* endpoint var, or a bare `claude --model` reach for the GLM backend.
if grep -qE 'api\.z\.ai' "$REPO_ROOT/$AGENT"; then assert "(a) no api.z.ai literal in agent" 1; else assert "(a) no api.z.ai literal in agent" 0; fi
if grep -qF 'ANTHROPIC_BASE_URL' "$REPO_ROOT/$AGENT"; then assert "(a) no ANTHROPIC_BASE_URL in agent" 1; else assert "(a) no ANTHROPIC_BASE_URL in agent" 0; fi
if grep -qF 'claude --model' "$REPO_ROOT/$AGENT"; then assert "(a) no bare 'claude --model' in agent" 1; else assert "(a) no bare 'claude --model' in agent" 0; fi
# scripts/claude-glm is a DIRECT GLM-backend launcher (no worktree isolation,
# no cap-guard, no grants seam) - the strongest realistic bypass; must be absent.
if grep -qF 'claude-glm' "$REPO_ROOT/$AGENT"; then assert "(a) no direct claude-glm launcher in agent" 1; else assert "(a) no direct claude-glm launcher in agent" 0; fi
# ... and it MUST point at the chokepoint.
if grep -qF 'scripts/telegram/spawn-glm.ts' "$REPO_ROOT/$AGENT"; then assert "(a) agent routes through spawn-glm.ts" 0; else assert "(a) agent routes through spawn-glm.ts" 1; fi
# The tool grant IS the isolation contract: a widened grant (Write/Edit) would
# let the dispatcher touch the parent repo directly. Pin frontmatter exactly.
if grep -qxF 'tools: Bash' "$REPO_ROOT/$AGENT"; then assert "(a) agent tool grant is exactly 'tools: Bash'" 0; else assert "(a) agent tool grant is exactly 'tools: Bash'" 1; fi
# The Agent-tool dispatch + lanes label key off the name; pin it.
if grep -qxF 'name: glm-subagent' "$REPO_ROOT/$AGENT"; then assert "(a) agent name frontmatter is glm-subagent" 0; else assert "(a) agent name frontmatter is glm-subagent" 1; fi

# --- (b) spawn-glm guard chain intact on this path ---
# checkGlmGuards is CALLED before executeRun is CALLED. Pull the call-site line
# numbers via parameter expansion (no head|cut pipe under pipefail -> no SIGPIPE
# on the grep-early-exit path).
# Match the assignment call-site shape ('= checkGlmGuards(') rather than a
# specific argument: HIMMEL-800's runSharedDispatch refactor renamed the arg
# (plan.worktree -> worktree) and the old 'checkGlmGuards(plan' pin broke on
# public CI while the guard-before-run invariant itself still held.
guard_match=$(grep -m1 -n '= checkGlmGuards(' "$REPO_ROOT/$SPAWN_GLM" 2>/dev/null || true)
run_match=$(grep -m1 -n 'await executeRun(' "$REPO_ROOT/$SPAWN_GLM" 2>/dev/null || true)
guard_line=${guard_match%%:*}
run_line=${run_match%%:*}
if [ -n "$guard_line" ] && [ -n "$run_line" ] && [ "$guard_line" -lt "$run_line" ]; then
    assert "(b) checkGlmGuards (line $guard_line) called before executeRun (line $run_line)" 0
else
    assert "(b) checkGlmGuards called before executeRun" 1
fi
# GLM_SESSION_DIR env seam: SET in spawn-glm.ts (propagates into the worker
# child), READ by the deny hook to consult grants.jsonl. NOTE: the HIMMEL-726
# spec named glm-env.ts for this plumbing; glm-env.ts builds the ANTHROPIC_* env
# block and does NOT touch GLM_SESSION_DIR. The seam actually lives in
# spawn-glm.ts (set) feeding block-glm-external-writes.sh (read) - this asserts
# the TRUE chain, not the literal (incorrect) file pointer.
if grep -qF 'process.env.GLM_SESSION_DIR' "$REPO_ROOT/$SPAWN_GLM"; then assert "(b) spawn-glm sets GLM_SESSION_DIR env seam" 0; else assert "(b) spawn-glm sets GLM_SESSION_DIR env seam" 1; fi
# shellcheck disable=SC2016  # literal ${GLM_SESSION_DIR is the text under test, not for expansion
if grep -qF '${GLM_SESSION_DIR' "$REPO_ROOT/$DENY_HOOK"; then assert "(b) deny hook reads GLM_SESSION_DIR" 0; else assert "(b) deny hook reads GLM_SESSION_DIR" 1; fi
# The hook-level red-path proof lives in test-block-glm-external-writes.sh.
if [ -f "$REPO_ROOT/$DENY_HOOK_TEST" ]; then assert "(b) deny-hook red-path test exists" 0; else assert "(b) deny-hook red-path test exists" 1; fi
if [ -x "$REPO_ROOT/$DENY_HOOK_TEST" ]; then assert "(b) deny-hook red-path test is executable" 0; else assert "(b) deny-hook red-path test is executable" 1; fi

# --- (c) lane registry carries the glm-subagent row, ZAI_API_KEY-gated ---
# Tie id + probe to the SAME row via a -A4 window, matched with `case` (no pipe
# under pipefail). Bash 3.2-safe: no assoc arrays.
glm_window=$(grep -A4 '"id": "glm-subagent"' "$REPO_ROOT/$LANES" 2>/dev/null || true)
if [ -n "$glm_window" ]; then assert "(c) lanes.json has glm-subagent row" 0; else assert "(c) lanes.json has glm-subagent row" 1; fi
case "$glm_window" in
    *'"name": "ZAI_API_KEY"'*) assert "(c) glm-subagent probe is ZAI_API_KEY" 0 ;;
    *) assert "(c) glm-subagent probe is ZAI_API_KEY" 1 ;;
esac

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED assertion(s) FAILED"
    exit 1
fi
# Count guard: a drift here means an assert was silently dropped (or an early
# exit skipped the tail) even though nothing FAILED. Bump EXPECTED_CASES when
# adding/removing an assertion.
if [ "$CASES" -ne "$EXPECTED_CASES" ]; then
    echo "CASE-COUNT MISMATCH - ran $CASES, expected $EXPECTED_CASES"
    exit 1
fi
echo "all assertions passed ($CASES/$EXPECTED_CASES)"
exit 0
