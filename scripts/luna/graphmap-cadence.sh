#!/usr/bin/env bash
# graphmap-cadence.sh — arm/status/disarm the recurring graphify curated-map
# cadence (HIMMEL-829, Option B).
#
# WHY: graphify graphs are point-in-time snapshots that drift as the corpus
# changes. scripts/graphify/refresh-graph-map.sh (HIMMEL-825) is the schedulable
# RUNNER that does a fence-safe incremental refresh + republishes a curated MOC
# for ONE corpus. What was missing is the scheduler/arm layer. This is that
# layer: a SEPARATE OS-scheduler cadence (Option B) that fires
# refresh-graph-map.sh per corpus, daily, off-peak — bounding graph drift with a
# cheap incremental (`graphify --update` re-extracts only changed files) instead
# of an expensive full re-sync.
#
# DESIGN DIFFERENCE from the sibling pipeline-cadence.sh: pipeline-cadence fires
# interactive `claude "<prompt>" < NUL` bounded sessions (each pipeline task = a
# claude session, wired with a --settings auto-approve fragment). THIS scheduler
# fires a DETERMINISTIC SCRIPT directly — `bash <himmel>/scripts/graphify/
# refresh-graph-map.sh <args>` — so it has NO claude, NO NUL-stdin, NO settings
# fragment, NO auto-approve hook, and NO claude-billing concern (HIMMEL-128 does
# not apply). That keeps pipeline-cadence's "every task = a claude session"
# invariant clean, and makes this scheduler strictly simpler than its sibling.
#
# FENCE SAFETY: refresh-graph-map.sh never extracts on a live vault — it copies
# the corpus to a PID-owned scratchpad, carries the `.graphify-corpus` marker,
# and only publishes the curated MOC back into the vault's 60-Maps/. That
# discipline lives in the runner; this scheduler just fires it.
#
# OPERATOR FLIP: arming this cadence commits to a daily graphify extraction run
# per corpus on the claude (claude-cli) backend (HIMMEL-1049 — no cloud API key;
# the fence maps claude -> anthropic by effective endpoint). It never auto-arms —
# `arm` registers tasks only when explicitly invoked, so the operator decides.
#
# Two daily tasks are registered:
#   HIMMEL-GraphMap-Luna    daily (default 13:00 local)
#       bash <himmel>/scripts/graphify/refresh-graph-map.sh --name luna ...
#   HIMMEL-GraphMap-Himmel  daily (default 13:20 local)
#       bash <himmel>/scripts/graphify/refresh-graph-map.sh --name himmel ...
#
# WHY 13:00 / 13:20 LOCAL (and staggered 20 min apart): a quiet mid-day default;
# the 20-minute stagger REDUCES THE CHANCE of the two extraction jobs overlapping
# (it cannot guarantee no overlap — luna and himmel are different corpora / out
# dirs, so the per-out-dir promote lock does not serialize them; a slow job could
# still run into the next). The claude-cli backend has no provider off-peak
# window, so these times are not cost-driven. The backend is fixed as BACKEND in
# this script — not a flag; edit + re-arm to change it.
#
# Usage:
#   bash scripts/luna/graphmap-cadence.sh arm [--luna-time HH:MM]
#       [--himmel-time HH:MM] [--vault PATH] [--force] [--dry-run]
#   bash scripts/luna/graphmap-cadence.sh status
#   bash scripts/luna/graphmap-cadence.sh disarm
#
# Test seams (used by test-graphmap-cadence.sh):
#   GRAPHMAP_SCHTASKS  — command invoked instead of `schtasks` (Windows)
#   GRAPHMAP_CRONTAB   — command invoked instead of `crontab` (POSIX)
#   GRAPHMAP_BAT_DIR   — where the persistent runners (.bat/.sh) live
#
# Exit codes (mirrors pipeline-cadence.sh):
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error
#   2  env unusable (no schtasks/crontab; unknown platform; runner missing;
#      query tool errored)
#   3  dedup block — HIMMEL-GraphMap-* task(s) already armed; use --force
#   4  scheduler invocation failed (/create, /delete, crontab rewrite,
#      path conversion)
set -euo pipefail

TASK_PREFIX="HIMMEL-GraphMap-"
TASK_LUNA="${TASK_PREFIX}Luna"
TASK_HIMMEL="${TASK_PREFIX}Himmel"
SCHTASKS_BIN="${GRAPHMAP_SCHTASKS:-schtasks}"
CRONTAB_BIN="${GRAPHMAP_CRONTAB:-crontab}"

