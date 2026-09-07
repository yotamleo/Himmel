<#
.SYNOPSIS
  Upgrade the installed rtk binary (rtk-ai/rtk) to the latest GitHub release.
  Windows twin of upgrade-rtk.sh (HIMMEL-1323) -- see that file for the WHY.

.DESCRIPTION
  This is an UPGRADER, not an installer: a machine with no rtk installed is
  rc=2. Safety sequence: record the current version -> back up the rtk binary
  itself (NOT its parent directory, which other tools can share -- see the
  backup block below) -> extract the new release zip over the live install
  dir (mirrors win11.ps1's "Install RTK" step) -> smoke-test (--version must
  parse strictly newer, plus a trivial `rtk ls <tmpdir>` functional probe) ->
  on a failure AFTER the live install was modified, restore the backed-up
  binary and exit 4; a download failure (before modification) exits 2 with no
  rollback. A machine must never be left with a broken rtk.

.PARAMETER DryRun
  Report the current/target version + paths; change nothing.

.NOTES
  Test seams (env vars, all unset in production):
    RTK_BIN            command name resolved via Get-Command (default: rtk)
    RTK_LATEST_TAG     skip the GitHub releases/latest API call and use this
                       tag directly (e.g. v0.44.0)
    RTK_INSTALL_DIR    scratch dir for the downloaded zip + the pre-upgrade
                       backup (default: $env:TEMP\rtk-upgrade)
    RTK_DOWNLOAD_CMD   replace the entire fetch+extract step with this
                       command (run via cmd.exe /c); env RTK_TARGET_VERSION /
                       RTK_TARGET_TAG / RTK_BIN_PATH / RTK_INSTALL_DIR are set
                       for it to read
    RTK_UPGRADE_LOCK_TTL  seconds after which a held concurrency lock is
                       presumed abandoned and reclaimed (default: 1800)

  Exit codes: 0 upgraded/already current; 2 invalid input or a failure before
  the live install was modified (including download failure); 3 another
  upgrade already holds the concurrency lock -- refused, never queued; 4 a
  failure after modification was possible, with rollback success or failure
  announced.
#>
param(
    [switch]$DryRun
)

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Same version shape as scripts/upstreams.json's rtk `version_regex`.
$VersionRegex = '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.\-]*'

# Test-IsNewer <candidate> <baseline> -- compares the leading dotted-numeric
# run only (a trailing suffix like -rc1 is ignored), same discipline
# upgrade-rtk.sh's bash-native is_newer() comparison uses (CR: the two used to
# diverge on a suffixed tag when the bash side was `sort -V`-based).
function Test-IsNewer([string]$Candidate, [string]$Baseline) {
    if ($Candidate -eq $Baseline) { return $false }
    $c = ([regex]::Match($Candidate, '^[0-9]+(\.[0-9]+)*')).Value
    $b = ([regex]::Match($Baseline, '^[0-9]+(\.[0-9]+)*')).Value
    if (-not $c -or -not $b) { return $false }
    try {
        return ([version]$c) -gt ([version]$b)
    } catch {
        # Component-wise numeric compare, NOT [string]::Compare (CR glm-5).
        # Lexicographic ordering is simply wrong for versions — it puts 0.10.0
        # BELOW 0.9.0, which here would mean silently refusing a real upgrade.
        # Only reachable when the [version] cast fails on an odd version string,
        # but a fallback whose whole job is ordering must at least order.
        $ca = $c -split '\.'; $ba = $b -split '\.'
        for ($i = 0; $i -lt [Math]::Max($ca.Count, $ba.Count); $i++) {
            $cv = if ($i -lt $ca.Count) { [int]$ca[$i] } else { 0 }
            $bv = if ($i -lt $ba.Count) { [int]$ba[$i] } else { 0 }
            if ($cv -ne $bv) { return ($cv -gt $bv) }
        }
        return $false
    }
}

$RtkBinName = if ($env:RTK_BIN) { $env:RTK_BIN } else { 'rtk' }
$rtkCmd = Get-Command $RtkBinName -ErrorAction SilentlyContinue
if (-not $rtkCmd) {
    Write-Error "upgrade-rtk: '$RtkBinName' is not installed -- this is an upgrader, not an installer. Run machine-setup provisioning first."
    exit 2
}
$RtkBinPath = $rtkCmd.Source
$RtkLiveDir = Split-Path $RtkBinPath -Parent

