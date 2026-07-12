#!/usr/bin/env bash
# usage-cache-producer.sh — HIMMEL-718 Phase 2 Task 2.1
#
# Single-writer producer for Claude usage state. Invoked ONCE per statusline
# render (no daemon, no loop, no detached spawn). Reads the Claude Code
# statusline stdin JSON and maintains TWO files:
#
#   A. consumer cache  ($CLAUDE_USAGE_CACHE, default /tmp/claude/statusline-usage-cache.json)
#      himmel schema for cap-guards:
#        {"five_hour":{"utilization":<num>,"resets_at":<str>},
#         "seven_day":{...same...},"extra_usage":{...},"oauth_checked_at":<epoch>}
#      five_hour/seven_day are ALWAYS JSON objects (resume-slot shape guard).
#
#   B. hud snapshot    ($HUD_USAGE_SNAPSHOT, default /tmp/claude/hud-usage-snapshot.json)
#      claude-hud externalUsagePath schema:
#        {"updated_at":<iso>,
#         "five_hour":{"used_percentage":<int 0-100>,"resets_at":<str>},
#         "seven_day":{...same 2 keys...},"balance_label":<str, optional>}
#      five_hour/seven_day carry EXACTLY 2 keys (hud write-throttle enforces it).
#
# Branches:
#   * stdin HAS rate_limits -> mirror them into both files (free, no network).
#   * stdin has NO rate_limits -> query the OAuth seam for extra_usage, MERGING
#     it while preserving the existing five_hour/seven_day (never clobber good
#     data with empties).
#
# Throttle (dual TTL, env-tunable):
#   USAGE_CACHE_TTL (300s) — a fresher consumer cache short-circuits the rates
#                            rewrite (no work when nothing changed).
#   USAGE_OAUTH_TTL (3540s) — the OAuth query is skipped when the cache's
#                             extra_usage (oauth_checked_at) is fresher.
#
# Parsing idioms (token resolution, curl headers, atomic tmp+mv, stat mtime,
# object-shape guard) are lifted from scripts/statusline/bin/statusline.sh
# (lines 288-427). Statusline must NEVER break: any failure keeps the previous
# cache intact, emits a stderr WARN, and exits 0.
set -u

CACHE_FILE="${CLAUDE_USAGE_CACHE:-/tmp/claude/statusline-usage-cache.json}"
HUD_FILE="${HUD_USAGE_SNAPSHOT:-/tmp/claude/hud-usage-snapshot.json}"
CACHE_TTL="${USAGE_CACHE_TTL:-300}"
OAUTH_TTL="${USAGE_OAUTH_TTL:-3540}"

command -v jq >/dev/null 2>&1 || { echo "WARN usage-cache-producer: jq not found" >&2; exit 0; }

now_epoch=$(date +%s 2>/dev/null || echo 0)
iso_now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

input=$(cat)

# stat mtime: GNU then BSD (statusline.sh:288 idiom).
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Atomic write: temp file + mv, so a reader never sees a torn file
# (statusline.sh:334-342 idiom). Returns non-zero on any write failure.
write_atomic() {
  local target="$1" content="$2" dir tmp
  dir=$(dirname "$target")
  mkdir -p "$dir" 2>/dev/null
  tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || tmp="${target}.$$.tmp"
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$target" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  else
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}

