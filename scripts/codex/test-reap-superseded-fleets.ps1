# Hermetic tests for reap-superseded-fleets.ps1 (HIMMEL-1309).
# Get-CimInstance is NOT mocked: the .ps1 exposes pure classifiers that take a
# synthetic process-records array. We dot-source with -AsLibrary (defines
# functions, skips the live scan) and assert the superseded set for a topology
# that mirrors the 2026-07-27 live reproduction (two app-servers, one of them
# holding five luna-correlate generations spawned 10-23s apart).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'reap-superseded-fleets.ps1'
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

. $Helper -AsLibrary

$Now = Get-Date -Date '2026-07-27T23:00:00'
function Rec($procId, $parentId, $name, $cl, $agoMinutes) {
  [pscustomobject]@{
    ProcessId       = $procId
    ParentProcessId = $parentId
    Name            = $name
    CommandLine     = $cl
    CreationDate    = $Now.AddMinutes(-$agoMinutes)
  }
}

# Fixture command lines derive from the running user's profile dir (no literal
# home paths in source - the propagation leak scan fail-closes on them). The
# classifiers key on username-independent fragments (--cwd plugin path, the
# command tail), so any profile root works.
$UserHome = $env:USERPROFILE
$UserHomeFwd = $UserHome -replace '\\', '/'
$PluginCache = "$UserHomeFwd/.codex/plugins/cache/himmel"
$LUNA   = "`"$UserHomeFwd/.bun/bin\bun.exe`" run --cwd $PluginCache/luna-correlate/0.2.0 --shell=bun --silent start"
$TELE   = "`"$UserHomeFwd/.bun/bin\bun.exe`" run --cwd $PluginCache/telegram-himmel/0.0.6 --shell=bun --silent start"
$SERVER = "$UserHome\.bun\bin\bun.exe server.ts"
$UVX    = "`"$UserHomeFwd/.local/bin\uvx.exe`" mcp-obsidian"
$REPL   = "`"$UserHome\AppData\Local\OpenAI\Codex\runtimes\cua_node\f8d2abcb\bin\node_repl.exe`""
$BROKER = "node $UserHome\.claude\plugins\cache\openai-codex\codex\1.0.5\scripts\app-server-broker.mjs serve --endpoint pipe:\\.\pipe\cxc-abc-codex-app-server"
$QMD    = "node `"$UserHome\.bun\install\global\node_modules\@tobilu\qmd\dist\cli\qmd.js`" mcp"

# --- topology (mirrors the live reproduction) --------------------------------
$procs = @(
  (Rec 90  1   'node.exe'  $BROKER 121)                     # broker (never a target)
  (Rec 100 90  'codex.exe' 'codex.exe app-server' 120)      # app-server A (LIVE)

  # A / luna-correlate: four generations. Newest (113) is 5m old.
  (Rec 110 100 'bun.exe' $LUNA 120)
  (Rec 111 100 'bun.exe' $LUNA 60)
  (Rec 112 100 'bun.exe' $LUNA 50)
  (Rec 113 100 'bun.exe' $LUNA 5)
  (Rec 210 110 'bun.exe' $SERVER 120)                       # server.ts grandchildren
  (Rec 211 111 'bun.exe' $SERVER 60)
  (Rec 212 112 'bun.exe' $SERVER 50)
  (Rec 213 113 'bun.exe' $SERVER 5)

  # A / telegram-himmel: a DIFFERENT plugin -> its own key, its own newest.
  (Rec 170 100 'bun.exe' $TELE 120)
  (Rec 270 170 'bun.exe' $SERVER 120)
  (Rec 171 100 'bun.exe' $TELE 40)
  (Rec 271 171 'bun.exe' $SERVER 40)

  # A / node_repl (no args at all) and uvx (args, no --cwd): cross-type keying.
  (Rec 120 100 'node_repl.exe' $REPL 120)
  (Rec 121 100 'node_repl.exe' $REPL 60)
  (Rec 130 100 'uvx.exe' $UVX 120)
  (Rec 131 100 'uvx.exe' $UVX 2)

  # A / codex's OWN qmd MCP server (a plugin fleet member, same shape as the
  # operator's 402 below) - superseded generations of it MUST stay reapable.
  (Rec 180 100 'qmd.exe' 'qmd mcp' 120)
  (Rec 280 180 'node.exe' $QMD 120)
  (Rec 181 100 'qmd.exe' 'qmd mcp' 40)
  (Rec 281 181 'node.exe' $QMD 40)

  # A / unreadable CommandLine -> unkeyable, must be excluded AND counted blind.
  (Rec 150 100 'bun.exe' $null 100)

  # app-server B (LIVE): same plugin key as A's, but a separate group.
  (Rec 200 90  'codex.exe' 'codex.exe app-server' 118)
  (Rec 140 200 'bun.exe' $LUNA 120)
  (Rec 141 200 'bun.exe' $LUNA 40)

  # app-server C (LIVE): a burst of three fleets seconds apart = parallel tool
  # calls, ALL younger than min-age -> none may be reaped.
  (Rec 300 90  'codex.exe' 'codex.exe app-server' 10)
  (Rec 310 300 'bun.exe' $LUNA 3)
  (Rec 311 300 'bun.exe' $LUNA 2)
  (Rec 312 300 'bun.exe' $LUNA 1)

  # Fleet under a DEAD app-server (pid 999 absent) - reap-mcp-fleet.ps1's job.
  (Rec 160 999 'bun.exe' $LUNA 120)

  # Protected, outside any app-server: v2 telegram bridge + qmd MCP.
  (Rec 400 1   'bun.exe' 'bun  supervisor.ts ' 200)
  (Rec 401 400 'bun.exe' 'bun poller.ts' 200)
  (Rec 402 1   'node.exe' $QMD 200)
)

$superseded = @(Get-SupersededFleetRoots -Procs $procs -Now $Now -KeepNewest 1 -MinAgeMinutes 30)
$got = @($superseded | ForEach-Object { $_.RootPid } | Sort-Object)
$want = @(110, 111, 112, 120, 130, 140, 170, 180)

Write-Host "Test 1: exact superseded set = every non-newest root older than min-age, per (app-server, plugin)"
Check 'superseded set is {110,111,112,120,130,140,170,180}' (($got -join ',') -eq ($want -join ',')) "got=$($got -join ',')"

Write-Host "Test 2: the newest root of every group is ALWAYS kept (this is what stays in use)"
foreach ($keep in @(113, 171, 121, 131, 141, 181, 312)) {
  Check "newest root $keep kept" (-not ($got -contains $keep))
}

Write-Host "Test 3: min-age gate protects a concurrent burst (parallel tool calls, seconds apart)"
Check 'burst root 310 kept (3m old)' (-not ($got -contains 310))
Check 'burst root 311 kept (2m old)' (-not ($got -contains 311))
$noAgeGate = @(Get-SupersededFleetRoots -Procs $procs -Now $Now -KeepNewest 1 -MinAgeMinutes 0 | ForEach-Object { $_.RootPid })
Check 'without the age gate the same burst IS flagged (gate is what spares it, not shape)' (($noAgeGate -contains 310) -and ($noAgeGate -contains 311))

Write-Host "Test 4: supervisors, dead-app-server fleets and unkeyable roots are never candidates"
Check 'app-server A (100) never a candidate'  (-not ($got -contains 100))
Check 'app-server B (200) never a candidate'  (-not ($got -contains 200))
Check 'broker 90 never a candidate'           (-not ($got -contains 90))
Check 'dead-app-server fleet 160 excluded (reap-mcp-fleet.ps1 owns it)' (-not ($got -contains 160))
Check 'blind root 150 excluded from verdicts' (-not ($got -contains 150))
$blind = Get-BlindFleetRootPids -Procs $procs
Check 'blind root 150 is COUNTED, not silently dropped' (($blind.Count -eq 1) -and ($blind[0] -eq 150)) "got=$($blind -join ',')"

Write-Host "Test 5: keys are per (app-server, plugin) - never merged across either axis"
Check "B's luna root 140 flagged even though A has its own luna group" ($got -contains 140)
Check "B's newest luna root 141 kept (per-app-server newest, not global)" (-not ($got -contains 141))
$lunaKey = Get-FleetKey -Proc (Rec 1 0 'bun.exe' $LUNA 0)
$teleKey = Get-FleetKey -Proc (Rec 1 0 'bun.exe' $TELE 0)
Check 'luna-correlate and telegram-himmel are DIFFERENT keys' ($lunaKey -ne $teleKey) "luna=$lunaKey tele=$teleKey"
Check 'the --cwd plugin path is the key identity' ($lunaKey -like '*luna-correlate/0.2.0') "got=$lunaKey"
Check 'separator spelling does not split a key' ((Get-FleetKey -Proc (Rec 1 0 'bun.exe' ($LUNA -replace '/', '\') 0)) -eq $lunaKey)

Write-Host "Test 6: cross-type keying (gap 3 - a bun-only fix misses most of the mass)"
Check 'uvx root 130 flagged (args, no --cwd)'        ($got -contains 130)
Check 'node_repl root 120 flagged (no args at all)'  ($got -contains 120)
Check 'uvx key carries its arg tail' ((Get-FleetKey -Proc (Rec 1 0 'uvx.exe' $UVX 0)) -eq 'uvx|mcp-obsidian')
Check 'node_repl key is name-scoped with an empty tail' ((Get-FleetKey -Proc (Rec 1 0 'node_repl.exe' $REPL 0)) -eq 'node_repl|')
Check 'two different images never collide on an empty tail' `
  ((Get-FleetKey -Proc (Rec 1 0 'node_repl.exe' '"a.exe"' 0)) -ne (Get-FleetKey -Proc (Rec 1 0 'bun.exe' '"b.exe"' 0)))
