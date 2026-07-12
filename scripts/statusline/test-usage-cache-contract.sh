#!/usr/bin/env bash
# Contract test: usage-cache-producer.sh -> all THREE shipped cap-guard
# consumers (HIMMEL-718 Phase 2 Task 2.2).
#
# The producer writes the consumer cache; the consumers must read it
# UNCHANGED. If any consumer chokes here, the fix goes in the PRODUCER
# schema — never in the consumers.
#
# Consumers under contract (paths + read anchors verified in-tree):
#   1. scripts/handover/cap-reset-time.sh   --cache <c> [--max-age 0]
#      reads .<window>.resets_at (jq, line 119), emits HH:MM local.
#   2. scripts/hooks/auto-arm-on-cap.sh     via AUTO_ARM_CACHE=<c>
#      python evaluator requires a non-null, in-range numeric
#      .five_hour/.seven_day.utilization (HIMMEL-279 guard: null ->
#      "utilization is null" stderr; all-unusable -> rc=4 MALFUNCTION).
#   3. scripts/handover/resume-slot.sh      --cache <c> --max-age 0
#      shape guard (~line 154): at least one of five_hour/seven_day must
#      be a JSON object, else "schema mismatch" die.
#
# Hermetic: own temp dirs, env-overridden cache/state/handover/ledger
# paths; never touches the real ~/.claude or /tmp/claude. Git-Bash-safe,
# bash 3.2-safe.
# Usage: bash scripts/statusline/test-usage-cache-contract.sh
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # vars used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # helper fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

STATUSLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCER="$STATUSLINE_DIR/usage-cache-producer.sh"
COMPOSER="$STATUSLINE_DIR/hud-custom-lines.sh"   # HIMMEL-718 Task 2.3 real driver
CAP_RESET="$STATUSLINE_DIR/../handover/cap-reset-time.sh"
AUTO_ARM="$STATUSLINE_DIR/../hooks/auto-arm-on-cap.sh"
RESUME_SLOT="$STATUSLINE_DIR/../handover/resume-slot.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test"; exit 1; }
for f in "$PRODUCER" "$CAP_RESET" "$AUTO_ARM" "$RESUME_SLOT"; do
  [ -f "$f" ] || { echo "FATAL: missing script under contract: $f"; exit 1; }
done

# All per-case mktemp -d workdirs land under one suite TMPDIR, swept on exit
# (CR codex-6 — same sweep as the producer test).
SUITE_TMP=$(mktemp -d)
export TMPDIR="$SUITE_TMP"
trap 'rm -rf "$SUITE_TMP"' EXIT

_failures=0

run_test() {
  local name="$1" body="$2"
  local rc=0
  ( eval "$body" ) || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s\n' "$name"
  else
    printf '  FAIL  %s (subshell rc=%s)\n' "$name" "$rc"
    _failures=$((_failures + 1))
  fi
}

# produce_cache <workdir> <five_util> <seven_util>
# Runs the PRODUCER on a rates-path stdin fixture; cache lands at
# <workdir>/cache.json (hud at <workdir>/hud.json). resets_at values are
# fixed far-future ISO with explicit +00:00 offset (parseable by the
# consumers' py-armor fromisoformat path on every python version).
produce_cache() {
  local w="$1" five="$2" seven="$3"
  CLAUDE_USAGE_CACHE="$w/cache.json" HUD_USAGE_SNAPSHOT="$w/hud.json" \
    bash "$PRODUCER" <<EOF
{"rate_limits":{"five_hour":{"utilization":$five,"resets_at":"2027-01-01T13:30:00+00:00"},"seven_day":{"utilization":$seven,"resets_at":"2027-01-04T09:00:00+00:00"}}}
EOF
}

# produce_cache_via_composer <workdir> <five_util> <seven_util>
# HIMMEL-718 Task 2.3: drive the cache through the REAL render-time driver
# (hud-custom-lines.sh), not the producer in isolation. Same rates-path stdin
# fixture, wrapped in a render JSON. WAW off (skip the segment subprocess) and an
# isolated all-sessions cache dir keep it hermetic + fast; the composer's
# freshness-gated producer spawn writes the same consumer cache.
produce_cache_via_composer() {
  local w="$1" five="$2" seven="$3"
  CLAUDE_USAGE_CACHE="$w/cache.json" HUD_USAGE_SNAPSHOT="$w/hud.json" \
  HIMMEL_WHERE_ARE_WE=0 CLAUDE_ALL_SESSIONS_CACHE_DIR="$w" \
    bash "$COMPOSER" >/dev/null 2>&1 <<EOF
{"rate_limits":{"five_hour":{"utilization":$five,"resets_at":"2027-01-01T13:30:00+00:00"},"seven_day":{"utilization":$seven,"resets_at":"2027-01-04T09:00:00+00:00"}},"model":{"id":"claude-opus-4-8"},"transcript_path":"","cwd":"$w"}
EOF
}

