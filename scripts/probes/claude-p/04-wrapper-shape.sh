#!/usr/bin/env bash
# Probe 4 (HIMMEL-2179): combined wrapper shape — stdin prompt,
# --append-system-prompt-file, --output-format json --json-schema. Verify by
# ARTIFACT: does the envelope carry a schema-conformant `structured_output`.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SYSFILE="$OUT_DIR/04-system-prompt.txt"
printf 'Always answer in exactly the JSON the schema demands. No prose outside the JSON.\n' > "$SYSFILE"
SCHEMA='{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}'

# headless-claude-ok: HIMMEL-2179 probe
printf 'Say hello in one word.\n' | timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 \
  --permission-mode dontAsk --append-system-prompt-file "$SYSFILE" \
  --output-format json --json-schema "$SCHEMA" \
  > "$OUT_DIR/04.json" 2>"$OUT_DIR/04.err"
echo "04 rc=$?"
echo "04: structured_output field:"
jq -c '{structured_output, result, is_error}' "$OUT_DIR/04.json" 2>/dev/null

# --max-turns 1 is documented (RESULTS.md) to exhaust turns for this
# schema+system-prompt combo; retry once with --max-turns 2 so this script
# reproduces the actual recorded PASS artifact (tmp/04-retry.json), not just
# the known-failing first attempt.
TERMINAL_REASON="$(jq -r '.terminal_reason // ""' "$OUT_DIR/04.json" 2>/dev/null)"
if [ "$TERMINAL_REASON" = "max_turns" ]; then
  echo "04: max_turns exhausted at --max-turns 1 — retrying with --max-turns 2"
  # headless-claude-ok: HIMMEL-2179 probe
  printf 'Say hello in one word.\n' | timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
    --permission-mode dontAsk --append-system-prompt-file "$SYSFILE" \
    --output-format json --json-schema "$SCHEMA" \
    > "$OUT_DIR/04-retry.json" 2>"$OUT_DIR/04-retry.err"
  echo "04-retry rc=$?"
  echo "04: structured_output field (retry):"
  jq -c '{structured_output, result, is_error}' "$OUT_DIR/04-retry.json" 2>/dev/null
fi
