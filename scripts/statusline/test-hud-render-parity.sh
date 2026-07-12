#!/usr/bin/env bash
# HIMMEL-718 Phase 3 Task 3.1 -- claude-hud NATIVE-line parity vs the legacy bar.
#
# Proves the forked claude-hud renderer, driven by marketplace/plugins/
# claude-hud/config/himmel-config.json, reproduces the legacy bash bar
# (scripts/statusline/bin/statusline.sh) for the fields that are derived purely
# from the Claude Code statusline stdin JSON and are therefore DETERMINISTIC:
#
#   * model display name   (stdin model.display_name)
#   * context %            (stdin context_window token counts / window size)
#   * 5h usage %           (stdin rate_limits.five_hour.used_percentage)
#   * 7d usage %           (stdin rate_limits.seven_day.used_percentage)
#
# It does NOT byte-compare against the legacy .out captures: those lines also
# carry wall-clock (session duration, reset countdown), live session/all-session
# economics, and real git state, so they differ every render (see the golden
# README + the Task-3.1 handover). The economics / where-are-we / extra-usage
# custom lines are the composer's concern and are proven in Task 3.2's parity
# test, since the composer is their host.
#
# Accepted deltas (documented, non-blocking -- no hud config key exists for
# either; native-first + delta per the migration plan section Global Constraints):
#   * context %: the legacy bar FLOORS, hud ROUNDS-half-up -- the same underlying
#     value, <=1 percentage-point apart (e.g. 69.6% -> legacy 69 / hud 70). hud's
#     rounded value is deterministic, so it is asserted EXACTLY against the
#     expected round-half-up value (stronger than a floor +/-1 band, which could
#     hide a <=1pp hud rounding regression). The legacy floor shown in each case
#     header is the same value or 1pp lower. 5h/7d/model are integer
#     pass-throughs, asserted exactly.
#   * usage labels: legacy "5h bank"/"7d bank" vs hud i18n "Usage"/"Weekly";
#     reset time wording. Cosmetic; not asserted.
#
# Hermetic: isolated HOME + CLAUDE_CONFIG_DIR, and externalUsagePath is
# repointed to a non-existent temp path so the render never reads the machine's
# real producer snapshot. Deterministic fields only -> no time/git flakiness.
# Usage: bash scripts/statusline/test-hud-render-parity.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

STATUSLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$STATUSLINE_DIR/../.." && pwd)"
HUD_DIST="$REPO_ROOT/marketplace/plugins/claude-hud/dist/index.js"
HUD_CONFIG="$REPO_ROOT/marketplace/plugins/claude-hud/config/himmel-config.json"
GOLDEN="$STATUSLINE_DIR/testdata/golden"

command -v node >/dev/null 2>&1 || { echo "FATAL: node required for this test"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "FATAL: jq required for this test"; exit 1; }
[ -f "$HUD_DIST" ]   || { echo "FATAL: hud dist not found: $HUD_DIST"; exit 1; }
[ -f "$HUD_CONFIG" ] || { echo "FATAL: himmel-config.json not found: $HUD_CONFIG"; exit 1; }

SUITE_TMP=$(mktemp -d)
trap 'rm -rf "$SUITE_TMP"' EXIT

# Hermetic hud config dir: ship the real himmel config but repoint
# externalUsagePath at a non-existent temp file, so 5h/7d/credits assertions
# stay independent of the machine's live producer snapshot.
CFG_DIR="$SUITE_TMP/cfg"
mkdir -p "$CFG_DIR/plugins/claude-hud" "$SUITE_TMP/home"
jq --arg p "$SUITE_TMP/nonexistent-hud-snapshot.json" \
   '.display.externalUsagePath = $p' \
   "$HUD_CONFIG" > "$CFG_DIR/plugins/claude-hud/config.json"

_failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; _failures=$((_failures + 1)); }

# Render a fixture through hud with the himmel config; strip ANSI SGR + OSC-8
# hyperlink escapes so text assertions see plain output. Runs from the repo root
# so each fixture's relative transcript_path resolves.
render() {
  ( cd "$REPO_ROOT" && HOME="$SUITE_TMP/home" CLAUDE_CONFIG_DIR="$CFG_DIR" \
      node "$HUD_DIST" < "$GOLDEN/$1" 2>&1 ) \
    | sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x07]*\x07//g'
}

