#!/usr/bin/env bash
# drift-fix-cadence.sh — arm/status/disarm the nightly upstream-drift REPAIR
# cadence (HIMMEL-1323).
#
# WHY: the nightly `fork-drift` GitHub Action (HIMMEL-1046) only DETECTS drift.
# It opens one tracking issue and refreshes it forever; closing that loop was
# always a hand-driven ticket, and those stall — HIMMEL-1260 ("bump graphify
# 0.9.22 -> 0.9.23") sat in To Do while the pin advanced past it twice in
# unrelated PRs, and issue #518 accumulated "still drifting" comments for days.
# Detection without repair is just a nag.
#
# This is the repair half, and it runs LOCALLY on purpose (operator decision,
# 2026-07-28): doing it in Actions would spend CI minutes on every nightly, and
# the private repo has Actions off by design anyway. TWO scheduled tasks fire
# an INTERACTIVE claude session each (HIMMEL-128 — never `-p`/`--print`): one on
# the `/drift-fix` runbook (bump what is mechanically bumpable), one on the
# `/fork-resync` runbook (rebase the carried fork against upstream). The drift
# leg lands on private main and leaves a PUBLIC PR for the operator to merge;
# the resync leg's unattended run stops at the audit and opens nothing — an
# operator-run resync may go further, per its own runbook. The public
# squash-merge stays human-authorized, unchanged.
#
# WHY a claude session and not a plain shell script: the repair has to pass the
# same rails a human PR passes — a clean /pr-check before `gh pr create` (the
# CR-marker hook HARD-blocks otherwise), attestation trailers in the FIRST
# commit, and `scripts/propagate-public.sh ship` for the public hop. A headless
# shell runner would have to bypass all three. The MECHANICAL half is still
# structural, not left to prose: scripts/upstreams/apply-drift-bump.sh owns the
# actual pin edit, so the session cannot fat-finger a version or move
# `synced_base` without moving the in-repo pin with it.
#
# TWO tasks, daily, default 05:00 (drift) / 05:30 (resync) local — after
# pipeline-cadence's 02:00/03:00/04:00 legs (no overlap on the same machine)
# and before the workday, so the drift leg's public PR is already waiting
# when the operator checks (the resync leg's unattended run opens nothing —
# see above). StartWhenAvailable=true: a fire missed because the machine
# was off/asleep catches up when it is next on. See the LEG_DRIFT/LEG_RESYNC
# block below for why this is two tasks in one script rather than one task or
# two scripts.
#
# Usage:
#   bash scripts/upstreams/drift-fix-cadence.sh arm [--time HH:MM] [--resync-time HH:MM] [--model M] [--force] [--dry-run]
#   bash scripts/upstreams/drift-fix-cadence.sh status
#   bash scripts/upstreams/drift-fix-cadence.sh disarm [--dry-run]
#
# Test seams (used by test-drift-fix-cadence.sh):
#   DRIFTFIX_SCHTASKS     command invoked instead of `schtasks` (Windows)
#   DRIFTFIX_CRONTAB      command invoked instead of `crontab` (POSIX)
#   DRIFTFIX_BAT_DIR      where the persistent runner (.bat/.sh) + log live
#   DRIFTFIX_CLAUDE       claude binary override (else: command -v claude)
#   DRIFTFIX_HIMMEL_ROOT  overrides the resolved primary checkout outright
#   DRIFTFIX_PLATFORM     force `windows` or `posix` (else: derived from OSTYPE)
#
# Exit codes:
#   0  done (armed / status printed / disarmed / dry-run complete)
#   1  usage or input error (bad subcommand, flag, --time, --resync-time, --model)
#   2  env unusable (no scheduler, no claude, unknown platform, missing payload)
#   3  dedup block — either leg already armed; --force replaces
#   4  scheduler invocation failed (create/delete/query), or the post-arm
#      verify failed (Windows: both legs are deleted before exiting, so arm
#      is all-or-nothing — never one leg live and the other missing)
set -euo pipefail

SCHTASKS_BIN="${DRIFTFIX_SCHTASKS:-schtasks}"
CRONTAB_BIN="${DRIFTFIX_CRONTAB:-crontab}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-platform user-home resolution (HIMMEL-645): on Windows Git-Bash the MSYS
# $HOME can differ from where ~/.claude actually lives, so prefer USERPROFILE.
resolve_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# Persistent runner home — deliberately NOT %TEMP%/mktemp: this task recurs
# daily and temp sweeps would silently kill the cadence.
BAT_DIR="${DRIFTFIX_BAT_DIR:-$(resolve_user_home)/.claude/drift-fix-cadence}"

# Resolve the himmel root to the PRIMARY checkout, never this script's own
# location (HIMMEL-892 codex-adv-1, same trap): arming from a feature worktree
# would embed that worktree's absolute path in the persistent runner, and the
# post-merge prune then deletes it — every later fire would cd into nothing.
# `--git-common-dir` resolves to the PRIMARY .git even from a linked worktree.
resolve_himmel_root() {
    local common_dir
    command -v git >/dev/null 2>&1 || return 1
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;                 # already absolute
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}

if [ -n "${DRIFTFIX_HIMMEL_ROOT:-}" ]; then
    HIMMEL_ROOT="$DRIFTFIX_HIMMEL_ROOT"
elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
    :
else
    echo "WARN drift-fix-cadence: could not resolve the primary checkout via git -- falling back to this script's own location. If this checkout is a worktree that gets pruned later, the armed cadence will break (HIMMEL-892 codex-adv-1)." >&2
    HIMMEL_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && cd .. && pwd)"
fi

GUARD_SCRIPT="$HIMMEL_ROOT/scripts/check-plugin-drift.sh"
BUMP_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/apply-drift-bump.sh"
TOOL_UPGRADE_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/apply-tool-upgrade.sh"
RESYNC_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/resync-fork.sh"

# Runner-format version stamp (HIMMEL-588) — shared with the sibling cadences so
# himmel-doctor / himmel-update can spot a runner armed before a format change.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cadence-format.sh"

FIRE_TIME="05:00"
RESYNC_TIME="05:30"
MODEL="sonnet"
DRY_RUN=0
FORCE=0

