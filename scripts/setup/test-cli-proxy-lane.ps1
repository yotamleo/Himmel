# Hermetic swap/rollback tests for cli-proxy-lane.ps1 (HIMMEL-1473).
# Dot-sources the helper without touching the live proxy, then replaces only the
# lifecycle commands and targeted filesystem failure points used by the swap.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'cli-proxy-lane.ps1'
foreach ($path in @($Helper, $MyInvocation.MyCommand.Path)) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if (@($parseErrors).Count -gt 0) { throw "PowerShell parser errors in ${path}: $($parseErrors -join '; ')" }
}
$script:Pass = 0
$script:Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

. $Helper -AsLibrary

$script:ProxyRunning = $false
$script:ProxyHealthy = $true
$script:HealthProbeResults = @()
$script:HealthProbeResultIndex = 0
$script:HealthProbeCount = 0
$script:StrictHealthProbeCount = 0
$script:StopCount = 0
$script:StartCount = 0
$script:DestinationMoveCount = 0
$script:TargetExe = ''
$script:TargetStamp = ''
$script:FailDestinationMove = $false
$script:FailStampWrite = $false
$script:LockRollbackStampOnFailure = $false
$script:RollbackStampLock = $null
$script:RollbackStampPath = ''

function Assert-BounceSafe {}
function Stop-ProxyInstance {
    $script:StopCount++
    $script:ProxyRunning = $false
    return $true
}
function Get-ProxyProcess {
    if ($script:ProxyRunning) { [pscustomobject]@{ Id = 1234 } }
}
function Start-ProxyBackground {
    $script:StartCount++
    $script:ProxyRunning = $true
}
function Wait-ProxyRunning {
    param([int]$TimeoutSeconds = 20, [switch]$RequireHealthy)
    $script:HealthProbeCount++
    if ($RequireHealthy) { $script:StrictHealthProbeCount++ }
    if ($script:HealthProbeResultIndex -lt @($script:HealthProbeResults).Count) {
        $result = $script:HealthProbeResults[$script:HealthProbeResultIndex]
        $script:HealthProbeResultIndex++
        if ($result -is [string]) {
            if ($RequireHealthy) { return $result -eq '200' }
            return ($result -eq '200') -or ($result -eq '401')
        }
        return $result
    }
    return $script:ProxyHealthy
}
function Move-Item {
    param(
        [Parameter(Mandatory = $true)][string[]]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )
    if ($Destination -eq $script:TargetExe) {
        $script:DestinationMoveCount++
        if ($script:FailDestinationMove) {
            throw 'simulated destination move failure'
        }
    }
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
function Set-Content {
    param(
        [Parameter(Mandatory = $true)][string[]]$LiteralPath,
        [Parameter(Mandatory = $true)][object]$Value
    )
    if ($script:FailStampWrite -and $LiteralPath[0].StartsWith("$($script:TargetStamp).")) {
        if ($script:LockRollbackStampOnFailure) {
            $rollbackStamp = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath (Split-Path -Parent $script:TargetStamp) |
                Where-Object { $_.FullName.StartsWith("$($script:TargetStamp).") -and $_.Name.EndsWith('.rollback') }) |
                Select-Object -First 1
            if (-not $rollbackStamp) { throw 'could not find rollback stamp to lock' }
            $script:RollbackStampPath = $rollbackStamp.FullName
            $script:RollbackStampLock = [System.IO.File]::Open(
                $script:RollbackStampPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None
            )
        }
        $script:FailStampWrite = $false
        throw 'simulated version stamp failure'
    }
    Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value
}

