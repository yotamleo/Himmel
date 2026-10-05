#!/usr/bin/env bash
# qmd-quality-cadence.sh — run the qmd retrieval-quality eval weekly, append the
# metrics to a log and tell the operator when MRR drops (HIMMEL-4184, ask 5).
#
# WHY: retrieval quality drifts silently (a model swap, a reindex, a changed
# chunker) and nobody reruns qmd-quality.sh by hand. This keeps one metrics
# row per mode per run so drift is visible, and alerts through the HIMMEL-4181
# path (scripts/luna/cadence-alert.sh) when a mode regresses.
#
#   qmd-quality-cadence.sh run --golden <file> --index <file>   (what cron fires)
#   qmd-quality-cadence.sh arm --golden <file> [--index <file>] [--day 0-6]
#                              [--time HH:MM] [--force] [--dry-run]
#   qmd-quality-cadence.sh status
#   qmd-quality-cadence.sh disarm [--dry-run]
#
# `run` calls qmd-quality.sh (--scope golden) into a fresh run dir and ALWAYS
# deletes that run's ~1.8 GB index snapshot afterwards. State under
# ~/.himmel/state/qmd-quality/:
#   runs/<UTC ts>/   eval.log, scores.tsv, runs.jsonl ... (newest 8 kept)
#   metrics.tsv      "ts mode n hit@1 hit@5 mrr" per mode per run (the ALL rows)
# A mode whose mrr fell by MORE than QMD_QUALITY_DRIFT_MRR (default 0.05) since
# its previous row alerts; a mode with no previous row is a baseline. A failed
# eval or an empty scores.tsv alerts too.
#
# ponytail: compares each mode only with the previous run, so a slow drift under QMD_QUALITY_DRIFT_MRR per week never alerts, upgrade path: compare with the best of the last N runs once metrics.tsv shows such a drift (HIMMEL-4184 follow-up).
#
# OFF by default: only `arm` installs it; arming on a station is an operator
# step after a VM proof. It is in no registry or wizard.
#
# Seams (tests): QMD_QUALITY_STATE_DIR, QMD_QUALITY_EVAL_CMD (replaces
# qmd-quality.sh, same arguments), QMD_QUALITY_TS (the run timestamp),
# QMD_QUALITY_KEEP_RUNS, QMD_QUALITY_DRIFT_MRR, QMDQUAL_CRONTAB,
# QMDQUAL_RUNNER_DIR, plus cadence-alert.sh's own CADENCE_ALERT_* seams.
# Platform: cron (Linux/macOS). Windows development is parked (HIMMEL-4102).
set -uo pipefail

TASK_NAME="HIMMEL-Qmd-Quality"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT="$SCRIPT_DIR/../../luna/cadence-alert.sh"
STATE_DIR="${QMD_QUALITY_STATE_DIR:-${HOME:-}/.himmel/state/qmd-quality}"
CRONTAB_BIN="${QMDQUAL_CRONTAB:-crontab}"
RUNNER_DIR="${QMDQUAL_RUNNER_DIR:-${HOME:-}/.claude/qmd-quality-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# abs_path <file>: absolute form of an existing file's path.
abs_path() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")"); }

# Run dir names sort chronologically; keep the newest N, failed runs included.
prune_runs() {
    local keep="${QMD_QUALITY_KEEP_RUNS:-8}" d
    # shellcheck disable=SC2012  # run dir names are our own timestamps
    for d in $(ls -1 "$STATE_DIR/runs" 2>/dev/null | sort -r | tail -n +$((keep + 1))); do
        rm -rf "${STATE_DIR:?}/runs/$d"
    done
}

