# HIMMEL-923 host-level observability detectors.
# Report-only: emits JSON for the flow exporter and never controls processes.
[CmdletBinding()]
param(
  [switch]$AsLibrary
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Capture our own switch BEFORE dot-sourcing: the reaper's param binding runs
# in THIS scope and its -AsLibrary overwrites our $AsLibrary, so the guard
# below would otherwise always return and main would silently never run.
$HostDetectorsAsLibrary = [bool]$AsLibrary
$Reaper = Join-Path $PSScriptRoot '..\codex\reap-mcp-fleet.ps1'
. $Reaper -AsLibrary

$TreeClassOrder = @(
  'claude',
  'codex-app-server',
  'codex-exec',
  'hermes-gateway',
  'telegram-bridge',
  'mcp-standalone',
  'other'
)

$OrphanClassOrder = @(
  'codex-fleet',
  'codex-exec-registry',
  'hermes-gateway-orphan',
  'codex-app-server-orphan',
  'mcp-dead-parent-unattributed'
)

function ConvertTo-DetectorRecord {
  param([Parameter(Mandatory)]$Proc)
  $rss = 0L
  if ($null -ne $Proc.WorkingSetSize) { $rss = [int64]$Proc.WorkingSetSize }
  [pscustomobject]@{
    ProcessId       = [int]$Proc.ProcessId
    ParentProcessId = [int]$Proc.ParentProcessId
    Name            = [string]$Proc.Name
    CommandLine     = [string]$Proc.CommandLine
    CreationDate    = $Proc.CreationDate
    WorkingSetSize  = $rss
  }
}

function New-ByPid {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $byPid = @{}
  foreach ($p in $Procs) {
    if ($null -ne $p.ProcessId) { $byPid[[string]$p.ProcessId] = $p }
  }
  return $byPid
}

function Get-CodexJobsDir {
  if ($env:CODEX_JOBS_DIR) { return $env:CODEX_JOBS_DIR }
  # $userHome, not $home: $HOME is a read-only PowerShell automatic variable.
  $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
  return (Join-Path $userHome '.himmel\state\codex-exec-jobs')
}

function Read-CodexExecJobs {
  param([string]$JobsDir = '')
  $dir = if ($JobsDir) { $JobsDir } else { Get-CodexJobsDir }
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }

  $jobs = New-Object System.Collections.ArrayList
  foreach ($jf in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    try {
      $job = Get-Content -Raw -LiteralPath $jf.FullName | ConvertFrom-Json
      if (-not $job.codex_pid) { continue }
      $started = $null
      if ($job.started_at) {
        $parsed = 0L
        if ([long]::TryParse([string]$job.started_at, [ref]$parsed)) { $started = $parsed }
      }
      [void]$jobs.Add([pscustomobject]@{
        CodexPid  = [int]$job.codex_pid
        StartedAt = $started
      })
    } catch {
      continue
    }
  }
  return $jobs.ToArray()
}

function Test-ClaudeRoot {
  param([Parameter(Mandatory)]$Proc)
  return ($Proc.Name -and ($Proc.Name -ieq 'claude.exe'))
}

function Test-CodexAppServerRoot {
  param([Parameter(Mandatory)]$Proc)
  $cl = [string]$Proc.CommandLine
  if ($cl -match 'app-server-broker\.mjs') { return $true }
  return ($Proc.Name -and ($Proc.Name -ieq 'codex.exe') -and $cl -match '\bapp-server\b')
}

function Test-HermesGatewayRoot {
  param([Parameter(Mandatory)]$Proc)
  $cl = [string]$Proc.CommandLine
  if (-not $cl) { return $false }
  return ($cl -match '(^|\s)hermes(\.exe)?\s+gateway(\s|$)') -or ($cl -match 'hermes_cli' -and $cl -match '\bgateway\b')
}

function Test-TelegramBridgeRoot {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name -or ($Proc.Name -ine 'bun.exe' -and $Proc.Name -ine 'bun')) { return $false }
  $cl = [string]$Proc.CommandLine
  return $cl -match 'scripts[\\/]+telegram' -or $cl -match '(supervisor|poller)\.ts' -or $cl -match 'telegram-himmel'
}

function Test-McpStandaloneRoot {
  param([Parameter(Mandatory)]$Proc)
  if (-not (Test-McpShaped -Proc $Proc)) { return $false }
  if (Test-CodexOwned -Proc $Proc) { return $false }
  $cl = [string]$Proc.CommandLine
  return $cl -match '\b(qmd|mcp-obsidian|obsidian.*mcp|mcp.*server|server\.ts)\b'
}

