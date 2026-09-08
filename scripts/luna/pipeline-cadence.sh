#!/usr/bin/env bash
# pipeline-cadence.sh — arm/status/disarm the recurring clip-pipeline
# cadence (HIMMEL-255).
#
# The luna vault's runbooks table gives only loose guidance
# (/synthesize-clips = "after a clip batch", /obsidian-health = "after
# big ingests") — but nothing was scheduled; every run was operator-
# remembered. The pipeline is idempotent at every stage by design
# (markers: harvested_at, processed, synthesis dedup window, _done/
# move) — exactly the cron-safe shape. This script registers the four
# recurring jobs with the OS scheduler, following the
# scripts/handover/arm-resume.sh precedent (HIMMEL-122):
#
#   HIMMEL-Pipeline-FetchHealth daily  (default 01:30, no LLM)          HIMMEL-1449
#       python fetch-health.py
#   HIMMEL-Pipeline-Harvest     daily   (default 02:00, model: sonnet)  HIMMEL-357/798
#       claude --model sonnet "/harvest-clips ... then /triage-clips ... then /ig-media-enrich ..." < NUL
#   HIMMEL-Pipeline-Synthesize  daily   (default 03:00, model: sonnet)
#       claude --model sonnet "/synthesize-clips … then /archive-clips …" < NUL
#   HIMMEL-Pipeline-Health      daily   (default 04:00, model: haiku)
#       claude --model haiku "vault-lint (obsidian-triage:vault-lint) …" < NUL
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
# health DAILY at 04:00 (HIMMEL-1383 — the weekly cadence meant vault
# drift was only visible once a week, and the haiku pin makes nightly
# affordable); machine assumed awake. Every leg
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
#   bash scripts/luna/pipeline-cadence.sh arm [--fetch-health-time HH:MM]
#       [--harvest-time HH:MM] [--ig-limit N] [--synth-time HH:MM]
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
TASK_FETCH_HEALTH="${TASK_PREFIX}FetchHealth"
TASK_HARVEST="${TASK_PREFIX}Harvest"
TASK_SYNTH="${TASK_PREFIX}Synthesize"
TASK_HEALTH="${TASK_PREFIX}Health"
SCHTASKS_BIN="${PIPELINE_SCHTASKS:-schtasks}"
CRONTAB_BIN="${PIPELINE_CRONTAB:-crontab}"

# Cross-platform user-home resolution (HIMMEL-645, generalized from
# HIMMEL-642's default_vault) + default_vault (HIMMEL-642), extracted into a
# shared lib on HIMMEL-2176 Stage 1 so other cadence scripts can source the
# same resolver instead of carrying their own copy.
# shellcheck source=../lib/resolve-user-home.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/resolve-user-home.sh"

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

# HIMMEL-2044: the bank guard the three claude legs launch behind. It was wired
# into refresh-graph-map.sh/graphmap-cadence.sh on HIMMEL-1841 and into NOTHING
# here, so Harvest/Synthesize/Health spent the shared 5h/weekly subscription
# bank unconditionally every night — against CLAUDE.md's HIMMEL-128 rule that a
# scheduled or unattended site preflights before spending. The generated runners
# branch on the helper's VERDICT TOKEN, never its exit code: bank-preflight.sh
# always exits 0 by design, and its BANK-STALE / BANK-UNKNOWN verdicts are
# deliberately fail-open (a box with no usage cache must still run its cadence).
# Only SKIPPED-BANK stops a leg.
BANK_PREFLIGHT="$HIMMEL_ROOT/scripts/lib/bank-preflight.sh"

# HIMMEL-2045: the free precondition for the synthesize leg. Answers NEW/NONE
# from the filesystem so a night with no newly triaged clips costs no session.
SYNTH_GATE="$HIMMEL_ROOT/scripts/luna/synth-input-check.sh"

# The marker line a runner writes to its log when a gate refused the leg. The
# sibling of LEG_DONE_MARKER: DONE means the session ran and finished, SKIPPED
# means no session was ever launched. Distinct words on purpose — a skipped
# night must not read as a parked one.
LEG_SKIPPED_MARKER="PIPELINE-LEG-SKIPPED"

# HIMMEL-2044 / CLAUDE.md § billing: every scheduled claude launch declares an
# explicit --permission-mode instead of inheriting the operator's saved default
# (a cadence must not change behaviour because someone toggled a mode in an
# interactive session). `acceptEdits` is the mode these legs have effectively
# been running under: file writes proceed, and every Bash call still goes
# through the cadence hook stack this script's --settings fragment wires.
# NEVER bypassPermissions — that is the one mode the billing rule forbids.
CADENCE_PERMISSION_MODE="acceptEdits"

# Runner-format version stamp (HIMMEL-588): emit_bat / emit_runner stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner so himmel-doctor / himmel-update
# can detect a cadence armed before a format change and nudge `arm --force`.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"

# Sourced for ONE constant: FLOW_RUN_ATTEMPT_MARKER (HIMMEL-1152). The emitted
# runners stamp that word into their log before each attempt and the same lib's
# --is-transient scan keys off it, so the two must never drift into separate
# copies of the same literal. (The lib is sourced, not executed — its only load
# -time effect is a guarded PATH self-heal.)
# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/flow-run-ledger.sh"

# Operator-decision defaults (HIMMEL-255 pinned comment, 2026-06-10;
# harvest leg added on HIMMEL-357, 2026-06-17; model pins + frequency
# shift on HIMMEL-506, 2026-07-11: synth weekly->daily, health
# monthly->weekly, per-leg --model pins so the cadence never inherits
# the operator's saved default tier; health weekly->daily on
# HIMMEL-1383, 2026-07-29; no-LLM fetch health added on HIMMEL-1449,
# 2026-08-02).
FETCH_HEALTH_TIME="01:30"
HARVEST_TIME="02:00"
IG_LIMIT="10"
SYNTH_TIME="03:00"
HEALTH_TIME="04:00"
# Health day-of-week (HIMMEL-1383 flipped this leg weekly -> daily; the
# 2026-08-23 cadence audit flips it back). Evidence: vault-lint's finding count
# moved 363 -> 369 in FOUR DAYS, and nobody consumes a nightly 369-line report —
# a daily session bought for a weekly-or-less signal. Weekly is the default
# again; `--health-day daily` restores the every-night shape for an operator who
# genuinely wants it, so this is a default change, not a capability removal.
HEALTH_DAY="SUN"
# Human-readable cadence label for the summary blocks; recomputed by
# validate_arm_inputs once --health-day is canonicalised.
HEALTH_CADENCE_LABEL="weekly  SUN 04:00"
HARVEST_MODEL="sonnet"
SYNTH_MODEL="sonnet"
HEALTH_MODEL="haiku"

# Bounded retry/resume for a claude leg killed by a TRANSIENT upstream API
# error (HIMMEL-1152). The 2026-07-17 harvest run died 48 minutes in on
# `API Error: Server error mid-response.` with 7 clips already recorded, and
# nothing retried it — the day's harvest simply sat unfinished. Every stage is
# idempotent through its own markers, so a re-invoke RESUMES; this is a
# scheduling wrapper around that contract, not a change to any harvest logic.
# 3 attempts = the original plus 2 retries; only a non-zero exit whose own
# attempt log carries FLOW_RUN_TRANSIENT_SIGNATURE_RE is ever retried.
RETRY_MAX_ATTEMPTS=3
RETRY_BACKOFF_1=60
RETRY_BACKOFF_2=180

# default_vault (HIMMEL-642) is sourced from ../lib/resolve-user-home.sh above.
VAULT="$(default_vault)"
FORCE=0
DRY_RUN=0

# Prompts are ASCII-only on purpose: the .bat is parsed by cmd.exe under
# the OEM codepage, where UTF-8 punctuation mojibakes into the prompt.
DAILY_CHAIN="/harvest-clips + /triage-clips + /ig-media-enrich"
# The bare completion marker the leg prompt asks for; flow_run_classify treats
# a zero exit WITHOUT this line in the log tail as `parked` (HIMMEL-1716).
LEG_DONE_MARKER="PIPELINE-LEG-DONE"
COMPLETION_INSTRUCTIONS="Run every command in the foreground. Never background a command or wait for a notification. Only if this cadence leg genuinely completed all of its work, print exactly PIPELINE-LEG-DONE as the final line of your output, on its own line with no prefix, suffix, or punctuation. If it was blocked, parked, or bailed early, do not print the marker."
HARVEST_PROMPT=""
SYNTH_PROMPT="Run /synthesize-clips to completion, then run /archive-clips. This is the scheduled daily pipeline cadence run (HIMMEL-255) - fully autonomous, no user prompts; report results and exit. $COMPLETION_INSTRUCTIONS"
HEALTH_PROMPT="Use the Skill tool to run the obsidian-triage:vault-lint skill (not /obsidian-health) against this vault to completion. This is the scheduled daily pipeline cadence run (HIMMEL-255/HIMMEL-1386) - fully autonomous, no user prompts; report results and exit. $COMPLETION_INSTRUCTIONS"

usage() {
    cat <<'EOF'
Usage: pipeline-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring clip-pipeline cadence
(HIMMEL-255/357/798/1449): daily no-LLM source fetch-health probes,
daily /harvest-clips (+ /triage-clips and
/ig-media-enrich chained after in the same session), daily
/synthesize-clips (+ /archive-clips chained after) and daily
vault-lint (obsidian-triage:vault-lint, HIMMEL-1386), run against the
luna vault as interactive bounded claude sessions. Each leg launches
with an explicit cheap --model pin (HIMMEL-506) so the cadence never
inherits the operator's saved default.

Subcommands:
  arm      Register all four recurring tasks. Dedup-guarded: refuses
           (rc=3) if any HIMMEL-Pipeline-* task already exists; --force
           replaces.
  status   Show which cadence tasks are armed (+ next run time + the
           pinned model parsed back out of each runner).
  disarm   Remove all tasks (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --fetch-health-time <HH:MM> Daily no-LLM fetch-health time (default 01:30)
  --harvest-time <HH:MM> Daily harvest+triage+ig-media-enrich time,
                         24h local (default 02:00)
  --ig-limit <N>         Daily /ig-media-enrich --limit N (default 10;
                         0 = unlimited)
  --synth-time <HH:MM>   Daily synthesize time, 24h local (default 03:00)
  --health-time <HH:MM>  Health fire time, 24h local (default 04:00)
  --health-day <DOW>     Health day: MON..SUN, or DAILY (default SUN —
                         demoted from daily by the 2026-08-23 cadence
                         audit; the finding count barely moves week to
                         week and nobody reads a nightly report)
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
        --fetch-health-time)   FETCH_HEALTH_TIME="${2:-}"; shift 2 ;;
        --fetch-health-time=*) FETCH_HEALTH_TIME="${1#--fetch-health-time=}"; shift ;;
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

