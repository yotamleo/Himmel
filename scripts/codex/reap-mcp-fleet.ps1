# reap-mcp-fleet.ps1 (HIMMEL-741) - report/reap ORPHANED Codex MCP-fleet processes.
#
# WHY: the Codex app-server (`codex.exe app-server`, launched via
# app-server-broker.mjs) spawns a fleet of ~5-6 MCP server processes per job
# (node_repl.exe, `uvx mcp-obsidian`, `bun ... --cwd <codex plugin cache> start`
# and their `bun server.ts` grandchildren) and does NOT reap them when the job
# ends. Repeated jobs pile up dozens of leaked node/bun/uvx processes on this
# Windows box. This tool surfaces (default) or terminates (--kill) ONLY the
# fleet processes whose Codex app-server ancestor is GONE - never a fleet with a
# live app-server (that fleet is legitimately in use).
#
# HIMMEL-840 EXTENSION: the codex-exec CLI sandbox (a DIFFERENT lane than the
# app-server above, dispatched via dispatch-codex-exec.sh) leaks its own MCP
# fleet - plain `npx <mcp-server>` under `cmd.exe` wrappers with NO codex path
# marker of their own once the `codex.exe` supervisor is gone, structurally
# invisible to the Test-CodexOwned fingerprint above. Two new primitives close
# that gap:
#   -RootPid <pid> [-StartedAt <epoch>] [-Kill] - report/reap every LIVE
#     descendant of a given (possibly dead) root pid, walking ParentProcessId
#     links down from RootPid over the current table (the dispatcher's own
#     EXIT trap calls this with its codex child's pid right after that child
#     exits - anything still alive under it is, by construction, a leak).
#     -StartedAt guards pid-reuse: a would-be descendant whose own
#     CreationDate predates the job start is excluded (it belongs to whatever
#     unrelated process now holds that pid, not our job).
#   Registry-driven maintenance (default mode, no -RootPid): in addition to
#     the app-server orphan scan above, reads the job registry dispatch-
#     codex-exec.sh writes (CODEX_JOBS_DIR, default
#     ~/.himmel/state/codex-exec-jobs/*.json) and, for every entry whose
#     codex_pid is dead (the dispatcher's own EXIT-trap reap never ran, or
#     died before it could - e.g. a SIGKILL), reports (default) / reaps
#     (-Kill) its descendants the same way, removing the entry under -Kill.
#     Also prints a summary line (registered jobs live/dead, dead-job fleet
#     count, app-server orphan count) plus an OBSERVABILITY-ONLY count of
#     MCP-shaped processes with a dead direct parent that carry no codex
#     lineage evidence at all (unregistered/historic leaks) - counted, never
#     killed (no marker to prove they are ours; the conservative "when unsure,
#     exclude" rule from the app-server fingerprint applies here too).
#
# GROUNDING (verified on this machine, 2026-07-07):
#   Live topology, one app-server subtree (`Get-CimInstance Win32_Process`):
#     codex.exe app-server (pid 51184)               <- SUPERVISOR
#       |- node_repl.exe   ...\OpenAI\Codex\runtimes\cua_node\...\node_repl.exe
#       |- uvx.exe         "...\uvx.exe" mcp-obsidian
#       |- bun.exe         run --cwd C:/Users/.../.codex/plugins/cache/himmel/luna-correlate/... start
#       |    \- bun.exe    server.ts        (grandchild, no codex marker of its own)
#       \- bun.exe         run --cwd C:/Users/.../.codex/plugins/cache/himmel/telegram-himmel/... start
#   The broker that owns the app-server:
#     node ...\.claude\plugins\cache\openai-codex\codex\1.0.5\scripts\app-server-broker.mjs serve ...
#   Multiple app-servers (51184 / 28748 / 61016 / desktop-app 66900) each carry
#   their own fleet -> that duplication IS the flood.
#
# FINGERPRINT (deliberately conservative - "when unsure, exclude"):
#   codex-owned  = own CommandLine references a codex-only path
#                  (OpenAI\Codex\runtimes  OR  \.codex\plugins\cache\)  OR  Name=node_repl.exe.
#                  These survive their parent's death (own cmdline still proves lineage).
#   supervisor   = Name codex.exe/Codex.exe (app-server + desktop app)  OR  app-server-broker.mjs.
#   A process is ORPHANED when it is codex-owned (or a descendant of a codex-owned
#   process still in the table) AND walking its ParentProcessId chain reaches a
#   dead/absent ancestor WITHOUT passing a LIVE supervisor.
#   Bare `uvx mcp-obsidian` / `bun server.ts` whose whole codex parent chain has
#   already vanished are NOT reaped (no codex marker to prove lineage) - the SAFE
#   under-reap direction, mirroring restart-bridge.ps1's server.ts handling.
#
# USAGE:
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1            # report-only (default; app-server scan + registry maintenance)
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1 -Kill     # terminate the orphans + dead-job registry fleets
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1 -RootPid <pid> [-StartedAt <epoch>] [-Kill]
#                                                                     # HIMMEL-840: report/reap descendants of one root pid
# Exit codes: 0 = ran (report or kill); 1 = usage/enumeration error.