Check 'an unreadable CommandLine is unkeyable (null), never a guessed key' `
  ($null -eq (Get-FleetKey -Proc (Rec 1 0 'bun.exe' $null 0)))

Write-Host "Test 7: LINEAGE is what spares the operator's processes; the tripwire is narrow"
Check "the operator's bridge (400/401) is out of scope - not under any app-server" `
  ((-not ($got -contains 400)) -and (-not ($got -contains 401)))
Check "the operator's qmd MCP (402) is out of scope - not under any app-server" (-not ($got -contains 402))
$prot = Get-ProtectedPids -Procs $procs
Check 'tripwire covers telegram bridge supervisor.ts (400)' ($prot.Contains(400))
Check 'tripwire covers telegram bridge poller.ts (401)'     ($prot.Contains(401))
Check 'tripwire is EXACTLY the bridge (2 pids)' ($prot.Count -eq 2) "got=$($prot.Count)"
Check "a codex telegram-himmel MCP server stays reapable (it is NOT the bridge)" ($got -contains 170)
Check 'its bun server.ts child is not tripwired either' (-not $prot.Contains(270))
Check 'npx-cli.js is not mistaken for the claude CLI' `
  (-not (Test-IsProtectedProcess -Proc (Rec 1 0 'node.exe' 'node C:\npm\bin\npx-cli.js -y @upstash/context7-mcp' 0)))
Check 'the codex broker is not tripwired (it is simply never a candidate)' (-not $prot.Contains(90))
# Regression for the 2026-07-27 dry run: a shape-based qmd entry in the tripwire
# protected SIX superseded codex-owned qmd fleet roots - i.e. it re-created the
# restart-bridge.ps1 misattribution (shape, not lineage) inside the new tool.
Check "codex's OWN qmd MCP server is NOT tripwired (shape must not override lineage)" `
  (-not (Test-IsProtectedProcess -Proc (Rec 1 0 'node.exe' $QMD 0)))
