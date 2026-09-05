#!/usr/bin/env bash
# Probe 7 (HIMMEL-2179, RETASK RTK-2179-8f3a1c): run the SAME write-a-file
# brief twice under --permission-mode dontAsk with an allowlist phrased only
# for Bash shapes ("Bash(echo *),Write"), and record per-run which tool the
# model actually reached for (Bash vs PowerShell vs Write) — measured
# evidence of run-to-run shell nondeterminism and whether a single-shape
# allowlist bleeds silent no-ops. Verify by ARTIFACT (file presence + which
# tool_use entries appear in the stream), never rc.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ALLOWLIST="Bash(echo *),Write"
PROMPT_PREFIX="Create a file named probe7-output.txt in the current directory containing the word OK."

run_once() {
  local n="$1"
  local workdir="$OUT_DIR/07-run$n"
  rm -rf "$workdir"
  mkdir -p "$workdir"
  (
    cd "$workdir" || exit 1
    # headless-claude-ok: HIMMEL-2179 probe
    timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
      --permission-mode dontAsk --allowedTools "$ALLOWLIST" \
      --output-format stream-json --verbose "$PROMPT_PREFIX" \
      > "$OUT_DIR/07-run$n.jsonl" 2>"$OUT_DIR/07-run$n.err"
    echo "07 run$n rc=$?"
  )
  echo "07 run$n: tool_use names reached for:"
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' \
    "$OUT_DIR/07-run$n.jsonl" 2>/dev/null | sort | uniq -c
  echo "07 run$n: permission_denials (final result line):"
  tail -1 "$OUT_DIR/07-run$n.jsonl" 2>/dev/null | jq -c '.permission_denials // []' 2>/dev/null
  if [ -f "$workdir/probe7-output.txt" ]; then
    echo "07 run$n: artifact PRESENT — $(cat "$workdir/probe7-output.txt")"
  else
    echo "07 run$n: artifact ABSENT"
  fi
}

run_once 1
run_once 2
