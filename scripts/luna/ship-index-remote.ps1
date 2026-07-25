# ASCII-ONLY, deliberately. This file is UTF-8 on disk, but Windows PowerShell
# 5.1 reads a BOM-less script using the ANSI codepage: a UTF-8 em dash
# (E2 80 94) decodes to the three chars a-circumflex, euro, and RIGHT DOUBLE
# QUOTATION MARK -- and PowerShell accepts that curly quote AS A STRING
# DELIMITER. One em dash inside a double-quoted string therefore desyncs every
# quote after it and the whole script fails to parse. Verified: 18 em dashes
# produced 4 parse errors and the receiver would not have run at all. Same rule
# the cadence emitters already follow for their .bat files. Keep it ASCII.
#
# ship-index-remote.ps1 -- the RECEIVER half of the qmd index ship (HIMMEL-1275).
#
# Runs ON the receiving machine (win2). scripts/luna/ship-index.sh copies this
# file over alongside the staged index and invokes it. It is a FILE, not an
# inline `ssh host 'powershell -Command "..."'` string, on purpose: the quoting
# that survives Git-Bash -> ssh -> cmd.exe -> powershell is
# `ssh host 'powershell -NoProfile -Command "..."'` and a nested `\"` inside
# that breaks cmd parsing outright. Anything with real logic in it therefore
# belongs in a script file, not in the command line.
#
# Contract: prints one `SHIP-REMOTE: <key>=<value>` line per step so the caller
# can parse a machine-readable result, and exits non-zero on any failure.
#
# Exit codes:
#   0  swapped + daemon restarted + verified
#   1  usage / staged file missing or implausible
#   2  daemon stop failed
#   3  swap failed (previous index left in place)
#   4  daemon restart failed (index WAS swapped -- say so loudly)
#   5  post-swap verify failed (vectors lag lex, or qmd unusable)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Staged,   # incoming index (already uploaded)
    [Parameter(Mandatory = $true)][string]$Target,   # live index path to replace
    [int]$ExpectDocs = -1,                            # from the sender's stats
    [int]$ExpectVectors = -1,
    [switch]$NoRestart                                # leave the daemon down (debug)
)

$ErrorActionPreference = 'Stop'
function Emit($k, $v) { Write-Output "SHIP-REMOTE: $k=$v" }

# Write to stderr DIRECTLY, not via Write-Error (CR finding [codex-1], verified
# by hand). Under $ErrorActionPreference='Stop', Write-Error raises a
# TERMINATING error, so the following `exit $code` never runs and the script
# dies with PowerShell's generic status 1 instead. That silently collapses every
# stage-specific code in the contract above into "1" -- and the distinction it
# destroys is the one that matters most after a failure: 3 means the index was
# NOT swapped, 4 means it WAS. Measured: the Write-Error form exits 1 where this
# form exits 5. A terminating error would also be swallowed by the enclosing
# try/catch blocks below and re-reported as the wrong stage.
function Fail($code, $msg) {
    [Console]::Error.WriteLine("ship-index-remote: $msg")
    exit $code
}

