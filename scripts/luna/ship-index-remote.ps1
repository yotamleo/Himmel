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
#   5  post-swap verify failed (doc/vector counts lag or mismatch, or qmd
#      unusable -- see Get-ShipVerdict)
#   6  index shipped + verified OK, but the HTTP-singleton MCP daemon restore
#      FAILED after the stop sweep (round 4 [codex-adv-6]). The PRIMARY
#      contract (swap + plain daemon + verify) succeeded; only the auxiliary
#      HTTP surface (port 8181) may still be down -- surfaced loudly rather
#      than silently reporting a clean 0 while unattended automation gets no
#      signal. Never returned when a PRIMARY stage (2/3/4/5) already failed --
#      that code always wins; restore failure only ever escalates a success.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Staged,   # incoming index (already uploaded)
    [Parameter(Mandatory = $true)][string]$Target,   # live index path to replace
    [int]$ExpectDocs = -1,                            # from the sender's stats
    [int]$ExpectVectors = -1,
    [string]$EnsureScript = '',                       # ensure-qmd-daemon.ps1, uploaded alongside (HIMMEL-1416)
    [switch]$NoRestart                                # leave the daemon down (debug)
)

$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
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

# Decides whether a process is one of the qmd-hosting shapes the stop sweep
# must reap (HIMMEL-1416). Pulled out as its own function so the matching
# logic is unit-testable without a live process list.
#
# qmd.exe is matched on NAME ALONE, unconditionally, BEFORE the CommandLine
# guard below -- no false-positive risk, since any process literally named
# qmd.exe is the daemon. This matters because Get-CimInstance Win32_Process
# commonly returns a NULL CommandLine for an other-session/elevated process
# (access denied to read it) -- exactly the Services-session qmd.exe this fix
# exists to catch (CR [codex-1]). A CommandLine-dependent check would let that
# process evade the sweep on a hardened/elevated receiver. bun.exe and
# node.exe carry no such guarantee (bun.exe also hosts unrelated daemons;
# node.exe is scoped to qmd.js specifically -- a bare 'qmd' substring would
# also catch dozens of unrelated node.exe processes on this box), so they
# still require the CommandLine match.
function Test-IsQmdHostProcess {
    param([string]$Name, [string]$CommandLine)
    if ($Name -eq 'qmd.exe') { return $true }
    if (-not $CommandLine) { return $false }
    if ($Name -eq 'node.exe') { return $CommandLine -match 'qmd\.js' }
    return $CommandLine -match 'qmd'
}

# Decides whether a STOPPED process was the HIMMEL-592 HTTP-singleton MCP
# daemon (round-2 CR [codex-adv-2], verified against the qmd fork source):
# ensure-qmd-daemon.ps1 always launches it as exactly `qmd mcp --http
# --daemon`. Matched on CommandLine alone, not process name -- that daemon can
# be bun-hosted (bun + the global qmd.js) or node-hosted (a PATH shim), and
# `--http` is the one substring both forms share that the plain `mcp
# --keep-models` daemon Start-QmdDaemon relaunches never carries.
function Test-IsHttpDaemonProcess {
    param([string]$CommandLine)
    return [bool]($CommandLine -and $CommandLine -match '--http')
}