# Cross-platform user-home resolution (mirrors pipeline-cadence's
# resolve_user_home, HIMMEL-645). On Windows Git-Bash $HOME can be the MSYS home
# (/home/<user>) while Claude Code's config (~/.claude) lives under the Windows
# user profile, so prefer USERPROFILE via cygpath BEFORE $HOME. POSIX hosts have
# USERPROFILE unset and fall straight through to $HOME. /tmp is the last-resort
# floor when both are unset.
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home (.bat on Windows, .sh on POSIX) — NOT mktemp: these
# tasks recur daily and %TEMP% / /tmp are subject to cleanup sweeps that would
# silently kill the cadence (same rationale as pipeline-cadence's BAT_DIR).
BAT_DIR="${GRAPHMAP_BAT_DIR:-$(resolve_user_home)/.claude/graphmap-cadence}"

# Resolve the himmel root from this script's own location (scripts/luna/..),
# so the runner fires the shipped refresh-graph-map.sh by absolute path.
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
REFRESH_SCRIPT="$HIMMEL_ROOT/scripts/graphify/refresh-graph-map.sh"

# Runner-format version stamp (HIMMEL-588): emit_bat / emit_runner stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner so a stale-format armed cadence
# is detectable. Reused from the shared lib (same as pipeline-cadence).
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"

# Off-peak defaults (see the header for the 13:00 / 13:20 local rationale).
LUNA_TIME="13:00"
HIMMEL_TIME="13:20"

# Default vault resolution (cross-platform; mirrors pipeline-cadence). Honors
# LUNA_VAULT_PATH first, else <home>/Documents/luna. Explicit --vault overrides.
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

# Fixed per-corpus map identity (titles/slugs/tags). ASCII-only: the .bat is
# parsed by cmd.exe under the OEM codepage where UTF-8 punctuation mojibakes.
LUNA_TITLE="Graphify Luna Map"
LUNA_SLUG="graphify-luna-map"
LUNA_TAG="luna"
HIMMEL_TITLE="Graphify Himmel Map"
HIMMEL_SLUG="graphify-himmel-map"
HIMMEL_TAG="himmel"
# HIMMEL-1049 (himmel off deepseek): the scheduled luna + himmel refresh runs on
# the claude-cli extraction backend — graphify's `claude-cli` routes through the
# locally-installed `claude` CLI (no extra API key), unlike `claude` which is the
# pay-as-you-go Anthropic API path (ANTHROPIC_API_KEY). The deepseek pipe was
# unreliable. BILLING CAVEAT: claude-cli rides the operator's Pro/Max
# subscription only while NO Anthropic API credential is in the environment — a
# set ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN takes precedence in the `claude`
# CLI and switches the run to pay-as-you-go. The fence maps claude/claude-cli ->
# a provider by their effective endpoint (see graphify-fence.sh); already-armed
# tasks keep their baked-in --backend until re-armed with this default.
BACKEND="claude-cli"

usage() {
    cat <<'EOF'
Usage: graphmap-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring graphify curated-map cadence
(HIMMEL-829): a daily fence-safe incremental refresh + curated-MOC
republish for the luna and himmel corpora, fired as a DETERMINISTIC
script (bash refresh-graph-map.sh ...) — NO claude session.

Subcommands:
  arm      Register both daily tasks. Dedup-guarded: refuses (rc=3) if
           any HIMMEL-GraphMap-* task already exists; --force replaces.
  status   Show which cadence tasks are armed (+ next run time).
  disarm   Remove both tasks (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --luna-time <HH:MM>    Daily luna-map time, 24h local   (default 13:00)
  --himmel-time <HH:MM>  Daily himmel-map time, 24h local (default 13:20;
                         staggered 20min after luna to reduce the chance of
                         the two extraction jobs overlapping — different
                         corpora/out-dirs, so no shared lock serializes them)
  --vault <PATH>         Luna vault root (default: $LUNA_VAULT_PATH if set,
                         else <user-profile>/Documents/luna). The vault's
                         60-Maps/ is where the curated MOCs are published.
  --force                Replace existing HIMMEL-GraphMap-* tasks
  --dry-run              Print what would happen, touch nothing
                         (honored by arm AND disarm)

WHY 13:00 / 13:20 local: a quiet mid-day default, staggered 20min to reduce
the chance of the two extraction jobs overlapping (not a guarantee — they use
different corpora/out-dirs, so no shared lock serializes them). The claude-cli
backend has no provider off-peak window, so the times are not cost-driven.
The extraction backend is NOT a flag here — it is fixed as BACKEND in this
script (claude-cli); edit it there and re-arm to change it.
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR graphmap-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR graphmap-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --luna-time)     LUNA_TIME="${2:-}"; shift 2 ;;
        --luna-time=*)   LUNA_TIME="${1#--luna-time=}"; shift ;;
        --himmel-time)   HIMMEL_TIME="${2:-}"; shift 2 ;;
        --himmel-time=*) HIMMEL_TIME="${1#--himmel-time=}"; shift ;;
        --vault)         VAULT="${2:-}"; shift 2 ;;
        --vault=*)       VAULT="${1#--vault=}"; shift ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERR graphmap-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Platform detect (same matrix as pipeline-cadence.sh).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)                           PLATFORM=unknown ;;