# TWO legs, because upstream drift has two genuinely different repairs and one
# must not block the other. The `drift` leg is mechanical and lands nightly
# (a version pin moves, a vendor CLI upgrades). The `resync` leg is a fork
# REBASE — it is a no-op most nights (upstream tags rarely) and, when it does
# fire, it can legitimately end in "conflicted, a human must decide". Folding
# that into the drift leg would let a stuck fork re-sync block routine pin
# bumps. They are separate scheduled tasks for the same reason pipeline-cadence
# arms its legs separately.
#
# Deliberately ONE script rather than a second near-identical cadence file: the
# arm/status/disarm/dedup/rollback machinery below is the part that is hard to
# get right (locale-independent query classification, StartWhenAvailable XML,
# fail-closed crontab reads), and a copy of it would drift from this one.
LEG_DRIFT="HIMMEL-DriftFix"
LEG_RESYNC="HIMMEL-ForkResync"

# Payload prompts. ASCII-only on purpose: the .bat is parsed by cmd.exe under
# the OEM codepage, where UTF-8 punctuation mojibakes. One line each, same
# reason. The real runbooks live in .claude/commands/{drift-fix,fork-resync}.md
# — these are only the invocations.
PROMPT_DRIFT="Run /drift-fix to completion. This is the scheduled nightly upstream-drift repair cadence (HIMMEL-1323) - fully autonomous, no user prompts; follow the runbook exactly, STOP at the public PR, and report what landed."
PROMPT_RESYNC="Run /fork-resync to completion. This is the scheduled nightly carried-fork re-sync cadence (HIMMEL-1323/HIMMEL-1435) - fully autonomous, no user prompts; audit every BEHIND scripts/upstreams.json entry with a fork block, including claude-obsidian (its carried delta is strictly additive; a non-additive result is a regression to report), then STOP at the end of step 3; NEVER run resync-fork.sh --push and do not open a branch or PR; report every result."

# leg_prompt / leg_log / leg_runner <task-name> — the per-leg lookups, kept as
# functions rather than an associative array (bash 3.2 has none; macOS ships 3.2).
leg_prompt() {
    if [ "$1" = "$LEG_RESYNC" ]; then printf '%s' "$PROMPT_RESYNC"; else printf '%s' "$PROMPT_DRIFT"; fi
}
leg_slug() {
    if [ "$1" = "$LEG_RESYNC" ]; then printf 'fork-resync'; else printf 'drift-fix'; fi
}
leg_time() {
    if [ "$1" = "$LEG_RESYNC" ]; then printf '%s' "$RESYNC_TIME"; else printf '%s' "$FIRE_TIME"; fi
}

usage() {
    cat <<'EOF'
Usage: drift-fix-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the nightly upstream-drift REPAIR cadence
(HIMMEL-1323): TWO daily tasks. HIMMEL-DriftFix fires an interactive claude
session on the /drift-fix runbook -- bump what is mechanically bumpable, land
it on private main, and leave a PUBLIC PR for the operator to merge.
HIMMEL-ForkResync fires one on the /fork-resync runbook -- rebase the carried
fork against upstream; its unattended run stops at the audit and opens
nothing (an operator-run resync may go further, per its own runbook).

Subcommands:
  arm      Register both daily tasks. Dedup-guarded: refuses (rc=3) if
           EITHER task is already armed, naming which; --force replaces.
  status   Show whether each leg is armed (+ next run time + run-log
           evidence from its last fire).
  disarm   Remove both tasks and their runners (idempotent; rc=0 if
           nothing was armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>         Daily fire time for HIMMEL-DriftFix, 24h local
                         (default 05:00 -- clear of pipeline-cadence's
                         02:00/03:00/04:00 legs, and early enough that the
                         public PR is waiting by the workday).
  --resync-time <HH:MM>  Daily fire time for HIMMEL-ForkResync, 24h local
                         (default 05:30 -- right after the drift leg).
  --model <name>  claude --model pin for BOTH sessions (default sonnet --
                  the runbooks are well-specified; never inherit the
                  operator's saved default tier).
  --force         Replace an already-armed leg (either or both).
  --dry-run       Print what would happen, touch nothing (honored by
                  arm AND disarm).
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR drift-fix-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR drift-fix-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

TIME_SET=0
RESYNC_TIME_SET=0
MODEL_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            # Guard the value slot: `arm --time` with nothing after it would
            # otherwise die on a raw "shift count out of range" under set -e.
            if [ $# -lt 2 ]; then
                echo "ERR drift-fix-cadence: --time requires a value (HH:MM)" >&2
                usage >&2; exit 1
            fi
            FIRE_TIME="$2"; TIME_SET=1; shift 2 ;;
        --time=*)  FIRE_TIME="${1#--time=}"; TIME_SET=1; shift ;;
        --resync-time)
            if [ $# -lt 2 ]; then
                echo "ERR drift-fix-cadence: --resync-time requires a value (HH:MM)" >&2
                usage >&2; exit 1
            fi
            RESYNC_TIME="$2"; RESYNC_TIME_SET=1; shift 2 ;;
        --resync-time=*) RESYNC_TIME="${1#--resync-time=}"; RESYNC_TIME_SET=1; shift ;;
        --model)
            if [ $# -lt 2 ]; then
                echo "ERR drift-fix-cadence: --model requires a value" >&2
                usage >&2; exit 1
            fi
            MODEL="$2"; MODEL_SET=1; shift 2 ;;
        --model=*) MODEL="${1#--model=}"; MODEL_SET=1; shift ;;
        --force)   FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "ERR drift-fix-cadence: unknown arg: $1" >&2
            usage >&2; exit 1
            ;;
    esac
done