Check "a superseded codex-owned qmd fleet root IS reaped" ($got -contains 180)

Write-Host "Test 8: -KeepNewest widens the kept band, never the kill set"
$keep2 = @(Get-SupersededFleetRoots -Procs $procs -Now $Now -KeepNewest 2 -MinAgeMinutes 30 | ForEach-Object { $_.RootPid } | Sort-Object)
Check 'keep-newest=2 spares the 2nd-newest luna root 112' (-not ($keep2 -contains 112))
Check 'keep-newest=2 still flags the older luna roots 110,111' (($keep2 -contains 110) -and ($keep2 -contains 111))
Check 'keep-newest=2 is a strict subset of keep-newest=1' (@($keep2 | Where-Object { $got -notcontains $_ }).Count -eq 0)

Write-Host "Test 9: app-server predicate is narrow (only `codex.exe app-server`)"
Check 'codex.exe app-server is an app-server'  (Test-IsCodexAppServer -Proc (Rec 1 0 'codex.exe' 'codex.exe app-server' 0))
Check 'codex.exe exec is NOT an app-server'    (-not (Test-IsCodexAppServer -Proc (Rec 1 0 'codex.exe' 'codex.exe exec --sandbox' 0)))
Check 'the broker node.exe is NOT an app-server' (-not (Test-IsCodexAppServer -Proc (Rec 1 0 'node.exe' $BROKER 0)))
Check 'app-server-broker.mjs does not match via the word app-server' `
  (-not (Test-IsCodexAppServer -Proc (Rec 1 0 'node.exe' 'node app-server-broker.mjs serve' 0)))

Write-Host "Test 10: CPU-idle veto fails SAFE - an unmeasurable subtree is never idle"
Check 'null delta (access denied / gone mid-sample) vetoes the kill' (-not (Test-CpuIdle -DeltaMs $null -ThresholdMs 50))
Check 'delta under threshold reads idle'  (Test-CpuIdle -DeltaMs 12.5 -ThresholdMs 50)
Check 'delta at threshold reads idle'     (Test-CpuIdle -DeltaMs 50 -ThresholdMs 50)
Check 'delta over threshold vetoes'       (-not (Test-CpuIdle -DeltaMs 51 -ThresholdMs 50))

Write-Host "Test 11: degenerate inputs do not throw"
Check 'empty table -> 0 superseded' (@(Get-SupersededFleetRoots -Procs @() -Now $Now).Count -eq 0)
Check 'empty table -> 0 blind'      ((Get-BlindFleetRootPids -Procs @()).Count -eq 0)
Check 'empty table -> 0 protected'  ((Get-ProtectedPids -Procs @()).Count -eq 0)
$noAppServer = @(Get-SupersededFleetRoots -Procs @((Rec 500 1 'bun.exe' $LUNA 300), (Rec 501 500 'bun.exe' $SERVER 300)) -Now $Now)
Check 'no live app-server -> 0 superseded (nothing to supersede against)' ($noAppServer.Count -eq 0)
$noCreation = @([pscustomobject]@{ ProcessId = 601; ParentProcessId = 600; Name = 'codex.exe'; CommandLine = 'codex.exe app-server' },
                [pscustomobject]@{ ProcessId = 602; ParentProcessId = 601; Name = 'bun.exe'; CommandLine = $LUNA },
                [pscustomobject]@{ ProcessId = 603; ParentProcessId = 601; Name = 'bun.exe'; CommandLine = $LUNA })
Check 'roots with no CreationDate are skipped, never guessed' (@(Get-SupersededFleetRoots -Procs $noCreation -Now $Now).Count -eq 0)

Write-Host "Test 14: stale-PPID impostors never reach the kill set (codex adversarial finding)"
# Get-DescendantPids' stale-PPID filter is fail-OPEN (it keeps a link when either
# creation date is unknown) because sweep-codex-orphans.ps1 gates orphan
# CLASSIFICATION separately via the client-pipe test. This tool has no such second
# gate: only the ROOT is classified, descendants inherit membership from the PPID
# walk alone. Windows never rewrites a process's recorded PPID when its parent
# dies, so an unrelated process whose dead parent's pid was RECYCLED into a fleet
# pid joins the tree, and the name allow-list (node/python/cmd/bash/pwsh) does not
# stop it. Select-VerifiedDescendants re-gates on the root's creation time.
$rootCreated = $Now.AddMinutes(-60)
$impostorProcs = @(
  (Rec 700 100 'bun.exe'    $LUNA 60)    # superseded fleet root
  (Rec 701 700 'bun.exe'    $SERVER 60)  # genuine child, same age as its root
  (Rec 702 701 'python.exe' 'python helper.py' 59)  # genuine grandchild, NEWER than the root
  (Rec 703 700 'python.exe' 'python unrelated-long-running.py' 300)  # STALE-PPID IMPOSTOR: 5h old, predates its "parent"
)
$walked = @(701, 702, 703)   # what the fail-open PPID walk yields
$verified = Select-VerifiedDescendants -Procs $impostorProcs -Pids ([int[]]$walked) -RootCreated $rootCreated
$vs = @($verified | Sort-Object)
Check 'genuine same-age child 701 kept'        ($vs -contains 701)
Check 'genuine newer grandchild 702 kept'      ($vs -contains 702)
Check 'stale-PPID impostor 703 DROPPED (predates its claimed root)' (-not ($vs -contains 703)) "got=$($vs -join ',')"
Check 'verified set is exactly {701,702}'      (($vs -join ',') -eq '701,702') "got=$($vs -join ',')"

# Fail CLOSED, not open: an unreadable creation time is exactly what must not be
# killed here (the opposite of the shared walk's fail-open stance).
$noDate = @([pscustomobject]@{ ProcessId = 801; ParentProcessId = 700; Name = 'node.exe'; CommandLine = 'node x.js' })
Check 'descendant with NO creation time is dropped (fail closed)' `
  ((Select-VerifiedDescendants -Procs $noDate -Pids ([int[]]@(801)) -RootCreated $rootCreated).Count -eq 0)
