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

# ── report_cadence_stale() — stale cadence runner nudge (HIMMEL-588/969) ─────
# Same lib seams; *_BAT_DIR point at fixture runner dirs.

# Case 5: no runners present anywhere → silent no-op (cadences not armed).
out=$(PIPELINE_BAT_DIR="$tmp/cad-empty" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
if [ -z "$out" ]; then echo "ok: cadence absent → silent"; else echo "FAIL: cadence absent not silent"; printf '%s\n' "$out"; fail=1; fi

# Case 6: codex-sweep.bat stamped current → shared probe returns its version.
mkdir -p "$tmp/cad-codex-current"
printf 'rem himmel-cadence-runner-format: %s\r\n' "$CADENCE_RUNNER_FORMAT_VERSION" \
  > "$tmp/cad-codex-current/codex-sweep.bat"
ver=$(cadence_runner_stamp "$tmp/cad-codex-current")
if [ "$ver" = "$CADENCE_RUNNER_FORMAT_VERSION" ]; then echo "ok: codex-sweep stamp probed"; else echo "FAIL: codex-sweep stamp probe got '$ver'"; fail=1; fi

# Case 7: pipeline runner with no format stamp (armed before HIMMEL-588) →
# STALE nudge with pipeline re-arm hint.
mkdir -p "$tmp/cad-stale"
printf '#!/bin/sh\necho old\n' > "$tmp/cad-stale/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-stale" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "stale pipeline cadence nudged (message)" "pipeline-cadence runners are STALE" "$out"
check "stale pipeline cadence nudged (rearm hint)" "bash scripts/luna/pipeline-cadence.sh arm --force" "$out"

# Case 8: codex-sweep.bat stamped stale → STALE nudge with codex re-arm hint.
mkdir -p "$tmp/cad-codex-stale"
printf 'rem himmel-cadence-runner-format: %s\r\n' "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" \
  > "$tmp/cad-codex-stale/codex-sweep.bat"
out=$(PIPELINE_BAT_DIR="$tmp/cad-empty" SWEEP_BAT_DIR="$tmp/cad-codex-stale" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "stale codex-sweep cadence nudged (message)" "codex-sweep-cadence runners are STALE" "$out"
check "stale codex-sweep cadence nudged (rearm hint)" "bash scripts/cleanup/codex-sweep-cadence.sh arm --force" "$out"

# Case 9: graphmap runner stamped stale → STALE nudge with graphmap re-arm hint.
mkdir -p "$tmp/cad-graphmap-stale"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old\n' "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" \
  > "$tmp/cad-graphmap-stale/graphmap-himmel.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-empty" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/cad-graphmap-stale" report_cadence_stale 2>&1)
check "stale graphmap cadence nudged (message)" "graphmap-cadence runners are STALE" "$out"
check "stale graphmap cadence nudged (rearm hint)" "bash scripts/luna/graphmap-cadence.sh arm --force" "$out"

# Case 10: pipeline-only runner stamped at the current version → no nudge and
# empty codex/graphmap dirs do not false-positive.
mkdir -p "$tmp/cad-current"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho cur\n' "$CADENCE_RUNNER_FORMAT_VERSION" \
    > "$tmp/cad-current/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-current" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
if [ -z "$out" ]; then echo "ok: current cadence → silent"; else echo "FAIL: current cadence wrongly nudged"; printf '%s\n' "$out"; fail=1; fi

# Case 11: malformed marker (present but no version number) → safe fallback to
# version 0 → treated as stale (nudge), never a crash under set -e.
mkdir -p "$tmp/cad-malformed"
printf '#!/bin/sh\n# himmel-cadence-runner-format:\necho bad\n' > "$tmp/cad-malformed/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-malformed" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "malformed stamp → stale fallback (message)" "pipeline-cadence runners are STALE" "$out"
check "malformed stamp → stale fallback (rearm hint)" "bash scripts/luna/pipeline-cadence.sh arm --force" "$out"

# Case 12: MIXED runner versions in one dir → probe returns the MINIMUM (one
# current runner must not mask a stale sibling — interrupted re-arm).
mkdir -p "$tmp/cad-mixed"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho cur\n' "$CADENCE_RUNNER_FORMAT_VERSION" \
  > "$tmp/cad-mixed/pipeline-harvest.sh"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old\n' "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" \
  > "$tmp/cad-mixed/pipeline-health.sh"
ver=$(cadence_runner_stamp "$tmp/cad-mixed")
if [ "$ver" = "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" ]; then echo "ok: mixed versions → minimum wins"; else echo "FAIL: mixed-version probe got '$ver'"; fail=1; fi
out=$(PIPELINE_BAT_DIR="$tmp/cad-mixed" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "mixed-version cadence nudged" "pipeline-cadence runners are STALE" "$out"

# Case 13: cadence_user_home — with USERPROFILE unset it echoes $HOME verbatim
# (the POSIX leg; the Windows USERPROFILE/cygpath leg is exercised by real
# Git-Bash runs where the two homes coincide).
uh=$(USERPROFILE='' HOME="$tmp/fake-home" cadence_user_home)
if [ "$uh" = "$tmp/fake-home" ]; then echo "ok: cadence_user_home falls back to HOME"; else echo "FAIL: cadence_user_home got '$uh'"; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: himmel-update hermes smoke test"
else
  echo "FAILED"; exit 1
fi
