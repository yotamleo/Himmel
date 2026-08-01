# reap-superseded-fleets.ps1 (HIMMEL-1309) - report/reap SUPERSEDED Codex MCP
# fleets that accumulate UNDER A STILL-LIVE app-server.
#
# WHY (the gap the two existing tools structurally cannot cover):
#   scripts/cleanup/sweep-codex-orphans.ps1 reaps orphaned BROKER TREES - a tree
#   is LIVE iff some claude.exe/ChatGPT.exe still references its
#   `cxc-<token>-codex-app-server` pipe. scripts/codex/reap-mcp-fleet.ps1 reaps
#   MCP fleets whose app-server ancestor is GONE. BOTH deliberately skip anything
#   under a LIVE app-server, because that fleet is "legitimately in use".
#
#   That is correct for ONE fleet and wrong for N duplicates. A long-lived
#   app-server spawns a FRESH MCP fleet per client connection and never reaps the
#   previous one, so every duplicate looks legitimately-in-use individually while
#   collectively being a leak. Observed 2026-07-27: ONE app-server (pid 51100, up
#   13:39->21:12) had accumulated 45 `luna-correlate` launcher+server pairs; the
#   armed daily sweep correctly judged its tree LIVE and skipped it. The leak is
#   INSIDE a live tree. This is that third check.
#
# THE TEST (per-key supersession, NOT bare cardinality):
#   A FLEET ROOT is a direct child of a live `codex.exe app-server`. Its FLEET KEY
#   is the MCP server it actually is - the launcher's `--cwd <plugin>` path when
#   present (that is the plugin identity), else its command line minus the leading
#   executable token. Within one (AppServerPid, FleetKey) group the NEWEST roots
#   are the current ones; strictly older roots are SUPERSEDED.
#
#   Supersession alone is NOT sufficient to kill - a second concurrent
#   `luna-correlate` can be a legitimate parallel tool call. Three gates narrow it,
#   and every one of them can only ever REMOVE targets:
#     1. -KeepNewest <n>   (default 1) newest roots per group are never candidates.
#     2. -MinAgeMinutes <n> (default 30) a superseded root younger than this is
#        KEPT. Genuinely-concurrent parallel calls are seconds-to-minutes apart
#        (the live reproduction spawned three fleets 10-23s apart), so this gate
#        is what separates "duplicate generation" from "parallel tool call". It is
#        the PRIMARY protection - the CPU gate below is a net, not a guarantee.
#     3. CPU-idle veto: the candidate's whole subtree is sampled twice
#        -SampleSeconds apart; if its total processor time advanced by more than
#        CPU_IDLE_THRESHOLD_MS the root is KEPT (it is doing work right now).
#        Honest limitation: a superseded-but-in-use server that happens to be idle
#        during the sample window is NOT protected by this gate - gate 2 is.
#
#   Deliberately NOT used: dead-parent and "has a codex.exe descendant" (both
#   documented false signals, HIMMEL-718), and bare per-plugin cardinality
#   (kills live tooling - it is exactly why the two existing scripts are
#   conservative).
#
# WHAT KEEPS THE OPERATOR'S OWN PROCESSES SAFE is LINEAGE, not shape: a target
#   must be a descendant of a live codex app-server, and the v2 telegram bridge,
#   the operator's qmd MCP server and the live claude session never are. That is
#   the 2026-07-27 manual pre-flight assertion ("bridge, qmd MCP and the live
#   claude session were confirmed ABSENT from the target list BEFORE -Kill"),
#   made structural. Test-IsProtectedProcess below is a narrow tripwire on top of
#   it for the case where that topology assumption breaks - see its comment for
#   why it deliberately does NOT list qmd.
#
# CPU THRESHOLD CALIBRATION (2026-07-27 live run, 30 candidates): abandoned fleet
#   roots measured 0.0 ms over the 3 s window, with two outliers at 15.6 ms and
#   31.2 ms (runtime GC/timer noise on the bun launchers). 50 ms sits above that
#   noise floor while staying far below anything doing real work.
#
# SCOPE NOTES - what this tool deliberately does NOT do:
#   * App-server accumulation is REPORTED, never reaped. Nothing caps how many
#     app-servers exist, but a live app-server whose pipe a client still holds is
#     in use by definition; killing one is the wrong-kill this tool exists to
#     avoid. The per-app-server census makes the accumulation visible instead.
#   * A fleet root whose CommandLine WMI will not show us cannot be keyed, so it
#     is counted as blind and never reaped (mirrors sweep-codex-orphans.ps1's
#     pid-reuse refusal). The long-lived unreadable `bun.exe` from HIMMEL-1296 is
#     not under an app-server at all, so it is out of this tool's scope entirely
#     and stays documented rather than killed - there is no signal that would
#     identify it without guessing.
#
# Kill safety is DELEGATED, not reimplemented: this script dot-sources
# sweep-codex-orphans.ps1 -AsLibrary and reuses its Get-DescendantPids (creation-
# time-ordered PPID-reuse filter), Test-ProcessNameAllowed and
# Test-ProcessStartMatches verbatim, so the pid-reuse guards cannot drift apart.
#
# USAGE:
#   pwsh -NoProfile -File scripts/codex/reap-superseded-fleets.ps1            # dry run (default)
#   pwsh -NoProfile -File scripts/codex/reap-superseded-fleets.ps1 -Kill      # name+identity-verified stop
#   pwsh -NoProfile -File scripts/codex/reap-superseded-fleets.ps1 -MinAgeMinutes 60 -KeepNewest 2
# Exit codes: 0 = nothing to reap OR run complete; 1 = usage / enumeration error.
# Non-Windows: exits 0 with a message (the leak is a Windows-observed pattern;
# the pure functions still dot-source-load for cross-platform tests).

