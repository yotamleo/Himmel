#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell.
#
# Blocks a tool call that registers an OS scheduler job which launches claude
# WITHOUT routing through the sanctioned arming tools — the exact shape that bit
# us in HIMMEL-647: a session hand-rolled
#     schtasks /create /tn HIMMEL-Arm-640-detector /tr <temp.bat> /sc ONCE ...
# where the .bat was just `"claude.exe" "load <handover> overnight mode"` — no
# `cd /d`, no Start In. schtasks fires a task with its DEFAULT cwd
# `C:\Windows\System32`, so claude relaunched from System32: a stray
# ~/.claude/projects/C--Windows-System32 project got registered, block-edit-on-
# main couldn't find .git, and relative handover paths broke. Two autonomous
# runs were wasted and had to be restarted by hand.
#
# The fix is to force scheduled claude relaunches back through the tools that
# already do it right:
#   - scripts/handover/arm-resume.sh   (emits `cd /d "$RESUME_CWD" || exit /b 1`,
#                                       pre-trusts the cwd HIMMEL-386, dedups,
#                                       names tasks HIMMEL-Resume-*, self-cleans)
#   - scripts/luna/pipeline-cadence.sh (same cwd + trust handling for the
#                                       recurring clip-pipeline cadence)
#   - scripts/handover/schedule-resume.sh (prints the command for review)
#
# Detection model (single tool-call command text, case-insensitive):
#   BLOCK when the command BOTH
#     (a) registers a scheduler job — `schtasks /create`,
#         `Register-ScheduledTask`/`Register-ScheduledJob`, a `crontab` write,
#         or `at <time>`, AND
#     (b) launches the claude EXECUTABLE (claude.exe/.cmd/.ps1, a `/claude`
#         or `\claude` binary path, or a bare `claude "<prompt>"` at command
#         position) — but NOT a mere `.claude/` directory reference,
#   UNLESS the command routes through a sanctioned arming script (allow).
#
# Known limitation (consciously accepted — like block-read-secrets, this guard
# targets the accidental shape, not a determined bypass): if the rogue arm is
# SPLIT across two tool calls (write the .bat in call 1, `schtasks /create
# /tr that.bat` in call 2), call 2 carries no `claude` token and is not caught.
# The HIMMEL-647 incident did both in ONE PowerShell call, which IS caught.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow (default)
#   2 — block; stderr is shown to Claude and the user
#
# Bypass: set ROGUE_SCHEDULE_OK=1 in the shell that launched Claude Code
# (Claude cannot inject env vars into hooks). Session-sticky; restart to
# re-enable. Or comment the hook in .claude/settings.json.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "block-rogue-claude-schedule: jq not on PATH — refusing to evaluate; install jq or comment the hook in .claude/settings.json" >&2
    exit 2
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$tool" in
    Bash|PowerShell) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# Lower-case once so every match below is plain (case-insensitive) without
# per-grep -i. All tokens we match (schtasks, register-scheduledtask, crontab,
# at, claude.exe, arm-resume.sh) are ASCII. ALSO flatten newlines/CRs to spaces:
# grep is line-oriented, so on a multi-line command an `^`-anchored arm (the `at`
# command-position check) would match the start of ANY line — a benign multi-line
# `git commit -m "...claude...<newline>at 0430..."` would false-block. Flattening
# makes `^`/`$` mean true start/end of the whole command and keeps unrelated
# tokens on different lines from jointly tripping the AND-gate.
cmd_lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]' | tr '\n\r' '  ')

# Allow short-circuit: the command routes through a sanctioned arming tool,
# which already handles cwd + workspace-trust + dedup. (arm-resume.sh runs its
# OWN schtasks/at/crontab in a CHILD process the hook never sees, so this only
# guards against a future caller that mentions both in one tool command.)
if printf '%s' "$cmd_lc" | grep -qE 'arm-resume\.sh|pipeline-cadence\.sh|schedule-resume\.sh'; then
    exit 0
fi

# (a) Does the command register a scheduler job?
is_scheduler_create() {
    local c="$1"
    # schtasks /create — both tokens present (order-independent in the command).
    if printf '%s' "$c" | grep -q 'schtasks' && printf '%s' "$c" | grep -q '/create'; then
        return 0
    fi
    if printf '%s' "$c" | grep -qE 'register-scheduled(task|job)'; then return 0; fi
    # crontab as a command (write or install); `crontab -l` reads — harmless
    # here because (b) launches_claude won't be true for a pure read.
    if printf '%s' "$c" | grep -qE '(^|[[:space:];|&(])crontab([[:space:]]|$)'; then return 0; fi
    # POSIX `at <timespec>` / `at -t|-f|...`. The `at` must sit at a command
    # position (line start or right after a ; & | ( separator, modulo spaces) so
    # prose like `git commit -m "... claude at 0430"` — where `at` follows a word
    # — is not mistaken for the scheduler.
    if printf '%s' "$c" | grep -qE '([;&|(]|^)[[:space:]]*at[[:space:]]+(-[a-z]|now|noon|midnight|[0-9])'; then return 0; fi
    return 1
}

# (b) Does the command launch the claude EXECUTABLE (not just a .claude/ path)?
launches_claude() {
    local c="$1"
    # claude.exe / claude.cmd / claude.ps1
    if printf '%s' "$c" | grep -qE 'claude\.(exe|cmd|ps1)'; then return 0; fi
    # a /claude or \claude binary PATH — the slash/backslash must sit IMMEDIATELY
    # before `claude`, so `~/.claude/...` (a `.` precedes claude) never matches.
    if printf '%s' "$c" | grep -qE '[/\]claude([[:space:]"'\''`]|$)'; then return 0; fi
    # a bare `claude "<prompt>"` at a command position OR right after a quote
    # (e.g. a schtasks /tr "claude ..." value).
    if printf '%s' "$c" | grep -qE '(^|[[:space:];|&("'\''])claude[[:space:]"'\'']'; then return 0; fi
    return 1
}

if is_scheduler_create "$cmd_lc" && launches_claude "$cmd_lc"; then
    [ "${ROGUE_SCHEDULE_OK:-0}" = "1" ] && exit 0
    {
        echo "⛔ block-rogue-claude-schedule: refusing a raw scheduler-arm of claude."
        echo "    A hand-rolled schtasks/crontab/at job that launches claude fires with"
        echo "    its DEFAULT cwd (C:\\Windows\\System32 on Windows), so the relaunch runs"
        echo "    OUTSIDE the repo — wasting the run and registering a stray System32"
        echo "    project (HIMMEL-647)."
        echo ""
        echo "    Use the sanctioned tool, which sets cwd, pre-trusts it, dedups and"
        echo "    self-cleans:"
        echo "        bash scripts/handover/arm-resume.sh --time <HH:MM|smart|auto> \\"
        echo "             --handover <path> [--worktree <type/slug>]"
        echo "    or, for the recurring clip-pipeline cadence:"
        echo "        bash scripts/luna/pipeline-cadence.sh arm"
        echo ""
        echo "    To bypass intentionally, set ROGUE_SCHEDULE_OK=1 in the shell that"
        echo "    launched Claude Code (env vars can't be injected per-call):"
        echo "        ROGUE_SCHEDULE_OK=1 claude"
        echo "    Session-sticky. Restart without it to re-enable the guard."
    } >&2
    exit 2
fi

exit 0
