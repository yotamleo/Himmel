#Requires -Version 5.1
<#
.SYNOPSIS
  Bring up the CLIProxyAPI codex lane (cc-codex) on a Windows HOST.

.DESCRIPTION
  The proxy is a HOST process on 127.0.0.1:8317. ONE instance per host serves
  that host's launchers (bash + .ps1) AND that host's WSL (via mirrored
  networking). Do NOT run this inside WSL. cc-glm needs no proxy (direct to z.ai).

  Per-host order:  -Install  ->  -Login (once)  ->  -Start  ->  -Register
  Run with no switch for a status report + the next command to run.

  Lifecycle: -Stop / -Restart bounce the running instance (HIMMEL-1451). They
  refuse while a client is actively connected (a bounce kills an in-flight
  codex-lane render) unless -Force is given. -Restart relaunches windowless and
  verifies /v1/models answers before exiting 0.

.PARAMETER Install   Download the CLIProxyAPI binary + write config.yaml if missing.
.PARAMETER Login     One-time codex OAuth via device-code flow (no local browser needed).
.PARAMETER Start     Start the proxy in the foreground (Ctrl-C to stop).
.PARAMETER Register  Register a logon scheduled task so the proxy restarts at each sign-in.
.PARAMETER Stop      Stop the running proxy (idempotent: no error if not running).
.PARAMETER Restart   Stop then relaunch the proxy windowless; verify /v1/models answers.
.PARAMETER Force     Override the claudex-live guard on -Stop / -Restart.
.PARAMETER Verify    Curl the running proxy.

.EXAMPLE
  # win1 (OAuth already present): start, then persist across boot
  .\cli-proxy-lane.ps1 -Start
  .\cli-proxy-lane.ps1 -Register

.EXAMPLE
  # win2 (fresh host): one-time login, start, persist
  .\cli-proxy-lane.ps1 -Login
  .\cli-proxy-lane.ps1 -Start
  .\cli-proxy-lane.ps1 -Register

.EXAMPLE
  # roll a pinned-binary bump over a RUNNING proxy (HIMMEL-1451): either three
  # separate calls (-Stop; -Install; -Start) or the single combined form
  .\cli-proxy-lane.ps1 -Install -Restart
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Login,
    [switch]$Start,
    [switch]$Register,
    [switch]$Stop,
    [switch]$Restart,
    [switch]$Force,
    [switch]$Verify,
    [Parameter(DontShow = $true)]
    [switch]$AsLibrary
)

$ErrorActionPreference = 'Stop'

$Dir     = Join-Path $HOME '.cli-proxy-api'
$Exe     = Join-Path $Dir 'cli-proxy-api.exe'
$Cfg     = Join-Path $Dir 'config.yaml'
$ApiKey  = 'himmel-local-claudex'   # local proxy token; must match config.yaml api-keys
$Port    = 8317
$Version = '7.2.115'
$Release = "https://github.com/router-for-me/CLIProxyAPI/releases/download/v$Version/CLIProxyAPI_${Version}_windows_amd64.zip"

function Test-OAuth {
    (Test-Path $Dir) -and @(Get-ChildItem $Dir -Filter 'codex-*.json' -ErrorAction SilentlyContinue).Count -gt 0
}
function Get-ProxyCode {
    # Authenticated HTTP probe (not just a port check): an unrelated listener on
    # $Port would pass a bare TCP test but not answer /v1/models.
    curl.exe -sk -H "Authorization: Bearer $ApiKey" "http://127.0.0.1:$Port/v1/models" -o NUL -w '%{http_code}' 2>$null
}
function Test-Running {
    # 200 = up + our key accepted; 401 = up but key rejected (still the proxy speaking HTTP).
    $c = Get-ProxyCode
    ($c -eq '200') -or ($c -eq '401')
}
function Test-Healthy {
    (Get-ProxyCode) -eq '200'
}
function Assert-Exe {
    if (-not (Test-Path $Exe)) { throw "binary missing at $Exe - run with -Install first" }
}
function Assert-Config {
    if (-not (Test-Path $Cfg)) { throw "config missing at $Cfg - run with -Install first" }
}

# --- lifecycle helpers (-Stop / -Restart, HIMMEL-1451) -----------------------