[CmdletBinding()]
param(
  [switch]$Kill,
  # Newest N roots per (app-server, fleet key) are never candidates.
  [ValidateRange(1, 1000)][int]$KeepNewest = 1,
  # A superseded root younger than this is KEPT (parallel-tool-call protection).
  [ValidateRange(0, 10080)][int]$MinAgeMinutes = 30,
  # CPU-idle sample window. 0 disables the veto (gate 2 still applies).
  [ValidateRange(0, 60)][int]$SampleSeconds = 3,
  # Dot-source seam for the hermetic test: define the pure functions, then
  # return WITHOUT scanning the live process table or touching the OS.
  [switch]$AsLibrary
)

# Subtree CPU advance (ms) above which a candidate is vetoed as "working right
# now". Not a parameter on purpose (simplicity-first): the dry-run report prints
# every candidate's measured delta, which is what calibration actually needs.
$CPU_IDLE_THRESHOLD_MS = 50

# Shared kill-safety primitives. Dot-sourcing (not copying) keeps the pid-reuse
# guards single-sourced - a fix there must never have to be mirrored here.
$SweepLib = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'cleanup') 'sweep-codex-orphans.ps1'
if (-not (Test-Path -LiteralPath $SweepLib)) {
  Write-Error "[reap-superseded-fleets] required library not found: $SweepLib"
  exit 1
}
# Dot-sourcing runs the LIBRARY'S OWN param() block in THIS scope, which
# silently overwrites every same-named variable of ours - sweep-codex-orphans.ps1
# declares -Kill and -AsLibrary, so an un-restored dot-source sets $AsLibrary
# to $true here and the script `return`s before doing anything (exit 0, no
# output) while -Kill is quietly discarded. Snapshot our own bindings first and
# restore them verbatim; doing it for ALL our params (not just the two that
# collide today) keeps a future param added over there from re-breaking this.
$MyParams = @{
  Kill          = $Kill
  KeepNewest    = $KeepNewest
  MinAgeMinutes = $MinAgeMinutes
  SampleSeconds = $SampleSeconds
  AsLibrary     = $AsLibrary
}
. $SweepLib -AsLibrary
foreach ($paramName in $MyParams.Keys) { Set-Variable -Name $paramName -Value $MyParams[$paramName] }

# --- pure helpers (fed records / strings; unit-tested directly) ---------------