# arm-only flags: reject on status/disarm so the error names the real reason.
if [ "$TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR drift-fix-cadence: --time is arm-only" >&2; exit 1
fi
if [ "$RESYNC_TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR drift-fix-cadence: --resync-time is arm-only" >&2; exit 1
fi
if [ "$MODEL_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR drift-fix-cadence: --model is arm-only" >&2; exit 1
fi

# Validate input BEFORE the platform gate so a bad value is rc 1 everywhere,
# not rc 2 on whichever platform happens to gate first.
if ! [[ "$FIRE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR drift-fix-cadence: --time must be HH:MM (24h), got: $FIRE_TIME" >&2
    exit 1
fi
if ! [[ "$RESYNC_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR drift-fix-cadence: --resync-time must be HH:MM (24h), got: $RESYNC_TIME" >&2
    exit 1
fi
# The model lands inside a generated .bat/cron line; keep it to the shape a
# model name actually has rather than escaping arbitrary text into a shell.
if ! [[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERR drift-fix-cadence: --model must be a plain model name (letters, digits, . _ -), got: $MODEL" >&2
    exit 1
fi

case "${DRIFTFIX_PLATFORM:-${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}}" in
    windows|msys*|cygwin*|win32*|MINGW*) PLATFORM=windows ;;
    posix|linux*|darwin*|freebsd*|Linux|Darwin) PLATFORM=posix ;;
    *) PLATFORM=unknown ;;
esac
if [ "$PLATFORM" = "unknown" ]; then
    echo "ERR drift-fix-cadence: unsupported platform '${OSTYPE:-unknown}'." >&2
    echo "    Supported: Windows (schtasks), Linux/macOS (crontab)" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Shared: payload presence + run-log reporting
# --------------------------------------------------------------------------

require_payload() {
    if [ ! -f "$GUARD_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: drift guard not found at $GUARD_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$BUMP_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: pin bumper not found at $BUMP_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$TOOL_UPGRADE_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: vendor-CLI upgrader not found at $TOOL_UPGRADE_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$HIMMEL_ROOT/.claude/commands/drift-fix.md" ]; then
        echo "ERR drift-fix-cadence: /drift-fix runbook not found at $HIMMEL_ROOT/.claude/commands/drift-fix.md" >&2
        exit 2
    fi
    if [ ! -f "$HIMMEL_ROOT/.claude/commands/fork-resync.md" ]; then
        echo "ERR drift-fix-cadence: /fork-resync runbook not found at $HIMMEL_ROOT/.claude/commands/fork-resync.md" >&2
        exit 2
    fi
    if [ ! -f "$RESYNC_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: fork resync script not found at $RESYNC_SCRIPT" >&2
        exit 2
    fi
}

# Resolve the claude binary. Absolute, so the scheduler's minimal PATH (cron in
# particular) does not decide whether the cadence can run at all.
#
# The override is existence-checked but the PATH lookup is not: `command -v`
# already guarantees an executable, whereas a hand-set DRIFTFIX_CLAUDE pointing
# at nothing would arm a cadence that fails silently every night. Deliberately
# NOT applying -x to the `command -v` result too — on Windows the claude shim
# resolves through .cmd/.exe extension search, and a false negative there would
# block real arming on the platform this cadence primarily runs on.
resolve_claude() {
    if [ -n "${DRIFTFIX_CLAUDE:-}" ]; then
        [ -x "$DRIFTFIX_CLAUDE" ] || return 1
        printf '%s' "$DRIFTFIX_CLAUDE"; return 0
    fi
    command -v claude 2>/dev/null
}

# Shared by both arm paths so the two platforms cannot drift on the message.
claude_unresolved_msg() {
    if [ -n "${DRIFTFIX_CLAUDE:-}" ]; then
        echo "ERR drift-fix-cadence: DRIFTFIX_CLAUDE is set to '$DRIFTFIX_CLAUDE' but that is not an executable file" >&2
    else
        echo "ERR drift-fix-cadence: 'claude' not on PATH at arm time (set DRIFTFIX_CLAUDE to override)" >&2
    fi
}

# Surface fire evidence: "armed but never succeeding" must be visible from
# status alone. The runner rotates one prior run to .log.prev.
status_log() {
    local log="$1" mtime last rc
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null || echo '?')
        echo "  run log    $log (last write: $mtime)"
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        [ -n "$last" ] && echo "             last line: $last"
        rc=$(grep -o '\[exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        if [ -n "$rc" ] && [ "$rc" != "0" ]; then
            echo "  WARN: last fire exited rc=$rc — the drift repair did not complete"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log.prev" 2>/dev/null || echo '?')
        echo "  prev log   $log.prev (last write: $mtime)"
    fi
}

# Best-effort: pre-trust the himmel checkout so an unattended `< NUL` run can't
# stall on Claude Code's interactive workspace-trust prompt (HIMMEL-386). Never
# fatal — a pre-seed failure must not block arming.
pretrust_workspace() {
    local lib="$HIMMEL_ROOT/scripts/lib/ensure-workspace-trust.sh"
    [ -x "$lib" ] || [ -f "$lib" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY drift-fix-cadence: would pre-trust workspace '$HIMMEL_ROOT' in ~/.claude.json"
        return 0
    fi
    bash "$lib" "$HIMMEL_ROOT" >/dev/null 2>&1 \
        || echo "WARN drift-fix-cadence: workspace-trust pre-seed failed for '$HIMMEL_ROOT' (arm continues; first run may prompt to trust the folder)" >&2
}

# --------------------------------------------------------------------------
# Windows (schtasks)
# --------------------------------------------------------------------------

# MSYS_NO_PATHCONV=1 per call: without it Git-Bash mangles /query, /create etc.
# into Windows-rooted paths before schtasks ever sees them.
run_schtasks() { MSYS_NO_PATHCONV=1 "$SCHTASKS_BIN" "$@"; }

# Emit the .bat runner: stamp the format version, rotate the log, stamp the fire
# time, cd into the primary checkout (a failed cd lands in the log rather than
# running claude from the wrong cwd), then the bounded interactive claude run.
# `< NUL` gives stdin EOF; there is deliberately no -p/--print (HIMMEL-128).
# EVERY parameter arrives already cadence_cmd_escape'd — the convention the
# sibling emitters settled on (HIMMEL-1281): if it is not named _esc it does not
# belong in a printf here.
emit_bat() {
    local root_esc="$1" claude_esc="$2" prompt_esc="$3" log_esc="$4" model_esc="$5"
    printf '@echo off\r\n'
    printf 'rem drift-fix-cadence runner (HIMMEL-1323)\r\n'
    printf 'rem %s %s\r\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Pin editor hooks to the no-op `true` so a cadence child (stdin closed under
    # schtasks) can never block on an editor prompt (HIMMEL-1753).
    cadence_bat_editor_set
    printf 'if exist "%s" move /y "%s" "%s.prev" > NUL 2>&1\r\n' "$log_esc" "$log_esc" "$log_esc"
    printf 'echo [fired %%DATE%% %%TIME%%] >> "%s" 2>&1\r\n' "$log_esc"
    printf 'cd /d "%s" >> "%s" 2>&1 || exit /b 1\r\n' "$root_esc" "$log_esc"
    printf 'call "%s" --model "%s" "%s" < NUL >> "%s" 2>&1\r\n' "$claude_esc" "$model_esc" "$prompt_esc" "$log_esc"
    printf 'echo [exit rc=%%ERRORLEVEL%%] >> "%s"\r\n' "$log_esc"
    printf 'exit /b %%ERRORLEVEL%%\r\n'
}

# Escape the three XML-significant characters for element-body text. sed, not
# bash ${s//&/&amp;}: bash 5.1+ treats a literal `&` in a substitution
# REPLACEMENT as the matched text, a version-dependent trap.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# schtasks /create has no flag for StartWhenAvailable, so a daily run is
# SILENTLY SKIPPED when the machine was off/asleep. The only CLI route is
# /create /xml (same approach as the sibling cadences, HIMMEL-362).
#
# The `encoding="UTF-16"` declaration on ASCII bytes is DELIBERATE and correct
# here — do not "fix" it. Two cross-model CR rounds flagged it as a parse risk
# (HIMMEL-1323 rounds 2 and 3), and it is disproved by production evidence, not
# argument: `HIMMEL-CodexOrphanSweep` is armed and Ready on the operator's
# machine right now, created by scripts/cleanup/codex-sweep-cadence.sh through
# `schtasks /create /xml` with byte-identical output. Real schtasks accepts the
# declaration without a BOM or a UTF-16LE re-encode. All three sibling emitters
# (codex-sweep, graphmap, this one) share the convention, so "fixing" it would
# break a working pattern in three places at once.
#
# The load-bearing constraint is the OTHER direction: the bytes must STAY
# ASCII. cmd.exe's OEM codepage mojibakes non-ASCII, and a non-ASCII byte here
# would genuinely require a real UTF-16LE encode to match the declaration —
# which is why every interpolated value above is ASCII-only by construction.
emit_task_xml() {
    local bat_win="$1" start_time="$2" vbs_win vbs_args
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
    <Description>himmel drift-fix-cadence (HIMMEL-1323)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2020-01-01T${start_time}:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
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
    local name="$1" start_time="$2" bat_win="$3" err_file="$4"
    local xml_file xml_win rc
    if ! xml_file=$(mktemp -t drift-fix-cadence.xml.XXXXXX 2>"$err_file"); then
        return 1
    fi
    emit_task_xml "$bat_win" "$start_time" > "$xml_file"
    if ! xml_win=$(cygpath -w "$xml_file" 2>"$err_file"); then
        rm -f "$xml_file"; return 1
    fi
    set +e
    run_schtasks /create /tn "$name" /xml "$xml_win" /f 2>"$err_file"
    rc=$?
    set -e
    rm -f "$xml_file"
    return "$rc"
}

# Real schtasks always emits one of these on a missing task, so rc=1 WITHOUT a
# match (silent rc=1 included) is a real query failure, not "not armed".
NOT_FOUND_RE='The system cannot find the file specified|The specified task name .* does not exist'

# query_task: rc 0 = armed (QUERY_OUT set), 1 = trusted not-found, 2 = query
# failed. Fail-CLOSED — a failed query must never read as "not armed" (arm would
# double-register, disarm would delete the runner while the task stayed live).
QUERY_OUT=""
query_task() {
    local name="$1" rc err_file
    err_file=$(mktemp -t drift-fix-cadence.err.XXXXXX)
    set +e
    QUERY_OUT=$(run_schtasks /query /tn "$name" /fo LIST 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then rm -f "$err_file"; return 0; fi
    if [ "$rc" -eq 1 ] && grep -qiE "$NOT_FOUND_RE" "$err_file"; then
        rm -f "$err_file"; return 1
    fi
    echo "ERR drift-fix-cadence: schtasks /query /tn $name failed (rc=$rc) — refusing to treat as 'not armed':" >&2
    cat "$err_file" >&2
    echo "    If this is a LOCALIZED 'task does not exist' message, the task may simply" >&2
    echo "    not be armed (only English stderr is trusted here). Verify / remove manually:" >&2
    echo "        schtasks /query /tn $name" >&2
    echo "        schtasks /delete /tn $name /f" >&2
    rm -f "$err_file"
    return 2
}

# Roll back BOTH legs, best-effort (a leg that was never created simply errors
# on /delete, which is ignored) — arm is all-or-nothing, so any failure past
# the dedup gate rolls back whatever the run may have already created.
# HIMMEL-1753 round 2 (glm-2): rollback also removes the $slug.vbs shims this
# arm may have published — a failed arm must not leave orphaned shims behind
# for a later disarm to trip over. Only once the leg's task is confirmed GONE,
# though (query_task rc 1, trusted not-found): if the /delete itself failed,
# that task is still armed and pointing at its shim, and removing the shim
# THEN would leave an armed task referencing nothing — the exact state this
# file's publish/registration ordering exists to prevent. A query error
# (rc 2) keeps the shim for the same fail-safe reason; disarm removes both.
win_rollback_both() {
    local leg rc
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        run_schtasks /delete /tn "$leg" /f >/dev/null 2>&1 || true
        rc=0
        query_task "$leg" 2>/dev/null || rc=$?
        if [ "$rc" -eq 1 ]; then
            rm -f "$BAT_DIR/$(leg_slug "$leg").vbs"
        fi
    done
}

win_arm() {
    command -v cygpath >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: cygpath not on PATH; cannot convert paths for schtasks" >&2
        exit 2
    }
    command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
        exit 2
    }
    cadence_require_wsh "drift-fix-cadence" || exit 2
    require_payload
    local claude_bin
    if ! claude_bin=$(resolve_claude) || [ -z "$claude_bin" ]; then
        claude_unresolved_msg
        exit 2
    fi

    # Dedup guard, both legs. No /delete here: `/create /xml <file> /f` already
    # force-overwrites IN PLACE, so --force just skips the rc=3 refusal and lets
    # the replacement happen atomically AFTER all prep below has succeeded —
    # deleting first would leave no cadence at all if a later step failed.
    local leg leg_rc dedup_names=""
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        leg_rc=0
        query_task "$leg" || leg_rc=$?
        case "$leg_rc" in
            0)
                if [ "$FORCE" -eq 1 ]; then
                    echo "drift-fix-cadence: --force set; existing task $leg will be replaced by /create /f" >&2
                else
                    if [ -z "$dedup_names" ]; then dedup_names="$leg"; else dedup_names="$dedup_names, $leg"; fi
                fi
                ;;
            1) : ;;
            *) exit 2 ;;
        esac
    done
    if [ -n "$dedup_names" ]; then
        {
            echo "ERR drift-fix-cadence: already armed: $dedup_names."
            echo ""
            echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
            echo "    bash scripts/upstreams/drift-fix-cadence.sh status"
        } >&2
        exit 3
    fi

    pretrust_workspace

    local root_win claude_win
    if ! root_win=$(cygpath -w "$HIMMEL_ROOT" 2>&1); then
        echo "ERR drift-fix-cadence: cygpath -w failed for himmel root: $root_win" >&2; exit 4
    fi
    if ! claude_win=$(cygpath -w "$claude_bin" 2>&1); then
        echo "ERR drift-fix-cadence: cygpath -w failed for claude: $claude_win" >&2; exit 4
    fi
    # The .bat is launched by cmd.exe, which cannot run an extensionless target.
    # Existence alone is NOT sufficient: an npm-style `claude` shell shim (a
    # #!/usr/bin/env bash text file with no extension) exists on disk, passes an
    # existence check, and bakes an extensionless path into the .bat that cmd.exe
    # then cannot launch — the failure surfaces at 05:00 in a log nobody reads.
    # MSYS usually makes `cygpath -w` append .exe for a native claude.exe (so a
    # bare `command -v claude` resolves cleanly), but where `command -v` returned
    # a literal extensionless shim, cygpath leaves it extensionless. Require a
    # cmd-launchable extension ON TOP of existence, so a target cmd.exe cannot run
    # fails at ARM time, when someone is present to act on it (CR round-9).
    # REFUSE, don't warn (CR round-7 codex-1): arming into a known-broken state
    # is worse than not arming — the failure then surfaces at 05:00, in a log
    # nobody reads, on a cadence the operator believes is running.
    local claude_ext claude_launchable=0
    claude_ext=$(printf '%s' "${claude_win##*.}" | tr '[:upper:]' '[:lower:]')
    case "$claude_ext" in
        exe|cmd|bat|com) [ -f "$(cygpath -u "$claude_win" 2>/dev/null)" ] && claude_launchable=1 ;;
    esac
    if [ "$claude_launchable" -eq 0 ]; then
        {
            echo "ERR drift-fix-cadence: the resolved claude path is not a file cmd.exe can run:"
            echo "    posix : $claude_bin"
            echo "    win32 : $claude_win   <-- this is what the .bat would invoke"
            echo ""
            echo "It does not exist as a file, or it has no cmd-launchable extension"
            echo "(.exe/.cmd/.bat/.com): cmd.exe cannot run an extensionless shell shim,"
            echo "and MSYS's silent .exe-suffix resolution does not carry through cygpath"
            echo "on every setup. Refusing to arm a cadence that would fail at fire time."
            echo "Point DRIFTFIX_CLAUDE at the real executable and re-arm:"
            echo "    DRIFTFIX_CLAUDE=/c/path/to/claude.exe bash scripts/upstreams/drift-fix-cadence.sh arm --force"
        } >&2
        exit 2
    fi
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$BAT_DIR"

    local root_esc claude_esc model_esc
    root_esc=$(cadence_cmd_escape "$root_win")
    claude_esc=$(cadence_cmd_escape "$claude_win")
    model_esc=$(cadence_cmd_escape "$MODEL")

    # One iteration per leg. Dry-run only previews; the real path writes the
    # .bat, creates the task, and verifies it — rolling back BOTH legs on any
    # failure so arm never leaves one leg live and the other missing.
    local slug time bat_file vbs_file bat_win log_file log_win prompt_esc log_esc err_file verify_rc
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        slug=$(leg_slug "$leg")
        time=$(leg_time "$leg")
        bat_file="$BAT_DIR/$slug.bat"
        # wscript //B shim (HIMMEL-1753) lives beside the .bat; rollback + disarm
        # remove both. The Windows path cadence_vbs_path derives from $bat_win is
        # the same one emit_task_xml references, so write + reference agree.
        vbs_file="$BAT_DIR/$slug.vbs"
        log_file="$BAT_DIR/$slug.log"
        if ! bat_win=$(cygpath -w "$bat_file" 2>&1); then
            echo "ERR drift-fix-cadence: cygpath -w failed for $slug bat file: $bat_win" >&2
            win_rollback_both; exit 4
        fi
        if ! log_win=$(cygpath -w "$log_file" 2>&1); then
            echo "ERR drift-fix-cadence: cygpath -w failed for $slug log file: $log_win" >&2
            win_rollback_both; exit 4
        fi
        prompt_esc=$(cadence_cmd_escape "$(leg_prompt "$leg")")
        log_esc=$(cadence_cmd_escape "$log_win")

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY drift-fix-cadence: would write $bat_file:"
            emit_bat "$root_esc" "$claude_esc" "$prompt_esc" "$log_esc" "$model_esc" | sed 's/^/    /'
            echo "DRY drift-fix-cadence: would write $vbs_file:"
            cadence_vbs_wrapper "$bat_win" | sed 's/^/    /'
            echo "DRY drift-fix-cadence: would schtasks /create /tn $leg /xml <daily $time, StartWhenAvailable=true, InteractiveToken/LeastPrivilege> /f"
            emit_task_xml "$bat_win" "$time" | sed 's/^/    /'
            continue
        fi

        # Atomic runner publication (HIMMEL-1753 round 2, glm-2/3 class): emit
        # to a staged temp BESIDE the final path (same dir -> same filesystem
        # -> `mv` is an atomic rename, not a copy; mirrors codex-sweep's
        # publish discipline). Redirecting straight onto the final path let a
        # task firing concurrently with a re-arm read a half-written
        # .bat/.vbs; after the rename the final path only ever holds a
        # complete file (old or new). A non-regular final path is refused up
        # front: `mv` onto a directory squatting on a runner name "succeeds"
        # by moving the staged file INSIDE it, so a checked rename alone
        # cannot catch a target the task could never run. The shim promotes
        # FIRST — an already-armed task can safely run a new shim against the
        # still-current .bat while the pair is replaced.
        local bat_tmp vbs_tmp
        bat_tmp=$(mktemp "$BAT_DIR/.$slug.bat.XXXXXX")
        vbs_tmp=$(mktemp "$BAT_DIR/.$slug.vbs.XXXXXX")
        if ! emit_bat "$root_esc" "$claude_esc" "$prompt_esc" "$log_esc" "$model_esc" > "$bat_tmp"; then
            echo "ERR drift-fix-cadence: could not write staged runner for $slug" >&2
            rm -f "$bat_tmp" "$vbs_tmp"
            win_rollback_both; exit 4
        fi
        if ! cadence_vbs_wrapper "$bat_win" > "$vbs_tmp"; then
            echo "ERR drift-fix-cadence: could not write staged shim for $slug" >&2
            rm -f "$bat_tmp" "$vbs_tmp"
            win_rollback_both; exit 4
        fi
        for final_to_check in "$bat_file" "$vbs_file"; do
            if [ -e "$final_to_check" ] && [ ! -f "$final_to_check" ]; then
                echo "ERR drift-fix-cadence: $final_to_check exists and is not a regular file — refusing to publish" >&2
                rm -f "$bat_tmp" "$vbs_tmp"
                win_rollback_both; exit 4
            fi
        done
        if ! mv -f "$vbs_tmp" "$vbs_file"; then
            echo "ERR drift-fix-cadence: failed to publish shim to $vbs_file" >&2
            rm -f "$bat_tmp" "$vbs_tmp"
            win_rollback_both; exit 4
        fi
        if ! mv -f "$bat_tmp" "$bat_file"; then
            echo "ERR drift-fix-cadence: failed to publish runner to $bat_file" >&2
            rm -f "$bat_tmp"
            win_rollback_both; exit 4
        fi

        err_file=$(mktemp -t drift-fix-cadence.err.XXXXXX)
        if ! schtasks_create_xml "$leg" "$time" "$bat_win" "$err_file"; then
            echo "ERR drift-fix-cadence: schtasks /create $leg failed:" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            win_rollback_both
            exit 4
        fi
        rm -f "$err_file"

        # Post-arm verify: a /create that "succeeded" but produced a task with no
        # live next-run time is not armed in any useful sense. Roll back BOTH
        # legs — arm is all-or-nothing — rather than report a half-armed cadence.
        verify_rc=0
        query_task "$leg" || verify_rc=$?
        if [ "$verify_rc" -ne 0 ] || ! printf '%s' "$QUERY_OUT" | grep -qi 'Next Run Time'; then
            echo "ERR drift-fix-cadence: post-arm verify failed for $leg — rolling back both legs." >&2
            win_rollback_both
            echo "    Re-arm with: bash scripts/upstreams/drift-fix-cadence.sh arm --time $FIRE_TIME --resync-time $RESYNC_TIME --model $MODEL" >&2
            exit 4
        fi
    done

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "drift-fix-cadence: dry-run complete (no changes made)"
        return 0
    fi
    arm_summary "schtasks task"
}

win_status() {
    command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
        exit 2
    }
    echo "drift-fix-cadence status:"
    local leg slug rc next status_rc=0
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        slug=$(leg_slug "$leg")
        rc=0
        query_task "$leg" || rc=$?
        case "$rc" in
            0)
                next=$(printf '%s' "$QUERY_OUT" | grep -i 'Next Run Time' | head -1 | sed 's/^[^:]*: *//' | tr -d '\r') || true
                cadence_registered_status "$leg" " (next run: ${next:-?})" || status_rc=2
                ;;
            1) echo "not armed  $leg" ;;
            *) exit 2 ;;
        esac
        echo "  runner     $BAT_DIR/$slug.bat"
        status_log "$BAT_DIR/$slug.log"
    done
    return "$status_rc"
}