# A pid that vanished between the walk and the re-gate is simply absent.
Check 'pid absent from the table is dropped, not assumed kin' `
  ((Select-VerifiedDescendants -Procs $impostorProcs -Pids ([int[]]@(999999)) -RootCreated $rootCreated).Count -eq 0)
# Clock-skew tolerance matches Test-ProcessStartMatches (2s), so a child recorded
# a hair before its parent is still kin, not an impostor.
$skew = @([pscustomobject]@{ ProcessId = 802; ParentProcessId = 700; Name = 'bun.exe'; CommandLine = $SERVER; CreationDate = $rootCreated.AddSeconds(-1) })
Check 'child 1s "older" than its root survives (2s skew tolerance)' `
  ((Select-VerifiedDescendants -Procs $skew -Pids ([int[]]@(802)) -RootCreated $rootCreated) -contains 802)
$skew2 = @([pscustomobject]@{ ProcessId = 803; ParentProcessId = 700; Name = 'bun.exe'; CommandLine = $SERVER; CreationDate = $rootCreated.AddSeconds(-30) })
Check 'child 30s older than its root is dropped (beyond tolerance)' `
  ((Select-VerifiedDescendants -Procs $skew2 -Pids ([int[]]@(803)) -RootCreated $rootCreated).Count -eq 0)
Check 'empty pid list does not throw' `
  ((Select-VerifiedDescendants -Procs $impostorProcs -Pids ([int[]]@()) -RootCreated $rootCreated).Count -eq 0)

