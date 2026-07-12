#!/usr/bin/env bash
# pipeline-cadence.sh — arm/status/disarm the recurring clip-pipeline
# cadence (HIMMEL-255).
#
# The luna vault's runbooks table gives only loose guidance
# (/synthesize-clips = "after a clip batch", /obsidian-health = "after
# big ingests") — but nothing was scheduled; every run was operator-
# remembered. The pipeline is idempotent at every stage by design
# (markers: harvested_at, processed, synthesis dedup window, _done/
# move) — exactly the cron-safe shape. This script registers the three
# recurring jobs with the OS scheduler, following the
# scripts/handover/arm-resume.sh precedent (HIMMEL-122):
#
#   HIMMEL-Pipeline-Harvest     daily   (default 02:00, model: sonnet)  HIMMEL-357/798
#       claude --model sonnet "/harvest-clips ... then /triage-clips ... then /ig-media-enrich ..." < NUL
#   HIMMEL-Pipeline-Synthesize  daily   (default 03:00, model: sonnet)
#       claude --model sonnet "/synthesize-clips … then /archive-clips …" < NUL
#   HIMMEL-Pipeline-Health      weekly  (default Sun 04:00, model: haiku)
#       claude --model haiku "/obsidian-health …" < NUL
#
# Defaults are the operator decision pinned on HIMMEL-255 (2026-06-10),
# plus the daily harvest+triage leg added on HIMMEL-357 (2026-06-17),
# the bounded ig-media-enrich chain link added on HIMMEL-798, and the
# per-leg model pins + frequency shift on HIMMEL-506 (2026-07-11):
# harvest+triage+ig-media-enrich daily at 02:00 (cheap, idempotent,
# keeps the Clippings/ inbox flowing and drains pending Instagram media
# across nights); synthesize+archive DAILY at 03:00 — synthesis is now
# cheap enough to run nightly once pinned to a cheap model, so cross-clip
# themes surface without a week's lag (archive only graduates clips
# synthesis has wikilinked, so it follows synth in the SAME session);
# health WEEKLY on Sunday at 04:00; machine assumed awake. Every leg
# launches with an explicit --model pin (harvest/synth=sonnet,
# health=haiku) so the cadence never inherits the operator's saved
# default (the scarcest tier) — the cheap pins are what make the higher
# frequencies affordable. All overridable via flags.
#
# The armed command is interactive-claude shaped — `claude "<prompt>"`
# with stdin redirected from NUL (the bounded-run primitive: the session
# runs the full turn, then exits clean). NOT headless (`-p`/`--print`)
# (HIMMEL-128 billing rule: headless invocations bill to a separate
# Agent SDK credit bucket from 2026-06-15; interactive stays on Max
# quota). Each task fires a runner (.bat on Windows, .sh on POSIX) that
# cd's into the luna vault so the obsidian-triage skills operate on the
# right tree.
#
# Windows (schtasks) is the primary platform per the HIMMEL-255
# acceptance criteria. macOS/Linux use crontab entries (HIMMEL-265),
# following the arm-resume.sh crontab-fallback precedent: each entry
# fires a persistent runner .sh (same role as the Windows .bat — log
# rotation + fire stamp + cd into the vault + bounded claude run) and
# carries a trailing `# HIMMEL-Pipeline-*` marker so dedup/status/
# disarm can find it (cron hands the whole line to /bin/sh, which reads
# the marker as a shell comment at fire time — same trick as
# arm-resume's crontab entry).
#
# Usage:
#   bash scripts/luna/pipeline-cadence.sh arm [--harvest-time HH:MM]
#       [--ig-limit N] [--synth-time HH:MM] [--health-day DAY]
#       [--health-time HH:MM] [--harvest-model M] [--synth-model M]
#       [--health-model M] [--vault PATH] [--force] [--dry-run]
#   bash scripts/luna/pipeline-cadence.sh status
#   bash scripts/luna/pipeline-cadence.sh disarm
#
# Test seams (used by test-pipeline-cadence.sh):
#   PIPELINE_SCHTASKS  — command invoked instead of `schtasks` (Windows)
#   PIPELINE_CRONTAB   — command invoked instead of `crontab` (POSIX)
#   PIPELINE_BAT_DIR   — where the persistent runners (.bat/.sh) live
#
# Exit codes (mirrors arm-resume.sh):
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error
#   2  env unusable (no schtasks/crontab; unknown platform; query tool errored)
#   3  dedup block — HIMMEL-Pipeline-* task(s) already armed; use --force
#   4  scheduler invocation failed (/create, /delete, crontab rewrite,
#      path conversion)
set -euo pipefail

TASK_PREFIX="HIMMEL-Pipeline-"
TASK_HARVEST="${TASK_PREFIX}Harvest"
TASK_SYNTH="${TASK_PREFIX}Synthesize"
TASK_HEALTH="${TASK_PREFIX}Health"
SCHTASKS_BIN="${PIPELINE_SCHTASKS:-schtasks}"
CRONTAB_BIN="${PIPELINE_CRONTAB:-crontab}"

# Cross-platform user-home resolution (HIMMEL-645, generalized from
# HIMMEL-642's default_vault). On Windows Git-Bash $HOME can be the MSYS home
# (/home/<user>) while Claude Code's config (~/.claude) and the luna vault live
# under the Windows user profile, so prefer USERPROFILE via cygpath BEFORE
# $HOME. POSIX hosts have USERPROFILE unset and fall straight through to $HOME,
# unchanged. /tmp is the last-resort floor when both are unset.
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home (.bat on Windows, .sh on POSIX) — NOT mktemp
# like arm-resume's one-shot task: these tasks recur indefinitely, and
# %TEMP% / /tmp are subject to cleanup sweeps that would silently kill
# the cadence. Default home resolved cross-platform (HIMMEL-645): the bare
# $HOME default put the runners under the MSYS home on Windows Git-Bash,
# where Claude Code does not read its config.
BAT_DIR="${PIPELINE_BAT_DIR:-$(resolve_user_home)/.claude/pipeline-cadence}"

# HIMMEL-575: a `claude --settings` fragment that wires himmel's
# auto-approve-safe-bash PreToolUse hook by ABSOLUTE path. The cadence fires in
# the luna vault cwd, which carries no himmel .claude/settings.json — so without
# this an autonomous run STALLS on the HIMMEL-203 compound-bash permission
# prompt (the static matcher bails on any `$var`/`$()`/pipe/compound command and
# prompts; an unattended `< NUL` run has nobody to answer it, wasting the run).
# Injecting the hook by absolute himmel path — resolved here at arm time —
# restores the auto-approve posture in the luna cwd. The hook only ever GRANTS
# (fail-open; never blocks), so this widens nothing the block-* hooks guard.
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
AUTO_APPROVE_HOOK="$HIMMEL_ROOT/scripts/hooks/auto-approve-safe-bash.sh"
SETTINGS_FRAGMENT="$BAT_DIR/cadence-settings.json"

# Runner-format version stamp (HIMMEL-588): emit_bat / emit_runner stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner so himmel-doctor / himmel-update
# can detect a cadence armed before a format change and nudge `arm --force`.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"

# Operator-decision defaults (HIMMEL-255 pinned comment, 2026-06-10;
# harvest leg added on HIMMEL-357, 2026-06-17; model pins + frequency
# shift on HIMMEL-506, 2026-07-11: synth weekly->daily, health
# monthly->weekly, per-leg --model pins so the cadence never inherits
# the operator's saved default tier).
HARVEST_TIME="02:00"
IG_LIMIT="10"
SYNTH_TIME="03:00"
HEALTH_DAY="SUN"
HEALTH_TIME="04:00"
HARVEST_MODEL="sonnet"
SYNTH_MODEL="sonnet"
HEALTH_MODEL="haiku"