esac
case "$PLATFORM" in
    windows)
        command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
            echo "ERR graphmap-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
            exit 2
        }
        ;;
    linux|macos)
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR graphmap-cadence: '$CRONTAB_BIN' not on PATH (required on $PLATFORM)" >&2
            exit 2
        }
        ;;
    *)
        echo "ERR graphmap-cadence: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Windows (schtasks), Linux/macOS (crontab)" >&2
        exit 2
        ;;
esac

# MSYS_NO_PATHCONV=1 per call: without it gitbash mangles /query, /create etc.
# into Windows-rooted paths before schtasks sees them.
run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# Escape CMD metacharacters for values interpolated into the .bat (same order as
# pipeline-cadence's cmd_escape) so a path containing legal-but-hostile chars
# (% & ^ are valid in Windows dirnames) can't inject commands at fire time.
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

# Dedup listing: every scheduled task named HIMMEL-GraphMap-*. Fail-CLOSED if
# the query tool itself errors (mirrors pipeline-cadence list_existing).
list_existing() {
    local err_file out rc
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    set +e
    out=$(run_schtasks /query /fo CSV /nh 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        # Fail-CLOSED: any nonzero rc is fatal UNLESS it matches the one trusted
        # empty-scheduler signature — rc=1 with EMPTY stderr (schtasks returns
        # rc=1 on a completely empty scheduler; real errors carry stderr).
        if [ "$rc" -ne 1 ] || [ -s "$err_file" ]; then
            echo "ERR graphmap-cadence: schtasks /query failed (rc=$rc) — refusing to treat as empty scheduler:" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
    # shellcheck disable=SC1003  # strips both quote and the literal backslash schtasks prefixes task names with
    printf '%s\n' "$out" \
        | grep -o '"\\\?HIMMEL-GraphMap-[^"]*"' 2>/dev/null \
        | tr -d '"\\' \
        | sort -u || true
}

delete_task() {
    local name="$1" err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    if run_schtasks /delete /tn "$name" /f >/dev/null 2>"$err_file"; then
        rm -f "$err_file"
        echo "graphmap-cadence: deleted scheduled task: $name"
    else
        echo "ERR graphmap-cadence: schtasks /delete $name failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
}

# Known not-found stderr signatures for `/query /tn <name>` (mirrors
# pipeline-cadence). Real schtasks always emits one of these on a missing task,
# so rc=1 WITHOUT a match (silent rc=1 included) is a real query failure.
NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

# query_one <name>: rc 0 = armed (QUERY_OUT set), rc 1 = trusted not-found,
# rc 2 = query failed (stderr already printed).
QUERY_OUT=""
query_one() {
    local name="$1" rc err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    set +e
    QUERY_OUT=$(run_schtasks /query /tn "$name" /fo LIST 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        rm -f "$err_file"
        return 0
    fi
    if [ "$rc" -eq 1 ] && grep -qiE "$NOT_FOUND_RE" "$err_file"; then
        rm -f "$err_file"
        return 1
    fi
    echo "ERR graphmap-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
    cat "$err_file" >&2
    echo "    If this is a localized 'task does not exist' message, the task may simply" >&2
    echo "    not be armed. Verify / remove manually:" >&2
    echo "        schtasks /query /tn $name" >&2
    echo "        schtasks /delete /tn $name /f" >&2
    rm -f "$err_file"
    return 2
}

task_summary() {
    case "$1" in
        "$TASK_LUNA")   printf ' -> refresh-graph-map luna (daily)' ;;
        "$TASK_HIMMEL") printf ' -> refresh-graph-map himmel (daily)' ;;
    esac
}

status_one() {
    local name="$1" next qrc=0
    query_one "$name" || qrc=$?
    case "$qrc" in
        0)
            next=$(printf '%s\n' "$QUERY_OUT" | grep -i 'Next Run Time' | head -1 \
                | sed 's/^[^:]*:[[:space:]]*//' || true)
            echo "ARMED      $name${next:+ (next run: $next)}$(task_summary "$name")"
            ;;
        1)  echo "not armed  $name$(task_summary "$name")" ;;
        *)
            echo "QUERY ERR  $name (see stderr above)"
            return 2
            ;;
    esac
}