[CmdletBinding()]
param(
  [switch]$Kill,
  # HIMMEL-840: single-root descendant-reap primitive (dispatch-codex-exec.sh's
  # own EXIT trap). 0 = not provided (a real pid is never 0) -> default mode.
  [int]$RootPid = 0,
  [string]$StartedAt = '',
  # Dot-source seam for the hermetic test: define the functions, then return
  # WITHOUT scanning the live process table.
  [switch]$AsLibrary
)

# --- pure predicates + filter (fed a records array; unit-tested directly) ----

function Test-CodexOwned {
  param([Parameter(Mandatory)]$Proc)
  if ($Proc.Name -and ($Proc.Name -ieq 'node_repl.exe')) { return $true }
  $cl = [string]$Proc.CommandLine
  if (-not $cl) { return $false }
  return ($cl -match 'OpenAI[\\/]+Codex[\\/]+runtimes') -or ($cl -match '[\\/]+\.codex[\\/]+plugins[\\/]+cache[\\/]+')
}

function Test-FleetSupervisor {
  param([Parameter(Mandatory)]$Proc)
  if ($Proc.Name -and ($Proc.Name -ieq 'codex.exe')) { return $true }
  $cl = [string]$Proc.CommandLine
  if ($cl -and ($cl -match 'app-server-broker\.mjs')) { return $true }
  return $false
}

# Walk the ParentProcessId chain over the supplied (live) record set.
# Returns a hashtable: HasLiveSupervisor (bool), UnderCodex (bool - an ancestor
# is codex-owned), DeadAncestorPid (first parent pid absent from the table, or $null).
function Resolve-Ancestry {
  param([Parameter(Mandatory)]$Proc, [Parameter(Mandatory)][hashtable]$ByPid)
  $hasSup = $false; $underCodex = $false; $deadPid = $null
  $seen = @{}
  $cur = $Proc.ParentProcessId
  $depth = 0
  while ($null -ne $cur -and $cur -ne 0 -and $depth -lt 64) {
    $depth++
    if ($seen.ContainsKey([string]$cur)) { break }   # pid-reuse cycle guard
    $seen[[string]$cur] = $true
    if (-not $ByPid.ContainsKey([string]$cur)) { $deadPid = $cur; break }  # ancestor gone
    $anc = $ByPid[[string]$cur]
    if (Test-FleetSupervisor -Proc $anc) { $hasSup = $true; break }
    if (Test-CodexOwned -Proc $anc)      { $underCodex = $true }
    $cur = $anc.ParentProcessId
  }
  return @{ HasLiveSupervisor = $hasSup; UnderCodex = $underCodex; DeadAncestorPid = $deadPid }
}

