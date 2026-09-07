# Hermetic tests for restart-bridge.ps1's server.ts attribution (HIMMEL-1309).
# Get-CimInstance is NOT mocked: the .ps1 exposes a pure classifier,
# Get-ServerTsAttribution, fed a synthetic parent lookup. We dot-source with
# -AsLibrary (defines the function, never touches the bridge) and assert the
# attribution for the exact topology that produced the 2026-07-27 misdiagnosis:
# 45 luna-correlate MCP servers reported as "rogue telegram-himmel children …
# live 2nd getUpdates consumer".
$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
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

Write-Host "Test 8 (HIMMEL-1510/1520): rotated-log naming is deterministic and collision-free"
$rotatedNow = [datetime]::new(2026, 8, 3, 22, 32, 0).AddTicks(1234567)
$rotatedPath = Get-RotatedLogPath -LogPath 'C:/logs/supervisor.log' -Now $rotatedNow
$rotatedPathLater = Get-RotatedLogPath -LogPath 'C:/logs/supervisor.log' -Now $rotatedNow.AddTicks(1)
Check 'rotated path carries base + fractional timestamp + extension' (($rotatedPath -replace '\\', '/') -eq 'C:/logs/supervisor.20260803-223200-1234567.log') "got=$rotatedPath"
Check 'two rotations within one second do not target the same path' ($rotatedPathLater -ne $rotatedPath)
# HIMMEL-1520 #2: the sibling .err is rotated in lockstep with $log, and its
# rotated name must never collide with a .log rotation (the prune filters
# `supervisor.*.log` and `supervisor.log.*.err` are disjoint).
$rotatedErrPath = Get-RotatedLogPath -LogPath 'C:/logs/supervisor.log.err' -Now $rotatedNow
Check 'err rotated path carries base + fractional timestamp + .err extension' (($rotatedErrPath -replace '\\', '/') -eq 'C:/logs/supervisor.log.20260803-223200-1234567.err') "got=$rotatedErrPath"
Check 'err rotated path never collides with the .log rotated path' ($rotatedErrPath -ne $rotatedPath)

Write-Host "Test 9 (HIMMEL-1510): offset-age computation, pure"
$base = [datetime]::new(2026, 8, 3, 12, 0, 0)
Check 'age in seconds, simple forward delta' ((Get-OffsetAgeSeconds -LastWriteTime $base -Now $base.AddSeconds(90)) -eq 90)
Check 'age clamps to 0, never negative (Now before LastWriteTime)' ((Get-OffsetAgeSeconds -LastWriteTime $base -Now $base.AddSeconds(-5)) -eq 0)

Write-Host "Test 10 (HIMMEL-1510/1520): watchdog state — DOWN / STALE / OK are three distinct answers"
$watchdogNow = [datetime]::new(2026, 8, 3, 22, 32, 0, [DateTimeKind]::Utc)
Check 'quiet-but-healthy bridge with stale offset and recent heartbeat -> OK' `
  ((Get-BridgeWatchdogState -ProcessCount 1 -OffsetAgeSeconds 1900 -HeartbeatTime $watchdogNow.AddSeconds(-30) -Now $watchdogNow -ThresholdSeconds 1800) -eq 'OK')
Check 'stale offset and no heartbeat -> STALE' `
  ((Get-BridgeWatchdogState -ProcessCount 1 -OffsetAgeSeconds 1900 -HeartbeatTime $null -Now $watchdogNow -ThresholdSeconds 1800) -eq 'STALE')
Check 'missing/unreadable offset and no heartbeat -> STALE, never blind OK' `
  ((Get-BridgeWatchdogState -ProcessCount 1 -OffsetAgeSeconds $null -HeartbeatTime $null -Now $watchdogNow -ThresholdSeconds 1800) -eq 'STALE')
Check 'missing offset but recent heartbeat -> OK' `
  ((Get-BridgeWatchdogState -ProcessCount 1 -OffsetAgeSeconds $null -HeartbeatTime $watchdogNow.AddSeconds(-30) -Now $watchdogNow -ThresholdSeconds 1800) -eq 'OK')