# Surface fire-time evidence: each runner writes its output to a .log next to the
# runner (rotated per fire), so "armed but never succeeding" is visible here.
status_log() {
    local log="$1" mtime last
    if [ -f "$log" ]; then
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
    local status_rc=0
    echo "graphmap-cadence status:"
    status_one "$TASK_LUNA" || status_rc=2
    status_log "$BAT_DIR/graphmap-luna.log"
    status_one "$TASK_HIMMEL" || status_rc=2
    status_log "$BAT_DIR/graphmap-himmel.log"
    return "$status_rc"
}

cmd_disarm() {
    local name found=0 qrc
    for name in "$TASK_LUNA" "$TASK_HIMMEL"; do
        qrc=0
        query_one "$name" || qrc=$?
        case "$qrc" in
            0)
                found=1
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "DRY graphmap-cadence: would delete $name"
                else
                    delete_task "$name"
                fi
                ;;
            1)  : ;;
            *)  exit 2 ;;
        esac
    done
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -f "$BAT_DIR/graphmap-luna.bat" "$BAT_DIR/graphmap-himmel.bat"
    fi
    if [ "$found" -eq 0 ]; then
        echo "graphmap-cadence: nothing armed — disarm is a no-op"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY graphmap-cadence: no changes made"
    else
        echo "graphmap-cadence: cadence disarmed"
    fi
}

# Build the argv the .bat hands to bash: the refresh-graph-map.sh path + its
# flags. All interpolated path values are already cmd-escaped by the caller;
# name/slug/tag/backend are fixed ASCII literals.
bat_payload() {
    local script_esc="$1" name="$2" corpus_esc="$3" maps_esc="$4" title="$5" slug="$6" tag="$7"
    printf '"%s" --name %s --corpus-root "%s" --maps-dir "%s" --title "%s" --slug %s --backend %s --corpus-tag %s' \
        "$script_esc" "$name" "$corpus_esc" "$maps_esc" "$title" "$slug" "$BACKEND" "$tag"
}

# Emit the .bat body for one cadence task: stamp the format version, rotate the
# run log (one prior run kept as .log.prev), stamp the fire time, cd into the
# himmel root (a failing cd aborts + is logged, instead of firing from the wrong
# CWD), then fire bash + refresh-graph-map.sh with its stdout+stderr captured to
# the rotating log. NO claude, NO stdin redirect: the runner IS the payload.
emit_bat() {
    local himmel_win_esc="$1" bash_win="$2" payload="$3" log_win_esc="$4"
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_win_esc" "$log_win_esc" "$log_win_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_win_esc"
    printf 'cd /d "%s" >> "%s" 2>&1 || exit /b 1\r\n' "$himmel_win_esc" "$log_win_esc"
    printf '%s >> "%s" 2>&1\r\n' "$payload" "$log_win_esc"
}

# --- schtasks task XML (StartWhenAvailable) --------------------------------
#
# schtasks /create has no flag for StartWhenAvailable ("run as soon as possible
# after a missed scheduled start"), so a daily 13:00 run is SILENTLY SKIPPED if
# the machine was off/asleep at 13:00. The only CLI route is `schtasks /create
# /xml`; we keep the per-task .bat as the Exec Command and wrap it in XML that
# carries StartWhenAvailable=true (same approach as pipeline-cadence, HIMMEL-362).

# Escape the three XML-significant characters for element-body text (the Exec
# <Command> path — a BAT_DIR path may legally contain `&`). `&` first so the `&`
# in the &lt;/&gt; entities isn't re-escaped. sed (not bash ${//}) for a
# version-independent literal-ampersand replacement.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

schedule_daily_xml() {
    printf '      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>\n      </ScheduleByDay>'
}

