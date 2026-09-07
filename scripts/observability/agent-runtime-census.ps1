# agent-runtime-census.ps1 (HIMMEL-1988) - REPORT-ONLY Windows agent-runtime
# evidence collector for the RAM + MCP lifecycle program (P0-1).
#
# WHY: the Windows kernel pool grows under agent/tool churn (File / Toke / FMfn
# rising with commit flat - kernel objects, not user private memory, see
# ram-leak-investigation-2026-08-20.md). Attribution needs CORRELATED
# snapshots - the supervisor/MCP-fleet/process-family generation at time T
# alongside the pool counters at time T - not one-off readings. This script
# produces exactly that and NOTHING else: it never kills, restarts, throttles
# or reconfigures a process, and it never reads a full command line into its
# output.
#
# WHAT IS RECORDED FROM A COMMAND LINE, EXACTLY: the executable name plus ONE
# argument. Never the rest of the line, never the environment, never anything
# after a bare `--`, never the value of any flag, and a path argument only as
# its leaf. That one argument is scrubbed for known credential shapes
# (ledger-append.sh's --detail regexes).
# The limit of the guarantee, stated plainly: that argument is a POSITIONAL
# token by design - it is what tells two MCP servers apart, which the duplicate
# census needs - so a bare positional secret with no recognizable credential
# shape (`qmd.exe <opaque-token>`) WOULD be recorded. Pass secrets to servers
# as flag values or environment, never as positional arguments; flag values are
# suppressed unconditionally.
#
# USAGE:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/observability/agent-runtime-census.ps1 `
#       -Label claude-swarm                       # one snapshot, appended + printed
#   ... -Label codex -Loop -IntervalSec 300 -MaxSnapshots 12    # 1 hour at the 5-min cadence
#   ... -OutFile D:\evidence\census.jsonl         # default: $HOME\.himmel\agent-runtime-census.jsonl
#
#   -Label is REQUIRED - the harness under test (codex / claude-swarm /
#   hermes-wsl). The program insists evidence stays labelled per harness -
#   do not conflate two harnesses in one run.
#   Each invocation appends one compact JSON object per snapshot to -OutFile
#   and prints a human table on stdout. Without -Loop exactly one snapshot is
#   taken (there is no unbounded-loop mode: -MaxSnapshots always bounds it).
#
#   Run ONE collector per -OutFile. Each row is written as a single append, so
#   a row is never torn in half, but there is no cross-process lock: two
#   collectors sharing an -OutFile interleave their rows (and one can fail an
#   append while the other holds the file). The file is an append-only evidence
#   log, not a coordinated store.
#
#   Reading the evidence: two consecutive rows let you correlate a fleet or
#   process-generation change (a new MCP root pid / creation time, a duplicate
#   count, a bash-family spike) with the File / Toke / FMfn deltas between them.
#
# TEST-ONLY SEAMS: -FixtureProcesses <json> / -FixturePoolmon <dump> feed the
# parsers a canned table instead of the live box (see
# test-agent-runtime-census.sh). In fixture mode the live probes (Get-Counter,
# node/npm/bun versions, the poolmon locator) are skipped so the suite is
# hermetic - those fields come out null. -AsLibrary dot-sources the functions
# without taking any snapshot.
#
# Exit codes: 0 = ran; 1 = usage / unrecoverable enumeration error.

[CmdletBinding()]
param(
  [switch]$Loop,
  [ValidateRange(1, 86400)][int]$IntervalSec = 300,
  [ValidateRange(1, 100000)][int]$MaxSnapshots = 1,
  [string]$OutFile = '',
  [string]$Label = '',
  [string]$FixtureProcesses = '',
  [string]$FixturePoolmon = '',
  [switch]$AsLibrary
)

$script:TrackedPoolTags = @('File', 'Toke', 'FMfn', 'SeAt', 'SeTd', 'SeTl')