Check 'stale offset and stale heartbeat -> STALE' `
  ((Get-BridgeWatchdogState -ProcessCount 1 -OffsetAgeSeconds 1900 -HeartbeatTime $watchdogNow.AddSeconds(-1900) -Now $watchdogNow -ThresholdSeconds 1800) -eq 'STALE')
Check 'zero bridge procs -> DOWN (HIMMEL-1520: a dead bridge was reported OK here before)' `
  ((Get-BridgeWatchdogState -ProcessCount 0 -OffsetAgeSeconds $null -HeartbeatTime $null -Now $watchdogNow -ThresholdSeconds 1800) -eq 'DOWN')
Check 'DOWN beats staleness: zero procs with a fresh offset + heartbeat is still DOWN' `
  ((Get-BridgeWatchdogState -ProcessCount 0 -OffsetAgeSeconds 5 -HeartbeatTime $watchdogNow.AddSeconds(-5) -Now $watchdogNow -ThresholdSeconds 1800) -eq 'DOWN')
# HIMMEL-1519 CR r2: the DOWN path is only reachable if the set-splitter accepts
# an EMPTY process list. A Mandatory [object[]] refuses an empty array at
# parameter binding, so without AllowEmptyCollection a fully-crashed bridge
# (zero bun.exe) died with a binding error instead of reporting DOWN -- the
# exact case this state exists for.
$emptySets = $null
$emptyBindErr = $null
try { $emptySets = Get-BridgeProcSets -Processes @() } catch { $emptyBindErr = "$_" }
Check 'zero bun processes bind without a parameter-binding error' ($null -eq $emptyBindErr)
Check 'zero bun processes yield an empty core set' (@($emptySets.Core).Count -eq 0)
Check 'zero bun processes yield an empty union' (@($emptySets.All).Count -eq 0)

Write-Host "Test 11 (HIMMEL-1520): rogue plugin processes are conflicts, not core liveness"
$rogueOnly = @(
  (Rec 600 1 $TELE_LAUNCHER)
  (Rec 601 600 $SERVER)
)
$rogueSets = Get-BridgeProcSets -Processes $rogueOnly
Check 'rogue launcher + child remain in the bridge remediation union' (@($rogueSets.All).Count -eq 2) "got=$(@($rogueSets.All).Count)"
Check 'rogue launcher + child contribute zero core processes' (@($rogueSets.Core).Count -eq 0) "got=$(@($rogueSets.Core).Count)"
Check 'rogue-only topology with fresh offset + heartbeat -> DOWN' `
  ((Get-BridgeWatchdogState -ProcessCount @($rogueSets.Core).Count -OffsetAgeSeconds 5 -HeartbeatTime $watchdogNow.AddSeconds(-5) -Now $watchdogNow -ThresholdSeconds 1800) -eq 'DOWN')

Write-Host "Test 12 (HIMMEL-1510): the CRITICAL verify fix — real progress, not mere process existence"
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

Write-Host "Test 13 (HIMMEL-1519): core-bridge matcher keys on entrypoint name, not a scripts/telegram path"
# Genuine bridge command lines carry NO path (the live table and this script's
# own `bun supervisor.ts > log 2>&1` launch both look like this).
Check 'bare bun supervisor.ts -> core bridge'            (Test-BridgeCoreProc -CommandLine 'bun supervisor.ts')
Check 'bare bun poller.ts -> core bridge'                (Test-BridgeCoreProc -CommandLine 'bun poller.ts')
Check 'double-spaced bun supervisor.ts -> core bridge'   (Test-BridgeCoreProc -CommandLine 'bun  supervisor.ts')
Check 'path-prefixed supervisor.ts still matches -> core' (Test-BridgeCoreProc -CommandLine 'bun C:/repo/scripts/telegram/supervisor.ts')
Check 'supervisor.ts with a redirect tail -> core bridge' (Test-BridgeCoreProc -CommandLine 'bun supervisor.ts > "C:/log" 2>&1')
# The over-reap the fix closes: the lane dispatchers DO live under scripts/telegram.
Check 'lane dispatcher spawn-claudex.ts under scripts/telegram -> NOT core' (-not (Test-BridgeCoreProc -CommandLine 'bun C:/repo/scripts/telegram/spawn-claudex.ts --ticket X'))
Check 'lane dispatcher spawn-glm.ts under scripts/telegram -> NOT core'      (-not (Test-BridgeCoreProc -CommandLine 'bun scripts\telegram\spawn-glm.ts'))
Check 'unrelated bun server.ts -> NOT core'               (-not (Test-BridgeCoreProc -CommandLine 'bun server.ts'))
Check 'unrelated bun script -> NOT core'                  (-not (Test-BridgeCoreProc -CommandLine 'bun run some-unrelated-script.ts'))
# Token anchors reject substrings (no false positives — no over-reap the other way).
Check 'mysupervisor.ts (no leading boundary) -> NOT core' (-not (Test-BridgeCoreProc -CommandLine 'bun mysupervisor.ts'))
Check 'supervisor.ts.bak (trailing chars) -> NOT core'    (-not (Test-BridgeCoreProc -CommandLine 'bun supervisor.ts.bak'))

