#!/usr/bin/env bash
# repo-sync-cadence.sh — arm/status/disarm the daily repo-sync cadence
# (HIMMEL-2115).
#
# WHY: operator directive (2026-08-25, NOW-20): a DAILY cadence that syncs
# every git repo on the machine to its remote default branch, safely — fetch
# always, fast-forward-only pull only when the repo is clean AND checked out
# on its default branch, NEVER merge/rebase/resolve a conflict. Anything else
# (dirty, non-default branch, a single-writer marker) is a benign fetch-only
# skip; a diverged/non-ff branch or any git failure is a recorded FAILURE,
# never a fix attempt.
#
# RUNNER SPLIT (mirrors graphmap-cadence.sh's structural/semantic legs,
# HIMMEL-829, and ggs-cadence.sh's flow-run-ledger use, HIMMEL-2048): the
# actual per-repo enumeration/fetch/ff-only-merge logic is real branching
# logic, not reasonably expressible as generated .bat lines, so it lives in
# the sibling scripts/sync/repo-sync-runner.sh. This file owns ONLY the OS
# scheduler arm/status/disarm layer and fires the runner by absolute path;
# the runner sources scripts/lib/flow-run-ledger.sh itself and writes its own
# start/end rows (flow "repo-sync") with a REAL exit code — never an
# unconditional exit 0 (the HIMMEL-2048 bug class).
#
# SELF-REGISTRATION (HIMMEL-1680): arm registers the "repo-sync" flow (daily,
# 86400s) into the observability registry (scripts/lib/observability-registry.sh)
# so himmel-doctor's C24 catches a silently-vanished task; disarm unregisters
# it.
#
# ALERTING: no new alert rule is added here. The existing flow-exporter /
# HimmelFlowRunStalled + flow-last-success pattern already alerts on a
# registered daily flow that stops reporting or reports outcome=error — that
# machinery is driven purely by the registry + ledger rows this file and the
# runner wire up (see flow_cadence_seconds in scripts/observability/flow-exporter.ts).
#
# OPERATOR-ARMED, NOT AUTO-ARMED: `arm` only runs when explicitly invoked.
#
# Windows-only (schtasks + cygpath), same platform gate as every sibling
# cadence (codex-sweep-cadence.sh, ggs-cadence.sh) — no InteractiveToken
# Principal needed (every leg is a plain git/bash filesystem operation, not a
# process-liveness sweep), so this follows ggs-cadence.sh's simpler shape.
#
# STALE-WT CLEANUP (HIMMEL-2116, follow-up): the runner also examines every
# enumerated folder that looks like a scratch worktree (a linked-worktree
# `.git` file, or a `wt-*`-named directory) against a stricter safety gate
# and deletes it (+ prunes the parent repo's worktree registry) only when
# clean, fully pushed, and stale beyond --wt-stale-days. This file only
# threads that one flag through to the runner invocation, same as
# --github-root/--documents-root; the classification logic itself lives in
# repo-sync-runner.sh.
#
# Usage:
#   bash scripts/sync/repo-sync-cadence.sh arm [--time HH:MM]
#       [--github-root PATH] [--documents-root PATH] [--wt-stale-days N]
#       [--force] [--dry-run]
#   bash scripts/sync/repo-sync-cadence.sh status
#   bash scripts/sync/repo-sync-cadence.sh disarm
#
# Test seams (used by test-repo-sync-cadence.sh):
#   RSC_SCHTASKS     — command invoked instead of `schtasks`
#   RSC_BAT_DIR       — where the persistent runner (.bat) lives
#   RSC_HIMMEL_ROOT   — overrides the resolved HIMMEL_ROOT outright (test-only;
#                       exercises the missing-runner rc=2 path)
#
# Exit codes:
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error (incl. malformed --time — checked BEFORE the
#      platform gate so it is rc 1 on every platform, not rc 2 on POSIX)
#   2  env unusable (non-Windows platform; no schtasks/cygpath/bash on PATH;
#      runner script missing; --documents-root not a directory; WSH runner
#      unavailable)
#   3  dedup block — HIMMEL-RepoSync already armed; --force replaces
#   4  scheduler invocation failed (/create, /delete, path conversion)
set -euo pipefail

TASK_NAME="HIMMEL-RepoSync"
SCHTASKS_BIN="${RSC_SCHTASKS:-schtasks}"

# Cross-platform user-home resolution (mirrors codex-sweep-cadence's /
# ggs-cadence's resolve_user_home, HIMMEL-645): prefer USERPROFILE via
# cygpath on Windows Git-Bash (MSYS $HOME can differ from where ~/.claude
# actually lives).
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home — also the runner's own default results-file
# directory (repo-sync-runner.sh defaults --results-file under the SAME
# <home>/.claude/repo-sync-cadence dir), so status can find it without a
# second knob.
BAT_DIR="${RSC_BAT_DIR:-$(resolve_user_home)/.claude/repo-sync-cadence}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the himmel root to the PRIMARY checkout, not this script's own
# location (mirrors codex-sweep-cadence's resolve_himmel_root, HIMMEL-892
# codex-adv-1): arming from a feature worktree would otherwise embed absolute
# runner paths under THAT worktree in the persistent .bat runner; post-merge
# worktree pruning then deletes those paths and every scheduled fire fails
# thereafter.
#
# Test seam: RSC_HIMMEL_ROOT overrides HIMMEL_ROOT outright — test-only, used
# to exercise the missing-runner rc=2 path via a root without it; the
# git-common-dir derivation itself is covered directly.
resolve_himmel_root() {
    local common_dir
    command -v git >/dev/null 2>&1 || return 1
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;                 # already absolute (POSIX or Windows drive)
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}

if [ -n "${RSC_HIMMEL_ROOT:-}" ]; then
    HIMMEL_ROOT="$RSC_HIMMEL_ROOT"
elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
    :
else
    echo "WARN repo-sync-cadence: could not resolve the primary checkout via git (git unavailable, not inside a repo, or rev-parse failed) -- falling back to this script's own location. If this checkout is a worktree that gets pruned later, the armed cadence's runner path will break (mirrors HIMMEL-892 codex-adv-1)." >&2
    HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
RUNNER_SCRIPT="$HIMMEL_ROOT/scripts/sync/repo-sync-runner.sh"

# Runner-format version stamp (HIMMEL-588): shared with the other cadences so
# a stale-format armed runner is detectable via the same marker convention.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"
# shellcheck source=../lib/observability-registry.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/observability-registry.sh"

# Off-peak default: before ggs-cadence's 05:20 and codex-sweep's 09:00, after
# graphmap's ast-luna 00:05 -- a quiet slot with no known collision.
SYNC_TIME="04:10"
DRY_RUN=0
FORCE=0
GITHUB_ROOT=""
DOCUMENTS_ROOT=""
WT_STALE_DAYS=""

usage() {
    cat <<'EOF'
Usage: repo-sync-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the daily repo-sync cadence (HIMMEL-2115): ONE
daily task that fires scripts/sync/repo-sync-runner.sh, which enumerates
every git repo under --github-root (scanned fully/recursively) and
--documents-root (scanned to depth 2, excluding the github-root subtree),
fetches each, and fast-forward-only pulls the default branch only when the
repo is clean and checked out on it. Dirty/non-default/single-writer repos
are fetch-only (benign skip); a diverged branch or any git failure is
recorded as a failure -- NEVER a merge/rebase/resolve attempt. The same fire
also runs a stale-wt cleanup pass (HIMMEL-2116): scratch worktree folders
(linked-worktree checkouts, `wt-*`-named dirs) get deleted + pruned only
when clean, fully pushed, and stale beyond --wt-stale-days -- anything else
is an ALERT row, never a delete. A flow-run ledger row and a per-repo JSONL
results file are written every fire.

Subcommands:
  arm      Register the daily task. Dedup-guarded: refuses (rc=3) if
           HIMMEL-RepoSync is already armed; --force replaces.
  status   Show whether the cadence task is armed (+ next run time +
           runner-log evidence).
  disarm   Remove the task (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>            Daily fire time, 24h local (default 04:10).
                             arm-only.
  --github-root <path>      Root scanned FULLY/recursively for git repos
                             (default: <home>/Documents/github). arm-only.
  --documents-root <path>   Root scanned to depth 2, excluding the
                             github-root subtree (default: <home>/Documents).
                             arm-only.
  --wt-stale-days <N>        Stale-wt-cleanup threshold in days (default 14).
                             arm-only.
  --force                    Replace an already-armed HIMMEL-RepoSync task
  --dry-run                  Print what would happen, touch nothing (honored
                             by arm AND disarm)
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR repo-sync-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR repo-sync-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

TIME_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            if [ $# -lt 2 ]; then
                echo "ERR repo-sync-cadence: --time requires a value (HH:MM)" >&2
                usage >&2
                exit 1
            fi
            SYNC_TIME="$2"; TIME_SET=1; shift 2 ;;
        --time=*)   SYNC_TIME="${1#--time=}"; TIME_SET=1; shift ;;
        --github-root)
            if [ $# -lt 2 ]; then
                echo "ERR repo-sync-cadence: --github-root requires a value" >&2
                usage >&2
                exit 1
            fi
            GITHUB_ROOT="$2"; shift 2 ;;
        --github-root=*) GITHUB_ROOT="${1#--github-root=}"; shift ;;
        --documents-root)
            if [ $# -lt 2 ]; then
                echo "ERR repo-sync-cadence: --documents-root requires a value" >&2
                usage >&2
                exit 1
            fi
            DOCUMENTS_ROOT="$2"; shift 2 ;;
        --documents-root=*) DOCUMENTS_ROOT="${1#--documents-root=}"; shift ;;
        --wt-stale-days)
            if [ $# -lt 2 ]; then
                echo "ERR repo-sync-cadence: --wt-stale-days requires a value" >&2
                usage >&2
                exit 1
            fi
            WT_STALE_DAYS="$2"; shift 2 ;;
        --wt-stale-days=*) WT_STALE_DAYS="${1#--wt-stale-days=}"; shift ;;
        --force)    FORCE=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)
            echo "ERR repo-sync-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# --time / --github-root / --documents-root are arm-only: usage scopes them