win_disarm() {
    command -v "$SCHTASKS_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$SCHTASKS_BIN' not on PATH (required on Windows)" >&2
        exit 2
    }
    local leg slug rc any_armed=0 err_file
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        slug=$(leg_slug "$leg")
        rc=0
        query_task "$leg" || rc=$?
        case "$rc" in
            1)
                if [ "$DRY_RUN" -eq 0 ]; then rm -f "$BAT_DIR/$slug.bat" "$BAT_DIR/$slug.vbs"; fi
                continue
                ;;
            2) exit 2 ;;
        esac
        any_armed=1
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY drift-fix-cadence: would schtasks /delete /tn $leg /f"
            echo "DRY drift-fix-cadence: would remove $BAT_DIR/$slug.bat + $BAT_DIR/$slug.vbs"
            continue
        fi
        err_file=$(mktemp -t drift-fix-cadence.err.XXXXXX)
        if ! run_schtasks /delete /tn "$leg" /f >/dev/null 2>"$err_file"; then
            echo "ERR drift-fix-cadence: schtasks /delete $leg failed:" >&2
            cat "$err_file" >&2
            rm -f "$err_file"
            exit 4
        fi
        rm -f "$err_file" "$BAT_DIR/$slug.bat" "$BAT_DIR/$slug.vbs"
    done
    if [ "$any_armed" -eq 0 ]; then
        echo "drift-fix-cadence: nothing armed — disarm is a no-op"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY drift-fix-cadence: no changes made"
    else
        echo "drift-fix-cadence: cadence disarmed"
    fi
}