# Exact process-name stems counted per snapshot (a family census, not a
# fingerprint): these are the shapes the incident notes track - hook/tool
# shell churn (bash/sh/cmd/pwsh/powershell/conhost/git), language runtimes
# that host MCP servers (node/bun/python), and the WSL boundary.
$script:FamilyStems = @('bash', 'sh', 'node', 'bun', 'python', 'pwsh', 'powershell', 'cmd', 'wsl', 'conhost', 'git')

$script:SupervisorNames = @('codex.exe', 'claude.exe')

# MCP-fleet-root shapes: a direct child of a supervisor running one of these
# executables counts as a fleet root. Deliberately coarse - this is an
# observability census, not a kill decision, so a false positive costs one
# spurious row and nothing else.
$script:McpExeNames = @(
  'node.exe', 'node_repl.exe', 'bun.exe', 'deno.exe',
  'python.exe', 'pythonw.exe', 'uv.exe', 'uvx.exe', 'npx.exe',
  'tokensave.exe', 'qmd.exe'
)

# --- redaction ---------------------------------------------------------------

# Anchored credential shapes, mirroring the ledger-append.sh --detail scrub
# (HIMMEL-1176) so both surfaces redact the same things. Lightweight, not a
# full gitleaks pass.
function Get-ScrubbedToken {
  param([string]$Text)
  if (-not $Text) { return '' }
  $t = $Text
  $t = $t -replace '[0-9]{8,10}:[A-Za-z0-9_-]{35}', '[REDACTED]'
  $t = $t -replace '(?i)bearer\s+[A-Za-z0-9._-]{16,}', 'bearer [REDACTED]'
  # `_-` inside the body: modern keys are hyphenated (`sk-proj-…`, `sk-ant-…`),
  # which the bare alphanumeric class this was copied from does not match
  # (codex panel; ledger-append.sh's copy was aligned by HIMMEL-1996 - keep the
  # two surfaces in lockstep).
  $t = $t -replace 'sk-[A-Za-z0-9][A-Za-z0-9_-]{15,}', '[REDACTED]'
  $t = $t -replace 'AKIA[0-9A-Z]{16}', '[REDACTED]'
  $t = $t -replace '(?i)(api[_-]?key|token|secret)\s*[:=]\s*[A-Za-z0-9._-]{12,}', '$1=[REDACTED]'
  return $t
}

# Tokenize a command line (quote-aware), stopping at a bare `--` so nothing a
# caller passed through to the child program can reach the output.
function Get-CommandTokens {
  param([string]$CommandLine)
  if (-not $CommandLine) { return @() }
  # `"(?:\\.|[^"])*"` keeps an ESCAPED quote inside a quoted value from ending
  # the token - otherwise `--opt "a \"b\" c"` splits into fragments and a
  # fragment of a flag VALUE could reach candidate position (codex panel).
  $raw = @([regex]::Matches($CommandLine, '"(?:\\.|[^"])*"|\S+') | ForEach-Object { $_.Value })
  $out = New-Object System.Collections.ArrayList
  foreach ($t in $raw) {
    $u = $t.Trim('"')
    if ($u -eq '--') { break }
    [void]$out.Add($u)
  }
  return $out.ToArray()
}

# A recorded argument must LOOK like an identity - a package name, a module, a
# script path. Anything else is a payload, and payloads are never persisted.
$script:IdentityArgPattern = '^[A-Za-z0-9_@:.,+/\\-]+$'

# KNOWN-BOOLEAN ONLY - when in doubt, value-taking. These flags never consume
# the token after them, so `npx -y <pkg>` (the most common MCP launch shape)
# identifies as <pkg> instead of collapsing every npx server into one `-y`
# duplicate group. Add a flag here only when it provably takes no value: a
# wrong entry here exposes that flag's value, which is the leak this whole
# path exists to prevent.
$script:KnownBooleanFlags = @('-y', '--yes', '-q', '--quiet', '--no-install', '--offline')