function Get-ProcessClass {
  param(
    [Parameter(Mandatory)]$Proc,
    [Parameter(Mandatory)][hashtable]$CodexExecRoots
  )
  if ($CodexExecRoots.ContainsKey([string]$Proc.ProcessId)) { return 'codex-exec' }
  if (Test-ClaudeRoot -Proc $Proc) { return 'claude' }
  if (Test-CodexAppServerRoot -Proc $Proc) { return 'codex-app-server' }
  if (Test-HermesGatewayRoot -Proc $Proc) { return 'hermes-gateway' }
  if (Test-TelegramBridgeRoot -Proc $Proc) { return 'telegram-bridge' }
  if (Test-McpStandaloneRoot -Proc $Proc) { return 'mcp-standalone' }
  return $null
}

function Test-HasClassAncestor {
  param(
    [Parameter(Mandatory)]$Proc,
    [Parameter(Mandatory)][hashtable]$ByPid,
    [Parameter(Mandatory)][hashtable]$CandidateClasses
  )
  $seen = @{}
  $cur = $Proc.ParentProcessId
  $depth = 0
  while ($null -ne $cur -and $cur -ne 0 -and $depth -lt 64) {
    $depth++
    $key = [string]$cur
    if ($seen.ContainsKey($key)) { return $false }
    $seen[$key] = $true
    if (-not $ByPid.ContainsKey($key)) { return $false }
    if ($CandidateClasses.ContainsKey($key)) { return $true }
    $cur = $ByPid[$key].ParentProcessId
  }
  return $false
}

function Find-NearestRootPid {
  param(
    [Parameter(Mandatory)]$Proc,
    [Parameter(Mandatory)][hashtable]$ByPid,
    [Parameter(Mandatory)][hashtable]$RootClasses
  )
  $seen = @{}
  $cur = $Proc.ProcessId
  $depth = 0
  while ($null -ne $cur -and $cur -ne 0 -and $depth -lt 64) {
    $depth++
    $key = [string]$cur
    if ($seen.ContainsKey($key)) { return $null }
    $seen[$key] = $true
    if ($RootClasses.ContainsKey($key)) { return [int]$cur }
    if (-not $ByPid.ContainsKey($key)) { return $null }
    $cur = $ByPid[$key].ParentProcessId
  }
  return $null
}

function Get-AgentTreeRows {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Jobs
  )
  $byPid = New-ByPid -Procs $Procs
  $codexExecRoots = @{}
  foreach ($job in $Jobs) {
    if ($null -ne $job.CodexPid -and $byPid.ContainsKey([string]$job.CodexPid)) {
      $codexExecRoots[[string]$job.CodexPid] = $job.StartedAt
    }
  }

  $candidateClasses = @{}
  foreach ($p in $Procs) {
    $class = Get-ProcessClass -Proc $p -CodexExecRoots $codexExecRoots
    if ($class) { $candidateClasses[[string]$p.ProcessId] = $class }
  }

  $rootClasses = @{}
  foreach ($p in $Procs) {
    $key = [string]$p.ProcessId
    if (-not $candidateClasses.ContainsKey($key)) { continue }
    if (-not (Test-HasClassAncestor -Proc $p -ByPid $byPid -CandidateClasses $candidateClasses)) {
      $rootClasses[$key] = $candidateClasses[$key]
    }
  }

  $byRootPid = @{}
  foreach ($rootKey in $rootClasses.Keys) {
    $rootPid = [int]$rootKey
    $startedAt = $null
    if ($codexExecRoots.ContainsKey($rootKey)) { $startedAt = $codexExecRoots[$rootKey] }
    $tree = New-Object System.Collections.ArrayList
    [void]$tree.Add($rootPid)
    foreach ($d in @(Get-DescendantPids -Procs $Procs -RootPid $rootPid -StartedAtEpoch $startedAt)) {
      [void]$tree.Add([int]$d)
    }
    $byRootPid[$rootKey] = $tree.ToArray()
  }

  $totals = @{}
  foreach ($class in $TreeClassOrder) {
    $totals[$class] = [pscustomobject]@{ class = $class; rss_bytes = 0L; process_count = 0 }
  }

  $assigned = @{}
  foreach ($rootKey in $rootClasses.Keys) {
    $class = $rootClasses[$rootKey]
    foreach ($treePid in @($byRootPid[$rootKey])) {
      $pidKey = [string]$treePid
      if (-not $byPid.ContainsKey($pidKey)) { continue }
      $nearest = Find-NearestRootPid -Proc $byPid[$pidKey] -ByPid $byPid -RootClasses $rootClasses
      if ($null -eq $nearest -or [string]$nearest -ne $rootKey) { continue }
      $assigned[$pidKey] = $true
      $totals[$class].rss_bytes += [int64]$byPid[$pidKey].WorkingSetSize
      $totals[$class].process_count++
    }
  }

  foreach ($p in $Procs) {
    $key = [string]$p.ProcessId
    if ($assigned.ContainsKey($key)) { continue }
    $totals['other'].rss_bytes += [int64]$p.WorkingSetSize
    $totals['other'].process_count++
  }

  return @($TreeClassOrder | ForEach-Object { $totals[$_] })
}