function Get-ProxyProcess {
    # Find the running proxy by process name. The exe is cli-proxy-api.exe, so
    # the process name is 'cli-proxy-api'. This catches BOTH the logon-task
    # instance AND one manually relaunched outside the task (the deployment
    # quirk -Restart has to converge from regardless of how it was started).
    Get-Process -Name 'cli-proxy-api' -ErrorAction SilentlyContinue
}

function Test-LaneWorkersLive {
    # claudex-live guard: a proxy bounce under an ACTIVE codex-lane worker kills
    # its in-flight render. Detect that the cheapest reliable way -- an
    # ESTABLISHED TCP connection to the proxy port means a client is connected
    # right now (mid-stream or on a keep-alive), the exact condition under which
    # a bounce hurts. Chosen over a process list (which would over-block the
    # operator's own idle session) and worktree lock files (which miss
    # throwaway-branch workers): it measures the risk directly and only refuses
    # when something is ACTIVELY connected. Conservative on both edges.
    [bool](Get-NetTCPConnection -LocalPort $Port -State Established -ErrorAction SilentlyContinue)
}

function Assert-BounceSafe {
    # Shared by -Stop and -Restart. -Force overrides the guard.
    if ($Force) { return }
    if (Test-LaneWorkersLive) {
        throw "refusing proxy bounce: a client is actively connected on port $Port (an in-flight codex-lane render would be killed). Re-run with -Force to override."
    }
}

function Stop-ProxyInstance {
    # Stop every running proxy process, then wait for it to release the port.
    # Returns $true if a process was stopped, $false if nothing was running.
    $procs = Get-ProxyProcess
    if (-not $procs) { return $false }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-ProxyProcess)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    throw "proxy process did not exit within 10s"
}