# The app-server is the fleet parent: `codex.exe app-server`. Name alone is not
# enough - `codex.exe` also fronts the CLI lane, which owns no MCP fleet here.
function Test-IsCodexAppServer {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name) { return $false }
  if ($Proc.Name -ine 'codex.exe') { return $false }
  return ([string]$Proc.CommandLine -match '(?:^|\s)app-server(?:\s|$)')
}

# Strip the leading executable token from a command line, quoted or bare, and
# return the normalized remainder (whitespace-collapsed, lowercased). This is
# what makes `uvx mcp-obsidian` and `node_repl.exe` (no args at all) keyable
# alongside the bun launchers - the fix must not be bun-only (HIMMEL-1309 gap 3:
# 146 codex-lineage procs / 2.6 GB survived a bun-keyed sweep).
function Get-CommandTail {
  param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$CommandLine)
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
  $tail = $CommandLine
  if ($CommandLine -match '^\s*(?:"[^"]*"|\S+)\s*(.*)$') { $tail = $Matches[1] }
  return (($tail -replace '\s+', ' ').Trim().ToLowerInvariant())
}

# Fleet key = which MCP server this root IS, independent of when it was spawned.
# Prefers the launcher's `--cwd <plugin path>` (the plugin identity: every
# generation of `luna-correlate/0.2.0` shares it while `telegram-himmel/0.0.6`
# stays a separate key), else the normalized command tail. Prefixed with the
# image base name so two different images can never collide on an empty tail.
# Returns $null for a root whose CommandLine is unreadable - unkeyable, so the
# caller counts it blind and never reaps it.
function Get-FleetKey {
  param([Parameter(Mandatory)]$Proc)
  $cl = [string]$Proc.CommandLine
  if ([string]::IsNullOrWhiteSpace($cl)) { return $null }
  $base = ([string]$Proc.Name) -replace '\.exe$', ''
  $identity = $null
  if ($cl -match '(?:^|\s)--cwd[ =](?:"([^"]+)"|(\S+))') {
    $identity = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
    # Normalize separators + trailing slash so the same plugin dir spelled
    # either way is ONE key (the live table mixes / and \ inside one cmdline).
    $identity = ($identity -replace '\\', '/').TrimEnd('/')
  } else {
    $identity = Get-CommandTail -CommandLine $cl
  }
  return ("{0}|{1}" -f $base.ToLowerInvariant(), $identity.ToLowerInvariant())
}

# Topology tripwire, NOT a general deny-list. Candidates are already scoped to
# descendants of a live codex app-server, which is what structurally keeps the
# operator's own long-lived processes out of every target set. This guard exists
# for the case where that scoping assumption turns out to be WRONG: it names the
# shapes that must never be codex fleet members, so a hit means the topology
# changed and the candidate is dropped loudly rather than killed quietly.
#
# It lists ONLY the v2 telegram bridge and the claude CLI. It deliberately does
# NOT list the qmd MCP server, even though the operator runs one: codex spawns
# its OWN qmd MCP server as a plugin fleet member, so a shape-based qmd entry
# protected exactly the duplicates this ticket exists to reap (six of them on
# the 2026-07-27 live run). The operator's qmd is not a descendant of any
# app-server, so lineage already excludes it - shape matching would only ever
# re-introduce the restart-bridge.ps1 misattribution bug in a new place.
function Test-IsProtectedProcess {
  param([Parameter(Mandatory)]$Proc)
  $cl = [string]$Proc.CommandLine
  if (-not $cl) { return $false }
  if ($cl -match '(?:^|[\\/\s])(supervisor|poller)\.ts(?:\s|$)') { return $true }   # v2 telegram bridge
  # Path-separator-anchored `cli.js` on purpose: a bare \bcli\.js\b also matches
  # npx-cli.js, which is a perfectly reapable fleet shape.
  if ($cl -match '[\\/]\.claude[\\/]' -and $cl -match '[\\/]cli\.js\b') { return $true }         # claude CLI
  return $false
}