# --------------------------------------------------------------------------
# POSIX (crontab)
# --------------------------------------------------------------------------

# Shell-quote for a cron command line: printf %q survives the /bin/sh re-parse
# at fire time. The extra % -> \% pass is cron(5) syntax — an unescaped % ends
# the command and the remainder becomes stdin.
cron_escape() {
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the crontab into CRON_TAB. Fail-CLOSED: any nonzero rc is fatal UNLESS it
# matches the trusted no-crontab-yet signature. A failed listing must never read
# as "nothing armed".
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t drift-fix-cadence.err.XXXXXX)
    set +e
    # LC_ALL=C pins the message shape so the signature grep isn't defeated by
    # translation.
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR drift-fix-cadence: crontab -l failed (rc=$rc) — refusing to treat as an empty crontab:" >&2
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

cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t drift-fix-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR drift-fix-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        echo "    rejected crontab left at: $tab_file" >&2
        rm -f "$err_file"
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

# Marker-tagged line for one leg (empty if not armed). Two literal greps, never
# a shared "HIMMEL-" prefix filter (unlike pipeline-cadence's TASK_PREFIX) —
# other himmel cadences share that prefix in the same crontab, and a prefix
# filter here would silently sweep entries this script does not own.
leg_existing() { printf '%s\n' "$CRON_TAB" | grep -F "# $1" || true; }

