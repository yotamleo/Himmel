#!/usr/bin/env bash
# Probe 1b (HIMMEL-2179, RETASK RTK-2179-8f3a1c): the SDK docs show /compact
# dispatched with --continue (same cwd, no session id), not --resume. Does
# --continue expand slash commands where --resume (probe 1) did not? Verify
# by ARTIFACT: session JSONL compact_boundary count, same as probe 1.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# headless-claude-ok: HIMMEL-2179 probe
timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 \
  --permission-mode dontAsk --output-format json "Say A" \
  > "$OUT_DIR/01b-a.json" 2>"$OUT_DIR/01b-a.err"
echo "01b-a rc=$?"
SID="$(jq -r '.session_id // ""' "$OUT_DIR/01b-a.json" 2>/dev/null)"
echo "01b: session_id=$SID"
if [ -z "$SID" ]; then
  echo "01b: ERROR — initial call produced no session_id; aborting rather than letting --continue pick up an unrelated latest session in this cwd" >&2
  exit 1
fi

# check_continued_sid: verify --continue actually resumed OUR session, not
# some other newer session in the same cwd (--continue picks the most
# recently active session by cwd, which a concurrent claude run could hijack).
check_continued_sid() {
  local label="$1" envelope="$2" continued_sid
  continued_sid="$(jq -r '.session_id // ""' "$envelope" 2>/dev/null)"
  if [ -z "$continued_sid" ]; then
    echo "01b: ERROR — $label's --continue response carried no session_id (failed/malformed response); cannot confirm it continued our SID=$SID, result is unreliable" >&2
    return 1
  fi
  if [ "$continued_sid" != "$SID" ]; then
    echo "01b: ERROR — $label's --continue resumed session_id=$continued_sid, not our SID=$SID (a concurrent session in this cwd likely hijacked --continue); result is unreliable" >&2
    return 1
  fi
  return 0
}

# headless-claude-ok: HIMMEL-2179 probe
timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --continue \
  --permission-mode dontAsk --output-format json "Say B" \
  > "$OUT_DIR/01b-b.json" 2>"$OUT_DIR/01b-b.err"
echo "01b-b rc=$?"
if ! check_continued_sid "Say B" "$OUT_DIR/01b-b.json"; then
  echo "01b: aborting before /compact — no point compacting a hijacked session" >&2
  exit 1
fi

# headless-claude-ok: HIMMEL-2179 probe
MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 1 --continue \
  --permission-mode dontAsk --output-format json "/compact" \
  > "$OUT_DIR/01b-c.json" 2>"$OUT_DIR/01b-c.err"
echo "01b-c rc=$?"
if ! check_continued_sid "/compact" "$OUT_DIR/01b-c.json"; then
  echo "01b: aborting before computing the summary — the /compact call targeted an unverified session, so a boundary-count/result line would misreport it as reliable" >&2
  exit 1
fi

JSONL=""
[ -n "$SID" ] && JSONL="$(find "$HOME/.claude/projects" -name "${SID}.jsonl" 2>/dev/null | head -1)"
echo "01b: jsonl=${JSONL:-NOT-FOUND}"
BOUNDARY_COUNT=0
if [ -n "$JSONL" ]; then
  cp "$JSONL" "$OUT_DIR/01b-session-after-c.jsonl"
  BOUNDARY_COUNT="$(grep -c 'compact_boundary' "$JSONL" 2>/dev/null)"
  BOUNDARY_COUNT="${BOUNDARY_COUNT:-0}"
fi
RESULT_C="$(jq -r '.result // ""' "$OUT_DIR/01b-c.json" 2>/dev/null)"
echo "01b: compact_boundary_count=$BOUNDARY_COUNT result_c=\"$RESULT_C\""
