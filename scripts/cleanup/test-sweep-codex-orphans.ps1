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

# Fixture command lines derive from the running user's profile dir (no literal
# home paths in source - the propagation leak scan fail-closes on them).
$UserHome = $env:USERPROFILE
function BrokerLine($token) {
  "node $UserHome\.claude\plugins\cache\openai-codex\codex\1.0.5\scripts\app-server-broker.mjs serve --endpoint pipe:\\.\pipe\cxc-$token-codex-app-server"
}
function ClientRef($token) {
  # A client (claude.exe / ChatGPT.exe) connects to the broker's named pipe;
  # its command line carries the same pipe-name fragment.
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

# --- Test 2: broker / client predicates --------------------------------------
Write-Host "Test 2: broker + client predicate classification"
Check 'broker is a broker'              (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' $bl))
Check 'plain node NOT a broker'         (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' 'node other.js')))
Check 'broker.mjs without serve NOT broker' (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' "node x\app-server-broker.mjs")))
Check 'broker.mjs without pipe NOT broker'  (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'node.exe' "node x\app-server-broker.mjs serve --endpoint elsewhere")))
Check 'non-node NOT a broker'           (-not (Test-IsCodexAppServerBroker -Proc (Rec 1 0 'python.exe' $bl)))
Check 'claude.exe is a client'          (Test-IsCodexAppServerClient -Proc (Rec 2 0 'claude.exe' 'anything'))
Check 'ChatGPT.exe is a client'         (Test-IsCodexAppServerClient -Proc (Rec 2 0 'ChatGPT.exe' 'anything'))
Check 'node.exe NOT a client'           (-not (Test-IsCodexAppServerClient -Proc (Rec 2 0 'node.exe' 'anything')))
Check 'codex.exe NOT a client (lives in-tree)' (-not (Test-IsCodexAppServerClient -Proc (Rec 2 0 'codex.exe' 'anything')))

# --- Test 3: live/orphan classification on a synthetic table -----------------
# The four guards the algorithm hinges on:
#   (a) live  = client holds the token           -> NOT orphan
#   (b) orphan = no client holds the token       -> orphan
#   (c) dead-parent is a FALSE signal            -> client holding wins, NOT orphan
#   (d) codex.exe descendant is NOT sufficient   -> still orphan with no client
Write-Host "Test 3: live/orphan classification (client-pipe test; dead-parent + codex.exe guards)"
$procs = @(
  # (a) LIVE: broker 100 token aaa111, client 110 holds aaa111.
  (Rec 100 1   'node.exe'   (BrokerLine 'aaa111'))
  (Rec 110 1   'claude.exe' (ClientRef 'aaa111'))   # holds the pipe -> broker LIVE

  # (b) ORPHAN: broker 200 token bbb222, NO client holds bbb222.
  (Rec 200 1   'node.exe'   (BrokerLine 'bbb222'))
  (Rec 201 200 'codex.exe'  'codex.exe app-server') # in-tree, irrelevant to liveness
  (Rec 202 200 'node.exe'   'node mcp-fleet.js')    # in-tree descendant

  # (c) dead-parent FALSE SIGNAL: broker 300 has DEAD parent (999 absent) BUT
  #     client 310 holds ccc333 -> MUST be LIVE (dead-parent must not reap it).
  (Rec 300 999 'node.exe'   (BrokerLine 'ccc333'))
  (Rec 310 1   'ChatGPT.exe' (ClientRef 'ccc333'))  # holds the pipe -> LIVE despite dead parent

  # (d) codex.exe-descendant NOT sufficient: broker 400 token ddd444 has a
  #     codex.exe descendant but NO outside client -> MUST be ORPHAN.
  (Rec 400 1   'node.exe'   (BrokerLine 'ddd444'))
  (Rec 401 400 'codex.exe'  'codex.exe app-server') # in-tree, cannot mark live
  (Rec 402 401 'node.exe'   'node mcp.js')           # grandchild

  # Non-broker node must never be a candidate.
  (Rec 500 1   'node.exe'   'node playwright-mcp.js')
)

$orphanBrokers = @(Get-CodexOrphanBrokers -Procs $procs)
$obPids = @($orphanBrokers | ForEach-Object { $_.BrokerPid } | Sort-Object)
Check 'orphan brokers = {200,400}'     (($obPids -join ',') -eq '200,400') "got=$($obPids -join ',')"
Check 'live broker 100 excluded'       (-not ($obPids -contains 100))
Check 'dead-parent-but-held 300 excluded' (-not ($obPids -contains 300))
Check 'non-broker node 500 excluded'   (-not ($obPids -contains 500))

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
# and fail open when a CreationDate is missing.
function RecT($procId, $parentId, $name, $cl, $created) {
  [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $parentId; Name = $name; CommandLine = $cl; CreationDate = $created }
}
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
Check 'undated child kept (fail-open)' ($ppidDesc -contains 733) "got=$($ppidDesc -join ',')"

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
$visProcs = @(
  (Rec 900 1 'claude.exe'  '')                       # client, INVISIBLE cmdline -> blind
  (Rec 901 1 'claude.exe'  (ClientRef 'tok9'))       # client, visible -> not blind
  (Rec 902 1 'ChatGPT.exe' $null)                    # client, null cmdline -> blind
  (Rec 903 1 'node.exe'    '')                       # NOT a client -> ignored
)
# Raw assignment, no @() wrap / no pipe on the call itself: the function
# returns via unary comma (same contract as Get-CxcTokens - see the note at
# its call site) so the array survives assignment as ONE object.
$blindRaw = Get-BlindClientPids -Procs $visProcs
$blind = @($blindRaw | Sort-Object)
Check 'blind clients = {900,902}'      (($blind -join ',') -eq '900,902') "got=$($blind -join ',')"
$noBlind = Get-BlindClientPids -Procs @( (Rec 901 1 'claude.exe' (ClientRef 'tok9')) )
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

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