# Pure orphan filter. $Procs = array of records exposing ProcessId,
# ParentProcessId, Name, CommandLine (CreationDate optional). Returns the orphan
# records annotated with a DeadAncestorPid note.
function Get-OrphanFleet {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $byPid = @{}
  foreach ($p in $Procs) { if ($null -ne $p.ProcessId) { $byPid[[string]$p.ProcessId] = $p } }
  $out = New-Object System.Collections.ArrayList
  foreach ($p in $Procs) {
    $isCodex = Test-CodexOwned -Proc $p
    # A supervisor (the app-server / broker) is NEVER a reap target.
    if (Test-FleetSupervisor -Proc $p) { continue }
    $anc = Resolve-Ancestry -Proc $p -ByPid $byPid
    $fleetRelated = $isCodex -or $anc.UnderCodex
    # Orphan requires EVIDENCE of a broken chain (a dead/absent ancestor pid),
    # not merely the absence of a recognized supervisor: a codex-owned process
    # whose fully-live chain roots at PID 0 or an unrecognized supervisor
    # variant must never be reaped (conservative under-reap).
    if ($fleetRelated -and -not $anc.HasLiveSupervisor -and $null -ne $anc.DeadAncestorPid) {
      $p | Add-Member -NotePropertyName DeadAncestorPid -NotePropertyValue $anc.DeadAncestorPid -Force
      [void]$out.Add($p)
    }
  }
  return $out.ToArray()
}

# Get-DescendantPids (HIMMEL-840) - pure descendant walk. Returns every LIVE
# pid in $Procs reachable from $RootPid by following ParentProcessId links
# DOWNWARD (children, grandchildren, ...). $RootPid itself need not be present
# in $Procs (it is typically already dead - that is why we are reaping) - a
# direct child still records the dead root's pid as its own ParentProcessId,
# which is all the walk needs to find it. $StartedAtEpoch, when given, guards
# pid-reuse: a candidate descendant whose own CreationDate predates the job
# start is excluded (and its subtree is NOT traversed - conservative
# under-reap, mirrors Get-OrphanFleet's stance).
function Get-DescendantPids {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][int]$RootPid,
    [Nullable[long]]$StartedAtEpoch = $null
  )
  $byParent = @{}
  foreach ($p in $Procs) {
    $key = [string]$p.ParentProcessId
    if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
    [void]$byParent[$key].Add($p)
  }
  $result = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Generic.Queue[int]
  $queue.Enqueue($RootPid)
  $visited = @{}
  $depth = 0
  while ($queue.Count -gt 0 -and $depth -lt 4096) {
    $depth++
    $cur = $queue.Dequeue()
    $curKey = [string]$cur
    if ($visited.ContainsKey($curKey)) { continue }   # pid-reuse cycle guard
    $visited[$curKey] = $true
    if (-not $byParent.ContainsKey($curKey)) { continue }
    foreach ($child in $byParent[$curKey]) {
      if ($null -ne $StartedAtEpoch -and $child.CreationDate -is [datetime]) {
        $childEpoch = [long][DateTimeOffset]::new($child.CreationDate.ToUniversalTime()).ToUnixTimeSeconds()
        if ($childEpoch -lt $StartedAtEpoch) { continue }  # predates the job - not ours (pid-reuse guard)
      }
      [void]$result.Add([int]$child.ProcessId)
      $queue.Enqueue([int]$child.ProcessId)
    }
  }
  return $result.ToArray()
}

# Test-McpShaped (HIMMEL-840, observability-only) - a coarse "looks like an
# MCP-server-launching process" predicate used ONLY for the report-mode
# visibility count of unregistered/historic dead-parent leaks (point 4). It is
# deliberately looser than Test-CodexOwned (no path-marker requirement) and
# MUST NEVER drive a kill decision - it has no lineage evidence, just a name/
# cmdline shape shared by legitimate live-Claude MCP servers too.
function Test-McpShaped {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name) { return $false }
  if ($Proc.Name -in @('node.exe', 'bun.exe', 'uvx.exe', 'npx.exe')) { return $true }
  if ($Proc.Name -ieq 'cmd.exe') {
    $cl = [string]$Proc.CommandLine
    return ($cl -match 'npx(\.cmd)?\s')
  }
  return $false
}