cmd_run() {
    local golden="${QMD_QUALITY_GOLDEN:-}" index="" ts out rc rows mode n h1 h5 mrr prev
    local regressed="" log thr
    while [ $# -gt 0 ]; do
        case "$1" in
            --golden) [ $# -ge 2 ] || { echo "ERR qmd-quality-cadence: --golden needs a value" >&2; return 64; }
                      golden="$2"; shift 2 ;;
            --index) [ $# -ge 2 ] || { echo "ERR qmd-quality-cadence: --index needs a value" >&2; return 64; }
                     index="$2"; shift 2 ;;
            *) echo "ERR qmd-quality-cadence: unknown arg: $1" >&2; return 64 ;;
        esac
    done
    # A golden set or index gone since `arm` is a failed leg, not a quiet log line.
    if [ ! -f "$golden" ] || [ ! -f "$index" ]; then
        echo "ERR qmd-quality-cadence: --golden (or QMD_QUALITY_GOLDEN) and --index must name files" >&2
        bash "$ALERT" fail qmd-quality missing-input "golden=$golden index=$index"
        return 64
    fi
    ts="${QMD_QUALITY_TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
    out="$STATE_DIR/runs/$ts"
    mkdir -p "$out" || return 2
    # an interrupted run (cron kill, shutdown) must not strand the snapshot either.
    # ponytail: a SIGKILL skips the trap, so the leak is bounded only by prune_runs; sweep stale snapshots under a run lock (HIMMEL-4500).
    SNAPSHOT="$out/index.sqlite"
    trap 'rm -f "$SNAPSHOT"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ -n "${QMD_QUALITY_EVAL_CMD:-}" ]; then
        "$QMD_QUALITY_EVAL_CMD" --index "$index" --out "$out" --golden "$golden" --scope golden > "$out/eval.log" 2>&1
    else
        bash "$SCRIPT_DIR/qmd-quality.sh" --index "$index" --out "$out" --golden "$golden" --scope golden > "$out/eval.log" 2>&1
    fi
    rc=$?
    # the snapshot is ~1.8 GB: it must not accumulate, whatever the outcome.
    rm -f "$out/index.sqlite"
    prune_runs
    if [ "$rc" -ne 0 ]; then
        bash "$ALERT" fail qmd-quality "eval-rc-$rc" "$out/eval.log"
        return 1
    fi
    rows="$(awk -F'\t' '$2 == "ALL"' "$out/scores.tsv" 2>/dev/null)"
    if [ -z "$rows" ]; then
        bash "$ALERT" fail qmd-quality no-scores "$out/eval.log"
        return 1
    fi
    log="$STATE_DIR/metrics.tsv"
    if [ ! -f "$log" ] && ! printf 'ts\tmode\tn\thit@1\thit@5\tmrr\n' > "$log"; then
        bash "$ALERT" fail qmd-quality metrics-write "$out/eval.log"
        return 2
    fi
    thr="${QMD_QUALITY_DRIFT_MRR:-0.05}"
    while IFS=$'\t' read -r mode _ n h1 h5 mrr _; do
        # the previous row is read BEFORE this run's row is appended.
        prev="$(awk -F'\t' -v m="$mode" '$2 == m { p = $6 } END { print p }' "$log")"
        if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$mode" "$n" "$h1" "$h5" "$mrr" >> "$log"; then
            bash "$ALERT" fail qmd-quality metrics-write "$out/eval.log"
            return 2
        fi
        [ -n "$prev" ] || continue
        if awk -v p="$prev" -v c="$mrr" -v t="$thr" 'BEGIN { exit !((p - c) > t + 1e-9) }'; then
            regressed="${regressed:+$regressed, }$mode $prev->$mrr"
        fi
    done <<< "$rows"
    # clear first: the sender's per-reason dedupe must not mute a drop that
    # recovered and came back; this script's prev-diff is the dedupe.
    bash "$ALERT" clear qmd-quality
    [ -z "$regressed" ] || bash "$ALERT" fail qmd-quality "mrr-drop: $regressed" "$out/scores.tsv"
    return 0
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
        *) echo "ERR qmd-quality-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local golden="${QMD_QUALITY_GOLDEN:-}" index="${XDG_CACHE_HOME:-${HOME:-}/.cache}/qmd/index.sqlite"
    local day=0 time="06:00" force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --golden|--index|--day|--time)
                [ $# -ge 2 ] || { echo "ERR qmd-quality-cadence: $1 needs a value" >&2; return 1; }
                case "$1" in
                    --golden) golden="$2" ;; --index) index="$2" ;;
                    --day) day="$2" ;; --time) time="$2" ;;
                esac
                shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR qmd-quality-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$day" =~ ^[0-6]$ ]] || { echo "ERR qmd-quality-cadence: --day must be 0-6, got: $day" >&2; return 1; }
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR qmd-quality-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    [ -f "$golden" ] || { echo "ERR qmd-quality-cadence: --golden (or QMD_QUALITY_GOLDEN) must name an existing file" >&2; return 1; }
    [ -f "$index" ] || { echo "ERR qmd-quality-cadence: index not found: $index (pass --index)" >&2; return 1; }
    golden="$(abs_path "$golden")"; index="$(abs_path "$index")"
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR qmd-quality-cadence: cron only; Windows is parked (HIMMEL-4102)" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR qmd-quality-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR qmd-quality-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR qmd-quality-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/qmd-quality-cadence.sh"
    entry="${time#*:} ${time%:*} * * $day \"$runner\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY qmd-quality-cadence: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# qmd-quality-cadence runner — generated by qmd-quality-cadence.sh arm (HIMMEL-4184)\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/qmd-quality-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run --golden %q --index %q >> "$log" 2>&1\n' \
            "$bash_bin" "$root/scripts/eval/qmd-quality/qmd-quality-cadence.sh" "$golden" "$index"
    } > "$runner" || { echo "ERR qmd-quality-cadence: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || { echo "ERR qmd-quality-cadence: cannot chmod the runner $runner" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR qmd-quality-cadence: crontab install failed" >&2; return 4; }
    echo "qmd-quality-cadence ARMED: weekly day $day $time — $runner (status: bash scripts/eval/qmd-quality/qmd-quality-cadence.sh status)"
}

cmd_status() {
    local last
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    if [ -f "$STATE_DIR/metrics.tsv" ]; then
        last="$(awk -F'\t' 'NR > 1 { t = $1 } END { print t }' "$STATE_DIR/metrics.tsv")"
        [ -z "$last" ] || { echo "  last run   $last"; awk -F'\t' -v t="$last" '$1 == t { print "    " $2 "  n=" $3 "  hit@1=" $4 "  hit@5=" $5 "  mrr=" $6 }' "$STATE_DIR/metrics.tsv"; }
    fi
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "qmd-quality-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY qmd-quality-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/qmd-quality-cadence.sh"
    echo "qmd-quality-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: qmd-quality-cadence.sh <run|arm|status|disarm>" >&2; exit 64 ;;
esac