# Bring the qmd daemon back up, WMI-parented so it outlives the ssh session.
# Returns the new PID, or $null. Used BOTH on the success path and on the
# swap-failure path -- a failed ship must not leave the receiver's search
# service DOWN just because the swap did not happen (CR finding [codex-1]).
function Start-QmdDaemon {
    $qmd = (Get-Command qmd -ErrorAction SilentlyContinue).Source
    if (-not $qmd) { return $null }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$qmd`" mcp --keep-models" }
    if ($r.ReturnValue -ne 0) { return $null }
    return $r.ProcessId
}

if (-not (Test-Path -LiteralPath $Staged)) { Fail 1 "staged index not found: $Staged" }
$stagedSize = (Get-Item -LiteralPath $Staged).Length
# A truncated/partial upload is the failure mode that would otherwise be
# discovered only by a broken search days later. 50MB is far below any real
# index and far above any plausible stub.
if ($stagedSize -lt 50MB) { Fail 1 "staged index is implausibly small ($stagedSize bytes) -- refusing to swap in a likely-truncated upload" }
Emit 'staged_bytes' $stagedSize

# --- 1. Stop the qmd daemon --------------------------------------------------
# The daemon is BUN, not node. A node-only filter both misses it and matches
# dozens of unrelated processes (this box runs ~40 node.exe). Match on the
# executable AND require the command line to mention qmd, so an unrelated bun
# process is left alone.
$stopped = @()
try {
    # -ErrorAction Stop, NOT SilentlyContinue: a FAILED enumeration would
    # otherwise be indistinguishable from "no daemon is running", and we would
    # go on to swap a file the daemon still holds open.
    $procs = Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'" -ErrorAction Stop
    foreach ($p in $procs) {
        if ($p.CommandLine -and $p.CommandLine -match 'qmd') {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $stopped += $p.ProcessId
        }
    }
} catch {
    # Report what we DID stop before failing. A partial stop otherwise leaves the
    # operator unable to tell whether a daemon needs restarting by hand.
    Emit 'stopped_before_failure' ($(if ($stopped.Count) { $stopped -join ',' } else { 'none' }))
    Fail 2 "failed to stop the qmd daemon: $($_.Exception.Message)"
}
Emit 'stopped_pids' ($(if ($stopped.Count) { $stopped -join ',' } else { 'none' }))

# Give the OS a moment to release the file handles before the swap; a swap
# against a still-mapped SQLite file fails with a sharing violation.
if ($stopped.Count -gt 0) { Start-Sleep -Seconds 3 }

# --- 2. Swap ------------------------------------------------------------------
# The previous index moves aside to .preship FIRST, so a failed move-in can be
# rolled back. It is REAPED below on success and on failure -- two stale copies
# (365MB + 221MB) once sat here for days.
$preship = "$Target.preship"
# Refuse a self-swap BEFORE anything moves. If -Staged resolves to the live
# index (or to the recovery copy), the move sequence would shuffle a file onto
# itself and could destroy the only copy. Compare normalized full paths, since
# the two can be spelled differently and still be the same file.
$normStaged = [System.IO.Path]::GetFullPath($Staged)
$normTarget = [System.IO.Path]::GetFullPath($Target)
$normPreship = [System.IO.Path]::GetFullPath($preship)
if ($normStaged -ieq $normTarget) {
    Fail 1 "staged index and target are the same file ($normTarget) -- refusing to swap a file onto itself"
}
if ($normStaged -ieq $normPreship) {
    Fail 1 "staged index is the recovery copy ($normPreship) -- refusing to swap, this would destroy the rollback"
}
$rolledBack = $false
try {
    if (Test-Path -LiteralPath $preship) { Remove-Item -LiteralPath $preship -Force }
    if (Test-Path -LiteralPath $Target) { Move-Item -LiteralPath $Target -Destination $preship -Force }
    # Retire the OUTGOING index's -wal/-shm sidecars. Moving only the main file
    # would leave journals belonging to the PREVIOUS database sitting exactly
    # where SQLite looks for the new one's -- it would attach them to the freshly
    # shipped index. The uploaded file arrives as a single artifact with no
    # sidecars of its own (prepare-ship-index checkpoints on close), so removing
    # is right here; there is nothing to carry across.
    foreach ($sfx in @('-wal', '-shm')) {
        $side = "$Target$sfx"
        if (Test-Path -LiteralPath $side) { Remove-Item -LiteralPath $side -Force }
    }
    Move-Item -LiteralPath $Staged -Destination $Target -Force
} catch {
    # Put the old index back rather than leaving the machine with none.
    try {
        if ((Test-Path -LiteralPath $preship) -and -not (Test-Path -LiteralPath $Target)) {
            Move-Item -LiteralPath $preship -Destination $Target -Force
            $rolledBack = $true
        }
    } catch {
        # Surface it. A silently-swallowed rollback failure is the difference
        # between "the swap failed, your old index is back" and "the swap failed
        # and the machine now has NO index" -- the operator must be told which.
        Write-Warning "ROLLBACK FAILED -- the receiver may have no index at ${Target}: $($_.Exception.Message)"
    }
    Emit 'rolled_back' $rolledBack
    # We stopped the daemon before the swap. Bailing out now without restarting
    # would leave the receiver with its ORIGINAL index restored but its search
    # service DOWN -- a failed ship silently taking the machine offline for
    # search, which is worse than the failed ship itself. Restart before exiting
    # (best effort, and reported either way).
    if (-not $NoRestart -and $stopped.Count -gt 0) {
        $backPid = $null
        try { $backPid = Start-QmdDaemon } catch { }
        Emit 'restarted_after_failure' $(if ($backPid) { $backPid } else { 'FAILED' })
    }
    Fail 3 "swap failed: $($_.Exception.Message)"
}
Emit 'swapped' 'yes'

# Reap the pre-ship copy immediately on the success path. Keeping it "just in
# case" is exactly how the stale copies accumulated.
# Report what ACTUALLY happened: an unconditional 'yes' here would mask a
# failed delete and re-create the stale-copy problem this reap exists to solve,
# while the caller's log claimed it was handled.
try {
    if (Test-Path -LiteralPath $preship) { Remove-Item -LiteralPath $preship -Force }
    Emit 'preship_reaped' 'yes'
} catch {
    Write-Warning "could not remove the pre-ship index at ${preship}: $($_.Exception.Message)"
    Emit 'preship_reaped' 'no'
}

# --- 3. Restart the daemon, WMI-parented -------------------------------------
# Invoke-CimMethod Win32_Process Create, NOT Start-Process: a child of the ssh
# session dies with the connection, so the daemon would silently vanish the
# moment the ship script disconnects.
if (-not $NoRestart) {
    try {
        $newPid = Start-QmdDaemon
        if (-not $newPid) { Fail 4 'could not restart the qmd daemon (qmd missing from PATH, or Win32_Process Create failed) -- index WAS swapped' }
        Emit 'restarted_pid' $newPid
    } catch {
        Fail 4 "daemon restart failed (index WAS swapped): $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 3
} else {
    Emit 'restarted_pid' 'skipped'
}

# --- 4. Verify -- fail LOUD if vectors lag lex --------------------------------
# This is the check that exists because win2 sat at 14,803 lex docs with ~5,200
# vectors missing and answered semantic queries off that gap in silence.
$statusText = ''
# Drop to 'Continue' around the NATIVE call. Under 'Stop', anything qmd writes
# to stderr -- including harmless progress noise -- is promoted to a TERMINATING
# error by the `2>&1` merge, so a perfectly healthy status would abort the
# verification on a machine whose index was just replaced. We still want the
# stderr text (it goes into the failure message), hence the merge; we just do
# not want its mere presence to be fatal. $LASTEXITCODE below is the real signal.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $statusText = (& qmd status 2>&1 | Out-String) }
catch { $ErrorActionPreference = $prevEap; Fail 5 "qmd status failed after swap: $($_.Exception.Message)" }
$ErrorActionPreference = $prevEap
# A native command's NON-ZERO EXIT does not throw, so the catch above never sees
# it. Without this check a failing `qmd status` would fall through to the regex
# parse, find nothing, and be reported as "could not parse" -- misdiagnosing a
# broken qmd as a format change, on a machine whose index was just replaced.
if ($LASTEXITCODE -ne 0) {
    Fail 5 "qmd status exited $LASTEXITCODE after the swap -- the receiver's qmd is not usable.`n$statusText"
}