if ($AsLibrary) { return }

# --- production path: enumerate the live table, report, optionally kill -------

$ErrorActionPreference = 'Stop'

try {
  $records = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    ForEach-Object {
      [pscustomobject]@{
        ProcessId       = [int]$_.ProcessId
        ParentProcessId = [int]$_.ParentProcessId
        Name            = [string]$_.Name
        CommandLine     = [string]$_.CommandLine
        CreationDate    = $_.CreationDate
      }
    })
} catch {
  Write-Error "[reap-mcp-fleet] could not enumerate processes: $_"
  exit 1
}

# --- HIMMEL-840: -RootPid mode - report/reap descendants of ONE root pid ----
# (the dispatcher's own EXIT trap, called with its codex child's pid).
if ($RootPid -gt 0) {
  # Entry-point safety parity with the registry-scan path below (which skips a
  # job whose codex_pid is still present in the table): a caller-supplied root
  # pid that is itself still alive must abort, not walk descendants - a live
  # root's own fleet is legitimately in use, not a leak.
  $byPidRoot = @{}
  foreach ($p in $records) { $byPidRoot[[string]$p.ProcessId] = $p }
  if ($byPidRoot.ContainsKey([string]$RootPid)) {
    Write-Host "[reap-mcp-fleet] pid $RootPid is still alive - skipping descendant walk (only reap descendants of a dead root)."
    exit 0
  }
  $startedEpoch = $null
  if ($StartedAt) {
    $parsed = 0L
    if ([long]::TryParse($StartedAt, [ref]$parsed)) { $startedEpoch = $parsed }
  }
  $descendants = @(Get-DescendantPids -Procs $records -RootPid $RootPid -StartedAtEpoch $startedEpoch)
  if ($descendants.Count -eq 0) {
    Write-Host "[reap-mcp-fleet] no live descendants of pid $RootPid."
    exit 0
  }
  Write-Host ("[reap-mcp-fleet] {0} descendant process(es) of pid {1}:" -f $descendants.Count, $RootPid)
  foreach ($d in $descendants) {
    $nm = if ($byPidRoot.ContainsKey([string]$d)) { $byPidRoot[[string]$d].Name } else { '?' }
    Write-Host "  pid $d ($nm)"
  }
  if (-not $Kill) {
    Write-Host "[reap-mcp-fleet] report-only (default). Re-run with -Kill to terminate the above."
    exit 0
  }
  $killedRoot = 0
  foreach ($d in $descendants) {
    try {
      Stop-Process -Id $d -Force -ErrorAction Stop
      $killedRoot++
    } catch {
      Write-Warning "[reap-mcp-fleet] could not kill pid $d`: $_"
    }
  }
  Write-Host ("[reap-mcp-fleet] terminated {0}/{1} descendant(s) of pid {2}." -f $killedRoot, $descendants.Count, $RootPid)
  exit 0
}

# --- default mode: app-server orphan scan + registry-driven maintenance -----

$orphans = @(Get-OrphanFleet -Procs $records)

if ($orphans.Count -eq 0) {
  Write-Host "[reap-mcp-fleet] no orphaned Codex MCP-fleet processes found."
} else {
  $now = Get-Date
  $rows = $orphans | ForEach-Object {
    $ageStr = '?'
    if ($_.CreationDate -is [datetime]) {
      $mins = [int]([math]::Round(($now - $_.CreationDate).TotalMinutes))
      $ageStr = "${mins}m"
    }
    $snip = if ($_.CommandLine) { $_.CommandLine.Substring(0, [Math]::Min(80, $_.CommandLine.Length)) } else { '' }
    [pscustomobject]@{
      PID          = $_.ProcessId
      Name         = $_.Name
      Age          = $ageStr
      DeadAncestor = $_.DeadAncestorPid
      Cmdline      = $snip
    }
  }

  Write-Host ("[reap-mcp-fleet] {0} orphaned Codex MCP-fleet process(es):" -f $orphans.Count)
  $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

  if (-not $Kill) {
    Write-Host "[reap-mcp-fleet] report-only (default). Re-run with -Kill to terminate the above."
  } else {
    $killed = 0
    foreach ($o in $orphans) {
      try {
        Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop
        Write-Host "[reap-mcp-fleet] killed pid $($o.ProcessId) ($($o.Name))"
        $killed++
      } catch {
        Write-Warning "[reap-mcp-fleet] could not kill pid $($o.ProcessId): $_"
      }
    }
    Write-Host ("[reap-mcp-fleet] terminated {0}/{1} orphan(s)." -f $killed, $orphans.Count)
  }
}