# Default vault resolution (cross-platform; HIMMEL-642). Honors
# LUNA_VAULT_PATH first — the vault path adopt.sh persists into
# .claude/settings.json (HIMMEL-458) and himmel-doctor probes first — so an
# adopted setup needs no --vault. Otherwise fall back to <home>/Documents/luna
# via the shared cross-platform home resolver (HIMMEL-645). Explicit --vault
# always overrides (parsed below).
default_vault() {
    if [ -n "${LUNA_VAULT_PATH:-}" ]; then
        printf '%s' "$LUNA_VAULT_PATH"
        return
    fi
    printf '%s/Documents/luna' "$(resolve_user_home)"
}
VAULT="$(default_vault)"
FORCE=0
DRY_RUN=0

# Prompts are ASCII-only on purpose: the .bat is parsed by cmd.exe under
# the OEM codepage, where UTF-8 punctuation mojibakes into the prompt.
DAILY_CHAIN="/harvest-clips + /triage-clips + /ig-media-enrich"
HARVEST_PROMPT=""
SYNTH_PROMPT="Run /synthesize-clips to completion, then run /archive-clips. This is the scheduled daily pipeline cadence run (HIMMEL-255) - fully autonomous, no user prompts; report results and exit."
HEALTH_PROMPT="Run /obsidian-health to completion. This is the scheduled weekly pipeline cadence run (HIMMEL-255) - fully autonomous, no user prompts; report results and exit."

usage() {
    cat <<'EOF'
Usage: pipeline-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring clip-pipeline cadence
(HIMMEL-255/357/798): daily /harvest-clips (+ /triage-clips and
/ig-media-enrich chained after in the same session), daily
/synthesize-clips (+ /archive-clips chained after) and weekly
/obsidian-health, run against the luna vault as interactive bounded
claude sessions. Each leg launches with an explicit cheap --model pin
(HIMMEL-506) so the cadence never inherits the operator's saved default.

Subcommands:
  arm      Register all three recurring tasks. Dedup-guarded: refuses
           (rc=3) if any HIMMEL-Pipeline-* task already exists; --force
           replaces.
  status   Show which cadence tasks are armed (+ next run time + the
           pinned model parsed back out of each runner).
  disarm   Remove all tasks (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --harvest-time <HH:MM> Daily harvest+triage+ig-media-enrich time,
                         24h local (default 02:00)
  --ig-limit <N>         Daily /ig-media-enrich --limit N (default 10;
                         0 = unlimited)
  --synth-time <HH:MM>   Daily synthesize time, 24h local (default 03:00)
  --health-day <DAY>     Weekly health day: MON..SUN (default SUN)
  --health-time <HH:MM>  Weekly health time, 24h local (default 04:00)
  --harvest-model <m>    claude --model for the harvest leg (default sonnet)
  --synth-model <m>      claude --model for the synthesize leg (default sonnet)
  --health-model <m>     claude --model for the health leg (default haiku)
  --vault <PATH>         Luna vault root (default: $LUNA_VAULT_PATH if set,
                         else <user-profile>/Documents/luna — on Windows
                         Git-Bash the Windows profile, not the MSYS $HOME)
  --force                Replace existing HIMMEL-Pipeline-* tasks
  --dry-run              Print what would happen, touch nothing
                         (honored by arm AND disarm)
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR pipeline-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR pipeline-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --harvest-time)   HARVEST_TIME="${2:-}"; shift 2 ;;
        --harvest-time=*) HARVEST_TIME="${1#--harvest-time=}"; shift ;;
        --ig-limit)      IG_LIMIT="${2:-}"; shift 2 ;;
        --ig-limit=*)    IG_LIMIT="${1#--ig-limit=}"; shift ;;
        --synth-day|--synth-day=*)
            echo "ERR pipeline-cadence: --synth-day is no longer supported — synthesize is daily now (HIMMEL-506); use --synth-time to set the time" >&2
            exit 1 ;;
        --synth-time)    SYNTH_TIME="${2:-}"; shift 2 ;;
        --synth-time=*)  SYNTH_TIME="${1#--synth-time=}"; shift ;;
        --health-day)    HEALTH_DAY="${2:-}"; shift 2 ;;
        --health-day=*)  HEALTH_DAY="${1#--health-day=}"; shift ;;
        --health-time)   HEALTH_TIME="${2:-}"; shift 2 ;;
        --health-time=*) HEALTH_TIME="${1#--health-time=}"; shift ;;
        --harvest-model)   HARVEST_MODEL="${2:-}"; shift 2 ;;
        --harvest-model=*) HARVEST_MODEL="${1#--harvest-model=}"; shift ;;
        --synth-model)   SYNTH_MODEL="${2:-}"; shift 2 ;;
        --synth-model=*) SYNTH_MODEL="${1#--synth-model=}"; shift ;;
        --health-model)  HEALTH_MODEL="${2:-}"; shift 2 ;;
        --health-model=*) HEALTH_MODEL="${1#--health-model=}"; shift ;;
        --vault)         VAULT="${2:-}"; shift 2 ;;
        --vault=*)       VAULT="${1#--vault=}"; shift ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERR pipeline-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

HARVEST_PROMPT="Run /harvest-clips to completion, then run /triage-clips, then run /ig-media-enrich --limit $IG_LIMIT. The /ig-media-enrich step uses --limit $IG_LIMIT; 0 means unlimited, otherwise one night's batch is bounded and the ig_media_pending backlog drains across nights. If /ig-media-enrich fails due to missing ffmpeg/whisper, expired IG cookies, or media download errors, report the failure but it must not abort or fail the harvest+triage leg; finish the session normally. This is the scheduled daily pipeline cadence run (HIMMEL-357/HIMMEL-798) - fully autonomous, no user prompts; report results and exit."

# Platform detect (same matrix as arm-resume.sh).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)                           PLATFORM=unknown ;;
esac
case "$PLATFORM" in
    windows)
        command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
            echo "ERR pipeline-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
            exit 2
        }
        ;;
    linux|macos)
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR pipeline-cadence: '$CRONTAB_BIN' not on PATH (required on $PLATFORM — HIMMEL-265 cron port)" >&2
            exit 2
        }
        ;;
    *)
        echo "ERR pipeline-cadence: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Windows (schtasks), Linux/macOS (crontab)" >&2
        exit 2
        ;;
esac

# MSYS_NO_PATHCONV=1 per call (HIMMEL-125): without it gitbash mangles
# /query, /create etc. into Windows-rooted paths before schtasks sees them.
run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# Escape CMD metacharacters for values interpolated into the .bat —
# same escape (and same order: " %, then ^, then the chars that GAIN a
# caret) as arm-resume.sh, so a vault path containing legal-but-hostile
# chars (% & ^ are valid in Windows dirnames) can't inject commands at
# fire time.
cmd_escape() {
    local s="$1"
    s="${s//\"/\\\"}"
    s="${s//%/%%}"
    s="${s//^/^^}"
    s="${s//&/^&}"
    s="${s//</^<}"
    s="${s//>/^>}"
    s="${s//|/^|}"
    printf '%s' "$s"
}