Write-Host "Test 14 (HIMMEL-1520): ledger kill failures and survivors fail closed"
$validatedEntries = @([pscustomobject]@{ label = 'poller'; pid = 700 })
$failedStops = @(Invoke-ValidatedBridgeStops -Entries $validatedEntries -StopAction { param($ProcessId) throw "access denied for $ProcessId" })
Check 'Stop-Process throw is returned as a fatal relaunch blocker' `
  (($failedStops.Count -eq 1) -and ($failedStops[0].pid -eq 700) -and ($failedStops[0].error -match 'access denied'))
Check 'Stop-Process failure means relaunch is unsafe' `
  (-not (Test-BridgeRelaunchSafe -StopFailures $failedStops -Survivors @()))
$validatedSurvivor = @([pscustomobject]@{ ProcessId = 700 })
Check 'validated pid still alive after the wait means relaunch is unsafe' `
  (-not (Test-BridgeRelaunchSafe -StopFailures @() -Survivors $validatedSurvivor))
Check 'no stop failure and no surviving bridge process means relaunch is safe' `
  (Test-BridgeRelaunchSafe -StopFailures @() -Survivors @())

Write-Host "Test 15 (HIMMEL-1520): empty BRIDGE_ROOT fails clearly at invocation level"
$pwshPath = (Get-Process -Id $PID).Path
$repoRoot = (Resolve-Path (Join-Path $ScriptDir '../..')).Path
$hadBridgeRoot = Test-Path Env:BRIDGE_ROOT
$oldBridgeRoot = $env:BRIDGE_ROOT
try {
  $env:BRIDGE_ROOT = ''
  $emptyRootOutput = @(& $pwshPath -NoProfile -ExecutionPolicy Bypass -File $Helper -Repo $repoRoot -StatusOnly 2>&1)
  $emptyRootExit = $LASTEXITCODE
} finally {
  if ($hadBridgeRoot) { $env:BRIDGE_ROOT = $oldBridgeRoot } else { Remove-Item Env:BRIDGE_ROOT -ErrorAction SilentlyContinue }
}
$emptyRootText = $emptyRootOutput -join "`n"
Check 'empty BRIDGE_ROOT exits 1' ($emptyRootExit -eq 1) "exit=$emptyRootExit output=$emptyRootText"
Check 'empty BRIDGE_ROOT names the variable and remediation' `
  (($emptyRootText -match 'BRIDGE_ROOT is set to an empty value') -and ($emptyRootText -match 'Unset BRIDGE_ROOT')) `
  "output=$emptyRootText"
Check 'empty BRIDGE_ROOT never leaks the obscure Join-Path binding error' `
  (-not ($emptyRootText -match "Cannot bind argument to parameter 'Path'")) `
  "output=$emptyRootText"

Write-Host "Test 16 (HIMMEL-1519): zero validated ledger pids no longer always refuses -- DOWN vs stale-ledger fork"
# The defect: -Watchdog -Kill routes into -FromLedger -Kill, which validates
# ledger pids via Test-LedgerPidValid. In the DOWN state (HIMMEL-1520) there
# are zero live bridge processes by definition, so neither pid can EVER
# validate -- the old unconditional refusal made a crashed bridge
# un-remediable via this verb. Test-FromLedgerZeroValidatedProceed is the
# exact fork the fixed script calls at that decision point.
# AllBunProbeAction is pinned to an empty set here (never the live default) --
# these two checks are about the bridge-proc survivor logic only, not the
# round-2 orphan-scan widening (that gets its own tests below), and a real
# Get-CimInstance call would make this depend on whatever bun.exe happens to be
# running on the machine executing the suite.
Check 'zero validated pids + zero live bridge processes (DOWN) -> may proceed to relaunch' `
  (Test-FromLedgerZeroValidatedProceed -ProbeAction { @() } -AllBunProbeAction { @() })
Check 'zero validated pids + a live unaccounted bridge process -> still refuses (the guard this fix must NOT delete)' `
  (-not (Test-FromLedgerZeroValidatedProceed -ProbeAction { @([pscustomobject]@{ ProcessId = 12345 }) } -AllBunProbeAction { @() }))