# The ONLY command-line-derived field that reaches the JSON: ONE argument -
# the first token that identifies what is running. `uvx --with <pin> pkg` must
# identify as `pkg`, not as `--with` (which would collapse every uvx server
# into one duplicate group - the failure HIMMEL-1328 fixed in
# reap-mcp-fleet.ps1), so leading flags are stepped over.
#
# A flag is assumed to take a value BY DEFAULT (codex panel, HIMMEL-1988).
# Enumerating the value-taking ones cannot be safe: the token after an UNKNOWN
# flag - `--prompt <text>`, `-c <code>`, `--from <src>` - is exactly where a
# prompt, a program or a credential sits, and one unlisted flag is one leak.
# The single exception is $script:KnownBooleanFlags, flags that provably take
# no value (`npx -y <pkg>` is the most common MCP launch shape, and treating
# `-y` as value-taking would identify every npx server as `-y`). A
# `--flag=value` token carries its own value, so it consumes nothing and is
# recorded as the bare flag name.
#
# The result is path-shortened to its leaf (a full path carries a user name and
# machine layout, and adds nothing to the identity) and credential-scrubbed.
# Nothing else from the command line is ever recorded.
function Get-FirstArg {
  param([string]$CommandLine)
  $tokens = @(Get-CommandTokens -CommandLine $CommandLine)
  if ($tokens.Count -lt 2) { return '' }
  $a = ''
  $i = 1
  while ($i -lt $tokens.Count) {
    $t = [string]$tokens[$i]
    if ($t.StartsWith('-')) {
      if ($t.Contains('=')) { $i += 1 }                                                  # `--flag=value` carries its own value
      elseif ($script:KnownBooleanFlags -contains $t.ToLowerInvariant()) { $i += 1 }      # known-boolean: takes no value
      else { $i += 2 }                                                                    # default: assume value-taking
      continue
    }
    if ($t -notmatch $script:IdentityArgPattern) { $i += 1; continue }
    $a = $t
    break
  }
  # Nothing but flags (e.g. `node_repl.exe --stdio`, or a command line that is
  # all flag/value pairs): the first flag NAME is the only signal left, and it
  # beats a bare exe name shared by every server of that runtime. Never fall
  # back to an unvetted token - that is how a payload would get in the back way.
  if (-not $a -and ([string]$tokens[1]).StartsWith('-')) {
    $a = ([string]$tokens[1] -split '=')[0]
    # A SHORT flag can carry its value glued (`-psecret`): no `=`/`:` to cut at
    # and no following token to step over, so the value would ride the fallback
    # into the row (HIMMEL-1997). Keep the flag letter only. `--long` forms are
    # untouched - their value is always delimited or a separate token.
    if (-not $a.StartsWith('--') -and $a.Length -gt 2) { $a = $a.Substring(0, 2) }
  }
  if ($a -match '[\\/]') { $a = ($a -split '[\\/]')[-1] }
  # Anything still carrying its own value keeps only the name: a Windows-style
  # `/token:SECRET` switch looks positional to the `-` test above, and a
  # `pkg=value` pair has a value half nobody needs to identify a server (codex
  # panel). Run AFTER the leaf reduction, so `C:\srv\index.js` is already
  # `index.js` and does not lose its tail to the drive colon.
  if ($a -match '[:=]') { $a = ($a -split '[:=]')[0] }
  return (Get-ScrubbedToken -Text $a)
}

# --- pure classifiers / aggregators (fed a records array; unit-tested) -------

function Test-CensusSupervisor {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name) { return $false }
  return ($script:SupervisorNames -contains $Proc.Name.ToLowerInvariant())
}

