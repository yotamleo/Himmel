#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; export ARMED_SESSIONS_FILE="$TMP/a.jsonl"; export CLAUDE_PROJECTS_DIR="$TMP/projects"
PROJ="$TMP/projects/C--repo"; mkdir -p "$PROJ"
cat > "$PROJ/s.jsonl" <<'JSONL'
{"type":"user","timestamp":"2026-05-30T00:57:00Z","message":{"role":"user","content":"load /h/x.md overnight mode"}}
{"type":"assistant","timestamp":"2026-05-30T01:06:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Ship it?","header":"Q"}]}}]}}
{"type":"user","timestamp":"2026-05-30T01:07:00Z","message":{"role":"user","content":[{"type":"tool_result","content":"Your questions have been answered: \"Ship it?\"=\"Yes\"."}]}}
JSONL
bun "$REPO/scripts/telegram/armed-session-track.ts" record --task t --ticket HIMMEL-216 \
  --handover /h/x.md --cwd C:/repo --armed-at 2026-05-30T00:57:00Z --mode ticket
out=$(bash "$HERE/resume-armed.sh")
case "$out" in
  *"HIMMEL-216"*"Ship it?"*"Yes"*) echo "ok: summary surfaces ticket + stop-point" ;;
  *) echo "FAIL: missing fields: $out"; exit 1 ;;
esac