function Get-OrphanRows {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Jobs
  )
  $byPid = New-ByPid -Procs $Procs
  $counts = @{}
  foreach ($class in $OrphanClassOrder) { $counts[$class] = 0 }

  $fleet = @(Get-OrphanFleet -Procs $Procs)
  $counts['codex-fleet'] = $fleet.Count
  $attributedPids = @{}
  foreach ($f in $fleet) { $attributedPids[[string]$f.ProcessId] = $true }

  foreach ($job in $Jobs) {
    if ($null -eq $job.CodexPid) { continue }
    if ($byPid.ContainsKey([string]$job.CodexPid)) { continue }
    $desc = @(Get-DescendantPids -Procs $Procs -RootPid ([int]$job.CodexPid) -StartedAtEpoch $job.StartedAt)
    $counts['codex-exec-registry'] += $desc.Count
    foreach ($d in $desc) { $attributedPids[[string]$d] = $true }
  }

  foreach ($p in $Procs) {
    if (Test-CodexAppServerRoot -Proc $p) {
      $anc = Resolve-Ancestry -Proc $p -ByPid $byPid
      if ($null -ne $anc.DeadAncestorPid -and -not $anc.HasLiveSupervisor) {
        $counts['codex-app-server-orphan']++
      }
    }
    if (Test-HermesGatewayRoot -Proc $p) {
      $anc = Resolve-Ancestry -Proc $p -ByPid $byPid
      if ($null -ne $anc.DeadAncestorPid -and -not $anc.HasLiveSupervisor) {
        $counts['hermes-gateway-orphan']++
      }
    }
    if (Test-McpShaped -Proc $p) {
      $parent = [int]$p.ParentProcessId
      if ($parent -ne 0 -and -not $byPid.ContainsKey([string]$parent) -and -not (Test-CodexOwned -Proc $p) -and -not $attributedPids.ContainsKey([string]$p.ProcessId)) {
        $counts['mcp-dead-parent-unattributed']++
      }
    }
  }

  return @($OrphanClassOrder | ForEach-Object {
    [pscustomobject]@{ class = $_; count = [int]$counts[$_] }
  })
}

function Invoke-HostDetectorSnapshot {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    # Untyped on purpose: [object[]] + [AllowNull()] still fails binding on
    # an omitted param under Windows PowerShell 5.1. $null means read from disk.
    [AllowNull()]$Jobs = $null,
    [string]$JobsDir = ''
  )
  $records = @($Procs | ForEach-Object { ConvertTo-DetectorRecord -Proc $_ })
  # @() wraps the WHOLE conditional: a statement-assignment whose branch
  # emits an empty array yields $null (zero pipeline objects), which then
  # fails the Mandatory -Jobs binding downstream when no codex jobs exist.
  $jobRows = @(if ($null -ne $Jobs) { $Jobs } else { Read-CodexExecJobs -JobsDir $JobsDir })
  [pscustomobject]@{
    trees   = @(Get-AgentTreeRows -Procs $records -Jobs $jobRows)
    orphans = @(Get-OrphanRows -Procs $records -Jobs $jobRows)
  }
}

if ($HostDetectorsAsLibrary) { return }

try {
  $records = @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { ConvertTo-DetectorRecord -Proc $_ })
  Invoke-HostDetectorSnapshot -Procs $records | ConvertTo-Json -Compress -Depth 6
} catch {
  # Not Write-Error: with $ErrorActionPreference='Stop' it throws inside the
  # catch and the message is lost before exit.
  [Console]::Error.WriteLine("[host-detectors] could not collect host detector snapshot: $_")
  exit 1
}