# Emit one task XML: a CalendarTrigger at the given local time, daily schedule,
# StartWhenAvailable=true, and the .bat runner as the Exec Command. StartBoundary
# date is a fixed past sentinel — the schedule fragment (not the date) governs
# firing. Declared UTF-16 (what schtasks /create /xml expects) but the bytes are
# plain ASCII — keep it ASCII-only (a non-ASCII byte would need a real UTF-16LE
# +BOM file; declaring UTF-8 is rejected on Win11).
emit_task_xml() {
    local command_raw="$1" start_time="$2" schedule_xml="$3" command
    command=$(xml_escape "$command_raw")
    cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>himmel graphmap-cadence (HIMMEL-829)</Description>
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

# Create one task from an XML definition (so StartWhenAvailable applies). Mirrors
# pipeline-cadence's schtasks_create_xml: self-contained error handling, returns
# the schtasks rc so callers keep the failure/rollback flow.
schtasks_create_xml() {
    local name="$1" schedule_xml="$2" start_time="$3" bat_win="$4" err_file="$5"
    local xml_file xml_win rc
    if ! xml_file=$(mktemp -t graphmap-cadence.xml.XXXXXX 2>"$err_file"); then
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

# Input validation shared by the schtasks and cron arm paths.
validate_arm_inputs() {
    if ! [[ "$LUNA_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR graphmap-cadence: --luna-time must be HH:MM (24h), got: $LUNA_TIME" >&2
        exit 1
    fi
    if ! [[ "$HIMMEL_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR graphmap-cadence: --himmel-time must be HH:MM (24h), got: $HIMMEL_TIME" >&2
        exit 1
    fi
    if [ ! -d "$VAULT" ]; then
        echo "ERR graphmap-cadence: --vault is not a directory: $VAULT" >&2
        exit 1
    fi
    if [ ! -f "$REFRESH_SCRIPT" ]; then
        echo "ERR graphmap-cadence: refresh-graph-map.sh not found at $REFRESH_SCRIPT" >&2
        exit 2
    fi
}

cmd_arm() {
    validate_arm_inputs

    # Resolve bash to an absolute Windows path so the .bat invokes the Git-Bash
    # interpreter directly — NOT the bare `bash` that resolves to the WSL
    # System32 stub in a fresh cmd.exe.
    local bash_posix bash_win
    if ! bash_posix=$(command -v bash 2>/dev/null); then
        echo "ERR graphmap-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR graphmap-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }
    if ! bash_win=$(cygpath -w "$bash_posix" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed for bash path: $bash_win" >&2
        exit 4
    fi

    # bash consumes these paths (POSIX/mixed C:/ form via cygpath -m, which
    # Git-Bash reads); the himmel cd target is a Windows path.
    local script_mixed vault_mixed maps_mixed himmel_mixed himmel_win
    if ! script_mixed=$(cygpath -m "$REFRESH_SCRIPT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for refresh script: $script_mixed" >&2
        exit 4
    fi
    if ! vault_mixed=$(cygpath -m "$VAULT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for vault path: $vault_mixed" >&2
        exit 4
    fi
    if ! maps_mixed=$(cygpath -m "$VAULT/60-Maps" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for maps dir: $maps_mixed" >&2
        exit 4
    fi
    if ! himmel_mixed=$(cygpath -m "$HIMMEL_ROOT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -m failed for himmel root: $himmel_mixed" >&2
        exit 4
    fi
    if ! himmel_win=$(cygpath -w "$HIMMEL_ROOT" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed for himmel root: $himmel_win" >&2
        exit 4
    fi

    # Dedup guard — never double-register the cadence.
    local existing
    existing=$(list_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "graphmap-cadence: --force set; replacing existing task(s):" >&2
            local marker
            while IFS= read -r marker; do
                [ -z "$marker" ] && continue
                echo "  $marker" >&2
                if [ "$DRY_RUN" -eq 0 ]; then
                    delete_task "$marker"
                else
                    echo "DRY graphmap-cadence: would delete $marker"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR graphmap-cadence: HIMMEL-GraphMap-* task(s) already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/graphmap-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    # cmd-escape the path values interpolated into each .bat payload.
    local script_esc vault_esc maps_esc himmel_esc himmel_win_esc
    script_esc=$(cmd_escape "$script_mixed")
    vault_esc=$(cmd_escape "$vault_mixed")
    maps_esc=$(cmd_escape "$maps_mixed")
    himmel_esc=$(cmd_escape "$himmel_mixed")
    himmel_win_esc=$(cmd_escape "$himmel_win")

    # Per-corpus payloads. NOTE the asymmetric --corpus-root: the luna map
    # extracts the VAULT ($vault_esc); the himmel map extracts the HIMMEL REPO
    # ($himmel_esc, so its derived graphify-out stays repo-local + gitignored) —
    # but BOTH publish their curated MOC into the luna vault's 60-Maps ($maps_esc).
    # The luna vault is the single home for every map; the cross-corpus mix here
    # is intentional, not a copy-paste bug (HIMMEL-829 wiring decision).
    local payload_luna payload_himmel
    payload_luna=$(bat_payload "$script_esc" luna "$vault_esc" "$maps_esc" "$LUNA_TITLE" "$LUNA_SLUG" "$LUNA_TAG")
    payload_himmel=$(bat_payload "$script_esc" himmel "$himmel_esc" "$maps_esc" "$HIMMEL_TITLE" "$HIMMEL_SLUG" "$HIMMEL_TAG")
    # Both .bats get the bash exe prepended; assemble the full exec line.
    payload_luna="\"$bash_win\" $payload_luna"
    payload_himmel="\"$bash_win\" $payload_himmel"

    local bat_luna="$BAT_DIR/graphmap-luna.bat"
    local bat_himmel="$BAT_DIR/graphmap-himmel.bat"

    # Fire-time run logs live next to the .bats (cmd-escaped for the `>>` target).
    local bat_dir_win log_luna_esc log_himmel_esc
    if ! bat_dir_win=$(cygpath -w "$BAT_DIR" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed for bat dir: $bat_dir_win" >&2
        exit 4
    fi
    log_luna_esc=$(cmd_escape "$bat_dir_win\\graphmap-luna.log")
    log_himmel_esc=$(cmd_escape "$bat_dir_win\\graphmap-himmel.log")

    # The .bat runner is the task's Exec Command. cygpath -w is a pure string
    # transform (the .bat need not exist yet), so resolve the win paths before
    # the dry-run preview too.
    local bat_luna_win bat_himmel_win
    if ! bat_luna_win=$(cygpath -w "$bat_luna" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed: $bat_luna_win" >&2
        exit 4
    fi
    if ! bat_himmel_win=$(cygpath -w "$bat_himmel" 2>&1); then
        echo "ERR graphmap-cadence: cygpath -w failed: $bat_himmel_win" >&2
        exit 4
    fi

    local sched
    sched=$(schedule_daily_xml)

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY graphmap-cadence: would write $bat_luna:"
        emit_bat "$himmel_win_esc" "$bash_win" "$payload_luna" "$log_luna_esc" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would write $bat_himmel:"
        emit_bat "$himmel_win_esc" "$bash_win" "$payload_himmel" "$log_himmel_esc" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would schtasks /create /tn $TASK_LUNA /xml <daily $LUNA_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_luna_win" "$LUNA_TIME" "$sched" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would schtasks /create /tn $TASK_HIMMEL /xml <daily $HIMMEL_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_himmel_win" "$HIMMEL_TIME" "$sched" | sed 's/^/    /'
        echo "graphmap-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    emit_bat "$himmel_win_esc" "$bash_win" "$payload_luna" "$log_luna_esc" > "$bat_luna"
    emit_bat "$himmel_win_esc" "$bash_win" "$payload_himmel" "$log_himmel_esc" > "$bat_himmel"

    local err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    if ! schtasks_create_xml "$TASK_LUNA" "$sched" "$LUNA_TIME" "$bat_luna_win" "$err_file"; then
        echo "ERR graphmap-cadence: schtasks /create $TASK_LUNA failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    if ! schtasks_create_xml "$TASK_HIMMEL" "$sched" "$HIMMEL_TIME" "$bat_himmel_win" "$err_file"; then
        echo "ERR graphmap-cadence: schtasks /create $TASK_HIMMEL failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        # Roll back the luna task that DID register so status/dedup stay truthful.
        if ! run_schtasks /delete /tn "$TASK_LUNA" /f >/dev/null 2>&1; then
            echo "WARN: rollback of $TASK_LUNA failed — run disarm" >&2
        fi
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    rm -f "$err_file"

    cat <<EOF

================================================================
  GRAPHMAP CADENCE ARMED (HIMMEL-829)
  $TASK_LUNA    daily $LUNA_TIME   -> refresh-graph-map luna
  $TASK_HIMMEL  daily $HIMMEL_TIME   -> refresh-graph-map himmel
  Vault: $VAULT   (maps -> 60-Maps/)
  Himmel: $HIMMEL_ROOT
  Runner .bats: $BAT_DIR

  Each task fires bash + refresh-graph-map.sh directly (no claude
  session). StartWhenAvailable=true: a run missed because the PC was
  off/asleep fires when the PC is next on. Arming = daily graphify
  extraction on the $BACKEND backend; disarm anytime with:
      bash scripts/luna/graphmap-cadence.sh disarm
================================================================
EOF
}

# --- POSIX (cron) implementation -------------------------------------------
#
# Same arm/status/disarm contract as the schtasks path, against the user
# crontab. Both cadence entries live in ONE crontab rewrite (snapshot -> filter
# -> append -> install), so there is no half-armed state to roll back. Runner
# .sh files mirror the .bat runners: log rotation, fire stamp, cd-into-himmel,
# then bash + refresh-graph-map.sh.

CRON_RUNNER_LUNA="$BAT_DIR/graphmap-luna.sh"
CRON_RUNNER_HIMMEL="$BAT_DIR/graphmap-himmel.sh"

# Shell-quote a value for a cron command line (mirrors pipeline-cadence
# cron_escape): printf %q survives the /bin/sh re-parse; the extra % -> \% pass
# is cron(5) syntax. Control characters are rejected (rc=2).
cron_escape() {
    if printf '%s' "$1" | grep -qP '[[:cntrl:]]' 2>/dev/null \
       || printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x1f\x7f]'; then
        echo "ERR graphmap-cadence: cron_escape: argument contains control characters — rejected" >&2
        return 2
    fi
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the current crontab into CRON_TAB. Fail-CLOSED like list_existing.
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    set +e
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR graphmap-cadence: crontab -l failed (rc=$rc) — refusing to treat as empty crontab:" >&2
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

# Install a new crontab from the given file. Returns 4 on failure; the rejected
# tab is kept for forensics.
cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR graphmap-cadence: crontab install failed:" >&2
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

# Build the argv the runner .sh hands to /bin/sh: bash + refresh-graph-map.sh +
# flags. bash/script/corpus/maps/title arrive pre-quoted (printf %q);
# name/slug/tag/backend are fixed ASCII literals.
cron_payload() {
    local q_bash="$1" q_script="$2" name="$3" q_corpus="$4" q_maps="$5" q_title="$6" slug="$7" tag="$8"
    printf '%s %s --name %s --corpus-root %s --maps-dir %s --title %s --slug %s --backend %s --corpus-tag %s' \
        "$q_bash" "$q_script" "$name" "$q_corpus" "$q_maps" "$q_title" "$slug" "$BACKEND" "$tag"
}

# Emit the runner .sh body for one cadence task: stamp the format version,
# rotate the run log, stamp the fire time, cd into the himmel root, then fire the
# payload with output captured to the log. Optional PATH prepend for nvm-managed
# node (refresh-graph-map.sh calls node) under cron's minimal PATH.
# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh
emit_runner() {
    local name="$1" payload="$2" q_log="$3" q_himmel="$4" q_node_dir="${5:-}"
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by graphmap-cadence.sh arm (HIMMEL-829)\n' "$name"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    if [ -n "$q_node_dir" ]; then
        printf 'export PATH=%s:$PATH\n' "$q_node_dir"
    fi
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then\n'
    printf '    mv -f "$log" "$log.prev" || echo "[rotation failed: mv $log -> $log.prev]" >> "$log" 2>&1\n'
    printf 'fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    printf '    cd %s || exit 1\n' "$q_himmel"
    printf '    _rc=0; %s || _rc=$?\n' "$payload"
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
}

cron_status() {
    cron_read
    echo "graphmap-cadence status:"
    local name log entry sched
    for name in "$TASK_LUNA" "$TASK_HIMMEL"; do
        case "$name" in
            "$TASK_LUNA") log="$BAT_DIR/graphmap-luna.log" ;;
            *)            log="$BAT_DIR/graphmap-himmel.log" ;;
        esac
        entry=$(printf '%s\n' "$CRON_TAB" | grep -F "# $name" | head -1 || true)
        if [ -n "$entry" ]; then
            sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
            echo "ARMED      $name (cron: $sched)$(task_summary "$name")"
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
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$CRON_RUNNER_LUNA" "$CRON_RUNNER_HIMMEL"
        fi
        echo "graphmap-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "DRY graphmap-cadence: would remove crontab entry: $line"
        done <<< "$existing"
        echo "DRY graphmap-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t graphmap-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" > "$newtab" || true
    # Install must succeed BEFORE the runners are removed — a failed install
    # leaves the entries live and they must keep pointing at existing runners.
    cron_install "$newtab" || exit 4
    rm -f "$CRON_RUNNER_LUNA" "$CRON_RUNNER_HIMMEL"
    echo "graphmap-cadence: cadence disarmed"
}

cron_arm() {
    validate_arm_inputs

    # Resolve bash to an absolute path so the runner doesn't depend on cron's
    # minimal PATH. Capture node's directory so the runner can prepend it (nvm
    # node won't be in cron's PATH; refresh-graph-map.sh needs node).
    local bash_bin node_dir node_bin
    if ! bash_bin=$(command -v bash 2>/dev/null); then
        echo "ERR graphmap-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    node_dir=""
    if node_bin=$(command -v node 2>/dev/null); then
        node_dir=$(dirname "$node_bin")
    fi

    # Dedup guard — never double-register the cadence.
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "graphmap-cadence: --force set; replacing existing cadence entries:" >&2
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$DRY_RUN" -eq 0 ]; then
                    echo "  $line" >&2
                else
                    echo "DRY graphmap-cadence: would remove crontab entry: $line"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR graphmap-cadence: HIMMEL-GraphMap-* crontab entries already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/graphmap-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_bash q_script q_node_dir q_vault q_himmel q_maps q_luna_title q_himmel_title q_log_luna q_log_himmel
    q_bash=$(printf '%q' "$bash_bin")
    q_script=$(printf '%q' "$REFRESH_SCRIPT")
    q_node_dir=$([ -n "$node_dir" ] && printf '%q' "$node_dir" || printf '')
    q_vault=$(printf '%q' "$VAULT")
    q_himmel=$(printf '%q' "$HIMMEL_ROOT")
    q_maps=$(printf '%q' "$VAULT/60-Maps")
    q_luna_title=$(printf '%q' "$LUNA_TITLE")
    q_himmel_title=$(printf '%q' "$HIMMEL_TITLE")
    q_log_luna=$(printf '%q' "$BAT_DIR/graphmap-luna.log")
    q_log_himmel=$(printf '%q' "$BAT_DIR/graphmap-himmel.log")

    local payload_luna payload_himmel
    payload_luna=$(cron_payload "$q_bash" "$q_script" luna "$q_vault" "$q_maps" "$q_luna_title" "$LUNA_SLUG" "$LUNA_TAG")
    payload_himmel=$(cron_payload "$q_bash" "$q_script" himmel "$q_himmel" "$q_maps" "$q_himmel_title" "$HIMMEL_SLUG" "$HIMMEL_TAG")

    local luna_hh luna_mm himmel_hh himmel_mm
    luna_hh="${LUNA_TIME%:*}"; luna_mm="${LUNA_TIME#*:}"
    himmel_hh="${HIMMEL_TIME%:*}"; himmel_mm="${HIMMEL_TIME#*:}"
    local q_runner_luna q_runner_himmel
    q_runner_luna=$(cron_escape "$CRON_RUNNER_LUNA")
    q_runner_himmel=$(cron_escape "$CRON_RUNNER_HIMMEL")
    local entry_luna entry_himmel
    entry_luna="$luna_mm $luna_hh * * * $q_runner_luna # $TASK_LUNA"
    entry_himmel="$himmel_mm $himmel_hh * * * $q_runner_himmel # $TASK_HIMMEL"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY graphmap-cadence: would write $CRON_RUNNER_LUNA:"
        emit_runner "$TASK_LUNA" "$payload_luna" "$q_log_luna" "$q_himmel" "$q_node_dir" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would write $CRON_RUNNER_HIMMEL:"
        emit_runner "$TASK_HIMMEL" "$payload_himmel" "$q_log_himmel" "$q_himmel" "$q_node_dir" | sed 's/^/    /'
        echo "DRY graphmap-cadence: would add crontab entries:"
        echo "    $entry_luna"
        echo "    $entry_himmel"
        echo "graphmap-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Stage the runners at temp paths and promote (mv) them only after the
    # crontab install succeeds: writing them in place first would let a failed
    # install (exit 4) leave the OLD crontab live while the runner files already
    # carry the NEW config — a silent half-state under --force re-arm.
    local tmp_luna="$CRON_RUNNER_LUNA.tmp.$$" tmp_himmel="$CRON_RUNNER_HIMMEL.tmp.$$"
    emit_runner "$TASK_LUNA" "$payload_luna" "$q_log_luna" "$q_himmel" "$q_node_dir" > "$tmp_luna"
    emit_runner "$TASK_HIMMEL" "$payload_himmel" "$q_log_himmel" "$q_himmel" "$q_node_dir" > "$tmp_himmel"
    chmod +x "$tmp_luna" "$tmp_himmel"

    # Single atomic rewrite: everything that isn't ours, then both entries.
    local newtab
    newtab=$(mktemp -t graphmap-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" || true
        fi
        printf '%s\n' "$entry_luna" "$entry_himmel"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        rm -f "$tmp_luna" "$tmp_himmel"
        echo "    existing runner files left untouched" >&2
        exit 4
    fi
    mv -f "$tmp_luna" "$CRON_RUNNER_LUNA"
    mv -f "$tmp_himmel" "$CRON_RUNNER_HIMMEL"

    cat <<EOF

================================================================
  GRAPHMAP CADENCE ARMED (HIMMEL-829, cron)
  $TASK_LUNA    daily $LUNA_TIME   -> refresh-graph-map luna
  $TASK_HIMMEL  daily $HIMMEL_TIME   -> refresh-graph-map himmel
  Vault: $VAULT   (maps -> 60-Maps/)
  Himmel: $HIMMEL_ROOT
  Runner .sh: $BAT_DIR

  Each task fires bash + refresh-graph-map.sh directly (no claude
  session). Arming = daily graphify extraction on the $BACKEND backend; disarm anytime:
      bash scripts/luna/graphmap-cadence.sh disarm
================================================================
EOF
}

case "$SUBCMD" in
    arm)    if [ "$PLATFORM" = "windows" ]; then cmd_arm;    else cron_arm;    fi ;;
    status) if [ "$PLATFORM" = "windows" ]; then cmd_status; else cron_status; fi ;;
    disarm) if [ "$PLATFORM" = "windows" ]; then cmd_disarm; else cron_disarm; fi ;;
esac
