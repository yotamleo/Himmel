# test-uninstall.ps1 — PowerShell smoke test for scripts/uninstall.ps1
# (HIMMEL-227 offboard; PS sibling of test-uninstall.sh, CR round 1).
# State-touching invocations point $env:TELEGRAM_CHANNEL_DIR + $env:BRIDGE_ROOT
# at temp dirs and pass -SkipTasks -SkipPlugins -SkipHooks, so the operator's
# real bridge, scheduled tasks, plugins, and git hooks are never touched.
# Deliberate exceptions: test 5 points TELEGRAM_CHANNEL_DIR at $HOME on
# purpose to prove the rm guard refuses it (nothing is removed); test 6 omits
# -SkipTasks but shadows Get-ScheduledTask with a throwing function in the
# child session (functions outrank cmdlets — no real task query ever runs);
# test 6b shadows Test-ScheduledTaskExists (the schtasks.exe rc-based wrapper
# used for exact-name pre-checks) + Get-ScheduledTask + Unregister-ScheduledTask
# so no real CIM queries or binary calls happen.
# The bridge-stop tests (7-9) run only against a temp-dir bun.cmd stub
# prepended to PATH (or a bun-free PATH) + a supervisor.pid seeded in a temp
# BRIDGE_ROOT with an impossible PID.
#
# Run: pwsh -NoProfile -File scripts/test-uninstall.ps1

$ErrorActionPreference = 'Continue'
$script:Failed = 0
$Cli = Join-Path $PSScriptRoot 'uninstall.ps1'

function Assert-Rc {
    param([string]$Label, [int]$Expected, [int]$Actual)
    if ($Actual -eq $Expected) {
        Write-Host "PASS $Label (rc=$Actual)"
    } else {
        Write-Host "FAIL $Label -- expected rc=$Expected, got rc=$Actual"
        $script:Failed++
    }
}

function Assert-Has {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) {
        Write-Host "PASS $Label"
    } else {
        Write-Host "FAIL $Label -- output missing: $Needle"
        $script:Failed++
    }
}

function Assert-NotHas {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) {
        Write-Host "FAIL $Label -- output unexpectedly contains: $Needle"
        $script:Failed++
    } else {
        Write-Host "PASS $Label"
    }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('himmel-uninstall-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Tmp | Out-Null

$SavedChannelDir = $env:TELEGRAM_CHANNEL_DIR
$SavedBridgeRoot = $env:BRIDGE_ROOT

function New-State {
    $script:Channel = Join-Path $Tmp 'channels\telegram'
    $script:Bridge  = Join-Path $Tmp 'bridge'
    Remove-Item -Recurse -Force $script:Channel, $script:Bridge -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $script:Bridge 'sessions\S1') | Out-Null
    New-Item -ItemType Directory -Force $script:Channel | Out-Null
    Set-Content -Path (Join-Path $script:Channel '.env') -Value 'TELEGRAM_BOT_TOKEN=123:abc'
    Set-Content -Path (Join-Path $script:Channel 'access.json') -Value '{"allowFrom":["42"]}'
    Set-Content -Path (Join-Path $script:Bridge 'sessions\S1\inbox.jsonl') -Value 'x'
}

# Resolved up front so Invoke-Uninstall still works while a test (9) runs
# with a stripped-down $env:PATH that cannot find pwsh by name.
$PwshExe = (Get-Command pwsh).Source

function Invoke-Uninstall {
    # Pipes empty stdin so the child sees IsInputRedirected=$true -- the
    # fail-closed branch is reachable and no test can hang on Read-Host.
    param([string[]]$CliArgs = @())
    $out = ('' | & $PwshExe -NoProfile -File $Cli @CliArgs 2>&1 | Out-String)
    $script:Rc = $LASTEXITCODE
    return $out
}