function Start-ProxyBackground {
    # Canonical windowless relaunch. If the logon task 'cli-proxy-api' is
    # registered, /run it (the same path -Register uses to start the proxy now);
    # otherwise launch the exe detached + hidden, so -Restart brings the proxy up
    # regardless of how the old instance was started (manually vs via the task).
    $useTask = $false
    schtasks /query /tn 'cli-proxy-api' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        schtasks /run /tn 'cli-proxy-api' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $useTask = $true }
    }
    if (-not $useTask) {
        Start-Process -FilePath $Exe -ArgumentList "-config `"$Cfg`"" -WindowStyle Hidden
    }
}

function Wait-ProxyRunning([int]$TimeoutSeconds = 20, [switch]$RequireHealthy) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $running = if ($RequireHealthy) { Test-Healthy } else { Test-Running }
        if ($running) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# Serialize the read/swap/recovery window with a held exclusive file handle.
# Process death releases the handle automatically; metadata is diagnostic only.
$script:ProxyInstallLockPath = $null
$script:ProxyInstallLockHandle = $null
$script:ProxyInstallLockDetail = ''

function Get-ProxyInstallLockHost {
    if ($env:COMPUTERNAME) { return $env:COMPUTERNAME }
    try { return [System.Net.Dns]::GetHostName() } catch { return 'unknown' }
}

function Remove-ProxyInstallLock {
    if (-not $script:ProxyInstallLockHandle) { return }
    try {
        $script:ProxyInstallLockHandle.Dispose()
    } catch { }
    $script:ProxyInstallLockHandle = $null
    Remove-Item -LiteralPath $script:ProxyInstallLockPath -Force -ErrorAction SilentlyContinue
}

function Write-ProxyInstallLockOwner([System.IO.FileStream]$Handle) {
    try {
        $metadata = "pid=$PID`nhost=$(Get-ProxyInstallLockHost)`nstarted=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($metadata)
        $Handle.SetLength(0)
        $Handle.Position = 0
        $Handle.Write($bytes, 0, $bytes.Length)
        $Handle.Flush()
    } catch { }
}

function Enter-ProxyInstallLock([string]$Path) {
    $script:ProxyInstallLockPath = $Path
    $script:ProxyInstallLockHandle = $null
    $script:ProxyInstallLockDetail = ''

    try {
        $script:ProxyInstallLockHandle = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch [System.IO.IOException] {
        # FileShare.None makes owner metadata unreadable until the holder exits.
        $script:ProxyInstallLockDetail = "another install already holds the lock (owner details unavailable while held) -- $Path"
        return $false
    } catch {
        $script:ProxyInstallLockDetail = "could not acquire install lock at ${Path}: $($_.Exception.Message)"
        return $false
    }

    Write-ProxyInstallLockOwner $script:ProxyInstallLockHandle
    return $true
}

function Invoke-ProxyBinarySwap {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$VersionStamp,
        [Parameter(Mandatory = $true)][string]$PinnedVersion,
        [switch]$StopForSwap,
        [switch]$RestartAfterSwap
    )

    # Stage both the candidate and rollback material beside the destination so
    # existing files can be replaced atomically on the same volume. Nothing
    # running is stopped until the candidate has been copied and validated.
    $swapId = [guid]::NewGuid().ToString('N')
    $stagedExe = "$Destination.$swapId.new"
    $rollbackExe = "$Destination.$swapId.rollback"
    $stagedStamp = "$VersionStamp.$swapId.new"
    $rollbackStamp = "$VersionStamp.$swapId.rollback"
    $hadDestination = Test-Path -LiteralPath $Destination
    $hadVersionStamp = Test-Path -LiteralPath $VersionStamp
    $restartAfterFailure = [bool]($StopForSwap -or $RestartAfterSwap)
    $swapAttempted = $false
    $candidateStartAttempted = $false
    $retainRollbackArtifacts = $false

    try {
        Copy-Item -LiteralPath $Source -Destination $stagedExe -Force
        $stagedInfo = Get-Item -LiteralPath $stagedExe
        if ($stagedInfo.Length -le 0) { throw "staged cli-proxy-api.exe is empty" }

        if ($hadDestination) {
            Copy-Item -LiteralPath $Destination -Destination $rollbackExe -Force
        }
        if ($hadVersionStamp) {
            Copy-Item -LiteralPath $VersionStamp -Destination $rollbackStamp -Force
        }

        if ($StopForSwap) {
            Assert-BounceSafe
            Write-Host "stopping cli-proxy-api to roll the pinned binary ..."
            Stop-ProxyInstance | Out-Null
        }

        $swapAttempted = $true
        if ($hadDestination) {
            [System.IO.File]::Replace($stagedExe, $Destination, [System.Management.Automation.Language.NullString]::Value)
        } else {
            Move-Item -LiteralPath $stagedExe -Destination $Destination -Force
        }
        Set-Content -LiteralPath $stagedStamp -Value $PinnedVersion
        if ($hadVersionStamp) {
            [System.IO.File]::Replace($stagedStamp, $VersionStamp, [System.Management.Automation.Language.NullString]::Value)
        } else {
            Move-Item -LiteralPath $stagedStamp -Destination $VersionStamp -Force
        }

        if ($RestartAfterSwap) {
            Write-Host "relaunching proxy (windowless) ..."
            $candidateStartAttempted = $true
            Start-ProxyBackground
            if (-not (Wait-ProxyRunning -RequireHealthy)) {
                throw "candidate deployment failed: proxy did not come up healthy on 127.0.0.1:$Port within 20s"
            }
            Write-Host "proxy back up on 127.0.0.1:$Port."
        }
    } catch {
        $installFailure = $_
        $recoveryFailures = @()
        $restorationFailed = $false

        if ($candidateStartAttempted -and (Get-ProxyProcess)) {
            try {
                Stop-ProxyInstance | Out-Null
            } catch {
                $recoveryFailures += "candidate stop failed: $($_.Exception.Message)"
            }
        }
        if ($swapAttempted) {
            try {
                if ($hadDestination) {
                    if (-not (Test-Path -LiteralPath $rollbackExe)) {
                        throw "rollback executable is missing: $rollbackExe"
                    }
                    if (Test-Path -LiteralPath $Destination) {
                        [System.IO.File]::Replace($rollbackExe, $Destination, [System.Management.Automation.Language.NullString]::Value)
                    } else {
                        Move-Item -LiteralPath $rollbackExe -Destination $Destination -Force
                    }
                } else {
                    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                }
            } catch {
                $restorationFailed = $true
                $recoveryFailures += "executable rollback failed: $($_.Exception.Message)"
            }

            try {
                if ($hadVersionStamp) {
                    if (-not (Test-Path -LiteralPath $rollbackStamp)) {
                        throw "rollback version stamp is missing: $rollbackStamp"
                    }
                    if (Test-Path -LiteralPath $VersionStamp) {
                        [System.IO.File]::Replace($rollbackStamp, $VersionStamp, [System.Management.Automation.Language.NullString]::Value)
                    } else {
                        Move-Item -LiteralPath $rollbackStamp -Destination $VersionStamp -Force
                    }
                } else {
                    Remove-Item -LiteralPath $VersionStamp -Force -ErrorAction SilentlyContinue
                }
            } catch {
                $restorationFailed = $true
                $stampRollbackFailure = $_.Exception.Message
                try {
                    if (Test-Path -LiteralPath $VersionStamp) {
                        Remove-Item -LiteralPath $VersionStamp -Force -ErrorAction Stop
                    }
                    $recoveryFailures += "version stamp rollback failed: $stampRollbackFailure; live version stamp invalidated: $VersionStamp"
                } catch {
                    $recoveryFailures += "version stamp rollback failed: $stampRollbackFailure; live version stamp invalidation failed: $($_.Exception.Message)"
                }
            }
        }

        if ($restartAfterFailure -and -not (Get-ProxyProcess)) {
            $destinationUsable = $false
            try {
                $destinationUsable = (Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination).Length -gt 0)
            } catch {
                $recoveryFailures += "could not validate executable before proxy restart: $($_.Exception.Message)"
            }
            if ($destinationUsable) {
                try {
                    Start-ProxyBackground
                    if (-not (Wait-ProxyRunning -RequireHealthy)) {
                        throw "proxy did not come up healthy on 127.0.0.1:$Port within 20s"
                    }
                } catch {
                    $recoveryFailures += "proxy restart failed: $($_.Exception.Message)"
                }
            } else {
                $recoveryFailures += "proxy restart skipped because no usable executable exists at $Destination"
            }
        }

        if ($recoveryFailures.Count -gt 0) {
            $message = "install failed: $($installFailure.Exception.Message); recovery failed: $($recoveryFailures -join '; ')"
            if ($restorationFailed) {
                $retainRollbackArtifacts = $true
                $retainedPaths = @($rollbackExe, $rollbackStamp) | Where-Object { Test-Path -LiteralPath $_ }
                if (@($retainedPaths).Count -gt 0) {
                    $message += "; rollback artifacts retained: $($retainedPaths -join ', ')"
                }
            }
            throw $message
        }
        throw $installFailure
    } finally {
        Remove-Item -LiteralPath $stagedExe, $stagedStamp -Force -ErrorAction SilentlyContinue
        if (-not $retainRollbackArtifacts) {
            Remove-Item -LiteralPath $rollbackExe, $rollbackStamp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-ProxyBinary {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$VersionStamp,
        [Parameter(Mandatory = $true)][string]$PinnedVersion,
        [switch]$StopForSwap,
        [switch]$RestartAfterSwap
    )

    $lockPath = "$Destination.install.lock"
    if (-not (Enter-ProxyInstallLock $lockPath)) {
        $exception = [System.InvalidOperationException]::new("cli-proxy install refused: $script:ProxyInstallLockDetail")
        $exception.Data['ExitCode'] = 3
        throw $exception
    }

    try {
        Invoke-ProxyBinarySwap @PSBoundParameters
    } finally {
        Remove-ProxyInstallLock
    }
}

if ($AsLibrary) { return }

$restartCompletedDuringInstall = $false

if ($Install) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    if (-not (Test-Path $Cfg)) {
        # host 127.0.0.1 ONLY: the default empty host binds ALL interfaces, which
        # would LAN-expose the OAuth-wrapped subscription endpoint.
        $yaml = @"
host: "127.0.0.1"
port: $Port
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "$ApiKey"
"@
        [System.IO.File]::WriteAllText($Cfg, $yaml, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "wrote config: $Cfg"
    } else {
        Write-Host "config already present: $Cfg"
    }
    # Version stamp makes -Install pin-aware (CR r1 codex-1, HIMMEL-1451): a
    # bare exe-exists check would skip the download forever, so bumping $Version
    # could never roll an existing install and the drift-row's documented
    # recovery path (-Install then -Restart) would silently no-op. A missing
    # stamp (legacy install) reads as version-unknown and re-downloads the
    # pinned release once, converging the host.
    $VerStamp = Join-Path $Dir 'cli-proxy-api.version'
    $installedVer = if (Test-Path $VerStamp) { (Get-Content $VerStamp -ErrorAction SilentlyContinue | Select-Object -First 1) } else { $null }
    if ((-not (Test-Path $Exe)) -or ($installedVer -ne $Version)) {
        # Windows locks a running exe - the pinned swap cannot land over a live
        # instance, so a combined -Install -Restart (or -Install -Stop) stops the
        # proxy in THIS invocation. -Restart validates the candidate before the
        # transaction ends; the later $Stop block finds nothing to stop. The stop
        # is DEFERRED until just before
        # the atomic swap (HIMMEL-1468): it used to run BEFORE the download, so a
        # download/extract failure left the proxy DOWN until manual recovery. Now
        # the temp download/extract resolves first and the running instance is
        # touched only once the new binary and rollback copy are staged, shrinking
        # the downtime window to the same-volume Move-Item; any failure above this
        # point leaves the old binary serving.
        $stopForSwap = $false
        if ((Test-Path $Exe) -and (Get-ProxyProcess)) {
            if ($Restart -or $Stop) {
                $stopForSwap = $true
            } else {
                # Standalone -Install: refuse loudly with the working order
                # instead of failing later on an opaque Copy-Item lock error.
                throw "installed version '$(if ($installedVer) { $installedVer } else { 'unknown' })' != pinned v$Version and the proxy is RUNNING - run -Stop first, then -Install, then -Start (or use the combined -Install -Restart)"
            }
        }
        # Unique per-run temp paths; cleanup in finally so a failed download/extract
        # leaves no orphaned artifacts. Trust boundary = pinned HTTPS release URL
        # (operator-accepted, HIMMEL-979); upstream publishes no per-asset checksum.
        $stamp = [guid]::NewGuid().ToString('N')
        $zip = Join-Path $env:TEMP "cliproxy-$stamp.zip"
        $tmp = Join-Path $env:TEMP "cliproxy-$stamp"
        try {
            Write-Host "downloading CLIProxyAPI v$Version ..."
            Invoke-WebRequest -Uri $Release -OutFile $zip
            Expand-Archive -Force $zip $tmp
            $src = Get-ChildItem -Recurse $tmp -Filter 'cli-proxy-api.exe' | Select-Object -First 1 -ExpandProperty FullName
            if (-not $src) { throw "cli-proxy-api.exe not found in release archive" }
            try {
                $restartAfterSwap = [bool]$Restart
                Install-ProxyBinary -Source $src -Destination $Exe -VersionStamp $VerStamp -PinnedVersion $Version -StopForSwap:$stopForSwap -RestartAfterSwap:$restartAfterSwap
                $restartCompletedDuringInstall = $restartAfterSwap
            } catch {
                if ($_.Exception.Data['ExitCode'] -eq 3) {
                    Write-Error $_.Exception.Message -ErrorAction Continue
                    exit 3
                }
                throw
            }
            Write-Host "installed binary: $Exe (v$Version)"
        } finally {
            Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "binary already present at pinned v${Version}: $Exe"
    }
}

if ($Login) {
    Assert-Exe; Assert-Config
    Write-Host "codex device-login: open the printed URL on any browser, enter the code,"
    Write-Host "and sign in with your codex / ChatGPT account. Writes ~/.cli-proxy-api/codex-<email>.json."
    # -config is required even for login: the binary reads it to locate auth-dir,
    # and defaults to .\config.yaml (cwd) when omitted -> fails outside ~/.cli-proxy-api.
    & $Exe -config $Cfg -codex-device-login
    # PowerShell 5.1 does not stop on a native non-zero exit; surface it.
    if ($LASTEXITCODE -ne 0) { throw "codex device-login failed (exit $LASTEXITCODE)" }
}

if ($Register) {
    Assert-Exe; Assert-Config
    # Windowless logon task so no console pops on every sign-in.
    $tr = "powershell -NoProfile -WindowStyle Hidden -Command `"& '$Exe' -config '$Cfg'`""
    schtasks /create /tn 'cli-proxy-api' /sc onlogon /rl limited /f /tr $tr | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /create failed (exit $LASTEXITCODE) - run elevated if it is a permissions error" }
    Write-Host "registered logon task 'cli-proxy-api' (runs the proxy at sign-in)"
    # Start it now too (windowless) so -Register brings the proxy up immediately,
    # not only at the next sign-in. -Start is foreground and dies with the terminal.
    schtasks /run /tn 'cli-proxy-api' | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "started 'cli-proxy-api' now (windowless background)" }
    else { Write-Warning "task registered but immediate /run failed (exit $LASTEXITCODE) - it will still start at next sign-in" }
}

