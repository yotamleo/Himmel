#!/usr/bin/env bash
# bank-monitor.sh — wake-up-budgeted bank burn projection (HIMMEL-2767).
#
# One fresh cache observation records one sample. The persisted ring retains the
# latest 30 minutes, then computes percentage-point/hour rates and projections
# to 100% for both Claude subscription windows. The claudex row from
# scripts/lanes/bank-status.ts contributes the codex-bank ceiling state.
# Output occurs only when the state changes or the earliest projection crosses
# from >=24h/unknown to <24h; repeated below-threshold observations are silent.
# This script is one-shot: collect enough points with a 300-second Bash poll,
# distinct from the console tick's 60-minute cadence:
#   while :; do bash scripts/lib/bank-monitor.sh; sleep 300; done
#
# Test seams:
#   BANK_CACHE_FILE  usage JSON (default /tmp/claude/statusline-usage-cache.json)
#   BANK_NOW_EPOCH   epoch seconds (default date +%s)
#   BANK_NOW_HM      display clock (default date +%H:%M)
#   BANK_STATE_FILE  emission state; its .samples sibling is the sample ring
#   REPO             checkout containing scripts/lanes/bank-status.ts
#
# PLATFORM GUARD: no .ps1 twin, by design. This is Bash 3.2-compatible and is
# consumed by the Linux console kit; its codex-bank reader is the Bun CLI.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
BANK_CACHE_FILE="${BANK_CACHE_FILE:-/tmp/claude/statusline-usage-cache.json}"

if [ -n "${BANK_STATE_FILE:-}" ]; then
    state_file="$BANK_STATE_FILE"
elif [ -n "${HOME:-}" ]; then
    state_file="$HOME/.himmel/cache/bank-monitor.state"
else
    state_file="${TMPDIR:-/tmp}/himmel-bank-monitor-${UID:-user}.state"
fi
samples_file="${BANK_SAMPLES_FILE:-$state_file.samples}"

now="${BANK_NOW_EPOCH:-$(date +%s 2>/dev/null)}"
clock="${BANK_NOW_HM:-$(date +%H:%M 2>/dev/null)}"
case "$now" in ''|*[!0-9]*) exit 0 ;; esac
[ -n "$clock" ] || clock='??:??'

[ -r "$BANK_CACHE_FILE" ] || exit 0
five="$(jq -r '.five_hour.utilization | if type == "number" then . else empty end' "$BANK_CACHE_FILE" 2>/dev/null)" || five=""
seven="$(jq -r '.seven_day.utilization | if type == "number" then . else empty end' "$BANK_CACHE_FILE" 2>/dev/null)" || seven=""
valid_pct() {
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value + 0 >= 0 && value + 0 <= 100) }'
}
valid_pct "$five" || exit 0
valid_pct "$seven" || exit 0

bank_status="$(bun "$REPO/scripts/lanes/bank-status.ts" 2>/dev/null | grep '^claudex ' | head -n 1)" || bank_status=""
codex_five="$(printf '%s\n' "$bank_status" | sed -n 's/.*5h used=\([0-9][0-9.]*\)%.*/\1/p')"
codex_seven="$(printf '%s\n' "$bank_status" | sed -n 's/.*weekly used=\([0-9][0-9.]*\)%.*/\1/p')"
valid_pct "$codex_five" 2>/dev/null || codex_five=""
valid_pct "$codex_seven" 2>/dev/null || codex_seven=""

state=headroom
if awk -v value="$seven" 'BEGIN { exit !(value + 0 >= 85) }' \
   || { [ -n "$codex_seven" ] && awk -v value="$codex_seven" 'BEGIN { exit !(value + 0 >= 85) }'; }
then
    state=WEEKLY-CEILING
elif awk -v value="$five" 'BEGIN { exit !(value + 0 >= 60) }' \
     || { [ -n "$codex_five" ] && awk -v value="$codex_five" 'BEGIN { exit !(value + 0 >= 60) }'; }
then
    state=park
fi

state_dir="$(dirname "$state_file")"
mkdir -p "$state_dir" 2>/dev/null || exit 0

# Stdin rate updates preserve oauth_checked_at; use mtime as well. The OAuth
# stamp also distinguishes refreshes within the same filesystem timestamp second.
cache_mtime="$(stat -c %Y "$BANK_CACHE_FILE" 2>/dev/null || stat -f %m "$BANK_CACHE_FILE" 2>/dev/null)" || exit 0
cache_oauth="$(jq -r '.oauth_checked_at | if type == "number" then . else empty end' "$BANK_CACHE_FILE" 2>/dev/null)"
cache_stamp="$cache_mtime:$cache_oauth"
last=""
[ -r "$samples_file" ] && last="$(tail -n 1 "$samples_file" 2>/dev/null)"
last_time="$(printf '%s\n' "$last" | awk '{print $1}')"
last_five="$(printf '%s\n' "$last" | awk '{print $2}')"
last_seven="$(printf '%s\n' "$last" | awk '{print $3}')"
last_stamp="$(printf '%s\n' "$last" | awk '{print $4}')"

if [ "$cache_stamp" = "$last_stamp" ]; then
    state=stale
    # Keep the last measured projections, not a fictitious zero-burn poll.
    now="$last_time"
    five="$last_five"
    seven="$last_seven"
