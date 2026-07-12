# register-qmd-daemon-logon.ps1 - register a per-user ONLOGON scheduled task
# that runs ensure-qmd-daemon.ps1, so the shared qmd HTTP MCP daemon
# (localhost:8181) is back up after every reboot without waiting for the
# first Claude session's SessionStart hook (HIMMEL-928).
#
# Lean-invoke, operator-run (HIMMEL-177): registration is a one-shot per
# machine, never a hook. Idempotent - re-running overwrites the existing
# task (-Force). Windows-only by design (the daemon-at-boot convenience);
# POSIX machines rely on the SessionStart hook. Remove with:
#   Unregister-ScheduledTask -TaskName 'qmd-mcp-daemon' -Confirm:$false
# (the exact command for a custom -TaskName is echoed after registration).
#
# Single-operator scope: the task registers in the ROOT Task Scheduler
# folder, and task identity is TaskPath+TaskName - on a genuinely
# multi-operator machine a second user registering the same default name
# replaces the first user's task. Out of scope for this personal-harness
# tool; pass a distinct -TaskName per user if you truly share a machine.
#
# Run from the PRIMARY checkout, not a worktree - the task stores an absolute
# path to ensure-qmd-daemon.ps1 next to this script, and a pruned worktree
# would leave the task pointing at nothing.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TaskName = 'qmd-mcp-daemon'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ensure = Join-Path $PSScriptRoot 'ensure-qmd-daemon.ps1'
if (-not (Test-Path $ensure)) {
    throw "ensure-qmd-daemon.ps1 not found next to this script: $ensure"
}

# Prefer pwsh (the twin targets PowerShell 7+); Windows PowerShell fallback.
# -CommandType Application: a profile-defined alias/function named pwsh
# would otherwise win command precedence and yield an unusable .Source.
$shell = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $shell) { $shell = Get-Command powershell -CommandType Application -ErrorAction Stop | Select-Object -First 1 }

if ($PSCmdlet.ShouldProcess($TaskName, "register ONLOGON scheduled task -> $ensure")) {
    $action = New-ScheduledTaskAction -Execute $shell.Source `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ensure`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Force | Out-Null
    Write-Host "Registered scheduled task '$TaskName' (at logon: $($shell.Name) -File $ensure)"
    Write-Host "Remove with: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
}
