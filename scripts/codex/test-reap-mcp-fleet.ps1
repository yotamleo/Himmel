# Hermetic tests for reap-mcp-fleet.ps1 (HIMMEL-741).
# Get-CimInstance is NOT mocked: the .ps1 exposes a pure filter, Get-OrphanFleet,
# that takes a synthetic process-records array. We dot-source the script with
# -AsLibrary (defines functions, skips the live scan) and assert the orphan set
# for a hand-built topology that mirrors the real machine grounding.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'reap-mcp-fleet.ps1'
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

# Load the functions without running the production scan.
. $Helper -AsLibrary

function Rec($procId, $parentId, $name, $cl) {
  [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $parentId; Name = $name; CommandLine = $cl }
}

# Fixture command lines derive from the running user's profile dir (no literal
# home paths in source — the propagation leak scan fail-closes on them). The
# reaper's ownership predicates match username-independent fragments
# (OpenAI\Codex\runtimes, .codex\plugins\cache), so any profile root works.
$UserHome = $env:USERPROFILE
$UserHomeFwd = $UserHome -replace '\\', '/'
$CODEX_RUNTIME = "$UserHome\AppData\Local\OpenAI\Codex\runtimes\cua_node\1b23c930\bin\node_repl.exe"
$BUN_LUNA = "run --cwd $UserHomeFwd/.codex/plugins/cache/himmel/luna-correlate/0.2.0 --shell=bun --silent start"
$BROKER   = "node $UserHome\.claude\plugins\cache\openai-codex\codex\1.0.5\scripts\app-server-broker.mjs serve"

# --- topology ----------------------------------------------------------------
$procs = @(
  # LIVE fleet under a live app-server (which the live broker owns).
  (Rec 90  1   'node.exe'      $BROKER)                                   # broker (supervisor, live)
  (Rec 100 90  'codex.exe'     'codex.exe app-server')                    # app-server (supervisor, live)
  (Rec 101 100 'node_repl.exe' $CODEX_RUNTIME)                            # live fleet child -> NOT orphan
  (Rec 102 100 'uvx.exe'       "`"$UserHomeFwd/.local/bin/uvx.exe`" mcp-obsidian") # live fleet child -> NOT orphan

  # ORPHANED fleet: app-server pid 200 is DEAD (absent from the table).
  (Rec 201 200 'node_repl.exe' $CODEX_RUNTIME)                            # codex-owned, parent gone -> ORPHAN
  (Rec 202 200 'bun.exe'       "bun $BUN_LUNA")                           # codex-owned, parent gone -> ORPHAN
  (Rec 203 202 'bun.exe'       'bun server.ts')                           # under codex 202 -> ORPHAN

  # Non-codex MCP servers (Claude-launched) must be untouched.
  (Rec 301 1   'node.exe'      'node claude cli')                         # not a supervisor by our narrow def
  (Rec 300 301 'node.exe'      '"node" @playwright/mcp/cli.js')           # not codex-owned -> NOT orphan

  # Safe under-reap: bun server.ts whose codex launcher parent (211) is ALSO gone.
  (Rec 210 211 'bun.exe'       'bun server.ts')                           # no marker, parent gone -> NOT orphan

  # Kill-safety: codex-owned proc with a FULLY-LIVE chain rooting at PID 0 and
  # no recognized supervisor in it (e.g. launched under an unrecognized
  # supervisor variant). No dead link -> NOT orphan, never reaped.
  (Rec 401 0   'pwsh.exe'      'pwsh -NoProfile -File dev-driver.ps1')    # live non-supervisor root
  (Rec 400 401 'node.exe'      $CODEX_RUNTIME)                            # codex-owned, live chain -> NOT orphan
)

$orphans = @(Get-OrphanFleet -Procs $procs)
$got = @($orphans | ForEach-Object { $_.ProcessId } | Sort-Object)
$want = @(201, 202, 203)

Write-Host "Test 1: exact orphan set = dead-app-server fleet + its server.ts descendant"
Check 'orphan set is {201,202,203}' (($got -join ',') -eq ($want -join ',')) "got=$($got -join ',')"

Write-Host "Test 2: live fleet + supervisors + non-codex + under-reap are all excluded"
Check 'live node_repl 101 excluded'      (-not ($got -contains 101))
Check 'live uvx 102 excluded'            (-not ($got -contains 102))
Check 'app-server 100 never reaped'      (-not ($got -contains 100))
Check 'broker 90 never reaped'           (-not ($got -contains 90))
Check 'non-codex playwright 300 excluded' (-not ($got -contains 300))
Check 'orphan-parent server.ts 210 excluded (safe under-reap)' (-not ($got -contains 210))

Write-Host "Test 3: DeadAncestorPid annotation points at the vanished app-server"
$o201 = $orphans | Where-Object { $_.ProcessId -eq 201 }
Check 'node_repl 201 dead ancestor = 200' ($o201.DeadAncestorPid -eq 200) "got=$($o201.DeadAncestorPid)"

Write-Host "Test 4: empty input yields no orphans (no throw)"
$empty = @(Get-OrphanFleet -Procs @())
Check 'empty input -> 0 orphans' ($empty.Count -eq 0)

Write-Host "Test 5: predicates classify the grounded fingerprints"
Check 'node_repl is codex-owned'   (Test-CodexOwned -Proc (Rec 1 0 'node_repl.exe' $CODEX_RUNTIME))
Check '.codex plugin cache bun is codex-owned' (Test-CodexOwned -Proc (Rec 1 0 'bun.exe' "bun $BUN_LUNA"))
Check 'bare uvx mcp-obsidian NOT codex-owned'  (-not (Test-CodexOwned -Proc (Rec 1 0 'uvx.exe' 'uvx mcp-obsidian')))
Check 'codex.exe is a supervisor'  (Test-FleetSupervisor -Proc (Rec 1 0 'codex.exe' 'codex.exe app-server'))
Check 'broker.mjs is a supervisor' (Test-FleetSupervisor -Proc (Rec 1 0 'node.exe' $BROKER))
Check 'playwright node NOT a supervisor' (-not (Test-FleetSupervisor -Proc (Rec 1 0 'node.exe' '"node" @playwright/mcp/cli.js')))

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