function Get-ProtectedPids {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $out = New-Object System.Collections.Generic.HashSet[int]
  foreach ($p in $Procs) {
    if (Test-IsProtectedProcess -Proc $p) { [void]$out.Add([int]$p.ProcessId) }
  }
  # Unary comma: return the HashSet AS ONE object. A bare `return $out` lets the
  # pipeline enumerate it, so an EMPTY set arrives at the caller as $null and
  # every .Count/.Contains on it throws (same trap as Get-CxcTokens' comma in
  # sweep-codex-orphans.ps1).
  return , $out
}

# Headline pure classifier. Returns one record per SUPERSEDED fleet root:
# { AppServerPid, RootPid, Name, Key, CreationDate, AgeMinutes, Rank } where Rank
# is 0-based newest-first position within its (app-server, key) group (so Rank
# always >= KeepNewest for a returned record). $Now is injected so the age gate
# is deterministic under test.
#
# A root with no CreationDate is SKIPPED entirely: it can be neither ranked by
# recency nor age-gated, and guessing would risk reaping the current fleet.
function Get-SupersededFleetRoots {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][datetime]$Now,
    [int]$KeepNewest = 1,
    [int]$MinAgeMinutes = 30
  )
  $appServers = New-Object System.Collections.Generic.HashSet[int]
  foreach ($p in $Procs) {
    if (Test-IsCodexAppServer -Proc $p) { [void]$appServers.Add([int]$p.ProcessId) }
  }
  if ($appServers.Count -eq 0) { return @() }

  # Group direct children of a LIVE app-server by (app-server, fleet key).
  $groups = @{}
  foreach ($p in $Procs) {
    if ($null -eq $p.ParentProcessId) { continue }
    if (-not $appServers.Contains([int]$p.ParentProcessId)) { continue }
    if (Test-IsCodexAppServer -Proc $p) { continue }        # never a nested app-server
    $key = Get-FleetKey -Proc $p
    if ($null -eq $key) { continue }                        # unreadable cmdline -> blind, never reaped
    if (-not ($p.PSObject.Properties['CreationDate']) -or $null -eq $p.CreationDate) { continue }
    $gk = "{0}#{1}" -f $p.ParentProcessId, $key
    if (-not $groups.ContainsKey($gk)) { $groups[$gk] = New-Object System.Collections.ArrayList }
    [void]$groups[$gk].Add($p)
  }

  $out = New-Object System.Collections.ArrayList
  foreach ($gk in $groups.Keys) {
    # Newest first. Ties (same CreationDate to the second - the live table
    # routinely spawns a whole generation inside one second) are broken by pid
    # only to make the order deterministic; KeepNewest >= 1 plus the age gate
    # mean a tie can never decide a kill on its own.
    $ordered = @($groups[$gk] | Sort-Object -Property @{Expression = { [datetime]$_.CreationDate }; Descending = $true }, @{Expression = { [int]$_.ProcessId }; Descending = $true })
    for ($i = $KeepNewest; $i -lt $ordered.Count; $i++) {
      $p = $ordered[$i]
      $ageMin = ($Now - [datetime]$p.CreationDate).TotalMinutes
      if ($ageMin -lt $MinAgeMinutes) { continue }          # too young -> parallel-call protection
      [void]$out.Add([pscustomobject]@{
        AppServerPid = [int]$p.ParentProcessId
        RootPid      = [int]$p.ProcessId
        Name         = [string]$p.Name
        Key          = (Get-FleetKey -Proc $p)
        CreationDate = [datetime]$p.CreationDate
        AgeMinutes   = [int][math]::Round($ageMin)
        Rank         = $i
      })
    }
  }
  return @($out.ToArray() | Sort-Object -Property AppServerPid, Key, CreationDate)
}

