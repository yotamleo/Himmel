#!/usr/bin/env bash
# Smoke test for scripts/cr/d1-verdict.sh (HIMMEL-654 WS7, spec D1.4).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/d1-verdict.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: got '$1' want '$2'"; fail=1; }; }

# PASS path: meta gets d1_verdict + stdout snippet emitted
printf '%s\n' '{"status":"done","lane":"glm","task_name":"spike-a"}' > "$tmp/meta.json"
out="$(bash "$SCRIPT" --session-dir "$tmp" --verdict pass)"
check "$out" "d1_verdict: pass (R1-R4)"
got="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).d1_verdict)' "$tmp/meta.json")"
check "$got" "pass (R1-R4)"
# existing fields preserved
keep="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).task_name)' "$tmp/meta.json")"
check "$keep" "spike-a"

# FAIL verdict persists too (symmetric with D6)
bash "$SCRIPT" --session-dir "$tmp" --verdict fail --rubric "R1" >/dev/null
got="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).d1_verdict)' "$tmp/meta.json")"
check "$got" "fail (R1)"

# --lane writes the DISTINCT d1_lane key and never clobbers spawn-glm's lane field
bash "$SCRIPT" --session-dir "$tmp" --verdict pass --lane cheap-glm >/dev/null
got="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).d1_lane)' "$tmp/meta.json")"
check "$got" "cheap-glm"
keep2="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).lane)' "$tmp/meta.json")"
check "$keep2" "glm"
# cheap-codex is DROPPED until the Codex session substrate exists → refuse
if bash "$SCRIPT" --session-dir "$tmp" --verdict pass --lane cheap-codex >/dev/null 2>&1; then echo "FAIL: cheap-codex lane must be rejected"; fail=1; fi

# fail-closed: missing meta.json → exit 2, nothing written
empty="$(mktemp -d)"
if bash "$SCRIPT" --session-dir "$empty" --verdict pass >/dev/null 2>&1; then echo "FAIL: missing meta should exit 2"; fail=1; fi
# fail-closed: invalid verdict → exit 2
if bash "$SCRIPT" --session-dir "$tmp" --verdict maybe >/dev/null 2>&1; then echo "FAIL: bad verdict should exit 2"; fail=1; fi
rm -rf "$empty"
[ "$fail" -eq 0 ] && echo "PASS test-d1-verdict" || exit 1
