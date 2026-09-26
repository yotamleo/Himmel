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

run_test "(3) no rate_limits + stubbed OAuth -> fetched primary wins, missing primary falls back, hud gains balance_label" '
  W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  # pre-seed cache with good five_hour/seven_day, NO oauth_checked_at (=> OAuth stale => fetch)
  printf "%s" "{\"five_hour\":{\"utilization\":40,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":8,\"resets_at\":\"R7\"},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "[ -n \"\${OAUTH_MARKER:-}\" ] \&\& : > \"\$OAUTH_MARKER\"" "cat <<JSON" "{\"five_hour\":{\"utilization\":99},\"extra_usage\":{\"is_enabled\":true,\"used_credits\":350,\"monthly_limit\":5000,\"utilization\":7}}" "JSON" > "$stub";
  export OAUTH_MARKER="$W/marker"; chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  # HIMMEL-1841: fetched primaries now WIN (the old order discarded them)
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "99" ] || exit 1;
  # seven_day absent from the fetch -> prev survives via the // $p fallback
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "8" ] || exit 1;
  # Partial primary fetch has no aggregate freshness provenance.
  jq -e ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE" >/dev/null && exit 1;
  # extra_usage merged from fetch
  [ "$(jq -r ".extra_usage.used_credits" "$CLAUDE_USAGE_CACHE")" = "350" ] || exit 1;
  # hud snapshot gains balance_label
  bl=$(jq -r ".balance_label // empty" "$HUD_USAGE_SNAPSHOT"); [ -n "$bl" ] || exit 1;
'

run_test "(3b) HIMMEL-1841: extra_usage-only fetch does NOT stamp primaries_refreshed_at" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-3b.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"extra_usage\":{\"utilization\":7}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "40" ] || exit 1;
  jq -e ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE" >/dev/null && exit 1;
  exit 0;
'

run_test "(3c) HIMMEL-1866: extra_usage-only fetch preserves primaries_refreshed_at" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-3c.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"extra_usage\":{},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"extra_usage\":{\"utilization\":7}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || exit 1;
'

run_test "(3d) HIMMEL-1866: empty fetched window preserves prior utilization" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-3d.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  printf "%s" "{\"five_hour\":{\"utilization\":40},\"seven_day\":{\"utilization\":8},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"model\":{\"display_name\":\"Claude\"}}" | bash "$PRODUCER";
  [ "$(jq -r ".five_hour.utilization" "$CLAUDE_USAGE_CACHE")" = "40" ] || exit 1;
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

