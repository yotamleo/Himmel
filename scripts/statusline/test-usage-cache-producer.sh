#!/usr/bin/env bash
# Test for scripts/statusline/usage-cache-producer.sh (HIMMEL-718 Phase 2 Task 2.1).
#
# The producer runs once per statusline render. It reads the Claude Code
# statusline stdin JSON and maintains TWO single-writer files:
#   A. consumer cache  (CLAUDE_USAGE_CACHE)  — himmel schema for cap-guards.
#   B. hud snapshot    (HUD_USAGE_SNAPSHOT)  — claude-hud externalUsagePath.
#
# Self-contained: every case builds its own temp HOME + output paths via env,
# so it NEVER touches the real ~/.claude or /tmp/claude cache. Cleans up on exit.
# Usage: bash scripts/statusline/test-usage-cache-producer.sh
# Exit 0 if all cases pass, 1 otherwise.
#
# shellcheck disable=SC2034  # PRODUCER/mtime used inside eval'd test body strings
# shellcheck disable=SC2016  # single-quoted test body strings intentionally contain $
# shellcheck disable=SC2317  # helper fns called indirectly via eval inside run_test
# shellcheck disable=SC2329  # same as SC2317 (alias in newer shellcheck versions)
set -uo pipefail

STATUSLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCER="$STATUSLINE_DIR/usage-cache-producer.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test"; exit 1; }

# All per-case mktemp -d workdirs land under one suite TMPDIR, swept on exit
# (CR codex-2: the per-case dirs were never removed).
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

# mtime helper (GNU stat then BSD stat) — mirrors statusline.sh idiom.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# --- cases --------------------------------------------------------------------

run_test "(1) stdin WITH rate_limits -> consumer cache mirrors five_hour/seven_day" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"2026-07-06T18:00:00Z\"},\"seven_day\":{\"utilization\":12.7,\"resets_at\":\"2026-07-10T00:00:00Z\"}}}" \
    | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "63.4" ] || exit 1;
  [ "$(jq -r ".five_hour.resets_at" "$CLAUDE_USAGE_CACHE")" = "2026-07-06T18:00:00Z" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "12.7" ] || exit 1;
  [ "$(jq -r ".seven_day.resets_at" "$CLAUDE_USAGE_CACHE")" = "2026-07-10T00:00:00Z" ] || exit 1;
'

run_test "(2) same run -> hud snapshot exactly-2-keys + rounded used_percentage + updated_at" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"2026-07-06T18:00:00Z\"},\"seven_day\":{\"utilization\":12.7,\"resets_at\":\"2026-07-10T00:00:00Z\"}}}" \
    | bash "$PRODUCER";
  [ "$(jq -r ".five_hour|keys|sort|join(\",\")" "$HUD_USAGE_SNAPSHOT")" = "resets_at,used_percentage" ] || exit 1;
  [ "$(jq -r ".seven_day|keys|length" "$HUD_USAGE_SNAPSHOT")" = "2" ] || exit 1;
  [ "$(jq -r ".five_hour.used_percentage" "$HUD_USAGE_SNAPSHOT")" = "63" ] || exit 1;
  [ "$(jq -r ".seven_day.used_percentage" "$HUD_USAGE_SNAPSHOT")" = "13" ] || exit 1;
  u=$(jq -r ".updated_at // empty" "$HUD_USAGE_SNAPSHOT"); [ -n "$u" ] || exit 1;
'

run_test "(3) no rate_limits + stubbed OAuth -> extra_usage merged, prior five/seven PRESERVED, hud gains balance_label" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  # pre-seed cache with good five_hour/seven_day, NO oauth_checked_at (=> OAuth stale => fetch)
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "[ -n \"\${OAUTH_MARKER:-}\" ] \&\& : > \"\$OAUTH_MARKER\"" "cat <<JSON" "{\"five_hour\":{\"utilization\":99},\"extra_usage\":{\"is_enabled\":true,\"used_credits\":350,\"monthly_limit\":5000,\"utilization\":7}}" "JSON" > "$stub";
  export OAUTH_MARKER="$W/marker"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  # prior five_hour/seven_day preserved (NOT clobbered by fetched five_hour:99)
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "40" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "8" ] || exit 1;
  # extra_usage merged from fetch
  [ "$(jq -r ".extra_usage.used_credits" "$CLAUDE_USAGE_CACHE")" = "350" ] || exit 1;
  # hud snapshot gains balance_label
  bl=$(jq -r ".balance_label // empty" "$HUD_USAGE_SNAPSHOT"); [ -n "$bl" ] || exit 1;
'