# Fleet roots under a live app-server whose CommandLine WMI will not show us -
# unkeyable, so structurally excluded from every verdict above. Reported so the
# blind spot is visible instead of silently shrinking the candidate set.
function Get-BlindFleetRootPids {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $appServers = New-Object System.Collections.Generic.HashSet[int]
  foreach ($p in $Procs) {
    if (Test-IsCodexAppServer -Proc $p) { [void]$appServers.Add([int]$p.ProcessId) }
  }
  $out = New-Object System.Collections.ArrayList
  foreach ($p in $Procs) {
    if ($null -eq $p.ParentProcessId) { continue }
    if (-not $appServers.Contains([int]$p.ParentProcessId)) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$p.CommandLine)) { [void]$out.Add([int]$p.ProcessId) }
  }
  return , ($out.ToArray())
}

# Re-gate the descendant walk's output against the ROOT's creation time
# (HIMMEL-1309, codex adversarial pass — "the main kill path has a concrete
# safety gap").
#
# Get-DescendantPids' own stale-PPID filter is deliberately fail-OPEN: it keeps
# a parent->child link whenever EITHER creation date is unknown. That is correct
# in sweep-codex-orphans.ps1, whose comment says why — "the orphan CLASSIFICATION
# is still gated by the client-pipe test". THIS tool has no such second gate.
# Only the ROOT is classified (a direct child of a live app-server); every
# descendant inherits membership from the PPID walk alone. Windows never updates
# a process's recorded PPID when its real parent dies, so an unrelated process
# whose dead parent's pid was later RECYCLED into one of our fleet pids joins the
# tree — and the only thing left between it and Stop-Process is a name allow-list
# holding node/python/cmd/bash/pwsh, which such a process trivially satisfies.
# (The kill loop's creation-time identity check does NOT catch it: that compares
# the impostor against ITS OWN snapshot, which matches — it is the same process,
# just not ours.)
#
# The invariant that closes it: a process spawned BY this subtree cannot predate
# its root. Drop anything older than the root, and fail CLOSED on an unreadable
# creation time — an unverifiable pid is exactly what must not be killed here.
function Select-VerifiedDescendants {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$Pids,
    [Parameter(Mandatory)][datetime]$RootCreated
  )
  $byPid = @{}
  foreach ($p in $Procs) { $byPid[[string]$p.ProcessId] = $p }
  $out = New-Object System.Collections.ArrayList
  foreach ($procId in $Pids) {
    $rec = $byPid[[string]$procId]
    if ($null -eq $rec) { continue }                                                   # vanished mid-walk
    if (-not ($rec.PSObject.Properties['CreationDate']) -or $null -eq $rec.CreationDate) { continue }  # unverifiable -> fail closed
    # 2s tolerance mirrors Test-ProcessStartMatches (kernel creation time
    # arrives via different conversions/rounding on the two paths).
    if (([datetime]$rec.CreationDate - $RootCreated).TotalSeconds -lt -2) { continue }  # predates the root -> not kin
    [void]$out.Add([int]$procId)
  }
  return , ($out.ToArray())
}

# CPU-idle veto decision. $DeltaMs is the subtree's total-processor-time advance
# across the sample window; $null means the sample could not be taken (access
# denied / process gone mid-sample) - fail SAFE by vetoing, because an
# unmeasurable candidate has no evidence of being idle.
# Platform guard ([codex-1]/[glm-3], HIMMEL-1309). `$IsWindows` is a PowerShell
# 6+ AUTOMATIC VARIABLE — under Windows PowerShell 5.1 it is simply UNDEFINED
# ($null), so the obvious `if (-not $IsWindows)` evaluates TRUE and the script
# exits 0 announcing "non-Windows" on the exact platform it exists for.
#
# That path is reachable in production, not theoretical: codex-sweep-cadence.sh's
# resolve_pwsh falls back to `powershell` when `pwsh` is not on PATH, so an
# adopter without PowerShell 7 gets an armed daily cadence whose legs no-op on
# every fire while the runner log records a clean rc=0 — a silent, self-reporting
# success that never sweeps anything.
#
# 5.1 ships only on Windows, so an undefined $IsWindows means Windows; $env:OS is
# the explicit corroborating signal rather than an assumption.
function Test-OnWindows {
  param([AllowNull()]$IsWindowsValue, [AllowNull()][AllowEmptyString()][string]$OsEnv)
  if ($null -eq $IsWindowsValue) { return ($OsEnv -eq 'Windows_NT') }
  return [bool]$IsWindowsValue
}

