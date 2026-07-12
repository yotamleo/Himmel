#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-cheap-lane-pr-without-verdict.sh
# (HIMMEL-654 WS7, spec D1.4 deferred-structural). Drives the hook with
# synthesized PreToolUse JSON on stdin + a temp BRIDGE_ROOT. The suite is the
# spec: cheap-glm w/o verdict blocks; verdict present allows; codex/claude pass;
# own-bugs fail-open.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/block-cheap-lane-pr-without-verdict.sh"
root="$(mktemp -d)"; export BRIDGE_ROOT="$root"; trap 'rm -rf "$root"' EXIT
sess="$root/glm-sessions/glm-spike-1"; mkdir -p "$sess"
fail=0
pj() { printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --head %s"}}' "$1"; }

# cheap-glm branch, meta WITHOUT d1_verdict → BLOCK (exit 2)
printf '{"lane":"glm","task_name":"spike","started_at":"2026-07-03T01:00:00Z","d1_verdict":null}' > "$sess/meta.json"
if pj "glm/spike" | bash "$HOOK"; then echo "FAIL: no-verdict cheap lane should block"; fail=1; fi

# cheap-glm branch, meta WITH d1_verdict → ALLOW (exit 0)
printf '{"lane":"glm","task_name":"spike","started_at":"2026-07-03T01:00:00Z","d1_verdict":"pass (R1-R4)"}' > "$sess/meta.json"
pj "glm/spike" | bash "$HOOK" || { echo "FAIL: verdict present should allow"; fail=1; }

# repeated slug (timestamped dirs): ANY matching session lacking a verdict → BLOCK
sess2="$root/glm-sessions/glm-spike-2"; mkdir -p "$sess2"
printf '{"lane":"glm","task_name":"spike","started_at":"2026-07-03T02:00:00Z"}' > "$sess2/meta.json"
if pj "glm/spike" | bash "$HOOK"; then echo "FAIL: any matching session w/o verdict should block"; fail=1; fi
rm -rf "$sess2"

# codex/* branch → ALLOW, never a spurious block (no session substrate exists;
# cheap-codex structural enforcement waits on the FUTURE hermes task→branch
# record — spec D1.1/SC2)
pj "codex/hermes-task" | bash "$HOOK" || { echo "FAIL: codex/* must not spuriously block"; fail=1; }

# claude-lane branch → ALLOW regardless (this hook only gates cheap-glm)
pj "feat/x" | bash "$HOOK" || { echo "FAIL: claude lane should pass"; fail=1; }

# fail-open on malformed JSON (own-bug) → ALLOW
if ! printf 'not json' | bash "$HOOK"; then echo "FAIL: malformed JSON must fail-open"; fail=1; fi
[ "$fail" -eq 0 ] && echo "PASS test-block-cheap-lane-pr-without-verdict" || exit 1