# Re-invokes the idempotent ensure-qmd-daemon.ps1 to restore the HTTP-singleton
# MCP daemon after the stop sweep (round 3 [codex-adv-3]/[codex-adv-4],
# verified). UNCONDITIONAL on purpose: round 2 gated this on
# Test-IsHttpDaemonProcess classifying a stopped process's CommandLine, but a
# qmd.exe swept on NAME ALONE (round 1, precisely BECAUSE its CommandLine can
# be null/access-denied on an elevated/other-session process) can BE the HTTP
# daemon with no CommandLine available to classify it by -- so the
# classification-gated restore could silently skip exactly the case round 1
# exists to catch, leaving port 8181 down with rc still 0. ensure-qmd-daemon.ps1
# is idempotent (probes 8181 first, short-circuits if already alive) and
# self-resolving, so calling it whenever ANYTHING was stopped -- even just the
# plain daemon -- converges on the right state without needing to classify
# what was killed. Test-IsHttpDaemonProcess and the stopped_http_daemon /
# stopped_before_failure_http_daemon emits stay for OBSERVABILITY only; they
# no longer gate this call.
#
# MUST be called from EVERY post-sweep exit path (round 4 [codex-adv-5]) --
# success, the stop-failure catch, the swap-failure recovery, AND both
# daemon-restart-failure branches -- see Complete-PostSweepFailure below,
# which every Fail() after the sweep now routes through so this can never be
# skipped by a return path that forgot to call it.
#
# Invoked as a genuinely SEPARATE `powershell` process (not `&`-sourced
# in-process): ensure-qmd-daemon.ps1 calls `exit` on both its success and
# failure paths, which would tear down THIS script's own process if run in
# the same session.
#
# Always Emits 'http_daemon_restored' (yes / FAILED / skipped-no-ensure-script
# / not-needed) so the caller's log states plainly what happened, and sets
# $script:EnsureRestoreFailed (round 4 [codex-adv-6]) so the SUCCESS path can
# turn an actual FAILED restore into exit code 6 instead of silently reporting
# 0 -- unattended automation otherwise gets no signal that port 8181 is down.
# A plain script-scoped variable, not a function return value: Emit itself
# calls Write-Output, so a caller capturing this function's own return stream
# (`$x = Invoke-EnsureRestore ...`) would get an ARRAY mixing the emitted
# strings with any explicit return value, not a clean boolean -- the
# script-scoped flag sidesteps that entirely.
#
# 'not-needed' (StoppedCount <= 0) does NOT set the flag: nothing was stopped,
# so there is nothing to have failed to restore. 'skipped-no-ensure-script'
# NOW DOES set the flag (round 5 [codex-adv-9], verified): something WAS
# stopped, and with no ensure script to run, a null-CommandLine qmd.exe (round
# 1 -- exactly the shape that cannot be classified as HTTP-shaped or not) can
# leave port 8181 down while this used to read as a clean, unremarkable
# skip -- a ship that swapped, restarted the plain daemon, and verified would
# still exit 0 with the HTTP surface silently unconfirmed. A non-empty
# -EnsureScript that resolves to nothing is now caught earlier and fails fast
# pre-sweep (see the pre-sweep validation block); this branch is what is left
# for a genuinely EMPTY -EnsureScript (the standalone/debug invocation) --
# absence with zero stops still reads as fine ('not-needed' above), it is only
# absence WITH something stopped that now escalates.
function Invoke-EnsureRestore {
    param([string]$EnsureScript, [int]$StoppedCount)
    $script:EnsureRestoreFailed = $false
    if ($StoppedCount -le 0) {
        Emit 'http_daemon_restored' 'not-needed'
        return
    }
    if (-not ($EnsureScript -and (Test-Path -LiteralPath $EnsureScript))) {
        Emit 'http_daemon_restored' 'skipped-no-ensure-script'
        $script:EnsureRestoreFailed = $true
        return
    }
    $ensureRc = 1
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $EnsureScript
        $ensureRc = $LASTEXITCODE
    } catch {
        $ensureRc = 1
    }
    if ($ensureRc -eq 0) {
        Emit 'http_daemon_restored' 'yes'
    } else {
        Emit 'http_daemon_restored' 'FAILED'
        $script:EnsureRestoreFailed = $true
    }
}

# Centralizes recovery-before-exit so it can never be skipped (round 4
# [codex-adv-5]/[codex-adv-7]): EVERY Fail() called after the stop sweep has
# started routes through here first. Restores the PLAIN daemon (best-effort,
# via Start-QmdDaemon) when -AlsoRestartPlainDaemon is passed -- the
# stop-failure catch never attempted this before (a stopped plain daemon was
# left down on a failed deploy, [codex-adv-7]) -- then ALWAYS restores the
# HTTP daemon (via Invoke-EnsureRestore, unconditional per its own comment),
# then calls Fail with the ORIGINAL code and message. The pre-determined
# $Code always wins regardless of what recovery does or does not manage to
# fix here -- a restore failure never masks or changes an already-decided
# primary-stage failure (2/3/4); it only ever escalates a SUCCESS (handled
# separately, at the bottom of the script, via $script:EnsureRestoreFailed).
#
# -AlsoRestartPlainDaemon is omitted at the daemon-restart-failure call sites
# (rc 4): the plain form just failed there, moments ago, in the same code --
# retrying it again immediately is not what round 4 asked for and adds no
# value without backoff logic that would be scope creep here.
function Complete-PostSweepFailure {
    param(
        [int]$Code,
        [string]$Msg,
        [string]$EnsureScript,
        [int]$StoppedCount,
        [switch]$NoRestart,
        [switch]$AlsoRestartPlainDaemon
    )
    if (-not $NoRestart) {
        if ($AlsoRestartPlainDaemon -and $StoppedCount -gt 0) {
            $backPid = $null
            try { $backPid = Start-QmdDaemon } catch { }
            Emit 'restarted_after_failure' $(if ($backPid) { $backPid } else { 'FAILED' })
        }
        Invoke-EnsureRestore -EnsureScript $EnsureScript -StoppedCount $StoppedCount
    }
    Fail $Code $Msg
}

