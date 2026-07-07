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
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1            # report-only (default)
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1 -Kill     # terminate the orphans
# Exit codes: 0 = ran (report or kill); 1 = usage/enumeration error.

[CmdletBinding()]
param(
  [switch]$Kill,
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

$orphans = @(Get-OrphanFleet -Procs $records)

if ($orphans.Count -eq 0) {
  Write-Host "[reap-mcp-fleet] no orphaned Codex MCP-fleet processes found."
  exit 0
}

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
  exit 0
}

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
exit 0
