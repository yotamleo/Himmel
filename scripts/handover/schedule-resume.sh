#!/usr/bin/env bash
# schedule-resume.sh - emit the right scheduler invocation to relaunch
# `claude` overnight after a usage-cooldown gap.
#
# Usage:
#   bash scripts/handover/schedule-resume.sh <RESUME_TIME_LOCAL> <HANDOVER_PATH>
#
# Args:
#   RESUME_TIME_LOCAL  HH:MM (24h, operator's local time). Same-day if in the
#                      future, next-day if already past.
#   HANDOVER_PATH      Path to the handover file to resume from. Pasted into
#                      the claude prompt so the next session picks up state.
#
# Behavior: prints the platform-appropriate command to schedule a one-shot
# relaunch of `claude` with a self-contained resume prompt. Does NOT execute
# the command - the operator copies, eyeballs, and runs it themselves. This
# is deliberate: scheduled-task creation touches the OS task scheduler
# (schtasks on Windows, `at` or crontab on POSIX) and the operator should
# see exactly what is being installed.
#
# Platforms:
#   - Windows (Git Bash / MSYS / CYGWIN / WSL): emits `schtasks /create ...`
#   - macOS / Linux:                            emits `at <time> <<< ...`
#                                               (or crontab fallback if `at`
#                                               is unavailable)
#
# Cooldown context (Anthropic):
# - Usage quota window is rolling 5 hours (verify per current docs).
# - After hitting the limit, plan ~5 hours before retry; schedule a touch
#   later to be safe. The operator picks RESUME_TIME_LOCAL with that buffer.
#
# Companion docs: docs/handover/overnight-mode.md "Phase 6.5".

set -uo pipefail

if [ "$#" -lt 2 ]; then
    cat >&2 <<EOF
usage: bash scripts/handover/schedule-resume.sh <RESUME_TIME_LOCAL> <HANDOVER_PATH>
example: bash scripts/handover/schedule-resume.sh 07:22 handovers/yotam/himmel/epics/HIMMEL-70-github-warp/next-session-12.md
EOF
    exit 2
fi

RESUME_TIME="$1"
HANDOVER_PATH="$2"

# Validate RESUME_TIME shape: HH:MM (24h).
if ! [[ "$RESUME_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERROR: RESUME_TIME must be HH:MM (24h), got: $RESUME_TIME" >&2
    exit 2
fi

# Validate HANDOVER_PATH exists - the scheduled task is useless if the
# resume file does not exist when the relaunch fires.
if [ ! -f "$HANDOVER_PATH" ]; then
    echo "ERROR: handover file not found: $HANDOVER_PATH" >&2
    exit 2
fi

# Self-contained resume prompt. Single line so it survives both schtasks
# (CMD quoting) and `at` (heredoc). Avoid backticks and $() so the operator's
# shell does not pre-interpolate anything before scheduling.
RESUME_PROMPT="load $HANDOVER_PATH overnight mode"

# Platform detection. Prefer OSTYPE (set by bash); fall back to uname.
detect_platform() {
    case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
        msys*|cygwin*|win32*|MINGW*) echo "windows" ;;
        linux*|Linux*)               echo "linux" ;;
        darwin*|Darwin*)             echo "macos" ;;
        *)                           echo "unknown" ;;
    esac
}

platform=$(detect_platform)

case "$platform" in
    windows)
        # schtasks /create: ONETIME at the given /st HH:MM. We tag with a
        # unique task name keyed off the handover path so multiple pending
        # resumes don't collide. /F overwrites silently if the operator
        # re-schedules the same handover.
        # Resume artifact: a tiny .bat in %TEMP% that runs `claude` with
        # the prompt. schtasks /tr requires a quoted command and CMD has its
        # own quoting rules, so the .bat indirection keeps the schtasks
        # invocation human-readable.
        # shellcheck disable=SC1003  # the `\\` in tr SET1 is two backslashes (single quotes), which tr collapses to one literal `\` - intentional, NOT a quoting error.
        task_name="HIMMEL-Resume-$(printf '%s' "$HANDOVER_PATH" | tr '/\\' '__' | tr -cd '[:alnum:]_-')"
        bat_path="%TEMP%\\himmel-resume-$task_name.bat"
        cat <<EOF
# Step 1 - write the resume launcher (one line, CMD syntax):
echo claude "$RESUME_PROMPT" > "$bat_path"

# Step 2 - register the one-shot Task Scheduler entry:
schtasks /create /tn "$task_name" /tr "$bat_path" /sc ONCE /st $RESUME_TIME /f

# To inspect / cancel:
#   schtasks /query /tn "$task_name"
#   schtasks /delete /tn "$task_name" /f
EOF
        ;;
    linux|macos)
        # Prefer `at` (one-shot, exactly the semantics we want). Falls back
        # to crontab if `at` is unavailable - but crontab is recurring, so
        # we add a self-deleting wrapper to keep one-shot semantics.
        if command -v at >/dev/null 2>&1; then
            cat <<EOF
# Step 1 - schedule via 'at':
at $RESUME_TIME <<'CMD'
claude "$RESUME_PROMPT"
CMD

# To inspect / cancel:
#   atq                    # list pending
#   atrm <job-id>          # remove
EOF
        else
            # Crontab fallback. Compute today's date components so the entry
            # fires once on the next occurrence then we manually clean up.
            # Operator gets a warning so they know it's NOT auto-self-deleting.
            hh="${RESUME_TIME%:*}"
            mm="${RESUME_TIME#*:}"
            cat <<EOF
# WARNING: 'at' is not installed; falling back to crontab. crontab entries
# are RECURRING - this fires daily at $RESUME_TIME until you remove it.
# Step 1 - add a one-line entry to your crontab:
(crontab -l 2>/dev/null; echo "$mm $hh * * * claude \"$RESUME_PROMPT\"") | crontab -

# Step 2 - REMOVE the entry after it has fired once:
crontab -l | grep -v 'HIMMEL-Resume' | crontab -

# To install 'at' for one-shot scheduling instead:
#   Debian/Ubuntu:  sudo apt install at && sudo systemctl enable --now atd
#   macOS:          'at' is preinstalled; enable atd via 'sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.atrun.plist'
EOF
        fi
        ;;
    *)
        echo "ERROR: unknown platform (OSTYPE=$OSTYPE) - cannot emit scheduler command" >&2
        echo "Supported: Windows (Git Bash/MSYS/Cygwin/WSL), Linux, macOS." >&2
        exit 2
        ;;
esac

cat <<EOF

---
Verify before running:
- Resume time: $RESUME_TIME (your local time)
- Handover:    $HANDOVER_PATH
- Prompt:      $RESUME_PROMPT
- Platform:    $platform

For sessions that must survive even local-machine death, prefer a remote
agent via /schedule (see docs/handover/overnight-mode.md Phase 6.5).
EOF