# The .sh runner mirrors the .bat: rotate the log, stamp the fire, cd into the
# checkout, bounded interactive claude run. All values arrive pre-quoted with
# printf %q. node_dir is prepended to PATH because an nvm-managed node is not on
# cron's minimal PATH even when the claude shim itself is absolute (#317).
# shellcheck disable=SC2016  # $log / $(date) are emitted literally for the runner's own /bin/sh
emit_runner() {
    local q_root="$1" q_claude="$2" q_prompt="$3" q_log="$4" q_model="$5" q_node_dir="${6:-}"
    printf '#!/bin/sh\n'
    printf '# drift-fix-cadence runner — generated by drift-fix-cadence.sh arm (HIMMEL-1323)\n'
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    if [ -n "$q_node_dir" ]; then
        printf 'PATH=%s:$PATH\nexport PATH\n' "$q_node_dir"
    fi
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then mv -f "$log" "$log.prev" 2>/dev/null; fi\n'
    printf '{\n'
    printf '    echo "[fired $(date "+%%Y-%%m-%%d %%H:%%M:%%S")]"\n'
    printf '    cd %s || exit 1\n' "$q_root"
    printf '    %s --model %s %s < /dev/null\n' "$q_claude" "$q_model" "$q_prompt"
    printf '    _rc=$?\n'
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
    # Exit WITH the payload's status (CR codex-3). The `{ … }` group is not a
    # subshell, so $_rc survives it. Without this the runner's last command is
    # the redirected group (effectively the `echo`), so it exited 0 no matter
    # how the run went — cron would mail nothing and any scheduler-level status
    # would read success on a failed drift repair. The .bat twin already ends
    # with `exit /b %ERRORLEVEL%`; this keeps the two platforms honest in the
    # same way.
    printf 'exit "$_rc"\n'
}