HARVEST_PROMPT="Run /harvest-clips to completion, then run /triage-clips, then run /ig-media-enrich --limit $IG_LIMIT. The /ig-media-enrich step uses --limit $IG_LIMIT; 0 means unlimited, otherwise one night's batch is bounded and the ig_media_pending backlog drains across nights. If /ig-media-enrich fails due to missing ffmpeg/whisper, expired IG cookies, or media download errors, report the failure but it must not abort or fail the harvest+triage leg; finish the session normally. This is the scheduled daily pipeline cadence run (HIMMEL-357/HIMMEL-798) - fully autonomous, no user prompts; report results and exit. $COMPLETION_INSTRUCTIONS"

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
        "$TASK_FETCH_HEALTH") printf ' -> clip-source fetch probes [no LLM]' ;;
        "$TASK_HARVEST") printf ' -> %s' "$DAILY_CHAIN" ;;
    esac
}

# Map a cadence task name to its generated runner file path (.bat on
# Windows, .sh on POSIX) so status can surface the pinned model (HIMMEL-506).
# Returns the path on stdout; rc 1 on an unknown name.
runner_for_name() {
    local base ext
    case "$1" in
        "$TASK_FETCH_HEALTH") base="pipeline-fetch-health" ;;
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
            cadence_registered_status "$name" "${next:+ (next run: $next)}$(task_summary "$name")$(model_suffix "$name")" || return 2
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
    status_one "$TASK_FETCH_HEALTH" || status_rc=2
    status_log "$BAT_DIR/pipeline-fetch-health.log"
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
    for name in "$TASK_FETCH_HEALTH" "$TASK_HARVEST" "$TASK_SYNTH" "$TASK_HEALTH"; do
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
        rm -f "$BAT_DIR/pipeline-fetch-health.bat" "$BAT_DIR/pipeline-harvest.bat" "$BAT_DIR/pipeline-synthesize.bat" "$BAT_DIR/pipeline-health.bat"
        rm -f "$BAT_DIR/pipeline-fetch-health.vbs" "$BAT_DIR/pipeline-harvest.vbs" "$BAT_DIR/pipeline-synthesize.vbs" "$BAT_DIR/pipeline-health.vbs" "$SETTINGS_FRAGMENT"
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
# EVERY parameter arrives already cadence_cmd_escape'd, and every name says so.
# This emitter used to split the job: four values came in pre-escaped from
# cmd_arm while six arrived raw and were escaped here (public-PR CR). Both
# sibling emitters — codex-sweep-cadence.sh and graphmap-cadence.sh — settle on
# caller-escapes-everything, so this file was the outlier. The split is also
# precisely how a value slips through unescaped: this PR's own history has the
# model (HIMMEL-506), then bash_win, then claude_win (HIMMEL-1281) each being
# discovered as "the last raw %s" in a separate round, because a raw parameter
# sitting among escaped ones looks like it was already handled. With the
# convention "if it is not named _esc it does not belong in a printf here",
# the next added parameter is checkable by eye instead of by archaeology.
#
# The escaping itself did NOT move to a weaker place: cmd_arm already builds
# vault/prompt/log/settings that way and is the single call path (the dry-run
# preview and the real write share one set of locals), and validate_arm_inputs
# still rejects metacharacters at the gate.
emit_bat() {
    local vault_win_esc="$1" claude_win_esc="$2" prompt_esc="$3" log_win_esc="$4" settings_esc="$5" model_esc="$6" flow_esc="$7" task_name_esc="$8" bash_win_esc="$9" flow_lib_m_esc="${10}" git_bin_esc="${11:-}" bank_lib_m_esc="${12:-}" gate_lib_m_esc="${13:-}"
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Pin editor hooks to the no-op `true` so a cadence child (stdin closed under
    # schtasks) can never block on an editor prompt (HIMMEL-1753).
    cadence_bat_editor_set
    # Prepend Git's usr\bin + bin so the NON-LOGIN bash.exe the flow-run-ledger
    # legs fire finds GNU coreutils (dirname/date/tail/grep/wc/tr) ahead of
    # System32 (HIMMEL-1672). claude/bash/flow-lib are all absolute paths below;
    # this fixes their unqualified coreutils, not those resolutions.
    if [ -n "$git_bin_esc" ]; then
        printf 'set "PATH=%s;%%PATH%%"\r\n' "$git_bin_esc"
    fi
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_win_esc" "$log_win_esc" "$log_win_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_win_esc"
    printf 'cd /d "%s" >> "%s" 2>&1 || exit /b 1\r\n' "$vault_win_esc" "$log_win_esc"
    # Capture the run_id via a temp file, NOT `for /f` — for /f re-parses its
    # backquoted command through cmd /c, whose quote-stripping mangles a
    # command that STARTS with a quoted path and carries more quoted args
    # (live-fire verified s52: FLOW_RUN_ID came back empty). A plain quoted
    # command line with a redirect parses fine.
    printf 'set "FLOW_RUN_TMP=%%TEMP%%\\flow-run-%s.tmp"\r\n' "$task_name_esc"

    # --- Gate 1 (HIMMEL-2045): is there anything to do? -------------------
    # Emitted ONLY for a leg that was given a gate script (today: synthesize).
    # Ordered BEFORE the bank preflight on purpose: this check is pure local
    # filesystem work, the preflight shells a network fetch. Ask the free
    # question first.
    # The verdict is read through the same temp-file capture the ledger rows
    # use -- NOT `for /f`, whose cmd /c re-parse mangles a quoted-path command
    # line (live-fire verified, see the FLOW_RUN_ID note below). stderr is
    # appended to the leg log so the reason a night was skipped is on disk.
    if [ -n "$gate_lib_m_esc" ]; then
        printf 'set "PIPELINE_GATE="\r\n'
        # `.` not the vault path: the runner cd'd into the vault above, and a
        # Windows-form path handed to a bash argument loses its backslashes to
        # shell escaping. See the helper's own header.
        printf '"%s" "%s" "." > "%%FLOW_RUN_TMP%%" 2>> "%s"\r\n' "$bash_win_esc" "$gate_lib_m_esc" "$log_win_esc"
        printf 'if exist "%%FLOW_RUN_TMP%%" set /p PIPELINE_GATE=<"%%FLOW_RUN_TMP%%"\r\n'
        printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1\r\n'
        # Fail-open by construction: ONLY the explicit NONE token skips. An
        # empty verdict (helper missing, bash unusable) falls through and the
        # leg runs, exactly as it did before this gate existed.
        # The reason is set UNCONDITIONALLY on the line before the test, never
        # as `if ... set X & goto Y`: cmd.exe splits on `&` at the TOP level,
        # so the goto in that shape would run whether the `if` matched or not.
        printf 'set "PIPELINE_SKIP_REASON=no-new-input"\r\n'
        printf 'if "%%PIPELINE_GATE%%"=="NONE" goto pipeline_skipped\r\n'
    fi

    # --- Gate 2 (HIMMEL-2044): may we spend the bank? ---------------------
    # CADENCE_BANK_LEG is what makes the spend ATTRIBUTABLE: before this every
    # row in ~/.himmel/cadence-ledger.jsonl read leg:"unknown". The flow name
    # (pipeline-harvest / -synthesize / -health) is already this leg's identity
    # in flow-runs.jsonl, so the two ledgers join on the same word.
    #
    # NO `timeout` wrapper here, unlike refresh-graph-map.sh's call site. That
    # one guards a multi-HOUR extraction where an unbounded precondition check
    # is a real hazard. bank-preflight.sh's only network work is
    # usage-cache-producer.sh, whose single curl is already `--max-time 5`, and
    # this leg's own budget is ~20 minutes -- a second bound would be
    # speculative, and emitting one through the cmd -> bash boundary costs more
    # quoting risk than it removes. Revisit if the producer ever grows an
    # unbounded call.
    if [ -n "$bank_lib_m_esc" ]; then
        printf 'set "CADENCE_BANK_LEG=%s"\r\n' "$flow_esc"
        printf 'set "PIPELINE_BANK="\r\n'
        printf '"%s" "%s" > "%%FLOW_RUN_TMP%%" 2>> "%s"\r\n' "$bash_win_esc" "$bank_lib_m_esc" "$log_win_esc"
        printf 'if exist "%%FLOW_RUN_TMP%%" set /p PIPELINE_BANK=<"%%FLOW_RUN_TMP%%"\r\n'
        printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1\r\n'
        # Only SKIPPED-BANK refuses. BANK-STALE / BANK-UNKNOWN are the helper's
        # deliberate fail-open verdicts and an empty capture means the helper
        # could not run at all -- neither may silence a cadence.
        printf 'set "PIPELINE_SKIP_REASON=bank-at-threshold"\r\n'
        printf 'if "%%PIPELINE_BANK%%"=="SKIPPED-BANK" goto pipeline_skipped\r\n'
    fi

    # HIMMEL-1152 retry/resume loop. cmd.exe has no `while`, so an attempt is a
    # goto label — which also means no delayed expansion (`!var!`) is needed:
    # a goto re-parses each line on every pass, so %FLOW_RUN_ATTEMPT% is the
    # current value. The marker line is what --is-transient scans FORWARD from,
    # so each attempt is judged on its own output, never on a previous
    # attempt's leftover error. Everything from the marker to :pipeline_done is
    # one attempt, and every attempt lands its own start/end ledger pair.
    printf 'set "FLOW_RUN_ATTEMPT=1"\r\n'
    printf ':pipeline_attempt\r\n'
    printf 'echo [%s %%FLOW_RUN_ATTEMPT%%/%s] >> "%s" 2>&1\r\n' "$FLOW_RUN_ATTEMPT_MARKER" "$RETRY_MAX_ATTEMPTS" "$log_win_esc"
    printf 'set "FLOW_RUN_ID="\r\n'
    printf '"%s" "%s" --append-start "%s" "" "%%COMPUTERNAME%%" "claude" "%s" "%s" "%s" "" > "%%FLOW_RUN_TMP%%" 2>NUL\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$flow_esc" "$model_esc" "$task_name_esc" "$log_win_esc"
    printf 'if exist "%%FLOW_RUN_TMP%%" set /p FLOW_RUN_ID=<"%%FLOW_RUN_TMP%%"\r\n'
    printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1\r\n'
    # HIMMEL-951: no bg-wait ceiling override here — CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
    # only affects --print mode, and cadence runners are interactive-shaped (HIMMEL-128).
    # `call` (HIMMEL-1389, mirroring the #1454 fix in drift-fix-cadence.sh): when
    # claude resolves to a .cmd/.bat shim (npm-global install), a bare invocation
    # makes cmd.exe TRANSFER control into the shim and never come back — every
    # line below (rc capture, classify, the --append-end ledger row, exit /b)
    # would silently never run. Latent where claude is an .exe; fatal on a shim.
    # --permission-mode is EXPLICIT (HIMMEL-2044): an unattended launch must not
    # inherit whatever mode the operator last saved interactively. In-repo
    # constant, no operator input, so it carries no escaping burden.
    printf 'call "%s" --model "%s" --permission-mode "%s" --settings "%s" "%s" < NUL >> "%s" 2>&1\r\n' "$claude_win_esc" "$model_esc" "$CADENCE_PERMISSION_MODE" "$settings_esc" "$prompt_esc" "$log_win_esc"
    printf 'set "FLOW_RUN_RC=%%ERRORLEVEL%%"\r\n'
    # Fail-closed fallback (coderabbit #1762): if the classifier is unavailable
    # or prints nothing, a zero-rc run is `parked` (no proof of completion),
    # a non-zero run `error` -- never `complete` by default.
    printf 'set "FLOW_RUN_OUTCOME="\r\n'
    printf '"%s" "%s" --classify "%%FLOW_RUN_RC%%" "%s" "" "%s" > "%%FLOW_RUN_TMP%%" 2>NUL\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$log_win_esc" "$LEG_DONE_MARKER"
    printf 'if exist "%%FLOW_RUN_TMP%%" set /p FLOW_RUN_OUTCOME=<"%%FLOW_RUN_TMP%%"\r\n'
    printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1\r\n'
    printf 'if "%%FLOW_RUN_OUTCOME%%"=="" if "%%FLOW_RUN_RC%%"=="0" set "FLOW_RUN_OUTCOME=parked"\r\n'
    printf 'if "%%FLOW_RUN_OUTCOME%%"=="" set "FLOW_RUN_OUTCOME=error"\r\n'
    # The end row carries the attempt in `note` — the ONE ledger, one row pair
    # per attempt (HIMMEL-1152), so a retried night is readable as
    # attempt=1/3 error -> attempt=2/3 complete instead of a single mystery.
    printf 'if not "%%FLOW_RUN_ID%%"=="" "%s" "%s" --append-end "%s" "%%FLOW_RUN_ID%%" "" "%%FLOW_RUN_RC%%" "%%FLOW_RUN_OUTCOME%%" "" "attempt=%%FLOW_RUN_ATTEMPT%%/%s" > NUL 2>&1\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$flow_esc" "$RETRY_MAX_ATTEMPTS"
    # Retry ONLY a non-zero exit whose own attempt log carries the transient
    # upstream signature, and only within the bound. `if errorlevel 1` is true
    # for any non-zero, so a --is-transient that cannot run (missing bash, no
    # awk) falls through to done — fail-closed, never a retry storm.
    printf 'if "%%FLOW_RUN_RC%%"=="0" goto pipeline_done\r\n'
    printf 'if %%FLOW_RUN_ATTEMPT%% GEQ %s goto pipeline_done\r\n' "$RETRY_MAX_ATTEMPTS"
    printf '"%s" "%s" --is-transient "%%FLOW_RUN_RC%%" "%s"\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$log_win_esc"
    printf 'if errorlevel 1 goto pipeline_done\r\n'
    printf 'set "FLOW_RUN_DELAY=%s"\r\n' "$RETRY_BACKOFF_1"
    printf 'if %%FLOW_RUN_ATTEMPT%% GEQ 2 set "FLOW_RUN_DELAY=%s"\r\n' "$RETRY_BACKOFF_2"
    printf 'echo [retry %%FLOW_RUN_ATTEMPT%%/%s after transient upstream API error - sleeping %%FLOW_RUN_DELAY%%s] >> "%s" 2>&1\r\n' "$((RETRY_MAX_ATTEMPTS - 1))" "$log_win_esc"
    # The backoff runs through the bash.exe this runner already bakes in:
    # `timeout /t` refuses a redirected stdin (which is exactly how the cadence
    # fires) and `ping -n` is a lie about what the line does.
    printf '"%s" -c "sleep %%FLOW_RUN_DELAY%%"\r\n' "$bash_win_esc"
    printf 'set /a FLOW_RUN_ATTEMPT+=1\r\n'
    printf 'goto pipeline_attempt\r\n'
    printf ':pipeline_done\r\n'
    # HIMMEL-1716: a parked leg (zero claude rc, no PIPELINE-LEG-DONE in the
    # log) must reach Task Scheduler as a FAILURE, not rc=0 -- the same
    # exit-code fidelity HIMMEL-1706 gave the codex sweep. The ledger row
    # above keeps the true rc + outcome=parked; only the scheduler-visible
    # code is raised. 3 = parked (1 = cd failed, claude's own rc otherwise).
    printf 'if "%%FLOW_RUN_OUTCOME%%"=="parked" if "%%FLOW_RUN_RC%%"=="0" exit /b 3\r\n'
    # HIMMEL-2045 completion stamp. Written ONLY on a leg that genuinely
    # finished (`complete` is the classifier's verdict when the session printed
    # PIPELINE-LEG-DONE), because it is the reference the input gate measures
    # "new since" against. Stamping a parked or errored night would advance the
    # reference past clips no session ever considered, and those clips would
    # never be synthesized. Emitted only for a gated leg.
    if [ -n "$gate_lib_m_esc" ]; then
        printf 'if "%%FLOW_RUN_OUTCOME%%"=="complete" "%s" "%s" --stamp "." >> "%s" 2>&1\r\n' "$bash_win_esc" "$gate_lib_m_esc" "$log_win_esc"
    fi
    printf 'exit /b %%FLOW_RUN_RC%%\r\n'
    # --- deliberate skip (HIMMEL-2044 / HIMMEL-2045) ----------------------
    # rc 0, NOT the 3 a parked leg exits with. Those are different events: a
    # parked leg SPENT a session and produced nothing (a failure the scheduler
    # must surface), a skipped leg deliberately spent nothing. The evidence
    # lives where the audit asked for it -- a PIPELINE-LEG-SKIPPED line in the
    # log and a start/end ledger pair whose `note` carries the reason -- so a
    # skipped night is legible without being a false alarm.
    # Unreachable for an ungated leg: the `exit /b` above is the last line it
    # executes, and a label cmd.exe never jumps to costs nothing.
    if [ -n "$bank_lib_m_esc" ] || [ -n "$gate_lib_m_esc" ]; then
        printf ':pipeline_skipped\r\n'
        printf 'echo [%s %%PIPELINE_SKIP_REASON%%] >> "%s" 2>&1\r\n' "$LEG_SKIPPED_MARKER" "$log_win_esc"
        printf 'set "FLOW_RUN_ID="\r\n'
        printf '"%s" "%s" --append-start "%s" "" "%%COMPUTERNAME%%" "claude" "%s" "%s" "%s" "" > "%%FLOW_RUN_TMP%%" 2>NUL\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$flow_esc" "$model_esc" "$task_name_esc" "$log_win_esc"
        printf 'if exist "%%FLOW_RUN_TMP%%" set /p FLOW_RUN_ID=<"%%FLOW_RUN_TMP%%"\r\n'
        printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1\r\n'
        printf 'if not "%%FLOW_RUN_ID%%"=="" "%s" "%s" --append-end "%s" "%%FLOW_RUN_ID%%" "" "0" "skipped" "0" "%%PIPELINE_SKIP_REASON%%" > NUL 2>&1\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$flow_esc"
        printf 'exit /b 0\r\n'
    fi
}

# Emit the plain-script fetch-health runner. It rotates one prior log, writes
# no fetched response content, and returns the probe's aggregate exit code.
#
# HIMMEL-1724: it also writes the SAME flow-run ledger start/end rows emit_bat
# writes, so the FetchHealth leg participates in stall / never-started
# detection. Without them the ledger never had a `pipeline-fetch-health` row,
# so "the task stopped firing" was indistinguishable from "never armed" — the
# leg reported success by being silent.
#
# The outcome is derived from the probe's rc inline instead of through
# flow_run_classify: that classifier exists to read a CLAUDE session log (the
# truncation signature, the PIPELINE-LEG-DONE completion marker), and this leg
# runs no LLM — its rc IS the completion signal, so there is no `parked` state
# to detect and nothing in the probe log for the classifier to read. Deriving
# it here also keeps the row honest when the ledger lib is unreachable: the
# end row simply never appears (append-start failed too), rather than a
# fail-open `complete`.
emit_fetch_health_bat() {
    local python_win_esc="$1" script_win_esc="$2" log_win_esc="$3" env_file_win_esc="$4" bash_win_esc="$5" flow_lib_m_esc="$6" flow_esc="$7" task_name_esc="$8" git_bin_esc="${9:-}"
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Pin editor hooks to the no-op `true` so a cadence child (stdin closed under
    # schtasks) can never block on an editor prompt (HIMMEL-1753).
    cadence_bat_editor_set
    # Prepend Git's usr\bin + bin so the NON-LOGIN bash.exe the flow-run-ledger
    # legs fire finds GNU coreutils (dirname/date/mkdir/mv) ahead of System32
    # (HIMMEL-1672) — same reason as emit_bat, and now the same need: this
    # runner shells that lib twice.
    if [ -n "$git_bin_esc" ]; then
        printf 'set "PATH=%s;%%PATH%%"\r\n' "$git_bin_esc"
    fi
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_win_esc" "$log_win_esc" "$log_win_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_win_esc"
    # Source the repo's gitignored .env at FIRE time (not arm time) so the
    # credentialed probes (bitbucket/firecrawl) inherit env-sourced secrets
    # under schtasks' minimal environment — mirrors emit_fetch_health_runner's
    # `[ -f .env ] && . .env` (HIMMEL-1449 r2). Only the PATH is embedded
    # (quoted); the values are parsed by cmd at fire time, never baked into the
    # .bat — secrets stay in the gitignored file (HIMMEL-1470). `for /f` skips
    # blank lines; eol=# skips comments; tokens=1,* with delims== keeps `=` in
    # values; the quoted `set "K=V"` survives value metacharacters (& | < >).
    printf 'if exist "%s" for /f "usebackq eol=# tokens=1,* delims==" %%%%K in ("%s") do set "%%%%K=%%%%L"\r\n' "$env_file_win_esc" "$env_file_win_esc"
    # Ledger start row (HIMMEL-1724). Same temp-file capture as emit_bat — NOT
    # `for /f`, whose cmd /c re-parse mangles a quoted-path command line.
    printf 'set "FLOW_RUN_ID="\r\n'
    printf 'set "FLOW_RUN_TMP=%%TEMP%%\\flow-run-%s.tmp"\r\n' "$task_name_esc"
    printf '"%s" "%s" --append-start "%s" "" "%%COMPUTERNAME%%" "python" "" "%s" "%s" "" > "%%FLOW_RUN_TMP%%" 2>NUL\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$flow_esc" "$task_name_esc" "$log_win_esc"
    printf 'if exist "%%FLOW_RUN_TMP%%" set /p FLOW_RUN_ID=<"%%FLOW_RUN_TMP%%"\r\n'
    printf 'del /q "%%FLOW_RUN_TMP%%" >NUL 2>&1\r\n'
    # `call` (HIMMEL-1389): pyenv-win/conda expose `python` as a .bat shim, and
    # a bare invocation of one transfers control away for good — the rc stamp,
    # the ledger end row and the exit /b below would never run, which is the
    # exact invisibility this leg is being fixed for.
    printf 'call "%s" "%s" >> "%s" 2>&1\r\n' "$python_win_esc" "$script_win_esc" "$log_win_esc"
    printf 'set "FETCH_HEALTH_RC=%%ERRORLEVEL%%"\r\n'
    printf 'echo [exit rc=%%FETCH_HEALTH_RC%%] >> "%s" 2>&1\r\n' "$log_win_esc"
    printf 'set "FLOW_RUN_OUTCOME=complete"\r\n'
    printf 'if not "%%FETCH_HEALTH_RC%%"=="0" set "FLOW_RUN_OUTCOME=error"\r\n'
    printf 'if not "%%FLOW_RUN_ID%%"=="" "%s" "%s" --append-end "%s" "%%FLOW_RUN_ID%%" "" "%%FETCH_HEALTH_RC%%" "%%FLOW_RUN_OUTCOME%%" "" "" > NUL 2>&1\r\n' "$bash_win_esc" "$flow_lib_m_esc" "$flow_esc"
    printf 'exit /b %%FETCH_HEALTH_RC%%\r\n'
}

# Emit the JSON settings fragment that wires the auto-approve-safe-bash hook by
# absolute path (HIMMEL-575). hook_path must be a forward-slash, JSON-safe
# absolute path (no backslashes — use cygpath -m on Windows). The command is
# unquoted to match himmel's own .claude/settings.json hook wiring convention.
#
# HIMMEL-1036: the fragment also force-enables obsidian-triage@himmel via
# enabledPlugins. The operator disables that plugin INTERACTIVELY (user-scope
# settings.local.json {"obsidian-triage@himmel": false}) — it's the luna clip
# pipeline, unused in hand-driven sessions. But this cadence IS that pipeline,
# so the nightly run must re-enable it. `--settings` is the highest non-managed
# precedence layer (spike-confirmed, HIMMEL-1040 design), so this enabledPlugins
# override wins over the settings.local.json disable and keeps the cadence live.
emit_settings_fragment() {
    local hook_path="$1"
    # HIMMEL-1682 S2a/S2b: two cadence-scoped controls live beside
    # auto-approve-safe-bash.sh. Derive their paths in the SAME form the caller
    # already resolved for hook_path (cygpath -m on Windows, POSIX elsewhere),
    # so no new path plumbing or signature change is needed. The deny wires
    # FIRST so a run_in_background deny is evaluated before any allow (an exit-2
    # deny wins over a hook allow regardless, but deny-first is unambiguous);
    # the enumerated-engine allow follows; auto-approve stays last. These three
    # are wired ONLY here (cadence-settings.json via --settings), so interactive
    # sessions are untouched.
    # HIMMEL-1973: a fourth control on its own matcher. Every hook above is
    # Bash-only, so the PowerShell tool is an unguarded second shell in a
    # cadence session — the health leg emitted the vault-lint engine through it
    # on 2026-08-20 and parked on an approval nobody was awake to give. Deny it
    # and redirect the model to the Bash tool, where the engine grant lives.
    local hooks_dir="${hook_path%/*}"
    local deny_bg_hook="$hooks_dir/cadence-deny-background.sh"
    local approve_engines_hook="$hooks_dir/cadence-approve-engines.sh"
    local deny_pwsh_hook="$hooks_dir/cadence-deny-powershell.sh"
    # HIMMEL-1682: emit an ABSOLUTE interpreter path, never a bare `bash`.
    # Under raw CreateProcess order a bare `bash` resolves to
    # C:\Windows\System32\bash.exe — the WSL stub, which cannot read a
    # C:/Users/... Windows path (the recurring WSL trap, HIMMEL-486/453). The
    # fragment works today only because the v8 runner format prepends a GNU
    # PATH (1b34a070); that is one PATH change away from silently breaking
    # every cadence hook, and this function emits three such commands. Resolve
    # ONCE here. Mixed (forward-slash) form to match hook_path and stay
    # JSON-safe — `cygpath -m`, never `-w`. Prefer $BASH (the interpreter
    # actually running this script) over a PATH lookup, which a hermetic-PATH
    # stub can shadow.
    local bash_cmd="${BASH:-}"
    [ -n "$bash_cmd" ] || bash_cmd=$(command -v bash 2>/dev/null) || bash_cmd="/usr/bin/bash"
    if command -v cygpath >/dev/null 2>&1; then
        bash_cmd=$(cygpath -m "$bash_cmd" 2>/dev/null || printf '%s' "$bash_cmd")
    fi
    # A System32 resolution IS the WSL stub — reject it outright rather than
    # emitting a fragment that is broken in exactly the way this fix prevents.
    # Probe the common Git-for-Windows prefixes before retaining the canonical
    # path as a legible last-resort value when no installation is executable.
    local git_bash_candidate local_appdata_fs
    # LOCALAPPDATA is Windows-form with backslashes under Git Bash. Fold to
    # forward slashes before building a candidate from it — an un-folded
    # backslash path both fails the `-x` test unreliably AND, if it somehow
    # resolved, would land in bash_cmd and get interpolated raw into the JSON
    # fragment below, where backslashes are invalid JSON escaping.
    # shellcheck disable=SC1003
    local_appdata_fs=$(printf '%s' "${LOCALAPPDATA:-}" | tr '\\' '/')
    case "$bash_cmd" in
        *[Ss]ystem32*)
            bash_cmd=""
            for git_bash_candidate in \
                "C:/Program Files/Git/bin/bash.exe" \
                "C:/Program Files (x86)/Git/bin/bash.exe" \
                "${local_appdata_fs:+${local_appdata_fs}/Programs/Git/bin/bash.exe}"
            do
                [ -n "$git_bash_candidate" ] || continue
                if [ -x "$git_bash_candidate" ]; then
                    bash_cmd="$git_bash_candidate"
                    break
                fi
            done
            # HIMMEL-1682 CR round 4: no candidate above was executable — the
            # canonical last-resort assignment below names an interpreter
            # that does NOT exist on this machine. The emitted hook commands
            # will reference it anyway, and hooks fail non-blocking (exit !=
            # 2), so this loses cadence protections SILENTLY. Warn loudly on
            # stderr before falling back (stdout is the JSON fragment the
            # caller consumes — never write this there).
            [ -n "$bash_cmd" ] || echo "WARNING: no usable Git Bash interpreter detected at any candidate prefix; hooks will reference C:/Program Files/Git/bin/bash.exe, which does not exist — cadence hooks will silently fail non-blocking until Git for Windows is installed at a probed prefix." >&2
            [ -n "$bash_cmd" ] || bash_cmd="C:/Program Files/Git/bin/bash.exe"
            ;;
    esac
    # The Git-Bash path contains a space ("C:/Program Files/..."), so the
    # interpreter is quoted in the emitted command — \" in the JSON source,
    # a literal quote in the decoded string. The hook paths are quoted for the
    # same reason (a checkout under a spaced path would otherwise split), which
    # is the convention himmel's own .claude/settings.json hook wiring uses for
    # every argument.
    cat <<JSON
{
  "enabledPlugins": {
    "obsidian-triage@himmel": true
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"${bash_cmd}\" \"${deny_bg_hook}\"" },
          { "type": "command", "command": "\"${bash_cmd}\" \"${approve_engines_hook}\"" },
          { "type": "command", "command": "\"${bash_cmd}\" \"${hook_path}\"" }
        ]
      },
      {
        "matcher": "PowerShell",
        "hooks": [
          { "type": "command", "command": "\"${bash_cmd}\" \"${deny_pwsh_hook}\"" }
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

# Escape the XML-significant characters for text interpolated into an
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

# The <CalendarTrigger> schedule fragment. Three legs are daily (harvest +
# synthesize on HIMMEL-506; fetch health on HIMMEL-1449); health is weekly
# again unless --health-day daily says otherwise (cadence audit 2026-08-23).
schedule_daily_xml() {
    printf '      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>\n      </ScheduleByDay>'
}

# Weekly on ONE day. $1 is a canonical DOW token (MON..SUN) already validated
# by validate_arm_inputs; cron_dow/xml_dow are the only two places that know the
# mapping, so a new spelling is added in one place.
schedule_weekly_xml() {
    printf '      <ScheduleByWeek>\n        <DaysOfWeek>\n          <%s />\n        </DaysOfWeek>\n        <WeeksInterval>1</WeeksInterval>\n      </ScheduleByWeek>' "$(xml_dow "$1")"
}

# DOW token -> Task Scheduler element name / cron numeric field. Both tables
# live beside each other on purpose: they are the same fact in two dialects,
# and the Windows and POSIX arms must never disagree about which day "SUN" is.
xml_dow() {
    case "$1" in
        MON) printf 'Monday' ;;   TUE) printf 'Tuesday' ;;
        WED) printf 'Wednesday' ;; THU) printf 'Thursday' ;;
        FRI) printf 'Friday' ;;   SAT) printf 'Saturday' ;;
        *)   printf 'Sunday' ;;
    esac
}
cron_dow() {
    case "$1" in
        MON) printf '1' ;; TUE) printf '2' ;; WED) printf '3' ;;
        THU) printf '4' ;; FRI) printf '5' ;; SAT) printf '6' ;;
        *)   printf '0' ;;
    esac
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
    local bat_win="$1" start_time="$2" schedule_xml="$3" vbs_win vbs_args
    # HIMMEL-1753: Exec is a `wscript //B <shim>.vbs` wrapper around the .bat.
    # The earlier hidden-powershell wrapper (-WindowStyle Hidden) was MEASURED to
    # still allocate visible consoles; wscript //B hosting the .vbs shim (which
    # runs the .bat hidden via WScript.Shell.Run and forwards its exit code via
    # WScript.Quit) allocates zero consoles. The shim path is derived from the
    # .bat path through cadence_vbs_path — the SAME helper cmd_arm writes the
    # file with — so the referenced path and the written file can never disagree.
    # //B is the WSH batch-mode flag (no error/prompt UI); the path is quoted so
    # a BAT_DIR with spaces survives, then xml_escaped like any element text.
    # WScript.Quit in the shim preserves HIMMEL-1706 exit-code fidelity (rc=42
    # re-arm survives — proven in test-cadence-format.sh).
    vbs_win=$(cadence_vbs_path "$bat_win")
    vbs_args=$(xml_escape "//B \"${vbs_win}\"")
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
      <Command>wscript.exe</Command>
      <Arguments>${vbs_args}</Arguments>
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

