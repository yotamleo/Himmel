# Hermetic fixture tests for host-detectors.ps1 (HIMMEL-923).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'host-detectors.ps1'
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

. $Helper -AsLibrary

function Rec($procId, $parentId, $name, $cl, $rss, $created = $null) {
  [pscustomobject]@{
    ProcessId       = $procId
    ParentProcessId = $parentId
    Name            = $name
    CommandLine     = $cl
    WorkingSetSize  = $rss
    CreationDate    = $created
  }
}

function Job($codexPid, $startedAt = $null) {
  [pscustomobject]@{ CodexPid = $codexPid; StartedAt = $startedAt }
}

function ByClass($rows, $class) {
  return ($rows | Where-Object { $_.class -eq $class } | Select-Object -First 1)
}

$now = Get-Date
$startedEpoch = [long][DateTimeOffset]::new($now.ToUniversalTime()).ToUnixTimeSeconds()
$afterStart = $now.AddSeconds(10)
$beforeStart = $now.AddMinutes(-30)

Write-Host "Test 1: RAM tree classes sum root + descendants, with pid-reuse guard and other residual"
$treeProcs = @(
  (Rec 10  1  'claude.exe' 'claude.exe' 1000 $now)
  (Rec 11  10 'node.exe'   'node child.js' 200 $now)

  (Rec 20  1  'node.exe' 'node qmd-mcp-server.js' 300 $now)
  (Rec 21  20 'node.exe' 'node helper.js' 50 $now)

  (Rec 30  1  'codex.exe' 'codex exec run' 400 $afterStart)
  (Rec 31  30 'node.exe'  'node mcp-server.js' 90 $afterStart)
  (Rec 32  30 'node.exe'  'node old-reused.js' 70 $beforeStart)

  (Rec 40  1  'codex.exe' 'codex.exe app-server' 800 $now)
  (Rec 41  40 'bun.exe'   'bun server.ts' 20 $now)

  (Rec 90  1  'notepad.exe' 'notepad.exe' 5 $now)
)
$tree = @(Get-AgentTreeRows -Procs $treeProcs -Jobs @((Job 30 $startedEpoch)))
$claude = ByClass $tree 'claude'
$mcp = ByClass $tree 'mcp-standalone'
$exec = ByClass $tree 'codex-exec'
$app = ByClass $tree 'codex-app-server'
$other = ByClass $tree 'other'
Check 'claude tree rss/processes = 1200/2' ($claude.rss_bytes -eq 1200 -and $claude.process_count -eq 2) "rss=$($claude.rss_bytes) count=$($claude.process_count)"
Check 'mcp-standalone tree rss/processes = 350/2' ($mcp.rss_bytes -eq 350 -and $mcp.process_count -eq 2) "rss=$($mcp.rss_bytes) count=$($mcp.process_count)"
Check 'codex-exec excludes pre-start reused descendant' ($exec.rss_bytes -eq 490 -and $exec.process_count -eq 2) "rss=$($exec.rss_bytes) count=$($exec.process_count)"
Check 'codex app-server includes server child' ($app.rss_bytes -eq 820 -and $app.process_count -eq 2) "rss=$($app.rss_bytes) count=$($app.process_count)"
Check 'other residual includes unmatched + reused descendant' ($other.rss_bytes -eq 75 -and $other.process_count -eq 2) "rss=$($other.rss_bytes) count=$($other.process_count)"

Write-Host "Test 2: orphan classes use library lineage predicates and registry descendant walk"
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = 'C:\Users\fixture' }
$UserHomeFwd = $UserHome -replace '\\', '/'
$CODEX_RUNTIME = "$UserHome\AppData\Local\OpenAI\Codex\runtimes\cua_node\1b23c930\bin\node_repl.exe"
$BUN_LUNA = "run --cwd $UserHomeFwd/.codex/plugins/cache/himmel/luna-correlate/0.2.0 --shell=bun --silent start"
$orphanProcs = @(
  (Rec 201 200 'node_repl.exe' $CODEX_RUNTIME 1 $now)
  (Rec 202 200 'bun.exe' "bun $BUN_LUNA" 1 $now)
  (Rec 203 202 'bun.exe' 'bun server.ts' 1 $now)

  (Rec 501 500 'cmd.exe'  'cmd.exe /c npx @upstash/context7-mcp' 1 $now)
  (Rec 502 501 'node.exe' 'node C:\x\npx-cli.js @upstash/context7-mcp' 1 $now)

  (Rec 601 600 'codex.exe' 'codex.exe app-server' 1 $now)
  (Rec 701 700 'python.exe' 'python -m hermes_cli gateway' 1 $now)
  (Rec 801 800 'node.exe' 'node qmd-mcp-server.js' 1 $now)
)
$orphans = @(Get-OrphanRows -Procs $orphanProcs -Jobs @((Job 500 $startedEpoch)))
Check 'codex-fleet count = 3' ((ByClass $orphans 'codex-fleet').count -eq 3) "got=$((ByClass $orphans 'codex-fleet').count)"
Check 'codex-exec-registry descendant process count = 2' ((ByClass $orphans 'codex-exec-registry').count -eq 2) "got=$((ByClass $orphans 'codex-exec-registry').count)"
Check 'codex app-server orphan count = 1' ((ByClass $orphans 'codex-app-server-orphan').count -eq 1)
Check 'hermes gateway orphan count = 1' ((ByClass $orphans 'hermes-gateway-orphan').count -eq 1)
Check 'unattributed dead-parent MCP excludes attributed registry/fleet descendants' ((ByClass $orphans 'mcp-dead-parent-unattributed').count -eq 1) "got=$((ByClass $orphans 'mcp-dead-parent-unattributed').count)"

Write-Host "Test 3: Invoke-HostDetectorSnapshot returns the exporter JSON shape"
$snapshot = Invoke-HostDetectorSnapshot -Procs $treeProcs -Jobs @((Job 30 $startedEpoch))
$json = $snapshot | ConvertTo-Json -Compress -Depth 6
$roundTrip = $json | ConvertFrom-Json
Check 'snapshot has trees array' ($roundTrip.trees.Count -ge 7)
Check 'snapshot has orphans array' ($roundTrip.orphans.Count -ge 5)

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