Write-Host "Test 15: platform guard survives Windows PowerShell 5.1 ([codex-1]/[glm-3])"
# $IsWindows is a PS6+ automatic variable. Under 5.1 it is UNDEFINED ($null), so a
# bare `-not $IsWindows` is TRUE and the reaper exits 0 as "non-Windows" on the
# very platform it targets — while the cadence runner logs a clean rc=0. That path
# is reachable: codex-sweep-cadence.sh's resolve_pwsh falls back to powershell.exe
# when pwsh is absent, so a PowerShell-7-less adopter gets a daily no-op sweep.
Check 'PS 7 on Windows  ($IsWindows=$true)  -> Windows'  (Test-OnWindows -IsWindowsValue $true -OsEnv 'Windows_NT')
Check 'PS 7 on Linux    ($IsWindows=$false) -> NOT Windows' (-not (Test-OnWindows -IsWindowsValue $false -OsEnv $null))
Check 'PS 5.1 on Windows ($IsWindows undefined, OS=Windows_NT) -> Windows (the regression)' `
  (Test-OnWindows -IsWindowsValue $null -OsEnv 'Windows_NT')
Check 'undefined $IsWindows with a non-Windows OS env -> NOT Windows' `
  (-not (Test-OnWindows -IsWindowsValue $null -OsEnv 'Linux'))