if ($Start) {
    Assert-Exe; Assert-Config
    if (-not (Test-OAuth)) { Write-Warning "no codex OAuth found - cc-codex will 401 until you run -Login" }
    Write-Host "starting proxy on 127.0.0.1:$Port (Ctrl-C to stop) ..."
    & $Exe -config $Cfg
    if ($LASTEXITCODE -ne 0) { throw "proxy exited with error (exit $LASTEXITCODE)" }
}

if ($Verify) {
    $code = Get-ProxyCode
    Write-Host "proxy http://127.0.0.1:$Port -> HTTP $code  (200/401 = reachable; 000 = not running)"
}

if ($Stop) {
    Assert-BounceSafe
    if (Get-ProxyProcess) {
        Write-Host "stopping cli-proxy-api ..."
        Stop-ProxyInstance | Out-Null
        Write-Host "stopped."
    } else {
        Write-Host "no running cli-proxy-api process (nothing to stop)."
    }
}

if ($Restart -and -not $restartCompletedDuringInstall) {
    Assert-Exe; Assert-Config
    Assert-BounceSafe
    if (Get-ProxyProcess) {
        Write-Host "stopping cli-proxy-api ..."
        Stop-ProxyInstance | Out-Null
    }
    Write-Host "relaunching proxy (windowless) ..."
    Start-ProxyBackground
    # Verify /v1/models answers (200 = up + key accepted; 401 = up, key rejected).
    if (-not (Wait-ProxyRunning)) {
        throw "proxy did not come up on 127.0.0.1:$Port within 20s (run -Verify, or -Start in the foreground to see the error)"
    }
    Write-Host "proxy back up on 127.0.0.1:$Port."
}