# to arm, but the flags were parsed for every subcommand above. Reject them
# on status/disarm before the format check so the error names the real
# reason (same ordering as codex-sweep-cadence/ggs-cadence).
if [ "$TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR repo-sync-cadence: --time is arm-only" >&2
    exit 1
fi
if [ -n "$GITHUB_ROOT" ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR repo-sync-cadence: --github-root is arm-only" >&2
    exit 1
fi
if [ -n "$DOCUMENTS_ROOT" ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR repo-sync-cadence: --documents-root is arm-only" >&2
    exit 1
fi
if [ -n "$WT_STALE_DAYS" ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR repo-sync-cadence: --wt-stale-days is arm-only" >&2
    exit 1
fi
if [ "$FORCE" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR repo-sync-cadence: --force is arm-only" >&2
    exit 1
fi

# --time validation happens BEFORE the platform gate (same ordering as
# codex-sweep-cadence/ggs-cadence): an input error must be rc 1 on every
# platform, not rc 2 on POSIX.
if ! [[ "$SYNC_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR repo-sync-cadence: --time must be HH:MM (24h), got: $SYNC_TIME" >&2
    exit 1
fi
[ -n "$WT_STALE_DAYS" ] || WT_STALE_DAYS=14
# Same 6-digit cap + STRING-length glob as repo-sync-runner.sh's own
# validation (codex-2, HIMMEL-2116 pr-check round-2 panel) -- kept in sync
# since this value is threaded straight into the runner's own flag.
case "$WT_STALE_DAYS" in
    ''|*[!0-9]*)
        echo "ERR repo-sync-cadence: --wt-stale-days must be a non-negative integer, got: $WT_STALE_DAYS" >&2
        exit 1
        ;;
    ???????*)
        echo "ERR repo-sync-cadence: --wt-stale-days is unreasonably large (max 6 digits), got: $WT_STALE_DAYS" >&2
        exit 1
        ;;
esac

# $HOME-relative defaults (CLAUDE.md: no absolute home paths in committed
# files) — resolved AFTER the platform/input checks so a bare --help or a
# malformed --time never depends on resolve_user_home.
[ -n "$GITHUB_ROOT" ] || GITHUB_ROOT="$(resolve_user_home)/Documents/github"
[ -n "$DOCUMENTS_ROOT" ] || DOCUMENTS_ROOT="$(resolve_user_home)/Documents"

# Platform gate: Windows-only, same as codex-sweep-cadence/ggs-cadence
# (schtasks + cygpath).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    *)                           PLATFORM=other ;;
esac
if [ "$PLATFORM" != "windows" ]; then
    echo "ERR repo-sync-cadence: Windows-only — schtasks/cygpath are Windows constructs." >&2
    exit 2
fi
command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
    echo "ERR repo-sync-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
    exit 2
}

# MSYS_NO_PATHCONV=1 per call: without it gitbash mangles /query, /create etc.
# into Windows-rooted paths before schtasks sees them.
run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# Emit the runner .bat body: stamp the format version, prepend Git's GNU
# coreutils to PATH (the runner needs dirname/date/mkdir/mv/find/sed — a
# non-login schtasks-launched bash.exe inherits the bare Windows PATH,
# HIMMEL-1672), rotate the log, stamp the fire time, fire the runner
# (`call`, HIMMEL-1389: a shim-resolvable payload must never transfer control
# away for good), capture its ERRORLEVEL, and propagate it AS the task's exit
# code (2048 pattern — never an unconditional exit /b 0). The runner owns its
# own flow-run ledger rows internally; this .bat writes none.
emit_bat() {
    local bat_dir_esc="$1" bash_esc="$2" runner_esc="$3" \
        github_root_esc="$4" documents_root_esc="$5" results_file_esc="$6" git_bin_esc="$7" \
        wt_stale_days_esc="$8"
    printf '@echo off\r\n'
    printf 'rem repo-sync-cadence runner (HIMMEL-2115)\r\n'
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    cadence_bat_editor_set
    if [ -n "$git_bin_esc" ]; then
        printf 'set "PATH=%s;%%PATH%%"\r\n' "$git_bin_esc"
    fi
    printf 'set "LOG=%s\\repo-sync.log"\r\n' "$bat_dir_esc"
    printf 'if exist "%%LOG%%" move /y "%%LOG%%" "%%LOG%%.prev" >nul\r\n'
    printf 'echo [fired %%date%% %%time%%] > "%%LOG%%"\r\n'
    printf 'call "%s" "%s" --github-root "%s" --documents-root "%s" --results-file "%s" --task-name "%s" --wt-stale-days "%s" >> "%%LOG%%" 2>&1\r\n' \
        "$bash_esc" "$runner_esc" "$github_root_esc" "$documents_root_esc" "$results_file_esc" "$TASK_NAME" "$wt_stale_days_esc"
    printf 'set "PAYLOAD_RC=%%ERRORLEVEL%%"\r\n'
    printf 'echo [repo-sync exit rc=%%PAYLOAD_RC%%] >> "%%LOG%%"\r\n'
    printf 'exit /b %%PAYLOAD_RC%%\r\n'
}

# --- schtasks task XML (StartWhenAvailable, default Principal) -------------

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

schedule_daily_xml() {
    printf '      <ScheduleByDay>\n        <DaysInterval>1</DaysInterval>\n      </ScheduleByDay>'
}

emit_task_xml() {
    local bat_win="$1" start_time="$2" schedule_xml="$3" vbs_win vbs_args
    vbs_win=$(cadence_vbs_path "$bat_win")
    vbs_args=$(xml_escape "//B \"${vbs_win}\"")
    cat <<XML
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>himmel repo-sync-cadence (HIMMEL-2115)</Description>
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

schtasks_create_xml() {
    local name="$1" schedule_xml="$2" start_time="$3" bat_win="$4" err_file="$5"
    local xml_file xml_win rc
    if ! xml_file=$(mktemp -t repo-sync-cadence.xml.XXXXXX 2>"$err_file"); then
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

NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

QUERY_OUT=""
query_task() {
    local name="$1" rc err_file
    err_file=$(mktemp -t repo-sync-cadence.err.XXXXXX)
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
    echo "ERR repo-sync-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
    cat "$err_file" >&2
    echo "    If this is a localized 'task does not exist' message, the task may simply" >&2
    echo "    not be armed. Verify / remove manually:" >&2
    echo "        schtasks /query /tn $name" >&2
    echo "        schtasks /delete /tn $name /f" >&2
    rm -f "$err_file"
    return 2
}

delete_task() {
    local name="$1" err_file
    err_file=$(mktemp -t repo-sync-cadence.err.XXXXXX)
    if run_schtasks /delete /tn "$name" /f >/dev/null 2>"$err_file"; then
        rm -f "$err_file"
        echo "repo-sync-cadence: deleted scheduled task: $name"
    else
        echo "ERR repo-sync-cadence: schtasks /delete $name failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        exit 4
    fi
}

# Surface fire-time evidence + the aggregate rc stamp.
status_log() {
    local log="$1" mtime last rc
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        echo "  run log    $log (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
        rc=$(grep -o '\[repo-sync exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        if [ -n "$rc" ] && [ "$rc" != "0" ]; then
            echo "  WARN: last fire had a non-zero repo-sync rc=$rc (at least one repo failed — see the results file)"
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
    echo "  results    $BAT_DIR/repo-sync-results.jsonl (per-repo detail; .prev = previous run)"
}

cmd_arm() {
    cadence_require_wsh "repo-sync-cadence" || exit 2

    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR repo-sync-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }

    if [ ! -f "$RUNNER_SCRIPT" ]; then
        echo "ERR repo-sync-cadence: repo-sync-runner.sh not found at $RUNNER_SCRIPT" >&2
        exit 2
    fi
    if [ ! -d "$DOCUMENTS_ROOT" ]; then
        echo "ERR repo-sync-cadence: --documents-root is not a directory: $DOCUMENTS_ROOT" >&2
        exit 2
    fi
    # WARN, not a hard failure (unlike --documents-root above): a missing
    # --github-root is handled gracefully by the runner every fire (it just
    # skips scanning it, since a fresh machine may not have cloned anything
    # there yet) — but silently accepting it at arm time hid a real typo
    # from the operator (codex CR round 5), so surface it loudly here while
    # still letting arm proceed for the legitimate not-yet-created case.
    if [ ! -d "$GITHUB_ROOT" ]; then
        echo "WARN repo-sync-cadence: --github-root is not a directory: $GITHUB_ROOT (arming anyway — the runner skips a missing root every fire, but verify this wasn't a typo)" >&2
    fi

    # Resolve bash to an absolute Windows path (the runner shells out to it) —
    # NOT the bare `bash` that resolves to the WSL System32 stub in a fresh
    # cmd.exe.
    local bash_posix bash_win
    if ! bash_posix=$(command -v bash 2>/dev/null); then
        echo "ERR repo-sync-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    if ! bash_win=$(cygpath -w "$bash_posix" 2>&1); then
        echo "ERR repo-sync-cadence: cygpath -w failed for bash path: $bash_win" >&2
        exit 4
    fi

    # Dedup guard — never double-register the cadence.
    local dedup_rc=0
    query_task "$TASK_NAME" || dedup_rc=$?
    case "$dedup_rc" in
        0)
            if [ "$FORCE" -eq 1 ]; then
                echo "repo-sync-cadence: --force set; existing task $TASK_NAME will be replaced by /create /f" >&2
            else
                {
                    echo "ERR repo-sync-cadence: $TASK_NAME already armed."
                    echo ""
                    echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                    echo "    bash scripts/sync/repo-sync-cadence.sh status"
                } >&2
                exit 3
            fi
            ;;
        1) : ;;
        *) exit 2 ;;
    esac

    local runner_win github_root_win documents_root_win bat_dir_win results_file_win
    if ! runner_win=$(cygpath -w "$RUNNER_SCRIPT" 2>&1); then
        echo "ERR repo-sync-cadence: cygpath -w failed for the runner script: $runner_win" >&2
        exit 4
    fi
    if ! github_root_win=$(cygpath -w "$GITHUB_ROOT" 2>&1); then
        echo "ERR repo-sync-cadence: cygpath -w failed for --github-root: $github_root_win" >&2
        exit 4
    fi
    if ! documents_root_win=$(cygpath -w "$DOCUMENTS_ROOT" 2>&1); then
        echo "ERR repo-sync-cadence: cygpath -w failed for --documents-root: $documents_root_win" >&2
        exit 4
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$BAT_DIR"
    fi
    if ! bat_dir_win=$(cygpath -w "$BAT_DIR" 2>&1); then
        echo "ERR repo-sync-cadence: cygpath -w failed for bat dir: $bat_dir_win" >&2
        exit 4
    fi
    if ! results_file_win=$(cygpath -w "$BAT_DIR/repo-sync-results.jsonl" 2>&1); then
        echo "ERR repo-sync-cadence: cygpath -w failed for the results file: $results_file_win" >&2
        exit 4
    fi

    local bash_esc runner_esc github_root_esc documents_root_esc results_file_esc bat_dir_esc git_bin_esc
    bash_esc=$(cadence_cmd_escape "$bash_win")
    runner_esc=$(cadence_cmd_escape "$runner_win")
    github_root_esc=$(cadence_cmd_escape "$github_root_win")
    documents_root_esc=$(cadence_cmd_escape "$documents_root_win")
    results_file_esc=$(cadence_cmd_escape "$results_file_win")
    bat_dir_esc=$(cadence_cmd_escape "$bat_dir_win")
    git_bin_esc=$(cadence_cmd_escape "$(cadence_git_bin_path_win "$bash_win")")

    local bat_file="$BAT_DIR/repo-sync.bat" vbs_file="$BAT_DIR/repo-sync.vbs" bat_win
    if ! bat_win=$(cygpath -w "$bat_file" 2>&1); then
        echo "ERR repo-sync-cadence: cygpath -w failed for bat file: $bat_win" >&2
        exit 4
    fi

    local sched
    sched=$(schedule_daily_xml)

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY repo-sync-cadence: would write $bat_file:"
        emit_bat "$bat_dir_esc" "$bash_esc" "$runner_esc" "$github_root_esc" "$documents_root_esc" "$results_file_esc" "$git_bin_esc" "$WT_STALE_DAYS" | sed 's/^/    /'
        echo "DRY repo-sync-cadence: would write $vbs_file:"
        cadence_vbs_wrapper "$bat_win" | sed 's/^/    /'
        echo "DRY repo-sync-cadence: would schtasks /create /tn $TASK_NAME /xml <daily $SYNC_TIME, StartWhenAvailable=true> /f"
        emit_task_xml "$bat_win" "$SYNC_TIME" "$sched" | sed 's/^/    /'
        echo "repo-sync-cadence: dry-run complete (no changes made)"
        return 0
    fi

    # Atomic runner publication BEFORE task registration (same ordering as
    # codex-sweep-cadence/ggs-cadence, HIMMEL-892 round-3 CR fix): emit to a
    # temp file beside the target, then publish it BEFORE /create runs.
    #
    # On a --force re-arm of an ALREADY-LIVE task, this publish already
    # overwrites the fixed-path .bat/.vbs the existing task invokes. If
    # `schtasks_create_xml` then fails, the pre-existing task stays armed but
    # now silently runs the new, never-registered payload despite this
    # command reporting failure (codex-2, HIMMEL-2115 pr-check round-7 panel).
    # Back up any pre-existing .bat/.vbs and restore them on failure, so a
    # reported arm failure truthfully means "nothing changed" for an already-
    # armed task; on a first-ever arm there is nothing to restore, so the
    # newly-published files are simply removed (no task references them yet).
    local bat_tmp vbs_tmp bat_backup="" vbs_backup=""
    bat_tmp=$(mktemp "$BAT_DIR/.repo-sync.bat.XXXXXX")
    vbs_tmp=$(mktemp "$BAT_DIR/.repo-sync.vbs.XXXXXX")
    emit_bat "$bat_dir_esc" "$bash_esc" "$runner_esc" "$github_root_esc" "$documents_root_esc" "$results_file_esc" "$git_bin_esc" "$WT_STALE_DAYS" > "$bat_tmp"
    cadence_vbs_wrapper "$bat_win" > "$vbs_tmp"
    if [ -f "$vbs_file" ]; then
        vbs_backup=$(mktemp "$BAT_DIR/.repo-sync.vbs.bak.XXXXXX")
        cp -p "$vbs_file" "$vbs_backup"
    fi
    if [ -f "$bat_file" ]; then
        bat_backup=$(mktemp "$BAT_DIR/.repo-sync.bat.bak.XXXXXX")
        cp -p "$bat_file" "$bat_backup"
    fi
    if ! mv -f "$vbs_tmp" "$vbs_file"; then
        echo "ERR repo-sync-cadence: failed to publish runner shim to $vbs_file" >&2
        rm -f "$bat_tmp" "$vbs_tmp" "$bat_backup" "$vbs_backup"
        exit 4
    fi
    if ! mv -f "$bat_tmp" "$bat_file"; then
        echo "ERR repo-sync-cadence: failed to publish runner to $bat_file" >&2
        rm -f "$bat_tmp" "$bat_backup"
        # The .vbs publish above already succeeded -- restore it too (or
        # remove it, first-arm case) rather than discarding the backup and
        # leaving .vbs on new content while .bat stays on old content, an
        # inconsistent pair despite this command reporting failure
        # (codex-3, HIMMEL-2115 pr-check round-8 panel).
        if [ -n "$vbs_backup" ]; then mv -f "$vbs_backup" "$vbs_file"; else rm -f "$vbs_file"; fi
        exit 4
    fi

    local err_file
    err_file=$(mktemp -t repo-sync-cadence.err.XXXXXX)
    if ! schtasks_create_xml "$TASK_NAME" "$sched" "$SYNC_TIME" "$bat_win" "$err_file"; then
        echo "ERR repo-sync-cadence: schtasks /create $TASK_NAME failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        if [ -n "$bat_backup" ]; then mv -f "$bat_backup" "$bat_file"; else rm -f "$bat_file"; fi
        if [ -n "$vbs_backup" ]; then mv -f "$vbs_backup" "$vbs_file"; else rm -f "$vbs_file"; fi
        echo "ERR repo-sync-cadence: restored the prior .bat/.vbs payload — any already-armed task is unchanged" >&2
        exit 4
    fi
    if [ -s "$err_file" ]; then cat "$err_file" >&2; fi
    rm -f "$err_file" "$bat_backup" "$vbs_backup"

    # Best-effort (codex CR round 5): the scheduled task above is already
    # live at this point (schtasks_create_xml succeeded) — a registration
    # failure here is an observability-bookkeeping gap, not an arming
    # failure, and under set -e a bare unguarded call would abort the whole
    # command with a misleading nonzero exit while leaving the real task
    # armed. WARN instead of failing so the operator knows himmel-doctor's
    # C24 check won't see this cadence until the registry write is fixed.
    observability_register_cadence repo-sync 86400 "$TASK_NAME" \
        || echo "WARN repo-sync-cadence: observability registration failed (rc=$?) -- $TASK_NAME IS armed and will fire on schedule, but himmel-doctor's C24 check will not detect it going missing until this is retried (re-run arm --force, or fix the registry directly)" >&2

    cat <<EOF

================================================================
  REPO-SYNC CADENCE ARMED (HIMMEL-2115)
  $TASK_NAME    daily $SYNC_TIME
    -> repo-sync-runner.sh --github-root $GITHUB_ROOT --documents-root $DOCUMENTS_ROOT
       fetch every repo; ff-only pull the default branch when clean +
       checked out on it; NEVER merge/rebase/resolve.
       stale-wt cleanup: --wt-stale-days $WT_STALE_DAYS (delete only when
       clean + fully pushed + stale; otherwise ALERT)
  Runner .bat: $bat_file
  Results:     $BAT_DIR/repo-sync-results.jsonl
  Ledger flow: repo-sync (~/.himmel/flow-runs.jsonl)

  Disarm anytime with:
      bash scripts/sync/repo-sync-cadence.sh disarm
================================================================
EOF
}

cmd_status() {
    local status_rc=0 qrc=0 next
    echo "repo-sync-cadence status:"
    query_task "$TASK_NAME" || qrc=$?
    case "$qrc" in
        0)
            next=$(printf '%s\n' "$QUERY_OUT" | grep -i 'Next Run Time' | head -1 \
                | sed 's/^[^:]*:[[:space:]]*//' || true)
            cadence_registered_status "$TASK_NAME" "${next:+ (next run: $next)}" || status_rc=2
            ;;
        1)  echo "not armed  $TASK_NAME" ;;
        *)
            echo "QUERY ERR  $TASK_NAME (see stderr above)"
            status_rc=2
            ;;
    esac
    status_log "$BAT_DIR/repo-sync.log"
    return "$status_rc"
}