cron_arm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    require_payload
    local claude_bin node_dir node_bin
    if ! claude_bin=$(resolve_claude) || [ -z "$claude_bin" ]; then
        claude_unresolved_msg
        exit 2
    fi
    node_dir=""
    if node_bin=$(command -v node 2>/dev/null); then node_dir=$(dirname "$node_bin"); fi

    cron_read
    local leg existing dedup_names=""
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        existing=$(leg_existing "$leg")
        if [ -n "$existing" ]; then
            if [ "$FORCE" -eq 1 ]; then
                echo "drift-fix-cadence: --force set; replacing existing entry:" >&2
                printf '%s\n' "$existing" | sed 's/^/  /' >&2
            else
                if [ -z "$dedup_names" ]; then dedup_names="$leg"; else dedup_names="$dedup_names, $leg"; fi
            fi
        fi
    done
    if [ -n "$dedup_names" ]; then
        {
            echo "ERR drift-fix-cadence: already armed: $dedup_names."
            echo ""
            echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
            echo "    bash scripts/upstreams/drift-fix-cadence.sh status"
        } >&2
        exit 3
    fi

    pretrust_workspace

    local q_root q_claude q_model q_node_dir
    q_root=$(printf '%q' "$HIMMEL_ROOT")
    q_claude=$(printf '%q' "$claude_bin")
    q_model=$(printf '%q' "$MODEL")
    q_node_dir=$([ -n "$node_dir" ] && printf '%q' "$node_dir" || printf '')

    local slug time runner q_prompt q_log hh mm entry_line
    if [ "$DRY_RUN" -eq 1 ]; then
        for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
            slug=$(leg_slug "$leg")
            time=$(leg_time "$leg")
            runner="$BAT_DIR/$slug.sh"
            q_prompt=$(printf '%q' "$(leg_prompt "$leg")")
            q_log=$(printf '%q' "$BAT_DIR/$slug.log")
            hh="${time%:*}"; mm="${time#*:}"
            entry_line="$mm $hh * * * $(cron_escape "$runner") # $leg"
            echo "DRY drift-fix-cadence: would write $runner:"
            emit_runner "$q_root" "$q_claude" "$q_prompt" "$q_log" "$q_model" "$q_node_dir" | sed 's/^/    /'
            echo "DRY drift-fix-cadence: would install crontab entry:"
            echo "    $entry_line"
        done
        echo "drift-fix-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"

    # ONE rewrite: snapshot -> filter out any prior entry for EITHER leg ->
    # append BOTH new entries -> install once. There is no half-armed state
    # to roll back — either the whole rewrite lands or neither leg does.
    # No blank-line strip here (CR glm-2): blank lines are valid crontab
    # syntax (cron_install just pipes this to `crontab -`), and stripping
    # them ate the operator's own formatting on every arm/disarm cycle while
    # disarm's equivalent rewrite below never did. Symmetric with cron_disarm.
    local newtab
    newtab=$(mktemp -t drift-fix-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "# $LEG_DRIFT" | grep -vF "# $LEG_RESYNC" > "$newtab" || true

    # Snapshot any PRE-EXISTING runner content before overwriting it, so a
    # failed cron_install below can restore it byte-identical (CR codex-1;
    # mirrors the pin_text snapshot/restore idiom in apply-drift-bump.sh:
    # capture before write, restore on failure). A runner that does not
    # already exist gets no snapshot — see the restore comment below for why
    # that is fine.
    local snap_dir
    snap_dir=$(mktemp -d -t drift-fix-cadence.runner-snap.XXXXXX)

    # restore_runner_snapshots — restore each pre-existing runner's CONTENT
    # from $snap_dir, never delete it (CR glm-3). A failed install leaves the
    # crontab UNCHANGED, so under --force the previous entries are still live
    # and still point at exactly these paths; without this restore, the loop
    # below would already have overwritten those paths with the NEW,
    # never-installed config — the operator is told the arm FAILED while the
    # already-armed cadence has silently been mutated to fire the new body
    # next time it runs (CR codex-1). Deleting the runners instead — the
    # ordering cron_disarm documents (install must succeed BEFORE anything is
    # removed) — would be worse: that working cadence would fire a missing
    # file every night, silently: the arm failed AND the pre-existing arm
    # broke. A runner with no snapshot (first-arm failure, nothing
    # pre-existed) is simply left as emitted — harmless, since nothing
    # references it yet and the next successful arm overwrites it. Shared by
    # BOTH failure paths below (a write/chmod failure mid-loop, and a failed
    # cron_install) so the discipline is identical whichever one fires.
    restore_runner_snapshots() {
        local _leg _slug
        for _leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
            _slug=$(leg_slug "$_leg")
            if [ -f "$snap_dir/$_slug.sh" ]; then
                cp "$snap_dir/$_slug.sh" "$BAT_DIR/$_slug.sh"
                chmod +x "$BAT_DIR/$_slug.sh"
            fi
        done
    }

    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        slug=$(leg_slug "$leg")
        time=$(leg_time "$leg")
        runner="$BAT_DIR/$slug.sh"
        q_prompt=$(printf '%q' "$(leg_prompt "$leg")")
        q_log=$(printf '%q' "$BAT_DIR/$slug.log")
        [ -f "$runner" ] && cp "$runner" "$snap_dir/$slug.sh"
        # Under set -e (line 59) a write/chmod failure here (e.g. disk full on
        # leg 2 after leg 1 was already overwritten) would otherwise exit
        # WITHOUT the restore below — a pre-existing armed runner silently
        # mutated while the crontab still points at it (CR round 5; the same
        # class the win_arm emit_bat fix closed on Windows).
        if ! emit_runner "$q_root" "$q_claude" "$q_prompt" "$q_log" "$q_model" "$q_node_dir" > "$runner" \
           || ! chmod +x "$runner"; then
            echo "ERR drift-fix-cadence: could not write $runner — restoring any pre-existing runners." >&2
            restore_runner_snapshots
            rm -rf "$snap_dir"
            rm -f "$newtab"
            exit 4
        fi
        hh="${time%:*}"; mm="${time#*:}"
        printf '%s\n' "$mm $hh * * * $(cron_escape "$runner") # $leg" >> "$newtab"
    done
    if ! cron_install "$newtab"; then
        restore_runner_snapshots
        rm -rf "$snap_dir"
        echo "ERR drift-fix-cadence: crontab install failed — runners left in place at $BAT_DIR (any previously-armed cadence keeps working)." >&2
        exit 4
    fi
    rm -rf "$snap_dir"
    arm_summary "crontab entry"
}