$docs = $null; $vecs = $null; $pending = 0
if ($statusText -match 'Total:\s+(\d+)\s+files indexed') { $docs = [int]$Matches[1] }
if ($statusText -match 'Vectors:\s+(\d+)\s+embedded') { $vecs = [int]$Matches[1] }
if ($statusText -match 'Pending:\s+(\d+)\s+need embedding') { $pending = [int]$Matches[1] }

Emit 'docs' $(if ($null -ne $docs) { $docs } else { 'unparsed' })
Emit 'vectors' $(if ($null -ne $vecs) { $vecs } else { 'unparsed' })
Emit 'pending' $pending

if ($null -eq $docs -or $null -eq $vecs) {
    Fail 5 "could not parse doc/vector counts from qmd status -- refusing to call the ship verified.`n$statusText"
}
if ($pending -gt 0) {
    Fail 5 "$pending content hash(es) still need embedding after the swap -- vectors LAG lex. This is the silent-wrong state the ship exists to eliminate; the shipped artifact was not fully embedded at the source."
}
if ($ExpectVectors -ge 0 -and $vecs -ne $ExpectVectors) {
    Fail 5 "vector count mismatch: receiver reports $vecs, sender shipped $ExpectVectors"
}
if ($ExpectDocs -ge 0 -and $docs -ne $ExpectDocs) {
    Fail 5 "document count mismatch: receiver reports $docs, sender shipped $ExpectDocs"
}

Emit 'verified' 'ok'
exit 0