# Build the hud snapshot from a consumer-cache JSON object ($1). five_hour /
# seven_day carry EXACTLY {used_percentage, resets_at}; used_percentage is the
# clamped, rounded integer of utilization (or used_percentage). balance_label
# is added ONLY when extra_usage has data.
build_hud() {
  local cache="$1" bl="" used limit ex_present
  ex_present=$(printf '%s' "$cache" | jq -r 'if ((.extra_usage // {}) | type=="object") and (((.extra_usage // {}) | length) > 0) then "1" else "" end' 2>/dev/null)
  if [ -n "$ex_present" ]; then
    used=$(printf '%s' "$cache" | jq -r '(.extra_usage.used_credits | tonumber?) // 0' 2>/dev/null)
    limit=$(printf '%s' "$cache" | jq -r '(.extra_usage.monthly_limit | tonumber?) // 0' 2>/dev/null)
    bl=$(awk -v u="${used:-0}" -v l="${limit:-0}" 'BEGIN{printf "$%.2f / $%.2f", u/100, l/100}')
  fi
  printf '%s' "$cache" | jq --arg upd "$iso_now" --arg bl "$bl" '
    (.five_hour // {}) as $fh |
    (.seven_day // {}) as $sd |
    ((($fh.utilization // $fh.used_percentage // 0) | tonumber?) // 0) as $fv |
    ((($sd.utilization // $sd.used_percentage // 0) | tonumber?) // 0) as $sv |
    {
      updated_at: $upd,
      five_hour: {
        used_percentage: ((if $fv < 0 then 0 elif $fv > 100 then 100 else $fv end) | round),
        resets_at: ($fh.resets_at // null)
      },
      seven_day: {
        used_percentage: ((if $sv < 0 then 0 elif $sv > 100 then 100 else $sv end) | round),
        resets_at: ($sd.resets_at // null)
      }
    }
    + (if $bl == "" then {} else { balance_label: $bl } end)
  ' 2>/dev/null
}

# Load the previous consumer cache as a JSON object, or "null". Requires an
# object (statusline.sh:368-374 shape guard) — a bare string/number would make
# the merge a type error.
prev="null"
if [ -f "$CACHE_FILE" ]; then
  prevraw=$(cat "$CACHE_FILE" 2>/dev/null)
  if [ -n "$prevraw" ] && printf '%s' "$prevraw" | jq -e 'type=="object"' >/dev/null 2>&1; then
    prev="$prevraw"
  fi
fi

# stdin rate_limits (utilization, falling back to used_percentage).
stdin_five=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.utilization // .rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
stdin_five_reset=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)
stdin_seven=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.utilization // .rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
stdin_seven_reset=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

# ── Branch A: stdin carries rate_limits — mirror into both files ─────────────
# Either window qualifies (CR codex-1: a seven_day-only payload must still be
# mirrored, not dropped to the OAuth branch).
if [ -n "$stdin_five" ] || [ -n "$stdin_seven" ]; then
  # Throttle: a fresh-enough consumer cache short-circuits the rewrite.
  if [ -f "$CACHE_FILE" ]; then
    age=$(( now_epoch - $(file_mtime "$CACHE_FILE") ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL" ]; then
      exit 0
    fi
  fi

  new_cache=$(jq -n --argjson prev "$prev" \
    --arg fh "$stdin_five" --arg fhr "$stdin_five_reset" \
    --arg sh "$stdin_seven" --arg shr "$stdin_seven_reset" '
    ($prev // {}) as $p |
    {
      five_hour: (if $fh == "" then ($p.five_hour // {})
                  else { utilization: ($fh | tonumber? // null),
                         resets_at: (if $fhr == "" then null else $fhr end) } end),
      seven_day: (if $sh == "" then ($p.seven_day // {})
                  else { utilization: ($sh | tonumber? // null),
                         resets_at: (if $shr == "" then null else $shr end) } end),
      extra_usage: ($p.extra_usage // {}),
      oauth_checked_at: ($p.oauth_checked_at // null)
    }' 2>/dev/null)

  if [ -z "$new_cache" ]; then
    echo "WARN usage-cache-producer: failed to build cache from stdin rates" >&2
    exit 0
  fi

  hud=$(build_hud "$new_cache")
  if write_atomic "$CACHE_FILE" "$new_cache"; then
    [ -n "$hud" ] && write_atomic "$HUD_FILE" "$hud"
  else
    echo "WARN usage-cache-producer: consumer-cache write failed (rates path)" >&2
  fi
  exit 0
fi

# ── Branch B: no stdin rate_limits — query the OAuth seam for extra_usage ────
# Throttle: skip the network entirely while the cached extra_usage is fresh.
oauth_at=$(printf '%s' "$prev" | jq -r '.oauth_checked_at // empty' 2>/dev/null)
if printf '%s' "$oauth_at" | grep -Eq '^[0-9]+$'; then
  oage=$(( now_epoch - oauth_at ))
  if [ "$oage" -ge 0 ] && [ "$oage" -lt "$OAUTH_TTL" ]; then
    exit 0
  fi
fi

fetched=""
if [ -n "${USAGE_OAUTH_CMD:-}" ]; then
  # Seam: a PATH to an executable (fixture stub in tests). Executed directly —
  # never eval'd — so shell metacharacters in the env value cannot inject
  # commands into the statusline render path (CR qwen3coder-1/codex-11).
  # No arguments supported: the value is a single argv[0]; wrap args in a
  # script. A non-executable/missing path fails into the WARN-keep-cache path.
  fetched=$("$USAGE_OAUTH_CMD" 2>/dev/null)
else
  # Real default: OAuth Bearer (env, else credentials file) against the usage
  # endpoint (statusline.sh:299-329 idiom).
  token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    creds="$HOME/.claude/.credentials.json"
    [ -f "$creds" ] && token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null)
  fi
  if [ -n "$token" ] && [ "$token" != "null" ]; then
    fetched=$(curl -sf --max-time 5 \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
  fi
fi

if [ -z "$fetched" ] || ! printf '%s' "$fetched" | jq -e 'type=="object"' >/dev/null 2>&1; then
  echo "WARN usage-cache-producer: usage fetch failed; keeping previous cache" >&2
  exit 0
fi

# Merge: preserve prior five_hour/seven_day (fall back to fetched, then {}),
# take extra_usage from the fetch, stamp oauth_checked_at.
new_cache=$(jq -n --argjson prev "$prev" --argjson f "$fetched" --argjson ts "$now_epoch" '
  ($prev // {}) as $p |
  ($f // {}) as $ff |
  {
    five_hour: ($p.five_hour // $ff.five_hour // {}),
    seven_day: ($p.seven_day // $ff.seven_day // {}),
    extra_usage: ($ff.extra_usage // $p.extra_usage // {}),
    oauth_checked_at: $ts
  }' 2>/dev/null)

if [ -z "$new_cache" ]; then
  echo "WARN usage-cache-producer: failed to merge fetched usage; keeping previous cache" >&2
  exit 0
fi

hud=$(build_hud "$new_cache")
if write_atomic "$CACHE_FILE" "$new_cache"; then
  [ -n "$hud" ] && write_atomic "$HUD_FILE" "$hud"
else
  echo "WARN usage-cache-producer: consumer-cache write failed (oauth path)" >&2
fi
exit 0