# Dedup listing: every scheduled task named HIMMEL-Pipeline-*.
# Fail-CLOSED if the query tool itself errors — a silent empty result
# followed by an arm would double-register (same rationale as
# arm-resume.sh list_existing).
list_existing() {
    local err_file out rc
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    # set +e: schtasks rc=1 on an empty scheduler must not trip set -e
    # before we can classify it (arm-resume never hits this because a
    # real Windows scheduler is never empty; the fake in tests can be).
    set +e
    out=$(run_schtasks /query /fo CSV /nh 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        # Fail-CLOSED: any nonzero rc is fatal UNLESS it matches the one
        # trusted empty-scheduler signature — rc=1 with EMPTY stderr
        # (schtasks returns rc=1 on a completely empty scheduler; real
        # errors like access-denied always carry stderr). Keyword-
        # grepping stderr the other way round was fail-OPEN: any
        # non-English / unrecognised error read as "empty scheduler" and
        # arm's /create /f would silently overwrite an armed cadence.
        if [ "$rc" -ne 1 ] || [ -s "$err_file" ]; then
            echo "ERR pipeline-cadence: schtasks /query failed (rc=$rc) — refusing to treat as empty scheduler:" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
    # shellcheck disable=SC1003  # `"\\'` strips both quote and the literal backslash schtasks prefixes task names with
    printf '%s\n' "$out" \
        | grep -o '"\\\?HIMMEL-Pipeline-[^"]*"' 2>/dev/null \
        | tr -d '"\\' \
        | sort -u || true
}

delete_task() {
    local name="$1" err_file
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    if run_schtasks /delete /tn "$name" /f >/dev/null 2>"$err_file"; then
        rm -f "$err_file"
        echo "pipeline-cadence: deleted scheduled task: $name"
    else
        echo "ERR pipeline-cadence: schtasks /delete $name failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
}

# Known not-found stderr signatures for `/query /tn <name>` on a real
# scheduler — anchored on the two exact schtasks messages so unrelated
# errors that merely contain "does not exist" (e.g. "The specified
# service does not exist as an installed service" when the Task
# Scheduler service is down) never classify as not-found. Real schtasks
# always emits one of these on a missing task, so rc=1 WITHOUT a match
# (silent rc=1 included) is a real query failure (access denied,
# service down) and fail-closes.
NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

# query_one <name>: rc 0 = armed (stdout = /fo LIST output via the
# QUERY_OUT global), rc 1 = trusted not-found, rc 2 = query failed
# (stderr already printed).
QUERY_OUT=""
query_one() {
    local name="$1" rc err_file
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    set +e
    QUERY_OUT=$(run_schtasks /query /tn "$name" /fo LIST 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        rm -f "$err_file"
        return 0
    fi
    # Trusted not-found is rc=1 AND a NOT_FOUND_RE stderr match — real
    # schtasks always emits the message on a missing task, so a silent
    # rc=1 (or a crashed query tool, rc=255) must NOT read as "not
    # armed": disarm would no-op and delete the runners while the
    # tasks stay armed.
    if [ "$rc" -eq 1 ] && grep -qiE "$NOT_FOUND_RE" "$err_file"; then
        rm -f "$err_file"
        return 1
    fi
    echo "ERR pipeline-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
    cat "$err_file" >&2
    # Escape hatch: NOT_FOUND_RE only matches the English schtasks
    # signatures, so a localized (non-English) not-found message of a
    # genuinely unarmed task lands here and fail-closes loud. Give the
    # operator the manual verify/remove commands instead of a dead end.
    echo "    If this is a localized 'task does not exist' message, the task may simply" >&2
    echo "    not be armed. Verify / remove manually:" >&2
    echo "        schtasks /query /tn $name" >&2
    echo "        schtasks /delete /tn $name /f" >&2
    rm -f "$err_file"
    return 2
}

# rc 0 = query trusted (armed or not-armed), rc 2 = query errored.
task_summary() {
    case "$1" in
        "$TASK_HARVEST") printf ' -> %s' "$DAILY_CHAIN" ;;
    esac
}

# Map a cadence task name to its generated runner file path (.bat on
# Windows, .sh on POSIX) so status can surface the pinned model (HIMMEL-506).
# Returns the path on stdout; rc 1 on an unknown name.
runner_for_name() {
    local base ext
    case "$1" in
        "$TASK_HARVEST") base="pipeline-harvest" ;;
        "$TASK_SYNTH")   base="pipeline-synthesize" ;;
        "$TASK_HEALTH")  base="pipeline-health" ;;
        *) return 1 ;;
    esac
    case "$PLATFORM" in
        windows) ext="bat" ;;
        *)       ext="sh" ;;
    esac
    printf '%s/%s.%s' "$BAT_DIR" "$base" "$ext"
}

# Read the --model pin back out of a generated runner (.bat or .sh) so
# status can flag an armed-but-wrong-model cadence (HIMMEL-506). Both
# emitters inject `--model <m>` right after the binary; this greps that
# token. rc 1 when the runner is absent (not armed / dry-run), empty
# stdout when armed without a stampable pin (pre-HIMMEL-506 runner).
runner_model() {
    local f="$1"
    [ -f "$f" ] || return 1
    grep -oE -- '--model[[:space:]]+[^[:space:]]+' "$f" 2>/dev/null \
        | head -1 | sed 's/^--model[[:space:]]*//' | tr -d '"' || true
}

# Status suffix: " [model: <m>]" when the runner carries a --model pin;
# " [runner missing]" when the scheduler entry is armed but its generated
# runner file is gone (every fire fails — distinguished from the
# intentional pre-HIMMEL-506 no-pin case, which exists on disk and stays
# silent rather than print "model: unknown"); empty otherwise. Without this
# guard a deleted runner read identically to a healthy v1 runner, so status
# reported ARMED while every fire failed (HIMMEL-506 CR fix).
model_suffix() {
    local runner model
    runner=$(runner_for_name "$1" 2>/dev/null) || return 0
    [ -f "$runner" ] || { printf ' [runner missing]'; return 0; }
    model=$(runner_model "$runner") || return 0
    [ -n "$model" ] && printf ' [model: %s]' "$model"
    return 0
}

status_one() {
    local name="$1" next qrc=0
    query_one "$name" || qrc=$?
    case "$qrc" in
        0)
            # "Next Run Time" header is locale-dependent (English assumed —
            # operator env); fall back to plain ARMED when absent.
            next=$(printf '%s\n' "$QUERY_OUT" | grep -i 'Next Run Time' | head -1 \
                | sed 's/^[^:]*:[[:space:]]*//' || true)
            echo "ARMED      $name${next:+ (next run: $next)}$(task_summary "$name")$(model_suffix "$name")"
            ;;
        1)  echo "not armed  $name$(task_summary "$name")" ;;
        *)
            echo "QUERY ERR  $name (see stderr above)"
            return 2
            ;;
    esac
}

# Surface fire-time evidence: each runner writes its claude output to a
# .log next to the .bat (rotated per fire — the log holds exactly the
# current run; the previous run survives as .log.prev), so "armed but
# never succeeding" is visible here.
status_log() {
    local log="$1" mtime last
    if [ -f "$log" ]; then
        # GNU `date -r <file>` (Linux/gitbash); on BSD/macOS -r means
        # epoch-seconds, so fall back to stat -f there.
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        echo "  run log    $log (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    # Rotation keeps exactly one prior run as .log.prev (emit_bat's
    # `move /y`) — surface it too, so the previous run's outcome stays
    # visible right after a fresh fire truncated the current .log.
    # Absence is normal (fewer than two fires) and stays silent.
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
        last=$(tail -n 1 "$log.prev" 2>/dev/null | tr -d '\r' || true)
        echo "  prev log   $log.prev (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    fi
}

cmd_status() {
    # Exit-code contract: 0 only when every query was trusted; 2 when
    # any query errored (the QUERY ERR line alone exiting 0 would let
    # scripted callers read a broken query tool as "all fine").
    local status_rc=0
    echo "pipeline-cadence status:"
    status_one "$TASK_HARVEST" || status_rc=2
    status_log "$BAT_DIR/pipeline-harvest.log"
    status_one "$TASK_SYNTH" || status_rc=2
    status_log "$BAT_DIR/pipeline-synthesize.log"
    status_one "$TASK_HEALTH" || status_rc=2
    status_log "$BAT_DIR/pipeline-health.log"
    return "$status_rc"
}