# -Register test state (HIMMEL-1822): a shadow schtasks records invocations and
# plays a configurable registration outcome through $global:LASTEXITCODE, so the
# registration form and the Defender-removal detection are exercised without
# touching the real task scheduler.
$script:SchtasksCalls = @()
$script:SchtasksCreateExit = 0
$script:SchtasksTaskPresent = $true
# Per-probe override for the /query sequence (HIMMEL-1822 settle-loop race
# test): consumed in order, one $bool per /query call; falls back to
# $SchtasksTaskPresent once exhausted. Lets a test simulate "present at the
# first probe, removed by a later one" instead of one static state.
$script:SchtasksQueryResults = @()
$script:SchtasksRunExit = 0
function schtasks {
    $line = ($args -join ' ')
    $script:SchtasksCalls += ,$line
    if ($line -match '(^| )/create( |$)') {
        $global:LASTEXITCODE = $script:SchtasksCreateExit
    } elseif ($line -match '(^| )/query( |$)') {
        if (@($script:SchtasksQueryResults).Count -gt 0) {
            $present = $script:SchtasksQueryResults[0]
            $script:SchtasksQueryResults = @($script:SchtasksQueryResults | Select-Object -Skip 1)
        } else {
            $present = $script:SchtasksTaskPresent
        }
        $global:LASTEXITCODE = if ($present) { 0 } else { 1 }
    } elseif ($line -match '(^| )/run( |$)') {
        $global:LASTEXITCODE = $script:SchtasksRunExit
    } else {
        $global:LASTEXITCODE = 0
    }
}
function Start-Sleep {
    # No-op: the Defender settle loop's back-off must not slow the suite. This
    # shadow is SUITE-WIDE (CR round, codex-adv Suggestion: scoping it only to
    # the -Register tests would be safer against a future test silently losing
    # real timing coverage). It is a no-op today for every OTHER path too: the
    # only two source functions that call the real Start-Sleep
    # (Stop-ProxyInstance, Wait-ProxyRunning) are themselves fully replaced by
    # the mocks directly above, so nothing in this suite currently exercises
    # real Start-Sleep-gated behavior outside Register-ProxyLogonTask. Adding a
    # test against a NON-mocked, Start-Sleep-using function must account for
    # this shadow (e.g. assert call counts/ordering instead of relying on
    # elapsed wall-clock time).
    param([int]$Milliseconds, [int]$Seconds)
}

function New-Fixture([string]$Root, [string]$Name) {
    $dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $source = Join-Path $dir 'downloaded.exe'
    $destination = Join-Path $dir 'cli-proxy-api.exe'
    $versionStamp = Join-Path $dir 'cli-proxy-api.version'
    [System.IO.File]::WriteAllText($source, 'new-binary')
    [System.IO.File]::WriteAllText($destination, 'old-binary')
    [System.IO.File]::WriteAllText($versionStamp, '7.2.112')
    [pscustomobject]@{ Dir = $dir; Source = $source; Destination = $destination; VersionStamp = $versionStamp }
}
function Reset-Lifecycle([object]$Fixture) {
    if ($script:RollbackStampLock) {
        $script:RollbackStampLock.Dispose()
        $script:RollbackStampLock = $null
    }
    $script:ProxyRunning = $true
    $script:ProxyHealthy = $true
    $script:HealthProbeResults = @()
    $script:HealthProbeResultIndex = 0
    $script:HealthProbeCount = 0
    $script:StrictHealthProbeCount = 0
    $script:StopCount = 0
    $script:StartCount = 0
    $script:DestinationMoveCount = 0
    $script:TargetExe = $Fixture.Destination
    $script:TargetStamp = $Fixture.VersionStamp
    $script:FailDestinationMove = $false
    $script:FailStampWrite = $false
    $script:LockRollbackStampOnFailure = $false
    $script:RollbackStampPath = ''
}
function Test-NoSwapArtifacts([string]$Dir) {
    @((Get-ChildItem -LiteralPath $Dir | Where-Object { $_.Name -match '\.(new|rollback)$' })).Count -eq 0
}

