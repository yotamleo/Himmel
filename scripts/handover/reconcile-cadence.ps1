<#
.SYNOPSIS
  Windows twin of reconcile-cadence.sh (HIMMEL-1880): arm/disarm/status the
  periodic seat-liveness reconcile on Task Scheduler.

.DESCRIPTION
  Registers ONE scheduled task, HIMMEL-ReconcileCadence, that fires every
  -IntervalMin minutes and runs `reconcile-cadence.sh run` under Git Bash.
  Register-ScheduledTask -Force replaces an existing task, so arming twice
  yields one job. The tick itself (logging, the --report classification) is
  the bash script's; this file only owns the scheduler.

  The task's action is a hidden powershell.exe wrapper (a bare bash.exe Exec
  flashes a console window) that prepends Git's usr\bin and bin to PATH, so
  the non-login bash resolves GNU coreutils ahead of System32 namesakes.

.PARAMETER Action
  Arm | Disarm | Status | Run (Run invokes one tick in the foreground).

.PARAMETER IntervalMin
  Minutes between ticks (2..59, default 10). Must not be shorter than
  RECONCILE_GRACE_SECS (default 120) and must exceed
  RECONCILE_CADENCE_TIMEOUT_SECS (default 110). Both, and any other override
  the tick reads, are baked into the task when set.

.PARAMETER BashPath
  Git Bash bash.exe. Default: derived from git.exe on PATH (never the WSL
  System32 bash.exe).

.EXAMPLE
  pwsh -File scripts\handover\reconcile-cadence.ps1 -Action Arm
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Arm', 'Disarm', 'Status', 'Run')][string]$Action,
    [ValidateRange(2, 59)][int]$IntervalMin = 10,
    [string]$BashPath
)

$ErrorActionPreference = 'Stop'
$TaskName = 'HIMMEL-ReconcileCadence'
$Runner = Join-Path $PSScriptRoot 'reconcile-cadence.sh'

function Resolve-GitBash {
    if ($BashPath) { return $BashPath }
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    # <GitRoot>\cmd\git.exe or <GitRoot>\bin\git.exe -> <GitRoot>\bin\bash.exe
    $gitRoot = Split-Path -Parent (Split-Path -Parent $git)
    $bash = Join-Path $gitRoot 'bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) { throw "Git Bash not found at $bash; pass -BashPath" }
    return $bash
}

function Quote-Ps([string]$s) { "'" + ($s -replace "'", "''") + "'" }

switch ($Action) {
    'Run' {
        & (Resolve-GitBash) $Runner run
        exit $LASTEXITCODE
    }
    'Arm' {
        # Same limits as reconcile-cadence.sh arm, from the same env overrides.
        $timeoutSecs = if ($env:RECONCILE_CADENCE_TIMEOUT_SECS) { [int]$env:RECONCILE_CADENCE_TIMEOUT_SECS } else { 110 }
        $graceSecs = if ($env:RECONCILE_GRACE_SECS) { [int]$env:RECONCILE_GRACE_SECS } else { 120 }
        if ($IntervalMin * 60 -lt $graceSecs) { throw "IntervalMin $IntervalMin is shorter than RECONCILE_GRACE_SECS=${graceSecs}s" }
        if ($IntervalMin * 60 -le $timeoutSecs) { throw "IntervalMin $IntervalMin does not exceed the ${timeoutSecs}s tick timeout" }
        $bash = Resolve-GitBash
        $gitRoot = Split-Path -Parent (Split-Path -Parent $bash)
        $pathPrefix = (Join-Path $gitRoot 'usr\bin') + ';' + (Join-Path $gitRoot 'bin') + ';'
        # Bake the overrides arm validated or the tick reads, as the cron entry does.
        $envSet = ''
        foreach ($v in 'RECONCILE_GRACE_SECS', 'RECONCILE_UNPROBEABLE_CEILING_SECS', 'RECONCILE_CADENCE_TIMEOUT_SECS', 'RECONCILE_CADENCE_LOG', 'WORKER_BRIDGE_ROOT', 'BRIDGE_ROOT') {
            $val = [Environment]::GetEnvironmentVariable($v)
            if ($val) { $envSet += '$env:' + $v + ' = ' + (Quote-Ps $val) + '; ' }
        }
        $command = $envSet + '$env:PATH = ' + (Quote-Ps $pathPrefix) + ' + $env:PATH; & ' + (Quote-Ps $bash) + ' ' + (Quote-Ps ($Runner -replace '\\', '/')) + ' run; exit $LASTEXITCODE'
        $actionObj = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -Command "' + ($command -replace '"', '\"') + '"')
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
        Register-ScheduledTask -TaskName $TaskName -Action $actionObj -Trigger $trigger -Settings $settings -Description 'HIMMEL-1880 periodic seat-liveness reconcile' -Force | Out-Null
        Write-Output "reconcile-cadence: armed every ${IntervalMin}m (task $TaskName)"
    }
    'Disarm' {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        }
        Write-Output 'reconcile-cadence: disarmed'
    }
    'Status' {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) { Write-Output "reconcile-cadence: armed: $TaskName ($($task.State))" }
        else { Write-Output 'reconcile-cadence: not armed' }
    }
}