cmd_disarm() {
    local name found=0 qrc
    for name in "$TASK_HARVEST" "$TASK_SYNTH" "$TASK_HEALTH"; do
        qrc=0
        query_one "$name" || qrc=$?
        case "$qrc" in
            0)
                found=1
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "DRY pipeline-cadence: would delete $name"
                else
                    delete_task "$name"
                fi
                ;;
            1)  : ;;  # trusted not-found — genuinely nothing to delete
            *)
                # Real query failure: do NOT report no-op, do NOT delete
                # the .bats (the task may still be armed and pointing at
                # them). query_one already printed the stderr.
                exit 2
                ;;
        esac
    done
    # Reached only when every query was trusted (armed or not-found) and
    # every delete succeeded (delete_task exits 4 otherwise) — safe to
    # remove the runners now.
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -f "$BAT_DIR/pipeline-harvest.bat" "$BAT_DIR/pipeline-synthesize.bat" "$BAT_DIR/pipeline-health.bat" "$SETTINGS_FRAGMENT"
    fi
    if [ "$found" -eq 0 ]; then
        echo "pipeline-cadence: nothing armed — disarm is a no-op"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: no changes made"
    else
        echo "pipeline-cadence: cadence disarmed"
    fi
}

# Emit .bat body for one cadence task: rotate the run log (one prior
# run kept as .log.prev), stamp the fire time, cd into the vault, then
# a bounded interactive claude run. `< NUL` is the cmd.exe spelling of
# the `claude "<prompt>" < /dev/null` bounded-run primitive — the
# session runs the full turn on stdin-EOF and exits clean (no
# -p/--print: HIMMEL-128). `cd /d ... || exit /b 1` aborts instead of
# silently running claude from the wrong CWD — and its output (incl.
# the cd error if the vault moved/was deleted after arming) goes to the
# .log next to the .bat, so the log exists on EVERY fire and a failing
# cd is visible instead of silently absent. The task fires in a
# transient console (03:00 Sunday) whose output would otherwise vanish;
# `status` surfaces the log.
emit_bat() {
    local vault_win_esc="$1" claude_win="$2" prompt_esc="$3" log_win_esc="$4" settings_esc="$5" model="$6"
    # cmd_escape the per-leg model (HIMMEL-506 CR fix): every other value
    # interpolated below is already escaped, but the model was a raw "%s" -
    # a value carrying " % & ^ < > | would corrupt the .bat at fire time.
    # validate_arm_inputs rejects metacharacters at the gate; escape here
    # too (defense in depth - the gate also guards emit_runner's printf '%q').
    local model_esc
    model_esc=$(cmd_escape "$model")
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_win_esc" "$log_win_esc" "$log_win_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_win_esc"
    printf 'cd /d "%s" >> "%s" 2>&1 || exit /b 1\r\n' "$vault_win_esc" "$log_win_esc"
    # HIMMEL-951: no bg-wait ceiling override here — CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
    # only affects --print mode, and cadence runners are interactive-shaped (HIMMEL-128).
    printf '"%s" --model "%s" --settings "%s" "%s" < NUL >> "%s" 2>&1\r\n' "$claude_win" "$model_esc" "$settings_esc" "$prompt_esc" "$log_win_esc"
}

# Emit the JSON settings fragment that wires the auto-approve-safe-bash hook by
# absolute path (HIMMEL-575). hook_path must be a forward-slash, JSON-safe
# absolute path (no backslashes — use cygpath -m on Windows). The command is
# unquoted to match himmel's own .claude/settings.json hook wiring convention.
emit_settings_fragment() {
    local hook_path="$1"
    cat <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash ${hook_path}" }
        ]
      }
    ]
  }
}
JSON
}

# --- schtasks task XML (HIMMEL-362) ---------------------------------------
#
# schtasks /create has no flag for StartWhenAvailable ("run the task as
# soon as possible after a missed scheduled start"), so a daily 02:00 run
# is SILENTLY SKIPPED if the machine was off/asleep at 02:00. The only way
# to set it from the CLI is to build the task from an XML definition and
# create via `schtasks /create /xml`. We keep the existing per-task .bat
# runner as the task's Exec Command and wrap it in XML that carries
# StartWhenAvailable=true. Catch-up only (operator decision 2026-06-17):
# we do NOT add a wake timer, and DisallowStartIfOnBatteries keeps its
# schema default (true) so a battery laptop catches up when next on AC
# rather than draining on battery.

# Escape the three XML-significant characters for text interpolated into an
# element body (the Exec <Command> path — a BAT_DIR path may legally
# contain `&`). `&` first so the `&` in the &lt;/&gt; entities isn't
# re-escaped. Implemented with sed, NOT bash `${s//&/&amp;}`: bash 5.1+
# treats a literal `&` in a substitution REPLACEMENT as the matched text
# (so `${s//</&lt;}` yields `<lt;`, dropping the ampersand) — a version-
# dependent trap. In sed, `\&` is an unambiguous literal ampersand on every
# bash version (incl. the macOS 3.2 baseline).
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# SUN..SAT -> the Task Scheduler XML day-element name.
dow_long() {
    case "$1" in
        SUN) echo Sunday ;;    MON) echo Monday ;;  TUE) echo Tuesday ;;
        WED) echo Wednesday ;; THU) echo Thursday ;; FRI) echo Friday ;;
        SAT) echo Saturday ;;
    esac
}

# Per-cadence <CalendarTrigger> schedule fragments. HEALTH_DAY is already
# validated (MON..SUN) by validate_arm_inputs. Harvest and synthesize are
# both daily (HIMMEL-506); health is weekly on HEALTH_DAY.
schedule_daily_xml() {
    printf '      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>\n      </ScheduleByDay>'
}
schedule_weekly_xml() {
    local day="$1"
    printf '      <ScheduleByWeek>\n        <DaysOfWeek>\n          <%s />\n        </DaysOfWeek>\n        <WeeksInterval>1</WeeksInterval>\n      </ScheduleByWeek>' "$(dow_long "$day")"
}

# Emit one task XML: a CalendarTrigger at the given local time with the
# supplied schedule fragment, StartWhenAvailable=true, and the .bat runner
# as the Exec Command. StartBoundary's date is a fixed past sentinel — the
# schedule fragment (not the date) governs which days fire; the date only
# marks when the schedule became active.
#
# Encoding: the prolog declares UTF-16 (what `schtasks /create /xml`
# expects) but the bytes we write are plain ASCII — every value in this
# document is ASCII (fixed tags, an ASCII HH:MM, and the .bat path under
# ~/.claude/pipeline-cadence). schtasks accepts that combination; declaring
# `encoding="UTF-8"` instead is REJECTED on Win11 with
# "(1,40):: unable to switch the encoding" (verified). Keep this ASCII-only
# — a non-ASCII byte here would need a real UTF-16LE+BOM file.
emit_task_xml() {
    local command_raw="$1" start_time="$2" schedule_xml="$3" command
    command=$(xml_escape "$command_raw")
    cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>himmel pipeline-cadence (HIMMEL-255/357/362)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2020-01-01T${start_time}:00</StartBoundary>
      <Enabled>true</Enabled>
${schedule_xml}
    </CalendarTrigger>
  </Triggers>
  <Settings>
    <StartWhenAvailable>true</StartWhenAvailable>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>${command}</Command>
    </Exec>
  </Actions>
</Task>
XML
}

