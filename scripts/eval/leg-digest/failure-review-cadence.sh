#!/usr/bin/env bash
# failure-review-cadence.sh — the daily failure review on a schedule (HIMMEL-4713, P5b of HIMMEL-4670).
#
# WHY: the failure loop records failures on every leg close and the router (failure_router.py) turns
# recurring classes into tickets, but nothing ran the router or showed the operator what failed.
# This is the daily run; failure_review.py is the work. No model is ever run.
#
#   failure-review-cadence.sh run                      one pass (what cron fires)
#   failure-review-cadence.sh arm [--time HH:MM] [--vault PATH] [--live] [--force] [--dry-run]
#   failure-review-cadence.sh status
#   failure-review-cadence.sh disarm [--dry-run]
#
# DRY-RUN BY DEFAULT: a scheduled run passes the router's dry-run, so it files nothing and calls no
# Jira. Live routing is an install-time opt-in: `arm --live` bakes --live into the runner, and
# `arm --force` without it goes back to dry-run. The digest names the mode on every run.
# `arm --live` also bakes the current JIRA_PROJECT_KEY into the runner (cron has none) and refuses
# when it is unset or not a project key; dry-run needs no key.
#
# `run` asks scripts/lib/bank-preflight.sh first, like every pipeline cadence leg, and branches on
# its verdict token: SKIPPED-BANK skips the night (logged, rc 0); every other verdict runs. It then
# runs failure_review.py from the PRIMARY checkout (the runner bakes that path) and, on a router
# failure, alerts through scripts/luna/cadence-alert.sh; a clean run clears that alert.
#
# Seams (tests): FAILREV_CRONTAB, FAILREV_RUNNER_DIR, FAILURE_REVIEW_PREFLIGHT, plus
# failure_review.py's own (HIMMEL_FAILURE_REVIEW_DIR, FAILURE_REVIEW_NOTIFY_CMD) and the router's.
# Platform: cron (Linux/macOS). Windows development is parked (HIMMEL-4102).
set -uo pipefail

TASK_NAME="HIMMEL-FailureReview"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CRONTAB_BIN="${FAILREV_CRONTAB:-crontab}"
RUNNER_DIR="${FAILREV_RUNNER_DIR:-${HOME:-}/.claude/failure-review-cadence}"
# shellcheck source=../../lib/resolve-user-home.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/resolve-user-home.sh"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# cmd_run takes failure_review.py's own flags (the runner passes --vault and, when armed so, --live).
cmd_run() {
    local verdict rc
    verdict="$(bash "${FAILURE_REVIEW_PREFLIGHT:-$ROOT/scripts/lib/bank-preflight.sh}" 2>/dev/null | tail -n 1)"
    echo "failure-review-cadence: bank preflight ${verdict:-<none>}"
    if [ "$verdict" = "SKIPPED-BANK" ]; then
        echo "failure-review-cadence: SKIPPED-BANK, no run tonight"
        return 0
    fi
    python3 "$SCRIPT_DIR/failure_review.py" "$@"; rc=$?
    if [ "$rc" -ne 0 ]; then
        bash "$ROOT/scripts/luna/cadence-alert.sh" fail failure-review "rc=$rc" "$RUNNER_DIR/failure-review-cadence.log"
    else
        bash "$ROOT/scripts/luna/cadence-alert.sh" clear failure-review
    fi
    return "$rc"
}

# "no crontab for <user>" is an empty table; any other read failure is an error
# (installing over it would drop the operator's other jobs).
cron_read() {
    local err
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR failure-review-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local time="06:15" vault="" live=0 force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --time|--vault) [ $# -ge 2 ] || { echo "ERR failure-review-cadence: $1 needs a value" >&2; return 1; }
                    if [ "$1" = --time ]; then time="$2"; else vault="$2"; fi; shift 2 ;;
            --live) live=1; shift ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR failure-review-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR failure-review-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    # The router fails closed without a project key and cron has none, so a live runner carries it (HIMMEL-4792).
    if [ "$live" -eq 1 ]; then
        [[ "${JIRA_PROJECT_KEY:-}" =~ ^[A-Z][A-Z0-9]+$ ]] || { echo "ERR failure-review-cadence: --live needs JIRA_PROJECT_KEY set to a project key (got: ${JIRA_PROJECT_KEY:-<unset>})" >&2; return 2; }
    fi
    [ -n "$vault" ] || vault="$(default_vault)"
    [ -d "$vault" ] || { echo "ERR failure-review-cadence: vault not found: $vault (pass --vault)" >&2; return 1; }
    # cron runs from $HOME, so the runner gets the absolute path.
    vault="$(cd "$vault" && pwd)" || { echo "ERR failure-review-cadence: cannot resolve the vault path" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR failure-review-cadence: cron only; Windows is parked (HIMMEL-4102)" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR failure-review-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR failure-review-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR failure-review-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/failure-review-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * * \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY failure-review-cadence: would write $runner ($([ "$live" -eq 1 ] && echo live || echo dry-run) routing) and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # The new runner goes in beside the old one and replaces it only once the crontab is installed:
    # a failed install must leave the armed schedule running the runner it was armed with.
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# failure-review-cadence runner — generated by failure-review-cadence.sh arm (HIMMEL-4713)\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        [ "$live" -eq 1 ] && printf 'JIRA_PROJECT_KEY=%q\nexport JIRA_PROJECT_KEY\n' "$JIRA_PROJECT_KEY"
        printf 'log=%q\n' "$RUNNER_DIR/failure-review-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf 'echo "[fired $(date "+%%F %%T")]" >> "$log"\n'
        printf '%q %q run --vault %q%s >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/eval/leg-digest/failure-review-cadence.sh" \
            "$vault" "$([ "$live" -eq 1 ] && printf ' --live')"
    } > "$runner.new" || { rm -f "$runner.new"; echo "ERR failure-review-cadence: cannot write the runner $runner.new" >&2; return 4; }
    chmod +x "$runner.new" || { rm -f "$runner.new"; echo "ERR failure-review-cadence: cannot chmod the runner $runner.new" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { rm -f "$runner.new"; echo "ERR failure-review-cadence: crontab install failed" >&2; return 4; }
    if ! mv -f "$runner.new" "$runner"; then
        rm -f "$runner.new"
        # The new entry must not outlive its runner: put the crontab back as it was read.
        { printf '%s\n' "$CRON_TAB" | sed '/^$/d'; } | "$CRONTAB_BIN" - \
            || echo "ERR failure-review-cadence: could not restore the previous crontab; check 'crontab -l'" >&2
        echo "ERR failure-review-cadence: cannot install the runner $runner (crontab restored)" >&2
        return 4
    fi
    echo "failure-review-cadence ARMED: daily $time, $([ "$live" -eq 1 ] && echo LIVE || echo dry-run) routing — $runner"
}

cmd_status() {
    local runner="$RUNNER_DIR/failure-review-cadence.sh" mode=dry-run
    cron_read || return 1
    grep -q -- '--live' "$runner" 2>/dev/null && mode=live
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'), $mode routing)"
    else echo "not armed  $TASK_NAME"; fi
    [ -f "$RUNNER_DIR/failure-review-cadence.log" ] && echo "  last run   $(tail -n 1 "$RUNNER_DIR/failure-review-cadence.log")"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "failure-review-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY failure-review-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/failure-review-cadence.sh"
    echo "failure-review-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: failure-review-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
