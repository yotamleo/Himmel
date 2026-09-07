#!/usr/bin/env bash
# Probe 1 (HIMMEL-2179): does resuming a session in -p mode and sending
# "/compact" actually compact? Verify by ARTIFACT: find the session JSONL and look for a
# `system` message with subtype "compact_boundary" (compact_metadata.pre_tokens,
# compact_metadata.trigger) — the documented telemetry shape
# (code.claude.com/docs/en/agent-sdk/slash-commands.md). A success result like
# "Not enough messages to compact." with NO compact_boundary message is a
# valid measured negative (insufficient history), not a probe failure — in
# that case we add one more exchange and retry /compact once.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SID="$(node -e "console.log(require('crypto').randomUUID())")"
echo "01: session_id=$SID"

find_jsonl() { find "$HOME/.claude/projects" -name "${SID}.jsonl" 2>/dev/null | head -1; }

# headless-claude-ok: HIMMEL-2179 probe
timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --session-id "$SID" \
  --permission-mode dontAsk --output-format json "Say A" > "$OUT_DIR/01-a.json" 2>"$OUT_DIR/01-a.err"
echo "01a rc=$?"

# headless-claude-ok: HIMMEL-2179 probe
timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --resume "$SID" \
  --permission-mode dontAsk --output-format json "Say B" > "$OUT_DIR/01-b.json" 2>"$OUT_DIR/01-b.err"
echo "01b rc=$?"

# headless-claude-ok: HIMMEL-2179 probe
MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --resume "$SID" \
  --permission-mode dontAsk --output-format json "/compact" > "$OUT_DIR/01-c.json" 2>"$OUT_DIR/01-c.err"
echo "01c rc=$?"

JSONL="$(find_jsonl)"
echo "01: jsonl=${JSONL:-NOT-FOUND}"
BOUNDARY_COUNT=0
if [ -n "$JSONL" ]; then
  cp "$JSONL" "$OUT_DIR/01-session-after-c.jsonl"
  BOUNDARY_COUNT="$(grep -c 'compact_boundary' "$JSONL" 2>/dev/null)"
  BOUNDARY_COUNT="${BOUNDARY_COUNT:-0}"
fi
RESULT_C="$(jq -r '.result // ""' "$OUT_DIR/01-c.json" 2>/dev/null)"
echo "01: compact_boundary_count=$BOUNDARY_COUNT result_c=\"$RESULT_C\""

# Retry once: only if no boundary AND the result reads as an insufficient-
# history negative (not some other kind of failure).
if [ "$BOUNDARY_COUNT" = "0" ] && printf '%s' "$RESULT_C" | grep -qiE 'not enough|insufficient'; then
  echo "01: retrying — one more exchange then /compact again"
  # headless-claude-ok: HIMMEL-2179 probe
  timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --resume "$SID" \
    --permission-mode dontAsk --output-format json "Say C" > "$OUT_DIR/01-d.json" 2>"$OUT_DIR/01-d.err"
  echo "01d rc=$?"
  # headless-claude-ok: HIMMEL-2179 probe
  MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --resume "$SID" \
    --permission-mode dontAsk --output-format json "/compact" > "$OUT_DIR/01-e.json" 2>"$OUT_DIR/01-e.err"
  echo "01e rc=$?"
  JSONL="$(find_jsonl)"
  RETRY_BOUNDARY_COUNT=0
  if [ -n "$JSONL" ]; then
    cp "$JSONL" "$OUT_DIR/01-session-after-e.jsonl"
    RETRY_BOUNDARY_COUNT="$(grep -c 'compact_boundary' "$JSONL" 2>/dev/null)"
    RETRY_BOUNDARY_COUNT="${RETRY_BOUNDARY_COUNT:-0}"
  fi
  echo "01: retry compact_boundary_count=$RETRY_BOUNDARY_COUNT result_e=\"$(jq -r '.result // ""' "$OUT_DIR/01-e.json" 2>/dev/null)\""
fi