# Create one task from an XML definition (so StartWhenAvailable applies).
# Writes the XML to a temp file, converts the path for schtasks, creates,
# then removes the temp. stderr -> $5 (shared err_file); returns the
# schtasks rc so callers keep the existing failure/rollback flow.
schtasks_create_xml() {
    local name="$1" bat_win="$2" schedule_xml="$3" start_time="$4" err_file="$5"
    local xml_file xml_win rc
    # Self-contained error handling (does not rely on the caller's `if !`
    # to suspend set -e): a failed mktemp/cygpath returns 1 with the temp
    # cleaned up; the create's rc is captured under `set +e` so it is
    # returned (not aborted on) even if called bare. Mirrors list_existing.
    if ! xml_file=$(mktemp -t pipeline-cadence.xml.XXXXXX 2>"$err_file"); then
        return 1
    fi
    emit_task_xml "$bat_win" "$start_time" "$schedule_xml" > "$xml_file"
    if ! xml_win=$(cygpath -w "$xml_file" 2>"$err_file"); then
        rm -f "$xml_file"
        return 1
    fi
    set +e
    run_schtasks /create /tn "$name" /xml "$xml_win" /f 2>"$err_file"
    rc=$?
    set -e
    rm -f "$xml_file"
    return "$rc"
}

# Validate a per-leg --*-model value (HIMMEL-506 CR fix). Defense in
# depth: a conservative identifier grammar rejects empty/whitespace and
# every shell/CMD metacharacter BEFORE the value is interpolated into a
# runner, so a model like a"&b can't corrupt the .bat (which additionally
# cmd_escapes it via emit_bat) or break the cron re-parse (emit_runner
# pre-quotes with printf '%q'). Known aliases (sonnet|opus|haiku|fable)
# and dotted full ids (containing '.' or a 'claude-' prefix) arm silently;
# any other grammar-valid value earns a non-fatal WARNING so a future
# model name never hard-breaks arming. POSIX-safe `case` (not [[ =~ ]]):
# it matches the WHOLE string, so a trailing newline can't slip a second
# line past an anchored regex the way `grep -E '^...$'` would.
validate_model_name() {
    local flag="$1" val="$2"
    # Grammar: first char [A-Za-z0-9], rest [A-Za-z0-9._:-]*. Glob, not
    # regex: `*[!class]` flags ANY disallowed char anywhere; `[._:-]*`
    # catches a leading . _ : - (and "" catches empty). The '-' is last
    # in each class so it is a literal, not a range endpoint.
    case "$val" in
        ""|*[!A-Za-z0-9._:-]*|[._:-]*)
            echo "ERR pipeline-cadence: $flag must match [A-Za-z0-9][A-Za-z0-9._:-]* (empty, whitespace, and shell/CMD metacharacters are rejected), got: $val" >&2
            return 1
            ;;
    esac
    case "$val" in
        sonnet|opus|haiku|fable) return 0 ;;
        *.*|claude-*) return 0 ;;
        *)
            echo "WARN pipeline-cadence: $flag '$val' is not a known alias (sonnet|opus|haiku|fable) or dotted full id; arming anyway - verify the model name" >&2
            return 0
            ;;
    esac
}