# --- HIMMEL-840: registry-driven maintenance (visibility surface, point 4) --
# Every job dispatch-codex-exec.sh registered under CODEX_JOBS_DIR whose
# codex_pid is now dead is a leak the dispatcher's own EXIT-trap reap never
# cleaned up (killed before it could run). Report (default) or reap (-Kill)
# its remaining descendants the same way -RootPid does, and drop the entry
# under -Kill (a report-only pass must not mutate state).
$jobsDir = if ($env:CODEX_JOBS_DIR) { $env:CODEX_JOBS_DIR } else { Join-Path $env:USERPROFILE '.himmel\state\codex-exec-jobs' }
$jobFiles = @()
if (Test-Path -LiteralPath $jobsDir) {
  $jobFiles = @(Get-ChildItem -LiteralPath $jobsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
}
$byPidAll = @{}
foreach ($p in $records) { $byPidAll[[string]$p.ProcessId] = $p }

$liveJobs = 0
$deadJobs = 0
$deadFleetTotal = 0
foreach ($jf in $jobFiles) {
  $job = $null
  try { $job = Get-Content -Raw -LiteralPath $jf.FullName | ConvertFrom-Json } catch { continue }
  if (-not $job.codex_pid) { continue }
  $jobPid = [int]$job.codex_pid
  $jobStarted = $null
  if ($job.started_at) {
    $parsedStarted = 0L
    if ([long]::TryParse([string]$job.started_at, [ref]$parsedStarted)) { $jobStarted = $parsedStarted }
  }
  if ($byPidAll.ContainsKey([string]$jobPid)) { $liveJobs++; continue }
  $deadJobs++
  $desc = @(Get-DescendantPids -Procs $records -RootPid $jobPid -StartedAtEpoch $jobStarted)
  $deadFleetTotal += $desc.Count
  if ($desc.Count -gt 0) {
    Write-Host ("[reap-mcp-fleet] registry job {0} (codex pid {1}, dead): {2} descendant fleet process(es)" -f $jf.Name, $jobPid, $desc.Count)
  }
  if ($Kill) {
    foreach ($d in $desc) {
      try { Stop-Process -Id $d -Force -ErrorAction Stop } catch { Write-Warning "[reap-mcp-fleet] could not kill pid $d`: $_" }
    }
    Remove-Item -LiteralPath $jf.FullName -Force -ErrorAction SilentlyContinue
  }
}

# Observability-only: MCP-shaped processes with a dead DIRECT parent that
# carry no codex lineage evidence at all (unregistered/historic leaks - a job
# that predates this registry, or a fleet that lost its own marker). Counted
# for visibility; NEVER reaped (no evidence they are ours - conservative
# under-reap).
$unregisteredDeadParent = 0
foreach ($p in $records) {
  if (-not (Test-McpShaped -Proc $p)) { continue }
  if (-not $byPidAll.ContainsKey([string]$p.ParentProcessId)) { $unregisteredDeadParent++ }
}

Write-Host ("[reap-mcp-fleet] registry: {0} job(s) live, {1} job(s) dead ({2} descendant fleet proc(s)); app-server orphans: {3}; unregistered dead-parent MCP-shaped proc(s): {4} (report-only, never reaped)" `
  -f $liveJobs, $deadJobs, $deadFleetTotal, $orphans.Count, $unregisteredDeadParent)

exit 0