Write-Host "Test 17 (HIMMEL-1519): relaunch dispatch -- scheduled task preferred, cmd /c fallback otherwise"
# Proves the seam the DOWN case now falls through to actually fires, and that
# it fires the RIGHT one, via injected actions -- never a real scheduled task
# or process launch in the test.
$taskCalls = 0; $cmdCalls = 0; $cmdSeen = $null
$dispatchWithTask = Invoke-BridgeRelaunch -TaskName 'HimmelTelegramBridge' -BridgeDir 'C:/repo/scripts/telegram' -LogPath 'C:/log/supervisor.log' `
  -GetTaskAction { param($Name) [pscustomobject]@{ TaskName = $Name } } `
  -StartTaskAction { param($Name) $script:taskCalls++ } `
  -StartProcessAction { param($Dir, $CmdLine) $script:cmdCalls++ }
Check 'registered scheduled task -> dispatches via the task, never the cmd fallback' `
  (($dispatchWithTask -eq 'scheduled-task') -and ($taskCalls -eq 1) -and ($cmdCalls -eq 0)) `
  "kind=$dispatchWithTask taskCalls=$taskCalls cmdCalls=$cmdCalls"

$taskCalls = 0; $cmdCalls = 0; $cmdSeen = $null
$dispatchNoTask = Invoke-BridgeRelaunch -TaskName 'HimmelTelegramBridge' -BridgeDir 'C:/repo/scripts/telegram' -LogPath 'C:/log/supervisor.log' `
  -GetTaskAction { param($Name) $null } `
  -StartTaskAction { param($Name) $script:taskCalls++ } `
  -StartProcessAction { param($Dir, $CmdLine) $script:cmdCalls++; $script:cmdSeen = $CmdLine }
Check 'no scheduled task registered -> falls back to the cmd /c launch, never the task' `
  (($dispatchNoTask -eq 'cmd-fallback') -and ($cmdCalls -eq 1) -and ($taskCalls -eq 0)) `
  "kind=$dispatchNoTask taskCalls=$taskCalls cmdCalls=$cmdCalls"
Check 'cmd fallback launches the real bun supervisor.ts entrypoint redirected to the log' `
  ($cmdSeen -match 'bun supervisor\.ts > "C:/log/supervisor\.log" 2>&1') "got=$cmdSeen"

Write-Host "Test 18 (HIMMEL-1510): Windows PowerShell 5.1 UTF-8 BOM contract"
$helperBytes = [System.IO.File]::ReadAllBytes($Helper)
$selfBytes = [System.IO.File]::ReadAllBytes($MyInvocation.MyCommand.Path)
Check 'restart-bridge.ps1 keeps UTF-8 BOM' (($helperBytes[0] -eq 0xEF) -and ($helperBytes[1] -eq 0xBB) -and ($helperBytes[2] -eq 0xBF))
Check 'test-restart-bridge.ps1 keeps UTF-8 BOM' (($selfBytes[0] -eq 0xEF) -and ($selfBytes[1] -eq 0xBB) -and ($selfBytes[2] -eq 0xBF))

Write-Host "Test 19 (HIMMEL-1519 round 2, finding A): the canonical circuit-breaker topology -- absent ledger + zero live processes + DOWN -> relaunches"
# supervisor.ts's circuit breaker clearPidfile()'s the ledger before it exits,
# so the most common fully-crashed state has NO ledger at all. Before this
# fix the absent-ledger refusal fired unconditionally and this state could
# never reach the zero-validated fork -- the entire reason HIMMEL-1519 exists.
Check 'ledger-absent gate does not itself refuse when this is DOWN remediation' `
  (-not (Test-FromLedgerAbsentLedgerRefuses -LedgerAbsent $true -IsDownRemediation $true))