function Test-CensusMcpRoot {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name) { return $false }
  $n = $Proc.Name.ToLowerInvariant()
  return ($script:McpExeNames -contains $n)
  # KNOWN LIMITATION: a generic `cmd.exe` / shell wrapper around a server
  # (`cmd /c npx <pkg>`) is deliberately NOT a fleet root here. Under the
  # exe + first-argument redaction rule its identity would be `cmd.exe /c`,
  # which groups unrelated servers into one bucket and manufactures false
  # duplicates - the exact failure HIMMEL-1328 fixed in reap-mcp-fleet.ps1's
  # Get-ServerIdentity. Such processes still land in the family counts.
}

function Get-CensusIdentity {
  param([Parameter(Mandatory)]$Proc)
  $exe = [string]$Proc.Name
  $arg = Get-FirstArg -CommandLine ([string]$Proc.CommandLine)
  if ($arg) { return "$exe $arg" }
  return $exe
}

# BFS over the supplied table. Returns @{ Count; WorkingSetBytes } for every
# live descendant of $RootPid (the root itself excluded).
function Get-CensusDescendants {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][int]$RootPid
  )
  $byParent = @{}
  $byPid = @{}
  foreach ($p in $Procs) {
    $key = [string]$p.ParentProcessId
    if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
    [void]$byParent[$key].Add($p)
    $byPid[[string]$p.ProcessId] = $p
  }
  $count = 0
  $ws = [int64]0
  $queue = New-Object System.Collections.Generic.Queue[int]
  $queue.Enqueue($RootPid)
  $visited = @{}
  $steps = 0
  while ($queue.Count -gt 0 -and $steps -lt 8192) {
    $steps++
    $cur = $queue.Dequeue()
    $curKey = [string]$cur
    if ($visited.ContainsKey($curKey)) { continue }   # pid-reuse cycle guard
    $visited[$curKey] = $true
    if (-not $byParent.ContainsKey($curKey)) { continue }
    # Same stale-PPID guard the fleet-root selection uses, one level at a time:
    # a real child cannot have started before its parent, so a "child" that
    # predates this node inherited a reused pid and is not part of the subtree
    # (its own subtree is skipped with it - conservative under-count).
    $curCreated = $null
    if ($byPid.ContainsKey($curKey) -and $byPid[$curKey].CreationDate -is [datetime]) { $curCreated = $byPid[$curKey].CreationDate }
    foreach ($child in $byParent[$curKey]) {
      $childKey = [string]$child.ProcessId
      if ($visited.ContainsKey($childKey)) { continue }
      if ($null -ne $curCreated -and $child.CreationDate -is [datetime]) {
        if ((New-TimeSpan -Start $curCreated -End $child.CreationDate).TotalSeconds -lt -2) { continue }
      }
      $count++
      $ws += [int64]$child.WorkingSetSize
      $queue.Enqueue([int]$child.ProcessId)
    }
  }
  return @{ Count = $count; WorkingSetBytes = $ws }
}

function Get-CensusFamilyCounts {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $counts = [ordered]@{}
  foreach ($stem in $script:FamilyStems) { $counts[$stem] = 0 }
  foreach ($p in $Procs) {
    if (-not $p.Name) { continue }
    $stem = $p.Name.ToLowerInvariant() -replace '\.exe$', ''
    if ($counts.Contains($stem)) { $counts[$stem] = $counts[$stem] + 1 }
  }
  return $counts
}