# run_arm_hook <statedir> <cache> <armlog> <handoverdir> <stderrlog>
# Full-hook invocation, existing test-auto-arm-on-cap.sh idiom: stub arm
# via AUTO_ARM_BIN, isolate state/handover/quota-ledger, stdin closed.
run_arm_hook() {
  local s="$1" c="$2" alog="$3" hdir="$4" elog="$5"
  AUTO_ARM_STATE_DIR="$s" AUTO_ARM_CACHE="$c" \
  AUTO_ARM_BIN="$ARM_STUB" ARM_LOG_PATH="$alog" \
  HANDOVER_DIR="$hdir" CLAUDE_PROJECT_DIR="" \
  HIMMEL_QUOTA_GAUGE_LEDGER="$s/quota-gauge.jsonl" \
  bash "$AUTO_ARM" </dev/null >/dev/null 2>"$elog"
}

# Shared stub arm (records args, exits 0). STUB_DIR lands under SUITE_TMP
# (TMPDIR is exported above) and rides its EXIT sweep — do NOT add a second
# EXIT trap here: bash traps REPLACE, they don't stack (CR independent-1).
STUB_DIR=$(mktemp -d)
ARM_STUB="$STUB_DIR/arm-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$@" >> "${ARM_LOG_PATH}"' 'exit 0' > "$ARM_STUB"
chmod +x "$ARM_STUB"

# --- cases --------------------------------------------------------------------

run_test "(1) cap-reset-time.sh reads the produced cache -> valid HH:MM (five-hour + seven-day)" '
  W=$(mktemp -d); produce_cache "$W" 63.4 12.7 || exit 1;
  out=$(bash "$CAP_RESET" --cache "$W/cache.json" --max-age 0) || exit 1;
  printf "%s" "$out" | grep -Eq "^([01][0-9]|2[0-3]):[0-5][0-9]$" || exit 1;
  out7=$(bash "$CAP_RESET" --window seven-day --cache "$W/cache.json" --max-age 0) || exit 1;
  printf "%s" "$out7" | grep -Eq "^([01][0-9]|2[0-3]):[0-5][0-9]$" || exit 1;
'

run_test "(2a) auto-arm-on-cap.sh below threshold: utilization read is non-null, no MALFUNCTION, no arm" '
  W=$(mktemp -d); produce_cache "$W" 63.4 12.7 || exit 1;
  S="$W/state"; mkdir -p "$S"; H="$W/handovers"; mkdir -p "$H";
  run_arm_hook "$S" "$W/cache.json" "$W/arm.log" "$H" "$W/stderr.log";
  rc=$?; [ "$rc" -eq 0 ] || exit 1;
  # HIMMEL-279 guard: a null/unusable utilization would warn on stderr
  grep -q "utilization is null" "$W/stderr.log" && exit 1;
  grep -q "MALFUNCTION" "$W/stderr.log" && exit 1;
  # real check ran (throttle marker), and below-threshold did not arm
  [ -f "$S/auto-arm-last-check" ] || exit 1;
  [ -e "$W/arm.log" ] && exit 1;
  exit 0;
'

run_test "(2b) auto-arm-on-cap.sh above threshold: utilization parsed from produced cache -> arm fires (rc=2 one-shot block)" '
  W=$(mktemp -d); produce_cache "$W" 95 12.7 || exit 1;
  S="$W/state"; mkdir -p "$S"; H="$W/handovers"; mkdir -p "$H";
  run_arm_hook "$S" "$W/cache.json" "$W/arm.log" "$H" "$W/stderr.log";
  rc=$?;
  # a TRIP exits 2 by design (one-shot block) — test-auto-arm-on-cap.sh:125 idiom
  [ "$rc" -eq 2 ] || exit 1;
  grep -q "MALFUNCTION" "$W/stderr.log" && exit 1;
  grep -q "RESUME ARMED" "$W/stderr.log" || exit 1;
  # the 95% utilization was READ as a number (proves non-null path end-to-end)
  [ -f "$W/arm.log" ] || exit 1;
  exit 0;
'

run_test "(3) resume-slot.sh --cache --max-age 0: shape guard passes, emits a slot" '
  W=$(mktemp -d); produce_cache "$W" 63.4 12.7 || exit 1;
  out=$(bash "$RESUME_SLOT" --cache "$W/cache.json" --max-age 0 2>"$W/stderr.log") || exit 1;
  [ -n "$out" ] || exit 1;
  grep -q "schema mismatch" "$W/stderr.log" && exit 1;
  exit 0;
