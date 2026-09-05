#!/usr/bin/env bash
# Probe 5 (HIMMEL-2179): start a session in the worktree, then --resume it
# from a different cwd ($TEMP). CLI is 2.1.250; docs claim cross-directory
# resume since 2.1.223. Verify by ARTIFACT: does the resumed call actually
# produce a result (and does the JSONL show both turns), not just rc.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SID="$(node -e "console.log(require('crypto').randomUUID())")"
echo "05: session_id=$SID"

# headless-claude-ok: HIMMEL-2179 probe
timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --session-id "$SID" \
  --permission-mode dontAsk --output-format json "Say A" \
  > "$OUT_DIR/05-a.json" 2>"$OUT_DIR/05-a.err"
echo "05a rc=$? (started in $PROBE_DIR)"

ALT_DIR="${TEMP:-/tmp}"
(
  cd "$ALT_DIR" || exit 1
  echo "05: resuming from cwd=$(pwd)"
  # headless-claude-ok: HIMMEL-2179 probe
  timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --resume "$SID" \
    --permission-mode dontAsk --output-format json "Say B" \
    > "$OUT_DIR/05-b.json" 2>"$OUT_DIR/05-b.err"
  echo "05b rc=$?"
)

echo "05b: envelope:"
jq -c '{is_error, result, num_turns, session_id}' "$OUT_DIR/05-b.json" 2>/dev/null
echo "05b: stderr:"
cat "$OUT_DIR/05-b.err" 2>/dev/null