$currentRaw = & $RtkBinPath --version 2>&1 | Out-String
$currentRc = $LASTEXITCODE
if ($currentRc -ne 0) {
    Write-Error "upgrade-rtk: '$RtkBinPath --version' failed to run (rc=$currentRc) -- can't establish a baseline, refusing to upgrade."
    exit 2
}
$currentMatch = [regex]::Match($currentRaw, $VersionRegex)
if (-not $currentMatch.Success) {
    Write-Error "upgrade-rtk: could not parse a version from: $currentRaw"
    exit 2
}
$CurrentVersion = $currentMatch.Value

if ($env:RTK_LATEST_TAG) {
    $TargetTag = $env:RTK_LATEST_TAG
} else {
    try {
        $TargetTag = (Invoke-RestMethod "https://api.github.com/repos/rtk-ai/rtk/releases/latest" -TimeoutSec 30).tag_name
    } catch {
        Write-Error "upgrade-rtk: could not resolve the latest rtk release tag from the GitHub API: $_"
        exit 2
    }
    if (-not $TargetTag) {
        Write-Error "upgrade-rtk: GitHub API returned no tag_name for the latest rtk release."
        exit 2
    }
}
$TargetVersion = $TargetTag -replace '^v', ''
if (-not [regex]::IsMatch($TargetVersion, "^$VersionRegex$")) {
    Write-Error "upgrade-rtk: invalid release tag '$TargetTag' -- expected a version like v0.44.0."
    exit 2
}

if (-not (Test-IsNewer $TargetVersion $CurrentVersion)) {
    Write-Host "upgrade-rtk: already current (installed $CurrentVersion, latest $TargetVersion) -- nothing to do."
    exit 0
}

if ($DryRun) {
    Write-Host "DRY upgrade-rtk: $RtkBinPath  $CurrentVersion -> $TargetVersion (tag $TargetTag)"
    Write-Host "DRY would back up $RtkBinPath, extract the new release zip over $RtkLiveDir, smoke-test, and roll back on any failure."
    exit 0
}

$InstallDir = if ($env:RTK_INSTALL_DIR) { $env:RTK_INSTALL_DIR } else { "$env:TEMP\rtk-upgrade" }

# --------------------------------------------------------------------------
# Concurrency lock (CR round 4, HIMMEL-1323): nothing else here serializes
# overlapping invocations, and this repo genuinely runs several concurrent
# Claude sessions (HIMMEL-1338) -- two overlapping upgrades sharing the same
# InstallDir (this twin's DEFAULT IS shared: $env:TEMP\rtk-upgrade) can
# overwrite each other's backup or roll back to a stale binary. Same
# lock-directory idiom as the bash twin / scripts/ci/run-shell-tests.sh's
# suite lock (HIMMEL-1338): a lock DIRECTORY (New-Item is the atomic
# create-if-absent primitive on Windows, mirroring mkdir-locks), branded
# with an owner file (pid/host/started) so a crashed holder's lock can be
# told apart from a live one via a TTL. Scaled down from that lock: this one
# never queues -- a stacked nightly upgrade must fail fast (exit 3), not
# wait -- so it skips the takeover-claim CAS dance that lock needs only to
# make a RECLAIM race-safe under contention this script never sees.
$script:RtkLockDir = $null
$script:RtkLockOwned = $false

function Get-RtkLockHost {
    if ($env:COMPUTERNAME) { return $env:COMPUTERNAME }
    try { return [System.Net.Dns]::GetHostName() } catch { return 'unknown' }
}

# Get-RtkLockField <owner-file> <key> -> value, or '' if absent/unreadable.
function Get-RtkLockField([string]$Path, [string]$Key) {
    if (-not (Test-Path $Path)) { return '' }
    foreach ($line in Get-Content $Path -ErrorAction SilentlyContinue) {
        $parts = $line -split '=', 2
        if ($parts.Length -eq 2 -and $parts[0] -eq $Key) { return $parts[1] }
    }
    return ''
}

function Remove-RtkLock {
    if (-not $script:RtkLockOwned) { return }
    Remove-Item -Force (Join-Path $script:RtkLockDir 'owner') -ErrorAction SilentlyContinue
    Remove-Item -Force $script:RtkLockDir -ErrorAction SilentlyContinue
    $script:RtkLockOwned = $false
}