# Input validation shared by the schtasks and cron arm paths.
validate_arm_inputs() {
    if ! [[ "$FETCH_HEALTH_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --fetch-health-time must be HH:MM (24h), got: $FETCH_HEALTH_TIME" >&2
        exit 1
    fi
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
    # Canonicalise --health-day once, here, so every consumer below (the XML
    # fragment, the cron DOW field, both summary blocks) reads one spelling.
    # bash 3.2 has no ${v^^}.
    HEALTH_DAY=$(printf '%s' "$HEALTH_DAY" | tr '[:lower:]' '[:upper:]')
    case "$HEALTH_DAY" in
        MON|TUE|WED|THU|FRI|SAT|SUN|DAILY) ;;
        *)
            echo "ERR pipeline-cadence: --health-day must be one of MON TUE WED THU FRI SAT SUN DAILY, got: $HEALTH_DAY" >&2
            exit 1 ;;
    esac
    if [ "$HEALTH_DAY" = DAILY ]; then
        HEALTH_CADENCE_LABEL="daily   $HEALTH_TIME"
    else
        HEALTH_CADENCE_LABEL="weekly  $HEALTH_DAY $HEALTH_TIME"
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
    cadence_require_wsh "pipeline-cadence" || exit 2

    # Resolve claude to an absolute Windows path so the .bat doesn't
    # depend on PATH in whatever cmd shell schtasks spawns.
    local claude_posix claude_win bash_posix bash_win flow_lib_m python_posix python_win fetch_script_win
    if ! claude_posix=$(command -v claude 2>/dev/null); then
        echo "ERR pipeline-cadence: 'claude' not on PATH at arm time" >&2
        exit 2
    fi
    if ! bash_posix=$(command -v bash 2>/dev/null); then
        echo "ERR pipeline-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    if python_posix=$(command -v python3 2>/dev/null); then
        :
    elif python_posix=$(command -v python 2>/dev/null); then
        :
    else
        echo "ERR pipeline-cadence: python3/python not on PATH at arm time (required for fetch-health)" >&2
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
    if ! bash_win=$(cygpath -w "$bash_posix" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for bash path: $bash_win" >&2
        exit 4
    fi
    if ! python_win=$(cygpath -w "$python_posix" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for python path: $python_win" >&2
        exit 4
    fi
    if ! fetch_script_win=$(cygpath -w "$HIMMEL_ROOT/scripts/luna/fetch-health.py" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for fetch-health.py: $fetch_script_win" >&2
        exit 4
    fi
    # HIMMEL-1470: the repo .env (gitignored, may be absent) is sourced by the
    # .bat at FIRE time so credentialed probes inherit env-sourced secrets under
    # schtasks' minimal environment. cygpath -w is a pure string transform, so a
    # missing .env still resolves; the .bat guards the load with `if exist`.
    if ! env_file_win=$(cygpath -w "$HIMMEL_ROOT/.env" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for repo .env: $env_file_win" >&2
        exit 4
    fi
    if ! flow_lib_m=$(cygpath -m "$HIMMEL_ROOT/scripts/lib/flow-run-ledger.sh" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -m failed for flow-run-ledger.sh: $flow_lib_m" >&2
        exit 4
    fi
    # The two gate helpers (HIMMEL-2044 / HIMMEL-2045). MIXED form (`cygpath
    # -m`, C:/...), like flow_lib_m and unlike the -w paths above: these are
    # bash arguments, and a Windows-form path loses its backslashes to shell
    # escaping the moment it crosses the cmd -> bash boundary.
    local bank_lib_m gate_lib_m
    if ! bank_lib_m=$(cygpath -m "$BANK_PREFLIGHT" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -m failed for bank-preflight.sh: $bank_lib_m" >&2
        exit 4
    fi
    if ! gate_lib_m=$(cygpath -m "$SYNTH_GATE" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -m failed for synth-input-check.sh: $gate_lib_m" >&2
        exit 4
    fi
    # Both gates are fail-open at fire time, so a missing helper degrades to the
    # pre-HIMMEL-2044 behaviour rather than breaking the cadence — but it must
    # not do so silently, because "the bank guard is armed" would then be false.
    [ -r "$BANK_PREFLIGHT" ] || \
        echo "WARN pipeline-cadence: bank-preflight not readable at $BANK_PREFLIGHT (claude legs will spend the bank UNGUARDED)" >&2
    [ -r "$SYNTH_GATE" ] || \
        echo "WARN pipeline-cadence: synth input gate not readable at $SYNTH_GATE (the synthesize leg will launch on empty nights)" >&2
    local vault_win
    if ! vault_win=$(cygpath -w "$VAULT" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for vault path: $vault_win" >&2
        exit 4
    fi
    # Drop a trailing separator (public-PR CR). `--vault` is operator input and
    # shell tab-completion happily supplies "…/vault/", which cygpath -w
    # PRESERVES: `C:\…\vault\`. That lands bare in `cd /d "%s"`, giving a
    # backslash immediately before the closing quote.
    #
    # Honesty about WHY: the review said cmd.exe's batch parser consumes that
    # `\"` as an escaped quote and corrupts the rest of the line. That does NOT
    # reproduce — measured on a spaced path with a trailing backslash, `cd`
    # succeeded, the `>>` redirect was honoured, the following line ran, rc 0.
    # Backslash-escaping of quotes is the C runtime's argv convention, not cmd's
    # own tokenizer, and this value is consumed by `cd /d`, a cmd BUILTIN.
    #
    # Normalizing anyway, because it stands on its own terms: a trailing
    # separator is redundant in a `cd` target (C:\foo and C:\foo\ are the same
    # directory), it is noise in a generated runner an operator has to read, and
    # stripping it removes the whole question rather than resting the runner's
    # correctness on a parser subtlety. Done HERE, at the source, rather than in
    # cadence_cmd_escape — the shared escaper is the %-only contract four
    # emitters depend on and that this PR spent rounds hardening; a path-shape
    # concern does not belong in it.
    # A DRIVE ROOT keeps its separator: `cd /d "C:\"` is the root of C:, while
    # `cd /d "C:"` means "the current directory on C:" — a different place, and
    # stripping there would be a real regression in the name of cosmetics.
    # Plain suffix removal in a loop (bash 3.2-safe; no extglob).
    while :; do
        case "$vault_win" in
            [A-Za-z]:\\) break ;;
            *\\)         vault_win="${vault_win%\\}" ;;
            *)           break ;;
        esac
    done

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
    vault_esc=$(cadence_cmd_escape "$vault_win")
    harvest_esc=$(cadence_cmd_escape "$HARVEST_PROMPT")
    synth_esc=$(cadence_cmd_escape "$SYNTH_PROMPT")
    health_esc=$(cadence_cmd_escape "$HEALTH_PROMPT")
    # The remaining six emit_bat parameters, escaped HERE rather than inside the
    # emitter (public-PR CR — see emit_bat's header). Escaped once and reused by
    # both the dry-run preview and the real write below, so the two can never
    # disagree about what lands in the .bat.
    local claude_win_esc bash_win_esc flow_lib_m_esc python_win_esc fetch_script_win_esc env_file_win_esc git_bin_esc
    claude_win_esc=$(cadence_cmd_escape "$claude_win")
    bash_win_esc=$(cadence_cmd_escape "$bash_win")
    # Git's usr\bin + bin, derived from the bash.exe path above (HIMMEL-1672):
    # prepended to PATH in emit_bat so the non-login bash.exe finds GNU coreutils
    # ahead of System32. Empty for a non-Git bash → emit_bat then omits the line.
    git_bin_esc=$(cadence_cmd_escape "$(cadence_git_bin_path_win "$bash_win")")
    flow_lib_m_esc=$(cadence_cmd_escape "$flow_lib_m")
    local bank_lib_m_esc gate_lib_m_esc
    bank_lib_m_esc=$(cadence_cmd_escape "$bank_lib_m")
    gate_lib_m_esc=$(cadence_cmd_escape "$gate_lib_m")
    python_win_esc=$(cadence_cmd_escape "$python_win")
    fetch_script_win_esc=$(cadence_cmd_escape "$fetch_script_win")
    env_file_win_esc=$(cadence_cmd_escape "$env_file_win")
    local harvest_model_esc synth_model_esc health_model_esc
    harvest_model_esc=$(cadence_cmd_escape "$HARVEST_MODEL")
    synth_model_esc=$(cadence_cmd_escape "$SYNTH_MODEL")
    health_model_esc=$(cadence_cmd_escape "$HEALTH_MODEL")
    local task_fetch_health_esc task_harvest_esc task_synth_esc task_health_esc
    task_fetch_health_esc=$(cadence_cmd_escape "$TASK_FETCH_HEALTH")
    task_harvest_esc=$(cadence_cmd_escape "$TASK_HARVEST")
    task_synth_esc=$(cadence_cmd_escape "$TASK_SYNTH")
    task_health_esc=$(cadence_cmd_escape "$TASK_HEALTH")
    # The flow names are in-repo literals, not operator input, so escaping them
    # changes nothing today. They go through the same call anyway: the value of
    # this convention is that NOTHING reaches emit_bat unescaped, and an
    # exception "because this one is a literal" is what makes the next one
    # arguable.
    local flow_fetch_health_esc flow_harvest_esc flow_synth_esc flow_health_esc
    flow_fetch_health_esc=$(cadence_cmd_escape "pipeline-fetch-health")
    flow_harvest_esc=$(cadence_cmd_escape "pipeline-harvest")
    flow_synth_esc=$(cadence_cmd_escape "pipeline-synthesize")
    flow_health_esc=$(cadence_cmd_escape "pipeline-health")
    local bat_fetch_health="$BAT_DIR/pipeline-fetch-health.bat"
    local bat_harvest="$BAT_DIR/pipeline-harvest.bat"
    local bat_synth="$BAT_DIR/pipeline-synthesize.bat"
    local bat_health="$BAT_DIR/pipeline-health.bat"
    # wscript //B shims (HIMMEL-1753) live beside their .bats; disarm removes
    # both together. Derived from the .bat Windows path through cadence_vbs_path
    # — the same helper emit_task_xml derives the referenced path with.
    local vbs_fetch_health="$BAT_DIR/pipeline-fetch-health.vbs"
    local vbs_harvest="$BAT_DIR/pipeline-harvest.vbs"
    local vbs_synth="$BAT_DIR/pipeline-synthesize.vbs"
    local vbs_health="$BAT_DIR/pipeline-health.vbs"

    # Fire-time run logs live next to the .bats (cmd-escaped for the
    # `>>` redirect target inside the .bat).
    local bat_dir_win log_fetch_health_esc log_harvest_esc log_synth_esc log_health_esc
    if ! bat_dir_win=$(cygpath -w "$BAT_DIR" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed for bat dir: $bat_dir_win" >&2
        exit 4
    fi
    log_fetch_health_esc=$(cadence_cmd_escape "$bat_dir_win\\pipeline-fetch-health.log")
    log_harvest_esc=$(cadence_cmd_escape "$bat_dir_win\\pipeline-harvest.log")
    log_synth_esc=$(cadence_cmd_escape "$bat_dir_win\\pipeline-synthesize.log")
    log_health_esc=$(cadence_cmd_escape "$bat_dir_win\\pipeline-health.log")

    # Settings fragment (HIMMEL-575): the `claude --settings` target inside each
    # .bat (a Windows path, cmd-escaped) plus the auto-approve hook's mixed
    # (C:/...) path embedded in the fragment JSON (forward-slash so it's both
    # JSON-safe and bash-readable when claude runs the hook command).
    local settings_esc hook_path_m
    settings_esc=$(cadence_cmd_escape "$bat_dir_win\\cadence-settings.json")
    if ! hook_path_m=$(cygpath -m "$AUTO_APPROVE_HOOK" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -m failed for hook path: $hook_path_m" >&2
        exit 4
    fi
    [ -r "$AUTO_APPROVE_HOOK" ] || \
        echo "WARN pipeline-cadence: auto-approve hook not readable at $AUTO_APPROVE_HOOK (cadence runs may stall on compound-bash prompts)" >&2
    # HIMMEL-1682 RETASK (CodeRabbit Major, judge-verified): the two S2a/S2b
    # cadence-scoped hooks emit_settings_fragment wires beside AUTO_APPROVE_HOOK
    # got no matching readability check. If either is missing at fire time, the
    # hook process fails to start; Claude Code treats a non-2 exit as
    # NON-BLOCKING, so the cadence session runs with that hook's protection
    # silently absent — exactly the permission surface this PR hardens.
    local hooks_dir_check="${AUTO_APPROVE_HOOK%/*}"
    [ -r "$hooks_dir_check/cadence-deny-background.sh" ] || \
        echo "WARN pipeline-cadence: deny-background hook not readable at $hooks_dir_check/cadence-deny-background.sh (background-command denies will be silently absent)" >&2
    [ -r "$hooks_dir_check/cadence-approve-engines.sh" ] || \
        echo "WARN pipeline-cadence: approve-engines hook not readable at $hooks_dir_check/cadence-approve-engines.sh (engine calls will prompt or stall)" >&2
    [ -r "$hooks_dir_check/cadence-deny-powershell.sh" ] || \
        echo "WARN pipeline-cadence: deny-powershell hook not readable at $hooks_dir_check/cadence-deny-powershell.sh (PowerShell-tool calls will bypass every cadence guardrail)" >&2

    # Per-cadence schedule fragments for the task XML (HIMMEL-362). Built
    # once and reused by the dry-run preview and the real create below.
    local sched_fetch_health sched_harvest sched_synth sched_health
    sched_fetch_health=$(schedule_daily_xml)
    sched_harvest=$(schedule_daily_xml)
    sched_synth=$(schedule_daily_xml)
    if [ "$HEALTH_DAY" = DAILY ]; then
        sched_health=$(schedule_daily_xml)
    else
        sched_health=$(schedule_weekly_xml "$HEALTH_DAY")
    fi

    # The .bat runner is the task's Exec Command. cygpath -w is a pure
    # string transform (the .bat need not exist yet), so resolve the win
    # paths before the dry-run preview too — the XML preview must show the
    # real Exec Command.
    local bat_fetch_health_win bat_harvest_win bat_synth_win bat_health_win
    if ! bat_fetch_health_win=$(cygpath -w "$bat_fetch_health" 2>&1); then
        echo "ERR pipeline-cadence: cygpath -w failed: $bat_fetch_health_win" >&2
        exit 4
    fi
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
        echo "DRY pipeline-cadence: would write $bat_fetch_health:"
        emit_fetch_health_bat "$python_win_esc" "$fetch_script_win_esc" "$log_fetch_health_esc" "$env_file_win_esc" "$bash_win_esc" "$flow_lib_m_esc" "$flow_fetch_health_esc" "$task_fetch_health_esc" "$git_bin_esc" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $vbs_fetch_health:"
        cadence_vbs_wrapper "$bat_fetch_health_win" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $bat_harvest:"
        emit_bat "$vault_esc" "$claude_win_esc" "$harvest_esc" "$log_harvest_esc" "$settings_esc" "$harvest_model_esc" "$flow_harvest_esc" "$task_harvest_esc" "$bash_win_esc" "$flow_lib_m_esc" "$git_bin_esc" "$bank_lib_m_esc" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $vbs_harvest:"
        cadence_vbs_wrapper "$bat_harvest_win" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $bat_synth:"
        emit_bat "$vault_esc" "$claude_win_esc" "$synth_esc" "$log_synth_esc" "$settings_esc" "$synth_model_esc" "$flow_synth_esc" "$task_synth_esc" "$bash_win_esc" "$flow_lib_m_esc" "$git_bin_esc" "$bank_lib_m_esc" "$gate_lib_m_esc" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $vbs_synth:"
        cadence_vbs_wrapper "$bat_synth_win" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $bat_health:"
        emit_bat "$vault_esc" "$claude_win_esc" "$health_esc" "$log_health_esc" "$settings_esc" "$health_model_esc" "$flow_health_esc" "$task_health_esc" "$bash_win_esc" "$flow_lib_m_esc" "$git_bin_esc" "$bank_lib_m_esc" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $vbs_health:"
        cadence_vbs_wrapper "$bat_health_win" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would schtasks /create /tn $TASK_FETCH_HEALTH /xml <daily $FETCH_HEALTH_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_fetch_health_win" "$FETCH_HEALTH_TIME" "$sched_fetch_health" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would schtasks /create /tn $TASK_HARVEST /xml <daily $HARVEST_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_harvest_win" "$HARVEST_TIME" "$sched_harvest" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would schtasks /create /tn $TASK_SYNTH /xml <daily $SYNTH_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_synth_win" "$SYNTH_TIME" "$sched_synth" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would schtasks /create /tn $TASK_HEALTH /xml <$HEALTH_CADENCE_LABEL, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_health_win" "$HEALTH_TIME" "$sched_health" | sed 's/^/    /'
        echo "pipeline-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    emit_settings_fragment "$hook_path_m" > "$SETTINGS_FRAGMENT"
    # Atomic runner publication (HIMMEL-1753 round 2, glm-3): every runner .bat
    # and .vbs shim is emitted to a staged temp BESIDE its final path (same dir
    # -> same filesystem -> `mv` is an atomic rename, not a copy) and promoted
    # only once complete, mirroring codex-sweep-cadence's publish discipline.
    # Redirecting straight onto the FINAL path let a task firing concurrently
    # with a re-arm read a half-written shim; after the rename the final path
    # only ever holds a complete file (old or new). Shims promote first (an
    # already-armed task can safely run a new shim against the still-current
    # .bat mid-replacement), and every promotion is CHECKED — a failed one
    # aborts the arm BEFORE any task is registered, with the staged temps
    # cleaned. A non-regular final path is refused too: `mv` onto a directory
    # squatting on a runner name "succeeds" by moving the staged file INSIDE
    # it, arming a task at a path that is not a file.
    local tmp_fetch_health_bat tmp_harvest_bat tmp_synth_bat tmp_health_bat
    local tmp_fetch_health_vbs tmp_harvest_vbs tmp_synth_vbs tmp_health_vbs
    tmp_fetch_health_bat=$(mktemp "$BAT_DIR/.pipeline-fetch-health.bat.XXXXXX")
    tmp_harvest_bat=$(mktemp "$BAT_DIR/.pipeline-harvest.bat.XXXXXX")
    tmp_synth_bat=$(mktemp "$BAT_DIR/.pipeline-synthesize.bat.XXXXXX")
    tmp_health_bat=$(mktemp "$BAT_DIR/.pipeline-health.bat.XXXXXX")
    tmp_fetch_health_vbs=$(mktemp "$BAT_DIR/.pipeline-fetch-health.vbs.XXXXXX")
    tmp_harvest_vbs=$(mktemp "$BAT_DIR/.pipeline-harvest.vbs.XXXXXX")
    tmp_synth_vbs=$(mktemp "$BAT_DIR/.pipeline-synthesize.vbs.XXXXXX")
    tmp_health_vbs=$(mktemp "$BAT_DIR/.pipeline-health.vbs.XXXXXX")
    emit_fetch_health_bat "$python_win_esc" "$fetch_script_win_esc" "$log_fetch_health_esc" "$env_file_win_esc" "$bash_win_esc" "$flow_lib_m_esc" "$flow_fetch_health_esc" "$task_fetch_health_esc" "$git_bin_esc" > "$tmp_fetch_health_bat"
    emit_bat "$vault_esc" "$claude_win_esc" "$harvest_esc" "$log_harvest_esc" "$settings_esc" "$harvest_model_esc" "$flow_harvest_esc" "$task_harvest_esc" "$bash_win_esc" "$flow_lib_m_esc" "$git_bin_esc" "$bank_lib_m_esc" > "$tmp_harvest_bat"
    emit_bat "$vault_esc" "$claude_win_esc" "$synth_esc"  "$log_synth_esc"  "$settings_esc" "$synth_model_esc"   "$flow_synth_esc" "$task_synth_esc" "$bash_win_esc" "$flow_lib_m_esc" "$git_bin_esc" "$bank_lib_m_esc" "$gate_lib_m_esc" > "$tmp_synth_bat"
    emit_bat "$vault_esc" "$claude_win_esc" "$health_esc" "$log_health_esc" "$settings_esc" "$health_model_esc"  "$flow_health_esc" "$task_health_esc" "$bash_win_esc" "$flow_lib_m_esc" "$git_bin_esc" "$bank_lib_m_esc" > "$tmp_health_bat"
    cadence_vbs_wrapper "$bat_fetch_health_win" > "$tmp_fetch_health_vbs"
    cadence_vbs_wrapper "$bat_harvest_win" > "$tmp_harvest_vbs"
    cadence_vbs_wrapper "$bat_synth_win" > "$tmp_synth_vbs"
    cadence_vbs_wrapper "$bat_health_win" > "$tmp_health_vbs"
    local promote_src promote_dst idx
    promote_src=("$tmp_fetch_health_vbs" "$tmp_harvest_vbs" "$tmp_synth_vbs" "$tmp_health_vbs" \
                 "$tmp_fetch_health_bat" "$tmp_harvest_bat" "$tmp_synth_bat" "$tmp_health_bat")
    promote_dst=("$vbs_fetch_health" "$vbs_harvest" "$vbs_synth" "$vbs_health" \
                 "$bat_fetch_health" "$bat_harvest" "$bat_synth" "$bat_health")
    for idx in "${!promote_dst[@]}"; do
        if [ -e "${promote_dst[$idx]}" ] && [ ! -f "${promote_dst[$idx]}" ]; then
            echo "ERR pipeline-cadence: ${promote_dst[$idx]} exists and is not a regular file — refusing to publish" >&2
            rm -f "${promote_src[@]}"
            exit 4
        fi
        if ! mv -f "${promote_src[$idx]}" "${promote_dst[$idx]}"; then
            echo "ERR pipeline-cadence: failed to publish runner to ${promote_dst[$idx]} — NO task armed" >&2
            rm -f "${promote_src[@]}"
            exit 4
        fi
    done

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
        # Roll back the tasks that DID register so
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
    if ! schtasks_create_xml "$TASK_FETCH_HEALTH" "$bat_fetch_health_win" "$sched_fetch_health" "$FETCH_HEALTH_TIME" "$err_file"; then
        echo "ERR pipeline-cadence: schtasks /create $TASK_FETCH_HEALTH failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        for name in "$TASK_HARVEST" "$TASK_SYNTH" "$TASK_HEALTH"; do
            if ! run_schtasks /delete /tn "$name" /f >/dev/null 2>&1; then
                echo "WARN: rollback of $name failed — run disarm" >&2
            fi
        done
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    rm -f "$err_file"

    cat <<EOF

================================================================
  PIPELINE CADENCE ARMED (HIMMEL-255 / HIMMEL-357 / HIMMEL-506 / HIMMEL-798 / HIMMEL-1383 / HIMMEL-1449)
  $TASK_FETCH_HEALTH  daily   $FETCH_HEALTH_TIME  [no LLM]  -> clip-source fetch probes
  $TASK_HARVEST  daily   $HARVEST_TIME  [model: $HARVEST_MODEL]  -> $DAILY_CHAIN
  $TASK_SYNTH    daily   $SYNTH_TIME    [model: $SYNTH_MODEL]    -> /synthesize-clips + /archive-clips
  $TASK_HEALTH   $HEALTH_CADENCE_LABEL   [model: $HEALTH_MODEL]   -> vault-lint (obsidian-triage:vault-lint)
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

CRON_RUNNER_FETCH_HEALTH="$BAT_DIR/pipeline-fetch-health.sh"
CRON_RUNNER_HARVEST="$BAT_DIR/pipeline-harvest.sh"
CRON_RUNNER_SYNTH="$BAT_DIR/pipeline-synthesize.sh"
CRON_RUNNER_HEALTH="$BAT_DIR/pipeline-health.sh"

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
    local name="$1" q_vault="$2" q_claude="$3" q_prompt="$4" q_log="$5" q_settings="$6" q_node_dir="${7:-}" q_model="${8:-}" flow="${9:-}" q_flow_lib="${10:-}" q_bank_lib="${11:-}" q_gate_lib="${12:-}"
    local q_task q_flow
    q_task=$(printf '%q' "$name")
    q_flow=$(printf '%q' "$flow")
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
    # The POSIX twins of the two .bat gates. Both live INSIDE the `{ } >> $log`
    # group, so each helper's stderr diagnostics land in the leg log while its
    # single verdict token is captured. `exit` from a brace group (not a
    # subshell) exits the runner, so a refused leg never reaches the claude
    # launch below.
    # Gate 1 (HIMMEL-2045): free filesystem precondition, asked first.
    if [ -n "$q_gate_lib" ]; then
        printf '    _gate=$(%s .) || _gate=\n' "$q_gate_lib"
        printf '    if [ "$_gate" = NONE ]; then\n'
        printf '        echo "[%s no-new-input]"\n' "$LEG_SKIPPED_MARKER"
        printf '        _sid=$(%s --append-start %s "" "" claude %s %s "$log" "$$" 2>/dev/null) || _sid=\n' "$q_flow_lib" "$q_flow" "$q_model" "$q_task"
        printf '        test "$_sid" != "" && %s --append-end %s "$_sid" "" 0 skipped 0 no-new-input >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow"
        printf '        exit 0\n'
        printf '    fi\n'
    fi
    # Gate 2 (HIMMEL-2044): bank preflight. Only SKIPPED-BANK refuses; the
    # helper's BANK-STALE / BANK-UNKNOWN verdicts are fail-open by design and
    # an empty capture means it could not run at all.
    if [ -n "$q_bank_lib" ]; then
        printf '    _bank=$(CADENCE_BANK_LEG=%s %s) || _bank=\n' "$q_flow" "$q_bank_lib"
        printf '    if [ "$_bank" = SKIPPED-BANK ]; then\n'
        printf '        echo "[%s bank-at-threshold]"\n' "$LEG_SKIPPED_MARKER"
        printf '        _sid=$(%s --append-start %s "" "" claude %s %s "$log" "$$" 2>/dev/null) || _sid=\n' "$q_flow_lib" "$q_flow" "$q_model" "$q_task"
        printf '        test "$_sid" != "" && %s --append-end %s "$_sid" "" 0 skipped 0 bank-at-threshold >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow"
        printf '        exit 0\n'
        printf '    fi\n'
    fi
    # HIMMEL-1152 retry/resume loop, the POSIX twin of the .bat goto loop. The
    # marker line is what --is-transient scans FORWARD from, so each attempt is
    # judged on its own output; each attempt lands its own start/end ledger
    # pair, the end row tagged attempt=N/MAX.
    printf '    _attempt=1\n'
    printf '    while :; do\n'
    printf '        echo "[%s $_attempt/%s]"\n' "$FLOW_RUN_ATTEMPT_MARKER" "$RETRY_MAX_ATTEMPTS"
    printf '        _flow_run_id=$(%s --append-start %s "" "" claude %s %s "$log" "$$" 2>/dev/null) || _flow_run_id=\n' "$q_flow_lib" "$q_flow" "$q_model" "$q_task"
    # HIMMEL-951: no bg-wait ceiling override here — CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
    # only affects --print mode, and cadence runners are interactive-shaped (HIMMEL-128).
    # --permission-mode is EXPLICIT (HIMMEL-2044) — see emit_bat's twin.
    printf '        _rc=0; %s --model %s --permission-mode %s --settings %s %s < /dev/null || _rc=$?\n' "$q_claude" "$q_model" "$CADENCE_PERMISSION_MODE" "$q_settings" "$q_prompt"
    # Fail-closed fallback (coderabbit #1762): classifier unavailable/silent ->
    # parked on rc 0, error otherwise -- never complete by default.
    printf '        _flow_outcome=$(%s --classify "$_rc" "$log" "" %s 2>/dev/null) || _flow_outcome=\n' "$q_flow_lib" "$LEG_DONE_MARKER"
    printf '        if [ "$_flow_outcome" = "" ]; then if [ "$_rc" = 0 ]; then _flow_outcome=parked; else _flow_outcome=error; fi; fi\n'
    printf '        test "$_flow_run_id" != "" && %s --append-end %s "$_flow_run_id" "" "$_rc" "$_flow_outcome" "" "attempt=$_attempt/%s" >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow" "$RETRY_MAX_ATTEMPTS"
    # Retry ONLY a non-zero exit whose own attempt log carries the transient
    # upstream signature, and only within the bound. A --is-transient that
    # cannot run answers non-zero, which breaks the loop — fail-closed.
    printf '        [ "$_rc" = 0 ] && break\n'
    printf '        [ "$_attempt" -ge %s ] && break\n' "$RETRY_MAX_ATTEMPTS"
    printf '        %s --is-transient "$_rc" "$log" || break\n' "$q_flow_lib"
    printf '        _delay=%s; [ "$_attempt" -ge 2 ] && _delay=%s\n' "$RETRY_BACKOFF_1" "$RETRY_BACKOFF_2"
    printf '        echo "[retry $_attempt/%s after transient upstream API error - sleeping ${_delay}s]"\n' "$((RETRY_MAX_ATTEMPTS - 1))"
    # Sleep seam (the CHECK_CI_SLEEP_CMD shape, HIMMEL-1953) so the hermetic
    # suite can fire a full three-attempt run without waiting four minutes.
    printf '        ${PIPELINE_CADENCE_SLEEP_CMD:-sleep} "$_delay"\n'
    printf '        _attempt=$((_attempt + 1))\n'
    printf '    done\n'
    printf '    echo "[exit rc=$_rc]"\n'
    # HIMMEL-2045 completion stamp — the POSIX twin; `complete` only, for the
    # reason emit_bat documents.
    if [ -n "$q_gate_lib" ]; then
        printf '    { [ "$_flow_outcome" = complete ] && %s --stamp .; } || true\n' "$q_gate_lib"
    fi
    printf '} >> "$log" 2>&1\n'
    # HIMMEL-1716: parked (zero rc, no marker) exits 3 so cron/the operator
    # sees a failure, mirroring the .bat runner.
    printf 'if [ "$_flow_outcome" = parked ] && [ "$_rc" = 0 ]; then exit 3; fi\n'
    printf 'exit "$_rc"\n'
}

# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh to expand at fire time
emit_fetch_health_runner() {
    local q_python="$1" q_script="$2" q_log="$3" q_arm_path="$4" q_env_file="$5" q_flow_lib="$6"
    local q_task q_flow
    q_task=$(printf '%q' "$TASK_FETCH_HEALTH")
    q_flow=$(printf '%q' "pipeline-fetch-health")
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by pipeline-cadence.sh arm (HIMMEL-1449)\n' "$TASK_FETCH_HEALTH"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Restore the arming shell's PATH so the probes' shelled-out CLIs (gallery-dl,
    # twitter, gh) resolve under cron's minimal PATH=/usr/bin:/bin, and source the
    # repo's gitignored .env (if present) so env-sourced credentials (Twitter/
    # Firecrawl) are available — mirrors fetch-health.py's load_repo_env. Both
    # lines flow through printf %s with pre-quoted q_ vars (SC2016-safe) (HIMMEL-1449 r2).
    printf 'PATH=%s; export PATH\n' "$q_arm_path"
    printf '[ -f %s ] && . %s\n' "$q_env_file" "$q_env_file"
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then mv -f "$log" "$log.prev" || exit 1; fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    # Flow-run ledger rows (HIMMEL-1724) — the POSIX twin of the .bat leg's
    # rows, so a cron-armed FetchHealth leg is equally visible to stall /
    # never-started detection. Outcome derived from the rc (no LLM, so no
    # truncation/parked state to classify); see emit_fetch_health_bat.
    printf '    _flow_run_id=$(%s --append-start %s "" "" python "" %s "$log" "$$" 2>/dev/null) || _flow_run_id=\n' "$q_flow_lib" "$q_flow" "$q_task"
    printf '    _rc=0; %s %s || _rc=$?\n' "$q_python" "$q_script"
    printf '    _flow_outcome=complete; [ "$_rc" = 0 ] || _flow_outcome=error\n'
    printf '    test "$_flow_run_id" != "" && %s --append-end %s "$_flow_run_id" "" "$_rc" "$_flow_outcome" "" "" >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow"
    printf '    echo "[exit rc=$_rc]"\n'
    printf '    exit "$_rc"\n'
    printf '} >> "$log" 2>&1\n'
}

cron_status() {
    cron_read
    echo "pipeline-cadence status:"
    local name log entry sched
    for name in "$TASK_FETCH_HEALTH" "$TASK_HARVEST" "$TASK_SYNTH" "$TASK_HEALTH"; do
        case "$name" in
            "$TASK_FETCH_HEALTH") log="$BAT_DIR/pipeline-fetch-health.log" ;;
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
            rm -f "$CRON_RUNNER_FETCH_HEALTH" "$CRON_RUNNER_HARVEST" "$CRON_RUNNER_SYNTH" "$CRON_RUNNER_HEALTH" "$SETTINGS_FRAGMENT"
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
    rm -f "$CRON_RUNNER_FETCH_HEALTH" "$CRON_RUNNER_HARVEST" "$CRON_RUNNER_SYNTH" "$CRON_RUNNER_HEALTH" "$SETTINGS_FRAGMENT"
    echo "pipeline-cadence: cadence disarmed"
}

cron_arm() {
    validate_arm_inputs

    # Resolve claude to an absolute path so the cron entry doesn't
    # depend on cron's minimal PATH. Also capture node's directory so
    # the runner can prepend it to PATH — nvm-managed node won't be in
    # cron's minimal PATH even when claude_bin is an absolute shim (#317).
    local claude_bin node_dir python_bin
    if ! claude_bin=$(command -v claude 2>/dev/null); then
        echo "ERR pipeline-cadence: 'claude' not on PATH at arm time" >&2
        exit 2
    fi
    if python_bin=$(command -v python3 2>/dev/null); then
        :
    elif python_bin=$(command -v python 2>/dev/null); then
        :
    else
        echo "ERR pipeline-cadence: python3/python not on PATH at arm time (required for fetch-health)" >&2
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

    local q_vault q_claude q_python q_fetch_script q_node_dir q_flow_lib q_bank_lib q_gate_lib q_harvest_prompt q_synth_prompt q_health_prompt q_log_fetch_health q_log_harvest q_log_synth q_log_health q_harvest_model q_synth_model q_health_model
    q_vault=$(printf '%q' "$VAULT")
    q_claude=$(printf '%q' "$claude_bin")
    q_python=$(printf '%q' "$python_bin")
    q_fetch_script=$(printf '%q' "$HIMMEL_ROOT/scripts/luna/fetch-health.py")
    q_flow_lib=$(printf '%q' "$HIMMEL_ROOT/scripts/lib/flow-run-ledger.sh")
    q_bank_lib=$(printf '%q' "$BANK_PREFLIGHT")
    q_gate_lib=$(printf '%q' "$SYNTH_GATE")
    q_node_dir=$([ -n "$node_dir" ] && printf '%q' "$node_dir" || printf '')
    q_harvest_prompt=$(printf '%q' "$HARVEST_PROMPT")
    q_synth_prompt=$(printf '%q' "$SYNTH_PROMPT")
    q_health_prompt=$(printf '%q' "$HEALTH_PROMPT")
    q_log_fetch_health=$(printf '%q' "$BAT_DIR/pipeline-fetch-health.log")
    q_log_harvest=$(printf '%q' "$BAT_DIR/pipeline-harvest.log")
    q_log_synth=$(printf '%q' "$BAT_DIR/pipeline-synthesize.log")
    q_log_health=$(printf '%q' "$BAT_DIR/pipeline-health.log")
    q_harvest_model=$(printf '%q' "$HARVEST_MODEL")
    q_synth_model=$(printf '%q' "$SYNTH_MODEL")
    q_health_model=$(printf '%q' "$HEALTH_MODEL")
    # Settings fragment (HIMMEL-575): the `claude --settings` target, shared by
    # the three Claude runners. The hook path inside the fragment is the POSIX absolute
    # path (JSON-safe — no backslashes — and bash-readable).
    local q_settings
    q_settings=$(printf '%q' "$SETTINGS_FRAGMENT")
    # Capture the arming shell's PATH and the repo .env path for the fetch-health
    # runner: under real cron (PATH=/usr/bin:/bin, no user env) the probes'
    # shelled-out CLIs and env-sourced credentials go missing. PATH is non-secret
    # (embedded quoted); .env is sourced at fire time, never embedded — secrets
    # stay in the gitignored file (HIMMEL-1449 r2).
    local q_arm_path q_env_file
    q_arm_path=$(printf '%q' "$PATH")
    q_env_file=$(printf '%q' "$HIMMEL_ROOT/.env")
    [ -r "$AUTO_APPROVE_HOOK" ] || \
        echo "WARN pipeline-cadence: auto-approve hook not readable at $AUTO_APPROVE_HOOK (cadence runs may stall on compound-bash prompts)" >&2
    # HIMMEL-1682 RETASK (CodeRabbit Major, judge-verified): see the matching
    # comment at the cmd_arm call site above — the two S2a/S2b cadence-scoped
    # hooks need the same readability check as AUTO_APPROVE_HOOK.
    local hooks_dir_check="${AUTO_APPROVE_HOOK%/*}"
    [ -r "$hooks_dir_check/cadence-deny-background.sh" ] || \
        echo "WARN pipeline-cadence: deny-background hook not readable at $hooks_dir_check/cadence-deny-background.sh (background-command denies will be silently absent)" >&2
    [ -r "$hooks_dir_check/cadence-approve-engines.sh" ] || \
        echo "WARN pipeline-cadence: approve-engines hook not readable at $hooks_dir_check/cadence-approve-engines.sh (engine calls will prompt or stall)" >&2
    [ -r "$hooks_dir_check/cadence-deny-powershell.sh" ] || \
        echo "WARN pipeline-cadence: deny-powershell hook not readable at $hooks_dir_check/cadence-deny-powershell.sh (PowerShell-tool calls will bypass every cadence guardrail)" >&2

    local fetch_health_hh fetch_health_mm harvest_hh harvest_mm synth_hh synth_mm health_hh health_mm
    fetch_health_hh="${FETCH_HEALTH_TIME%:*}"; fetch_health_mm="${FETCH_HEALTH_TIME#*:}"
    harvest_hh="${HARVEST_TIME%:*}"; harvest_mm="${HARVEST_TIME#*:}"
    synth_hh="${SYNTH_TIME%:*}"; synth_mm="${SYNTH_TIME#*:}"
    health_hh="${HEALTH_TIME%:*}"; health_mm="${HEALTH_TIME#*:}"
    local entry_fetch_health entry_harvest entry_synth entry_health
    entry_fetch_health="$fetch_health_mm $fetch_health_hh * * * $(cron_escape "$CRON_RUNNER_FETCH_HEALTH") # $TASK_FETCH_HEALTH"
    entry_harvest="$harvest_mm $harvest_hh * * * $(cron_escape "$CRON_RUNNER_HARVEST") # $TASK_HARVEST"
    entry_synth="$synth_mm $synth_hh * * * $(cron_escape "$CRON_RUNNER_SYNTH") # $TASK_SYNTH"
    local health_dow='*'
    [ "$HEALTH_DAY" = DAILY ] || health_dow=$(cron_dow "$HEALTH_DAY")
    entry_health="$health_mm $health_hh * * $health_dow $(cron_escape "$CRON_RUNNER_HEALTH") # $TASK_HEALTH"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: would write $SETTINGS_FRAGMENT:"
        emit_settings_fragment "$AUTO_APPROVE_HOOK" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_FETCH_HEALTH:"
        emit_fetch_health_runner "$q_python" "$q_fetch_script" "$q_log_fetch_health" "$q_arm_path" "$q_env_file" "$q_flow_lib" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_HARVEST:"
        emit_runner "$TASK_HARVEST" "$q_vault" "$q_claude" "$q_harvest_prompt" "$q_log_harvest" "$q_settings" "$q_node_dir" "$q_harvest_model" "pipeline-harvest" "$q_flow_lib" "$q_bank_lib" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_SYNTH:"
        emit_runner "$TASK_SYNTH" "$q_vault" "$q_claude" "$q_synth_prompt" "$q_log_synth" "$q_settings" "$q_node_dir" "$q_synth_model" "pipeline-synthesize" "$q_flow_lib" "$q_bank_lib" "$q_gate_lib" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_HEALTH:"
        emit_runner "$TASK_HEALTH" "$q_vault" "$q_claude" "$q_health_prompt" "$q_log_health" "$q_settings" "$q_node_dir" "$q_health_model" "pipeline-health" "$q_flow_lib" "$q_bank_lib" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would add crontab entries:"
        echo "    $entry_fetch_health"
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
    local tmp_fetch_health="$CRON_RUNNER_FETCH_HEALTH.tmp.$$" tmp_harvest="$CRON_RUNNER_HARVEST.tmp.$$" tmp_synth="$CRON_RUNNER_SYNTH.tmp.$$" tmp_health="$CRON_RUNNER_HEALTH.tmp.$$"
    local tmp_settings="$SETTINGS_FRAGMENT.tmp.$$"
    emit_settings_fragment "$AUTO_APPROVE_HOOK" > "$tmp_settings"
    emit_fetch_health_runner "$q_python" "$q_fetch_script" "$q_log_fetch_health" "$q_arm_path" "$q_env_file" "$q_flow_lib" > "$tmp_fetch_health"
    emit_runner "$TASK_HARVEST" "$q_vault" "$q_claude" "$q_harvest_prompt" "$q_log_harvest" "$q_settings" "$q_node_dir" "$q_harvest_model" "pipeline-harvest" "$q_flow_lib" "$q_bank_lib" > "$tmp_harvest"
    emit_runner "$TASK_SYNTH"  "$q_vault" "$q_claude" "$q_synth_prompt"  "$q_log_synth"  "$q_settings" "$q_node_dir" "$q_synth_model"   "pipeline-synthesize" "$q_flow_lib" "$q_bank_lib" "$q_gate_lib" > "$tmp_synth"
    emit_runner "$TASK_HEALTH" "$q_vault" "$q_claude" "$q_health_prompt" "$q_log_health" "$q_settings" "$q_node_dir" "$q_health_model"  "pipeline-health" "$q_flow_lib" "$q_bank_lib" > "$tmp_health"
    chmod +x "$tmp_fetch_health" "$tmp_harvest" "$tmp_synth" "$tmp_health"

    # Single atomic rewrite: everything that isn't ours, then all four
    # cadence entries.
    local newtab
    newtab=$(mktemp -t pipeline-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" || true
        fi
        printf '%s\n' "$entry_fetch_health" "$entry_harvest" "$entry_synth" "$entry_health"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        # Pre-existing runners were never touched; sweep the staged
        # new-config ones (runners + fragment) so no half-state survives.
        rm -f "$tmp_fetch_health" "$tmp_harvest" "$tmp_synth" "$tmp_health" "$tmp_settings"
        echo "    existing runner files left untouched" >&2
        exit 4
    fi
    mv -f "$tmp_fetch_health" "$CRON_RUNNER_FETCH_HEALTH"
    mv -f "$tmp_harvest" "$CRON_RUNNER_HARVEST"
    mv -f "$tmp_synth"  "$CRON_RUNNER_SYNTH"
    mv -f "$tmp_health" "$CRON_RUNNER_HEALTH"
    mv -f "$tmp_settings" "$SETTINGS_FRAGMENT"

    cat <<EOF

================================================================
  PIPELINE CADENCE ARMED (HIMMEL-255 / HIMMEL-265 cron / HIMMEL-357 / HIMMEL-506 / HIMMEL-798 / HIMMEL-1383 / HIMMEL-1449)
  $TASK_FETCH_HEALTH  daily   $FETCH_HEALTH_TIME  [no LLM]  -> clip-source fetch probes
  $TASK_HARVEST  daily   $HARVEST_TIME  [model: $HARVEST_MODEL]  -> $DAILY_CHAIN
  $TASK_SYNTH    daily   $SYNTH_TIME    [model: $SYNTH_MODEL]    -> /synthesize-clips + /archive-clips
  $TASK_HEALTH   $HEALTH_CADENCE_LABEL   [model: $HEALTH_MODEL]   -> vault-lint (obsidian-triage:vault-lint)
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