function Test-CpuIdle {
  param([Nullable[double]]$DeltaMs, [double]$ThresholdMs)
  if ($null -eq $DeltaMs) { return $false }
  return ($DeltaMs -le $ThresholdMs)
}

if ($AsLibrary) { return }

# --- production path ---------------------------------------------------------

if (-not (Test-OnWindows -IsWindowsValue $IsWindows -OsEnv $env:OS)) {
  Write-Host "[reap-superseded-fleets] non-Windows host (the codex fleet leak is a Windows pattern) - nothing to reap."
  exit 0
}

$ErrorActionPreference = 'Stop'

try {
  $records = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    ForEach-Object {
      [pscustomobject]@{
        ProcessId       = [int]$_.ProcessId
        ParentProcessId = [int]$_.ParentProcessId
        Name            = [string]$_.Name
        CommandLine     = [string]$_.CommandLine
        WorkingSetSize  = [long]($_.WorkingSetSize)
        CreationDate    = $_.CreationDate
      }
    })
} catch {
  Write-Error "[reap-superseded-fleets] could not enumerate processes: $_"
  exit 1
}

$byPid = @{}
foreach ($p in $records) { $byPid[[string]$p.ProcessId] = $p }

function Get-TreeWSMB {
  param([Parameter(Mandatory)][AllowEmptyCollection()][int[]]$Pids)
  $bytes = 0L
  foreach ($procId in $Pids) {
    $rec = $byPid[[string]$procId]
    if ($rec -and $rec.WorkingSetSize) { $bytes += [long]$rec.WorkingSetSize }
  }
  return [math]::Round($bytes / 1MB, 1)
}

# Sum TotalProcessorTime over a pid set. Returns $null if ANY pid could not be
# read (gone / access denied) - a partial sum would silently look like "idle".
function Get-SubtreeCpuMs {
  param([Parameter(Mandatory)][AllowEmptyCollection()][int[]]$Pids)
  $sum = 0.0
  foreach ($procId in $Pids) {
    try {
      $proc = Get-Process -Id $procId -ErrorAction Stop
      $sum += $proc.TotalProcessorTime.TotalMilliseconds
    } catch { return $null }
  }
  return $sum
}

# --- app-server census (gap 2: accumulation is REPORTED, never reaped) -------

$appServerRecs = @($records | Where-Object { Test-IsCodexAppServer -Proc $_ })
$now = Get-Date

if ($appServerRecs.Count -eq 0) {
  Write-Host "[reap-superseded-fleets] no live codex app-server found - nothing to inspect."
  exit 0
}

$censusRows = $appServerRecs | ForEach-Object {
  $asPid = [int]$_.ProcessId
  $roots = @($records | Where-Object { [int]$_.ParentProcessId -eq $asPid })
  $treePids = @($asPid) + @(Get-DescendantPids -Procs $records -RootPid $asPid)
  $ageStr = '?'
  if ($_.CreationDate -is [datetime]) { $ageStr = "{0}m" -f [int][math]::Round(($now - $_.CreationDate).TotalMinutes) }
  [pscustomobject]@{
    AppServerPID = $asPid
    Age          = $ageStr
    FleetRoots   = $roots.Count
    TreeProcs    = $treePids.Count
    TreeWSMB     = (Get-TreeWSMB -Pids ([int[]]$treePids))
  }
}
Write-Host ("[reap-superseded-fleets] {0} live app-server(s) (never reaped by this tool - reported so accumulation is visible):" -f $appServerRecs.Count)
$censusRows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$blindRoots = Get-BlindFleetRootPids -Procs $records
if ($blindRoots.Count -gt 0) {
  Write-Warning ("[reap-superseded-fleets] {0} fleet root(s) under a live app-server have no readable CommandLine (pid(s): {1}) - unkeyable, so excluded from every verdict below and never reaped." -f $blindRoots.Count, ($blindRoots -join ', '))
}

# --- superseded candidates ---------------------------------------------------