if (-not ($Install -or $Login -or $Start -or $Register -or $Stop -or $Restart -or $Verify)) {
    Write-Host "== CLIProxyAPI codex lane (HOST-only; serves this host + its WSL via 127.0.0.1:$Port) =="
    $hasExe = Test-Path $Exe
    $hasCfg = Test-Path $Cfg
    $hasOA  = Test-OAuth
    $run    = Test-Running
    "{0,-12} {1}" -f 'binary:',    $(if ($hasExe) { "OK   $Exe" }              else { 'MISSING  -> -Install' })
    "{0,-12} {1}" -f 'config:',    $(if ($hasCfg) { "OK   $Cfg" }              else { 'MISSING  -> -Install' })
    "{0,-12} {1}" -f 'codex auth:',$(if ($hasOA)  { 'OK' }                     else { 'MISSING  -> -Login' })
    "{0,-12} {1}" -f 'running:',   $(if ($run)    { "OK   127.0.0.1:$Port" }   else { 'no       -> -Start (then -Register to restart at sign-in)' })
    Write-Host ''
    if (-not $hasExe -or -not $hasCfg) { Write-Host 'NEXT: .\cli-proxy-lane.ps1 -Install' }
    elseif (-not $hasOA)               { Write-Host 'NEXT: .\cli-proxy-lane.ps1 -Login   (then -Start, then -Register)' }
    elseif (-not $run)                 { Write-Host 'NEXT: .\cli-proxy-lane.ps1 -Start   (and -Register to restart at sign-in)' }
    else                               { Write-Host 'lane is up. Test: bash $HOME/Documents/github/himmel/scripts/claude-codex -p "reply OK"' }
}
