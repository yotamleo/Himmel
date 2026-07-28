#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# Everything below parses the stdin JSON with jq. Without jq the bar would
# render near-blank (every extraction silently yields empty). Degrade VISIBLY
# instead of silently so a missing dependency is obvious. (HIMMEL-612)
if ! command -v jq >/dev/null 2>&1; then
    printf 'Claude \033[38;2;255;176;85m⚠ statusline degraded: jq not found\033[0m'
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(LC_ALL=C date -j -r "$epoch" +"%l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(LC_ALL=C date -d "@$epoch" +"%l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(LC_ALL=C date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(LC_ALL=C date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(LC_ALL=C date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(LC_ALL=C date -d "@$epoch" +"%b %-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

epoch_to_iso() {
    local epoch="$1"
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
        # Pass through only if it already looks ISO-shaped; anything else
        # (fractional epochs, garbage) would leak a non-ISO resets_at into
        # the cache schema — emit nothing so the caller stores null.
        [[ "$epoch" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && printf "%s" "$epoch"
        return
    fi

    local iso
    iso=$(date -u -d "@${epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    [ -z "$iso" ] && iso=$(date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    printf "%s" "$iso"
}

# Append a one-line failure breadcrumb to the debug log. Capped at ~100KB
# (truncate-on-overflow) because the failure modes it logs repeat every
# render — a stuck mv on the shared cache must not fill /tmp over a long
# session. Known blind spot: if /tmp/claude itself is unwritable, the
# cache write AND this breadcrumb vanish together — there is nowhere
# else for a statusline to report, so the log is not a complete record.
cache_breadcrumb() {
    local log="/tmp/claude/statusline-debug.log"
    [ -f "$log" ] && [ "$(wc -c < "$log" 2>/dev/null || echo 0)" -gt 100000 ] && : > "$log"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) cache-write failed: $1" >> "$log" 2>/dev/null
}

# ── Extract JSON data ───────────────────────────────────
# Pull EVERY stdin field in ONE jq pass (was ~14 separate `echo|jq` pipes).
# On Windows/MSYS each process spawn costs ~1-2s, so collapsing the per-render
# fork storm here is the dominant render-latency win (HIMMEL-612). Fields are
# joined with US (\x1f, unit separator): a NON-whitespace delimiter so `read`
# preserves empty fields (a whitespace IFS like tab coalesces runs of the
# delimiter, which would shift every field after an empty one). \x1f never
# occurs in the JSON values; all fields carry a default so no null reaches it.
US=$'\037'
IFS="$US" read -r model_name model_id transcript_path session_cost \
    size input_tokens cache_create cache_read cwd session_start \
    b_five_pct b_five_reset b_seven_pct b_seven_reset <<EOF
$(printf '%s' "$input" | jq -r --arg sep "$US" '
    [ (.model.display_name // "Claude"),
      (.model.id // "claude-sonnet"),
      (.transcript_path // ""),
      (.cost.total_cost_usd // ""),
      (.context_window.context_window_size // 200000),
      (.context_window.current_usage.input_tokens // 0),
      (.context_window.current_usage.cache_creation_input_tokens // 0),
      (.context_window.current_usage.cache_read_input_tokens // 0),
      (.cwd // ""),
      (.session.start_time // ""),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // "")
    ] | map(tostring) | join($sep)' 2>/dev/null)
EOF

[ -n "$model_name" ] || model_name="Claude"
[ -n "$model_id" ] || model_id="claude-sonnet"
[ -n "$size" ] || size=200000
[ "$size" -eq 0 ] 2>/dev/null && size=200000
[ -n "$input_tokens" ] || input_tokens=0
[ -n "$cache_create" ] || cache_create=0
[ -n "$cache_read" ] || cache_read=0
current=$(( input_tokens + cache_create + cache_read ))

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

effort="default"
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Effort ──
pct_color=$(color_for_pct "$pct_used")
# cwd extracted in the batched jq read above.
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
# session_start extracted in the batched jq read above.
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

skip_perms=""
parent_cmd=$(ps -o args= -p "$PPID" 2>/dev/null)
if [[ "$parent_cmd" == *"--dangerously-skip-permissions"* ]]; then
    skip_perms="⚡  "
fi

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="✍️ ctx ${pct_color}${pct_used}%${reset}"
line1+="${sep}"
line1+="${skip_perms}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line1+="${sep}"
case "$effort" in
    high)   line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# ── Rate limits from stdin (primary) ───────────────────
has_stdin_rates=false
five_hour_pct=""
five_hour_reset_epoch=""
seven_day_pct=""
seven_day_reset_epoch=""

# Rate-limit fields come from the batched jq read above (b_* vars).
stdin_five_pct="$b_five_pct"
stdin_seven_pct=""
if [ -n "$stdin_five_pct" ]; then
    has_stdin_rates=true
    five_hour_pct=$(printf "%.0f" "$stdin_five_pct")
    five_hour_reset_epoch="$b_five_reset"
    stdin_seven_pct="$b_seven_pct"
    seven_day_pct=$(printf "%s" "$stdin_seven_pct" | awk '{printf "%.0f", $1}')
    seven_day_reset_epoch="$b_seven_reset"
fi

# ── Fallback: API call (cached) ────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
mkdir -p /tmp/claude

usage_data=""
extra_enabled="false"

if ! $has_stdin_rates; then
    needs_refresh=true

    if [ -f "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        if [ "$cache_age" -lt "$cache_max_age" ]; then
            needs_refresh=false
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi

    if $needs_refresh; then
        token=""
        if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
            token="$CLAUDE_CODE_OAUTH_TOKEN"
        elif command -v security >/dev/null 2>&1; then
            blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            if [ -n "$blob" ]; then
                token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            creds_file="${HOME}/.claude/.credentials.json"
            if [ -f "$creds_file" ]; then
                token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            if command -v secret-tool >/dev/null 2>&1; then
                blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
                if [ -n "$blob" ]; then
                    token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
                fi
            fi
        fi

        if [ -n "$token" ] && [ "$token" != "null" ]; then
            response=$(curl -s --max-time 5 \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.34" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
                usage_data="$response"
                # Atomic tmp+mv — a reader hitting a torn write would treat
                # the cache as corrupt and silently drop extra_usage.
                tmp_cache="${cache_file}.$$.tmp"
                api_write_fail=""
                if echo "$response" > "$tmp_cache" 2>/dev/null; then
                    mv -f "$tmp_cache" "$cache_file" 2>/dev/null \
                        || { rm -f "$tmp_cache" 2>/dev/null; api_write_fail="api-mv"; }
                else
                    rm -f "$tmp_cache" 2>/dev/null
                    api_write_fail="api-tmp-write"
                fi
                [ -n "$api_write_fail" ] && cache_breadcrumb "$api_write_fail"
            fi
        fi
        if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi

    if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
        five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
        five_hour_reset_epoch=$(iso_to_epoch "$five_hour_reset_iso")
        seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
        seven_day_reset_epoch=$(iso_to_epoch "$seven_day_reset_iso")

        extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    fi
else
    if [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
        # Require an object, not just valid JSON — a bare string/number/array
        # would make the ($prev // {}) + {} merge below a type error on every
        # render, freezing the cache permanently. Object-check + is_enabled in
        # ONE jq pass (was two echo|jq pipes; HIMMEL-612).
        if [ -n "$usage_data" ]; then
            extra_enabled=$(printf '%s' "$usage_data" \
                | jq -r 'if type == "object" then (.extra_usage.is_enabled // false | tostring) else "__notobj__" end' 2>/dev/null)
            if [ "$extra_enabled" = "__notobj__" ] || [ -z "$extra_enabled" ]; then
                usage_data=""
                extra_enabled="false"
            fi
        fi
    fi

    # Keep the cache fresh from stdin rates. During live sessions stdin
    # carries rate_limits, so the API branch above never runs — without
    # this write the cache freezes at its last pre-session value for the
    # whole session (external consumers read this file). Same schema as
    # the API response (utilization + ISO resets_at), same 60s throttle,
    # atomic tmp+mv so concurrent sessions never leave a torn file.
    needs_refresh=true
    if [ -f "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        [ "$cache_age" -lt "$cache_max_age" ] && needs_refresh=false
    fi

    if $needs_refresh; then
        five_hour_reset_iso=$(epoch_to_iso "$five_hour_reset_epoch")
        seven_day_reset_iso=$(epoch_to_iso "$seven_day_reset_epoch")
        # Per-field tonumber? guards: one malformed field (e.g. "63%") must
        # degrade to null, not abort the whole jq program and lose the write.
        stdin_cache=$(jq -n \
            --argjson prev "${usage_data:-null}" \
            --arg fh_util "$stdin_five_pct" \
            --arg fh_reset "$five_hour_reset_iso" \
            --arg sd_util "$stdin_seven_pct" \
            --arg sd_reset "$seven_day_reset_iso" \
            '($prev // {}) +
             { five_hour: { utilization: ($fh_util | tonumber? // null),
                            resets_at: (if $fh_reset == "" then null else $fh_reset end) } } +
             (if $sd_util == "" then {} else
               { seven_day: { utilization: ($sd_util | tonumber? // null),
                              resets_at: (if $sd_reset == "" then null else $sd_reset end) } } end)' \
            2>/dev/null)
        write_fail=""
        if [ -n "$stdin_cache" ]; then
            tmp_cache="${cache_file}.$$.tmp"
            if echo "$stdin_cache" > "$tmp_cache" 2>/dev/null; then
                mv -f "$tmp_cache" "$cache_file" 2>/dev/null \
                    || { rm -f "$tmp_cache" 2>/dev/null; write_fail="mv"; }
            else
                rm -f "$tmp_cache" 2>/dev/null
                write_fail="tmp-write"
            fi
        else
            write_fail="jq-build"
        fi
        # Breadcrumb on failure — otherwise "no write" here is field-
        # indistinguishable from the frozen-cache bug this branch fixes.
        [ -n "$write_fail" ] && cache_breadcrumb "stdin-${write_fail}"
    fi
fi

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
cache_lines=""
bar_width=10

if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    rate_lines+="${white}5h bank${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}7d bank${reset} ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}"
    [ -n "$seven_day_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${seven_day_reset}${reset}"
fi

if [ "$extra_enabled" = "true" ] && [ -n "$usage_data" ]; then
    extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
    extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
    extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
    extra_bar=$(build_bar "$extra_pct" "$bar_width")
    extra_pct_color=$(color_for_pct "$extra_pct")

    extra_reset=$(LC_ALL=C date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$extra_reset" ]; then
        extra_reset=$(LC_ALL=C date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}⟳${reset} ${white}${extra_reset}${reset}"
fi

# ── Cache metrics functions ──────────────────────────────
# ── Dual-logging dedup, shared jq prelude (HIMMEL-1300) ─────────────────────
# Claude Code writes the same API response into the transcript 2-3 times, so a
# naive per-row sum over-counts 1.9x-3.3x. Mirrors claude-hud transcript.ts
# (457-490): primary key message.id (non-empty string <= 128 chars) against a
# bounded FIFO seen-set (cap 4096, evict-oldest); a row with a missing/invalid
# id falls back to its usage fingerprint vs the IMMEDIATELY PREVIOUS row and
# counts only on change; the fallback key resets on EVERY non-assistant /
# non-usage row. That reset is why the scan runs over the UNFILTERED row
# stream — pre-filtering destroys adjacency and would merge two distinct
# id-less messages. foreach (a reduce that also emits), never group_by /
# unique_by: those reorder the stream, which the consecutive fingerprint
# cannot survive. dedup_usage emits one compact {t,r,w,i,o} record per COUNTED
# message; sum4 folds them into [reads, writes, inputs, outputs]. A WINDOWED
# caller filters the winners on .t between the two — dedup first, then window;
# UNWINDOWED callers apply no timestamp filter at all (rows legitimately carry
# no .timestamp, and filtering them would zero the total).
_HUD_DEDUP_JQ='
def normcount:
  if type != "number" then 0
  elif (isnan or isinfinite) then 0
  else (floor as $f | if $f < 0 then 0 else $f end)
  end;
def normid:
  if (type == "string") and (length > 0) and (length <= 128) then . else null end;
def fp:
  [.input_tokens, .output_tokens, .cache_creation_input_tokens, .cache_read_input_tokens]
  | map(if . == null then "null" else tostring end) | join("|");
def dedup_usage:
  [ foreach .[] as $msg (
      { seen: {}, queue: [], lastKey: null, hit: false };
      if ($msg.type == "assistant") and ($msg.message.usage != null) then
        ($msg.message.id | normid) as $mid
        | if $mid != null then
            ( if (.seen[$mid] // false) then .hit = false
              else ( if (.queue | length) >= 4096
                     then (.queue[0]) as $old | .seen |= del(.[$old]) | .queue |= .[1:]
                     else . end )
                   | .seen[$mid] = true | .queue += [$mid] | .hit = true
              end )
            | .lastKey = null
          else
            ($msg.message.usage | fp) as $f
            | .hit = ($f != .lastKey) | .lastKey = $f
          end
      else .hit = false | .lastKey = null
      end;
      if .hit then
        { t: ($msg.timestamp // ""),
          r: ($msg.message.usage.cache_read_input_tokens     | normcount),
          w: ($msg.message.usage.cache_creation_input_tokens | normcount),
          i: ($msg.message.usage.input_tokens                | normcount),
          o: ($msg.message.usage.output_tokens               | normcount) }
      else empty end ) ];
def sum4:
  [ ([.[].r] | add // 0), ([.[].w] | add // 0),
    ([.[].i] | add // 0), ([.[].o] | add // 0) ];
'
format_tokens() {
    local n="${1:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if   [ "$n" -ge 1000000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fB", n/1000000000}'
    elif [ "$n" -ge 1000000 ];    then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
    elif [ "$n" -ge 1000 ];       then awk -v n="$n" 'BEGIN{printf "%.0fk", n/1000}'
    else printf "%s" "$n"
    fi
}
# Humanize a positive USD amount for readability: K/M/B once it reaches $1000,
# else the caller's raw %.4f (so sub-$1000 displays — and the byte-exact golden
# fixture — are unchanged). Returns the number WITHOUT a leading $ (the caller
# adds it). Callers pass an already-absolute value; sign is handled separately.
format_usd() {
    local n="${1:-0}"
    awk -v n="$n" 'BEGIN{
        if      (n >= 1000000000) printf "%.1fB", n/1000000000;
        else if (n >= 1000000)    printf "%.1fM", n/1000000;
        else if (n >= 1000)       printf "%.1fK", n/1000;
        else                      printf "%.4f", n;
    }'
}
# Sets read_savings_rate and write_overhead_rate (USD per token, float)
get_model_savings_rate() {
    local model_id="${1:-claude-sonnet}"
    local input_price cache_read_price cache_write_price
    # Rates per 1M tokens. Cache convention: read = 0.1x input, write = 2x
    # input (1h TTL; 5m write = 1.25x). Cache rows derived from the standard
    # prompt-caching multipliers. Case ORDER matters: higher-priced /
    # more-specific globs must precede glm/gpt/default so they win.
    case "$model_id" in
        claude-fable*)  input_price=10.00; cache_read_price=1.00;  cache_write_price=20.00 ;; # 1h; 5m=12.50
        claude-mythos*) input_price=10.00; cache_read_price=1.00;  cache_write_price=20.00 ;; # 1h; 5m=12.50
        claude-opus*)   input_price=5.00;  cache_read_price=0.50;  cache_write_price=10.00 ;; # 1h; 5m=6.25
        claude-haiku*)  input_price=1.00;  cache_read_price=0.10;  cache_write_price=2.00  ;; # 1h; 5m=1.25
        claude-sonnet*) input_price=3.00;  cache_read_price=0.30;  cache_write_price=6.00  ;; # 1h; 5m=3.75
        glm-*)          input_price=1.40;  cache_read_price=0.26;  cache_write_price=1.40  ;; # z.ai promo: free cache-write, write_overhead 0
        gpt-5*)         input_price=5.00;  cache_read_price=0.50;  cache_write_price=5.00  ;; # gpt-5.5 standard tier: no write premium, write_overhead 0
        *)              input_price=3.00;  cache_read_price=0.30;  cache_write_price=6.00  ;;
    esac
    read_savings_rate=$(awk  -v i="$input_price" -v r="$cache_read_price"  'BEGIN{printf "%.8f",(i-r)/1000000}')
    write_overhead_rate=$(awk -v w="$cache_write_price" -v i="$input_price" 'BEGIN{printf "%.8f",(w-i)/1000000}')
}
# Sets cache_ttl_str (e.g. "47m12s", "expired", "") and cache_ttl_pct (0-100)
# Args: $1=last_write_iso  $2=ttl_seconds (300 for 5m-cache, 3600 for 1h-cache)
compute_cache_ttl() {
    local last_write_iso="$1" ttl_seconds="$2"
    cache_ttl_str=""; cache_ttl_pct=0
    [ -z "$last_write_iso" ] || [ "$last_write_iso" = "null" ] && return

    local write_epoch now elapsed remaining
    write_epoch=$(iso_to_epoch "$last_write_iso") || return
    [ -z "$write_epoch" ] && return

    now=$(date +%s)
    elapsed=$(( now - write_epoch ))
    remaining=$(( ttl_seconds - elapsed ))

    if [ "$remaining" -le 0 ]; then
        cache_ttl_str="expired"; cache_ttl_pct=0; return
    fi

    cache_ttl_pct=$(( remaining * 100 / ttl_seconds ))
    [ "$cache_ttl_pct" -gt 100 ] && cache_ttl_pct=100

    local h=$(( remaining / 3600 ))
    local m=$(( (remaining % 3600) / 60 ))
    local s=$(( remaining % 60 ))

    if   [ "$h" -gt 0 ]; then cache_ttl_str=$(printf "%dh%02dm%02ds" "$h" "$m" "$s")
    elif [ "$m" -gt 0 ]; then cache_ttl_str=$(printf "%dm%02ds" "$m" "$s")
    else                       cache_ttl_str=$(printf "%ds" "$s")
    fi
}
# Renders one cache-TTL row (label + bar + remaining) as a string ending in a
# literal "\n", for the caller to accumulate and emit via printf %b.
# Args: $1=label  $2=ttl_str ("expired" | "47m12s" | "")  $3=ttl_pct (0-100)
format_ttl_line() {
    local lbl="$1" ttl_str="$2" ttl_pct="$3"
    if [ "$ttl_str" = "expired" ]; then
        printf '%s' "${white}${lbl}${reset} $(build_bar 0 10) ${red}expired${reset}\n"
    elif [ -n "$ttl_str" ]; then
        local pct_color ttl_filled ttl_empty ttl_fs="" ttl_es="" ttl_i
        pct_color=$(color_for_pct $(( 100 - ttl_pct )))
        ttl_filled=$(( ttl_pct * 10 / 100 ))
        ttl_empty=$(( 10 - ttl_filled ))
        for (( ttl_i=0; ttl_i<ttl_filled; ttl_i++ )); do ttl_fs+="●"; done
        for (( ttl_i=0; ttl_i<ttl_empty;  ttl_i++ )); do ttl_es+="○"; done
        printf '%s' "${white}${lbl}${reset} ${pct_color}${ttl_fs}${dim}${ttl_es}${reset} ${pct_color}${ttl_str}${reset}\n"
    fi
}
# Reads session cache stats from transcript JSONL.
# Sets: sess_reads sess_writes sess_inputs sess_outputs last_5m_iso last_1h_iso
read_session_cache_stats() {
    local transcript="$1"
    sess_reads=0; sess_writes=0; sess_inputs=0; sess_outputs=0; last_5m_iso=""; last_1h_iso=""
    [ -z "$transcript" ] || [ ! -f "$transcript" ] && return

    # One jq pass joining on US \x1f (was a slurp + 5 echo|jq extractions;
    # HIMMEL-612). US is non-whitespace so `read` preserves empty timestamp
    # fields instead of coalescing them (a tab IFS would shift columns when
    # last_5m is empty but last_1h is set).
    # The four token sums are DEDUPED (_HUD_DEDUP_JQ, HIMMEL-1300) and, being an
    # unwindowed site, carry no timestamp filter. The two TTL timestamps stay on
    # the raw row stream — "the last write of tier X" is unaffected by dedup.
    local stats US=$'\037'
    stats=$(jq -rs --arg sep "$US" "$_HUD_DEDUP_JQ"'
        ((dedup_usage | sum4) + [
            ([.[] | select(.type == "assistant" and ((.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) > 0))] | last | .timestamp // ""),
            ([.[] | select(.type == "assistant" and ((.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) > 0))] | last | .timestamp // "")
        ]) | map(tostring) | join($sep)' "$transcript" 2>/dev/null) || return
    [ -n "$stats" ] || return

    IFS="$US" read -r sess_reads sess_writes sess_inputs sess_outputs last_5m_iso last_1h_iso <<EOF
$stats
EOF
    [ -n "$sess_reads" ]   || sess_reads=0
    [ -n "$sess_writes" ]  || sess_writes=0
    [ -n "$sess_inputs" ]  || sess_inputs=0
    [ -n "$sess_outputs" ] || sess_outputs=0
}
# Resolves the bottom cache-row aggregation window for a period. Sets, in the
# CALLER's scope: window_id, window_start (inclusive epoch), window_end
# (exclusive epoch).
#   - all   → window_id "all-stats", unbounded. This keeps the legacy cache
#             filenames (cache-all-stats{,-index}.json) byte-for-byte, so the
#             default path and any external consumer are untouched.
#   - week  → ISO Monday-start (local), 7-day span.
#   - month → calendar month (local), 1st 00:00 to next 1st 00:00.
#   - invalid → falls back to all + a one-line stderr warning.
# `now` is overridable via HIMMEL_STATUSLINE_NOW (epoch) so a test can cross a
# week/month boundary without faking the wall clock (the script otherwise has
# no seam — it calls `date +%s` inline). The per-window filenames also give the
# boundary reset for free: a new window_id is a new file → cache miss → rebuild.
resolve_window() {
    local period="$1"
    local now="${HIMMEL_STATUSLINE_NOW:-$(date +%s)}"
    case "$period" in
        week)
            local dow ymd midnight
            dow=$(date -d "@$now" +%u 2>/dev/null || date -r "$now" +%u 2>/dev/null || echo 1)
            ymd=$(date -d "@$now" +%Y-%m-%d 2>/dev/null || date -r "$now" +%Y-%m-%d 2>/dev/null)
            midnight=$(date -d "$ymd 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ymd 00:00:00" +%s 2>/dev/null)
            window_start=$(( midnight - (dow - 1) * 86400 ))
            window_end=$(( window_start + 7 * 86400 ))
            window_id="week-$(date -d "@$window_start" +%Y%m%d 2>/dev/null || date -r "$window_start" +%Y%m%d 2>/dev/null)"
            ;;
        month)
            local ym nextym
            ym=$(date -d "@$now" +%Y-%m 2>/dev/null || date -r "$now" +%Y-%m 2>/dev/null)
            window_start=$(date -d "$ym-01 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ym-01 00:00:00" +%s 2>/dev/null)
            # Resolve the NEXT month's label first, then re-parse a clean local
            # midnight for the end — adding "+1 month" to a datetime can drift an
            # hour on some date(1) builds, so we never use it as an epoch directly.
            nextym=$(date -d "$ym-01 00:00:00 +1 month" +%Y-%m 2>/dev/null || date -j -v+1m -f "%Y-%m-%d %H:%M:%S" "$ym-01 00:00:00" +%Y-%m 2>/dev/null)
            window_end=$(date -d "$nextym-01 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$nextym-01 00:00:00" +%s 2>/dev/null)
            window_id="month-${ym/-/}"
            ;;
        all)
            window_id="all-stats"; window_start=0; window_end=9999999999
            ;;
        *)
            echo "statusline: invalid HIMMEL_STATUSLINE_PERIOD='$period'; falling back to all" >&2
            window_id="all-stats"; window_start=0; window_end=9999999999
            ;;
    esac
}
# Removes every temp file the current rebuild pass registered in
# $_HUD_RB_TMPFILES (newline-separated; empty entries skipped) and clears the
# register. Called on every exit path of rebuild_all_sessions_index — and, per
# HIMMEL-1300 R3-4, ALSO from the periodic hook's kill-path trap, because a hook
# timeout-kill never reaches the rebuild's own cleanup and would otherwise leave
# three mktemps per killed pass behind (kills are the NORMAL termination mode
# while the index heals).
_hud_rb_rmtemps() {
    local _t
    [ -n "${_HUD_RB_TMPFILES:-}" ] || return 0
    while IFS= read -r _t; do
        [ -n "$_t" ] && rm -f "$_t" 2>/dev/null
    done <<EOF
$_HUD_RB_TMPFILES
EOF
    _HUD_RB_TMPFILES=""
    return 0
}
# Assembles + atomically publishes BOTH the per-file index ($2) and the totals
# cache ($1) from the CALLER's $recomputed via the caller's $tmp_old/$tmp_all/
# $tmp_rc transport (bash dynamic scoping — those strings run to hundreds of KB
# and must never cross an argv boundary).
# Args: $1=cache_file  $2=index_file  $3=ref_file ("" when none).
#
# HIMMEL-1300 R3-5: hoisted out of rebuild_all_sessions_index's tail so it can
# run every N files as a CHECKPOINT, not only once at the end. A pass killed by
# the hook timeout previously wrote NOTHING, so on a history whose full scan
# cannot finish inside the timeout, progress was zero forever. It publishes BOTH
# files on purpose: an index-only checkpoint would leave the totals (and
# `pending`) frozen exactly while the index churns. Mid-pass totals are as valid
# as terminal ones — the reduce carries $oldidx forward for unprocessed files.
#
# HIMMEL-1300 R3-1: after each publish the index mtime is pinned BACK to the
# pass-start reference. The next pass's recompute set is `find -newer
# "$index_file"`, so an advancing mtime would make a file that is (a) already
# v-current, (b) modified during this pass and (c) not yet reached when the pass
# is killed invisible to every later pass — neither -newer, nor missing, nor
# stale-schema — freezing it at its pre-modification sums indefinitely. Pinning
# is conservative: such a file is merely re-scanned once.
# shellcheck disable=SC2154  # $recomputed/$tmp_old/$tmp_all/$tmp_rc are the
# caller's locals, visible here by bash dynamic scoping (see above).
_hud_write_index_checkpoint() {
    local cache_file="$1" index_file="$2" ref_file="$3"
    local out tmp
    printf '%s' "$recomputed" > "$tmp_rc"

    # Entry schema v2 (HIMMEL-1300): { reads, writes, inputs, outputs, v }
    # (+ `attempts` while a file is failing). `outputs` rides THIS bump on
    # purpose — adding it later would force a v3 and a second full re-migration.
    # `pending` (R3-5 / §3.5) counts the work still owed: paths with no entry at
    # all, plus carried entries whose `v` is not current — EXCLUDING the v:-1
    # permanently-parked failures, which is what lets the composer's `all~`
    # marker eventually disappear.
    out=$(jq -n --rawfile old "$tmp_old" --rawfile allp "$tmp_all" --rawfile recomp "$tmp_rc" '
        2 as $schema
        | 3 as $maxattempts
        | ($old | fromjson? // {}) as $oldidx
        | ($recomp | split("\n") | map(select(length > 0) | split("\t"))
            | map(if (length >= 5)
                  then { key: .[0], value: { ok: true,
                                             reads:   (.[1] | tonumber? // 0),
                                             writes:  (.[2] | tonumber? // 0),
                                             inputs:  (.[3] | tonumber? // 0),
                                             outputs: (.[4] | tonumber? // 0) } }
                  else { key: .[0], value: { ok: false } }
                  end)
            | from_entries) as $rc
        | ($allp | split("\n") | map(select(length > 0))) as $files
        | reduce $files[] as $p
            ({ index: {}, reads: 0, writes: 0, inputs: 0, outputs: 0, pending: 0 };
             ($oldidx[$p] // null) as $o
             | ($rc[$p] // null) as $r
             | (if $r == null then
                  # Untouched this pass: carry the old entry (and its v) forward.
                  (if $o == null then null
                   else { reads:   ($o.reads   // 0), writes:  ($o.writes  // 0),
                          inputs:  ($o.inputs  // 0), outputs: ($o.outputs // 0),
                          v: ($o.v // 1) }
                        + (if ($o.attempts // 0) > 0 then { attempts: $o.attempts } else {} end)
                   end)
                elif ($r.ok) then
                  # Success: stamp the current schema, clear any attempt count.
                  { reads: $r.reads, writes: $r.writes, inputs: $r.inputs,
                    outputs: $r.outputs, v: $schema }
                else
                  # Failure sentinel: old sums (zeros if never indexed), one more
                  # attempt, and NO current v — so the known-set filter keeps
                  # retrying it. After $maxattempts consecutive failures park it
                  # at v:-1: known (never re-enters the recompute set) but flagged.
                  { reads:   ($o.reads   // 0), writes:  ($o.writes  // 0),
                    inputs:  ($o.inputs  // 0), outputs: ($o.outputs // 0),
                    attempts: (($o.attempts // 0) + 1) }
                  | if .attempts >= $maxattempts then . + { v: -1 } else . end
                end) as $e
             | if $e == null then .pending += 1
               else .index[$p] = $e
                  | .reads   += $e.reads
                  | .writes  += $e.writes
                  | .inputs  += $e.inputs
                  | .outputs += $e.outputs
                  | (($e.v // 1) as $ev
                     | if $ev == $schema or $ev == -1 then . else .pending += 1 end)
               end)' 2>/dev/null)
    [ -z "$out" ] && return 0

    # Atomic tmp+mv so a concurrent reader never sees a torn file.
    tmp="${index_file}.$$.tmp"
    if echo "$out" | jq -c '.index' > "$tmp" 2>/dev/null; then
        if mv -f "$tmp" "$index_file" 2>/dev/null; then
            # R3-1 mtime pin — see the header. Best-effort: a touch(1) without
            # -r just leaves the natural (later) mtime, i.e. today's behaviour.
            [ -n "$ref_file" ] && touch -r "$ref_file" "$index_file" 2>/dev/null
        else
            rm -f "$tmp" 2>/dev/null
        fi
    else
        rm -f "$tmp" 2>/dev/null
    fi
    tmp="${cache_file}.$$.tmp"
    if echo "$out" | jq -c '{ reads, writes, inputs, outputs, pending }' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}
# Rebuilds the all-sessions cache incrementally. Sets nothing; writes totals
# to $2 (cache_file) and a per-file sums index to $3 (index_file), atomically.
# Optional $4/$5 (win_start/win_end epochs) switch on WINDOWED mode: files whose
# mtime predates win_start are dropped (they can hold no in-window messages —
# bounds the scan), and surviving files are re-summed per-message on
# `.timestamp ∈ [win_start,win_end)`. Per-window-id per-file sums are still
# immutable (a fixed week/month + an unchanged file = a fixed sum), so the same
# `-newer` memoization stays valid within a window. With no win args the path is
# the legacy unbounded immutable-per-file index, byte-identical to before.
#
# Why this is not a one-line glob: the old version ran
#   cat "$HOME/.claude/projects"/*/*.jsonl | timeout 10 jq -s ...
# which has two fatal flaws once a few hundred sessions accumulate:
#   1. The glob expands to hundreds of paths — on Windows/MSYS that overflows
#      the ~32KB argv limit, so `cat` dies with "Argument list too long",
#      stderr is swallowed, jq slurps empty input, and every field sums to 0
#      (the "all = 0" bug).
#   2. Even on Linux/macOS it re-reads the entire, ever-growing history (100s
#      of MB) every refresh — far slower than the 10s timeout, which then
#      kills it and again writes 0.
# This version scans with `find` (streams, no argv limit), recomputes only the
# files changed since the last index (`-newer`), and memoizes per-file sums so
# steady-state refreshes touch just the active session. All bulk data flows
# through temp files / stdin, never jq args, to stay under the argv limit.
rebuild_all_sessions_index() {
    local proj_root="$1" cache_file="$2" index_file="$3"
    local win_start="${4:-}" win_end="${5:-}"
    local old_index all_paths recompute_paths recomputed ref_file
    local tmp_old tmp_all tmp_rc

    old_index=$(cat "$index_file" 2>/dev/null)
    echo "$old_index" | jq -e 'type == "object"' >/dev/null 2>&1 || old_index='{}'

    # HIMMEL-1300 R3-1: the pass-start mtime reference, touched into existence
    # BEFORE the first `find` below. _hud_write_index_checkpoint pins
    # $index_file back to it after every publish — see that function's header
    # for why an advancing index mtime silently freezes files modified mid-pass.
    # Registered in $_HUD_RB_TMPFILES so a caller killed mid-pass (the periodic
    # hook's timeout) can still reap it.
    ref_file=$(mktemp 2>/dev/null) || ref_file=""
    _HUD_RB_TMPFILES="$ref_file"

    # Current transcripts (one dir level down). `find` streams paths, so this
    # never hits the argv limit the glob did.
    all_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null)
    if [ -z "$all_paths" ]; then
        _hud_rb_rmtemps
        return 0
    fi

    # Windowed mode: drop files whose mtime predates the window start — none of
    # their messages can fall in [start,end), so this only bounds the scan, it
    # never changes the result. The `all` path skips this and keeps every file.
    #
    # The mtime filter MUST run inside a single `find`, not a bash stat-per-file
    # loop: each `stat` is a separate process, and on a large history (1000+
    # transcripts) that is 1000+ process spawns — on Git-Bash/Windows that alone
    # overruns the render timeout, so the backgrounded rebuild never finishes and
    # the per-window cache stays at 0 (the "week/month row renders 0" bug). We
    # use a reference file + POSIX `-newer` (portable GNU/BSD) rather than the
    # GNU-only `-newermt`; the reference mtime is win_start-1 so the boundary
    # stays inclusive (>=), matching the per-message [start,end) test below.
    if [ -n "$win_start" ]; then
        local _ref="" _reffail=""
        _ref=$(mktemp 2>/dev/null) || _reffail=1
        if [ -z "$_reffail" ]; then
            touch -d "@$(( win_start - 1 ))" "$_ref" 2>/dev/null \
                || touch -t "$(date -r "$(( win_start - 1 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$_ref" 2>/dev/null \
                || _reffail=1
        fi
        if [ -z "$_reffail" ]; then
            all_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$_ref" 2>/dev/null)
        fi
        # If the reference file could not be built, all_paths keeps the unbounded
        # list: the per-message jq still yields a correct windowed sum, only the
        # scan is unbounded — a slow-but-correct render beats a 0.
        [ -n "$_ref" ] && rm -f "$_ref" 2>/dev/null
        if [ -z "$all_paths" ]; then
            _hud_rb_rmtemps
            return 0
        fi
    fi

    # Files to recompute: those modified since the last index write (so the
    # active session and any new files), or everything on a cold first run.
    #
    # PLUS a bounded backfill of transcripts ABSENT from the carried-forward
    # index (HIMMEL-698). A file that predates the index's first write and was
    # never itself the freshly-written active transcript is never `-newer`, so
    # without this it is never recomputed and — because it never entered
    # $oldidx either — is permanently dropped from the aggregate: the reduce
    # below skips any path that is neither in $rc nor $oldidx. On a large
    # history whose cold full-scan never completed, the "all" row then reflects
    # only the handful of files that happened to be the active transcript at a
    # render (observed: 6 of 1812 files → a stuck, implausibly-low total).
    # The backfill is BOUNDED per rebuild (override
    # HIMMEL_STATUSLINE_BACKFILL_MAX); the index grows monotonically (a
    # backfilled file's mtime predates the new index write, so it is carried
    # forward, not re-scanned), so the aggregate heals over successive passes.
    # HIMMEL-1300 §3.4 retunes the default 400 -> 50: at a measured 71ms/file
    # that is ~3.5s, ~35% of a 10s hook, where 400 was 28.4s (2.8x over) and
    # therefore never completed. With checkpointing this is a latency knob, not
    # a correctness one.
    #
    # HIMMEL-1300 §3.4 also bounds COLD START: the recompute set starts EMPTY
    # (it used to be `$all_paths`, unbounded), and the backfill below is hoisted
    # OUT of the `-f "$index_file"` guard so it runs unconditionally. The old
    # cold scan could not finish inside the hook timeout, was killed, wrote
    # nothing, and so left the next pass cold too — a permanent 0. Cold start is
    # now simply "empty index + BACKFILL_MAX files per pass".
    recompute_paths=""
    if [ -f "$index_file" ]; then
        recompute_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$index_file" 2>/dev/null)
    fi
    local backfill_max="${HIMMEL_STATUSLINE_BACKFILL_MAX:-50}"
    case "$backfill_max" in ''|*[!0-9]*) backfill_max=50 ;; esac
    if [ "$backfill_max" -gt 0 ]; then
        local tmp_known missing
        tmp_known=$(mktemp 2>/dev/null) || tmp_known=""
        # Registered like every other mktemp in this function: the jq/sort/comm
        # window below is long enough to be killed through, and a timeout-kill
        # IS the normal termination mode while the index heals — so the inline
        # `rm -f` after the pipeline is not sufficient on its own.
        [ -n "$tmp_known" ] && _HUD_RB_TMPFILES="$ref_file
$tmp_known"
        if [ -n "$tmp_known" ]; then
            # Known = paths already in the index AT THE CURRENT SCHEMA.
            # HIMMEL-1300 stamps `v` INSIDE each entry value (so `keys[]` is
            # never polluted): v=2 = deduped accounting, v=-1 = a file that
            # failed to parse N times running (permanently parked). Anything
            # else — a pre-dedup v=1 entry, or a failure sentinel with no v —
            # is deliberately NOT known, so `comm -23` classifies it as
            # missing and it re-enters the SAME bounded backfill machinery.
            # That one query line is the whole re-migration.
            # `tr -d` strips CR: a native-Windows jq (jq-1.8.2 via winget)
            # writes CRLF, and unlike a single-line `$(…)` — where bash eats
            # the trailing \r\n — a multi-line pipeline keeps a \r on EVERY
            # line. `comm -23` then matches nothing, so every path looks
            # missing and the backfill re-scans BACKFILL_MAX files every
            # pass forever. Pre-existing (the old `keys[]?` had it too) and
            # invisible because "recompute everything" is merely slow, not
            # wrong — but it would make the schema filter above a no-op.
            printf '%s\n' "$old_index" \
                | jq -r 'to_entries[]?
                         | (.value | if type == "object" then (.v // 1) else 1 end) as $v
                         | select($v == 2 or $v == -1) | .key' 2>/dev/null \
                | tr -d '\r' | LC_ALL=C sort -u > "$tmp_known"
            missing=$(printf '%s\n' "$all_paths" | grep -v '^$' | LC_ALL=C sort -u \
                | LC_ALL=C comm -23 - "$tmp_known" | head -n "$backfill_max")
            rm -f "$tmp_known" 2>/dev/null
            if [ -n "$missing" ]; then
                recompute_paths=$(printf '%s\n%s' "$recompute_paths" "$missing" \
                    | grep -v '^$' | LC_ALL=C sort -u)
            fi
        fi
    fi

    # Assemble/publish transport. Created BEFORE the recompute loop (it used to
    # sit after it) because the loop now CHECKPOINTS through
    # _hud_write_index_checkpoint every N files, and each checkpoint re-runs the
    # assemble jq over these same three files. Everything large flows through
    # them, never through jq args.
    tmp_old=$(mktemp 2>/dev/null) || tmp_old=""
    tmp_all=$(mktemp 2>/dev/null) || tmp_all=""
    tmp_rc=$(mktemp  2>/dev/null) || tmp_rc=""
    _HUD_RB_TMPFILES="$ref_file
$tmp_old
$tmp_all
$tmp_rc"
    if [ -z "$tmp_old" ] || [ -z "$tmp_all" ] || [ -z "$tmp_rc" ]; then
        _hud_rb_rmtemps
        return 0
    fi
    printf '%s'   "$old_index" > "$tmp_old"
    printf '%s\n' "$all_paths" > "$tmp_all"

    # Recompute changed files one at a time →
    # path<TAB>reads<TAB>writes<TAB>inputs<TAB>outputs (5 fields), or the
    # 2-field failure sentinel path<TAB>FAIL. Cheap in steady state (usually
    # just the active transcript).
    #
    # CHECKPOINT every $ckpt_every files (HIMMEL-1300 R3-5, override
    # HIMMEL_STATUSLINE_CHECKPOINT_EVERY): the pass is normally terminated by
    # the hook's timeout kill, and a single terminal `mv` meant such a pass
    # persisted NOTHING. Checkpointing makes progress monotonic regardless of
    # how the budget compares to the timeout.
    recomputed=""
    if [ -n "$recompute_paths" ]; then
        local fpath sums line ckpt_every processed
        ckpt_every="${HIMMEL_STATUSLINE_CHECKPOINT_EVERY:-25}"
        case "$ckpt_every" in ''|*[!0-9]*) ckpt_every=25 ;; esac
        processed=0
        while IFS= read -r fpath; do
            [ -z "$fpath" ] && continue
            # LIVENESS HEARTBEAT (HIMMEL-1300). A caller holding a lock over
            # this rebuild — scripts/hooks/refresh-statusline-caches-periodic.sh
            # — defines _hud_rb_heartbeat to re-stamp its lock. Without it a pass
            # that legitimately runs past that reaper's age threshold looks
            # exactly like a leaked lock and gets reaped out from under itself,
            # letting a second refresher start on top of the first. Called
            # per-file rather than per-checkpoint on purpose: a pass with fewer
            # files than $ckpt_every never checkpoints at all, so a
            # checkpoint-only heartbeat would go quiet in precisely the
            # slow-and-few case the reap protects against. The contract on the
            # callback is that it must be SPAWN-FREE (builtin write, no touch(1))
            # — this runs once per file inside the hot path. Optional by design:
            # the legacy bar defines no such function and the `command -v` guard
            # makes it a no-op there.
            command -v _hud_rb_heartbeat >/dev/null 2>&1 && _hud_rb_heartbeat
            if [ -n "$win_start" ]; then
                # Windowed: dedup over the FULL row stream FIRST (the
                # consecutive-fingerprint fallback needs the original row
                # adjacency; filtering first would fuse two distinct id-less
                # messages), then keep the winners whose timestamp falls in
                # [win_start, win_end). Fractional ".000Z" is stripped before
                # fromdateiso8601; an unparseable timestamp → -1 → excluded.
                sums=$(jq -rs --argjson s "$win_start" --argjson e "$win_end" \
                    "$_HUD_DEDUP_JQ"' dedup_usage
                     | map(select((.t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601? // -1) as $te
                                  | $te >= $s and $te < $e))
                     | sum4 | @tsv' "$fpath" 2>/dev/null)
            else
                # Unwindowed: dedup ONLY, no timestamp filter. Rows here
                # legitimately carry no `.timestamp`, and a winner-filter would
                # silently drop every one of them (→ a 0 total).
                sums=$(jq -rs "$_HUD_DEDUP_JQ"' dedup_usage | sum4 | @tsv' "$fpath" 2>/dev/null)
            fi
            # jq failure (corrupt/oversized file, or a torn read of the live
            # transcript mid-append) → a SENTINEL row, never a zero row: a zero
            # entry OVERRIDES the carried-forward value and drags the aggregate
            # below true. The assemble below carries the old sums and bumps
            # `attempts` instead; `attempts` resets on the next success.
            [ -z "$sums" ] && sums="FAIL"
            line=$(printf '%s\t%s' "$fpath" "$sums")
            recomputed="${recomputed}${line}"$'\n'
            processed=$(( processed + 1 ))
            if [ "$ckpt_every" -gt 0 ] && [ $(( processed % ckpt_every )) -eq 0 ]; then
                _hud_write_index_checkpoint "$cache_file" "$index_file" "$ref_file"
            fi
        done <<EOF
$recompute_paths
EOF
    fi

    # Final publish. Also the ONLY publish when nothing was recomputed —
    # deletions and carried-forward entries still have to reach the index and
    # the totals — and the one that lands the tail of a chunk shorter than
    # $ckpt_every.
    _hud_write_index_checkpoint "$cache_file" "$index_file" "$ref_file"
    _hud_rb_rmtemps
    return 0
}
# Returns all-sessions cache totals, refreshing via a single locked background
# rebuild (30s throttle). Sets: all_reads all_writes all_inputs
read_all_sessions_cache_stats() {
    local period="${1:-all}"
    all_reads=0; all_writes=0; all_inputs=0

    local window_id window_start window_end
    resolve_window "$period"

    # For period=all, window_id="all-stats" → the legacy filenames are
    # reproduced byte-for-byte; week/month get their own per-window files.
    local cache_file="/tmp/claude/cache-${window_id}.json"
    local index_file="/tmp/claude/cache-${window_id}-index.json"
    local cache_max_age=30
    local needs_refresh=true

    mkdir -p /tmp/claude
    if [ -f "$cache_file" ]; then
        local cache_mtime now cache_age
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        [ "$cache_age" -lt "$cache_max_age" ] && needs_refresh=false
    fi

    if $needs_refresh; then
        local proj_root="$HOME/.claude/projects" lock="${index_file}.lock"
        # Clear a stale lock left by a crashed rebuild so refresh can't wedge.
        if [ -d "$lock" ]; then
            local lock_mtime
            lock_mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)
            [ "$(( $(date +%s) - lock_mtime ))" -gt 300 ] && rmdir "$lock" 2>/dev/null
        fi
        # mkdir is atomic → exactly one rebuild at a time; prevents pile-up
        # while a slow cold-start scan of a large history is in flight.
        if mkdir "$lock" 2>/dev/null; then
            local _pr="$proj_root" _cf="$cache_file" _if="$index_file" _lk="$lock"
            local _ws="$window_start" _we="$window_end" _wid="$window_id"
            ( trap 'rmdir "$_lk" 2>/dev/null' EXIT
              if [ "$_wid" = "all-stats" ]; then
                  rebuild_all_sessions_index "$_pr" "$_cf" "$_if"
              else
                  rebuild_all_sessions_index "$_pr" "$_cf" "$_if" "$_ws" "$_we"
              fi
            ) & disown 2>/dev/null || true
        fi
    fi

    # Return last cached totals immediately (may be one render stale during refresh).
    [ ! -f "$cache_file" ] && return
    local data joined US=$'\037'
    data=$(cat "$cache_file" 2>/dev/null) || return
    # One jq pass (was 3 echo|jq extractions; HIMMEL-612).
    joined=$(printf '%s' "$data" | jq -r --arg sep "$US" '[(.reads // 0), (.writes // 0), (.inputs // 0)] | map(tostring) | join($sep)' 2>/dev/null)
    [ -n "$joined" ] || return
    IFS="$US" read -r all_reads all_writes all_inputs <<EOF
$joined
EOF
    [ -n "$all_reads" ]  || all_reads=0
    [ -n "$all_writes" ] || all_writes=0
    [ -n "$all_inputs" ] || all_inputs=0
}
# Assembles cache display lines (TTL bars + session + all-sessions rows).
# Sets: cache_lines (multi-line string with ANSI codes)
# Args: $1=transcript_path  $2=model_id  $3=session_cost_usd
build_cache_lines() {
    local transcript_path="$1" model_id="$2" session_cost="${3:-}"
    local read_savings_rate write_overhead_rate
    local sess_reads sess_writes sess_inputs sess_outputs last_5m_iso last_1h_iso
    local all_reads all_writes all_inputs
    local cache_ttl_str cache_ttl_pct
    cache_lines=""

    read_session_cache_stats "$transcript_path"
    get_model_savings_rate "$model_id"

    # ── TTL lines ──────────────────────────────────────────
    # Compute both tiers up front, then hide an *expired* tier when the other
    # is still live — otherwise a single early 5m-cache write leaves a permanent
    # "5m-cache expired" row cluttering an otherwise-1h-cache session.
    local ttl_lines=""
    local h1_str="" h1_pct=0 m5_str="" m5_pct=0
    local present_1h=false present_5m=false h1_live=false m5_live=false

    if [ -n "$last_1h_iso" ] && [ "$last_1h_iso" != "" ]; then
        compute_cache_ttl "$last_1h_iso" 3600
        h1_str="$cache_ttl_str"; h1_pct="$cache_ttl_pct"; present_1h=true
        [ "$h1_str" != "expired" ] && [ -n "$h1_str" ] && h1_live=true
    fi
    if [ -n "$last_5m_iso" ] && [ "$last_5m_iso" != "" ]; then
        compute_cache_ttl "$last_5m_iso" 300
        m5_str="$cache_ttl_str"; m5_pct="$cache_ttl_pct"; present_5m=true
        [ "$m5_str" != "expired" ] && [ -n "$m5_str" ] && m5_live=true
    fi

    local show_1h=false show_5m=false
    if $present_1h && ! { [ "$h1_str" = "expired" ] && $m5_live; }; then show_1h=true; fi
    if $present_5m && ! { [ "$m5_str" = "expired" ] && $h1_live; }; then show_5m=true; fi

    local both_shown=false
    $show_1h && $show_5m && both_shown=true

    if $show_1h; then
        local lbl="cache   "
        $both_shown && lbl="1h-cache"
        ttl_lines+="$(format_ttl_line "$lbl" "$h1_str" "$h1_pct")"
    fi
    if $show_5m; then
        ttl_lines+="$(format_ttl_line "5m-cache" "$m5_str" "$m5_pct")"
    fi

    # ── Session stats line ─────────────────────────────────
    local r_fmt w_fmt hit_pct net_usd net_abs net_sign net_color
    r_fmt=$(format_tokens "$sess_reads")
    w_fmt=$(format_tokens "$sess_writes")

    local denom=$(( sess_inputs + sess_reads ))
    [ "$denom" -gt 0 ] && hit_pct=$(( sess_reads * 100 / denom )) || hit_pct=0

    net_usd=$(awk -v r="$sess_reads" -v w="$sess_writes" \
              -v rs="$read_savings_rate" -v wo="$write_overhead_rate" \
              'BEGIN{printf "%.4f", r*rs - w*wo}')
    net_abs=$(format_usd "$(awk -v n="$net_usd" 'BEGIN{if(n<0)n=-n; printf "%.4f",n}')")
    if awk -v n="$net_usd" 'BEGIN{exit !(n >= 0)}'; then
        net_sign="+"; net_color="$green"
    else
        net_sign="-"; net_color="$red"
    fi

    local cost_part=""
    if [ -n "$session_cost" ] && [ "$session_cost" != "null" ] && \
       awk -v c="$session_cost" 'BEGIN{exit !(c+0 > 0)}'; then
        cost_part="  ${dim}cost${reset} ${white}\$$(format_usd "$session_cost")${reset}"
    fi

    local sess_line="${white}session${reset}  "
    sess_line+="${dim}r:${reset}${white}${r_fmt}${reset}  ${dim}w:${reset}${white}${w_fmt}${reset}  "
    sess_line+="${dim}hit:${reset}${white}${hit_pct}%${reset}  "
    sess_line+="${dim}net${reset} ${net_color}${net_sign}\$${net_abs}${reset}${cost_part}"

    # ── All-sessions stats line ────────────────────────────
    # Bottom-row period (HIMMEL-617): week | month | all (default all). An
    # invalid value renders the `all` label and resolve_window falls back to
    # the all-stats window, so the row degrades to the unchanged default.
    local period="${HIMMEL_STATUSLINE_PERIOD:-all}"
    read_all_sessions_cache_stats "$period"
    local ar_fmt aw_fmt all_hit all_net all_abs all_sign all_color
    ar_fmt=$(format_tokens "$all_reads")
    aw_fmt=$(format_tokens "$all_writes")

    local all_denom=$(( all_inputs + all_reads ))
    [ "$all_denom" -gt 0 ] && all_hit=$(( all_reads * 100 / all_denom )) || all_hit=0

    all_net=$(awk -v r="$all_reads" -v w="$all_writes" \
              -v rs="$read_savings_rate" -v wo="$write_overhead_rate" \
              'BEGIN{printf "%.4f", r*rs - w*wo}')
    all_abs=$(format_usd "$(awk -v n="$all_net" 'BEGIN{if(n<0)n=-n; printf "%.4f",n}')")
    if awk -v n="$all_net" 'BEGIN{exit !(n >= 0)}'; then
        all_sign="+"; all_color="$green"
    else
        all_sign="-"; all_color="$red"
    fi

    # Label = active period, padded to the session-row label width (9 cols).
    # The `all` arm is byte-identical to the original line.
    local all_line
    case "$period" in
        week)  all_line="${white}week${reset}     " ;;
        month) all_line="${white}month${reset}    " ;;
        *)     all_line="${white}all${reset}      " ;;
    esac
    all_line+="${dim}r:${reset}${white}${ar_fmt}${reset}  ${dim}w:${reset}${white}${aw_fmt}${reset}  "
    all_line+="${dim}hit:${reset}${white}${all_hit}%${reset}  "
    all_line+="${dim}net${reset} ${all_color}${all_sign}\$${all_abs}${reset}"

    cache_lines="${ttl_lines}${sess_line}\n${all_line}"
}
# ── End cache metrics functions ──────────────────────────

# ── Output ──────────────────────────────────────────────
build_cache_lines "$transcript_path" "$model_id" "$session_cost"
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"
[ -n "$cache_lines" ] && printf "\n%b" "$cache_lines"

exit 0