else
    reset_five=0
    reset_seven=0
    case "$last_time" in ''|*[!0-9]*) ;;
        *)
            if [ "$last_time" -ge "$now" ]; then
                reset_five=1
                reset_seven=1
            else
                awk -v current="$five" -v previous="$last_five" 'BEGIN { exit !(current + 0 < previous + 0) }' && reset_five=1
                awk -v current="$seven" -v previous="$last_seven" 'BEGIN { exit !(current + 0 < previous + 0) }' && reset_seven=1
            fi
            ;;
    esac

    cutoff=$((now - 1800))
    samples_tmp="$samples_file.tmp.$$"
    if [ -r "$samples_file" ]; then
        # A dash invalidates only the resetting window, retaining the other.
        awk -v cutoff="$cutoff" -v now="$now" -v rf="$reset_five" -v rs="$reset_seven" '
            $1 ~ /^[0-9]+$/ && $1 >= cutoff && $1 <= now {
                if (rf) $2="-"
                if (rs) $3="-"
                if ($2 != "-" || $3 != "-") print $1, $2, $3, $4
            }' "$samples_file" > "$samples_tmp" 2>/dev/null || : > "$samples_tmp"
    else
        : > "$samples_tmp"
    fi
    printf '%s %s %s %s\n' "$now" "$five" "$seven" "$cache_stamp" >> "$samples_tmp"
    mv -f "$samples_tmp" "$samples_file" 2>/dev/null || exit 0
fi

oldest_five="$(awk 'NF >= 3 && $2 != "-" { print $1, $2; exit }' "$samples_file")"
oldest_seven="$(awk 'NF >= 3 && $3 != "-" { print $1, $3; exit }' "$samples_file")"
old_five_time="$(printf '%s\n' "$oldest_five" | awk '{print $1}')"
old_seven_time="$(printf '%s\n' "$oldest_seven" | awk '{print $1}')"
old_five="$(printf '%s\n' "$oldest_five" | awk '{print $2}')"
old_seven="$(printf '%s\n' "$oldest_seven" | awk '{print $2}')"
five_span=$((now - old_five_time))
seven_span=$((now - old_seven_time))

five_rate=0.0
seven_rate=0.0
five_ttc='?'
seven_ttc='?'
if [ "$five_span" -gt 0 ]; then
    five_rate_raw="$(awk -v current="$five" -v old="$old_five" -v seconds="$five_span" 'BEGIN { printf "%.8f", (current-old) * 3600 / seconds }')"
    five_rate="$(awk -v rate="$five_rate_raw" 'BEGIN { printf "%.1f", rate }')"
    if awk -v rate="$five_rate_raw" 'BEGIN { exit !(rate > 0) }'; then
        five_ttc="$(awk -v current="$five" -v rate="$five_rate_raw" 'BEGIN { value=(100-current)/rate; if (value < 0) value=0; printf "%.1f", value }')"
    fi
fi
if [ "$seven_span" -gt 0 ]; then
    seven_rate_raw="$(awk -v current="$seven" -v old="$old_seven" -v seconds="$seven_span" 'BEGIN { printf "%.8f", (current-old) * 3600 / seconds }')"
    seven_rate="$(awk -v rate="$seven_rate_raw" 'BEGIN { printf "%.1f", rate }')"
    if awk -v rate="$seven_rate_raw" 'BEGIN { exit !(rate > 0) }'; then
        seven_ttc="$(awk -v current="$seven" -v rate="$seven_rate_raw" 'BEGIN { value=(100-current)/rate; if (value < 0) value=0; printf "%.1f", value }')"
    fi
fi

ttc='?'
if [ "$five_ttc" != '?' ]; then ttc="$five_ttc"; fi
if [ "$seven_ttc" != '?' ] && { [ "$ttc" = '?' ] || awk -v a="$seven_ttc" -v b="$ttc" 'BEGIN { exit !(a < b) }'; }; then
    ttc="$seven_ttc"
fi
below=0
if [ "$ttc" != '?' ] && awk -v value="$ttc" 'BEGIN { exit !(value < 24) }'; then
    below=1
fi

previous_state=""
previous_below=0
if [ -r "$state_file" ]; then
    IFS=' ' read -r previous_state previous_below < "$state_file" || true
    case "$previous_below" in 0|1) ;; *) previous_below=0 ;; esac
fi

emit=0
[ "$state" = "$previous_state" ] || emit=1
[ "$below" -eq 1 ] && [ "$previous_below" -ne 1 ] && emit=1

state_tmp="$state_file.tmp.$$"
printf '%s %s\n' "$state" "$below" > "$state_tmp" 2>/dev/null && mv -f "$state_tmp" "$state_file" 2>/dev/null

codex='?'
if [ -n "$codex_five" ] || [ -n "$codex_seven" ]; then
    [ -n "$codex_five" ] || codex_five='?'
    [ -n "$codex_seven" ] || codex_seven='?'
    codex="5h${codex_five}/wk${codex_seven}"
fi

if [ "$emit" -eq 1 ]; then
    printf 'BANK %s rate five_hour=+%s/h seven_day=+%s/h ttc=%sh state=%s five_hour_ttc=%sh seven_day_ttc=%sh codex=%s\n' \
        "$clock" "$five_rate" "$seven_rate" "$ttc" "$state" "$five_ttc" "$seven_ttc" "$codex"
fi
exit 0