# Decides the post-swap verify outcome from already-parsed counts (HIMMEL-1416).
# Pulled out as its own function so the pass/fail boundary is unit-testable
# without a live qmd process. Returns @{ FailCode; FailMsg }: FailCode 0 means
# the ship is verified; a non-zero FailCode is handed straight to Fail().
#
# Doc count is a HARD failure again, same as vectors/pending (round-2 CR
# [codex-adv-1], verified against the qmd fork source): the live 14844-vs-15189
# anomaly was a PREDICATE mismatch, not a genuine method/scope difference --
# `qmd status`'s "Total: N files indexed" is `SELECT COUNT(*) FROM documents
# WHERE active = 1` (src/cli/qmd.ts), while prepare-ship-index.mjs staged its
# count with a bare COUNT(*) that also counted soft-deleted rows. Now that the
# sender counts with the SAME active=1 predicate (prepare-ship-index.mjs), a
# swapped-in index and the receiver's own status read of it MUST agree exactly
# -- no legitimate mismatch source remains, so tolerating one here would just
# be hiding a real transport bug.
function Get-ShipVerdict {
    param($Docs, $Vecs, $Pending, $ExpectDocs, $ExpectVectors)
    if ($null -eq $Docs -or $null -eq $Vecs) {
        return @{ FailCode = 5; FailMsg = 'could not parse doc/vector counts from qmd status -- refusing to call the ship verified.' }
    }
    if ($Pending -gt 0) {
        return @{ FailCode = 5; FailMsg = "$Pending content hash(es) still need embedding after the swap -- vectors LAG lex. This is the silent-wrong state the ship exists to eliminate; the shipped artifact was not fully embedded at the source." }
    }
    if ($ExpectVectors -ge 0 -and $Vecs -ne $ExpectVectors) {
        return @{ FailCode = 5; FailMsg = "vector count mismatch: receiver reports $Vecs, sender shipped $ExpectVectors" }
    }
    if ($ExpectDocs -ge 0 -and $Docs -ne $ExpectDocs) {
        return @{ FailCode = 5; FailMsg = "document count mismatch: receiver reports $Docs, sender shipped $ExpectDocs" }
    }
    return @{ FailCode = 0; FailMsg = '' }
}

if (-not (Test-Path -LiteralPath $Staged)) { Fail 1 "staged index not found: $Staged" }
$stagedSize = (Get-Item -LiteralPath $Staged).Length
# A truncated/partial upload is the failure mode that would otherwise be
# discovered only by a broken search days later. 50MB is far below any real
# index and far above any plausible stub.
if ($stagedSize -lt 50MB) { Fail 1 "staged index is implausibly small ($stagedSize bytes) -- refusing to swap in a likely-truncated upload" }
Emit 'staged_bytes' $stagedSize

# --- 0. Pre-sweep validation --------------------------------------------------
# Moved here from just before the swap (round 5 [codex-adv-8], verified): these
# used to sit BETWEEN the stop sweep and the swap and call Fail directly. A
# failure there exits after daemons were already stopped, with no recovery
# attempted at all -- the exact gap Complete-PostSweepFailure exists to close.
# Nothing here depends on anything the sweep produces (only $Staged/$Target,
# both already known from the parameters), so moving it BEFORE the sweep is
# strictly better: nothing has been stopped yet, so a plain Fail is correct
# and the "should this restore first" question does not even arise.
$preship = "$Target.preship"
# Refuse a self-swap BEFORE anything moves (and before anything is stopped).
# If -Staged resolves to the live index (or to the recovery copy), the move
# sequence would shuffle a file onto itself and could destroy the only copy.
# Compare normalized full paths, since the two can be spelled differently and
# still be the same file.
$normStaged = [System.IO.Path]::GetFullPath($Staged)
$normTarget = [System.IO.Path]::GetFullPath($Target)
$normPreship = [System.IO.Path]::GetFullPath($preship)
if ($normStaged -ieq $normTarget) {
    Fail 1 "staged index and target are the same file ($normTarget) -- refusing to swap a file onto itself"
}
if ($normStaged -ieq $normPreship) {
    Fail 1 "staged index is the recovery copy ($normPreship) -- refusing to swap, this would destroy the rollback"
}
# Round 5 [codex-adv-9], optional per the coordinator: fail FAST, pre-sweep,
# when the sender says it uploaded an ensure script (-EnsureScript non-empty)
# but the path does not actually resolve -- a config mistake caught before any
# daemon is touched, rather than discovered only via a degraded rc 6 after a
# full swap. An EMPTY -EnsureScript (the standalone/debug invocation with none
# uploaded) is legitimate and deliberately NOT validated here -- only a
# NON-EMPTY one that resolves to nothing.
if ($EnsureScript -and -not (Test-Path -LiteralPath $EnsureScript)) {
    Fail 1 "ensure script not found at $EnsureScript (the sender said it uploaded one) -- refusing to proceed with a restore path that cannot work"
}