run_test "(9) HIMMEL-3364: both stdin windows stamp primaries_refreshed_at=now, and bank-preflight PROCEEDs on the result" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-9.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-9\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  before=$(date +%s);
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":23,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":46,\"resets_at\":\"R7\"}}}" | bash "$PRODUCER";
  stamp=$(jq -r ".primaries_refreshed_at // empty" "$CLAUDE_USAGE_CACHE");
  [ -n "$stamp" ] || exit 1;
  [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$(( $(date +%s) + 1 ))" ] || exit 1;
  noflt="$W/no-fleet-ps.sh"; printf "%s\n" "#!/usr/bin/env bash" "true" > "$noflt"; chmod +x "$noflt";
  v=$(CADENCE_BANK_CACHE="$CLAUDE_USAGE_CACHE" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/ledger.jsonl" \
      CADENCE_BANK_LEG=test3364 FLEET_PS_CMD="$noflt" bash "$STATUSLINE_DIR/../lib/bank-preflight.sh" </dev/null 2>/dev/null | tail -n1);
  [ "$v" = "PROCEED" ] || exit 1;
'

run_test "(9b) HIMMEL-3364: both stdin windows refresh a stale prior stamp" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-9b.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"five_hour\":{\"utilization\":1},\"seven_day\":{\"utilization\":1},\"extra_usage\":{},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"five_hour\":{\"utilization\":23},\"seven_day\":{\"utilization\":46}}}" | bash "$PRODUCER";
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" != "1234567890" ] || exit 1;
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" -gt 1234567890 ] || exit 1;
'

run_test "(9c) HIMMEL-3364: one stdin window carries the prior stamp; with no prior stamp none is invented" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-9c.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"five_hour\":{\"utilization\":33},\"seven_day\":{\"utilization\":1},\"extra_usage\":{},\"primaries_refreshed_at\":1234567890}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"seven_day\":{\"utilization\":21.5}}}" | bash "$PRODUCER";
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "21.5" ] || exit 1;
  [ "$(jq -r ".primaries_refreshed_at" "$CLAUDE_USAGE_CACHE")" = "1234567890" ] || exit 1;
  printf "%s" "{\"five_hour\":{\"utilization\":33},\"seven_day\":{\"utilization\":1},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"rate_limits\":{\"seven_day\":{\"utilization\":21.5}}}" | bash "$PRODUCER";
  jq -e "has(\"primaries_refreshed_at\") | not" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
  exit 0;
'

run_test "(10) HIMMEL-1712: rates path stamps account (16-hex hash, never the raw uuid)/derived_at/produced_by" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-10.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  before=$(date +%s);
  printf "%s" "{\"session_id\":\"sess-10\",\"rate_limits\":{\"five_hour\":{\"utilization\":63.4,\"resets_at\":\"Z\"}}}" | bash "$PRODUCER";
  acct=$(jq -r ".account // empty" "$CLAUDE_USAGE_CACHE"); [ -n "$acct" ] || exit 1;
  [ "$acct" != "uuid-account-A" ] || exit 1;
  [[ "$acct" =~ ^[0-9a-f]{16}$ ]] || exit 1;
  derived=$(jq -r ".derived_at // empty" "$CLAUDE_USAGE_CACHE");
  [ -n "$derived" ] && [ "$derived" -ge "$before" ] || exit 1;
  produced_by=$(jq -r ".produced_by // empty" "$CLAUDE_USAGE_CACHE");
  [[ "$produced_by" =~ ^[0-9]+$ ]] || exit 1;
'

run_test "(11) HIMMEL-1712: oauth path stamps account/derived_at/produced_by too" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-11.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  stub="$W/stub.sh";
  printf "%s\n" "#!/usr/bin/env bash" "cat <<JSON" "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}" "JSON" > "$stub";
  chmod +x "$stub"; export USAGE_OAUTH_CMD="$stub";
  printf "%s" "{\"session_id\":\"sess-11\",\"model\":{}}" | bash "$PRODUCER";
  acct=$(jq -r ".account // empty" "$CLAUDE_USAGE_CACHE"); [ -n "$acct" ] || exit 1;
  [[ "$acct" =~ ^[0-9a-f]{16}$ ]] || exit 1;
  jq -e ".derived_at" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
  jq -e ".produced_by" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
'

run_test "(12) HIMMEL-1712: a session keeps stamping its FIRST-seen identity after ~/.claude.json flips mid-session; a NEW session picks up the current one" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-12.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"session_id\":\"sess-S\",\"rate_limits\":{\"five_hour\":{\"utilization\":10,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  acct_first=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ -n "$acct_first" ] && [ "$acct_first" != "null" ] || exit 1;
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  printf "%s" "{\"session_id\":\"sess-S\",\"rate_limits\":{\"five_hour\":{\"utilization\":11,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  acct_second=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ "$acct_second" = "$acct_first" ] || exit 1;
  printf "%s" "{\"session_id\":\"sess-T\",\"rate_limits\":{\"five_hour\":{\"utilization\":12,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  acct_new_session=$(jq -r ".account" "$CLAUDE_USAGE_CACHE");
  [ "$acct_new_session" != "$acct_first" ] || exit 1;
'

run_test "(13) HIMMEL-1712: no readable ~/.claude.json -> account stamped null (UNKNOWN), never fabricated" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-13.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD;
  printf "%s" "{\"session_id\":\"sess-13\",\"rate_limits\":{\"five_hour\":{\"utilization\":10,\"resets_at\":\"R\"}}}" | bash "$PRODUCER";
  jq -e "has(\"account\")" "$CLAUDE_USAGE_CACHE" >/dev/null || exit 1;
  [ "$(jq -r ".account" "$CLAUDE_USAGE_CACHE")" = "null" ] || exit 1;
'

run_test "(14) HIMMEL-1712 CR (panel round 1, codex-1): a partial window is NOT carried forward from a cache stamped for a DIFFERENT known account" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-14.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-A\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"session_id\":\"sess-A\",\"rate_limits\":{\"five_hour\":{\"utilization\":33,\"resets_at\":\"R5\"}}}" | bash "$PRODUCER";
  acct_a=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct_a" ] && [ "$acct_a" != "null" ] || exit 1;
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-B\"}}" > "$HOME/.claude.json";
  printf "%s" "{\"session_id\":\"sess-B\",\"rate_limits\":{\"seven_day\":{\"utilization\":21.5,\"resets_at\":\"R7\"}}}" | bash "$PRODUCER";
  acct_b=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ "$acct_b" != "$acct_a" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "21.5" ] || exit 1;
  [ "$(jq -r ".five_hour" "$CLAUDE_USAGE_CACHE")" = "{}" ] || exit 1;
'

run_test "(15) HIMMEL-1712 CR (panel round 2, codex-1): a legacy cache with NO account field is not relabeled under a known current identity" '
  W=$(mktemp -d "${TMPDIR:-/tmp}/usage-cache-producer-15.XXXXXX"); export HOME="$W/home"; mkdir -p "$HOME";
  printf "%s" "{\"oauthAccount\":{\"accountUuid\":\"uuid-account-C\"}}" > "$HOME/.claude.json";
  export CLAUDE_USAGE_CACHE="$W/cache.json"; export HUD_USAGE_SNAPSHOT="$W/hud.json";
  unset USAGE_OAUTH_CMD; export USAGE_CACHE_TTL=0;
  printf "%s" "{\"five_hour\":{\"utilization\":33,\"resets_at\":\"R5\"},\"seven_day\":{\"utilization\":1,\"resets_at\":\"old\"},\"extra_usage\":{}}" > "$CLAUDE_USAGE_CACHE";
  printf "%s" "{\"session_id\":\"sess-C\",\"rate_limits\":{\"seven_day\":{\"utilization\":21.5,\"resets_at\":\"R7\"}}}" | bash "$PRODUCER";
  acct=$(jq -r ".account" "$CLAUDE_USAGE_CACHE"); [ -n "$acct" ] && [ "$acct" != "null" ] || exit 1;
  [ "$(jq -r ".seven_day.utilization" "$CLAUDE_USAGE_CACHE")" = "21.5" ] || exit 1;
  [ "$(jq -r ".five_hour" "$CLAUDE_USAGE_CACHE")" = "{}" ] || exit 1;
'

# --- summary ------------------------------------------------------------------
if [ "$_failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $_failures case(s) failed"
  exit 1
fi