cron_status() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    echo "drift-fix-cadence status:"
    local leg slug entry sched
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        slug=$(leg_slug "$leg")
        entry=$(leg_existing "$leg" | head -1)
        if [ -n "$entry" ]; then
            sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
            echo "ARMED      $leg (cron: $sched)"
        else
            echo "not armed  $leg"
        fi
        echo "  runner     $BAT_DIR/$slug.sh"
        status_log "$BAT_DIR/$slug.log"
    done
}

cron_disarm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    local leg existing any_existing=0
    for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
        existing=$(leg_existing "$leg")
        [ -n "$existing" ] && any_existing=1
    done
    if [ "$any_existing" -eq 0 ]; then
        # Trusted-empty read (cron_read exits 2 otherwise) — safe to sweep.
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$BAT_DIR/$(leg_slug "$LEG_DRIFT").sh" "$BAT_DIR/$(leg_slug "$LEG_RESYNC").sh"
        fi
        echo "drift-fix-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        for leg in "$LEG_DRIFT" "$LEG_RESYNC"; do
            existing=$(leg_existing "$leg")
            [ -n "$existing" ] && printf '%s\n' "$existing" | sed 's/^/DRY drift-fix-cadence: would remove crontab entry: /'
        done
        echo "DRY drift-fix-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t drift-fix-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "# $LEG_DRIFT" | grep -vF "# $LEG_RESYNC" > "$newtab" || true
    # Ordering invariant: the install must succeed BEFORE the runners are
    # removed — a failed install leaves the entries live and they must keep
    # pointing at files that exist.
    cron_install "$newtab" || exit 4
    rm -f "$BAT_DIR/$(leg_slug "$LEG_DRIFT").sh" "$BAT_DIR/$(leg_slug "$LEG_RESYNC").sh"
    echo "drift-fix-cadence: cadence disarmed"
}

# --------------------------------------------------------------------------

arm_summary() {
    local kind="$1" ext runner_drift runner_resync log_drift log_resync
    if [ "$PLATFORM" = "windows" ]; then ext="bat"; else ext="sh"; fi
    runner_drift="$BAT_DIR/$(leg_slug "$LEG_DRIFT").$ext"
    runner_resync="$BAT_DIR/$(leg_slug "$LEG_RESYNC").$ext"
    log_drift="$BAT_DIR/$(leg_slug "$LEG_DRIFT").log"
    log_resync="$BAT_DIR/$(leg_slug "$LEG_RESYNC").log"
    cat <<EOF
================================================================
drift-fix-cadence ARMED (HIMMEL-1323)

  $LEG_DRIFT   daily $FIRE_TIME local   — $kind — runner: $runner_drift
  $LEG_RESYNC  daily $RESYNC_TIME local — $kind — runner: $runner_resync
  Model:  $MODEL
  Repo:   $HIMMEL_ROOT
  Logs:   $log_drift
          $log_resync
          (one prior run kept as .log.prev, per leg)

  Each night:
    - $LEG_DRIFT runs /drift-fix: upgrade the installed vendor CLIs whose
      registry entry is marked upgrade.unattended:true, bump every repo
      pin apply-drift-bump.sh can bump, land it on PRIVATE main, then
      open a PUBLIC PR and STOP.
    - $LEG_RESYNC runs /fork-resync: rebase every BEHIND registry fork
      against upstream and audit it — a no-op most nights. The unattended
      run ALWAYS stops after each audit (clean, conflicted, or deliberately
      non-additive alike): it never pushes or opens anything, leaving that
      for a human instead.

  The public squash-merge stays yours — neither leg ever merges it.

  Status / disarm anytime:
      bash scripts/upstreams/drift-fix-cadence.sh status
      bash scripts/upstreams/drift-fix-cadence.sh disarm
================================================================
EOF
}

case "$PLATFORM:$SUBCMD" in
    windows:arm)    win_arm ;;
    windows:status) win_status ;;
    windows:disarm) win_disarm ;;
    posix:arm)      cron_arm ;;
    posix:status)   cron_status ;;
    posix:disarm)   cron_disarm ;;
esac
