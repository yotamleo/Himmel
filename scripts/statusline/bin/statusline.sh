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
line1+="✍️ ${pct_color}${pct_used}%${reset}"
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

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset}"
    [ -n "$five_hour_reset" ] && rate_lines+=" ${dim}⟳${reset} ${white}${five_hour_reset}${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    [ -n "$rate_lines" ] && rate_lines+="\n"
    rate_lines+="${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset}"
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
format_tokens() {
    local n="${1:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if   [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
    elif [ "$n" -ge 1000 ];    then awk -v n="$n" 'BEGIN{printf "%.0fk", n/1000}'
    else printf "%s" "$n"
    fi
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
# Sets: sess_reads sess_writes sess_inputs last_5m_iso last_1h_iso
read_session_cache_stats() {
    local transcript="$1"
    sess_reads=0; sess_writes=0; sess_inputs=0; last_5m_iso=""; last_1h_iso=""
    [ -z "$transcript" ] || [ ! -f "$transcript" ] && return

    # One jq pass joining on US \x1f (was a slurp + 5 echo|jq extractions;
    # HIMMEL-612). US is non-whitespace so `read` preserves empty timestamp
    # fields instead of coalescing them (a tab IFS would shift columns when
    # last_5m is empty but last_1h is set).
    local stats US=$'\037'
    stats=$(jq -rs --arg sep "$US" '[
        ([.[] | select(.type == "assistant") | .message.usage.cache_read_input_tokens   // 0] | add // 0),
        ([.[] | select(.type == "assistant") | .message.usage.cache_creation_input_tokens // 0] | add // 0),
        ([.[] | select(.type == "assistant") | .message.usage.input_tokens              // 0] | add // 0),
        ([.[] | select(.type == "assistant" and ((.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) > 0))] | last | .timestamp // ""),
        ([.[] | select(.type == "assistant" and ((.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) > 0))] | last | .timestamp // "")
    ] | map(tostring) | join($sep)' "$transcript" 2>/dev/null) || return
    [ -n "$stats" ] || return

    IFS="$US" read -r sess_reads sess_writes sess_inputs last_5m_iso last_1h_iso <<EOF
$stats
EOF
    [ -n "$sess_reads" ]  || sess_reads=0
    [ -n "$sess_writes" ] || sess_writes=0
    [ -n "$sess_inputs" ] || sess_inputs=0
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
    local old_index all_paths recompute_paths recomputed out
    local tmp_old tmp_all tmp_rc tmp

    old_index=$(cat "$index_file" 2>/dev/null)
    echo "$old_index" | jq -e 'type == "object"' >/dev/null 2>&1 || old_index='{}'

    # Current transcripts (one dir level down). `find` streams paths, so this
    # never hits the argv limit the glob did.
    all_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null)
    [ -z "$all_paths" ] && return

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
        [ -z "$all_paths" ] && return
    fi

    # Files to recompute: those modified since the last index write (so the
    # active session and any new files), or everything on a cold first run.
    if [ -f "$index_file" ]; then
        recompute_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$index_file" 2>/dev/null)
    else
        recompute_paths="$all_paths"
    fi

    # Recompute changed files one at a time → path<TAB>reads<TAB>writes<TAB>inputs.
    # Cheap in steady state (usually just the active transcript).
    recomputed=""
    if [ -n "$recompute_paths" ]; then
        local fpath sums line
        while IFS= read -r fpath; do
            [ -z "$fpath" ] && continue
            if [ -n "$win_start" ]; then
                # Windowed: keep only assistant messages whose timestamp falls
                # in [win_start, win_end). Fractional ".000Z" is stripped before
                # fromdateiso8601; an unparseable timestamp → -1 → excluded.
                sums=$(jq -rs --argjson s "$win_start" --argjson e "$win_end" \
                    '[ .[] | select(.type == "assistant")
                           | ((.timestamp // "") | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601? // -1) as $te
                           | select($te >= $s and $te < $e) ]
                     | [ ([.[] | .message.usage.cache_read_input_tokens   // 0] | add // 0),
                         ([.[] | .message.usage.cache_creation_input_tokens // 0] | add // 0),
                         ([.[] | .message.usage.input_tokens               // 0] | add // 0)
                       ] | @tsv' "$fpath" 2>/dev/null)
            else
                sums=$(jq -rs '[ ([.[] | select(.type == "assistant") | .message.usage.cache_read_input_tokens   // 0] | add // 0),
                                 ([.[] | select(.type == "assistant") | .message.usage.cache_creation_input_tokens // 0] | add // 0),
                                 ([.[] | select(.type == "assistant") | .message.usage.input_tokens               // 0] | add // 0)
                               ] | @tsv' "$fpath" 2>/dev/null)
            fi
            [ -z "$sums" ] && sums=$(printf '0\t0\t0')
            line=$(printf '%s\t%s' "$fpath" "$sums")
            recomputed="${recomputed}${line}"$'\n'
        done <<EOF
$recompute_paths
EOF
    fi

    # Assemble the new index (recomputed entries override carried-forward ones,
    # deleted files drop out because we only iterate current paths) and the
    # totals. Everything large goes through temp files, never jq args.
    tmp_old=$(mktemp 2>/dev/null) || return
    tmp_all=$(mktemp 2>/dev/null) || { rm -f "$tmp_old"; return; }
    tmp_rc=$(mktemp  2>/dev/null) || { rm -f "$tmp_old" "$tmp_all"; return; }
    printf '%s'   "$old_index"   > "$tmp_old"
    printf '%s\n' "$all_paths"   > "$tmp_all"
    printf '%s'   "$recomputed"  > "$tmp_rc"

    out=$(jq -n --rawfile old "$tmp_old" --rawfile allp "$tmp_all" --rawfile recomp "$tmp_rc" '
        ($old | fromjson? // {}) as $oldidx
        | ($recomp | split("\n") | map(select(length > 0) | split("\t"))
            | map({ key: .[0], value: { reads:  (.[1] | tonumber? // 0),
                                        writes: (.[2] | tonumber? // 0),
                                        inputs: (.[3] | tonumber? // 0) } })
            | from_entries) as $rc
        | ($allp | split("\n") | map(select(length > 0))) as $files
        | reduce $files[] as $p
            ({ index: {}, reads: 0, writes: 0, inputs: 0 };
             ($rc[$p] // $oldidx[$p] // null) as $e
             | if $e == null then .
               else .index[$p] = { reads: $e.reads, writes: $e.writes, inputs: $e.inputs }
                  | .reads  += $e.reads
                  | .writes += $e.writes
                  | .inputs += $e.inputs
               end)' 2>/dev/null)
    rm -f "$tmp_old" "$tmp_all" "$tmp_rc"
    [ -z "$out" ] && return

    # Atomic tmp+mv so a concurrent reader never sees a torn file.
    tmp="${index_file}.$$.tmp"
    if echo "$out" | jq -c '.index' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$index_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    tmp="${cache_file}.$$.tmp"
    if echo "$out" | jq -c '{ reads, writes, inputs }' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
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
    local sess_reads sess_writes sess_inputs last_5m_iso last_1h_iso
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
    net_abs=$(awk -v n="$net_usd" 'BEGIN{if(n<0)n=-n; printf "%.4f",n}')
    if awk -v n="$net_usd" 'BEGIN{exit !(n >= 0)}'; then
        net_sign="+"; net_color="$green"
    else
        net_sign="-"; net_color="$red"
    fi

    local cost_part=""
    if [ -n "$session_cost" ] && [ "$session_cost" != "null" ] && \
       awk -v c="$session_cost" 'BEGIN{exit !(c+0 > 0)}'; then
        cost_part="  ${dim}cost${reset} ${white}$(printf '$%.4f' "$session_cost")${reset}"
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
    all_abs=$(awk -v n="$all_net" 'BEGIN{if(n<0)n=-n; printf "%.4f",n}')
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