# Input validation shared by the schtasks and cron arm paths. Upcases
# HEALTH_DAY in place.
validate_arm_inputs() {
    local day_ok=0 d
    if ! [[ "$HARVEST_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --harvest-time must be HH:MM (24h), got: $HARVEST_TIME" >&2
        exit 1
    fi
    if ! [[ "$SYNTH_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --synth-time must be HH:MM (24h), got: $SYNTH_TIME" >&2
        exit 1
    fi
    if ! [[ "$IG_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "ERR pipeline-cadence: --ig-limit must be a non-negative integer, got: $IG_LIMIT" >&2
        exit 1
    fi
    # Health is weekly now (HIMMEL-506): --health-day is a weekday
    # MON..SUN, not a day-of-month. A numeric 1-28 is the old monthly
    # semantics — reject it with a pointer to the new weekday meaning.
    HEALTH_DAY=$(printf '%s' "$HEALTH_DAY" | tr '[:lower:]' '[:upper:]')
    day_ok=0
    for d in MON TUE WED THU FRI SAT SUN; do
        [ "$HEALTH_DAY" = "$d" ] && day_ok=1
    done
    if [ "$day_ok" -ne 1 ]; then
        echo "ERR pipeline-cadence: --health-day must be a weekday MON..SUN (health is weekly now — HIMMEL-506), got: $HEALTH_DAY" >&2
        exit 1
    fi
    if ! [[ "$HEALTH_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --health-time must be HH:MM (24h), got: $HEALTH_TIME" >&2
        exit 1
    fi
    # Per-leg model pins (HIMMEL-506): each --*-model must match a
    # conservative identifier grammar ([A-Za-z0-9][A-Za-z0-9._:-]*) -
    # this rejects empty/whitespace AND every shell/CMD metacharacter
    # before the value reaches a runner. The .bat emitter additionally
    # cmd_escapes the value (emit_bat) and the cron emitter pre-quotes it
    # with printf '%q' (emit_runner) - defense in depth, never the sole
    # guard. claude's own runtime error on a bad name is a last line, not
    # the first.
    validate_model_name "--harvest-model" "$HARVEST_MODEL" || exit 1
    validate_model_name "--synth-model"  "$SYNTH_MODEL"  || exit 1
    validate_model_name "--health-model" "$HEALTH_MODEL" || exit 1
    if [ ! -d "$VAULT" ]; then
        echo "ERR pipeline-cadence: --vault is not a directory: $VAULT" >&2
        exit 1
    fi
}

cmd_arm() {
    validate_arm_inputs

    # Resolve claude to an absolute Windows path so the .bat doesn't
    # depend on PATH in whatever cmd shell schtasks spawns.
    local claude_posix claude_win
    if ! claude_posix=$(command -v claude 2>/dev/null); then
        echo "ERR pipeline-cadence: 'claude' not on PATH at arm time" >&2
        exit 2
    fi
    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR pipeline-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }
    if ! claude_win=$(cygpath -w "$claude_posix" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for claude path: $claude_win" >&2
        exit 4
    fi
    local vault_win
    if ! vault_win=$(cygpath -w "$VAULT" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for vault path: $vault_win" >&2
        exit 4
    fi

    # Pre-trust the vault dir (HIMMEL-386) so the fired cadence runs don't stall
    # on Claude Code's interactive workspace-trust prompt ("Is this a project
    # you trust?"). An autonomous run has no human to answer it and its stdin is
    # NUL (cmd.exe's /dev/null — see the runner below), so an untrusted cwd
    # silently wastes the run. Non-fatal: a pre-seed failure must never block
    # the arm.
    local _pc_lib
    _pc_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/ensure-workspace-trust.sh"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: would pre-trust workspace '$VAULT' in ~/.claude.json"
    else
        "$_pc_lib" "$VAULT" \
            || echo "WARN pipeline-cadence: workspace-trust pre-seed failed for '$VAULT' (arm continues; first run may prompt to trust the folder)" >&2
    fi

    # Dedup guard — never double-register the cadence.
    local existing
    existing=$(list_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "pipeline-cadence: --force set; replacing existing task(s):" >&2
            local marker
            while IFS= read -r marker; do
                [ -z "$marker" ] && continue
                echo "  $marker" >&2
                if [ "$DRY_RUN" -eq 0 ]; then
                    delete_task "$marker"
                else
                    echo "DRY pipeline-cadence: would delete $marker"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR pipeline-cadence: HIMMEL-Pipeline-* task(s) already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/pipeline-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local vault_esc harvest_esc synth_esc health_esc
    vault_esc=$(cmd_escape "$vault_win")
    harvest_esc=$(cmd_escape "$HARVEST_PROMPT")
    synth_esc=$(cmd_escape "$SYNTH_PROMPT")
    health_esc=$(cmd_escape "$HEALTH_PROMPT")
    local bat_harvest="$BAT_DIR/pipeline-harvest.bat"
    local bat_synth="$BAT_DIR/pipeline-synthesize.bat"
    local bat_health="$BAT_DIR/pipeline-health.bat"

    # Fire-time run logs live next to the .bats (cmd-escaped for the
    # `>>` redirect target inside the .bat).
    local bat_dir_win log_harvest_esc log_synth_esc log_health_esc
    if ! bat_dir_win=$(cygpath -w "$BAT_DIR" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for bat dir: $bat_dir_win" >&2
        exit 4
    fi
    log_harvest_esc=$(cmd_escape "$bat_dir_win\\pipeline-harvest.log")
    log_synth_esc=$(cmd_escape "$bat_dir_win\\pipeline-synthesize.log")
    log_health_esc=$(cmd_escape "$bat_dir_win\\pipeline-health.log")

    # Settings fragment (HIMMEL-575): the `claude --settings` target inside each
    # .bat (a Windows path, cmd-escaped) plus the auto-approve hook's mixed
    # (C:/...) path embedded in the fragment JSON (forward-slash so it's both
    # JSON-safe and bash-readable when claude runs the hook command).
    local settings_esc hook_path_m
    settings_esc=$(cmd_escape "$bat_dir_win\\cadence-settings.json")
    if ! hook_path_m=$(cygpath -m "$AUTO_APPROVE_HOOK" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -m failed for hook path: $hook_path_m" >&2
        exit 4
    fi
    [ -r "$AUTO_APPROVE_HOOK" ] || \
        echo "WARN pipeline-cadence: auto-approve hook not readable at $AUTO_APPROVE_HOOK (cadence runs may stall on compound-bash prompts)" >&2

    # Per-cadence schedule fragments for the task XML (HIMMEL-362). Built
    # once and reused by the dry-run preview and the real create below.
    local sched_harvest sched_synth sched_health
    sched_harvest=$(schedule_daily_xml)
    sched_synth=$(schedule_daily_xml)
    sched_health=$(schedule_weekly_xml "$HEALTH_DAY")

    # The .bat runner is the task's Exec Command. cygpath -w is a pure
    # string transform (the .bat need not exist yet), so resolve the win
    # paths before the dry-run preview too — the XML preview must show the
    # real Exec Command.
    local bat_harvest_win bat_synth_win bat_health_win
    if ! bat_harvest_win=$(cygpath -w "$bat_harvest" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed: $bat_harvest_win" >&2
        exit 4
    fi
    if ! bat_synth_win=$(cygpath -w "$bat_synth" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed: $bat_synth_win" >&2
        exit 4
    fi
    if ! bat_health_win=$(cygpath -w "$bat_health" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed: $bat_health_win" >&2
        exit 4
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: would write $SETTINGS_FRAGMENT:"
        emit_settings_fragment "$hook_path_m" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $bat_harvest:"
        emit_bat "$vault_esc" "$claude_win" "$harvest_esc" "$log_harvest_esc" "$settings_esc" "$HARVEST_MODEL" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $bat_synth:"
        emit_bat "$vault_esc" "$claude_win" "$synth_esc" "$log_synth_esc" "$settings_esc" "$SYNTH_MODEL" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $bat_health:"
        emit_bat "$vault_esc" "$claude_win" "$health_esc" "$log_health_esc" "$settings_esc" "$HEALTH_MODEL" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would schtasks /create /tn $TASK_HARVEST /xml <daily $HARVEST_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_harvest_win" "$HARVEST_TIME" "$sched_harvest" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would schtasks /create /tn $TASK_SYNTH /xml <daily $SYNTH_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_synth_win" "$SYNTH_TIME" "$sched_synth" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would schtasks /create /tn $TASK_HEALTH /xml <weekly $HEALTH_DAY $HEALTH_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_health_win" "$HEALTH_TIME" "$sched_health" | sed 's/^/    /'
        echo "pipeline-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    emit_settings_fragment "$hook_path_m" > "$SETTINGS_FRAGMENT"
    emit_bat "$vault_esc" "$claude_win" "$harvest_esc" "$log_harvest_esc" "$settings_esc" "$HARVEST_MODEL" > "$bat_harvest"
    emit_bat "$vault_esc" "$claude_win" "$synth_esc"  "$log_synth_esc"  "$settings_esc" "$SYNTH_MODEL"   > "$bat_synth"
    emit_bat "$vault_esc" "$claude_win" "$health_esc" "$log_health_esc" "$settings_esc" "$HEALTH_MODEL"  > "$bat_health"

    local err_file
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    if ! schtasks_create_xml "$TASK_HARVEST" "$bat_harvest_win" "$sched_harvest" "$HARVEST_TIME" "$err_file"; then
        echo "ERR pipeline-cadence: schtasks /create $TASK_HARVEST failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
    # Surface success-path /create warnings instead of deleting them unread.
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    if ! schtasks_create_xml "$TASK_SYNTH" "$bat_synth_win" "$sched_synth" "$SYNTH_TIME" "$err_file"; then
        echo "ERR pipeline-cadence: schtasks /create $TASK_SYNTH failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        # Don't leave a half-armed cadence behind: roll back the daily
        # task that DID register so status/dedup stay truthful.
        if ! run_schtasks /delete /tn "$TASK_HARVEST" /f >/dev/null 2>&1; then
            echo "WARN: rollback of $TASK_HARVEST failed — run disarm" >&2
        fi
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    if ! schtasks_create_xml "$TASK_HEALTH" "$bat_health_win" "$sched_health" "$HEALTH_TIME" "$err_file"; then
        echo "ERR pipeline-cadence: schtasks /create $TASK_HEALTH failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        # Roll back the daily + weekly tasks that DID register so
        # status/dedup stay truthful.
        if ! run_schtasks /delete /tn "$TASK_HARVEST" /f >/dev/null 2>&1; then
            echo "WARN: rollback of $TASK_HARVEST failed — run disarm" >&2
        fi
        if ! run_schtasks /delete /tn "$TASK_SYNTH" /f >/dev/null 2>&1; then
            echo "WARN: rollback of $TASK_SYNTH failed — run disarm" >&2
        fi
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    rm -f "$err_file"

    cat <<EOF

================================================================
  PIPELINE CADENCE ARMED (HIMMEL-255 / HIMMEL-357 / HIMMEL-506 / HIMMEL-798)
  $TASK_HARVEST  daily   $HARVEST_TIME  [model: $HARVEST_MODEL]  -> $DAILY_CHAIN
  $TASK_SYNTH    daily   $SYNTH_TIME    [model: $SYNTH_MODEL]    -> /synthesize-clips + /archive-clips
  $TASK_HEALTH   weekly  $HEALTH_DAY $HEALTH_TIME [model: $HEALTH_MODEL] -> /obsidian-health
  Vault: $vault_win
  Runner .bats: $BAT_DIR

  Sessions launch as bounded interactive claude runs (stdin from NUL)
  in the vault directory. StartWhenAvailable=true (HIMMEL-362): a run
  missed because the PC was off/asleep fires when the PC is next on.
  Disarm anytime with:
      bash scripts/luna/pipeline-cadence.sh disarm
================================================================
EOF
}

# --- POSIX (cron) implementation — HIMMEL-265 ------------------------------
#
# Same arm/status/disarm contract as the schtasks path above, against
# the user crontab. Both cadence entries live in ONE crontab rewrite
# (snapshot -> filter -> append -> install), so there is no half-armed
# state to roll back. Runner .sh files mirror the .bat runners: log
# rotation, fire stamp, cd-into-vault, bounded interactive claude run.

CRON_RUNNER_HARVEST="$BAT_DIR/pipeline-harvest.sh"
CRON_RUNNER_SYNTH="$BAT_DIR/pipeline-synthesize.sh"
CRON_RUNNER_HEALTH="$BAT_DIR/pipeline-health.sh"

# SUN..SAT -> cron day-of-week (0 = Sunday; 0-6 is portable across
# Vixie/BSD crons, unlike 7 for Sunday).
dow_num() {
    case "$1" in
        SUN) echo 0 ;; MON) echo 1 ;; TUE) echo 2 ;; WED) echo 3 ;;
        THU) echo 4 ;; FRI) echo 5 ;; SAT) echo 6 ;;
    esac
}

# Shell-quote a value for a cron command line: printf %q survives the
# /bin/sh re-parse at fire time for ordinary path-shaped values (no
# control characters). The extra % -> \% pass is cron(5) syntax — an
# unescaped % ends the command and becomes stdin.
# Control characters are rejected (rc=2): bash's printf %q emits
# ANSI-C $'...' quoting for them, which dash/sh can't parse at cron
# fire time. Paths and prompts never legitimately contain them.
cron_escape() {
    if printf '%s' "$1" | grep -qP '[[:cntrl:]]' 2>/dev/null \
       || printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x1f\x7f]'; then
        echo "ERR pipeline-cadence: cron_escape: argument contains control characters — rejected" >&2
        return 2
    fi
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the current crontab into the CRON_TAB global. Fail-CLOSED like
# list_existing: any nonzero rc is fatal UNLESS it matches the trusted
# no-crontab-yet signature — rc=1 with EMPTY stderr or the standard
# "no crontab for <user>" message. A failed listing must never read as
# "nothing armed" (arm would double-register; disarm would no-op and
# delete the runners while the entries stay armed).
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    set +e
    # LC_ALL=C pins the message shape where locales apply, so the
    # 'no crontab' signature grep below isn't defeated by translation.
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR pipeline-cadence: crontab -l failed (rc=$rc) — refusing to treat as empty crontab:" >&2
            cat "$err_file" >&2
            echo "    Non-vixie crons (busybox, Solaris) phrase 'no crontab yet' differently;" >&2
            echo "    if that is what tripped this, install an empty crontab to unblock:" >&2
            echo "        crontab - </dev/null" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
}

# Install a new crontab from the given file (via stdin, the arm-resume
# precedent). Returns 4 on failure (callers exit 4 — cron_arm sweeps its
# staged temp runners first); the rejected tab is kept for forensics.
cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR pipeline-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        echo "    rejected crontab left at: $tab_file" >&2
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

# Marker-tagged cadence lines in the current CRON_TAB (empty if none).
cron_existing() {
    printf '%s\n' "$CRON_TAB" | grep -F "$TASK_PREFIX" || true
}

# Emit the runner .sh body for one cadence task: rotate the run log
# (one prior run kept as .log.prev), stamp the fire time, cd into the
# vault (a failing cd lands in the log instead of silently running
# claude from the wrong CWD), then the bounded interactive claude run
# — `< /dev/null` stdin-EOF, NO -p/--print (HIMMEL-128). All values
# arrive pre-quoted with printf %q.
# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh to expand at fire time
emit_runner() {
    local name="$1" q_vault="$2" q_claude="$3" q_prompt="$4" q_log="$5" q_settings="$6" q_node_dir="${7:-}" q_model="${8:-}"
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by pipeline-cadence.sh arm (HIMMEL-265)\n' "$name"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Prepend the arm-time node directory so nvm-managed node is found
    # under cron's minimal PATH even when the claude shim is a
    # #!/usr/bin/env node wrapper (#317).
    if [ -n "$q_node_dir" ]; then
        printf 'export PATH=%s:$PATH\n' "$q_node_dir"
    fi
    printf 'log=%s\n' "$q_log"
    printf '# Test log existence BEFORE the capture redirect opens $log.\n'
    printf '# The old brace-group form (`{ [ -f ] && mv; } >> "$log"`) created\n'
    printf '# $log before the test ran, so an absent .log clobbered .log.prev\n'
    printf '# with an empty file (PR430 CR regression).\n'
    printf 'if [ -f "$log" ]; then\n'
    printf '    mv -f "$log" "$log.prev" || echo "[rotation failed: mv $log -> $log.prev]" >> "$log" 2>&1\n'
    printf 'fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    printf '    cd %s || exit 1\n' "$q_vault"
    # HIMMEL-951: no bg-wait ceiling override here — CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
    # only affects --print mode, and cadence runners are interactive-shaped (HIMMEL-128).
    printf '    _rc=0; %s --model %s --settings %s %s < /dev/null || _rc=$?\n' "$q_claude" "$q_model" "$q_settings" "$q_prompt"
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
}

cron_status() {
    cron_read
    echo "pipeline-cadence status:"
    local name log entry sched
    for name in "$TASK_HARVEST" "$TASK_SYNTH" "$TASK_HEALTH"; do
        case "$name" in
            "$TASK_HARVEST") log="$BAT_DIR/pipeline-harvest.log" ;;
            "$TASK_SYNTH")  log="$BAT_DIR/pipeline-synthesize.log" ;;
            *)              log="$BAT_DIR/pipeline-health.log" ;;
        esac
        entry=$(printf '%s\n' "$CRON_TAB" | grep -F "# $name" | head -1 || true)
        if [ -n "$entry" ]; then
            sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
            echo "ARMED      $name (cron: $sched)$(task_summary "$name")$(model_suffix "$name")"
        else
            echo "not armed  $name$(task_summary "$name")"
        fi
        status_log "$log"
    done
}

cron_disarm() {
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -z "$existing" ]; then
        # Trusted-empty read (cron_read exits 2 otherwise) — safe to
        # sweep the runners like the schtasks path does.
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$CRON_RUNNER_HARVEST" "$CRON_RUNNER_SYNTH" "$CRON_RUNNER_HEALTH" "$SETTINGS_FRAGMENT"
        fi
        echo "pipeline-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "DRY pipeline-cadence: would remove crontab entry: $line"
        done <<< "$existing"
        echo "DRY pipeline-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t pipeline-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" > "$newtab" || true
    # Ordering invariant: install must succeed BEFORE the runners are
    # removed — a failed install (exit 4) leaves the entries live and
    # they must keep pointing at existing runner files.
    cron_install "$newtab" || exit 4
    rm -f "$CRON_RUNNER_HARVEST" "$CRON_RUNNER_SYNTH" "$CRON_RUNNER_HEALTH" "$SETTINGS_FRAGMENT"
    echo "pipeline-cadence: cadence disarmed"
}

cron_arm() {
    validate_arm_inputs

    # Resolve claude to an absolute path so the cron entry doesn't
    # depend on cron's minimal PATH. Also capture node's directory so
    # the runner can prepend it to PATH — nvm-managed node won't be in
    # cron's minimal PATH even when claude_bin is an absolute shim (#317).
    local claude_bin node_dir
    if ! claude_bin=$(command -v claude 2>/dev/null); then
        echo "ERR pipeline-cadence: 'claude' not on PATH at arm time" >&2
        exit 2
    fi
    node_dir=""
    if node_bin=$(command -v node 2>/dev/null); then
        node_dir=$(dirname "$node_bin")
    fi

    # Pre-trust the vault dir (HIMMEL-386) — same rationale as cmd_arm: a
    # cron-fired claude run (stdin /dev/null) has no human to answer Claude
    # Code's interactive workspace-trust prompt, so an untrusted cwd wastes
    # the run. Non-fatal: a pre-seed failure must never block the arm.
    local _pc_lib
    _pc_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/ensure-workspace-trust.sh"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: would pre-trust workspace '$VAULT' in ~/.claude.json"
    else
        "$_pc_lib" "$VAULT" \
            || echo "WARN pipeline-cadence: workspace-trust pre-seed failed for '$VAULT' (arm continues; first run may prompt to trust the folder)" >&2
    fi

    # Dedup guard — never double-register the cadence. The actual
    # removal under --force happens in the single rewrite below.
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "pipeline-cadence: --force set; replacing existing cadence entries:" >&2
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$DRY_RUN" -eq 0 ]; then
                    echo "  $line" >&2
                else
                    echo "DRY pipeline-cadence: would remove crontab entry: $line"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR pipeline-cadence: HIMMEL-Pipeline-* crontab entries already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/pipeline-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_vault q_claude q_node_dir q_harvest_prompt q_synth_prompt q_health_prompt q_log_harvest q_log_synth q_log_health q_harvest_model q_synth_model q_health_model
    q_vault=$(printf '%q' "$VAULT")
    q_claude=$(printf '%q' "$claude_bin")
    q_node_dir=$([ -n "$node_dir" ] && printf '%q' "$node_dir" || printf '')
    q_harvest_prompt=$(printf '%q' "$HARVEST_PROMPT")
    q_synth_prompt=$(printf '%q' "$SYNTH_PROMPT")
    q_health_prompt=$(printf '%q' "$HEALTH_PROMPT")
    q_log_harvest=$(printf '%q' "$BAT_DIR/pipeline-harvest.log")
    q_log_synth=$(printf '%q' "$BAT_DIR/pipeline-synthesize.log")
    q_log_health=$(printf '%q' "$BAT_DIR/pipeline-health.log")
    q_harvest_model=$(printf '%q' "$HARVEST_MODEL")
    q_synth_model=$(printf '%q' "$SYNTH_MODEL")
    q_health_model=$(printf '%q' "$HEALTH_MODEL")
    # Settings fragment (HIMMEL-575): the `claude --settings` target, shared by
    # all three runners. The hook path inside the fragment is the POSIX absolute
    # path (JSON-safe — no backslashes — and bash-readable).
    local q_settings
    q_settings=$(printf '%q' "$SETTINGS_FRAGMENT")
    [ -r "$AUTO_APPROVE_HOOK" ] || \
        echo "WARN pipeline-cadence: auto-approve hook not readable at $AUTO_APPROVE_HOOK (cadence runs may stall on compound-bash prompts)" >&2

    local dow harvest_hh harvest_mm synth_hh synth_mm health_hh health_mm
    dow=$(dow_num "$HEALTH_DAY")
    harvest_hh="${HARVEST_TIME%:*}"; harvest_mm="${HARVEST_TIME#*:}"
    synth_hh="${SYNTH_TIME%:*}"; synth_mm="${SYNTH_TIME#*:}"
    health_hh="${HEALTH_TIME%:*}"; health_mm="${HEALTH_TIME#*:}"
    local entry_harvest entry_synth entry_health
    entry_harvest="$harvest_mm $harvest_hh * * * $(cron_escape "$CRON_RUNNER_HARVEST") # $TASK_HARVEST"
    entry_synth="$synth_mm $synth_hh * * * $(cron_escape "$CRON_RUNNER_SYNTH") # $TASK_SYNTH"
    entry_health="$health_mm $health_hh * * $dow $(cron_escape "$CRON_RUNNER_HEALTH") # $TASK_HEALTH"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: would write $SETTINGS_FRAGMENT:"
        emit_settings_fragment "$AUTO_APPROVE_HOOK" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_HARVEST:"
        emit_runner "$TASK_HARVEST" "$q_vault" "$q_claude" "$q_harvest_prompt" "$q_log_harvest" "$q_settings" "$q_node_dir" "$q_harvest_model" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_SYNTH:"
        emit_runner "$TASK_SYNTH" "$q_vault" "$q_claude" "$q_synth_prompt" "$q_log_synth" "$q_settings" "$q_node_dir" "$q_synth_model" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_HEALTH:"
        emit_runner "$TASK_HEALTH" "$q_vault" "$q_claude" "$q_health_prompt" "$q_log_health" "$q_settings" "$q_node_dir" "$q_health_model" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would add crontab entries:"
        echo "    $entry_harvest"
        echo "    $entry_synth"
        echo "    $entry_health"
        echo "pipeline-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Stage the runners at temp paths and promote (mv) them only after
    # the crontab install succeeds: writing them in place first would
    # let a failed install (exit 4) leave the OLD crontab live while
    # the runner files already carry the NEW config — a silent
    # half-state under --force re-arm.
    # Stage the settings fragment (HIMMEL-575) alongside the runners and promote
    # it on the SAME success gate — writing it in place before the install would
    # leave an orphan cadence-settings.json on a failed fresh arm, and under a
    # --force re-arm that changes HIMMEL_ROOT then fails to install, the live old
    # runners would silently pick up the new hook path via the shared fragment.
    local tmp_harvest="$CRON_RUNNER_HARVEST.tmp.$$" tmp_synth="$CRON_RUNNER_SYNTH.tmp.$$" tmp_health="$CRON_RUNNER_HEALTH.tmp.$$"
    local tmp_settings="$SETTINGS_FRAGMENT.tmp.$$"
    emit_settings_fragment "$AUTO_APPROVE_HOOK" > "$tmp_settings"
    emit_runner "$TASK_HARVEST" "$q_vault" "$q_claude" "$q_harvest_prompt" "$q_log_harvest" "$q_settings" "$q_node_dir" "$q_harvest_model" > "$tmp_harvest"
    emit_runner "$TASK_SYNTH"  "$q_vault" "$q_claude" "$q_synth_prompt"  "$q_log_synth"  "$q_settings" "$q_node_dir" "$q_synth_model"   > "$tmp_synth"
    emit_runner "$TASK_HEALTH" "$q_vault" "$q_claude" "$q_health_prompt" "$q_log_health" "$q_settings" "$q_node_dir" "$q_health_model"  > "$tmp_health"
    chmod +x "$tmp_harvest" "$tmp_synth" "$tmp_health"

    # Single atomic rewrite: everything that isn't ours, then all three
    # cadence entries.
    local newtab
    newtab=$(mktemp -t pipeline-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" || true
        fi
        printf '%s\n' "$entry_harvest" "$entry_synth" "$entry_health"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        # Pre-existing runners were never touched; sweep the staged
        # new-config ones (runners + fragment) so no half-state survives.
        rm -f "$tmp_harvest" "$tmp_synth" "$tmp_health" "$tmp_settings"
        echo "    existing runner files left untouched" >&2
        exit 4
    fi
    mv -f "$tmp_harvest" "$CRON_RUNNER_HARVEST"
    mv -f "$tmp_synth"  "$CRON_RUNNER_SYNTH"
    mv -f "$tmp_health" "$CRON_RUNNER_HEALTH"
    mv -f "$tmp_settings" "$SETTINGS_FRAGMENT"

    cat <<EOF

================================================================
  PIPELINE CADENCE ARMED (HIMMEL-255 / HIMMEL-265 cron / HIMMEL-357 / HIMMEL-506 / HIMMEL-798)
  $TASK_HARVEST  daily   $HARVEST_TIME  [model: $HARVEST_MODEL]  -> $DAILY_CHAIN
  $TASK_SYNTH    daily   $SYNTH_TIME    [model: $SYNTH_MODEL]    -> /synthesize-clips + /archive-clips
  $TASK_HEALTH   weekly  $HEALTH_DAY $HEALTH_TIME [model: $HEALTH_MODEL] -> /obsidian-health
  Vault: $VAULT
  Runner .sh: $BAT_DIR

  Sessions launch as bounded interactive claude runs (stdin from
  /dev/null) in the vault directory. Disarm anytime with:
      bash scripts/luna/pipeline-cadence.sh disarm
================================================================
EOF
}

case "$SUBCMD" in
    arm)    if [ "$PLATFORM" = "windows" ]; then cmd_arm;    else cron_arm;    fi ;;
    status) if [ "$PLATFORM" = "windows" ]; then cmd_status; else cron_status; fi ;;
    disarm) if [ "$PLATFORM" = "windows" ]; then cmd_disarm; else cron_disarm; fi ;;
esac
