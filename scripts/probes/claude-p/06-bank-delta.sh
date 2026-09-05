#!/usr/bin/env bash
# Probe 6 (HIMMEL-2179): bank utilization snapshot around the probe batch.
# Usage: 06-bank-delta.sh before   (run FIRST, aborts the caller if SKIPPED-BANK)
#        06-bank-delta.sh after    (run LAST, also prints the delta)
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PHASE="${1:?usage: 06-bank-delta.sh before|after}"
REPO_ROOT="$(cd "$PROBE_DIR/../../.." && pwd)"
CACHE="${CLAUDE_USAGE_CACHE:-/tmp/claude/statusline-usage-cache.json}"

VERDICT="$(bash "$REPO_ROOT/scripts/lib/bank-preflight.sh" 2>"$OUT_DIR/06-$PHASE-preflight.err")"
PREFLIGHT_RC=$?
if [ "$PREFLIGHT_RC" -ne 0 ]; then
  echo "06: ERROR: bank-preflight.sh failed (rc=$PREFLIGHT_RC): $(cat "$OUT_DIR/06-$PHASE-preflight.err" 2>/dev/null)" >&2
  exit 1
fi
echo "06: $PHASE verdict=$VERDICT"

if [ ! -r "$CACHE" ]; then
  echo "06: ERROR: usage cache unreadable: $CACHE" >&2
  exit 1
fi
if ! jq -e '(.five_hour.utilization|type=="number") and (.seven_day.utilization|type=="number")' "$CACHE" >/dev/null 2>"$OUT_DIR/06-$PHASE-jq.err"; then
  echo "06: ERROR: usage cache malformed or missing numeric five_hour/seven_day utilization: $CACHE" >&2
  exit 1
fi

jq -c '{five_hour: .five_hour.utilization, seven_day: .seven_day.utilization, refreshed_at: .primaries_refreshed_at}' "$CACHE" > "$OUT_DIR/06-$PHASE.json"
echo "06: $PHASE snapshot:"
cat "$OUT_DIR/06-$PHASE.json"

if [ "$PHASE" = "before" ] && [ "$VERDICT" = "SKIPPED-BANK" ]; then
  echo "06: SKIPPED-BANK — caller must abort the rest of the batch" >&2
  exit 1
fi

if [ "$PHASE" = "after" ] && [ -f "$OUT_DIR/06-before.json" ]; then
  echo "06: delta (after - before):"
  jq -n --slurpfile b "$OUT_DIR/06-before.json" --slurpfile a "$OUT_DIR/06-after.json" \
    '{five_hour_delta: ($a[0].five_hour - $b[0].five_hour), seven_day_delta: ($a[0].seven_day - $b[0].seven_day)}' \
    2>/dev/null | tee "$OUT_DIR/06-delta.json"
fi