try {
    # 1. fail-closed: non-interactive without -Yes aborts (rc=2), removes nothing
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    $out = Invoke-Uninstall @('-SkipTasks', '-SkipPlugins', '-SkipHooks')
    Assert-Rc 'non-interactive without -Yes aborts' 2 $script:Rc
    Assert-Has 'abort message names -Yes' 'non-interactive run without -Yes' $out
    if ((Test-Path (Join-Path $Channel 'access.json')) -and (Test-Path $Bridge)) {
        Write-Host 'PASS nothing removed on abort'
    } else {
        Write-Host 'FAIL state was removed despite abort'; $script:Failed++
    }

    # 2. dry-run: prints actions, removes nothing, needs no confirmation
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    $out = Invoke-Uninstall @('-DryRun', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
    Assert-Rc 'dry-run exits 0' 0 $script:Rc
    Assert-Has 'dry-run prints DRY rm for channel dir' "DRY: Remove-Item -Recurse -Force $Channel" $out
    Assert-Has 'dry-run prints DRY rm for bridge root' "DRY: Remove-Item -Recurse -Force $Bridge" $out
    if ((Test-Path (Join-Path $Channel 'access.json')) -and (Test-Path (Join-Path $Bridge 'sessions\S1\inbox.jsonl'))) {
        Write-Host 'PASS dry-run removed nothing'
    } else {
        Write-Host 'FAIL dry-run removed state'; $script:Failed++
    }
    Assert-Has 'dry-run reports bridge not running' 'bridge not running' $out

    # 3. -Yes: removes telegram + bridge state (skips tasks/plugins/hooks)
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    $out = Invoke-Uninstall @('-Yes', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
    Assert-Rc '-Yes run exits 0' 0 $script:Rc
    if ((Test-Path $Channel) -or (Test-Path $Bridge)) {
        Write-Host 'FAIL -Yes run left state behind'; $script:Failed++
    } else {
        Write-Host 'PASS telegram pairing + bridge state removed'
    }
    Assert-Has '-Yes run notes BotFather revocation' 'revoke the token via @BotFather' $out
    Assert-Has 'skip-tasks honored' 'kept (-SkipTasks)' $out
    Assert-Has 'skip-plugins honored' 'kept (-SkipPlugins)' $out
    Assert-Has 'skip-hooks honored' 'kept (-SkipHooks)' $out

    # 4. -KeepTelegramState: state survives a -Yes run
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    $out = Invoke-Uninstall @('-Yes', '-KeepTelegramState', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
    Assert-Rc '-KeepTelegramState run exits 0' 0 $script:Rc
    if ((Test-Path (Join-Path $Channel 'access.json')) -and (Test-Path $Bridge)) {
        Write-Host 'PASS telegram state kept'
    } else {
        Write-Host 'FAIL telegram state removed despite -KeepTelegramState'; $script:Failed++
    }

    # 5. rm guard: refuses $HOME even when asked
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $HOME
    $env:BRIDGE_ROOT = $Bridge
    $out = Invoke-Uninstall @('-Yes', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
    Assert-Rc 'HOME-as-target run exits 0' 0 $script:Rc
    Assert-Has 'refuses to rm HOME' 'refusing to remove suspicious path' $out
    if (Test-Path $HOME) {
        Write-Host 'PASS HOME survived'
    } else {
        Write-Host 'FAIL HOME gone (!)'; $script:Failed++
    }
    Assert-NotHas 'guard refusal not reported as rm failure' 'failed to remove' $out
    Assert-NotHas 'guard refusal does not suggest manual removal' 'residue remains' $out

    # 6. scheduled-task query failure WARNs -- never masked as "no tasks".
    # Runs WITHOUT -SkipTasks: Get-ScheduledTask is shadowed by a throwing
    # function defined in the child session before the script runs (functions
    # outrank cmdlets in command resolution), so no real CIM query happens.
    # -DryRun keeps every other step inert.
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    $shadowCmd = "function Get-ScheduledTask { throw 'CIM down' }; & '$Cli' -DryRun -SkipPlugins -SkipHooks"
    $out = ('' | & $PwshExe -NoProfile -Command $shadowCmd 2>&1 | Out-String)
    $script:Rc = $LASTEXITCODE
    Assert-Rc 'task-query-failure dry-run exits 0' 0 $script:Rc
    Assert-Has 'task query failure WARNs' 'scheduled-task query failed' $out
    Assert-Has 'task query failure says tasks may remain' 'tasks may remain' $out
    Assert-NotHas 'query failure not masked as no-tasks' 'no matching scheduled tasks found' $out

    # 6b. HimmelTelegramBridge absent must NOT poison HIMMEL-Resume-* deletion.
    #     Production uses Test-ScheduledTaskExists (a thin wrapper around
    #     schtasks.exe rc) for the exact-name pre-check — tests shadow THAT
    #     function to report absent (return $false) without any real binary call.
    #     Get-ScheduledTask is shadowed so HIMMEL-Resume-* returns one fake task.
    #     Unregister-ScheduledTask is shadowed to record which tasks were deleted.
    #     Assert: HIMMEL-Resume-TestSession IS unregistered, no query-failed WARN.
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    $shadowCmd6b = @'
# Test-ScheduledTaskExists shadow: HimmelTelegramBridge absent (rc != 0).
function Test-ScheduledTaskExists {
    param([string]$TaskName)
    if ($TaskName -eq 'HimmelTelegramBridge') { return $false }
    return $true
}
# Get-ScheduledTask shadow: wildcard query returns one fake resume task.
function Get-ScheduledTask {
    param([string]$TaskName)
    [pscustomobject]@{ TaskName = 'HIMMEL-Resume-TestSession' }
}
# Unregister-ScheduledTask shadow: record deletions for assertion.
function Unregister-ScheduledTask {
    param([string]$TaskName, [switch]$Confirm)
    Add-Content -Path "$env:HIMMEL_UNREG_LOG" -Value $TaskName
}
'@
    $UnregLog = Join-Path $Tmp 'unreg.log'
    Remove-Item $UnregLog -ErrorAction SilentlyContinue
    $env:HIMMEL_UNREG_LOG = $UnregLog
    $shadowCmd6b += "; & '$Cli' -Yes -SkipPlugins -SkipHooks"
    $out = ('' | & $PwshExe -NoProfile -Command $shadowCmd6b 2>&1 | Out-String)
    $script:Rc = $LASTEXITCODE
    Assert-Rc 'task-not-found run exits 0' 0 $script:Rc
    # HIMMEL-Resume-* task must be processed (unregistered via shadow).
    $unregText = if (Test-Path $UnregLog) { Get-Content $UnregLog -Raw } else { '' }
    if ($unregText -match 'HIMMEL-Resume-TestSession') {
        Write-Host 'PASS HIMMEL-Resume-* tasks unregistered despite HimmelTelegramBridge absent'
    } else {
        Write-Host 'FAIL HIMMEL-Resume-* tasks were NOT unregistered -- absent-task check poisoned deletion path'
        $script:Failed++
    }
    Assert-NotHas 'HimmelTelegramBridge absent is not reported as query failure' 'scheduled-task query failed' $out
    Assert-NotHas 'HimmelTelegramBridge absent does not emit tasks-may-remain' 'tasks may remain' $out
    $env:HIMMEL_UNREG_LOG = ''

    # Tests 7-9 mirror bash tests 10-12 (bridge-stop gate). supervisor.pid is
    # seeded with an impossible PID (99999999 -- and a bare number fails
    # parsePidfile anyway), so even a leaked REAL supervisor --kill would
    # signal nothing. The bun seen by the child is a temp-dir bun.cmd stub
    # prepended to PATH.
    $StubBun = Join-Path $Tmp 'stub-bun'
    New-Item -ItemType Directory -Force $StubBun | Out-Null
    $BunLog = Join-Path $Tmp 'bun-call.log'
    @(
        '@echo off'
        "echo BRIDGE_ROOT=%BRIDGE_ROOT%> `"$BunLog`""
        "echo ARGS=%*>> `"$BunLog`""
        'if "%BUN_STUB_RC%"=="" (exit /b 0)'
        'exit /b %BUN_STUB_RC%'
    ) | Set-Content -Path (Join-Path $StubBun 'bun.cmd')
    $SavedPath = $env:PATH

    # 7. bridge-stop: BRIDGE_ROOT passed through to the stubbed --kill (rc=0),
    #    then state removal proceeds.
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    Set-Content -Path (Join-Path $Bridge 'supervisor.pid') -Value '99999999'
    try {
        $env:PATH = "$StubBun;$SavedPath"
        $out = Invoke-Uninstall @('-Yes', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
    } finally { $env:PATH = $SavedPath }
    Assert-Rc 'bridge-stop run exits 0' 0 $script:Rc
    $bunLogText = if (Test-Path $BunLog) { Get-Content $BunLog -Raw } else { '' }
    Assert-Has 'BRIDGE_ROOT passed through to supervisor --kill' "BRIDGE_ROOT=$Bridge" $bunLogText
    Assert-Has 'supervisor.ts --kill invoked' 'supervisor.ts --kill' $bunLogText
    if ((Test-Path $Channel) -or (Test-Path $Bridge)) {
        Write-Host 'FAIL state left behind after successful kill'; $script:Failed++
    } else {
        Write-Host 'PASS state removed after successful kill'
    }

    # 8. bridge-stop failure (rc>=2) WARNs and gates state removal
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    Set-Content -Path (Join-Path $Bridge 'supervisor.pid') -Value '99999999'
    try {
        $env:PATH = "$StubBun;$SavedPath"
        $env:BUN_STUB_RC = '2'
        $out = Invoke-Uninstall @('-Yes', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
    } finally {
        $env:PATH = $SavedPath
        Remove-Item Env:\BUN_STUB_RC -ErrorAction SilentlyContinue
    }
    Assert-Rc 'kill-failure run still exits 0' 0 $script:Rc
    Assert-Has 'kill failure WARNs' 'supervisor --kill rc=2 -- bridge may still be running' $out
    Assert-Has 'state removal skipped while bridge may run' 'SKIPPED: step 1 could not stop the bridge' $out
    if ((Test-Path (Join-Path $Channel 'access.json')) -and (Test-Path (Join-Path $Bridge 'sessions\S1\inbox.jsonl'))) {
        Write-Host 'PASS state preserved while bridge may be running'
    } else {
        Write-Host 'FAIL state removed despite live-bridge risk'; $script:Failed++
    }

    # 9. bun missing with a live pidfile also gates state removal. PATH is
    #    stripped to System32 only; skip if a bun is somehow still resolvable
    #    there (the bun-missing branch would be unreachable).
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    Set-Content -Path (Join-Path $Bridge 'supervisor.pid') -Value '99999999'
    $MinPath = Join-Path $env:SystemRoot 'System32'
    try {
        $env:PATH = $MinPath
        if (Get-Command bun -ErrorAction SilentlyContinue) {
            $env:PATH = $SavedPath
            Write-Host 'SKIP test 9 -- bun still resolvable on the minimal PATH; bun-missing branch not reachable here'
        } else {
            $out = Invoke-Uninstall @('-Yes', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
            $env:PATH = $SavedPath
            Assert-Rc 'bun-missing run still exits 0' 0 $script:Rc
            Assert-Has 'bun missing WARNs' 'bun is not on PATH' $out
            Assert-Has 'bun-missing run skips state removal' 'SKIPPED: step 1 could not stop the bridge' $out
            if (Test-Path (Join-Path $Channel 'access.json')) {
                Write-Host 'PASS state preserved when bridge cannot be stopped'
            } else {
                Write-Host 'FAIL state removed though bridge could not be stopped'; $script:Failed++
            }
        }
    } finally { $env:PATH = $SavedPath }

    # 10. partial delete -> residue WARN, never reported as "removed".
    #     An open handle (FileShare None) on access.json makes Remove-Item
    #     fail on that file; the WARN + survival must be asserted.
    #     FileShare None locking doesn't block unlink on Linux/macOS — skip there.
    if (-not $IsWindows) {
        Write-Host 'SKIP test 10 -- FileShare None does not block unlink on non-Windows; locking semantics differ'
    } else {
    New-State
    $env:TELEGRAM_CHANNEL_DIR = $Channel
    $env:BRIDGE_ROOT = $Bridge
    $AccessJson = Join-Path $Channel 'access.json'
    $lock = [IO.File]::Open($AccessJson, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $out = Invoke-Uninstall @('-Yes', '-SkipTasks', '-SkipPlugins', '-SkipHooks')
    } finally {
        $lock.Dispose()
    }
    Assert-Rc 'locked-file run still exits 0' 0 $script:Rc
    Assert-Has 'partial delete WARNs failed removal' "failed to remove $Channel" $out
    Assert-Has 'partial delete WARNs residue location' 'residue remains under' $out
    Assert-NotHas 'partial delete not reported as removed' "removed: $Channel" $out
    if (Test-Path $AccessJson) {
        Write-Host 'PASS locked access.json survived (residue detected, not silently lost)'
    } else {
        Write-Host 'FAIL access.json gone despite open handle'; $script:Failed++
    }
    }
} finally {
    $env:TELEGRAM_CHANNEL_DIR = $SavedChannelDir
    $env:BRIDGE_ROOT = $SavedBridgeRoot
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host 'ALL PASS'
    exit 0
} else {
    Write-Host "$script:Failed FAILURE(S)"
    exit 1
}