# Per supervisor: its direct MCP-shaped children (fleet roots), each with its
# own descendant rollup, plus the duplicate groups (same identity, same
# supervisor, more than one live instance).
function Get-CensusSupervisors {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $out = New-Object System.Collections.ArrayList
  foreach ($sup in @($Procs | Where-Object { Test-CensusSupervisor -Proc $_ })) {
    $roots = New-Object System.Collections.ArrayList
    $byIdentity = @{}
    # Stale-PPID guard: Windows does NOT clear a process's recorded
    # ParentProcessId when its real parent exits, so pid reuse can make an
    # unrelated older process look like a child of a freshly-started
    # supervisor that happens to hold its dead parent's pid. Same 2s
    # creation-time tolerance reap-mcp-fleet.ps1 uses for the same problem;
    # best-effort (skipped when either creation time is unavailable) because a
    # report-only false positive is cheap.
    $supCreated = $null
    if ($sup.CreationDate -is [datetime]) { $supCreated = $sup.CreationDate }
    foreach ($child in @($Procs | Where-Object { $_.ParentProcessId -eq $sup.ProcessId })) {
      if (-not (Test-CensusMcpRoot -Proc $child)) { continue }
      if ($null -ne $supCreated -and $child.CreationDate -is [datetime]) {
        if ((New-TimeSpan -Start $supCreated -End $child.CreationDate).TotalSeconds -lt -2) { continue }
      }
      $identity = Get-CensusIdentity -Proc $child
      $desc = Get-CensusDescendants -Procs $Procs -RootPid ([int]$child.ProcessId)
      [void]$roots.Add([ordered]@{
        pid                      = [int]$child.ProcessId
        exe                      = [string]$child.Name
        first_arg                = (Get-FirstArg -CommandLine ([string]$child.CommandLine))
        identity                 = $identity
        created_utc              = (Format-CensusTime -Value $child.CreationDate)
        working_set_mb           = [math]::Round(([int64]$child.WorkingSetSize) / 1MB, 1)
        descendants              = $desc.Count
        descendant_working_set_mb = [math]::Round($desc.WorkingSetBytes / 1MB, 1)
      })
      if (-not $byIdentity.ContainsKey($identity)) { $byIdentity[$identity] = New-Object System.Collections.ArrayList }
      [void]$byIdentity[$identity].Add([int]$child.ProcessId)
    }
    $dups = New-Object System.Collections.ArrayList
    foreach ($k in @($byIdentity.Keys | Sort-Object)) {
      if ($byIdentity[$k].Count -gt 1) {
        [void]$dups.Add([ordered]@{ identity = $k; count = $byIdentity[$k].Count; pids = @($byIdentity[$k].ToArray()) })
      }
    }
    [void]$out.Add([ordered]@{
      pid              = [int]$sup.ProcessId
      exe              = [string]$sup.Name
      created_utc      = (Format-CensusTime -Value $sup.CreationDate)
      working_set_mb   = [math]::Round(([int64]$sup.WorkingSetSize) / 1MB, 1)
      mcp_root_count   = $roots.Count
      mcp_roots        = @($roots.ToArray())
      duplicate_groups = @($dups.ToArray())
    })
  }
  return @($out.ToArray())
}

function Format-CensusMB {
  param($Bytes)
  if ($null -eq $Bytes) { return 'n/a' }
  return ('{0:N0} MB' -f ([double]$Bytes / 1MB))
}

