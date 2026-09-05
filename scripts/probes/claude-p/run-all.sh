#!/usr/bin/env bash
# Runs the whole HIMMEL-2179 P0 probe batch in order. Bank snapshot first
# (aborts everything on SKIPPED-BANK), then probes 1/1b/2/3/3b/3c/3d/4/5/7,
# then a second bank snapshot + delta. Logs everything to tmp/run-all.log; each
# probe's own artifacts land in tmp/ under its own prefix. This script does
# not itself invoke claude in -p mode — no headless-claude-ok marker needed.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/run-all.log"
: > "$LOG"

echo "=== bank snapshot: before ===" | tee -a "$LOG"
bash "$PROBE_DIR/06-bank-delta.sh" before 2>&1 | tee -a "$LOG"
BANK_BEFORE_RC=${PIPESTATUS[0]}
if [ "$BANK_BEFORE_RC" -ne 0 ]; then
  echo "ABORT: 06-bank-delta.sh before failed (rc=$BANK_BEFORE_RC) — see $LOG" | tee -a "$LOG"
  exit 1
fi
if grep -q 'verdict=SKIPPED-BANK' "$LOG"; then
  echo "ABORT: bank at/over threshold before any probe ran (SKIPPED-BANK)." | tee -a "$LOG"
  exit 1
fi

REPO_ROOT="$(cd "$PROBE_DIR/../../.." && pwd)"
FAILED_PROBES=""
for probe in 01-compact-via-resume.sh 01b-compact-via-continue.sh 02-dontask-allowlist.sh \
             03-bare-add-dir-skills.sh 03b-configdir-pack.sh 03c-cwd-pack.sh 03d-plugin-dir-pack.sh \
             04-wrapper-shape.sh 05-cross-cwd-resume.sh 07-dual-shell-allowlist.sh; do
  # Re-check the bank between probes, not just once before the whole batch —
  # a run starting just below the skip threshold could otherwise cross it
  # partway through and keep issuing every remaining headless call unchecked.
  MIDBATCH_VERDICT="$(bash "$REPO_ROOT/scripts/lib/bank-preflight.sh" 2>"$OUT_DIR/midbatch-preflight.err")"
  MIDBATCH_RC=$?
  if [ "$MIDBATCH_RC" -ne 0 ]; then
    echo "ABORT: mid-batch bank-preflight.sh failed (rc=$MIDBATCH_RC, before $probe) — see $OUT_DIR/midbatch-preflight.err" | tee -a "$LOG"
    exit 1
  fi
  if [ "$MIDBATCH_VERDICT" = "SKIPPED-BANK" ]; then
    echo "ABORT: bank crossed threshold mid-batch (before $probe) — stopping remaining probes." | tee -a "$LOG"
    exit 1
  fi
  echo "=== $probe ===" | tee -a "$LOG"
  bash "$PROBE_DIR/$probe" 2>&1 | tee -a "$LOG"
  PROBE_RC=${PIPESTATUS[0]}
  # Report, don't abort the batch — a probe's own nonzero exit can be either
  # a genuine reliability abort (e.g. probe 1b's hijacked-session guards) or
  # an expected measured negative baked into the CLI call itself; either way
  # every remaining probe still has independent measurement value. Recording
  # it here is what stops a reliability abort from being silently masked
  # behind a plain "Done" (unlike this loop's own artifact/log-based results,
  # which stay verified by artifact per common.sh's documented convention).
  if [ "$PROBE_RC" -ne 0 ]; then
    echo "NOTE: $probe exited rc=$PROBE_RC — see its section above for details" | tee -a "$LOG"
    FAILED_PROBES="$FAILED_PROBES $probe(rc=$PROBE_RC)"
  fi
done

echo "=== bank snapshot: after ===" | tee -a "$LOG"
bash "$PROBE_DIR/06-bank-delta.sh" after 2>&1 | tee -a "$LOG"
BANK_AFTER_RC=${PIPESTATUS[0]}
if [ "$BANK_AFTER_RC" -ne 0 ]; then
  echo "ERROR: 06-bank-delta.sh after failed (rc=$BANK_AFTER_RC) — see $LOG" | tee -a "$LOG"
  exit 1
fi

if [ -n "$FAILED_PROBES" ]; then
  echo "Done WITH FAILURES. Full log: $LOG — nonzero probes:$FAILED_PROBES" | tee -a "$LOG"
  exit 1
fi
echo "Done. Full log: $LOG"