# --- 1. Stop the qmd daemon --------------------------------------------------
# THREE distinct process shapes can independently hold the index file open
# (HIMMEL-1416, live on win2: a bun.exe-only filter left two of these running
# through four straight ship failures -- each rc=6 "file being used by another
# process", stopped_pids=none every time -- until both were killed by hand
# over ssh):
#   - bun.exe running the plain daemon Start-QmdDaemon (below) launches.
#   - qmd.exe -- a compiled/shimmed qmd binary. A Name='bun.exe' filter never
#     matches this by name, in ANY Windows session (one holder was found
#     running in the Services session).
#   - node.exe running .../qmd.js mcp|--daemon -- the HIMMEL-592
#     HTTP-singleton MCP daemon (port 8181), resident by design and started
#     independently of this script (ensure-qmd-daemon.ps1/.sh). It is
#     NODE-hosted, not bun, so the bun-only filter misses it too.
# The node.exe match is scoped to command lines mentioning qmd.js specifically,
# not a bare 'qmd' substring -- an unscoped node filter would also catch
# dozens of unrelated node.exe processes (this box runs ~40).
#
# The HTTP-singleton daemon can be among these, and Start-QmdDaemon's own
# restart below only relaunches the plain `mcp --keep-models` form (a
# DIFFERENT, non-HTTP invocation), so stopping it here without restoring it
# would leave the receiver's HTTP MCP surface down until the next
# SessionStart-hook/logon fires -- not prompt on an unattended receiver.
# $stoppedHttpDaemon is tracked below for OBSERVABILITY (round 2 [codex-adv-2])
# but no longer GATES the restore (round 3 [codex-adv-3]/[codex-adv-4]):
# Invoke-EnsureRestore below runs unconditionally whenever anything was
# stopped, because a qmd.exe swept on name alone can have a null CommandLine
# (round 1) with nothing left to classify it by -- a classification-gated
# restore could silently miss exactly that case.
$stopped = @()
$stoppedHttpDaemon = $false
$script:EnsureRestoreFailed = $false   # set by Invoke-EnsureRestore; consulted at the success-path exit (round 4 [codex-adv-6])
try {
    # -ErrorAction Stop, NOT SilentlyContinue: a FAILED enumeration would
    # otherwise be indistinguishable from "no daemon is running", and we would
    # go on to swap a file the daemon still holds open.
    $procs = Get-CimInstance Win32_Process `
        -Filter "Name = 'bun.exe' OR Name = 'qmd.exe' OR Name = 'node.exe'" -ErrorAction Stop
    foreach ($p in $procs) {
        if (Test-IsQmdHostProcess -Name $p.Name -CommandLine $p.CommandLine) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $stopped += $p.ProcessId
            if (Test-IsHttpDaemonProcess -CommandLine $p.CommandLine) { $stoppedHttpDaemon = $true }
        }
    }
} catch {
    # Report what we DID stop before failing. A partial stop otherwise leaves the
    # operator unable to tell whether a daemon needs restarting by hand -- and,
    # honestly, whether that includes the HTTP daemon specifically (round 2
    # [codex-adv-2], observability only). A stop failure here means the swap
    # never happens and this script exits before reaching the success path's
    # restore, so Complete-PostSweepFailure recovers BOTH daemon forms here too
    # (round 4 [codex-adv-7]: the plain form was never restarted on this path
    # before, taking search offline on a failed deploy) -- whatever WAS stopped
    # before the enumeration failed still needs both, or it is left down with
    # no restore attempted at all.
    Emit 'stopped_before_failure' ($(if ($stopped.Count) { $stopped -join ',' } else { 'none' }))
    Emit 'stopped_before_failure_http_daemon' $(if ($stoppedHttpDaemon) { 'yes' } else { 'no' })
    Complete-PostSweepFailure -Code 2 -Msg "failed to stop the qmd daemon: $($_.Exception.Message)" `
        -EnsureScript $EnsureScript -StoppedCount $stopped.Count -NoRestart:$NoRestart -AlsoRestartPlainDaemon
}
Emit 'stopped_pids' ($(if ($stopped.Count) { $stopped -join ',' } else { 'none' }))
Emit 'stopped_http_daemon' $(if ($stoppedHttpDaemon) { 'yes' } else { 'no' })