$superseded = @(Get-SupersededFleetRoots -Procs $records -Now $now -KeepNewest $KeepNewest -MinAgeMinutes $MinAgeMinutes)

if ($superseded.Count -eq 0) {
  Write-Host ("[reap-superseded-fleets] no superseded fleet roots (keep-newest={0}, min-age={1}m)." -f $KeepNewest, $MinAgeMinutes)
  exit 0
}

$protectedPids = Get-ProtectedPids -Procs $records

# Build each candidate's full target set (root + descendants) and drop any whose
# subtree touches a protected process. Structurally this must never fire; if it
# does, the topology assumption is wrong and the loud skip is the right outcome.
$candidates = New-Object System.Collections.ArrayList
$unverifiedDropped = 0
foreach ($s in $superseded) {
  $walked = @(Get-DescendantPids -Procs $records -RootPid $s.RootPid)
  # Re-gate against the root's creation time before ANY of these pids can reach
  # the kill loop (see Select-VerifiedDescendants for the stale-PPID hole this
  # closes). The root itself is already classified, so it is added after.
  $verified = Select-VerifiedDescendants -Procs $records -Pids ([int[]]$walked) -RootCreated $s.CreationDate
  $unverifiedDropped += ($walked.Count - $verified.Count)
  $tree = @($s.RootPid) + @($verified)
  $hit = @($tree | Where-Object { $protectedPids.Contains([int]$_) })
  if ($hit.Count -gt 0) {
    # Message lists exactly what Test-IsProtectedProcess matches ([glm-2]) - it
    # used to say "qmd MCP" too, which is precisely what the tripwire does NOT
    # cover (codex owns its own qmd fleet members; see that function's comment).
    Write-Warning ("[reap-superseded-fleets] root pid {0} ({1}) subtree contains PROTECTED pid(s) {2} (telegram bridge / claude CLI) - dropping this candidate entirely." -f $s.RootPid, $s.Key, ($hit -join ', '))
    continue
  }
  [void]$candidates.Add([pscustomobject]@{
    AppServerPid = $s.AppServerPid
    RootPid      = $s.RootPid
    Name         = $s.Name
    Key          = $s.Key
    AgeMinutes   = $s.AgeMinutes
    Rank         = $s.Rank
    TreePids     = [int[]]$tree
    TreeProcs    = $tree.Count
    TreeWSMB     = (Get-TreeWSMB -Pids ([int[]]$tree))
    CpuDeltaMs   = $null
    Verdict      = 'REAP'
  })
}

if ($unverifiedDropped -gt 0) {
  Write-Host ("[reap-superseded-fleets] {0} walked descendant(s) dropped as unverifiable kin (older than their root, or no readable creation time) - stale-PPID safety, never reaped." -f $unverifiedDropped)
}

if ($candidates.Count -eq 0) {
  Write-Host "[reap-superseded-fleets] every superseded root was dropped by the protected-process guard - nothing to reap."
  exit 0
}

# --- CPU-idle veto (gate 3) --------------------------------------------------

if ($SampleSeconds -gt 0) {
  $before = @{}
  foreach ($c in $candidates) { $before[[string]$c.RootPid] = (Get-SubtreeCpuMs -Pids $c.TreePids) }
  Start-Sleep -Seconds $SampleSeconds
  foreach ($c in $candidates) {
    $b = $before[[string]$c.RootPid]
    $a = Get-SubtreeCpuMs -Pids $c.TreePids
    $delta = $null
    if ($null -ne $b -and $null -ne $a) { $delta = [math]::Round(($a - $b), 1) }
    $c.CpuDeltaMs = $delta
    if (-not (Test-CpuIdle -DeltaMs $delta -ThresholdMs $CPU_IDLE_THRESHOLD_MS)) {
      $c.Verdict = if ($null -eq $delta) { 'KEEP (cpu unreadable)' } else { 'KEEP (cpu active)' }
    }
  }
}

$reapList = @($candidates | Where-Object { $_.Verdict -eq 'REAP' })
$reapPids = @($reapList | ForEach-Object { $_.TreePids } | Sort-Object -Unique)