Check 'absent ledger + DOWN remediation + zero live bridge/orphan procs -> the owner-scan still lets it proceed' `
  (Test-FromLedgerZeroValidatedProceed -ProbeAction { @() } -AllBunProbeAction { @() })

Write-Host "Test 20 (HIMMEL-1519 round 2, finding A): absent ledger + a live core bridge process -> still refuses"
# Falling through the ledger-absence refusal must NOT itself grant a relaunch
# -- the downstream owner-scan (the same guard Test 16 already proves is not
# deleted) still catches a live unaccounted-for bridge process.
Check 'ledger-absent gate still does not refuse for lack of ledger alone during DOWN remediation' `
  (-not (Test-FromLedgerAbsentLedgerRefuses -LedgerAbsent $true -IsDownRemediation $true))
Check 'absent ledger + DOWN remediation + a live unaccounted core bridge process -> the owner-scan refuses' `
  (-not (Test-FromLedgerZeroValidatedProceed -ProbeAction { @([pscustomobject]@{ ProcessId = 900 }) } -AllBunProbeAction { @() }))

Write-Host "Test 21 (HIMMEL-1519 round 2, finding B): orphan-only -> refuses, and the data behind the refusal names the PID"
# Get-BridgeProcs deliberately excludes a bun server.ts orphaned by a dead
# telegram-himmel launcher (the script's own accepted under-reap trade-off).
# Before round 1 that was harmless (nothing ever relaunched); now it must be
# caught by the stricter owner-scan or it becomes a live 2nd getUpdates
# consumer beside the freshly relaunched supervisor.
$unattribOrphan = @(Rec 501 999 $SERVER)   # launcher pid 999 absent -> unattributable
Check 'unattributable server.ts orphan alone is flagged as a plausible getUpdates owner' `
  (@(Get-PlausibleGetUpdatesOwners -BridgeProcs @() -AllBun $unattribOrphan).Count -eq 1)
Check 'unattributable orphan alone -> zero-validated-proceed refuses' `
  (-not (Test-FromLedgerZeroValidatedProceed -ProbeAction { @() } -AllBunProbeAction { $unattribOrphan }))
Check 'the refusal is backed by the actual orphan PID, not log prose' `
  ((@(Get-PlausibleGetUpdatesOwners -BridgeProcs @() -AllBun $unattribOrphan) | ForEach-Object { $_.ProcessId }) -contains 501)

$teleLauncherAlive = Rec 800 1 $TELE_LAUNCHER
$teleChildOrphan   = Rec 801 800 $SERVER
$telegramOrphanSet = @($teleLauncherAlive, $teleChildOrphan)
Check 'telegram-attributable server.ts orphan (missed by the core bridge-proc split) is flagged too' `
  (@(Get-PlausibleGetUpdatesOwners -BridgeProcs @() -AllBun $telegramOrphanSet).Count -eq 1)
Check 'telegram-attributable orphan alone -> zero-validated-proceed refuses' `
  (-not (Test-FromLedgerZeroValidatedProceed -ProbeAction { @() } -AllBunProbeAction { $telegramOrphanSet }))

Write-Host "Test 22 (HIMMEL-1519 round 2, finding B, MANDATORY anti-fail-closed-forever): a clean empty machine still relaunches"
# Proves the stricter owner-scan did not brick the happy path this whole verb
# exists to serve -- both a truly empty machine and one with only unrelated
# codex-plugin bun processes (the common real-machine case: other MCP
# servers' bare `server.ts` cmdlines) must still proceed to relaunch.
Check 'clean empty machine (no core procs, no server.ts of any kind) -> still proceeds to relaunch' `
  (Test-FromLedgerZeroValidatedProceed -ProbeAction { @() } -AllBunProbeAction { @() })
$unrelatedCodexPlugin = @((Rec 700 1 $LUNA_LAUNCHER), (Rec 701 700 $SERVER))
Check 'unrelated codex-plugin bun server.ts (e.g. luna-correlate) present -> still proceeds, never a false-positive owner' `
  (Test-FromLedgerZeroValidatedProceed -ProbeAction { @() } -AllBunProbeAction { $unrelatedCodexPlugin })