run_test "(4) atomicity: temp+mv pattern present AND cache intact after failing OAuth stub (no partial/tmp file)" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  # static: producer writes via temp + mv -f
  grep -q "mv -f" "$PRODUCER" || exit 1;
  grep -q "\.tmp" "$PRODUCER" || exit 1;
  # seed a good cache; a FAILING (non-JSON) OAuth stub must not clobber it
  good="{\"five_hour\":{\"utilization\":55,\"resets_at\":\"RR\"},\"seven_day\":{\"utilization\":9,\"resets_at\":\"RR7\"},\"extra_usage\":{}}";
  printf "%s" "$good" > "$CLAUDE_USAGE_CACHE";
  fstub="$W/failstub.sh"; printf "%s\n" "#!/usr/bin/env bash" "echo not-json-{{" > "$fstub";
  chmod +x "$fstub"; export USAGE_OAUTH_CMD="$fstub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ "$(cat "$CLAUDE_USAGE_CACHE")" = "$good" ] || exit 1;
  # no leftover temp files in EITHER pattern: PID fallback (.tmp) or mktemp (.XXXXXX -> cache.json.??????)
  ls "$W"/*.tmp >/dev/null 2>&1 && exit 1;
  ls "$W"/cache.json.?????? >/dev/null 2>&1 && exit 1;
  ls "$W"/hud.json.?????? >/dev/null 2>&1 && exit 1;
  exit 0;
'

run_test "(5a) TTL throttle: fresh consumer cache (within USAGE_CACHE_TTL) is NOT rewritten on rates path" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  seed="{\"five_hour\":{\"utilization\":1,\"resets_at\":\"X\"},\"seven_day\":{\"utilization\":1,\"resets_at\":\"Y\"},\"extra_usage\":{}}";
  printf "%s" "$seed" > "$CLAUDE_USAGE_CACHE";
  m1=$(mtime "$CLAUDE_USAGE_CACHE");
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  m2=$(mtime "$CLAUDE_USAGE_CACHE");
  [ "$(cat "$CLAUDE_USAGE_CACHE")" = "$seed" ] || exit 1;
  [ "$m1" = "$m2" ] || exit 1;
'

run_test "(5b) OAuth throttle: fresh oauth_checked_at -> stub NOT invoked (marker absent)" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  now=$(date +%s);
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{\"is_enabled\":true},\"oauth_checked_at\":$now}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh"; export OAUTH_MARKER="$W/marker";
  printf "%s\n" "#!/usr/bin/env bash" ": > \"\$OAUTH_MARKER\"" "echo {}" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ -e "$OAUTH_MARKER" ] && exit 1;
  exit 0;
'

run_test "(5c) OAuth throttle: stale oauth_checked_at -> stub IS invoked (marker present)" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  now=$(date +%s); old=$((now - 4000));
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{\"is_enabled\":true},\"oauth_checked_at\":$old}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh"; export OAUTH_MARKER="$W/marker";
  printf "%s\n" "#!/usr/bin/env bash" ": > \"\$OAUTH_MARKER\"" "echo '"'"'{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":100,\"monthly_limit\":5000}}'"'"'" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ -e "$OAUTH_MARKER" ] || exit 1;
  exit 0;
'

run_test "(6) shape guard: five_hour/seven_day are JSON objects on the no-rates path" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  # no pre-existing cache (prev null); stub returns ONLY extra_usage
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "echo '"'"'{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":10,\"monthly_limit\":100}}'"'"'" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour|type" "$CLAUDE_USAGE_CACHE")" = "object" ] || exit 1;
  [ "$(jq -r ".seven_day|type" "$CLAUDE_USAGE_CACHE")" = "object" ] || exit 1;
'

run_test "(7) static no-spawn: no background/disown in producer" '
  ! grep -Eq "&[[:space:]]*disown|\([^)]*&[[:space:]]*\)" "$PRODUCER";
'

run_test "(8) seven_day-only rate_limits still mirrors (CR codex-1), five_hour preserved from prev" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  # pre-seed with five_hour so the preserve path is observable; make it STALE vs TTL
  printf "%s" "{\"five_hour\":{\"utilization\":33,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":1,\"resets_at\":\"old\"},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  export USAGE_CACHE_TTL=0;
  printf "%s" "{\"rate_limits\":{\"seven_day\":{\"utilization\":21.5,\"resets_at\":\"2026-07-10T00:00:00Z\"}}}" | bash "$PRODUCER";
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "21.5" ] || exit 1;
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "33" ] || exit 1;
'

# --- summary ------------------------------------------------------------------
if [ "$_failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $_failures case(s) failed"
  exit 1
fi