# Give the OS a moment to release the file handles before the swap; a swap
# against a still-mapped SQLite file fails with a sharing violation.
if ($stopped.Count -gt 0) { Start-Sleep -Seconds 3 }

# --- 2. Swap ------------------------------------------------------------------
# The previous index moves aside to .preship FIRST, so a failed move-in can be
# rolled back. It is REAPED below on success and on failure -- two stale copies
# (365MB + 221MB) once sat here for days. $preship + the self-swap guards moved
# BEFORE the stop sweep (round 5 [codex-adv-8]) -- see that block for why.
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
    # search, which is worse than the failed ship itself. Complete-PostSweepFailure
    # restores BOTH daemon forms before exiting (best effort, and reported
    # either way) -- a failed, rolled-back ship must not leave the receiver's
    # MCP endpoint down any more than a successful one would.
    Complete-PostSweepFailure -Code 3 -Msg "swap failed: $($_.Exception.Message)" `
        -EnsureScript $EnsureScript -StoppedCount $stopped.Count -NoRestart:$NoRestart -AlsoRestartPlainDaemon
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
        # Round 4 [codex-adv-5]: both branches below used to call Fail 4
        # directly, whose exit terminates BEFORE the HTTP-daemon restore
        # further down ever ran -- an HTTP daemon killed by the sweep stayed
        # down with no restore attempt whatsoever if the PLAIN daemon also
        # failed to come back. Complete-PostSweepFailure runs that restore
        # first. No -AlsoRestartPlainDaemon here: the plain form just failed,
        # moments ago, in this same block.
        if (-not $newPid) {
            Complete-PostSweepFailure -Code 4 -Msg 'could not restart the qmd daemon (qmd missing from PATH, or Win32_Process Create failed) -- index WAS swapped' `
                -EnsureScript $EnsureScript -StoppedCount $stopped.Count
        }
        Emit 'restarted_pid' $newPid
    } catch {
        Complete-PostSweepFailure -Code 4 -Msg "daemon restart failed (index WAS swapped): $($_.Exception.Message)" `
            -EnsureScript $EnsureScript -StoppedCount $stopped.Count
    }
    Start-Sleep -Seconds 3

    # Restore the HTTP-singleton MCP daemon (round 2 [codex-adv-2] /
    # round 3 [codex-adv-3]/[codex-adv-4]): Start-QmdDaemon above only
    # relaunches the plain `mcp --keep-models` form, which never listens on
    # HTTP. See Invoke-EnsureRestore's own comment for why this call is
    # UNCONDITIONAL on $stopped.Count rather than gated on classifying which
    # stopped process was the HTTP daemon.
    Invoke-EnsureRestore -EnsureScript $EnsureScript -StoppedCount $stopped.Count
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

$verdict = Get-ShipVerdict -Docs $docs -Vecs $vecs -Pending $pending -ExpectDocs $ExpectDocs -ExpectVectors $ExpectVectors
if ($verdict.FailCode -ne 0) {
    Fail $verdict.FailCode "$($verdict.FailMsg)`n$statusText"
}

Emit 'verified' 'ok'
# Round 4 [codex-adv-6], coordinator-overridden: the index shipped and
# verified cleanly (rc 0 was always correct for THAT), but if the HTTP-daemon
# restore actually failed, exit 6 instead of silently reporting a clean 0 --
# unattended automation gets no other signal that port 8181 may be down.
# $script:EnsureRestoreFailed stays $false (its initial value) when
# -NoRestart skipped the restore entirely, so that mode is unaffected.
if ($script:EnsureRestoreFailed) {
    Fail 6 'index shipped and verified OK, but the HTTP-singleton MCP daemon restore FAILED after the stop sweep -- port 8181 may still be down. See the http_daemon_restored line above.'
}
exit 0