'

run_test "(4) consumers UNCHANGED premise: cache byte-identical across all three consumer reads" '
  W=$(mktemp -d); produce_cache "$W" 63.4 12.7 || exit 1;
  before=$(cat "$W/cache.json");
  bash "$CAP_RESET" --cache "$W/cache.json" --max-age 0 >/dev/null || exit 1;
  S="$W/state"; mkdir -p "$S"; H="$W/handovers"; mkdir -p "$H";
  run_arm_hook "$S" "$W/cache.json" "$W/arm.log" "$H" "$W/stderr.log" || exit 1;
  bash "$RESUME_SLOT" --cache "$W/cache.json" --max-age 0 >/dev/null || exit 1;
  [ "$(cat "$W/cache.json")" = "$before" ] || exit 1;
'

# --- HIMMEL-718 Task 2.3: same contract, via the REAL composer driver ---------
run_test "(5) composer-DRIVEN cache satisfies the full cap-guard contract (real 2.3 driver)" '
  W=$(mktemp -d); produce_cache_via_composer "$W" 55.5 22.2 || exit 1;
  [ -f "$W/cache.json" ] || exit 1;
  # five_hour/seven_day are JSON objects with numeric utilization (schema).
  [ "$(jq -r ".five_hour.utilization" "$W/cache.json")" = "55.5" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$W/cache.json")" = "22.2" ] || exit 1;
  # consumer 1: cap-reset-time reads resets_at -> HH:MM.
  bash "$CAP_RESET" --cache "$W/cache.json" --max-age 0 | grep -Eq "^([01][0-9]|2[0-3]):[0-5][0-9]$" || exit 1;
  # consumer 2: auto-arm reads a non-null utilization, no MALFUNCTION.
  S="$W/state"; mkdir -p "$S"; H="$W/handovers"; mkdir -p "$H";
  run_arm_hook "$S" "$W/cache.json" "$W/arm.log" "$H" "$W/stderr.log";
  grep -q "utilization is null" "$W/stderr.log" && exit 1;
  grep -q "MALFUNCTION" "$W/stderr.log" && exit 1;
  # consumer 3: resume-slot shape guard passes.
  bash "$RESUME_SLOT" --cache "$W/cache.json" --max-age 0 2>"$W/rs.err" >/dev/null || exit 1;
  grep -q "schema mismatch" "$W/rs.err" && exit 1;
  exit 0;
'

# A stub producer (HIMMEL_USAGE_PRODUCER seam) that LOGS every invocation, so we
# can OBSERVE the composer's freshness-gated fork directly (not merely the
# producer's own internal throttle). It also drains stdin so the pipe never blocks.
STUB_PROD="$STUB_DIR/stub-producer.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1 || true' 'echo x >> "$STUB_PROD_LOG"' > "$STUB_PROD"
chmod +x "$STUB_PROD"
compose_with_stub() {   # <workdir> <ttl-or-empty>   (env used: expansion-safe assignment)
  local w="$1" ttl="$2"
  env CLAUDE_USAGE_CACHE="$w/cache.json" HUD_USAGE_SNAPSHOT="$w/hud.json" HIMMEL_WHERE_ARE_WE=0 \
    CLAUDE_ALL_SESSIONS_CACHE_DIR="$w" HIMMEL_USAGE_PRODUCER="$STUB_PROD" STUB_PROD_LOG="$w/prod.log" \
    ${ttl:+USAGE_CACHE_TTL="$ttl"} \
    bash "$COMPOSER" >/dev/null 2>&1 <<JSON
{"rate_limits":{"five_hour":{"utilization":55.5,"resets_at":"2027-01-01T13:30:00+00:00"},"seven_day":{"utilization":22.2,"resets_at":"2027-01-04T09:00:00+00:00"}},"model":{"id":"claude-opus-4-8"},"transcript_path":"","cwd":"$w"}
JSON
}

run_test "(6) composer freshness-gate: a FRESH consumer cache SKIPS the producer FORK (observed via stub)" '
  W=$(mktemp -d); : > "$W/prod.log";
  printf "%s" "{\"five_hour\":{\"utilization\":55.5}}" > "$W/cache.json";   # fresh (just written)
  compose_with_stub "$W" "";
  [ ! -s "$W/prod.log" ] || exit 1;                       # stub NOT invoked -> fork avoided
  # TTL=0 bypasses the gate -> the stub IS invoked (fork happens).
  : > "$W/prod.log";
  compose_with_stub "$W" 0;
  [ -s "$W/prod.log" ] || exit 1;                         # stub invoked
  exit 0;
'

# --- summary ------------------------------------------------------------------
if [ "$_failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $_failures case(s) failed"
  exit 1
fi
