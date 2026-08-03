# Hermetic tests for sweep-codex-orphans.ps1 (HIMMEL-892).
# Get-CimInstance is NOT mocked and NO real process is killed: the .ps1 exposes
# pure helpers (token extraction, broker/client predicates, the client-pipe
# orphan classifier, the descendant walk, the name allow-list) that take a
# synthetic process-records array. We dot-source the script with -AsLibrary
# (defines functions, skips the live scan + OS guard) and assert against a
# hand-built topology that mirrors the real machine grounding.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'sweep-codex-orphans.ps1'
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

# Load the pure functions without running the production scan.
. $Helper -AsLibrary

function Rec($procId, $parentId, $name, $cl) {
  [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $parentId; Name = $name; CommandLine = $cl }
}
function RecT($procId, $parentId, $name, $cl, $created) {
  [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $parentId; Name = $name; CommandLine = $cl; CreationDate = $created }
}

# Fixture command lines derive from the running user's profile dir (no literal
# home paths in source - the propagation leak scan fail-closes on them).
$UserHome = $env:USERPROFILE
function BrokerLine($token, $cwd = $null) {
  $line = "node $UserHome\.claude\plugins\cache\openai-codex\codex\1.0.5\scripts\app-server-broker.mjs serve --endpoint pipe:\\.\pipe\cxc-$token-codex-app-server"
  if ($cwd) { $line += " --cwd=`"$cwd`"" }
  return $line
}
function ClientRef($token) {
  # Any outside client connects to the broker's named pipe; its command line
  # carries the same pipe-name fragment regardless of image name.
  "claude-code.exe --mcp-endpoint \\.\pipe\cxc-$token-codex-app-server --session xyz"
}

# --- Test 1: token extraction ------------------------------------------------
Write-Host "Test 1: token extraction from sample command lines"
$bl = BrokerLine 'aaa111'
Check 'broker line -> aaa111'           ((Get-CxcToken -CommandLine $bl) -eq 'aaa111') "got='$(Get-CxcToken -CommandLine $bl)'"
Check 'client line -> aaa111'           ((Get-CxcToken -CommandLine (ClientRef 'aaa111')) -eq 'aaa111')
Check 'no-pipe line -> $null'           ($null -eq (Get-CxcToken -CommandLine 'node plain-script.js'))
$mt = Get-CxcTokens -CommandLine "x cxc-one-codex-app-server and cxc-two-codex-app-server"
Check 'multi-token -> both'             (($mt -join ',') -eq 'one,two') "got='$($mt -join ',')'"
Check 'no-pipe line -> empty array'     ((Get-CxcTokens -CommandLine 'nothing here').Count -eq 0)
Check 'dashed token a1-b2 preserved'    ((Get-CxcToken -CommandLine 'cxc-a1-b2-codex-app-server') -eq 'a1-b2') "got='$(Get-CxcToken -CommandLine 'cxc-a1-b2-codex-app-server')'"
Check 'quoted --cwd preserves spaces'   ((Get-BrokerCwd -CommandLine 'node broker.mjs --cwd="C:\Users\Example User\repo"') -eq 'C:\Users\Example User\repo')
Check 'unquoted --cwd still parses'     ((Get-BrokerCwd -CommandLine 'node broker.mjs --cwd=C:\repo') -eq 'C:\repo')

# --- Test 2: broker / client predicates --------------------------------------
Write-Host "Test 2: broker + client predicate classification"
Check 'broker is a broker'              (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' $bl))
Check 'plain node NOT a broker'         (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' 'node other.js')))
Check 'broker.mjs without serve NOT broker' (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' "node x\app-server-broker.mjs")))
Check 'broker.mjs without pipe NOT broker'  (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' "node x\app-server-broker.mjs serve --endpoint elsewhere")))
Check 'non-node NOT a broker'           (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'python.exe' $bl)))
Check 'claude.exe plausible blind client'  (Test-IsPlausibleCodexAppServerClient -Proc (Rec 2 0 'claude.exe' 'anything'))
Check 'ChatGPT.exe plausible blind client' (Test-IsPlausibleCodexAppServerClient -Proc (Rec 2 0 'ChatGPT.exe' 'anything'))
Check 'node.exe plausible blind client'    (Test-IsPlausibleCodexAppServerClient -Proc (Rec 2 0 'node.exe' 'anything'))
Check 'bun.exe plausible blind client'     (Test-IsPlausibleCodexAppServerClient -Proc (Rec 2 0 'bun.exe' 'anything'))
Check 'codex.exe NOT plausible outside client' (-not (Test-IsPlausibleCodexAppServerClient -Proc (Rec 2 0 'codex.exe' 'anything')))

# --- Test 2b: Layer A outside-tree render defers the whole kill pass ---------
Write-Host "Test 2b: outside-tree adversarial render deferral (HIMMEL-1474 Layer A)"
$tRender = Get-Date '2026-08-02 01:00:00'
$renderProcs = @(
  (RecT 10 1  'node.exe' (BrokerLine 'render10') $tRender)
  (RecT 11 10 'node.exe' 'node codex-companion.mjs adversarial-review --wait --base main' ($tRender.AddSeconds(1)))
  (RecT 20 1  'node.exe' 'node codex-companion.mjs adversarial-review --wait --base main' ($tRender.AddSeconds(1)))
  (RecT 21 1  'node.exe' 'node codex-companion.mjs adversarial-review --base main' ($tRender.AddSeconds(1)))
)
$outsideRenders = Get-OutsideCodexAdversarialRenderPids -Procs $renderProcs
Check 'only outside-tree full render shape is returned' (($outsideRenders -join ',') -eq '20') "got=$($outsideRenders -join ',')"
Check 'outside-tree render defers all kills' (Test-ShouldDeferCodexKill -OutsideRenderPids $outsideRenders)
$noRenders = Get-OutsideCodexAdversarialRenderPids -Procs @( (Rec 30 1 'node.exe' 'node other.js') )
Check 'no render leaves current kill behavior unchanged' (-not (Test-ShouldDeferCodexKill -OutsideRenderPids $noRenders))
Check 'missing --wait is not render shape' (-not (Test-IsCodexAdversarialRender -Proc $renderProcs[3]))

# --- Test 3: live/orphan classification on a synthetic table -----------------
# The five guards the algorithm hinges on:
#   (a) live  = outside process holds token      -> NOT orphan
#   (b) orphan = no outside process holds token  -> orphan
#   (c) dead-parent is a FALSE signal            -> outside holder wins, NOT orphan
#   (d) broker/descendant token refs are FALSE   -> still orphan
#   (e) detached companion node holds token      -> NOT orphan (HIMMEL-1467 repro)
Write-Host "Test 3: live/orphan classification (outside-tree pipe test; self/descendant guards)"
$tClass = Get-Date '2026-07-11 01:00:00'
$procs = @(
  # (a) LIVE: broker 100 token aaa111, client 110 holds aaa111.
  (Rec 100 1   'node.exe'   (BrokerLine 'aaa111'))
  (Rec 110 1   'claude.exe' (ClientRef 'aaa111'))   # holds the pipe -> broker LIVE

  # (b) ORPHAN: broker 200 token bbb222, NO client holds bbb222.
  (RecT 200 1   'node.exe'   (BrokerLine 'bbb222') $tClass)
  (RecT 201 200 'codex.exe'  'codex.exe app-server' ($tClass.AddSeconds(1))) # in-tree, irrelevant to liveness
  (RecT 202 200 'node.exe'   'node mcp-fleet.js'    ($tClass.AddSeconds(2))) # in-tree descendant

  # (c) dead-parent FALSE SIGNAL: broker 300 has DEAD parent (999 absent) BUT
  #     client 310 holds ccc333 -> MUST be LIVE (dead-parent must not reap it).
  (Rec 300 999 'node.exe'   (BrokerLine 'ccc333'))
  (Rec 310 1   'ChatGPT.exe' (ClientRef 'ccc333'))  # holds the pipe -> LIVE despite dead parent

  # (d) self/descendant references are NOT sufficient: both the broker argv
  #     and its codex.exe child carry ddd444, but no OUTSIDE process does.
  (RecT 400 1   'node.exe'   (BrokerLine 'ddd444') $tClass)
  (RecT 401 400 'codex.exe'  (ClientRef 'ddd444')  ($tClass.AddSeconds(1))) # in-tree token ref -> ignored
  (RecT 402 401 'node.exe'   'node mcp.js'         ($tClass.AddSeconds(2))) # grandchild

  # (e) HIMMEL-1467 exact repro: detached codex-companion node.exe is outside
  #     the broker tree and holds eee555 -> broker MUST be LIVE.
  (Rec 600 1   'node.exe'   (BrokerLine 'eee555'))
  (Rec 610 1   'node.exe'   ("node codex-companion.mjs adversarial-review " + (ClientRef 'eee555')))

  # Non-broker node must never be a candidate.
  (Rec 500 1   'node.exe'   'node playwright-mcp.js')
)

$orphanBrokers = @(Get-CodexOrphanBrokers -Procs $procs)
$obPids = @($orphanBrokers | ForEach-Object { $_.BrokerPid } | Sort-Object)
Check 'orphan brokers = {200,400}'     (($obPids -join ',') -eq '200,400') "got=$($obPids -join ',')"
Check 'live broker 100 excluded'       (-not ($obPids -contains 100))
Check 'dead-parent-but-held 300 excluded' (-not ($obPids -contains 300))
Check 'self/descendant-only broker 400 stays orphan' ($obPids -contains 400)
Check 'standalone companion node keeps 600 live' (-not ($obPids -contains 600))
Check 'non-broker node 500 excluded'   (-not ($obPids -contains 500))

# Exclusion is the union of ALL broker trees, not just the tree being judged:
# a descendant under one broker that mentions another token is still internal
# fleet evidence and must not keep the other broker alive.
$crossTreeProcs = @(
  (RecT 650 1   'node.exe'  (BrokerLine 'left11')  $tClass)
  (RecT 651 650 'node.exe'  (ClientRef 'right22') ($tClass.AddSeconds(1)))
  (RecT 660 1   'node.exe'  (BrokerLine 'right22') $tClass)
)
$crossTreeOrphans = @((Get-CodexOrphanBrokers -Procs $crossTreeProcs) | ForEach-Object { $_.BrokerPid } | Sort-Object)
Check 'cross-tree token reference cannot mark broker live' (($crossTreeOrphans -join ',') -eq '650,660') "got=$($crossTreeOrphans -join ',')"

# A detached outside client can retain a stale PPID after its real parent dies.
# If its CreationDate is unavailable, exclusion membership must fail closed:
# do not follow the unverifiable edge, so its visible token still proves LIVE.
$staleClientProcs = @(
  (RecT 670 1   'node.exe' (BrokerLine 'stale67') $tClass)
  (Rec  671 670 'node.exe' (ClientRef 'stale67'))
)
$staleClientOrphans = @((Get-CodexOrphanBrokers -Procs $staleClientProcs) | ForEach-Object { $_.BrokerPid })
Check 'undated stale-PPID outside token-holder keeps broker live' (-not ($staleClientOrphans -contains 670)) "got=$($staleClientOrphans -join ',')"

# codex-adv r2: a stale PPID recycled into a broker created within the OLD 2s
# tolerance window must not read as verified kin. The client (681) is 1 second
# OLDER than the broker (680) its stale PPID points at - strict same-snapshot
# ordering drops the edge, so its token still proves the broker LIVE.
$narrowStaleProcs = @(
  (RecT 680 1   'node.exe' (BrokerLine 'stale68') $tClass)
  (RecT 681 680 'node.exe' (ClientRef 'stale68') ($tClass.AddSeconds(-1)))
)
$narrowStaleOrphans = @((Get-CodexOrphanBrokers -Procs $narrowStaleProcs) | ForEach-Object { $_.BrokerPid })
Check '1s-older stale-PPID client still proves broker live (strict verified ordering)' (-not ($narrowStaleOrphans -contains 680)) "got=$($narrowStaleOrphans -join ',')"

# --- Test 3b: Layer B client leases protect only their attributed tree -------
Write-Host "Test 3b: fresh pid+StartTime client leases (HIMMEL-1474 Layer B)"
$leaseNow = [datetime]::Parse('2026-08-02T12:00:00Z').ToUniversalTime()
$leaseStart = $leaseNow.AddMinutes(-2)
$leaseProcs = @(
  (RecT 1000 1 'node.exe' (BrokerLine 'lease-a' 'C:\repo-a') $leaseStart)
  (RecT 2000 1 'node.exe' (BrokerLine 'lease-b' 'C:\repo-b') $leaseStart)
  (RecT 1010 1 'node.exe' 'node codex-companion.mjs adversarial-review --wait --base main' $leaseStart)
)
$freshLease = [pscustomobject]@{
  Token = 'lease-a'; ClientPid = 1010; ClientStartTime = $leaseStart.ToString('o')
  Cwd = 'C:\repo-a'; Heartbeat = $leaseNow.AddMinutes(-1).ToString('o')
}
$freshLeaseOrphans = @((Get-CodexOrphanBrokers -Procs $leaseProcs -ClientLeases @($freshLease) -NowUtc $leaseNow) | ForEach-Object { $_.BrokerPid } | Sort-Object)
Check 'fresh lease + live pid protects its tree' (-not ($freshLeaseOrphans -contains 1000)) "got=$($freshLeaseOrphans -join ',')"
Check 'lease in one tree does not protect another' ($freshLeaseOrphans -contains 2000) "got=$($freshLeaseOrphans -join ',')"
$leaseTreePids = Get-CodexBrokerTreePids -Procs $leaseProcs
$unattributedFreshRenders = Get-UnattributedCodexAdversarialRenderPids -Procs $leaseProcs -BrokerTreePids $leaseTreePids -ClientLeases @($freshLease) -NowUtc $leaseNow
Check 'fresh attributed render restores kill availability for other-cwd trees' (-not (Test-ShouldDeferCodexKill -OutsideRenderPids $unattributedFreshRenders))

# HIMMEL-1474 r2 startup race: the writer leased an older same-cwd broker, then
# a sibling broker appeared before the next heartbeat scan. The sibling remains
# an orphan candidate, but Layer A must defer -Kill until its lease catches up.
$raceProcs = @(
  (RecT 3000 1 'node.exe' (BrokerLine 'lease-old' 'C:\repo-race') $leaseStart)
  (RecT 3001 1 'node.exe' (BrokerLine 'lease-new' 'C:\repo-race') ($leaseStart.AddSeconds(30)))
  (RecT 3010 1 'node.exe' 'node codex-companion.mjs adversarial-review --wait --base main' $leaseStart)
)
$raceLease = [pscustomobject]@{
  Token = 'lease-old'; ClientPid = 3010; ClientStartTime = $leaseStart.ToString('o')
  Cwd = 'C:\repo-race'; Heartbeat = $leaseNow.AddMinutes(-1).ToString('o')
}
$raceTreePids = Get-CodexBrokerTreePids -Procs $raceProcs
$raceOrphans = @((Get-CodexOrphanBrokers -Procs $raceProcs -BrokerTreePids $raceTreePids -ClientLeases @($raceLease) -NowUtc $leaseNow) | ForEach-Object { $_.BrokerPid })
$raceOutsideRenders = Get-UnattributedCodexAdversarialRenderPids -Procs $raceProcs -BrokerTreePids $raceTreePids -ClientLeases @($raceLease) -NowUtc $leaseNow
Check 'new same-cwd broker remains unleased candidate' ($raceOrphans -contains 3001) "got=$($raceOrphans -join ',')"
Check 'unleased same-cwd broker keeps Layer A deferral active' (Test-ShouldDeferCodexKill -OutsideRenderPids $raceOutsideRenders) "got=$($raceOutsideRenders -join ',')"

# HIMMEL-1474 r3: an older explicitly-bound broker can be leased while a
# sibling with no explicit cwd under the same render remains unattributable.
# Unknown means unresolved, so Layer A must preserve the global safety defer.
$unknownCwdProcs = @(
  (RecT 3100 1 'node.exe' (BrokerLine 'lease-explicit' 'C:\repo-mixed') $leaseStart)
  (RecT 3101 1 'node.exe' (BrokerLine 'lease-unknown') ($leaseStart.AddSeconds(30)))
  (RecT 3110 1 'node.exe' 'node codex-companion.mjs adversarial-review --wait --base main' $leaseStart)
)
$unknownCwdLease = [pscustomobject]@{
  Token = 'lease-explicit'; ClientPid = 3110; ClientStartTime = $leaseStart.ToString('o')
  Cwd = 'C:\repo-mixed'; Heartbeat = $leaseNow.AddMinutes(-1).ToString('o')
}
$unknownCwdTreePids = Get-CodexBrokerTreePids -Procs $unknownCwdProcs
$unknownCwdOrphans = @((Get-CodexOrphanBrokers -Procs $unknownCwdProcs -BrokerTreePids $unknownCwdTreePids -ClientLeases @($unknownCwdLease) -NowUtc $leaseNow) | ForEach-Object { $_.BrokerPid })
$unknownCwdOutsideRenders = Get-UnattributedCodexAdversarialRenderPids -Procs $unknownCwdProcs -BrokerTreePids $unknownCwdTreePids -ClientLeases @($unknownCwdLease) -NowUtc $leaseNow
Check 'missing-cwd broker remains unleased candidate' ($unknownCwdOrphans -contains 3101) "got=$($unknownCwdOrphans -join ',')"
Check 'missing-cwd broker keeps Layer A deferral active' (Test-ShouldDeferCodexKill -OutsideRenderPids $unknownCwdOutsideRenders) "got=$($unknownCwdOutsideRenders -join ',')"

$staleLease = $freshLease.PSObject.Copy()
$staleLease.Heartbeat = $leaseNow.AddMinutes(-11).ToString('o')
$staleLeaseOrphans = @((Get-CodexOrphanBrokers -Procs $leaseProcs -ClientLeases @($staleLease) -NowUtc $leaseNow) | ForEach-Object { $_.BrokerPid })
Check 'stale lease older than TTL is ignored' ($staleLeaseOrphans -contains 1000) "got=$($staleLeaseOrphans -join ',')"
$unattributedStaleRenders = Get-UnattributedCodexAdversarialRenderPids -Procs $leaseProcs -BrokerTreePids $leaseTreePids -ClientLeases @($staleLease) -NowUtc $leaseNow
Check 'stale lease leaves Layer A global deferral active' (Test-ShouldDeferCodexKill -OutsideRenderPids $unattributedStaleRenders)

$deadLease = $freshLease.PSObject.Copy()
$deadLease.ClientPid = 9999
$deadLeaseOrphans = @((Get-CodexOrphanBrokers -Procs $leaseProcs -ClientLeases @($deadLease) -NowUtc $leaseNow) | ForEach-Object { $_.BrokerPid })
Check 'dead lease pid is ignored' ($deadLeaseOrphans -contains 1000) "got=$($deadLeaseOrphans -join ',')"

$mismatchLease = $freshLease.PSObject.Copy()
$mismatchLease.ClientStartTime = $leaseStart.AddMinutes(-5).ToString('o')
$mismatchLeaseOrphans = @((Get-CodexOrphanBrokers -Procs $leaseProcs -ClientLeases @($mismatchLease) -NowUtc $leaseNow) | ForEach-Object { $_.BrokerPid })
Check 'pid with mismatched StartTime is ignored' ($mismatchLeaseOrphans -contains 1000) "got=$($mismatchLeaseOrphans -join ',')"

$wrongCwdLease = $freshLease.PSObject.Copy()
$wrongCwdLease.Cwd = 'C:\repo-b'
$wrongCwdLeaseOrphans = @((Get-CodexOrphanBrokers -Procs $leaseProcs -ClientLeases @($wrongCwdLease) -NowUtc $leaseNow) | ForEach-Object { $_.BrokerPid })
Check 'cwd mismatch cannot attribute lease to token directory' ($wrongCwdLeaseOrphans -contains 1000) "got=$($wrongCwdLeaseOrphans -join ',')"

# Filesystem seam: the token comes from the broker directory, never from JSON.
$leaseTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-1474-" + [guid]::NewGuid().ToString('N'))
try {
  $leaseDir = Join-Path $leaseTemp 'cxc-lease-a'
  [void](New-Item -ItemType Directory -Path $leaseDir -Force)
  $leaseJson = [ordered]@{
    clientPid = 1010; clientStartTime = $leaseStart.ToString('o')
    cwd = 'C:\repo-a'; heartbeat = $leaseNow.AddMinutes(-1).ToString('o')
  } | ConvertTo-Json -Compress
  Set-Content -LiteralPath (Join-Path $leaseDir 'client-lease-1010-test.json') -Value $leaseJson -Encoding UTF8
  $loadedLeases = @(Get-CodexClientLeases -Procs $leaseProcs -TempRoot $leaseTemp)
  Check 'filesystem lease reader binds directory token' ($loadedLeases.Count -eq 1 -and $loadedLeases[0].Token -eq 'lease-a') "count=$($loadedLeases.Count)"
} finally {
  Remove-Item -LiteralPath $leaseTemp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Test 4: orphan TREE composition (broker + descendants) ------------------
Write-Host "Test 4: orphan tree = broker pid + full descendant walk"
$trees = @(Get-CodexOrphanTrees -Procs $procs)
$byPid = @{}
foreach ($t in $trees) { $byPid[[string]$t.BrokerPid] = $t }
Check 'two orphan trees'               ($trees.Count -eq 2) "got=$($trees.Count)"

$t200 = $byPid['200']
Check 'tree 200 includes broker 200'   ($t200.TreePids -contains 200)
Check 'tree 200 includes child 201'    ($t200.TreePids -contains 201)
Check 'tree 200 includes child 202'    ($t200.TreePids -contains 202)
Check 'tree 200 proc count = 3'        ($t200.TreeProcCount -eq 3) "got=$($t200.TreeProcCount)"
Check 'tree 200 token = bbb222'        ($t200.Token -eq 'bbb222')

$t400 = $byPid['400']
Check 'tree 400 includes 400,401,402'  (($t400.TreePids -join ',') -eq '400,401,402') "got=$($t400.TreePids -join ',')"
Check 'tree 400 proc count = 3'        ($t400.TreeProcCount -eq 3)

# cwd label is cosmetic but must be non-unknown for a real broker path.
Check 'tree 200 cwd derived (contains scripts)' ($t200.Cwd -match 'scripts') "got=$($t200.Cwd)"

# Childless orphan broker (freshly launched / partially reaped): TreePids must
# be exactly the broker itself - exercises the empty-descendant-array append
# path (@() + empty), a documented PowerShell unwrapping corner in this file.
$soloProcs = @( (Rec 800 1 'node.exe' (BrokerLine 'solo55')) )
$soloTrees = @(Get-CodexOrphanTrees -Procs $soloProcs)
Check 'childless orphan -> 1 tree'        ($soloTrees.Count -eq 1) "got=$($soloTrees.Count)"
Check 'childless orphan tree = broker only' (($soloTrees[0].TreePids -join ',') -eq '800') "got=$($soloTrees[0].TreePids -join ',')"
Check 'childless orphan proc count = 1'   ($soloTrees[0].TreeProcCount -eq 1)

# --- Test 5: descendant walk in isolation (root excluded) --------------------
Write-Host "Test 5: Get-DescendantPids walks downward, root excluded, cycle-safe"
$walkProcs = @(
  (Rec 700 1   'node.exe'  'broker')
  (Rec 701 700 'codex.exe' 'app-server')
  (Rec 702 700 'node.exe'  'mcp1')
  (Rec 703 702 'node.exe'  'mcp1-child')
)
$desc = @(Get-DescendantPids -Procs $walkProcs -RootPid 700)
$descSorted = @($desc | Sort-Object)
Check 'descendants of 700 = {701,702,703}' (($descSorted -join ',') -eq '701,702,703') "got=$($descSorted -join ',')"
Check 'root 700 excluded from descendants' (-not ($desc -contains 700))
$emptyDesc = @(Get-DescendantPids -Procs @() -RootPid 999)
Check 'empty table -> 0 descendants'   ($emptyDesc.Count -eq 0)
$leafDesc = @(Get-DescendantPids -Procs $walkProcs -RootPid 703)
Check 'leaf root -> 0 descendants'     ($leafDesc.Count -eq 0)
# PPID cycle THROUGH the root (pid-reuse artifact): the walk must terminate,
# the root must NOT appear in its own descendant list, and the cycle peer must
# appear exactly once (CR round 2 - the old dequeue-time guard re-added the
# root before the visited check fired).
$cycProcs = @(
  (Rec 710 720 'node.exe' 'cycle-a')
  (Rec 720 710 'node.exe' 'cycle-b')
)
$cycDesc = @(Get-DescendantPids -Procs $cycProcs -RootPid 710)
Check 'cycle: root NOT in own descendants' (-not ($cycDesc -contains 710)) "got=$($cycDesc -join ',')"
Check 'cycle: peer listed exactly once'    ((@($cycDesc | Where-Object { $_ -eq 720 })).Count -eq 1) "got=$($cycDesc -join ',')"
# Stale-PPID impostor (codex CR round 4): an unrelated process whose recorded
# PPID was recycled into a tree pid is OLDER than its claimed parent - the
# creation-time ordering filter must drop it, keep real (younger) children,
# and fail open when a CreationDate is missing for the kill-tree walk.
$tWalk = Get-Date '2026-07-11 03:00:00'
$ppidProcs = @(
  (RecT 730 1   'node.exe'   'walk-root'      $tWalk)
  (RecT 731 730 'node.exe'   'real-child'     ($tWalk.AddSeconds(5)))    # younger -> kin
  (RecT 732 730 'node.exe'   'ppid-impostor'  ($tWalk.AddSeconds(-300))) # older -> stale PPID
  (Rec  733 730 'node.exe'   'undated-child')                            # no CreationDate -> fail-open, kept
)
$ppidDesc = @(Get-DescendantPids -Procs $ppidProcs -RootPid 730)
Check 'younger real child kept'        ($ppidDesc -contains 731) "got=$($ppidDesc -join ',')"
Check 'stale-PPID impostor excluded'   (-not ($ppidDesc -contains 732)) "got=$($ppidDesc -join ',')"
Check 'kill-tree keeps undated child (fail-open)' ($ppidDesc -contains 733) "got=$($ppidDesc -join ',')"
$verifiedPpidDesc = @(Get-DescendantPids -Procs $ppidProcs -RootPid 730 -VerifiedEdgesOnly)
Check 'exclusion walk drops undated edge (fail-closed)' (-not ($verifiedPpidDesc -contains 733)) "got=$($verifiedPpidDesc -join ',')"

# --- Test 6: name allow-list filtering (kill-safety) -------------------------
Write-Host "Test 6: name allow-list (PID-reuse safety gate)"
Check 'node.exe allowed'               (Test-ProcessNameAllowed -Name 'node.exe')
Check 'node (no ext) allowed'          (Test-ProcessNameAllowed -Name 'node')
Check 'node_repl.exe allowed'          (Test-ProcessNameAllowed -Name 'node_repl.exe')
Check 'codex.exe allowed'              (Test-ProcessNameAllowed -Name 'codex.exe')
Check 'conhost.exe allowed'            (Test-ProcessNameAllowed -Name 'conhost.exe')
Check 'mcp-obsidian allowed'           (Test-ProcessNameAllowed -Name 'mcp-obsidian')
Check 'qmd allowed'                    (Test-ProcessNameAllowed -Name 'qmd')
Check 'firefox.exe NOT allowed'        (-not (Test-ProcessNameAllowed -Name 'firefox.exe'))
Check 'explorer.exe NOT allowed'       (-not (Test-ProcessNameAllowed -Name 'explorer.exe'))
Check 'Code.exe (VSCode) NOT allowed'  (-not (Test-ProcessNameAllowed -Name 'Code.exe'))
Check 'empty name NOT allowed'         (-not (Test-ProcessNameAllowed -Name ''))
# Case-insensitivity lock-in: this is the last gate before Stop-Process; a
# future case-sensitive comparer swap must fail here, not in production.
Check 'NODE.EXE allowed (case-insensitive)' (Test-ProcessNameAllowed -Name 'NODE.EXE')

# --- Test 6b: start-time identity check (codex-1 round 2) --------------------
Write-Host "Test 6b: Test-ProcessStartMatches (recycled-pid identity gate)"
$t0 = Get-Date '2026-07-11 03:00:00'
Check 'equal times match'              (Test-ProcessStartMatches -SnapshotCreation $t0 -LiveStart $t0)
Check 'within 2s tolerance matches'    (Test-ProcessStartMatches -SnapshotCreation $t0 -LiveStart $t0.AddSeconds(1.5))
Check '5s apart does NOT match'        (-not (Test-ProcessStartMatches -SnapshotCreation $t0 -LiveStart $t0.AddSeconds(5)))
Check '5s apart (negative) does NOT match' (-not (Test-ProcessStartMatches -SnapshotCreation $t0.AddSeconds(5) -LiveStart $t0))
Check 'null snapshot -> match (name gate only)' (Test-ProcessStartMatches -SnapshotCreation $null -LiveStart $t0)
Check 'null live -> match (name gate only)'     (Test-ProcessStartMatches -SnapshotCreation $t0 -LiveStart $null)

# --- Test 6b2: token path-safety gate (codex CR round 3) ---------------------
Write-Host "Test 6b2: Test-CxcTokenPathSafe (broker.pid path-join gate)"
Check 'plain token safe'               (Test-CxcTokenPathSafe -Token 'aaa111')
Check 'dashed token safe'              (Test-CxcTokenPathSafe -Token 'a1-b2_c3')
Check 'traversal token NOT safe'       (-not (Test-CxcTokenPathSafe -Token '..\..\evil'))
Check 'dotted token NOT safe'          (-not (Test-CxcTokenPathSafe -Token 'a.b'))
Check 'fwd-slash token NOT safe'       (-not (Test-CxcTokenPathSafe -Token 'a/b'))
Check 'empty token NOT safe'           (-not (Test-CxcTokenPathSafe -Token ''))

# --- Test 6c: blind-client visibility probe (silent-failure CR) --------------
Write-Host "Test 6c: Get-BlindClientPids (degraded CommandLine visibility)"
$tVis = Get-Date '2026-07-11 04:00:00'
$visProcs = @(
  (Rec 900 1   'claude.exe'  '')                       # plausible outside client, blind
  (Rec 901 1   'claude.exe'  (ClientRef 'tok9'))       # plausible client, visible
  (Rec 902 1   'ChatGPT.exe' $null)                    # plausible outside client, blind
  (Rec 903 1   'node.exe'    '')                       # detached companion could be client -> blind
  (Rec 904 1   'bun.exe'     $null)                    # plausible outside client, blind
  (Rec 905 1   'svchost.exe' '')                       # unrelated hidden SYSTEM proc -> ignored
  (RecT 920 1   'node.exe'    (BrokerLine 'blindtree') $tVis)
  (RecT 921 920 'node.exe'    '' ($tVis.AddSeconds(1))) # verified hidden broker descendant -> ignored
  (Rec  922 920 'node.exe'    '')                       # undated stale PPID -> outside, blind
)
# Raw assignment, no @() wrap / no pipe on the call itself: the function
# returns via unary comma (same contract as Get-CxcTokens - see the note at
# its call site) so the array survives assignment as ONE object.
$blindRaw = Get-BlindClientPids -Procs $visProcs
$blind = @($blindRaw | Sort-Object)
Check 'blind outside clients = {900,902,903,904,922}' (($blind -join ',') -eq '900,902,903,904,922') "got=$($blind -join ',')"
Check 'verified hidden broker descendant 921 excluded' (-not ($blind -contains 921)) "got=$($blind -join ',')"
Check 'undated stale-PPID plausible client 922 stays blind' ($blind -contains 922) "got=$($blind -join ',')"
Check 'unrelated hidden svchost 905 ignored' (-not ($blind -contains 905)) "got=$($blind -join ',')"
$noBlind = Get-BlindClientPids -Procs @( (Rec 901 1 'node.exe' (ClientRef 'tok9')) )
Check 'all-visible -> empty'           ($noBlind.Count -eq 0) "got count=$($noBlind.Count)"

# --- Test 6d: caller-path @() wrap regression (HIMMEL-930) -------------------
# Get-BlindClientPids is array-guaranteed by its own unary-comma return (Test
# 6c). That guarantee is worthless if the CALLER re-wraps the result in @():
# @() re-boxes an EMPTY inner array into a ONE-element wrapper, so the
# production caller's `$blindClients.Count` read 1 even with zero blind
# clients - the elevation/session-gap warning ALWAYS fired and -Kill ALWAYS
# refused (exit 1) on every machine, regardless of actual visibility. The
# harness has no Get-CimInstance mock to drive the production path end-to-end,
# so this pins the exact expression shape at both the source-text level (the
# caller line must not be @()-wrapped) and the behavioral level (unwrapped ==
# correct, @()-wrapped == the bug), so a regression back to @() is caught
# either way.
Write-Host "Test 6d: caller-path @() wrap regression (HIMMEL-930)"
$noBlindProcs = @( (Rec 901 1 'claude.exe' (ClientRef 'tok9')) )
$callerUnwrapped = Get-BlindClientPids -Procs $noBlindProcs
Check 'unwrapped caller expression: zero blind clients -> Count 0' ($callerUnwrapped.Count -eq 0) "got count=$($callerUnwrapped.Count)"
$callerOldWrap = @(Get-BlindClientPids -Procs $noBlindProcs)
Check 'OLD @()-wrapped expression on empty result -> Count 1 (documents the bug)' ($callerOldWrap.Count -eq 1) "got count=$($callerOldWrap.Count)"
$callerSrc = Get-Content -LiteralPath $Helper -Raw
Check 'production source: blindClients assignment is NOT @()-wrapped' `
  ($callerSrc -match '\$blindClients\s*=\s*Get-BlindClientPids' -and $callerSrc -notmatch '\$blindClients\s*=\s*@\(\s*Get-BlindClientPids') `
  'caller line regressed to the @() wrap'

# --- Test 6e: pr-check uses one lease-aware launcher at both render sites ------
Write-Host "Test 6e: pr-check launcher wiring (HIMMEL-1474 Layer B)"
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$PrCheck = Join-Path $RepoRoot '.claude\commands\pr-check.md'
$Runner = Join-Path $RepoRoot 'scripts\cr\run-codex-adversarial.sh'
$LeaseWriter = Join-Path $RepoRoot 'scripts\cr\codex-render-client-lease.ps1'
Check 'shared adversarial runner exists' (Test-Path -LiteralPath $Runner)
Check 'PowerShell lease writer exists' (Test-Path -LiteralPath $LeaseWriter)
$prCheckSrc = Get-Content -LiteralPath $PrCheck -Raw
$runnerRefs = [regex]::Matches($prCheckSrc, 'bash scripts/cr/run-codex-adversarial\.sh').Count
Check 'kickoff and retry both use shared runner' ($runnerRefs -eq 2) "got=$runnerRefs"
$runnerSrc = Get-Content -LiteralPath $Runner -Raw
Check 'runner starts client lease writer with translated client pid' `
  ($runnerSrc -match 'codex-render-client-lease\.ps1' -and $runnerSrc -match '-ClientPid \"\$lease_client_pid\"')

# --- Test 6f: execute the real writer and observe two heartbeats ---------------
# Source-grep coverage missed the read-only `$PID` binder collision. This starts
# a real node broker plus the real writer, then requires a write AND refresh so
# the Layer B heartbeat path executes past identity binding (HIMMEL-1474 r2).
Write-Host "Test 6f: lease writer executes and refreshes (HIMMEL-1474 r2)"
$writerIsWindows = Test-OnWindows -IsWindowsValue (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) -OsEnv $env:OS
if (-not $writerIsWindows) {
  Write-Host '  SKIP  lease writer execution test is Windows-only'
} else {
  $leaseToken = 'writer-r2-test'
  $leaseTestDir = Join-Path ([string]$env:TEMP) "cxc-$leaseToken"
  $brokerScript = Join-Path $leaseTestDir 'app-server-broker.mjs'
  # HIMMEL-1509 r2 regression (glm-2 critical): -LeaseDir must survive the
  # broker foreach. A local named $leaseDir case-insensitively CLOBBERED the
  # param after the first token iteration, so the SECOND registry heartbeat
  # landed in the cxc token dir and the registry lease starved past TTL.
  # Running with >=1 broker token and requiring TWO registry heartbeats
  # catches exactly that.
  $registryLeaseDir = Join-Path ([string]$env:TEMP) ("h1509-r2-lease-" + [System.IO.Path]::GetRandomFileName())
  $brokerProc = $null
  $writerProc = $null
  try {
    [void](New-Item -ItemType Directory -Path $leaseTestDir -Force)
    [void](New-Item -ItemType Directory -Path $registryLeaseDir -Force)
    Set-Content -LiteralPath $brokerScript -Value 'setInterval(() => {}, 1000);' -Encoding UTF8
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $brokerArgs = "$brokerScript serve --endpoint `"pipe:\\.\pipe\cxc-$leaseToken-codex-app-server`" --cwd `"$RepoRoot`""
    $brokerProc = Start-Process -FilePath $nodePath -ArgumentList $brokerArgs -WorkingDirectory $RepoRoot -NoNewWindow -PassThru
    $writerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$LeaseWriter`" -ClientPid $PID -HeartbeatSeconds 1 -LeaseDir `"$registryLeaseDir`""
    $writerProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $writerArgs -WorkingDirectory $RepoRoot -NoNewWindow -PassThru

    $leaseFile = $null
    $writeDeadline = [datetime]::UtcNow.AddSeconds(10)
    while (-not $leaseFile -and [datetime]::UtcNow -lt $writeDeadline) {
      Start-Sleep -Milliseconds 250
      $leaseFile = Get-ChildItem -LiteralPath $leaseTestDir -Filter 'client-lease-*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    Check 'writer creates a lease file' ($null -ne $leaseFile)

    $firstHeartbeat = $null
    if ($leaseFile) {
      try { $firstHeartbeat = (Get-Content -LiteralPath $leaseFile.FullName -Raw | ConvertFrom-Json).heartbeat } catch {}
    }
    $refreshedHeartbeat = $firstHeartbeat
    $refreshDeadline = [datetime]::UtcNow.AddSeconds(10)
    while ($firstHeartbeat -and $refreshedHeartbeat -eq $firstHeartbeat -and [datetime]::UtcNow -lt $refreshDeadline) {
      Start-Sleep -Milliseconds 250
      try { $refreshedHeartbeat = (Get-Content -LiteralPath $leaseFile.FullName -Raw | ConvertFrom-Json).heartbeat } catch {}
    }
    Check 'writer refreshes the heartbeat' ($firstHeartbeat -and $refreshedHeartbeat -ne $firstHeartbeat) "first=$firstHeartbeat refreshed=$refreshedHeartbeat"

    # HIMMEL-1509 r2: BOTH iterations above wrote a cxc lease for the broker
    # token, so with the $leaseDir collision the registry heartbeat would have
    # stopped advancing after the first write. Require it to advance too.
    $registryHbFile = Join-Path $registryLeaseDir 'heartbeat'
    $firstRegistryHb = $null
    $regDeadline = [datetime]::UtcNow.AddSeconds(10)
    while (-not $firstRegistryHb -and [datetime]::UtcNow -lt $regDeadline) {
      Start-Sleep -Milliseconds 250
      try { $firstRegistryHb = [string](Get-Content -LiteralPath $registryHbFile -Raw -ErrorAction Stop) } catch {}
    }
    Check 'writer creates the registry heartbeat' ($null -ne $firstRegistryHb)
    $refreshedRegistryHb = $firstRegistryHb
    $regDeadline = [datetime]::UtcNow.AddSeconds(10)
    while ($firstRegistryHb -and $refreshedRegistryHb -eq $firstRegistryHb -and [datetime]::UtcNow -lt $regDeadline) {
      Start-Sleep -Milliseconds 250
      try { $refreshedRegistryHb = [string](Get-Content -LiteralPath $registryHbFile -Raw -ErrorAction Stop) } catch {}
    }
    Check 'registry heartbeat advances across broker-token iterations (r2 collision)' `
      ($firstRegistryHb -and $refreshedRegistryHb -ne $firstRegistryHb) "first=$firstRegistryHb refreshed=$refreshedRegistryHb"
    $tokensFile = Join-Path $registryLeaseDir 'tokens'
    $tokensContent = ''
    try { $tokensContent = [string](Get-Content -LiteralPath $tokensFile -Raw -ErrorAction Stop) } catch {}
    Check 'writer records the observed broker token on the lease' ($tokensContent -match [regex]::Escape($leaseToken)) "tokens=$tokensContent"
    # And the registry writes must never leak into the cxc token dir (the
    # collision's failure mode wrote `heartbeat`/`tokens` files there).
    Check 'no registry files leak into the cxc token dir' `
      (-not (Test-Path -LiteralPath (Join-Path $leaseTestDir 'heartbeat')) -and -not (Test-Path -LiteralPath (Join-Path $leaseTestDir 'tokens')))
    # r9 codex-2: token protection ages out with reality - once the broker
    # dies, the next EMPTY observation removes the tokens file instead of
    # letting a stale token set keep protecting unrelated trees.
    if ($brokerProc -and -not $brokerProc.HasExited) { Stop-Process -Id $brokerProc.Id -Force -ErrorAction SilentlyContinue }
    $tokensGoneDeadline = [datetime]::UtcNow.AddSeconds(10)
    while ((Test-Path -LiteralPath $tokensFile) -and [datetime]::UtcNow -lt $tokensGoneDeadline) {
      Start-Sleep -Milliseconds 250
    }
    Check 'dead broker ages out the tokens file (r9)' (-not (Test-Path -LiteralPath $tokensFile))
  } finally {
    if ($writerProc -and -not $writerProc.HasExited) { Stop-Process -Id $writerProc.Id -Force -ErrorAction SilentlyContinue }
    if ($brokerProc -and -not $brokerProc.HasExited) { Stop-Process -Id $brokerProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $leaseTestDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $registryLeaseDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- Test 7: malformed argv fails fast (no hang, no production execution) ----
# PowerShell's parameter binder rejects unknown params / stray positionals
# BEFORE the script body runs, so these never reach Get-CimInstance or any kill
# path - safe to invoke as a real subprocess. Invokes the real script (never the
# dot-sourced functions) so a regression would surface as an actual hang, not an
# in-process exception. Stdin from an empty file so any interactive prompt gets
# immediate EOF.
Write-Host "Test 7: malformed argv fails fast (no hang, no body execution)"
function Test-FailsFast([string[]]$ExtraArgs, [string]$Name) {
  $inFile = [System.IO.Path]::GetTempFileName()
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Helper) + $ExtraArgs
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $psArgs `
      -NoNewWindow -PassThru -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $finished = $proc.WaitForExit(10000)
    if (-not $finished) {
      try { $proc.Kill() } catch {}
      Fail $Name 'timed out after 10s (hang)'
    } else {
      Check $Name ($proc.ExitCode -ne 0) "exit=$($proc.ExitCode)"
    }
  } finally {
    Remove-Item -Path $inFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}
Test-FailsFast @('-NonexistentFlag') 'unknown parameter fails fast (no hang)'
Test-FailsFast @('bogus-positional') 'stray positional fails fast (no hang)'

# --- Test 8: platform guard survives Windows PowerShell 5.1 (HIMMEL-1321) ----
Write-Host "Test 8: platform guard survives Windows PowerShell 5.1 (HIMMEL-1321)"
# $IsWindows is a PS6+ automatic variable. Under 5.1 it is UNDEFINED ($null), so a
# bare `-not $IsWindows` is TRUE and the sweep exits 0 as "non-Windows" on the
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

# --- Test 9: render-lease registry + kill-ledger (HIMMEL-1509) ---------------
Write-Host "Test 9: render-lease dispositions, kill filtering, kill-ledger (HIMMEL-1509)"

function LeaseRec($name, $worktree, $identity, $started, $heartbeat, $tokens, $unreadable) {
  [pscustomobject]@{
    Name = $name; Path = "X:\reg\$name"; Branch = $name; Worktree = $worktree
    LeaderIdentity = $identity; StartedAt = $started; Heartbeat = $heartbeat
    Tokens = $tokens; Unreadable = $unreadable
  }
}

$nowUtc = [datetime]::SpecifyKind([datetime]'2026-08-03T12:00:00', [System.DateTimeKind]::Utc)
$freshHb = '2026-08-03T11:55:00Z'
$staleHb = '2026-08-03T10:00:00Z'
$leaderStart = [datetime]::SpecifyKind([datetime]'2026-08-03T11:00:00', [System.DateTimeKind]::Utc)
$leaderIdentity = "win:900:$($leaderStart.Ticks)"

# Slug parity with render-lease.sh (r6 codex-2): identical +HH byte encoding,
# same expected literals as test-render-lease.sh, so the twins can never
# drift apart silently; the map is injective (aliasing branches diverge).
Check 'slug: slash encodes to +2F'       ((Get-RenderLeaseSlug -Branch 'feat/himmel-1509-x') -ceq 'feat+2Fhimmel-1509-x')
Check 'slug: literal plus escapes to +2B' ((Get-RenderLeaseSlug -Branch 'feat/a+b') -ceq 'feat+2Fa+2Bb')
Check 'slug: aliasing branches stay distinct' ((Get-RenderLeaseSlug -Branch 'feat/a/b') -ceq 'feat+2Fa+2Fb')
Check 'slug: hostile chars hex-encode per byte' ((Get-RenderLeaseSlug -Branch 'a b!c') -ceq 'a+20b+21c')
Check 'slug: deterministic' ((Get-RenderLeaseSlug -Branch 'feat/a+b') -ceq (Get-RenderLeaseSlug -Branch 'feat/a+b'))

# Identity-string parsing.
$parts = Get-RenderLeaseIdentityParts -Identity 'win:123:456'
Check 'win identity parses pid'    ($parts.WinPid -eq 123)
Check 'win identity parses ticks'  ($parts.StartTicks -eq 456)
Check 'posix identity -> $null'    ($null -eq (Get-RenderLeaseIdentityParts -Identity 'posix:Mon Aug 3 bash'))
Check 'empty identity -> $null'    ($null -eq (Get-RenderLeaseIdentityParts -Identity ''))

# lease.record parsing.
$map = ConvertFrom-RenderLeaseRecord -Lines @("branch`tfeat/x", "worktree`tC:\repo\wt", 'garbage-no-tab', "status`trunning")
Check 'record parses branch'   ($map['branch'] -eq 'feat/x')
Check 'record parses worktree' ($map['worktree'] -eq 'C:\repo\wt')
Check 'record skips tabless garbage' (-not $map.ContainsKey('garbage-no-tab'))

# Heartbeat freshness (sparing gate: future skew reads FRESH, never a kill).
Check 'fresh heartbeat is fresh'    (Test-RenderLeaseHeartbeatFresh -HeartbeatText $freshHb -NowUtc $nowUtc)
Check 'stale heartbeat is not'      (-not (Test-RenderLeaseHeartbeatFresh -HeartbeatText $staleHb -NowUtc $nowUtc))
Check 'future heartbeat reads fresh' (Test-RenderLeaseHeartbeatFresh -HeartbeatText '2026-08-03T12:30:00Z' -NowUtc $nowUtc)
Check 'garbage heartbeat is not fresh' (-not (Test-RenderLeaseHeartbeatFresh -HeartbeatText 'not-a-time' -NowUtc $nowUtc))

# Dispositions against a snapshot carrying the recorded leader.
$leaseProcs = @(
  (RecT 900 1 'node.exe' 'node codex-companion.mjs adversarial-review --wait --base main' $leaderStart)
  (RecT 901 1 'node.exe' 'node other.js' ($leaderStart.AddSeconds(100)))
  (Rec  902 1 'node.exe' 'node no-creation.js')
)
Check 'unreadable lease -> unverifiable' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l1' 'C:\repo\wtA' $leaderIdentity $staleHb $staleHb @() $true) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'unverifiable')
Check 'fresh heartbeat -> live' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l2' 'C:\repo\wtA' $leaderIdentity $staleHb $freshHb @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'live')
Check 'stale heartbeat + creation-matched leader -> live' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l3' 'C:\repo\wtA' $leaderIdentity $staleHb $staleHb @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'live')
Check 'stale heartbeat + absent leader -> stale' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l4' 'C:\repo\wtA' 'win:999:1' $staleHb $staleHb @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'stale')
Check 'stale heartbeat + recycled leader pid -> stale' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l5' 'C:\repo\wtA' "win:901:$($leaderStart.Ticks)" $staleHb $staleHb @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'stale')
Check 'leader without snapshot creation -> unverifiable' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l6' 'C:\repo\wtA' "win:902:$($leaderStart.Ticks)" $staleHb $staleHb @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'unverifiable')
Check 'leaderless record + fresh started_at -> live' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l7' 'C:\repo\wtA' '' $freshHb $null @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'live')
Check 'leaderless record + stale started_at -> unverifiable' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l8' 'C:\repo\wtA' '' $staleHb $null @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'unverifiable')
# r6 codex-1: a lease BOUND AFTER the snapshot has a leader the snapshot
# cannot contain - absence (or a pre-launch recycled pid) plus a FRESH record
# is live, not stale.
Check 'post-snapshot leader (absent) + fresh started_at -> live' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l9' 'C:\repo\wtA' 'win:555:1' $freshHb $staleHb @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'live')
Check 'post-snapshot leader (recycled snapshot pid) + fresh started_at -> live' `
  ((Get-RenderLeaseDisposition -Lease (LeaseRec 'l10' 'C:\repo\wtA' "win:901:$($leaderStart.Ticks)" $freshHb $staleHb @() $false) -Procs $leaseProcs -NowUtc $nowUtc) -eq 'live')

# Kill filtering over classified orphan trees: three orphan brokers, one per
# shape (leased cwd, other cwd, unresolvable cwd).
$tKill = Get-Date '2026-08-03 01:00:00'
$killProcs = @(
  (RecT 700 1 'node.exe' (BrokerLine 'tokA' 'C:\repo\wtA') $tKill)
  (RecT 710 1 'node.exe' (BrokerLine 'tokB' 'C:\repo\wtB') ($tKill.AddSeconds(1)))
  (RecT 720 1 'node.exe' (BrokerLine 'tokC') ($tKill.AddSeconds(2)))
)
$killTrees = @(Get-CodexOrphanTrees -Procs $killProcs)
Check 'kill fixture classifies three orphans' ($killTrees.Count -eq 3) "got=$($killTrees.Count)"

function ActionFor($actions, $token) {
  foreach ($a in @($actions)) { if ($a.Tree.Token -eq $token) { return "$($a.Action):$($a.Reason)" } }
  return '(missing)'
}

$noLease = @(Select-RenderLeaseKillActions -Trees $killTrees -Dispositions @() -Procs $killProcs)
Check 'no leases: every tree stays killable' ((@($noLease | Where-Object { $_.Action -eq 'kill' })).Count -eq 3)

$dispLiveA = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+a' 'C:\repo\wtA' $leaderIdentity $staleHb $freshHb @() $false)) -Procs $killProcs -NowUtc $nowUtc)
$actLiveA = @(Select-RenderLeaseKillActions -Trees $killTrees -Dispositions $dispLiveA -Procs $killProcs)
Check 'live lease spares its cwd tree'          ((ActionFor $actLiveA 'tokA') -eq 'spared:live-lease-cwd') "got=$(ActionFor $actLiveA 'tokA')"
Check 'live lease leaves other cwd killable'    ((ActionFor $actLiveA 'tokB') -eq 'kill:')
Check 'cwd-less broker defers under any lease'  ((ActionFor $actLiveA 'tokC') -eq 'deferred:unresolvable-broker-cwd')

$dispToken = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+x' 'C:\repo\wtX' $leaderIdentity $staleHb $freshHb @('tokB') $false)) -Procs $killProcs -NowUtc $nowUtc)
$actToken = @(Select-RenderLeaseKillActions -Trees $killTrees -Dispositions $dispToken -Procs $killProcs)
Check 'recorded token spares its tree regardless of cwd' ((ActionFor $actToken 'tokB') -eq 'spared:live-lease-token')
Check 'token spare leaves unrelated cwd killable'        ((ActionFor $actToken 'tokA') -eq 'kill:')

$dispUnvB = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+b' 'C:\repo\wtB' $leaderIdentity $staleHb $staleHb @() $true)) -Procs $killProcs -NowUtc $nowUtc)
$actUnvB = @(Select-RenderLeaseKillActions -Trees $killTrees -Dispositions $dispUnvB -Procs $killProcs)
Check 'unverifiable lease defers its cwd tree'   ((ActionFor $actUnvB 'tokB') -eq 'deferred:unverifiable-lease-cwd')
Check 'unverifiable lease leaves other cwd killable' ((ActionFor $actUnvB 'tokA') -eq 'kill:')

$dispUnvGlobal = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+g' $null $leaderIdentity $staleHb $staleHb @() $true)) -Procs $killProcs -NowUtc $nowUtc)
$actUnvGlobal = @(Select-RenderLeaseKillActions -Trees $killTrees -Dispositions $dispUnvGlobal -Procs $killProcs)
Check 'worktree-less unverifiable lease defers everything' ((@($actUnvGlobal | Where-Object { $_.Action -eq 'deferred' })).Count -eq 3)

$dispStale = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+s' 'C:\repo\wtA' 'win:999:1' $staleHb $staleHb @() $false)) -Procs $killProcs -NowUtc $nowUtc)
$actStale = @(Select-RenderLeaseKillActions -Trees $killTrees -Dispositions $dispStale -Procs $killProcs)
Check 'confirmed-stale lease leaves its cwd killable' ((ActionFor $actStale 'tokA') -eq 'kill:')

# Kill-ledger parsing: consumed records retire by pid+creation; malformed
# lines and unknown types are skipped.
$c1 = '2026-08-03T09:00:00.0000000Z'
$c2 = '2026-08-03T09:05:00.0000000Z'
$ledgerLines = @(
  ('{"type":"kill-failed","ts":"x","token":"tokA","pid":100,"name":"node","creation":"' + $c1 + '","reason":"stop-failed"}')
  ('{"type":"kill-failed","ts":"x","token":"tokB","pid":101,"name":"node","creation":"' + $c2 + '","reason":"stop-failed"}')
  ('{"type":"consumed","ts":"x","pid":100,"creation":"' + $c1 + '","reason":"swept"}')
  'not json at all'
  '{"type":"mystery","pid":5}'
)
$unconsumed = @(ConvertFrom-KillLedger -Lines $ledgerLines)
Check 'ledger returns only unconsumed entries' ($unconsumed.Count -eq 1) "got=$($unconsumed.Count)"
Check 'ledger keeps the unresolved pid'        ([int]$unconsumed[0].pid -eq 101)
Check 'empty ledger parses to empty'           ((@(ConvertFrom-KillLedger -Lines @())).Count -eq 0)

# Ledger entry vs live process: strict identity, fail-closed on any gap.
$entry = $unconsumed[0]
$entryCreationUtc = ([datetimeoffset]::Parse($c2)).UtcDateTime
Check 'creation-matched allow-listed live -> match' `
  ((Get-KillLedgerEntryLiveState -Entry $entry -LiveName 'node' -LiveStart $entryCreationUtc) -eq 'match')
Check 'creation mismatch -> recycled' `
  ((Get-KillLedgerEntryLiveState -Entry $entry -LiveName 'node' -LiveStart $entryCreationUtc.AddSeconds(100)) -eq 'recycled')
Check 'missing live start -> unverifiable' `
  ((Get-KillLedgerEntryLiveState -Entry $entry -LiveName 'node' -LiveStart $null) -eq 'unverifiable')
Check 'disallowed live name -> unverifiable' `
  ((Get-KillLedgerEntryLiveState -Entry $entry -LiveName 'explorer' -LiveStart $entryCreationUtc) -eq 'unverifiable')
$noCreation = [pscustomobject]@{ type = 'kill-failed'; pid = 102; name = 'node' }
Check 'entry without creation -> unverifiable' `
  ((Get-KillLedgerEntryLiveState -Entry $noCreation -LiveName 'node' -LiveStart $entryCreationUtc) -eq 'unverifiable')

# Replay guard (r2 codex-1): -FromLedger protection must match the main pass,
# not just recorded tokens - a TOKENLESS live lease still protects its
# worktree's brokers, and ambiguity fails closed.
$guardNone = Get-RenderLeaseReplayGuard -Dispositions @() -Procs $killProcs
Check 'replay guard: no leases -> no signal, nothing protected' `
  (-not $guardNone.AnySignal -and -not $guardNone.ProtectAll -and $guardNone.Tokens.Count -eq 0)
$dispTokenlessLive = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+a' 'C:\repo\wtA' $leaderIdentity $staleHb $freshHb @() $false)) -Procs $killProcs -NowUtc $nowUtc)
$guardTokenless = Get-RenderLeaseReplayGuard -Dispositions $dispTokenlessLive -Procs $killProcs
Check 'replay guard: tokenless live lease protects its cwd broker token' `
  ($guardTokenless.Tokens.Contains('tokA'))
Check 'replay guard: tokenless live lease protects ambiguous cwd-less broker' `
  ($guardTokenless.Tokens.Contains('tokC'))
Check 'replay guard: tokenless live lease leaves other cwd token killable' `
  (-not $guardTokenless.Tokens.Contains('tokB') -and -not $guardTokenless.ProtectAll -and $guardTokenless.AnySignal)
$dispRecordedTok = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+x' 'C:\repo\wtX' $leaderIdentity $staleHb $freshHb @('tokB') $false)) -Procs $killProcs -NowUtc $nowUtc)
$guardRecorded = Get-RenderLeaseReplayGuard -Dispositions $dispRecordedTok -Procs $killProcs
Check 'replay guard: recorded lease tokens stay protected' ($guardRecorded.Tokens.Contains('tokB'))
$dispStaleOnly = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+s' 'C:\repo\wtA' 'win:999:1' $staleHb $staleHb @() $false)) -Procs $killProcs -NowUtc $nowUtc)
$guardStale = Get-RenderLeaseReplayGuard -Dispositions $dispStaleOnly -Procs $killProcs
Check 'replay guard: confirmed-stale lease protects nothing' `
  (-not $guardStale.AnySignal -and $guardStale.Tokens.Count -eq 0)
$dispNoWorktree = @(Get-RenderLeaseDispositions -Leases @((LeaseRec 'feat+g' $null $leaderIdentity $staleHb $staleHb @() $true)) -Procs $killProcs -NowUtc $nowUtc)
$guardNoWorktree = Get-RenderLeaseReplayGuard -Dispositions $dispNoWorktree -Procs $killProcs
Check 'replay guard: worktree-less unverifiable lease protects everything' ($guardNoWorktree.ProtectAll)

# TTL parity with the launcher (r3 glm-4): RENDER_LEASE_TTL_SECS resolves to
# the sweep's freshness window; a heartbeat past the 10-min default but
# inside a raised env TTL must stay LIVE.
Check 'ttl resolver: unset -> 10min default'    ((Get-RenderLeaseTtlMinutes -EnvValue '') -eq 10)
Check 'ttl resolver: 1800s -> 30min'            ((Get-RenderLeaseTtlMinutes -EnvValue '1800') -eq 30)
Check 'ttl resolver: 90s rounds UP to 2min'     ((Get-RenderLeaseTtlMinutes -EnvValue '90') -eq 2)
Check 'ttl resolver: garbage -> default'        ((Get-RenderLeaseTtlMinutes -EnvValue 'abc') -eq 10)
Check 'ttl resolver: zero -> default'           ((Get-RenderLeaseTtlMinutes -EnvValue '0') -eq 10)
$agedHb = '2026-08-03T11:40:00Z'   # 20 min before $nowUtc
$agedLease = LeaseRec 'feat+aged' 'C:\repo\wtA' 'win:999:1' $agedHb $agedHb @() $false
Check 'aged heartbeat under default TTL falls through (leader gone -> stale)' `
  ((Get-RenderLeaseDisposition -Lease $agedLease -Procs $killProcs -NowUtc $nowUtc -TtlMinutes 10) -eq 'stale')
Check 'aged heartbeat inside a raised env TTL stays live' `
  ((Get-RenderLeaseDisposition -Lease $agedLease -Procs $killProcs -NowUtc $nowUtc -TtlMinutes (Get-RenderLeaseTtlMinutes -EnvValue '1800')) -eq 'live')

# Unconditional lock (r3 codex-1): a registry ABSENT at sweep start is
# created + locked, and a lease landing mid-pass is seen by the locked
# re-read and spares its tree - "missing registry" never skips the lock.
$lateReg = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-1509-late-" + [System.IO.Path]::GetRandomFileName())
$lateLock = $null
try {
  [void](New-Item -ItemType Directory -Force -Path $lateReg)
  $lateLock = Lock-RenderLeaseRegistry -RegistryPath $lateReg
  Check 'unconditional lock acquires on a just-created empty registry' ($null -ne $lateLock)
  $lateLease = Join-Path $lateReg 'feat+late'
  [void](New-Item -ItemType Directory -Force -Path $lateLease)
  Set-Content -LiteralPath (Join-Path $lateLease 'lease.record') -Value @("branch`tfeat/late", "worktree`tC:\repo\wtA", "leader_identity`t$leaderIdentity", "started_at`t$freshHb", "status`trunning")
  Set-Content -LiteralPath (Join-Path $lateLease 'heartbeat') -Value $freshHb -NoNewline
  $lateReads = @(Get-RenderLeaseRecords -RegistryPath $lateReg)
  Check 'locked re-read sees the mid-pass lease' ($lateReads.Count -eq 1) "got=$($lateReads.Count)"
  $lateDisp = @(Get-RenderLeaseDispositions -Leases $lateReads -Procs $killProcs -NowUtc $nowUtc)
  $lateActions = @(Select-RenderLeaseKillActions -Trees $killTrees -Dispositions $lateDisp -Procs $killProcs)
  Check 'mid-pass lease spares its tree under the lock' ((ActionFor $lateActions 'tokA') -eq 'spared:live-lease-cwd') "got=$(ActionFor $lateActions 'tokA')"
} finally {
  Remove-Item -LiteralPath $lateReg -Recurse -Force -ErrorAction SilentlyContinue
}
# Registry-lock stale-break disposition (r4 codex-1): a verified-live
# same-space owner is NEVER broken (age included); a confirmed-dead owner
# breaks immediately; cross-space keeps the age break.
$lockReg = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-1509-lock-" + [System.IO.Path]::GetRandomFileName())
try {
  [void](New-Item -ItemType Directory -Force -Path $lockReg)
  $lockDir = Join-Path $lockReg '.registry.lock'
  [void](New-Item -ItemType Directory -Force -Path $lockDir)
  Set-Content -LiteralPath (Join-Path $lockDir 'owner.pid') -Value "win:$PID"
  (Get-Item -LiteralPath $lockDir -Force).CreationTimeUtc = [datetime]'2020-01-01'
  $lockTry = Lock-RenderLeaseRegistry -RegistryPath $lockReg -Attempts 2 -DelayMs 10
  Check 'aged lock with verified-live owner is never age-broken' ($null -eq $lockTry)
  Check 'verified-live owner keeps its lock through contention' (Test-Path -LiteralPath $lockDir)
  Set-Content -LiteralPath (Join-Path $lockDir 'owner.pid') -Value 'win:999999999'
  (Get-Item -LiteralPath $lockDir -Force).CreationTimeUtc = [datetime]::UtcNow
  $lockTry = Lock-RenderLeaseRegistry -RegistryPath $lockReg -Attempts 2 -DelayMs 10
  Check 'young lock with confirmed-dead owner breaks immediately' ($null -ne $lockTry)
  Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
  [void](New-Item -ItemType Directory -Force -Path $lockDir)
  Set-Content -LiteralPath (Join-Path $lockDir 'owner.pid') -Value 'msys:123'
  $lockTry = Lock-RenderLeaseRegistry -RegistryPath $lockReg -Attempts 2 -DelayMs 10
  Check 'fresh cross-space owner is not broken' ($null -eq $lockTry)
  (Get-Item -LiteralPath $lockDir -Force).CreationTimeUtc = [datetime]'2020-01-01'
  $lockTry = Lock-RenderLeaseRegistry -RegistryPath $lockReg -Attempts 2 -DelayMs 10
  Check 'aged cross-space owner is age-broken' ($null -ne $lockTry)
  # Lock-stale env parity (r5 glm-2): RENDER_LEASE_LOCK_STALE_SECS resolves
  # through the same conversion as the TTL knob, and a cross-space lock aged
  # past the 10-min default but inside a raised env threshold is NOT broken.
  Check 'lock-stale resolver: unset -> 10min default' ((Get-RenderLeaseLockStaleMinutes -EnvValue '') -eq 10)
  Check 'lock-stale resolver: 1800s -> 30min'         ((Get-RenderLeaseLockStaleMinutes -EnvValue '1800') -eq 30)
  Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
  [void](New-Item -ItemType Directory -Force -Path $lockDir)
  Set-Content -LiteralPath (Join-Path $lockDir 'owner.pid') -Value 'msys:123'
  (Get-Item -LiteralPath $lockDir -Force).CreationTimeUtc = [datetime]::UtcNow.AddMinutes(-20)
  $lockTry = Lock-RenderLeaseRegistry -RegistryPath $lockReg -Attempts 2 -DelayMs 10 -StaleMinutes (Get-RenderLeaseLockStaleMinutes -EnvValue '1800')
  Check '20min-aged cross-space lock survives a raised env threshold' ($null -eq $lockTry)
  Check 'raised-threshold contention leaves the lock intact' (Test-Path -LiteralPath $lockDir)
  $lockTry = Lock-RenderLeaseRegistry -RegistryPath $lockReg -Attempts 2 -DelayMs 10 -StaleMinutes (Get-RenderLeaseLockStaleMinutes -EnvValue '')
  Check '20min-aged cross-space lock breaks under the default threshold' ($null -ne $lockTry)
  # r7 codex-1: owner-verified release - a broken-then-superseded holder must
  # never delete a successor's lock.
  Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
  [void](New-Item -ItemType Directory -Force -Path $lockDir)
  Set-Content -LiteralPath (Join-Path $lockDir 'owner.pid') -Value 'msys:123'
  Unlock-RenderLeaseRegistry -LockPath $lockDir
  Check 'unlock leaves a successor-owned lock intact' (Test-Path -LiteralPath $lockDir)
  Set-Content -LiteralPath (Join-Path $lockDir 'owner.pid') -Value "win:$PID"
  Unlock-RenderLeaseRegistry -LockPath $lockDir
  Check 'unlock removes this process''s own lock' (-not (Test-Path -LiteralPath $lockDir))
} finally {
  Remove-Item -LiteralPath $lockReg -Recurse -Force -ErrorAction SilentlyContinue
}

$helperSource = Get-Content -LiteralPath $Helper -Raw
Check 'both kill paths create the registry before locking' `
  (([regex]::Matches($helperSource, [regex]::Escape('reason=registry-unusable'))).Count -eq 2)
Check 'both production releases are owner-verified (r7)' `
  (([regex]::Matches($helperSource, [regex]::Escape('Unlock-RenderLeaseRegistry -LockPath $leaseLock'))).Count -eq 2)
Check 'FromLedger lock is no longer gated on registry existence' `
  (-not ($helperSource -match '\$Kill\s+-and\s+\(Test-Path\s+-LiteralPath\s+\$renderLeaseRegistry\)'))
Check 'main kill lock is no longer gated on registry existence' `
  (-not ($helperSource -match 'Test-Path[^\r\n]*renderLeaseRegistry[^\r\n]*\{\s*\r?\n\s*\$leaseLock\s*=\s*Lock-'))

# Registry IO reader: readable lease, unreadable lease, dotted dirs skipped.
$regRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-1509-reg-" + [System.IO.Path]::GetRandomFileName())
try {
  $goodDir = Join-Path $regRoot 'feat+good'
  [void](New-Item -ItemType Directory -Force -Path $goodDir)
  Set-Content -LiteralPath (Join-Path $goodDir 'lease.record') -Value @("branch`tfeat/good", "worktree`tC:\repo\wtA", "leader_identity`t$leaderIdentity", "started_at`t$staleHb", "status`trunning")
  Set-Content -LiteralPath (Join-Path $goodDir 'heartbeat') -Value $freshHb -NoNewline
  Set-Content -LiteralPath (Join-Path $goodDir 'tokens') -Value @('tokA', 'tokB')
  $badDir = Join-Path $regRoot 'feat+bad'
  [void](New-Item -ItemType Directory -Force -Path $badDir)
  [void](New-Item -ItemType Directory -Force -Path (Join-Path $regRoot '.registry.lock'))
  $reads = @(Get-RenderLeaseRecords -RegistryPath $regRoot)
  Check 'registry reader returns both leases, skips dotted dirs' ($reads.Count -eq 2) "got=$($reads.Count)"
  $good = @($reads | Where-Object { $_.Name -eq 'feat+good' })[0]
  $bad = @($reads | Where-Object { $_.Name -eq 'feat+bad' })[0]
  Check 'readable lease carries branch'    ($good.Branch -eq 'feat/good')
  Check 'readable lease carries worktree'  ($good.Worktree -eq 'C:\repo\wtA')
  Check 'readable lease carries heartbeat' (([string]$good.Heartbeat).Trim() -eq $freshHb)
  Check 'readable lease carries tokens'    ((@($good.Tokens) -join ',') -eq 'tokA,tokB')
  Check 'recordless lease reads unreadable' ($bad.Unreadable)
  Check 'unreadable lease disposes unverifiable' `
    ((Get-RenderLeaseDisposition -Lease $bad -Procs $killProcs -NowUtc $nowUtc) -eq 'unverifiable')
  Check 'absent registry reads empty' ((@(Get-RenderLeaseRecords -RegistryPath (Join-Path $regRoot 'nope'))).Count -eq 0)
} finally {
  Remove-Item -LiteralPath $regRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
