# install-logon-task.ps1 — register / remove / report the logon scheduled task
# that auto-starts the Telegram bun bridge after a Windows reboot.
#
# Why this exists: the bun bridge is a detached process; nothing relaunches it
# after a reboot. This registers an idempotent -AtLogOn task that runs the
# canonical launcher (restart-bridge.ps1) at every logon. It does NOT start a
# poller itself (no 409 risk) — it only installs persistence. Single source of
# truth for the task definition (the README used to inline a copy-paste block
# that drifted). Operator-invoked by design — Claude's auto-mode does not create
# persistence on your behalf.
#
# Usage (from anywhere):
#   pwsh -File scripts/telegram/install-logon-task.ps1            # register (idempotent)
#   pwsh -File scripts/telegram/install-logon-task.ps1 -Status    # report, change nothing
#   pwsh -File scripts/telegram/install-logon-task.ps1 -Remove    # unregister
#   pwsh -File scripts/telegram/install-logon-task.ps1 -Repo C:/path/to/himmel
#
# Exit codes: 0 = success / report; 1 = usage/env error.

[CmdletBinding()]
param(
  [string]$Repo = $(if ($env:HIMMEL_REPO) { $env:HIMMEL_REPO } else { (Resolve-Path "$PSScriptRoot/../..").Path }),
  [switch]$Status,
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$TaskName = 'HimmelTelegramBridge'
$launcher = Join-Path $Repo 'scripts/telegram/restart-bridge.ps1'

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($Status) {
  if ($existing) {
    Write-Host "[install-logon-task] ${TaskName}: present (State=$($existing.State))"
    $existing.Actions | ForEach-Object { Write-Host "  action: $($_.Execute) $($_.Arguments)" }
  } else {
    Write-Host "[install-logon-task] ${TaskName}: NOT registered"
  }
  exit 0
}

if ($Remove) {
  if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[install-logon-task] $TaskName unregistered."
  } else {
    Write-Host "[install-logon-task] $TaskName not registered — nothing to remove."
  }
  exit 0
}

# Register (idempotent — -Force replaces any existing definition).
if (-not (Test-Path $launcher)) {
  Write-Error "launcher not found: $launcher — pass -Repo <himmel root>."
  exit 1
}
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) { $pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe' }

$action  = New-ScheduledTaskAction -Execute $pwshPath `
  -Argument ('-NoProfile -WindowStyle Hidden -File "{0}"' -f $launcher)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Start Telegram bun bridge (himmel) at logon' -Force | Out-Null

Write-Host "[install-logon-task] $TaskName registered (AtLogOn, user $env:USERNAME)."
Write-Host "  launcher: $launcher"
Write-Host "  remove with: pwsh -File scripts/telegram/install-logon-task.ps1 -Remove"
exit 0