function ConvertTo-CensusDate {
  param($Value)
  if ($null -eq $Value -or "$Value" -eq '') { return $null }
  if ($Value -is [datetime]) { return $Value }
  $parsed = [datetime]::MinValue
  $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
  if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Format-CensusTime {
  param($Value)
  $dt = ConvertTo-CensusDate -Value $Value
  if ($null -eq $dt) { return $null }
  return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# poolmon dump -> per-tag rollup. A tag can appear as BOTH a Nonp and a Paged
# row and poolmon's row order is not stable between dumps, so first-row-wins
# would silently swap which variant is read (seen live: FMfn 9 -> 538,939
# across two runs, see station-ops/pool/pool-rate.ps1). Every row for a tag is
# summed instead.
function Read-CensusPoolmon {
  param([Parameter(Mandatory)][string]$Path)
  $h = [ordered]@{}
  if (-not (Test-Path -LiteralPath $Path)) { return $h }
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if ($line -notmatch '^\s*\S{4}\s+(Nonp|Paged)\s+\d') { continue }
    $p = ($line -replace '^\s+', '') -split '\s+'
    $tag = $p[0]
    if ($script:TrackedPoolTags -notcontains $tag) { continue }
    if (-not $h.Contains($tag)) {
      $h[$tag] = [ordered]@{ type = $p[1]; allocs = [int64]0; outstanding = [int64]0; bytes = [int64]0 }
    } elseif ($h[$tag].type -ne $p[1]) {
      $h[$tag].type = 'both'
    }
    $h[$tag].allocs      = $h[$tag].allocs + [int64]$p[2]
    $h[$tag].outstanding = $h[$tag].outstanding + [int64]$p[4]
    $h[$tag].bytes       = $h[$tag].bytes + [int64]$p[5]
  }
  return $h
}

if ($AsLibrary) { return }

# --- live probes (skipped in fixture mode) -----------------------------------

function Get-CensusProcessTable {
  if ($FixtureProcesses) {
    $raw = Get-Content -LiteralPath $FixtureProcesses -Raw | ConvertFrom-Json
    return @($raw | ForEach-Object {
      [pscustomobject]@{
        ProcessId       = [int]$_.ProcessId
        ParentProcessId = [int]$_.ParentProcessId
        Name            = [string]$_.Name
        CommandLine     = [string]$_.CommandLine
        # Live CIM hands back a [datetime]; a fixture hands back a string.
        # Parse it here so every consumer below (including the stale-PPID
        # creation-time guard) sees the same type either way.
        CreationDate    = (ConvertTo-CensusDate -Value $_.CreationDate)
        WorkingSetSize  = [int64]$_.WorkingSetSize
      }
    })
  }
  return @(Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
    [pscustomobject]@{
      ProcessId       = [int]$_.ProcessId
      ParentProcessId = [int]$_.ParentProcessId
      Name            = [string]$_.Name
      CommandLine     = [string]$_.CommandLine
      CreationDate    = $_.CreationDate
      WorkingSetSize  = [int64]$_.WorkingSetSize
    }
  })
}

function Get-CensusRuntimeTuple {
  if ($FixtureProcesses) { return [ordered]@{ node = $null; npm = $null; bun = $null; bash_first = $null; bash_is_wsl = $null } }
  $probe = {
    param($exe, $args1)
    try {
      $v = & $exe $args1 2>$null
      if ($LASTEXITCODE -eq 0 -and $v) { return ([string]($v | Select-Object -First 1)).Trim() }
    } catch { }
    return $null
  }
  $bashFirst = $null
  try {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $bashFirst = [string]$cmd.Source }
  } catch { }
  $isWsl = $null
  if ($bashFirst) { $isWsl = ($bashFirst -match '(?i)[\\/]System32[\\/]bash\.exe$') }
  return [ordered]@{
    node        = (& $probe 'node' '--version')
    npm         = (& $probe 'npm' '--version')
    bun         = (& $probe 'bun' '--version')
    bash_first  = $bashFirst
    bash_is_wsl = $isWsl
  }
}

function Get-CensusMemoryCounters {
  if ($FixtureProcesses) {
    return [ordered]@{ pool_nonpaged_bytes = $null; pool_paged_bytes = $null; committed_bytes = $null; commit_limit_bytes = $null; available_bytes = $null }
  }
  $paths = [ordered]@{
    pool_nonpaged_bytes = '\Memory\Pool Nonpaged Bytes'
    pool_paged_bytes    = '\Memory\Pool Paged Bytes'
    committed_bytes     = '\Memory\Committed Bytes'
    commit_limit_bytes  = '\Memory\Commit Limit'
    available_bytes     = '\Memory\Available Bytes'
  }
  $out = [ordered]@{}
  foreach ($k in $paths.Keys) {
    $out[$k] = $null
    try {
      $s = Get-Counter -Counter $paths[$k] -ErrorAction Stop
      $out[$k] = [int64]$s.CounterSamples[0].CookedValue
    } catch {
      # Localized counter names / missing perf counters must degrade to null,
      # never fail the snapshot.
    }
  }
  return $out
}

