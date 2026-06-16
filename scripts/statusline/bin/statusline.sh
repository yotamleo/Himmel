#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
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
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null)
            result=$(echo "$result" | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
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
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
model_id=$(echo "$input" | jq -r '.model.id // "claude-sonnet"')
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // ""')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
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
cwd=$(echo "$input" | jq -r '.cwd // ""')
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
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
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

stdin_five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
stdin_seven_pct=""
if [ -n "$stdin_five_pct" ]; then
    has_stdin_rates=true
    five_hour_pct=$(printf "%.0f" "$stdin_five_pct")
    five_hour_reset_epoch=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    stdin_seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
    seven_day_pct=$(printf "%s" "$stdin_seven_pct" | awk '{printf "%.0f", $1}')
    seven_day_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
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
        # render, freezing the cache permanently.
        if [ -n "$usage_data" ] && echo "$usage_data" | jq -e 'type == "object"' >/dev/null 2>&1; then
            extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
        else
            usage_data=""
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

    extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$extra_reset" ]; then
        extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
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
    case "$model_id" in
        claude-opus*)   input_price=15.00; cache_read_price=1.50;  cache_write_price=30.00 ;;
        claude-haiku*)  input_price=0.80;  cache_read_price=0.08;  cache_write_price=1.60  ;;
        claude-sonnet*) input_price=3.00;  cache_read_price=0.30;  cache_write_price=6.00  ;;
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

    local stats
    stats=$(jq -s '{
        reads:   ([.[] | select(.type == "assistant") | .message.usage.cache_read_input_tokens   // 0] | add // 0),
        writes:  ([.[] | select(.type == "assistant") | .message.usage.cache_creation_input_tokens // 0] | add // 0),
        inputs:  ([.[] | select(.type == "assistant") | .message.usage.input_tokens              // 0] | add // 0),
        last_5m: ([.[] | select(.type == "assistant" and ((.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) > 0))] | last | .timestamp // ""),
        last_1h: ([.[] | select(.type == "assistant" and ((.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) > 0))] | last | .timestamp // "")
    }' "$transcript" 2>/dev/null) || return

    sess_reads=$(echo  "$stats" | jq -r '.reads   // 0')
    sess_writes=$(echo "$stats" | jq -r '.writes  // 0')
    sess_inputs=$(echo "$stats" | jq -r '.inputs  // 0')
    last_5m_iso=$(echo "$stats" | jq -r '.last_5m // ""')
    last_1h_iso=$(echo "$stats" | jq -r '.last_1h // ""')
}
# Rebuilds the all-sessions cache incrementally. Sets nothing; writes totals
# to $2 (cache_file) and a per-file sums index to $3 (index_file), atomically.
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
    local old_index all_paths recompute_paths recomputed out
    local tmp_old tmp_all tmp_rc tmp

    old_index=$(cat "$index_file" 2>/dev/null)
    echo "$old_index" | jq -e 'type == "object"' >/dev/null 2>&1 || old_index='{}'

    # Current transcripts (one dir level down). `find` streams paths, so this
    # never hits the argv limit the glob did.
    all_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null)
    [ -z "$all_paths" ] && return

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
            sums=$(jq -rs '[ ([.[] | select(.type == "assistant") | .message.usage.cache_read_input_tokens   // 0] | add // 0),
                             ([.[] | select(.type == "assistant") | .message.usage.cache_creation_input_tokens // 0] | add // 0),
                             ([.[] | select(.type == "assistant") | .message.usage.input_tokens               // 0] | add // 0)
                           ] | @tsv' "$fpath" 2>/dev/null)
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
    all_reads=0; all_writes=0; all_inputs=0

    local cache_file="/tmp/claude/cache-all-stats.json"
    local index_file="/tmp/claude/cache-all-stats-index.json"
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
            ( trap 'rmdir "$_lk" 2>/dev/null' EXIT
              rebuild_all_sessions_index "$_pr" "$_cf" "$_if"
            ) & disown 2>/dev/null || true
        fi
    fi

    # Return last cached totals immediately (may be one render stale during refresh).
    [ ! -f "$cache_file" ] && return
    local data
    data=$(cat "$cache_file" 2>/dev/null) || return
    all_reads=$(echo  "$data" | jq -r '.reads  // 0')
    all_writes=$(echo "$data" | jq -r '.writes // 0')
    all_inputs=$(echo "$data" | jq -r '.inputs // 0')
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
    read_all_sessions_cache_stats
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

    local all_line="${white}all${reset}      "
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
