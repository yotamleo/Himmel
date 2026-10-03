#!/usr/bin/env bash
# scripts/luna/cadence-alert.sh — the one failure sink every generated cadence
# runner calls (HIMMEL-4181). A failed leg must never be silent: the 2026-10-03
# harvest did nothing and logged rc=0, and nobody found out until morning.
#
#   cadence-alert.sh fail <leg> <reason> <log-path>
#   cadence-alert.sh clear <leg>
#
# `fail` ALWAYS appends one line `<UTC iso-ts> <leg> <reason> <log-path>` to the
# console-readable alert file, then sends the same event to the operator's
# Telegram ONCE through the existing sender (vault-stall-alert.sh, i.e. the
# merge-block-alert.sh -> console-route.ts bridge path). A repeat of the same
# leg+reason appends again but does not re-send until `clear` — a completed
# run of that leg — re-arms it. The dedupe sentinel is written only after a
# delivered send, so a failed send means the next failure retries the DM.
#
# Seams: CADENCE_ALERT_FILE (default ~/.himmel/state/cadence-alerts.log),
# CADENCE_ALERT_DEDUPE_DIR (default ~/.himmel/state/cadence-alert-sent),
# CADENCE_ALERT_SEND_CMD (default vault-stall-alert.sh; called with one
# argument, the message).
#
# Always exits 0: alerting must never change a runner's own exit status.
set -u

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="${HOME:-}/.himmel/state"
alert_file="${CADENCE_ALERT_FILE:-$state/cadence-alerts.log}"
dedupe_dir="${CADENCE_ALERT_DEDUPE_DIR:-$state/cadence-alert-sent}"
send_cmd="${CADENCE_ALERT_SEND_CMD:-$_here/vault-stall-alert.sh}"

# A leg or reason becomes part of a sentinel filename: keep it to safe bytes.
# No `.` survives, so `<leg>.<reason>` splits unambiguously and `clear a`
# cannot match leg `a.b`'s sentinels.
_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

case "${1:-}" in
    fail)
        leg="${2:-unknown}" reason="${3:-unknown}" log="${4:-}"
        mkdir -p "$(dirname "$alert_file")" "$dedupe_dir" 2>/dev/null
        printf '%s %s %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$leg" "$reason" "$log" >> "$alert_file" \
            || echo "cadence-alert: could not append to $alert_file" >&2
        sentinel="$dedupe_dir/$(_slug "$leg").$(_slug "$reason")"
        # The sentinel is written only AFTER a delivered send: an unwritable
        # dedupe dir, a failed send or an interrupted one never suppresses the
        # next alert. Two concurrent failures of one leg could both send; one
        # runner per leg per night makes that a harmless double DM at worst.
        if [ ! -e "$sentinel" ]; then
            if "$send_cmd" "cadence leg failed: $leg $reason (log: $log)"; then
                : > "$sentinel" 2>/dev/null \
                    || echo "cadence-alert: could not record dedupe sentinel $sentinel" >&2
            else
                echo "cadence-alert: Telegram send failed for $leg $reason" >&2
            fi
        fi
        ;;
    clear)
        leg="${2:-}"
        [ -n "$leg" ] && rm -f "$dedupe_dir/$(_slug "$leg")".*
        ;;
    *)
        echo "usage: cadence-alert.sh fail <leg> <reason> <log> | clear <leg>" >&2
        ;;
esac
exit 0
