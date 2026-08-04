# Hermetic tests for restart-bridge.ps1's server.ts attribution (HIMMEL-1309).
# Get-CimInstance is NOT mocked: the .ps1 exposes a pure classifier,
# Get-ServerTsAttribution, fed a synthetic parent lookup. We dot-source with
# -AsLibrary (defines the function, never touches the bridge) and assert the
# attribution for the exact topology that produced the 2026-07-27 misdiagnosis:
# 45 luna-correlate MCP servers reported as "rogue telegram-himmel children …
# live 2nd getUpdates consumer".
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'restart-bridge.ps1'
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

. $Helper -AsLibrary

function Rec($procId, $parentId, $cl) {
  [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $parentId; Name = 'bun.exe'; CommandLine = $cl }
}
function ByPid($procs) {
  $h = @{}
  foreach ($p in $procs) { $h[[string]$p.ProcessId] = $p }
  return $h
}

# Fixture command lines derive from the running user's profile dir (no literal
# home paths in source — the propagation leak scan fail-closes on them).
$UserHomeFwd = ($env:USERPROFILE) -replace '\\', '/'
$Cache = "$UserHomeFwd/.codex/plugins/cache/himmel"
$LUNA_LAUNCHER = "`"$UserHomeFwd/.bun/bin\bun.exe`" run --cwd $Cache/luna-correlate/0.2.0 --shell=bun --silent start"
$TELE_LAUNCHER = "`"$UserHomeFwd/.bun/bin\bun.exe`" run --cwd $Cache/telegram-himmel/0.0.6 --shell=bun --silent start"
$SERVER = 'bun.exe server.ts'

$table = @(
  (Rec 100 1   $LUNA_LAUNCHER)
  (Rec 101 100 $SERVER)          # luna-correlate MCP server -> codex-plugin
  (Rec 200 1   $TELE_LAUNCHER)
  (Rec 201 200 $SERVER)          # telegram-himmel MCP server -> telegram
  (Rec 301 999 $SERVER)          # launcher pid 999 absent -> unattributable
  (Rec 400 1   $null)
  (Rec 401 400 $SERVER)          # launcher cmdline unreadable -> unattributable
)
$map = ByPid $table

Write-Host "Test 1: the 2026-07-27 misdiagnosis — a luna-correlate MCP server is NOT telegram"
Check 'luna-correlate server.ts attributes to codex-plugin' `
  ((Get-ServerTsAttribution -Proc $table[1] -ByPid $map) -eq 'codex-plugin') `
  "got=$(Get-ServerTsAttribution -Proc $table[1] -ByPid $map)"

Write-Host "Test 2: a real telegram-himmel child IS still attributed to telegram"
Check 'telegram-himmel server.ts attributes to telegram' `
  ((Get-ServerTsAttribution -Proc $table[3] -ByPid $map) -eq 'telegram')

Write-Host "Test 3: an unreadable launcher is 'unattributable', never a telegram claim"
Check 'dead launcher -> unattributable'      ((Get-ServerTsAttribution -Proc $table[4] -ByPid $map) -eq 'unattributable')
Check 'blind launcher cmdline -> unattributable' ((Get-ServerTsAttribution -Proc $table[6] -ByPid $map) -eq 'unattributable')

Write-Host "Test 4: --cwd is read in every spelling the live table actually uses"
foreach ($case in @(
    @{ n = 'backslash separators'; cl = "bun run --cwd $($Cache -replace '/', '\')\telegram-himmel\0.0.6 start"; want = 'telegram' },
    @{ n = 'quoted path with a space'; cl = "bun run --cwd `"C:/a b/.codex/plugins/cache/himmel/telegram-himmel/0.0.6`" start"; want = 'telegram' },
    @{ n = '--cwd=<path> form'; cl = "bun run --cwd=$Cache/luna-correlate/0.2.0 start"; want = 'codex-plugin' },
    @{ n = 'other plugin, telegram nowhere in it'; cl = "bun run --cwd $Cache/qmd/1.0.0 start"; want = 'codex-plugin' }
  )) {
  $t = @((Rec 10 1 $case.cl), (Rec 11 10 $SERVER))
  Check "$($case.n) -> $($case.want)" ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq $case.want) `
    "got=$(Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t))"
}

Write-Host "Test 5: a plugin merely NAMED like telegram-himmel does not borrow its identity"
$t = @((Rec 20 1 "bun run --cwd $Cache/telegram-himmel-fork/0.0.1 start"), (Rec 21 20 $SERVER))
Check 'telegram-himmel-fork attributes to codex-plugin, not telegram' `
  ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'codex-plugin') `
  "got=$(Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t))"

Write-Host "Test 6: a launcher with no --cwd still attributes by its plugin lineage"
$t = @((Rec 30 1 'bun run telegram-himmel start'), (Rec 31 30 $SERVER))
Check 'bare telegram-himmel mention -> telegram' ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'telegram')
$t = @((Rec 40 1 "bun $UserHomeFwd/.codex/plugins/cache/himmel/other/1.0.0/index.ts"), (Rec 41 40 $SERVER))
Check 'bare .codex plugin-cache path -> codex-plugin' ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'codex-plugin')
$t = @((Rec 50 1 'bun some-unrelated-thing.ts'), (Rec 51 50 $SERVER))
Check 'an unrelated bun parent -> unattributable (never a telegram claim)' `
  ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'unattributable')

