#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-rogue-claude-schedule.sh (HIMMEL-647).
#
# Usage: bash scripts/hooks/test-block-rogue-claude-schedule.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-rogue-claude-schedule.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

run_case() {
    local input="$1"
    local env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        printf '%s' "$input" | env "$env_assign" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash()  { printf '{"tool_name":"Bash","tool_input":{"command":%s}}'  "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh()  { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# The actual HIMMEL-647 incident: a single PowerShell call that wrote a claude
# launcher .bat AND registered it with schtasks /create — no cd, fires from
# System32. (Literal PowerShell text — the $claude is intentionally unexpanded.)
# shellcheck disable=SC2016
INCIDENT='$claude = "C:\Users\yotam\.local\bin\claude.exe"
Set-Content -Path $bat640 -Value "`"$claude`" `"load /c/.../next-session.md overnight mode`"" -Encoding ASCII
schtasks /create /tn "HIMMEL-Arm-640-detector" /tr "$bat640" /sc ONCE /st 04:30 /f'

# --- BLOCK cases (expect rc=2) ---
assert_rc "HIMMEL-647 incident (PowerShell)"      2 "$(run_case "$(j_pwsh "$INCIDENT")")"
assert_rc "schtasks /create /tr claude.exe"       2 "$(run_case "$(j_bash 'schtasks /create /tn X /tr "C:\\Users\\u\\.local\\bin\\claude.exe load h" /sc ONCE /st 04:30 /f')")"
assert_rc "schtasks /create bareword claude"      2 "$(run_case "$(j_bash 'schtasks /create /tn X /tr "claude \"load h\"" /sc ONCE /st 09:00 /f')")"
assert_rc "Register-ScheduledTask claude.exe"     2 "$(run_case "$(j_pwsh 'Register-ScheduledTask -TaskName X -Action (New-ScheduledTaskAction -Execute "claude.exe" -Argument "load h")')")"
assert_rc "Register-ScheduledJob claude.exe"      2 "$(run_case "$(j_pwsh 'Register-ScheduledJob -Name X -ScriptBlock { claude.exe "load h" }')")"
assert_rc "schtasks /create /tr claude.cmd"       2 "$(run_case "$(j_bash 'schtasks /create /tn X /tr "C:\\Users\\u\\.local\\bin\\claude.cmd load h" /sc ONCE /st 09:00 /f')")"
assert_rc "crontab install claude"                2 "$(run_case "$(j_bash 'echo "30 4 * * * /home/u/.local/bin/claude \"load h\"" | crontab -')")"
assert_rc "at now claude"                         2 "$(run_case "$(j_bash 'echo "claude \"load h\"" | at now + 1 hour')")"

# --- ALLOW cases (expect rc=0) ---
assert_rc "sanctioned arm-resume.sh"              0 "$(run_case "$(j_bash 'bash scripts/handover/arm-resume.sh --time 04:30 --handover /c/h/next-session.md')")"
assert_rc "sanctioned pipeline-cadence arm"       0 "$(run_case "$(j_bash 'bash scripts/luna/pipeline-cadence.sh arm --harvest-time 02:00')")"
assert_rc "schtasks /query (read, no create)"     0 "$(run_case "$(j_bash 'schtasks /query /tn HIMMEL-Pipeline-Harvest /fo LIST')")"
assert_rc "schtasks /create non-claude task"      0 "$(run_case "$(j_bash 'schtasks /create /tn Backup /tr "robocopy C:\\a C:\\b" /sc DAILY /st 01:00 /f')")"
assert_rc "crontab -l (read)"                     0 "$(run_case "$(j_bash 'crontab -l')")"
assert_rc "plain claude launch (not scheduled)"   0 "$(run_case "$(j_bash 'claude "do a thing"')")"
assert_rc "cat ~/.claude/settings.json"           0 "$(run_case "$(j_bash 'cat ~/.claude/settings.json')")"
assert_rc "git commit msg mentioning claude+at"   0 "$(run_case "$(j_bash 'git commit -m "fire claude at 0430"')")"
# Multi-line prose must NOT false-block: grep is line-oriented, so an `at 0430`
# at the START of a body line + `claude` on another line previously tripped the
# `^`-anchored at-arm. cmd_lc flattens newlines so `^` means true start-of-cmd.
assert_rc "multi-line commit claude+at (prose)"   0 "$(run_case "$(j_bash "$(printf 'git commit -m "fix claude bug\nat 0430 it still failed"')")")"
# scheduler-create whose only claude token is a .claude/ DIRECTORY (a backup
# task), not the executable → ALLOW (predicate (b) discriminates exe vs dir).
assert_rc "schtasks /create backup of .claude"    0 "$(run_case "$(j_bash 'schtasks /create /tn Backup /tr "robocopy C:\\Users\\u\\.claude C:\\backup" /sc DAILY /st 01:00 /f')")"
assert_rc "sanctioned schedule-resume.sh"         0 "$(run_case "$(j_bash 'bash scripts/handover/schedule-resume.sh --time 04:30 --handover /c/h.md')")"
assert_rc "non-Bash/PS tool ignored"              0 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"x"}}')"

# --- Escape hatch (expect rc=0 even on an otherwise-blocked command) ---
assert_rc "incident + ROGUE_SCHEDULE_OK=1"        0 "$(run_case "$(j_pwsh "$INCIDENT")" "ROGUE_SCHEDULE_OK=1")"

if [ "$FAILED" -ne 0 ]; then
    echo "FAILED: $FAILED case(s)"
    exit 1
fi
echo "All block-rogue-claude-schedule cases passed."
exit 0