# Same locator convention as station-ops/pool/pool-rate.ps1 (WDK/Windows Kits
# x64 build), with an env override. Absent poolmon is NOT a failure: the tag
# fields come out empty and the rest of the snapshot still lands.
function Find-CensusPoolmon {
  if ($env:HIMMEL_POOLMON -and (Test-Path -LiteralPath $env:HIMMEL_POOLMON)) { return $env:HIMMEL_POOLMON }
  $pm = Get-ChildItem 'C:\Program Files (x86)\Windows Kits', 'C:\Program Files\Windows Kits' `
          -Recurse -Filter poolmon.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'x64|amd64' } | Select-Object -First 1
  if ($pm) { return $pm.FullName }
  return $null
}

# --- snapshot ----------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# An unlabelled row is evidence nobody can attribute to a harness later, which
# is the one thing this program's notes insist on. Refuse instead (a plain
# check, not [Parameter(Mandatory)] - that would PROMPT, and this runs headless).
if (-not $Label) {
  Write-Error '[agent-runtime-census] -Label is required: name the harness under test (codex | claude-swarm | hermes-wsl).'
  exit 1
}

if (-not $OutFile) { $OutFile = Join-Path $HOME '.himmel\agent-runtime-census.jsonl' }
# Root a relative -OutFile against the current directory: `Split-Path -Parent`
# returns '' for a bare file name, and the empty parent then breaks the
# poolmon artifact path under ErrorActionPreference=Stop (codex panel).
if (-not [System.IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location).Path $OutFile }
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$bootUtc = $null
if (-not $FixtureProcesses) {
  try { $bootUtc = Format-CensusTime -Value (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
}

$total = 1
if ($Loop) { $total = $MaxSnapshots }

for ($i = 1; $i -le $total; $i++) {
  $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

  try {
    $procs = @(Get-CensusProcessTable)
  } catch {
    Write-Error "[agent-runtime-census] could not enumerate processes: $_"
    exit 1
  }

  # poolmon dump: keep the raw artifact next to the JSONL and point at it.
  $poolArtifact = $null
  $poolRows = [ordered]@{}
  if ($FixturePoolmon) {
    $poolArtifact = $FixturePoolmon
    $poolRows = Read-CensusPoolmon -Path $FixturePoolmon
  } elseif (-not $FixtureProcesses) {
    # Fixture mode stays hermetic even when only -FixtureProcesses is given:
    # never run the host's poolmon under a canned process table (codex panel).
    $pm = Find-CensusPoolmon
    if ($pm) {
      $pmDir = Join-Path $outDir 'poolmon'
      if (-not (Test-Path -LiteralPath $pmDir)) { New-Item -ItemType Directory -Path $pmDir -Force | Out-Null }
      # The pid keeps two collectors started in the same second from writing
      # the same dump file (codex panel).
      $dump = Join-Path $pmDir ('poolmon-' + ($ts -replace '[:-]', '') + '-' + $PID + '.txt')
      try {
        & $pm -n $dump 2>$null | Out-Null
        if (Test-Path -LiteralPath $dump) {
          $poolArtifact = $dump
          $poolRows = Read-CensusPoolmon -Path $dump
        }
      } catch { }
    }
  }

  $snapshot = [ordered]@{
    schema           = 'agent-runtime-census/1'
    ts_utc           = $ts
    label            = $Label
    host             = $env:COMPUTERNAME
    boot_utc         = $bootUtc
    supervisors      = @(Get-CensusSupervisors -Procs $procs)
    process_total    = $procs.Count
    families         = (Get-CensusFamilyCounts -Procs $procs)
    runtime          = (Get-CensusRuntimeTuple)
    memory           = (Get-CensusMemoryCounters)
    pool_tags        = $poolRows
    poolmon_artifact = $poolArtifact
  }

  # One compact line per snapshot, BOM-free (jq / node parse it directly).
  $line = ($snapshot | ConvertTo-Json -Depth 8 -Compress)
  [System.IO.File]::AppendAllText($OutFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))

  # --- human table ---
  Write-Host ("=== agent-runtime-census {0}  label={1}  host={2}  boot={3} ===" -f $ts, $(if ($Label) { $Label } else { '(none)' }), $snapshot.host, $(if ($bootUtc) { $bootUtc } else { 'n/a' }))
  Write-Host ("SUPERVISORS ({0}), processes total {1}" -f $snapshot.supervisors.Count, $procs.Count)
  foreach ($s in $snapshot.supervisors) {
    Write-Host ("  {0,-12} pid {1,-7} created {2}  ws {3,8:N1} MB  mcp-roots {4}  dup-groups {5}" -f `
      $s.exe, $s.pid, $(if ($s.created_utc) { $s.created_utc } else { 'n/a                 ' }), $s.working_set_mb, $s.mcp_root_count, $s.duplicate_groups.Count)
    foreach ($r in $s.mcp_roots) {
      Write-Host ("      root pid {0,-7} {1,-34} created {2}  ws {3,7:N1} MB  desc {4,3} ({5,7:N1} MB)" -f `
        $r.pid, $r.identity, $(if ($r.created_utc) { $r.created_utc } else { 'n/a' }), $r.working_set_mb, $r.descendants, $r.descendant_working_set_mb)
    }
    foreach ($d in $s.duplicate_groups) {
      Write-Host ("      DUPLICATE x{0}  {1}  pids {2}" -f $d.count, $d.identity, ($d.pids -join ','))
    }
  }
  $famLine = (@($snapshot.families.Keys | ForEach-Object { "$_=$($snapshot.families[$_])" }) -join ' ')
  Write-Host ("FAMILIES    {0}" -f $famLine)
  $rt = $snapshot.runtime
  Write-Host ("RUNTIME     node={0} npm={1} bun={2} bash={3}{4}" -f `
    $rt.node, $rt.npm, $rt.bun, $rt.bash_first, $(if ($rt.bash_is_wsl -eq $true) { '  [WSL-FIRST]' } else { '' }))
  $m = $snapshot.memory
  Write-Host ("MEMORY      nonpaged={0} paged={1} committed={2} limit={3} available={4}" -f `
    (Format-CensusMB $m.pool_nonpaged_bytes), (Format-CensusMB $m.pool_paged_bytes), (Format-CensusMB $m.committed_bytes), (Format-CensusMB $m.commit_limit_bytes), (Format-CensusMB $m.available_bytes))
  if ($poolRows.Count -gt 0) {
    Write-Host ("POOL        TAG   TYPE    OUTSTANDING          MB")
    foreach ($t in $script:TrackedPoolTags) {
      if (-not $poolRows.Contains($t)) { continue }
      Write-Host ("            {0,-5} {1,-6} {2,12:N0} {3,11:N1}" -f $t, $poolRows[$t].type, $poolRows[$t].outstanding, ($poolRows[$t].bytes / 1MB))
    }
  } elseif ($poolArtifact) {
    Write-Host ("POOL        (no tracked tag rows in the dump - it may be truncated or unreadable)")
  } elseif ($FixtureProcesses) {
    Write-Host ("POOL        (fixture mode without -FixturePoolmon - poolmon deliberately not run)")
  } else {
    Write-Host ("POOL        (poolmon.exe not found - install WDK/Windows Kits or set HIMMEL_POOLMON)")
  }
  Write-Host ("POOLMON     {0}" -f $(if ($poolArtifact) { $poolArtifact } else { 'n/a' }))
  Write-Host ("OUT         {0}" -f $OutFile)
  Write-Host ''

  if ($i -lt $total) { Start-Sleep -Seconds $IntervalSec }
}

exit 0