Check 'Get-PlausibleGetUpdatesOwners itself excludes the codex-plugin server.ts' `
  (@(Get-PlausibleGetUpdatesOwners -BridgeProcs @() -AllBun $unrelatedCodexPlugin).Count -eq 0)

Write-Host "Test 23 (HIMMEL-1519 round 2, finding A scoping): ordinary -FromLedger -Kill (not DOWN) with an absent ledger -> still refuses"
# Proves the Finding-A fall-through is scoped to the DOWN-remediation entry
# only -- an operator-invoked `-FromLedger -Kill` (never routed through
# -Watchdog's DOWN classification) keeps the original, stricter behavior.
Check 'ordinary -FromLedger -Kill + absent ledger -> refuses before ever reaching the owner-scan' `
  (Test-FromLedgerAbsentLedgerRefuses -LedgerAbsent $true -IsDownRemediation $false)
Check 'a present ledger never refuses on this gate, remediation flag either way' `
  ((-not (Test-FromLedgerAbsentLedgerRefuses -LedgerAbsent $false -IsDownRemediation $false)) -and (-not (Test-FromLedgerAbsentLedgerRefuses -LedgerAbsent $false -IsDownRemediation $true)))

Write-Host "Test 24 (HIMMEL-1519 round 3): validated ledger stop succeeds BUT an orphaned server.ts survives -> still refuses"
# The round-3 defect: the validated-stop branch's post-stop survivor probe was
# a bare Get-BridgeProcs, which deliberately misses a bun server.ts orphaned by
# a dead telegram-himmel launcher (the script's own accepted under-reap). Stop
# the validated pid(s), the orphan survives UNSEEN, Test-BridgeRelaunchSafe
# returned safe, and the script relaunched -> 2nd getUpdates owner -> 409 storm
# -- the precise outcome the guard exists to prevent (same class as round 2
# finding B, one branch over). Test-ValidatedStopRelaunchSafe is the exact
# orphan-aware probe the fixed script calls after the stop + settle sleep; it
# returning $false IS the refuse-to-relaunch decision that drives exit 1 there.
# Step 1: the validated stop succeeds. The orphan is NOT a validated pid, so it
# is never sent to Stop-Process -- it survives the stop by construction.
$validatedEntries = @([pscustomobject]@{ label = 'poller'; pid = 700 })
$stopFailures = @(Invoke-ValidatedBridgeStops -Entries $validatedEntries -StopAction { param($ProcessId) <# pid exits cleanly #> })
Check 'validated ledger pid stops cleanly (no stop failures)' (@($stopFailures).Count -eq 0)
Check 'a clean validated stop alone does not block relaunch' (Test-BridgeRelaunchSafe -StopFailures $stopFailures -Survivors @())
# Step 2: post-stop, an orphaned server.ts survives that Get-BridgeProcs does
# NOT match. ProbeAction=empty models the reaped bridge set (the validated pid
# is gone); AllBunProbeAction carries the orphan (launcher pid 999 dead ->
# unattributable -> a plausible owner Get-PlausibleGetUpdatesOwners keeps).
$orphanAfterStop = @(Rec 501 999 $SERVER)
Check 'validated stop + orphan survivor that Get-BridgeProcs misses -> relaunch UNSAFE (the round-3 fix)' `
  (-not (Test-ValidatedStopRelaunchSafe -ProbeAction { @() } -AllBunProbeAction { $orphanAfterStop }))
# Step 3: the refusal the operator sees is backed by the surviving orphan PID,
# so the warning names something concrete to kill -- not prose.
$refusalOwners = @(Get-PlausibleGetUpdatesOwners -BridgeProcs @() -AllBun $orphanAfterStop)
Check 'the refusal is backed by the surviving orphan PID, not prose' (($refusalOwners | ForEach-Object { $_.ProcessId }) -contains 501)
# Step 4 (anti-fail-closed-forever): a genuinely empty post-stop table still
# relaunches -- the orphan-aware scan did not brick the happy path this verb
# exists to serve.
Check 'validated stop + genuinely empty post-stop table -> relaunch safe' `
  (Test-ValidatedStopRelaunchSafe -ProbeAction { @() } -AllBunProbeAction { @() })

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