Write-Host ("[reap-superseded-fleets] {0} superseded fleet root(s) (keep-newest={1}, min-age={2}m, cpu-sample={3}s, idle-threshold={4}ms):" -f $candidates.Count, $KeepNewest, $MinAgeMinutes, $SampleSeconds, $CPU_IDLE_THRESHOLD_MS)
$candidates | Select-Object AppServerPid, RootPid, Name, Rank, @{n = 'Age'; e = { "$($_.AgeMinutes)m" } }, TreeProcs, TreeWSMB, CpuDeltaMs, Verdict, @{n = 'Key'; e = { if ($_.Key.Length -gt 60) { '...' + $_.Key.Substring($_.Key.Length - 57) } else { $_.Key } } } |
  Format-Table -AutoSize | Out-String -Width 220 | Write-Host

if ($reapList.Count -eq 0) {
  Write-Host "[reap-superseded-fleets] every candidate was vetoed by the CPU-idle gate - nothing to reap."
  exit 0
}

$reapMB = Get-TreeWSMB -Pids ([int[]]$reapPids)
Write-Host ("[reap-superseded-fleets] reap set: {0} root(s), {1} proc(s), ~{2} MB. flat PID list: {3}" -f $reapList.Count, $reapPids.Count, $reapMB, ($reapPids -join ', '))

if (-not $Kill) {
  Write-Host "[reap-superseded-fleets] dry run (default). Re-run with -Kill to name+identity-verified-stop the reap set."
  exit 0
}

# -Kill: same two pid-reuse gates as sweep-codex-orphans.ps1 (dot-sourced, not
# reimplemented) - the live ProcessName must be in the allow set AND the live
# StartTime must match the enumeration snapshot's CreationDate.
$killed = 0
$skippedName = 0
$skippedRecycled = 0
$skippedGone = 0
$killedPids = New-Object System.Collections.ArrayList
foreach ($procId in $reapPids) {
  $rec = $byPid[[string]$procId]
  $liveNow = $null
  try { $liveNow = Get-Process -Id $procId -ErrorAction Stop } catch { $liveNow = $null }
  if ($null -eq $liveNow) { $skippedGone++; continue }
  $curName = [string]$liveNow.ProcessName
  if (-not (Test-ProcessNameAllowed -Name $curName)) {
    Write-Warning "[reap-superseded-fleets] pid $procId now '$curName' (not in allow set) - SKIP (pid-reuse safety)."
    $skippedName++
    continue
  }
  $liveStart = $null
  try { $liveStart = $liveNow.StartTime } catch { $liveStart = $null }
  $snapStart = $null
  if ($rec) { $snapStart = $rec.CreationDate }
  if (-not (Test-ProcessStartMatches -SnapshotCreation $snapStart -LiveStart $liveStart)) {
    Write-Warning "[reap-superseded-fleets] pid $procId ('$curName') start time differs from the enumeration snapshot (recycled pid) - SKIP (pid-reuse safety)."
    $skippedRecycled++
    continue
  }
  try {
    Stop-Process -Id $procId -Force -ErrorAction Stop
    $killed++
    [void]$killedPids.Add([int]$procId)
  } catch {
    Write-Warning "[reap-superseded-fleets] could not stop pid $procId ('$curName'): $_"
  }
}

$reclaimedMB = 0
if ($killedPids.Count -gt 0) { $reclaimedMB = Get-TreeWSMB -Pids ([int[]]$killedPids.ToArray()) }
$stopFailed = $reapPids.Count - $killed - $skippedGone - $skippedName - $skippedRecycled
Write-Host ("[reap-superseded-fleets] {0} superseded root(s): stopped {1} of {2} proc(s) ({3} name-skipped, {4} recycled-skipped, {5} already-gone, {6} stop-failed). ~{7} MB reclaimed (candidates totalled ~{8} MB)." `
  -f $reapList.Count, $killed, $reapPids.Count, $skippedName, $skippedRecycled, $skippedGone, $stopFailed, $reclaimedMB, $reapMB)

exit 0