# Percentage immediately following a labelled segment ("Context 48%", "Usage
# 42%", "Weekly 68%"). Anchored on each segment's own label so the extraction
# does not depend on render order. NB: the "Usage"/"Weekly" labels are i18n and
# cosmetic for the label text itself, but they are LOAD-BEARING for these numeric
# extractions -- a hud label change would break the 5h/7d gate even at perfect
# percentage parity (a 3.2 change adding custom lines containing "Usage" would
# also need to revisit the check_absent anchors below).
pct_after() { sed -nE "s/.*$1 [^0-9]*([0-9]+)%.*/\1/p" | head -1; }

check_model() { case "$1" in *"$2"*) pass "$3: model '$2'";; *) fail "$3: model expected '$2' in: $1";; esac; }
check_exact() { if [ "$1" = "$2" ]; then pass "$4: $3=$2"; else fail "$4: $3 expected '$2' got '$1'"; fi; }
check_ctx() {  # $1=actual $2=expected hud round-half-up value $3=label (legacy floor is == or 1pp lower)
  if [ "${1:-}" = "$2" ]; then pass "$3: ctx=$2%"; else fail "$3: ctx expected $2% got '${1:-none}'"; fi
}
check_absent() { if printf '%s' "$1" | grep -q "$2"; then fail "$4: '$2' should be absent ($3)"; else pass "$4: no $3"; fi; }

echo "== static config wiring =="
check_exact "$(jq -r '.display.externalUsagePath' "$HUD_CONFIG")" \
  "/tmp/claude/hud-usage-snapshot.json" "externalUsagePath" "config"
check_exact "$(jq -r '.display.autocompactBuffer' "$HUD_CONFIG")" \
  "disabled" "autocompactBuffer" "config"

echo "== with-ratelimits (Sonnet, ctx 48, 5h 42, 7d 68) =="
OUT=$(render fixture-with-ratelimits.json)
check_model "$OUT" "Claude Sonnet 4.5" "with-ratelimits"
check_ctx   "$(printf '%s' "$OUT" | pct_after Context)" 48 "with-ratelimits"
check_exact "$(printf '%s' "$OUT" | pct_after Usage)"  "42" "5h%"  "with-ratelimits"
check_exact "$(printf '%s' "$OUT" | pct_after Weekly)" "68" "7d%"  "with-ratelimits"

echo "== warm (Sonnet, ctx 93, 5h 58, 7d 39) =="
OUT=$(render fixture-warm.json)
check_model "$OUT" "Claude Sonnet 4.5" "warm"
check_ctx   "$(printf '%s' "$OUT" | pct_after Context)" 93 "warm"
check_exact "$(printf '%s' "$OUT" | pct_after Usage)"  "58" "5h%" "warm"
check_exact "$(printf '%s' "$OUT" | pct_after Weekly)" "39" "7d%" "warm"

echo "== with-extra-usage (Opus, ctx 69->70, 5h 74, 7d 81) =="
OUT=$(render fixture-with-extra-usage.json)
check_model "$OUT" "Claude Opus 4.8" "with-extra-usage"
check_ctx   "$(printf '%s' "$OUT" | pct_after Context)" 70 "with-extra-usage"
check_exact "$(printf '%s' "$OUT" | pct_after Usage)"  "74" "5h%" "with-extra-usage"
check_exact "$(printf '%s' "$OUT" | pct_after Weekly)" "81" "7d%" "with-extra-usage"

echo "== no-ratelimits (Sonnet, ctx 12->13, no bank lines) =="
OUT=$(render fixture-no-ratelimits.json)
check_model  "$OUT" "Claude Sonnet 4.5" "no-ratelimits"
check_ctx    "$(printf '%s' "$OUT" | pct_after Context)" 13 "no-ratelimits"
check_absent "$OUT" "Usage"  "5h bank"  "no-ratelimits"
check_absent "$OUT" "Weekly" "7d bank"  "no-ratelimits"

echo "== cold (Haiku, ctx 0, no bank lines) =="
OUT=$(render fixture-cold.json)
check_model  "$OUT" "Claude Haiku" "cold"
check_ctx    "$(printf '%s' "$OUT" | pct_after Context)" 0 "cold"
check_absent "$OUT" "Usage"  "5h bank" "cold"
check_absent "$OUT" "Weekly" "7d bank" "cold"

echo
if [ "$_failures" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES: $_failures"
exit 1