Write-Host "Test 7 (HIMMEL-1510): -FromLedger pid validation — refusal cases"
$ledgerWrittenAt = [datetime]::new(2026, 8, 4, 12, 0, 0, [DateTimeKind]::Utc)
$bridgeStartedAt = $ledgerWrittenAt.AddSeconds(-5)
$recycledStartedAt = $ledgerWrittenAt.AddSeconds(5)
$byPid = @{}
# The live bridge's command lines are this bare: no path or --cwd marker.
$byPid['100'] = [pscustomobject]@{ ProcessId = 100; Name = 'bun.exe'; CommandLine = 'bun  supervisor.ts'; CreationDate = $bridgeStartedAt }
$byPid['101'] = [pscustomobject]@{ ProcessId = 101; Name = 'bun.exe'; CommandLine = 'bun poller.ts'; CreationDate = $bridgeStartedAt }
$byPid['102'] = [pscustomobject]@{ ProcessId = 102; Name = 'bun.exe'; CommandLine = 'bun supervisor.ts'; CreationDate = $recycledStartedAt } # same filename outside the bridge, after stale ledger write
$byPid['103'] = [pscustomobject]@{ ProcessId = 103; Name = 'bun.exe'; CommandLine = 'bun poller.ts'; CreationDate = $recycledStartedAt }     # same filename outside the bridge, after stale ledger write
$byPid['200'] = [pscustomobject]@{ ProcessId = 200; Name = 'notepad.exe'; CommandLine = 'notepad C:/tmp/foo.txt'; CreationDate = $recycledStartedAt }
$byPid['300'] = [pscustomobject]@{ ProcessId = 300; Name = 'bun.exe'; CommandLine = 'bun run some-unrelated-script.ts'; CreationDate = $bridgeStartedAt }
Check 'genuine live shape: bare supervisor.ts predating ledger -> validated' (Test-LedgerPidValid -Pid_ 100 -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid)
Check 'genuine live shape: bare poller.ts predating ledger -> validated' (Test-LedgerPidValid -Pid_ 101 -Role poller -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid)
Check 'recycled bun pid running supervisor.ts outside bridge -> refused' (-not (Test-LedgerPidValid -Pid_ 102 -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'recycled bun pid running poller.ts outside bridge -> refused' (-not (Test-LedgerPidValid -Pid_ 103 -Role poller -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'ledger role must match the exact bridge entrypoint' (-not (Test-LedgerPidValid -Pid_ 101 -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'recycled pid now owned by an unrelated process.exe -> refused' (-not (Test-LedgerPidValid -Pid_ 200 -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'bun.exe pid that is NOT the bridge -> refused' (-not (Test-LedgerPidValid -Pid_ 300 -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'pid=0 -> refused (never a broad-kill fallthrough)' (-not (Test-LedgerPidValid -Pid_ 0 -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'pid=$null (missing ledger key) -> refused' (-not (Test-LedgerPidValid -Pid_ $null -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'non-numeric pid -> refused' (-not (Test-LedgerPidValid -Pid_ 'not-a-pid' -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'negative pid -> refused' (-not (Test-LedgerPidValid -Pid_ (-5) -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))
Check 'pid absent from the live snapshot (already dead) -> refused' (-not (Test-LedgerPidValid -Pid_ 999999 -Role supervisor -LedgerLastWriteTime $ledgerWrittenAt -ByPid $byPid))

Write-Host "Test 8 (HIMMEL-1510): rotated-log naming is deterministic and collision-free"
$rotatedNow = [datetime]::new(2026, 8, 3, 22, 32, 0).AddTicks(1234567)
$rotatedPath = Get-RotatedLogPath -LogPath 'C:/logs/supervisor.log' -Now $rotatedNow
$rotatedPathLater = Get-RotatedLogPath -LogPath 'C:/logs/supervisor.log' -Now $rotatedNow.AddTicks(1)
Check 'rotated path carries base + fractional timestamp + extension' (($rotatedPath -replace '\\', '/') -eq 'C:/logs/supervisor.20260803-223200-1234567.log') "got=$rotatedPath"
Check 'two rotations within one second do not target the same path' ($rotatedPathLater -ne $rotatedPath)

Write-Host "Test 9 (HIMMEL-1510): offset-age computation, pure"
$base = [datetime]::new(2026, 8, 3, 12, 0, 0)
Check 'age in seconds, simple forward delta' ((Get-OffsetAgeSeconds -LastWriteTime $base -Now $base.AddSeconds(90)) -eq 90)
Check 'age clamps to 0, never negative (Now before LastWriteTime)' ((Get-OffsetAgeSeconds -LastWriteTime $base -Now $base.AddSeconds(-5)) -eq 0)

Write-Host "Test 10 (HIMMEL-1510): watchdog requires stale/unknown offset AND no recent poll heartbeat"
$watchdogNow = [datetime]::new(2026, 8, 3, 22, 32, 0, [DateTimeKind]::Utc)
Check 'quiet-but-healthy bridge with stale offset and recent heartbeat -> NOT wedged' `
  (-not (Test-BridgeStale -ProcessCount 1 -OffsetAgeSeconds 1900 -HeartbeatTime $watchdogNow.AddSeconds(-30) -Now $watchdogNow -ThresholdSeconds 1800))
Check 'stale offset and no heartbeat -> wedged' `
  (Test-BridgeStale -ProcessCount 1 -OffsetAgeSeconds 1900 -HeartbeatTime $null -Now $watchdogNow -ThresholdSeconds 1800)
Check 'missing/unreadable offset and no heartbeat -> wedged, never blind OK' `
  (Test-BridgeStale -ProcessCount 1 -OffsetAgeSeconds $null -HeartbeatTime $null -Now $watchdogNow -ThresholdSeconds 1800)
Check 'missing offset but recent heartbeat -> NOT wedged' `
  (-not (Test-BridgeStale -ProcessCount 1 -OffsetAgeSeconds $null -HeartbeatTime $watchdogNow.AddSeconds(-30) -Now $watchdogNow -ThresholdSeconds 1800))
Check 'stale offset and stale heartbeat -> wedged' `
  (Test-BridgeStale -ProcessCount 1 -OffsetAgeSeconds 1900 -HeartbeatTime $watchdogNow.AddSeconds(-1900) -Now $watchdogNow -ThresholdSeconds 1800)

Write-Host "Test 11 (HIMMEL-1510): the CRITICAL verify fix — real progress, not mere process existence"
$restartedAt = [datetime]::new(2026, 8, 3, 22, 32, 0, [DateTimeKind]::Utc)
Check 'offset mtime moved forward at/after the UTC restart -> progressed' `
  (Test-BridgeProgressed -OffsetMTimeBefore $base -OffsetMTimeAfter $restartedAt.AddSeconds(5) -HeartbeatAfter $null -RestartedAt $restartedAt)
Check 'offset write after the before-snapshot but before RestartedAt -> NOT progressed' `
  (-not (Test-BridgeProgressed -OffsetMTimeBefore $base -OffsetMTimeAfter $restartedAt.AddSeconds(-1) -HeartbeatAfter $null -RestartedAt $restartedAt))
Check 'offset unchanged, but a heartbeat logged AT/AFTER the restart -> progressed' `
  (Test-BridgeProgressed -OffsetMTimeBefore $base -OffsetMTimeAfter $base -HeartbeatAfter $restartedAt.AddSeconds(3) -RestartedAt $restartedAt)
Check 'the 2026-08-03 wedge shape: offset unchanged, no heartbeat -> NOT progressed (this is the bug the CRITICAL fix closes)' `
  (-not (Test-BridgeProgressed -OffsetMTimeBefore $base -OffsetMTimeAfter $base -HeartbeatAfter $null -RestartedAt $restartedAt))
Check 'a STALE heartbeat from before the restart does not count' `
  (-not (Test-BridgeProgressed -OffsetMTimeBefore $base -OffsetMTimeAfter $base -HeartbeatAfter $restartedAt.AddSeconds(-10) -RestartedAt $restartedAt))
Check 'no prior offset file (first run) + a fresh post-restart offset appearing -> progressed' `
  (Test-BridgeProgressed -OffsetMTimeBefore $null -OffsetMTimeAfter $restartedAt.AddSeconds(1) -HeartbeatAfter $null -RestartedAt $restartedAt)
Check 'no prior offset, still no offset, no heartbeat -> NOT progressed' `
  (-not (Test-BridgeProgressed -OffsetMTimeBefore $null -OffsetMTimeAfter $null -HeartbeatAfter $null -RestartedAt $restartedAt))

Write-Host "Test 12 (HIMMEL-1510): Windows PowerShell 5.1 UTF-8 BOM contract"
$helperBytes = [System.IO.File]::ReadAllBytes($Helper)
$selfBytes = [System.IO.File]::ReadAllBytes($MyInvocation.MyCommand.Path)
Check 'restart-bridge.ps1 keeps UTF-8 BOM' (($helperBytes[0] -eq 0xEF) -and ($helperBytes[1] -eq 0xBB) -and ($helperBytes[2] -eq 0xBF))
Check 'test-restart-bridge.ps1 keeps UTF-8 BOM' (($selfBytes[0] -eq 0xEF) -and ($selfBytes[1] -eq 0xBB) -and ($selfBytes[2] -eq 0xBF))

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