function New-RegisterFixture([string]$Root, [string]$Name) {
    $dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $exe = Join-Path $dir 'cli-proxy-api.exe'
    $cfg = Join-Path $dir 'config.yaml'
    [System.IO.File]::WriteAllText($exe, 'fake-binary')
    [System.IO.File]::WriteAllText($cfg, 'fake-config')
    [pscustomobject]@{ Dir = $dir; Exe = $exe; Cfg = $cfg; Vbs = Join-Path $dir 'start-hidden.vbs' }
}
function Reset-Register([object]$Fixture) {
    # Re-aim the helper's install-root globals at the fixture so registration
    # writes/queries land in the sandbox, never the real ~/.cli-proxy-api.
    $script:SchtasksCalls = @()
    $script:SchtasksCreateExit = 0
    $script:SchtasksTaskPresent = $true
    $script:SchtasksQueryResults = @()
    $script:SchtasksRunExit = 0
    $script:Dir = $Fixture.Dir
    $script:Exe = $Fixture.Exe
    $script:Cfg = $Fixture.Cfg
    $script:Vbs = $Fixture.Vbs
}

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-cli-proxy-swap-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
try {
    Write-Host 'Test 1: first install moves staged files into absent destinations'
    $fixture = New-Fixture $Tmp 'first-install'
    Remove-Item -LiteralPath $fixture.Destination, $fixture.VersionStamp -Force
    Reset-Lifecycle $fixture
    Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113'
    Check 'first install writes the new binary' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'new-binary')
    Check 'first install writes the new version stamp' (([System.IO.File]::ReadAllText($fixture.VersionStamp)).Trim() -eq '7.2.113')
    Check 'first install uses Move-Item for the absent executable' ($script:DestinationMoveCount -eq 1) "count=$script:DestinationMoveCount"
    Check 'first-install artifacts cleaned' (Test-NoSwapArtifacts $fixture.Dir)
    Check 'first-install lock released' (-not (Test-Path -LiteralPath "$($fixture.Destination).install.lock"))

    Write-Host 'Test 2: an existing destination is replaced without Move-Item overwrite'
    $fixture = New-Fixture $Tmp 'replace-existing'
    Reset-Lifecycle $fixture
    $script:FailDestinationMove = $true
    Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113'
    Check 'replace path writes the new binary' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'new-binary')
    Check 'replace path writes the new version stamp' (([System.IO.File]::ReadAllText($fixture.VersionStamp)).Trim() -eq '7.2.113')
    Check 'replace path does not Move-Item over the executable' ($script:DestinationMoveCount -eq 0) "count=$script:DestinationMoveCount"
    Check 'replace-path artifacts cleaned' (Test-NoSwapArtifacts $fixture.Dir)

    Write-Host 'Test 3: a healthy candidate is validated before rollback cleanup'
    $fixture = New-Fixture $Tmp 'healthy-candidate'
    Reset-Lifecycle $fixture
    Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113' -StopForSwap -RestartAfterSwap
    Check 'healthy candidate stops the old proxy once' ($script:StopCount -eq 1) "count=$script:StopCount"
    Check 'healthy candidate starts once' ($script:StartCount -eq 1) "count=$script:StartCount"
    Check 'healthy candidate is probed once' ($script:HealthProbeCount -eq 1) "count=$script:HealthProbeCount"
    Check 'healthy candidate remains running' $script:ProxyRunning
    Check 'healthy candidate keeps the new binary' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'new-binary')
    Check 'healthy candidate keeps the new version stamp' (([System.IO.File]::ReadAllText($fixture.VersionStamp)).Trim() -eq '7.2.113')
    Check 'healthy-candidate rollback artifacts cleaned' (Test-NoSwapArtifacts $fixture.Dir)

    Write-Host 'Test 4: a candidate returning 401 restores and restarts the old proxy'
    $fixture = New-Fixture $Tmp 'candidate-health-failure'
    Reset-Lifecycle $fixture
    $script:HealthProbeResults = @('401', '200')
    $errorMessage = ''
    try {
        Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113' -StopForSwap -RestartAfterSwap
    } catch {
        $errorMessage = $_.Exception.Message
    }
    Check '401 candidate deployment is rejected' ($errorMessage.Contains('candidate deployment failed:')) $errorMessage
    Check 'failed candidate names the strict health timeout' ($errorMessage.Contains('proxy did not come up healthy on 127.0.0.1:8317 within 20s')) $errorMessage
    Check 'old and candidate processes were each stopped' ($script:StopCount -eq 2) "count=$script:StopCount"
    Check 'candidate and restored old proxy were each started' ($script:StartCount -eq 2) "count=$script:StartCount"
    Check 'candidate and restored old proxy were each health-checked' ($script:HealthProbeCount -eq 2) "count=$script:HealthProbeCount"
    Check 'candidate and recovery probes both require HTTP 200' ($script:StrictHealthProbeCount -eq 2) "count=$script:StrictHealthProbeCount"
    Check 'old proxy reports running after candidate failure' $script:ProxyRunning
    Check 'old binary restored after candidate failure' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'old-binary')
    Check 'old version restored after candidate failure' (([System.IO.File]::ReadAllText($fixture.VersionStamp)) -eq '7.2.112')
    Check 'candidate-failure rollback artifacts consumed' (Test-NoSwapArtifacts $fixture.Dir)

    Write-Host 'Test 5: a stamp failure restores both files and restarts the old proxy'
    $fixture = New-Fixture $Tmp 'stamp-failure'
    Reset-Lifecycle $fixture
    $script:FailStampWrite = $true
    $threw = $false
    try {
        Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113' -StopForSwap
    } catch {
        $threw = $true
    }
    Check 'stamp failure is surfaced' $threw
    Check 'proxy was stopped once for stamp failure' ($script:StopCount -eq 1) "count=$script:StopCount"
    Check 'old proxy was restarted after executable restore' ($script:StartCount -eq 1) "count=$script:StartCount"
    Check 'restarted proxy health was verified' ($script:HealthProbeCount -eq 1) "count=$script:HealthProbeCount"
    Check 'proxy reports running after executable restore' $script:ProxyRunning
    Check 'old binary restored after stamp failure' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'old-binary')
    Check 'old version stamp restored after stamp failure' (([System.IO.File]::ReadAllText($fixture.VersionStamp)) -eq '7.2.112')
    Check 'stamp-failure artifacts cleaned' (Test-NoSwapArtifacts $fixture.Dir)

    Write-Host 'Test 6: rollback failure retains the artifact, names it, and still restarts'
    $fixture = New-Fixture $Tmp 'rollback-failure'
    Reset-Lifecycle $fixture
    $script:FailStampWrite = $true
    $script:LockRollbackStampOnFailure = $true
    $errorMessage = ''
    try {
        Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113' -StopForSwap
    } catch {
        $errorMessage = $_.Exception.Message
    }
    $retainedRollback = @(Get-ChildItem -LiteralPath $fixture.Dir | Where-Object { $_.Name.EndsWith('.rollback') })
    Check 'rollback failure is surfaced' ($errorMessage.Length -gt 0)
    Check 'executable was restored before stamp rollback failed' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'old-binary')
    Check 'live stamp is removed after stamp rollback fails' (-not (Test-Path -LiteralPath $fixture.VersionStamp))
    $installedVer = if (Test-Path -LiteralPath $fixture.VersionStamp) { Get-Content $fixture.VersionStamp | Select-Object -First 1 } else { $null }
    $nextInstallNeeded = (-not (Test-Path -LiteralPath $fixture.Destination)) -or ($installedVer -ne '7.2.113')
    Check 'missing live stamp prevents the next install from skipping' $nextInstallNeeded
    Check 'stamp rollback error names live stamp invalidation' ($errorMessage.Contains("live version stamp invalidated: $($fixture.VersionStamp)")) $errorMessage
    Check 'restart was attempted after executable restore' ($script:StartCount -eq 1) "count=$script:StartCount"
    Check 'proxy reports running after partial rollback' $script:ProxyRunning
    Check 'failed rollback artifact is retained' ($retainedRollback.Count -eq 1) "count=$($retainedRollback.Count)"
    Check 'error names the retained rollback artifact' ($errorMessage.Contains($script:RollbackStampPath)) $errorMessage
    Check 'only the rollback artifact remains staged' (@(Get-ChildItem -LiteralPath $fixture.Dir | Where-Object { $_.Name.EndsWith('.new') }).Count -eq 0)
    $script:RollbackStampLock.Dispose()
    $script:RollbackStampLock = $null

    Write-Host 'Test 7: recovery reports a launch that never becomes healthy'
    $fixture = New-Fixture $Tmp 'restart-health-failure'
    Reset-Lifecycle $fixture
    $script:FailStampWrite = $true
    $script:ProxyHealthy = $false
    $errorMessage = ''
    try {
        Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113' -StopForSwap
    } catch {
        $errorMessage = $_.Exception.Message
    }
    Check 'failed recovery is surfaced' ($errorMessage.Contains('recovery failed:')) $errorMessage
    Check 'failed recovery names the strict health timeout' ($errorMessage.Contains('proxy did not come up healthy on 127.0.0.1:8317 within 20s')) $errorMessage
    Check 'recovery launch was attempted once' ($script:StartCount -eq 1) "count=$script:StartCount"
    Check 'failed recovery was health-checked once' ($script:HealthProbeCount -eq 1) "count=$script:HealthProbeCount"
    Check 'old binary remains restored after unhealthy restart' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'old-binary')
    Check 'old version remains restored after unhealthy restart' (([System.IO.File]::ReadAllText($fixture.VersionStamp)) -eq '7.2.112')
    Check 'restart-health-failure artifacts cleaned' (Test-NoSwapArtifacts $fixture.Dir)
    Check 'restart-health-failure lock released' (-not (Test-Path -LiteralPath "$($fixture.Destination).install.lock"))

    Write-Host 'Test 8: a live install lock refuses overlap without altering completed files'
    $fixture = New-Fixture $Tmp 'concurrent-install'
    [System.IO.File]::WriteAllText($fixture.Destination, 'concurrent-completed-binary')
    [System.IO.File]::WriteAllText($fixture.VersionStamp, '7.2.114')
    Reset-Lifecycle $fixture
    $lockPath = "$($fixture.Destination).install.lock"
    $liveLock = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    Write-ProxyInstallLockOwner $liveLock
    $errorMessage = ''
    $exitCode = $null
    try {
        Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113' -StopForSwap
    } catch {
        $errorMessage = $_.Exception.Message
        $exitCode = $_.Exception.Data['ExitCode']
    }
    Check 'overlapping install is refused' ($errorMessage.Contains('another install already holds the lock')) $errorMessage
    Check 'lock refusal honestly omits unreadable owner fields' ($errorMessage.Contains('owner details unavailable while held')) $errorMessage
    Check 'lock refusal carries distinct exit code 3' ($exitCode -eq 3) "exit=$exitCode"
    Check 'completed binary is unchanged after refusal' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'concurrent-completed-binary')
    Check 'completed version is unchanged after refusal' (([System.IO.File]::ReadAllText($fixture.VersionStamp)) -eq '7.2.114')
    Check 'lock refusal does not stop the proxy' ($script:StopCount -eq 0) "count=$script:StopCount"
    Check 'contender does not remove the live lock' (Test-Path -LiteralPath $lockPath)
    $liveLock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force

    Write-Host 'Test 9: a released holder does not block the next install'
    $fixture = New-Fixture $Tmp 'released-holder'
    Reset-Lifecycle $fixture
    $lockPath = "$($fixture.Destination).install.lock"
    $deadHolder = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    Write-ProxyInstallLockOwner $deadHolder
    $deadHolder.Dispose()
    Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113'
    Check 'released-holder install writes the new binary' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'new-binary')
    Check 'released-holder install writes the new version stamp' (([System.IO.File]::ReadAllText($fixture.VersionStamp)).Trim() -eq '7.2.113')
    Check 'released-holder lock cleaned' (-not (Test-Path -LiteralPath $lockPath))

    Write-Host 'Test 10: a leftover lock file without a holder does not wedge installs'
    $fixture = New-Fixture $Tmp 'leftover-lock-file'
    Reset-Lifecycle $fixture
    $lockPath = "$($fixture.Destination).install.lock"
    [System.IO.File]::WriteAllText($lockPath, '')
    Install-ProxyBinary -Source $fixture.Source -Destination $fixture.Destination -VersionStamp $fixture.VersionStamp -PinnedVersion '7.2.113'
    Check 'leftover-file install writes the new binary' (([System.IO.File]::ReadAllText($fixture.Destination)) -eq 'new-binary')
    Check 'leftover-file install writes the new version stamp' (([System.IO.File]::ReadAllText($fixture.VersionStamp)).Trim() -eq '7.2.113')
    Check 'leftover lock file cleaned' (-not (Test-Path -LiteralPath $lockPath))

    $origDir = $Dir; $origExe = $Exe; $origCfg = $Cfg; $origVbs = $Vbs

    Write-Host 'Test 11: -Register writes the launcher and registers the wscript task action'
    $fixture = New-RegisterFixture $Tmp 'register-new'
    Reset-Register $fixture
    Register-ProxyLogonTask
    Check 'launcher written next to the exe' (Test-Path -LiteralPath $fixture.Vbs)
    $vbsBody = [System.IO.File]::ReadAllText($fixture.Vbs)
    $expectedRun = '"""' + $fixture.Exe + '"" -config ""' + $fixture.Cfg + '""", 0, False'
    Check 'launcher starts the installed exe hidden' ($vbsBody.Contains($expectedRun)) $vbsBody
    $vbsFirstBytes = [System.IO.File]::ReadAllBytes($fixture.Vbs) | Select-Object -First 3
    Check 'launcher carries a UTF-8 BOM (WSH non-ASCII-path safety, CR round)' (($vbsFirstBytes[0] -eq 0xEF) -and ($vbsFirstBytes[1] -eq 0xBB) -and ($vbsFirstBytes[2] -eq 0xBF)) ($vbsFirstBytes -join ',')
    $createLine = @($script:SchtasksCalls | Where-Object { $_ -match '(^| )/create( |$)' })[0]
    Check 'task action is the wscript launcher' (($createLine -match 'wscript\.exe //B //Nologo') -and ($createLine.Contains('"' + $fixture.Vbs + '"'))) $createLine
    Check 'registration force-replaces (idempotent + upgrades old form)' ($createLine -match '(^| )/f( |$)') $createLine
    Check 'old PowerShell-wrapper action is gone' ($createLine -notmatch 'powershell') $createLine
    Check 'task verified present after create' (@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/query( |$)' }).Count -ge 1)
    Check 'task started immediately' (@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/run( |$)' }).Count -eq 1)
    Register-ProxyLogonTask
    $createCalls = @($script:SchtasksCalls | Where-Object { $_ -match '(^| )/create( |$)' })
    Check 're-register does not duplicate the task (same /tn, /f)' ($createCalls.Count -eq 2) "count=$($createCalls.Count)"
    Check 're-register rewrites identical launcher bytes' (([System.IO.File]::ReadAllText($fixture.Vbs)) -eq $vbsBody)

    Write-Host 'Test 12: a task removed right after registration fails loudly with Defender guidance'
    $fixture = New-RegisterFixture $Tmp 'register-defender-removed'
    Reset-Register $fixture
    $script:SchtasksTaskPresent = $false
    $errorMessage = ''
    try { Register-ProxyLogonTask } catch { $errorMessage = $_.Exception.Message }
    Check 'removal is surfaced as a failure' ($errorMessage.Contains("logon task 'cli-proxy-api' is ABSENT right after registration")) $errorMessage
    Check 'failure names Defender' ($errorMessage.Contains('Windows Defender')) $errorMessage
    Check 'failure names the detection' ($errorMessage.Contains('Trojan:Win32/Commando.A!ml')) $errorMessage
    Check 'failure quotes the exclusion command scoped to the launcher, not the whole dir' ($errorMessage.Contains('Add-MpPreference -ExclusionPath "' + $fixture.Vbs + '"')) $errorMessage
    Check 'failure states the lost logon start' ($errorMessage.Contains('will NOT auto-start')) $errorMessage
    Check 'no /run attempted against a vanished task' (@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/run( |$)' }).Count -eq 0)

    Write-Host 'Test 13: a failed schtasks /create carries the same Defender guidance'
    $fixture = New-RegisterFixture $Tmp 'register-create-failed'
    Reset-Register $fixture
    $script:SchtasksCreateExit = 1
    $errorMessage = ''
    try { Register-ProxyLogonTask } catch { $errorMessage = $_.Exception.Message }
    Check 'create failure is surfaced' ($errorMessage.Contains('schtasks /create failed (exit 1)')) $errorMessage
    Check 'create failure still names Defender' ($errorMessage.Contains('Trojan:Win32/Commando.A!ml')) $errorMessage

    Write-Host 'Test 14: a task present at the first probe but genuinely removed mid-window still fails (HIMMEL-1822 settle-loop race)'
    $fixture = New-RegisterFixture $Tmp 'register-removed-mid-window'
    Reset-Register $fixture
    # Present at the immediate post-/create probe (delay 0), gone by the time
    # Defender's async removal has had a moment to run (the later probes) -
    # and it STAYS gone on the confirming retry too, because this is a real
    # removal. Stopping at the first success would miss this; the fix must not.
    $script:SchtasksQueryResults = @($true, $false, $false, $false, $false)
    $errorMessage = ''
    try { Register-ProxyLogonTask } catch { $errorMessage = $_.Exception.Message }
    Check 'a mid-window removal is still caught (not masked by an early positive)' ($errorMessage.Contains("logon task 'cli-proxy-api' is ABSENT right after registration")) $errorMessage
    Check 'all four settle probes plus the confirming retry were taken' (@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/query( |$)' }).Count -eq 5) "count=$(@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/query( |$)' }).Count)"
    Check 'no /run attempted against a task removed mid-window' (@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/run( |$)' }).Count -eq 0)

    Write-Host 'Test 15: a single transient query glitch on the final settle probe does not misreport a live task as removed'
    $fixture = New-RegisterFixture $Tmp 'register-transient-glitch'
    Reset-Register $fixture
    # Present on every probe except a lone flaky failure at the final
    # SCHEDULED one - the task was never actually touched by Defender, only
    # that one query hiccuped. The immediate confirming retry (falls back to
    # $SchtasksTaskPresent = $true, unset here) must recover it rather than
    # declare a false removal.
    $script:SchtasksQueryResults = @($true, $true, $true, $false)
    $errorMessage = ''
    try { Register-ProxyLogonTask } catch { $errorMessage = $_.Exception.Message }
    Check 'a lone final-probe glitch does not fail the registration' ($errorMessage -eq '') $errorMessage
    Check 'the confirming retry query was taken' (@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/query( |$)' }).Count -eq 5) "count=$(@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/query( |$)' }).Count)"
    Check 'task started immediately despite the glitch' (@($script:SchtasksCalls | Where-Object { $_ -match '(^| )/run( |$)' }).Count -eq 1)

    $Dir = $origDir; $Exe = $origExe; $Cfg = $origCfg; $Vbs = $origVbs

    Write-Host ""
    Write-Host "test-cli-proxy-lane: $script:Pass passed, $script:Fail failed"
    if ($script:Fail -gt 0) { exit 1 }
} finally {
    if ($script:RollbackStampLock) { $script:RollbackStampLock.Dispose() }
    Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