# Write-RtkLockOwner -- create-EXCLUSIVE (never overwrite), the same intent
# as the bash twin's `set -C`: a co-winner of a non-atomic New-Item loses
# here instead of silently overwriting the real winner's brand.
function Write-RtkLockOwner([string]$Dir) {
    $ownerPath = Join-Path $Dir 'owner'
    try {
        $fs = [System.IO.File]::Open($ownerPath, [System.IO.FileMode]::CreateNew)
        $writer = New-Object System.IO.StreamWriter($fs)
        $writer.WriteLine("pid=$PID")
        $writer.WriteLine("host=$(Get-RtkLockHost)")
        $writer.WriteLine("started=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
        $writer.Close()
        $fs.Close()
        return $true
    } catch {
        return $false
    }
}

# Enter-RtkLock <dir> -- $true once this process holds the lock; $false to
# refuse (caller exits 3). Never waits.
function Enter-RtkLock([string]$Dir) {
    $script:RtkLockDir = $Dir
    $ttl = if ($env:RTK_UPGRADE_LOCK_TTL) { [int]$env:RTK_UPGRADE_LOCK_TTL } else { 1800 }

    $created = $false
    try {
        New-Item -ItemType Directory -Path $Dir -ErrorAction Stop | Out-Null
        $created = $true
    } catch { }

    if ($created) {
        if (Write-RtkLockOwner $Dir) {
            $script:RtkLockOwned = $true
            return $true
        }
        if (-not (Test-Path (Join-Path $Dir 'owner'))) {
            Remove-Item -Force $Dir -ErrorAction SilentlyContinue
        }
        return $false
    }

    $ownerPath = Join-Path $Dir 'owner'
    $oPid = Get-RtkLockField $ownerPath 'pid'
    $oHost = Get-RtkLockField $ownerPath 'host'
    $oStarted = Get-RtkLockField $ownerPath 'started'
    $thisHost = Get-RtkLockHost
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $age = -1
    if ($oStarted -match '^\d+$') { $age = $now - [long]$oStarted }

    $stale = $false
    if ($oPid -and $oHost -eq $thisHost) {
        $proc = Get-Process -Id $oPid -ErrorAction SilentlyContinue
        if (-not $proc) { $stale = $true }
    }
    if ($age -ge $ttl) { $stale = $true }

    if ($stale) {
        Remove-Item -Force $ownerPath -ErrorAction SilentlyContinue
        Remove-Item -Force $Dir -ErrorAction SilentlyContinue
        try {
            New-Item -ItemType Directory -Path $Dir -ErrorAction Stop | Out-Null
            if (Write-RtkLockOwner $Dir) {
                Write-Warning "upgrade-rtk: cleared an abandoned lock (pid=$oPid host=$oHost age=${age}s) at $Dir"
                $script:RtkLockOwned = $true
                return $true
            }
        } catch { }
    }

    Write-Error "upgrade-rtk: another upgrade already holds the lock (pid=$oPid host=$oHost age=${age}s) -- $Dir"
    Write-Error "    refusing to queue -- the nightly cadence never stacks concurrent upgrades. Re-run once it finishes."
    return $false
}

# Exit-Upgrade -- the ONLY way this script exits once the lock is held, so
# release can never be missed on any of the several exit points below.
function Exit-Upgrade([int]$Code) {
    Remove-RtkLock
    exit $Code
}

if (-not (Enter-RtkLock "$InstallDir.lock")) {
    exit 3
}

# Back up the BINARY, not $RtkLiveDir (CR glm-3): $RtkLiveDir is the binary's
# parent directory, which other tools can share (e.g. a shared ~/.local/bin).
# A directory-level backup/restore meant Restore-Backup below had to
# Remove-Item -Recurse that shared directory before restoring into it --
# on a failed restore, every OTHER tool living there is gone too. Matching
# the bash twin's semantics (a single-file cp) keeps the blast radius to the
# one file this script actually owns.
try {
    New-Item -ItemType Directory -Force $InstallDir -ErrorAction Stop | Out-Null
    $BackupPath = Join-Path $InstallDir 'rtk.pre-upgrade.bak'
    Copy-Item -Force $RtkBinPath $BackupPath -ErrorAction Stop
    if (-not (Test-Path $BackupPath)) {
        throw "backup file was not created"
    }
} catch {
    Write-Error "upgrade-rtk: could not back up $RtkBinPath to $BackupPath -- refusing to upgrade without a backup: $_"
    Exit-Upgrade 2
}

# Returns $true ONLY when the binary was actually restored (CR round-2
# codex-1). Copy-Item's failures are NON-terminating by default, so the previous
# body could fail and still fall through to the caller's unconditional
# "ROLLED BACK" line. This is the same defect fixed on the bash side in round 1
# — missed here because the two platforms carry separate copies of the rollback,
# which is exactly why a two-platform fix needs checking on both.
function Restore-Backup {
    try {
        Copy-Item -Force $BackupPath $RtkBinPath -ErrorAction Stop
    } catch {
        Write-Error "upgrade-rtk: restore of $RtkBinPath from $BackupPath failed: $_"
        return $false
    }
    # Verify rather than trust the copy's silence: a backup taken from an
    # already-partial install would copy "successfully" and still leave no
    # working binary.
    return (Test-Path $RtkBinPath)
}

# The ONLY place a rollback outcome is announced, mirroring announce_rollback in
# the bash twin so the two platforms cannot drift on this again.
function Announce-Rollback {
    if (Restore-Backup) {
        Write-Error "upgrade-rtk: ROLLED BACK -- $RtkBinPath restored to $CurrentVersion."
    } else {
        Write-Error "upgrade-rtk: ROLLBACK FAILED -- could NOT restore $RtkBinPath from $BackupPath."
        Write-Error "    The installed rtk may be broken or absent. Restore it by hand:"
        Write-Error "        Copy-Item -Force '$BackupPath' '$RtkBinPath'"
    }
}

$installOk = $true
if ($env:RTK_DOWNLOAD_CMD) {
    $env:RTK_TARGET_VERSION = $TargetVersion
    $env:RTK_TARGET_TAG = $TargetTag
    $env:RTK_BIN_PATH = $RtkBinPath
    $env:RTK_INSTALL_DIR = $InstallDir
    & cmd.exe /c $env:RTK_DOWNLOAD_CMD
    if ($LASTEXITCODE -ne 0) { $installOk = $false }
} else {
    # Real flow, mirrors win11.ps1's "Install RTK" step.
    $RtkZipName = 'rtk-x86_64-pc-windows-msvc.zip'
    $RtkUrl = "https://github.com/rtk-ai/rtk/releases/download/$TargetTag/$RtkZipName"
    $RtkZipPath = Join-Path $InstallDir $RtkZipName
    # Download and extract are split deliberately (CR codex-2). They fail
    # differently: the download writes only into the scratch InstallDir, so the
    # live install is untouched and exit 2 is honest. Expand-Archive writes
    # INTO $RtkLiveDir, so a failure part-way through leaves the live install
    # half-overwritten — exiting there without restoring was how a partial
    # extract could leave rtk corrupted with no rollback.
    try {
        Invoke-WebRequest $RtkUrl -OutFile $RtkZipPath -TimeoutSec 60 -ErrorAction Stop
    } catch {
        Write-Error "upgrade-rtk: download of $RtkZipName ($TargetTag) failed: $_ -- $RtkLiveDir was never touched."
        Exit-Upgrade 2
    }
    try {
        Expand-Archive -Path $RtkZipPath -DestinationPath $RtkLiveDir -Force -ErrorAction Stop
    } catch {
        Write-Error "upgrade-rtk: extract of $RtkZipName ($TargetTag) into $RtkLiveDir failed: $_"
        $installOk = $false
    }
}

if (-not $installOk) {
    Write-Error "upgrade-rtk: install step failed -- restoring the pre-upgrade backup."
    Announce-Rollback
    Exit-Upgrade 4
}

$newRaw = & $RtkBinPath --version 2>&1 | Out-String
$newRc = $LASTEXITCODE
$newMatch = [regex]::Match($newRaw, $VersionRegex)
$NewVersion = if ($newMatch.Success) { $newMatch.Value } else { $null }
if ($newRc -ne 0 -or -not $NewVersion -or -not (Test-IsNewer $NewVersion $CurrentVersion)) {
    Write-Error "upgrade-rtk: smoke test FAILED ('$RtkBinPath --version' -> rc=$newRc, parsed='$NewVersion', expected > $CurrentVersion) -- restoring the pre-upgrade backup."
    Announce-Rollback
    Exit-Upgrade 4
}

# Functional probe: `rtk ls <tmpdir>` -- verified by hand against the real
# 0.43.0 install (rc=0, prints a compact file listing) before this script was
# written, so a rc!=0 here is a genuine functional regression, not a fluke.
$ProbeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rtk-upgrade-probe-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $ProbeDir | Out-Null
New-Item -ItemType File -Force (Join-Path $ProbeDir 'probe.txt') | Out-Null
& $RtkBinPath ls $ProbeDir | Out-Null
$probeRc = $LASTEXITCODE
Remove-Item -Recurse -Force $ProbeDir -ErrorAction SilentlyContinue
if ($probeRc -ne 0) {
    Write-Error "upgrade-rtk: functional smoke test FAILED ('$RtkBinPath ls <tmpdir>' did not exit 0) -- restoring the pre-upgrade backup."
    Announce-Rollback
    Exit-Upgrade 4
}

Remove-Item -Force $BackupPath -ErrorAction SilentlyContinue
Write-Host "upgrade-rtk: OK -- $RtkBinPath  $CurrentVersion -> $NewVersion"
Exit-Upgrade 0
