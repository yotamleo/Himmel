#!/usr/bin/env bash
# Probe 2 (HIMMEL-2179): --permission-mode dontAsk + --allowedTools.
# Run A: allowlist covers Write -> verify artifact file exists.
# Run B: allowlist does NOT cover Write -> verify artifact absent AND
# permission_denials populated in the JSON envelope. Verify by ARTIFACT
# (file presence/absence), never by rc.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TARGET_A="$PROBE_DIR/tmp-artifact.txt"
TARGET_B="$PROBE_DIR/tmp-artifact-noaccess.txt"
rm -f "$TARGET_A" "$TARGET_B"

# headless-claude-ok: HIMMEL-2179 probe
timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
  --permission-mode dontAsk --allowedTools "Bash(echo *),Write" \
  --output-format json "Write the single word OK to $TARGET_A" \
  > "$OUT_DIR/02-a.json" 2>"$OUT_DIR/02-a.err"
echo "02a rc=$?"
if [ -f "$TARGET_A" ]; then
  echo "02a: artifact PRESENT — $(cat "$TARGET_A")"
else
  echo "02a: artifact ABSENT"
fi

# headless-claude-ok: HIMMEL-2179 probe
timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
  --permission-mode dontAsk --allowedTools "Bash(echo *)" \
  --output-format json "Write the single word OK to $TARGET_B" \
  > "$OUT_DIR/02-b.json" 2>"$OUT_DIR/02-b.err"
echo "02b rc=$?"
if [ -f "$TARGET_B" ]; then
  echo "02b: artifact PRESENT (unexpected) — $(cat "$TARGET_B")"
else
  echo "02b: artifact ABSENT (expected)"
fi
DENIALS="$(jq -c '.permission_denials // []' "$OUT_DIR/02-b.json" 2>/dev/null)"
echo "02b: permission_denials=$DENIALS"
