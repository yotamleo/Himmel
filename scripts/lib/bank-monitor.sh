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
# distinct from the console tick's 180-second sample cadence (console-wait.sh,
# HIMMEL-3509; it wakes the console only on a change, not on every sample):
#   while :; do bash scripts/lib/bank-monitor.sh; sleep 300; done
#
# Test seams:
#   BANK_CACHE_FILE  usage JSON (default /tmp/claude/statusline-usage-cache.json)
#   BANK_NOW_EPOCH   epoch seconds (default date +%s)
#   BANK_NOW_HM      display clock (default date +%H:%M)
#   BANK_STATE_FILE  emission state; its .samples sibling is the sample ring
#   REPO             checkout containing scripts/lanes/bank-status.ts
#
# HIMMEL-4421: the BANK line also carries seven_day_reset_in=<h>h and
# unspent_at_reset=<pct> = max(0, 100 - (seven_day + seven_day_rate x reset_in)),
# the weekly quota the current burn leaves unspent at the reset (advisory only;
# it gates nothing). Either reads ? when the rate or resets_at is unknown or the
# reset is already past. `--spare` is READ-ONLY: it derives the rate from the
# existing sample ring plus this observation in memory, writes neither the ring
# nor the emission state, never calls bank-status.ts, and prints only those two
# fields. The console tick can read them without a later normal run seeing a
# repeated cache stamp (state=stale) and swallowing a state-change line.
#
# PLATFORM GUARD: no .ps1 twin, by design. This is Bash 3.2-compatible and is
# consumed by the Linux console kit; its codex-bank reader is the Bun CLI.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
BANK_CACHE_FILE="${BANK_CACHE_FILE:-/tmp/claude/statusline-usage-cache.json}"
spare_only=0
[ "${1:-}" = "--spare" ] && spare_only=1

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
# resets_at is an ISO-8601 UTC string in the real cache (fractional seconds and a
# +00:00 offset); a bare epoch is accepted too. Anything else reads as unknown.
seven_reset_epoch="$(jq -r '.seven_day.resets_at | if type == "number" then floor elif type == "string" then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | try fromdateiso8601 catch empty) else empty end' "$BANK_CACHE_FILE" 2>/dev/null)" || seven_reset_epoch=""
case "$seven_reset_epoch" in ''|*[!0-9]*) seven_reset_epoch="" ;; esac
real_now="$now"

# HIMMEL-1712: a cache stamped by a different account is the same
# can't-trust-this-number case valid_pct's own failures above already
# quiet-no-op on. A missing/unreadable helper degrades to "can't tell",
# which this treats the same as a mismatch.
_id_lib="$HERE/usage-cache-identity.sh"
# shellcheck source=usage-cache-identity.sh
# shellcheck disable=SC1090,SC1091
{ [ -r "$_id_lib" ] && . "$_id_lib"; } 2>/dev/null || usage_cache_account_mismatch() { return 0; }
usage_cache_account_mismatch "$BANK_CACHE_FILE" && exit 0

bank_status=""
if [ "$spare_only" -eq 0 ]; then
    bank_status="$(bun "$REPO/scripts/lanes/bank-status.ts" 2>/dev/null | grep '^claudex ' | head -n 1)" || bank_status=""
fi
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
[ "$spare_only" -eq 1 ] || mkdir -p "$state_dir" 2>/dev/null || exit 0

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

if [ "$spare_only" -eq 1 ]; then
    # Read-only: the ring plus this observation, in memory, mirroring the
    # normal-mode window and reset rules below; the file is never written, so a
    # later normal run still sees a fresh cache_stamp.
    read -r old_seven_time old_seven now seven <<EOF
$(awk -v cutoff="$((now - 1800))" -v now="$now" -v cur="$seven" -v stamp="$cache_stamp" '
    $1 ~ /^[0-9]+$/ { lt = $1; ls = $3; lk = $4 }
    $1 ~ /^[0-9]+$/ && $3 != "-" && !oa { oa_t = $1; oa_s = $3; oa = 1 }
    $1 ~ /^[0-9]+$/ && $1 >= cutoff && $1 <= now && $3 != "-" && !ow { ow_t = $1; ow_s = $3; ow = 1 }
    END {
        if (lk != "" && lk == stamp) { if (oa) print oa_t, oa_s, lt, ls; else print "-", "-", lt, ls; exit }
        reset = (lt ~ /^[0-9]+$/) && (lt >= now || cur + 0 < ls + 0)
        if (reset || !ow) print "-", "-", now, cur; else print ow_t, ow_s, now, cur
    }' "$samples_file" 2>/dev/null || printf '%s\n' "- - $now $seven")
EOF
    [ -n "$seven" ] || exit 0
    case "$old_seven_time" in ''|*[!0-9]*) old_seven_time="$now" ;; esac
    old_five_time="$now"
elif [ "$cache_stamp" = "$last_stamp" ]; then
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

if [ "$spare_only" -eq 0 ]; then
    oldest_five="$(awk 'NF >= 3 && $2 != "-" { print $1, $2; exit }' "$samples_file")"
    oldest_seven="$(awk 'NF >= 3 && $3 != "-" { print $1, $3; exit }' "$samples_file")"
    old_five_time="$(printf '%s\n' "$oldest_five" | awk '{print $1}')"
    old_seven_time="$(printf '%s\n' "$oldest_seven" | awk '{print $1}')"
    old_five="$(printf '%s\n' "$oldest_five" | awk '{print $2}')"
    old_seven="$(printf '%s\n' "$oldest_seven" | awk '{print $2}')"
fi
five_span=$((now - old_five_time))
seven_span=$((now - old_seven_time))

five_rate=0.0
seven_rate=0.0
seven_rate_raw=""
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

reset_in='?'
unspent='?'
if [ -n "$seven_reset_epoch" ] && [ -n "$seven_rate_raw" ] && [ "$seven_reset_epoch" -gt "$real_now" ]; then
    reset_in="$(awk -v reset="$seven_reset_epoch" -v now="$real_now" 'BEGIN { printf "%.1fh", (reset - now) / 3600 }')"
    unspent="$(awk -v seven="$seven" -v rate="$seven_rate_raw" -v reset="$seven_reset_epoch" -v now="$real_now" 'BEGIN { value = 100 - (seven + rate * (reset - now) / 3600); if (value < 0) value = 0; printf "%.1f", value }')"
fi
if [ "$spare_only" -eq 1 ]; then
    printf 'seven_day_reset_in=%s unspent_at_reset=%s\n' "$reset_in" "$unspent"
    exit 0
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
    printf 'BANK %s rate five_hour=+%s/h seven_day=+%s/h ttc=%sh state=%s five_hour_ttc=%sh seven_day_ttc=%sh codex=%s seven_day_reset_in=%s unspent_at_reset=%s\n' \
        "$clock" "$five_rate" "$seven_rate" "$ttc" "$state" "$five_ttc" "$seven_ttc" "$codex" "$reset_in" "$unspent"
fi
exit 0