Check 'undefined $IsWindows with an EMPTY OS env -> NOT Windows (no blind assume)' `
  (-not (Test-OnWindows -IsWindowsValue $null -OsEnv ''))
# NB: the "PS 5.1 on Windows" case above IS the regression guard — under the bare
# `-not $IsWindows` form it evaluated TRUE (skip), and it now evaluates to Windows.
# An earlier draft added a further `Check ... (-not $null)` here meaning to pin
# that contrast; `-not $null` is a TAUTOLOGY, so it asserted nothing while adding
# a guaranteed PASS to the count — a test that reports success without testing.
# Removed rather than reworded: the assertions above already cover the behaviour.

Write-Host "Test 12: malformed argv fails fast (no hang) - parity with test-reap-mcp-fleet.ps1"
function Test-FailsFast([string[]]$ExtraArgs, [string]$Name) {
  $inFile = [System.IO.Path]::GetTempFileName()
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Helper) + $ExtraArgs
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $psArgs `
      -NoNewWindow -PassThru -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $finished = $proc.WaitForExit(30000)
    if (-not $finished) {
      try { $proc.Kill() } catch {}
      Fail $Name 'timed out after 30s (hang)'
    } else {
      Check $Name ($proc.ExitCode -ne 0) "exit=$($proc.ExitCode)"
    }
  } finally {
    Remove-Item -Path $inFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}
Test-FailsFast @('-MinAgeMinutes') 'missing -MinAgeMinutes value fails fast (no hang)'
Test-FailsFast @('-KeepNewest', '0') 'out-of-range -KeepNewest 0 is rejected (never "keep none")'

Write-Host "Test 13: the real script actually RUNS its production path (dot-source param clobber regression)"
# Dot-sourcing sweep-codex-orphans.ps1 executes ITS param() block in this
# script's scope, overwriting our identically-named $Kill / $AsLibrary. Before
# the restore, that set $AsLibrary = $true at runtime so the production path
# `return`ed immediately: exit 0, ZERO output, -Kill silently discarded - a
# reaper that looks healthy and never reaps. Any output at all proves the
# production path was reached (the exact line depends on what is running on the
# host, so the assertion is on the tag, not on a verdict).
$outFile = [System.IO.Path]::GetTempFileName()
$errFile = [System.IO.Path]::GetTempFileName()
$inFile = [System.IO.Path]::GetTempFileName()
try {
  $proc = Start-Process -FilePath (Get-Process -Id $PID).Path `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Helper, '-SampleSeconds', '0') `
    -NoNewWindow -PassThru -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  if (-not $proc.WaitForExit(60000)) {
    try { $proc.Kill() } catch {}
    Fail 'dry run reaches the production path' 'timed out after 60s'
  } else {
    $stdout = (Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue)
    Check 'dry run exits 0' ($proc.ExitCode -eq 0) "exit=$($proc.ExitCode)"
    Check 'dry run emits its tag (production path was not silently skipped)' `
      ($stdout -and $stdout -match '\[reap-superseded-fleets\]') "stdout=$($stdout | Out-String)"
    Check 'dry run never claims to have stopped anything' (-not ($stdout -match 'stopped \d+ of')) "stdout=$($stdout | Out-String)"
  }
} finally {
  Remove-Item -Path $inFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
