#!/usr/bin/env bash
# doctor-cadence.sh — run himmel-doctor daily and tell the operator when it
# finds something new (HIMMEL-4251).
#
# WHY: himmel-doctor flagged the missing pre-commit/commit-msg hooks (C16) for
# nine days (HIMMEL-4243) and nobody saw it, because nothing ran the doctor on a
# schedule. This is the visibility half; repair is `himmel-update`'s drift pass
# (HIMMEL-4246). Nothing here fixes anything.
#
#   doctor-cadence.sh run                  one pass (what cron fires)
#   doctor-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   doctor-cadence.sh status
#   doctor-cadence.sh disarm [--dry-run]
#
# `run` executes scripts/himmel-doctor.sh from the PRIMARY checkout (resolved
# via git-common-dir: a worktree run gives false C16 reds), then keeps the
# result under ~/.himmel/state/doctor-cadence/:
#   last.tsv   "<SEV> <id>" per FAIL/WARN of the latest run
#   prev.tsv   the run before it (what the next run diffs against)
#   counts     "fail=<n> warn=<n>" — read by the statusline segment
# An alert goes out (through scripts/luna/cadence-alert.sh, the existing
# Telegram path) when a FAIL or a WARN is absent from the previous run. The
# first-ever run is a baseline: only FAILs alert, so arming does not DM the
# operator every standing WARN. A doctor that prints no Summary line (crashed)
# alerts and leaves the state alone.
#
# ponytail: the diff baseline advances even when the Telegram send fails (the
# sender's own result is not visible here), so a lost DM is not retried,
# upgrade path: have cadence-alert.sh return the delivery status (HIMMEL-4226).
#
# Seams (tests): HIMMEL_DOCTOR_STATE_DIR, DOCTORCAD_CRONTAB, DOCTORCAD_RUNNER_DIR.
# Platform: cron (Linux/macOS). Windows development is parked (HIMMEL-4102).
set -uo pipefail

TASK_NAME="HIMMEL-Doctor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HIMMEL_DOCTOR_STATE_DIR:-${HOME:-}/.himmel/state/doctor-cadence}"
CRONTAB_BIN="${DOCTORCAD_CRONTAB:-crontab}"
RUNNER_DIR="${DOCTORCAD_RUNNER_DIR:-${HOME:-}/.claude/doctor-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# cmd_run is a plain pass; cmd_arm/cmd_status/cmd_disarm are the contract
# test-wizard-cadence-registry.sh lints every registry row for.
cmd_run() {
    local root out keys new="" k sev
    root="$(resolve_primary)" || { echo "doctor-cadence: cannot resolve the primary checkout" >&2; return 2; }
    mkdir -p "$STATE_DIR" || return 2
    out="$STATE_DIR/last-run.log"
    (cd "$root" && bash "$root/scripts/himmel-doctor.sh" --no-color </dev/null) > "$out" 2>&1
    if ! grep -q '^Summary: ' "$out"; then
        bash "$root/scripts/luna/cadence-alert.sh" fail himmel-doctor no-summary "$out"
        return 1
    fi
    keys="$(sed -n -E 's/^(FAIL|WARN) +([A-Za-z0-9_-]+):.*/\1 \2/p' "$out" | sort -u)"
    local first=0
    [ -f "$STATE_DIR/last.tsv" ] || first=1
    if [ "$first" -eq 0 ]; then cp -f "$STATE_DIR/last.tsv" "$STATE_DIR/prev.tsv"; else : > "$STATE_DIR/prev.tsv"; fi
    printf '%s\n' "$keys" | sed '/^$/d' > "$STATE_DIR/last.tsv"
    printf 'fail=%s warn=%s\n' \
        "$(grep -c '^FAIL ' "$STATE_DIR/last.tsv")" "$(grep -c '^WARN ' "$STATE_DIR/last.tsv")" > "$STATE_DIR/counts"
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        grep -qxF "$k" "$STATE_DIR/prev.tsv" && continue
        sev="${k%% *}"
        [ "$first" -eq 1 ] && [ "$sev" != FAIL ] && continue
        new="${new:+$new, }$k"
    done <<< "$keys"
    if [ -n "$new" ]; then
        # clear first: the sender's per-reason dedupe must not mute a key that
        # went away and came back; THIS script's prev-diff is the dedupe.
        bash "$root/scripts/luna/cadence-alert.sh" clear himmel-doctor
        bash "$root/scripts/luna/cadence-alert.sh" fail himmel-doctor "new: $new" "$out"
    fi
    return 0
}

cron_read() {
    CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>/dev/null)" || CRON_TAB=""
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local time="05:30" force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --time) time="${2:-}"; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR doctor-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR doctor-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR doctor-cadence: cron only; Windows is parked (HIMMEL-4102)" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR doctor-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR doctor-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR doctor-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/doctor-cadence.sh"
    entry="${time#*:} ${time%:*} * * * $runner # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY doctor-cadence: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/bin/sh\n# doctor-cadence runner — generated by doctor-cadence.sh arm (HIMMEL-4251)\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/doctor-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/doctor-cadence.sh"
    } > "$runner"
    chmod +x "$runner"
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR doctor-cadence: crontab install failed" >&2; return 4; }
    echo "doctor-cadence ARMED: daily $time — $runner (status: bash scripts/doctor-cadence.sh status)"
}

cmd_status() {
    cron_read
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    [ -f "$STATE_DIR/counts" ] && echo "  last run   $(cat "$STATE_DIR/counts") ($(date -r "$STATE_DIR/counts" '+%Y-%m-%d %H:%M' 2>/dev/null))"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read
    if [ -z "$(cron_entry)" ]; then echo "doctor-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY doctor-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/doctor-cadence.sh"
    echo "doctor-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: doctor-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
