#!/usr/bin/env bash
# Smoke test for update_hermes() in himmel-update.sh (HIMMEL-426). Sources the
# script via its HIMMEL_UPDATE_LIB seam so the function runs in isolation with
# HERMES_HOME fixtures — no network, no repo mutation.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
HIMMEL_UPDATE_LIB=1 . "$HERE/himmel-update.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

check() {  # <description> <expected-substring> <actual-output>
  if printf '%s' "$3" | grep -Eq "$2"; then
    echo "ok: $1"
  else
    echo "FAIL: $1"; echo "  expected /$2/ in:"; printf '%s\n' "$3" | sed 's/^/    /'
    fail=1
  fi
}

# HERMES_HOME is the install ROOT; the git checkout is its hermes-agent/ subdir.

# Case 1: install root with no hermes-agent checkout → "not installed" skip.
out=$(HERMES_HOME="$tmp/nope" update_hermes check 2>&1)
check "absent hermes skips" "skip: hermes not installed as a git checkout" "$out"

# Case 2: hermes-agent/ checkout with a foreign remote → "not a … checkout" skip
# (returns before any fetch/pull, so this stays offline).
git init -q "$tmp/other/hermes-agent"
git -C "$tmp/other/hermes-agent" remote add origin https://github.com/x/y.git
out=$(HERMES_HOME="$tmp/other" update_hermes apply 2>&1)
check "foreign checkout skips" "is not a NousResearch/hermes-agent checkout" "$out"

# Case 3: NousResearch hermes-agent/ checkout, check mode, fetch unreachable →
# graceful handling (offline / current / update-available), never crash/push.
git init -q "$tmp/install/hermes-agent"
git -C "$tmp/install/hermes-agent" remote add origin https://github.com/NousResearch/hermes-agent.git
out=$(HERMES_HOME="$tmp/install" update_hermes check 2>&1)
check "nous checkout check handled" "could not reach origin|hermes is current|update available" "$out"

# Case 4: HERMES_HOME pointing STRAIGHT at the checkout (…/.git present) is
# tolerated — same NousResearch handling.
git init -q "$tmp/direct"
git -C "$tmp/direct" remote add origin https://github.com/NousResearch/hermes-agent.git
out=$(HERMES_HOME="$tmp/direct" update_hermes check 2>&1)
check "direct checkout tolerated" "could not reach origin|hermes is current|update available" "$out"

# ── report_cadence_stale() — stale pipeline-cadence runner nudge (HIMMEL-588) ──
# Same lib seam; PIPELINE_BAT_DIR points at a fixture runner dir.

# Case 5: no runners present → silent no-op (cadence not armed via this dir).
out=$(PIPELINE_BAT_DIR="$tmp/cad-empty" report_cadence_stale 2>&1)
if [ -z "$out" ]; then echo "ok: cadence absent → silent"; else echo "FAIL: cadence absent not silent"; printf '%s\n' "$out"; fail=1; fi

# Case 6: runner with no format stamp (armed before HIMMEL-588) → STALE nudge.
mkdir -p "$tmp/cad-stale"
printf '#!/bin/sh\necho old\n' > "$tmp/cad-stale/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-stale" report_cadence_stale 2>&1)
check "stale cadence nudged" "runners are STALE|arm --force" "$out"

# Case 7: runner stamped at the current version → no nudge.
mkdir -p "$tmp/cad-current"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho cur\n' "$CADENCE_RUNNER_FORMAT_VERSION" \
    > "$tmp/cad-current/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-current" report_cadence_stale 2>&1)
if [ -z "$out" ]; then echo "ok: current cadence → silent"; else echo "FAIL: current cadence wrongly nudged"; printf '%s\n' "$out"; fail=1; fi

# Case 8: malformed marker (present but no version number) → safe fallback to
# version 0 → treated as stale (nudge), never a crash under set -e.
mkdir -p "$tmp/cad-malformed"
printf '#!/bin/sh\n# himmel-cadence-runner-format:\necho bad\n' > "$tmp/cad-malformed/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-malformed" report_cadence_stale 2>&1)
check "malformed stamp → stale fallback" "runners are STALE|arm --force" "$out"

if [ "$fail" -eq 0 ]; then
  echo "PASS: himmel-update hermes smoke test"
else
  echo "FAILED"; exit 1
fi