cmd_disarm() {
    local qrc=0 found=0
    query_task "$TASK_NAME" || qrc=$?
    case "$qrc" in
        0)
            found=1
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "DRY repo-sync-cadence: would delete $TASK_NAME"
            else
                delete_task "$TASK_NAME"
            fi
            ;;
        1)  : ;;
        *)  exit 2 ;;
    esac
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -f "$BAT_DIR/repo-sync.bat" "$BAT_DIR/repo-sync.vbs"
        # Best-effort, same treatment as the arm path's registration call
        # above: the task and runner files are already gone at this point
        # (the actually-destructive disarm steps already succeeded), so a
        # bare unguarded call here would abort under set -e on a registry
        # write failure, skip the "cadence disarmed" confirmation, and leave
        # a stale registration despite the disarm itself having worked
        # (codex-3, HIMMEL-2115 pr-check round-9 panel).
        observability_unregister_cadence repo-sync "$TASK_NAME" \
            || echo "WARN repo-sync-cadence: observability unregistration failed (rc=$?) -- $TASK_NAME IS disarmed and its runner files are removed, but himmel-doctor's C24 check may still show a stale registration until this is retried (re-run disarm, or fix the registry directly)" >&2
    fi
    if [ "$found" -eq 0 ]; then
        echo "repo-sync-cadence: nothing armed — disarm is a no-op"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY repo-sync-cadence: no changes made"
    else
        echo "repo-sync-cadence: cadence disarmed"
    fi
}

# Runtime preflight on the ARM path only (mirrors codex-sweep/ggs-cadence):
# arming hands this runtime to an unattended schedule, so the drift is named
# while a human is still watching. Advisory by default;
# HIMMEL_RUNTIME_PREFLIGHT=strict refuses, =0 silences.
if [ "$SUBCMD" = "arm" ]; then
    # shellcheck source=../lib/runtime-preflight.sh
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/runtime-preflight.sh"
    runtime_preflight "repo-sync-cadence arm" || exit 1
fi

case "$SUBCMD" in
    arm)    cmd_arm ;;
    status) cmd_status ;;
    disarm) cmd_disarm ;;
esac
