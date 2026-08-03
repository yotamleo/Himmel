# sweep-codex-orphans.ps1 (HIMMEL-892) - report/sweep ORPHANED Codex
# app-server-broker daemon TREES via the client-side pipe-token liveness test.
#
# WHY: the openai-codex plugin's app-server-broker.mjs daemon spawns a whole
# tree per client connection (broker node -> codex.exe app-server -> a fleet of
# node_repl / uvx / bun MCP servers) keyed by a named pipe
# `\\.\pipe\cxc-<token>-codex-app-server`, and does NOT tear the tree down when
# the client disconnects without a clean exit. Repeated claude/codex sessions
# pile up leaked broker trees. On 2026-07-11 twelve orphaned trees (510 procs /
# ~3.8 GB) were found and hand-killed on this Windows box. This tool is the
# reusable sweep.
#
# THE TEST (client-side liveness - validated pipe token + pr-check lease):
#   A broker tree is LIVE iff either (a) a process OUTSIDE every broker tree has
#   a command line referencing the same `cxc-<token>-codex-app-server` pipe, or
#   (b) its TEMP directory has a fresh pr-check lease whose pid + StartTime
#   identifies a live outside-tree process and whose cwd matches the broker.
#   An unattributed outside-tree adversarial render defers the whole -Kill pass.
#
#   Two signals are DELIBERATELY NOT used, because they are documented false
#   signals on this fleet (HIMMEL-718):
#     * Dead-parent is NOT sufficient. The broker + its codex.exe app-server
#       routinely have a DEAD parent process while remaining LIVE and in use
#       (claude.exe spawns them through a chain that has already exited). Killing
#       by dead-parent alone reaps live, in-use trees. Do NOT do it.
#     * A codex.exe descendant is NOT sufficient. codex.exe lives INSIDE the
#       broker tree; it is present whether or not a client is still attached, so
#       it can never distinguish live from orphan. Only an OUTSIDE process
#       holding the pipe can; its image name is not part of the signal.
#   This tool is the complement of scripts/codex/reap-mcp-fleet.ps1: that one
#   reaps MCP FLEETS under a dead app-server via codex-lineage fingerprints;
#   this one reaps the BROKER TREES themselves via the client-pipe test.
#
# ALGORITHM:
#   1. Enumerate node.exe processes whose CommandLine matches
#      `app-server-broker.mjs serve --endpoint pipe:\\.\pipe\cxc-<token>-codex-app-server`;
#      capture the cxc token per broker.
#   2. Build the union of every broker tree, then collect outside-tree token
#      references plus fresh per-tree client leases. Excluding all broker roots
#      and descendants prevents their own arguments from self-marking live. An
#      outside adversarial render not covered by a valid lease defers -Kill.
#      A broker whose token has neither signal is an ORPHAN.
#   3. For each orphan broker, walk descendants via CIM Win32_Process
#      ParentProcessId (child map built once) to collect the full tree
#      (broker + all descendants).
#   4. Default = DRY RUN: print a table (broker PID, cwd from command line,
#      tree proc count, tree WS MB) + the flat PID list + a summary line.
#      -Kill actually stops them, NAME- and IDENTITY-VERIFIED: a PID is
#      stopped only if its ProcessName (base name, .exe stripped, case-
#      insensitive) is in the allow set below AND its live StartTime matches
#      the enumeration snapshot's CreationDate - PID-reuse safety against
#      recycling into an unrelated image AND into another allow-listed image.
#      -Kill REFUSES to run (exit 1) when any plausible outside client image
#      (claude.exe, ChatGPT.exe, node.exe, bun.exe) has no visible CommandLine.
#      Cross-session processes of unrelated names are routinely invisible and
#      do not disable the sweep.
#   5. -Kill also removes stale `$env:TEMP\cxc-<token>\broker.pid` files whose
#      token belonged to a swept tree AND whose broker was confirmed stopped.
#   Allow set (name-verified kill): node, cmd, bash, codex, conhost, pwsh,
#   python, bun, uv, uvx, node_repl, mcp-obsidian, qmd, tokensave.
#
# RENDER-LEASE REGISTRY (HIMMEL-1509 - replaces the retired :00 launch-window
# rule with dynamic coordination): before ANY kill, the sweep takes the
# registry lock and reads the per-branch render leases that
# run-codex-adversarial.sh acquires (see scripts/lib/render-lease.sh). A LIVE
# lease (fresh heartbeat, or a leader pid whose snapshot creation time matches
# the recorded win:<pid>:<startticks> identity) makes every broker tree in its
# worktree - and every token its heartbeat recorded - UNTOUCHABLE regardless
# of command-line visibility. An UNVERIFIABLE lease defers its trees
# (fail-closed); only a confirmed-STALE lease leaves its trees as ordinary
# candidates, still subject to every name/token/identity gate below. An
# unreadable registry or unavailable lock refuses the kill pass outright.
#
# KILL-LEDGER (HIMMEL-1509): verified orphan pids the -Kill pass could NOT
# stop (e.g. Stop-Process refusals such as the HIMMEL-1508 Session-0 gap) are
# appended to an append-only JSONL ledger next to the registry. Later sweep
# runs consume resolved entries; `-FromLedger` is the sanctioned orchestrator
# consume path - it kills ONLY entries whose live process still matches the
# recorded creation-time identity and the name allow set, and skips anything
# a live/unverifiable lease protects.
#
# USAGE:
#   pwsh -NoProfile -File scripts/cleanup/sweep-codex-orphans.ps1           # dry run (default): report orphan trees
#   pwsh -NoProfile -File scripts/cleanup/sweep-codex-orphans.ps1 -Kill     # lease-validated name-verified stop + stale broker.pid cleanup
#   pwsh -NoProfile -File scripts/cleanup/sweep-codex-orphans.ps1 -FromLedger        # list unconsumed kill-ledger entries (dry run)
#   pwsh -NoProfile -File scripts/cleanup/sweep-codex-orphans.ps1 -FromLedger -Kill  # identity-verified ledger consume (orchestrator path)
# -RegistryPath / -LedgerPath override the render-lease registry and ledger
# locations (default: $env:RENDER_LEASE_DIR or
# $env:USERPROFILE\.claude\handover\bridge\render-leases, ledger
# kill-ledger.jsonl inside it).
# Exit codes: 0 = nothing to sweep OR sweep done (prints count + estimated MB);
#             1 = usage / enumeration error, or the render-lease registry
#                 refused the kill pass (lock unavailable / unreadable).
# Non-Windows: exits 0 with a message (the broker leak is a Windows-observed
# pattern; the pure functions still dot-source-load for cross-platform tests).

# PositionalBinding=$false (HIMMEL-1509): the string params below must never
# swallow a stray positional argument - malformed argv keeps failing fast.
[CmdletBinding(PositionalBinding = $false)]
param(
  [switch]$Kill,
  # HIMMEL-1509 orchestrator consume path: act on the kill-ledger instead of
  # classifying; -Kill upgrades it from listing to identity-verified stopping.
  [switch]$FromLedger,
  [string]$RegistryPath,
  [string]$LedgerPath,
  # Dot-source seam for the hermetic test: define the pure functions, then
  # return WITHOUT scanning the live process table or touching the OS.
  [switch]$AsLibrary
)

# --- pure helpers (fed records / strings; unit-tested directly) ---------------

# Tokens look like `cxc-<token>-codex-app-server`. The bare `<token>` is the
# identity: the pipe is `cxc-<token>-codex-app-server`, the per-tree TEMP dir is
# `cxc-<token>`. Returns the list of bare tokens found in the line (a client
# cmdline could in principle reference more than one).
function Get-CxcTokens {
  param([string]$CommandLine)
  if (-not $CommandLine) { return , ([string[]]@()) }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($m in [regex]::Matches($CommandLine, 'cxc-(\S+?)-codex-app-server')) {
    [void]$out.Add($m.Groups[1].Value)
  }
  # Unary comma: return the array AS ONE object so an empty/single-element
  # result is not unraveled to $null / a scalar by the pipeline (StrictMode-safe
  # .Count at callers).
  return , ($out.ToArray())
}

# First bare token in the line, or $null. Convenience over Get-CxcTokens.
# NB: NO @() wrap on the call - Get-CxcTokens returns via unary comma so the
# array survives raw assignment (wrapping it in @() would re-box it into a
# 1-element wrapper and break the empty check).
function Get-CxcToken {
  param([string]$CommandLine)
  $all = Get-CxcTokens -CommandLine $CommandLine
  if ($all.Count -eq 0) { return $null }
  return [string]$all[0]
}

# Broker = node.exe launched as `app-server-broker.mjs serve ...` with a pipe.
function Test-IsCodexAppServerBroker {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name) { return $false }
  if ($Proc.Name -ine 'node.exe') { return $false }
  $cl = [string]$Proc.CommandLine
  if (-not ($cl -match 'app-server-broker\.mjs\s+serve')) { return $false }
  return ($null -ne (Get-CxcToken -CommandLine $cl))
}

# Plausible outside-client IMAGE for the degraded-visibility fail-safe. This is
# deliberately broader than the original desktop-only set because detached
# codex-companion renders are node.exe clients (HIMMEL-1467). It is NOT the
# liveness classifier: every visible outside-tree process is searched by token.
function Test-IsPlausibleCodexAppServerClient {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name) { return $false }
  return @('claude.exe','ChatGPT.exe','node.exe','bun.exe') -contains [string]$Proc.Name
}

# Render shape visible even when the companion argv does not carry its cxc token.
# Any such process outside every broker tree is fail-safe evidence that attribution
# may be incomplete, so -Kill defers the whole pass (Layer A, HIMMEL-1474).
function Test-IsCodexAdversarialRender {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name -or $Proc.Name -ine 'node.exe') { return $false }
  $cl = [string]$Proc.CommandLine
  return ($cl -match 'codex-companion\.mjs' -and $cl -match '(?:^|\s)adversarial-review(?:\s|$)' -and $cl -match '(?:^|\s)--wait(?:\s|$)')
}

function Get-OutsideCodexAdversarialRenderPids {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [AllowNull()]$BrokerTreePids = $null
  )
  if ($null -eq $BrokerTreePids) { $BrokerTreePids = Get-CodexBrokerTreePids -Procs $Procs }
  $out = New-Object System.Collections.ArrayList
  foreach ($p in $Procs) {
    if ($BrokerTreePids.Contains([int]$p.ProcessId)) { continue }
    if (Test-IsCodexAdversarialRender -Proc $p) { [void]$out.Add([int]$p.ProcessId) }
  }
  return , ($out.ToArray())
}

function Test-ShouldDeferCodexKill {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OutsideRenderPids)
  return ($OutsideRenderPids.Count -gt 0)
}

# Best-effort cwd LABEL for the table (purely cosmetic, never gates a decision).
# Prefers an explicit --cwd, else derives the broker.mjs script directory.
function Get-BrokerCwd {
  param([string]$CommandLine)
  if (-not $CommandLine) { return '(unknown)' }
  if ($CommandLine -match '(?:^|\s)--cwd[ =](?:"([^"]+)"|(\S+))') {
    if ($Matches[1]) { return $Matches[1] }
    return $Matches[2]
  }
  if ($CommandLine -match '(\S*app-server-broker\.mjs)') {
    try { return [System.IO.Path]::GetDirectoryName($Matches[1]) } catch { return $Matches[1] }
  }
  return '(unknown)'
}

# Lease attribution is deliberately stricter than the cosmetic table label:
# only an explicit broker --cwd can bind a pr-check client lease to that tree.
function Get-BrokerLeaseCwd {
  param([string]$CommandLine)
  if (-not $CommandLine) { return $null }
  if ($CommandLine -match '(?:^|\s)--cwd[ =](?:"([^"]+)"|(\S+))') {
    if ($Matches[1]) { return $Matches[1] }
    return $Matches[2]
  }
  return $null
}

function Test-PathEquivalent {
  param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd([char[]]@('\','/'))
    $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd([char[]]@('\','/'))
    return [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Test-PathResolvable {
  param([AllowNull()][string]$Path)
  if (-not $Path) { return $false }
  try { [void][System.IO.Path]::GetFullPath($Path); return $true } catch { return $false }
}

# Tokens referenced by at least one visible process OUTSIDE every broker tree.
# Image names are irrelevant to liveness: detached codex-companion node.exe is
# a real client. The exclusion is essential because each broker's own argv and
# its codex.exe descendants can reference the token after the real client dies.
function Get-LiveClientTokens {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)]$BrokerTreePids
  )
  $set = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($p in $Procs) {
    if ($BrokerTreePids.Contains([int]$p.ProcessId)) { continue }
    foreach ($t in (Get-CxcTokens -CommandLine ([string]$p.CommandLine))) { [void]$set.Add($t) }
  }
  return , ([string[]]@($set))
}

# A lease is valid only while all identity signals agree: fresh heartbeat, an
# explicit cwd matching the broker, and a live outside-tree pid whose snapshot
# CreationDate matches the recorded StartTime. Missing identity data fails
# closed (ignore the lease); a lease may only subtract from the kill set.
function Test-LeaseProcessStartMatches {
  param($SnapshotCreation, $LeaseStart)
  if ($null -eq $SnapshotCreation -or $null -eq $LeaseStart) { return $false }
  try {
    $snapshotUtc = ([datetime]$SnapshotCreation).ToUniversalTime()
    $leaseUtc = ([datetimeoffset]::Parse([string]$LeaseStart)).UtcDateTime
    return ([math]::Abs(($snapshotUtc - $leaseUtc).TotalSeconds) -le 2)
  } catch { return $false }
}

function Get-LiveClientLeaseEvidence {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)]$BrokerTreePids,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ClientLeases,
    [datetime]$NowUtc = [datetime]::UtcNow,
    [int]$LeaseTtlMinutes = 10
  )
  $out = New-Object System.Collections.ArrayList
  $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  if ($LeaseTtlMinutes -le 0) { return $out.ToArray() }

  $byPid = @{}
  foreach ($p in $Procs) { $byPid[[string]$p.ProcessId] = $p }
  $brokersByToken = @{}
  foreach ($p in $Procs) {
    if (-not (Test-IsCodexAppServerBroker -Proc $p)) { continue }
    $token = Get-CxcToken -CommandLine ([string]$p.CommandLine)
    $cwd = Get-BrokerLeaseCwd -CommandLine ([string]$p.CommandLine)
    if ($token -and $cwd) { $brokersByToken[[string]$token] = [string]$cwd }
  }

  foreach ($lease in $ClientLeases) {
    $tokenProp = $lease.PSObject.Properties['Token']
    $pidProp = $lease.PSObject.Properties['ClientPid']
    $startProp = $lease.PSObject.Properties['ClientStartTime']
    $cwdProp = $lease.PSObject.Properties['Cwd']
    $heartbeatProp = $lease.PSObject.Properties['Heartbeat']
    if (-not $tokenProp -or -not $pidProp -or -not $startProp -or -not $cwdProp -or -not $heartbeatProp) { continue }

    $token = [string]$tokenProp.Value
    if (-not $brokersByToken.ContainsKey($token)) { continue }
    if (-not (Test-PathEquivalent -Left ([string]$cwdProp.Value) -Right ([string]$brokersByToken[$token]))) { continue }

    $heartbeatUtc = $null
    try { $heartbeatUtc = ([datetimeoffset]::Parse([string]$heartbeatProp.Value)).UtcDateTime } catch { continue }
    $age = ($NowUtc.ToUniversalTime() - $heartbeatUtc).TotalMinutes
    if ($age -lt 0 -or $age -gt $LeaseTtlMinutes) { continue }

    $clientPid = 0
    try { $clientPid = [int]$pidProp.Value } catch { continue }
    if ($clientPid -le 0 -or $BrokerTreePids.Contains($clientPid)) { continue }
    $client = $byPid[[string]$clientPid]
    if ($null -eq $client) { continue }
    $creationProp = $client.PSObject.Properties['CreationDate']
    if (-not $creationProp) { continue }
    if (-not (Test-LeaseProcessStartMatches -SnapshotCreation $creationProp.Value -LeaseStart $startProp.Value)) { continue }
    $key = "$token|$clientPid"
    if ($seen.Add($key)) {
      [void]$out.Add([pscustomobject]@{
        Token = $token; ClientPid = $clientPid; Cwd = [string]$cwdProp.Value
      })
    }
  }
  return $out.ToArray()
}

function Get-LiveClientLeaseTokens {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)]$BrokerTreePids,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ClientLeases,
    [datetime]$NowUtc = [datetime]::UtcNow,
    [int]$LeaseTtlMinutes = 10
  )
  $set = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($evidence in @(Get-LiveClientLeaseEvidence -Procs $Procs -BrokerTreePids $BrokerTreePids -ClientLeases $ClientLeases -NowUtc $NowUtc -LeaseTtlMinutes $LeaseTtlMinutes)) {
    [void]$set.Add([string]$evidence.Token)
  }
  return , ([string[]]@($set))
}

# A render lease suppresses Layer A only when it covers EVERY broker in the
# leased cwd. The writer scans once per heartbeat, so a broker born after that
# scan is deliberately still ambiguous and must defer -Kill (HIMMEL-1474 r2).
# HIMMEL-1474 r3: a broker without a resolvable explicit cwd is equally
# ambiguous; no path signal proves it belongs outside the active render.
function Get-UnattributedCodexAdversarialRenderPids {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [AllowNull()]$BrokerTreePids = $null,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ClientLeases,
    [datetime]$NowUtc = [datetime]::UtcNow,
    [int]$LeaseTtlMinutes = 10
  )
  if ($null -eq $BrokerTreePids) { $BrokerTreePids = Get-CodexBrokerTreePids -Procs $Procs }
  $outsideRenderPids = Get-OutsideCodexAdversarialRenderPids -Procs $Procs -BrokerTreePids $BrokerTreePids
  $leaseEvidence = @(Get-LiveClientLeaseEvidence -Procs $Procs -BrokerTreePids $BrokerTreePids -ClientLeases $ClientLeases -NowUtc $NowUtc -LeaseTtlMinutes $LeaseTtlMinutes)
  $brokers = @($Procs | Where-Object { Test-IsCodexAppServerBroker -Proc $_ })
  $out = New-Object System.Collections.ArrayList

  foreach ($renderPid in $outsideRenderPids) {
    $renderEvidence = @($leaseEvidence | Where-Object { [int]$_.ClientPid -eq [int]$renderPid })
    if ($renderEvidence.Count -eq 0) {
      [void]$out.Add([int]$renderPid)
      continue
    }

    $coveredTokens = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($evidence in $renderEvidence) { [void]$coveredTokens.Add([string]$evidence.Token) }
    $hasUnleasedSameCwdBroker = $false
    foreach ($broker in $brokers) {
      $brokerCwd = Get-BrokerLeaseCwd -CommandLine ([string]$broker.CommandLine)
      if (-not (Test-PathResolvable -Path $brokerCwd)) {
        $hasUnleasedSameCwdBroker = $true
        break
      }
      $sharesLeasedCwd = $false
      foreach ($evidence in $renderEvidence) {
        if (Test-PathEquivalent -Left $brokerCwd -Right ([string]$evidence.Cwd)) {
          $sharesLeasedCwd = $true
          break
        }
      }
      if (-not $sharesLeasedCwd) { continue }
      $brokerToken = Get-CxcToken -CommandLine ([string]$broker.CommandLine)
      if (-not $coveredTokens.Contains([string]$brokerToken)) {
        $hasUnleasedSameCwdBroker = $true
        break
      }
    }
    if ($hasUnleasedSameCwdBroker) { [void]$out.Add([int]$renderPid) }
  }
  return , ($out.ToArray())
}

# Pure classification: the orphan brokers in $Procs - brokers whose token no
# outside-tree process references. Each returned record carries BrokerPid,
# Token, Cwd. The broker-tree union is built once and excludes roots plus all
# descendants before tokens are collected. Dead-parent and codex.exe-descendant
# remain INTENTIONALLY ignored (documented false signals).
function Get-CodexOrphanBrokers {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [AllowNull()]$BrokerTreePids = $null,
    [AllowEmptyCollection()][object[]]$ClientLeases = @(),
    [datetime]$NowUtc = [datetime]::UtcNow
  )
  if ($null -eq $BrokerTreePids) { $BrokerTreePids = Get-CodexBrokerTreePids -Procs $Procs }
  $liveTokens = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($token in (Get-LiveClientTokens -Procs $Procs -BrokerTreePids $BrokerTreePids)) { [void]$liveTokens.Add($token) }
  foreach ($token in (Get-LiveClientLeaseTokens -Procs $Procs -BrokerTreePids $BrokerTreePids -ClientLeases $ClientLeases -NowUtc $NowUtc)) { [void]$liveTokens.Add($token) }
  $out = New-Object System.Collections.ArrayList
  foreach ($p in $Procs) {
    if (-not (Test-IsCodexAppServerBroker -Proc $p)) { continue }
    $tok = Get-CxcToken -CommandLine ([string]$p.CommandLine)
    if ($null -eq $tok) { continue }
    if ($liveTokens.Contains($tok)) { continue }   # an outside token reference or fresh client lease -> LIVE
    [void]$out.Add([pscustomobject]@{
      BrokerPid = [int]$p.ProcessId
      Token     = [string]$tok
      Cwd       = (Get-BrokerCwd -CommandLine ([string]$p.CommandLine))
    })
  }
  return $out.ToArray()
}

# Build the child + creation-time maps once when several broker roots must be
# walked against the same process snapshot. Get-DescendantPids still builds its
# own index when called directly, preserving the public pure-helper seam.
function Get-ProcessTreeIndex {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $created = @{}
  $byParent = @{}
  foreach ($p in $Procs) {
    if ($p.PSObject.Properties['CreationDate'] -and $null -ne $p.CreationDate) {
      $created[[string]$p.ProcessId] = [datetime]$p.CreationDate
    }
    if ($null -eq $p.ParentProcessId) { continue }
    $key = [string]$p.ParentProcessId
    if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
    [void]$byParent[$key].Add([int]$p.ProcessId)
  }
  return [pscustomobject]@{ Created = $created; ByParent = $byParent }
}

# Pure descendant walk. Returns every LIVE pid in $Procs reachable from $RootPid
# by following ParentProcessId links DOWNWARD (children, grandchildren, ...).
# $RootPid itself is NOT included (the caller adds it). BFS over a child map
# built once; pid-reuse cycle guard + depth cap mirror reap-mcp-fleet.ps1.
# PPID-reuse filter (codex CR round 4): Windows never updates a process's
# recorded PPID when its real parent dies, so an UNRELATED process can carry
# a stale PPID that a broker-tree pid has since RECYCLED into - the walk
# would sweep it in. The canonical filter is creation-time ordering: a real
# child can never be OLDER than its parent, while a stale-PPID impostor
# predates the recycled pid it points at. A claimed child older than its
# claimed parent (2s tolerance, matching Test-ProcessStartMatches) is skipped.
#
# The default kill-tree walk keeps an edge when either CreationDate is missing
# (fail-open for orphan-descendant completeness); the downstream name + process
# identity gates still protect every kill. -VerifiedEdgesOnly instead drops
# such unverifiable edges (fail-closed for broker-tree evidence suppression),
# so an outside client with a stale PPID cannot be hidden from liveness.
function Get-DescendantPids {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][int]$RootPid,
    [AllowNull()]$TreeIndex = $null,
    [switch]$VerifiedEdgesOnly
  )
  if ($null -eq $TreeIndex) { $TreeIndex = Get-ProcessTreeIndex -Procs $Procs }
  $created = $TreeIndex.Created
  $byParent = $TreeIndex.ByParent
  $result = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Generic.Queue[int]
  $queue.Enqueue($RootPid)
  # seen = enqueued-or-root, checked at CHILD-ADD time (CR round 2): the old
  # dequeue-time visited check terminated PPID cycles but still ADDED the
  # already-seen pid to the result first, so a cycle through the root put
  # $RootPid into its own descendant list (contract violation + duplicate
  # Stop-Process target). Gating the add keeps every pid at most once and
  # the root never.
  $seen = @{ ([string]$RootPid) = $true }
  $depth = 0
  while ($queue.Count -gt 0 -and $depth -lt 4096) {
    $depth++
    $cur = $queue.Dequeue()
    $curKey = [string]$cur
    if (-not $byParent.ContainsKey($curKey)) { continue }
    foreach ($child in $byParent[$curKey]) {
      $childKey = [string]$child
      if ($seen.ContainsKey($childKey)) { continue }   # pid-reuse cycle guard
      # Creation-time ordering (codex round 4): a claimed child measurably
      # OLDER than its claimed parent is a stale-PPID impostor, not kin.
      $hasChildCreated = $created.ContainsKey($childKey)
      $hasParentCreated = $created.ContainsKey($curKey)
      if ($VerifiedEdgesOnly -and (-not $hasChildCreated -or -not $hasParentCreated)) { continue }
      if ($hasChildCreated -and $hasParentCreated) {
        # Both timestamps come from the SAME CIM snapshot, so a real child is
        # never older than its parent at all - the 2s tolerance exists for the
        # CROSS-read comparisons (Test-ProcessStartMatches, snapshot vs live).
        # The verified walk therefore rejects ANY older-than-parent child
        # (codex-adv r2: a stale PPID recycled within the 2s window would
        # otherwise read as verified kin and suppress client evidence); the
        # kill-tree walk keeps the lenient cross-read-shaped tolerance.
        $gap = ($created[$curKey] - $created[$childKey]).TotalSeconds
        if ($VerifiedEdgesOnly) {
          if ($gap -gt 0) { continue }
        } elseif ($gap -gt 2) { continue }
      }
      $seen[$childKey] = $true
      [void]$result.Add($child)
      $queue.Enqueue($child)
    }
  }
  return $result.ToArray()
}

# Union of every broker root + VERIFIED descendant pid in the snapshot. A
# process inside ANY broker tree cannot be client evidence for ANY token, but an
# unverifiable edge must fail closed here: suppressing a real outside client's
# evidence could make its live broker look orphaned. Cross-tree references with
# verified ancestry remain excluded. The process-tree index is built once and
# reused for every root.
function Get-CodexBrokerTreePids {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $set = New-Object System.Collections.Generic.HashSet[int]
  $treeIndex = Get-ProcessTreeIndex -Procs $Procs
  foreach ($p in $Procs) {
    if (-not (Test-IsCodexAppServerBroker -Proc $p)) { continue }
    [void]$set.Add([int]$p.ProcessId)
    foreach ($procId in (Get-DescendantPids -Procs $Procs -RootPid ([int]$p.ProcessId) -TreeIndex $treeIndex -VerifiedEdgesOnly)) {
      [void]$set.Add([int]$procId)
    }
  }
  return , $set
}

# Headline pure classifier the brief asks for: given a synthetic proc table,
# return one object per orphan tree - { BrokerPid, Token, Cwd, TreePids (broker
# + descendants), TreeProcCount }. Testable end-to-end without real processes.
function Get-CodexOrphanTrees {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [AllowNull()]$BrokerTreePids = $null,
    [AllowEmptyCollection()][object[]]$ClientLeases = @(),
    [datetime]$NowUtc = [datetime]::UtcNow
  )
  $orphans = @(Get-CodexOrphanBrokers -Procs $Procs -BrokerTreePids $BrokerTreePids -ClientLeases $ClientLeases -NowUtc $NowUtc)
  $out = New-Object System.Collections.ArrayList
  foreach ($o in $orphans) {
    $desc = @(Get-DescendantPids -Procs $Procs -RootPid $o.BrokerPid)
    $tree = @($o.BrokerPid) + $desc
    [void]$out.Add([pscustomobject]@{
      BrokerPid    = $o.BrokerPid
      Token        = $o.Token
      Cwd          = $o.Cwd
      TreePids     = [int[]]$tree
      TreeProcCount = $tree.Count
    })
  }
  return $out.ToArray()
}

# Name-allow-list for the name-verified kill. Base name (.exe stripped,
# case-insensitive) must be in the set. Keep in sync with the header allow set.
function Test-ProcessNameAllowed {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
  # `tokensave` added HIMMEL-1309: it is a plugin MCP server the codex app-server
  # spawns like any other fleet member (six superseded `tokensave|serve` roots on
  # the 2026-07-27 live table), so omitting it made every classified tokensave
  # orphan report as name-skipped and survive the sweep forever. This gate only
  # ever permits stopping a process the classifier ALREADY judged reapable.
  $allow = @('node','cmd','bash','codex','conhost','pwsh','python','bun','uv','uvx','node_repl','mcp-obsidian','qmd','tokensave')
  $base = $Name
  if ($base -match '\.exe$') { $base = $base -replace '\.exe$', '' }
  return ($allow -contains $base)
}

# Identity check for the kill loop (codex-1 round 2): a pid recycled into
# ANOTHER allow-listed image (e.g. a fresh node.exe) passes the name gate.
# The process CREATION TIME is the identity anchor - the enumeration
# snapshot's CIM CreationDate must match the live process's StartTime
# (2s tolerance: both derive from the kernel creation time but arrive via
# different conversions/rounding). Either side missing/unreadable returns
# $true - fall back to the name gate alone (the pre-existing guard level;
# a lost EXTRA check must never become a reason to kill more broadly, and
# failing closed here would wedge -Kill on processes whose StartTime is
# access-denied).
function Test-ProcessStartMatches {
  param($SnapshotCreation, $LiveStart)
  if ($null -eq $SnapshotCreation -or $null -eq $LiveStart) { return $true }
  try {
    $delta = [math]::Abs(([datetime]$LiveStart - [datetime]$SnapshotCreation).TotalSeconds)
    return ($delta -le 2)
  } catch { return $true }
}

# Path-safety gate for tokens that reach the FILESYSTEM (codex CR round 3):
# the token is captured by a \S+? regex from a process COMMAND LINE - argv is
# attacker-writable and \S matches path separators and dots, so a crafted
# "cxc-..\..\x-codex-app-server" token would traverse out of $env:TEMP\cxc-<t>
# at broker.pid cleanup. Classification may see exotic tokens harmlessly;
# only [A-Za-z0-9_-] may ever be joined into a path.
function Test-CxcTokenPathSafe {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Token)
  return ($Token -match '^[A-Za-z0-9_-]+$')
}

# Best-effort filesystem reader for Layer B leases. Invalid JSON, unsafe tokens,
# missing fields, and unreadable files are ignored; Get-LiveClientLeaseTokens
# applies the freshness + identity + cwd gates before any lease becomes evidence.
function Get-CodexClientLeases {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [AllowNull()][string]$TempRoot
  )
  $out = New-Object System.Collections.ArrayList
  if (-not $TempRoot -or -not (Test-Path -LiteralPath $TempRoot)) { return $out.ToArray() }
  foreach ($p in $Procs) {
    if (-not (Test-IsCodexAppServerBroker -Proc $p)) { continue }
    $token = Get-CxcToken -CommandLine ([string]$p.CommandLine)
    if (-not $token -or -not (Test-CxcTokenPathSafe -Token $token)) { continue }
    $leaseDir = Join-Path $TempRoot "cxc-$token"
    if (-not (Test-Path -LiteralPath $leaseDir)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $leaseDir -Filter 'client-lease-*.json' -File -ErrorAction SilentlyContinue)) {
      try {
        $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        [void]$out.Add([pscustomobject]@{
          Token           = [string]$token
          ClientPid       = $raw.clientPid
          ClientStartTime = $raw.clientStartTime
          Cwd             = $raw.cwd
          Heartbeat       = $raw.heartbeat
        })
      } catch { continue }
    }
  }
  return $out.ToArray()
}

# Degraded-visibility probe (silent-failure CR): WMI returns an EMPTY
# CommandLine for a process the caller lacks rights to inspect (cross-
# elevation / cross-session). If that hits a plausible OUTSIDE client image
# (claude.exe, ChatGPT.exe, node.exe, bun.exe), its token could silently drop
# out of the live-token set and a broker could misclassify as ORPHAN.
#
# Do NOT gate on every invisible process: unrelated cross-session / SYSTEM
# processes routinely hide CommandLine from a non-elevated sweep, which would
# disable -Kill permanently. Processes inside any broker tree are also excluded;
# descendants are known non-client false signals even when their argv is hidden.
function Get-BlindClientPids {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [AllowNull()]$BrokerTreePids = $null
  )
  if ($null -eq $BrokerTreePids) { $BrokerTreePids = Get-CodexBrokerTreePids -Procs $Procs }
  $out = New-Object System.Collections.ArrayList
  foreach ($p in $Procs) {
    if ($BrokerTreePids.Contains([int]$p.ProcessId)) { continue }
    if (-not (Test-IsPlausibleCodexAppServerClient -Proc $p)) { continue }
    if ([string]::IsNullOrEmpty([string]$p.CommandLine)) { [void]$out.Add([int]$p.ProcessId) }
  }
  return , ($out.ToArray())
}

# Platform guard (HIMMEL-1321, following the [codex-1]/[glm-3] fix already
# ported to scripts/codex/reap-superseded-fleets.ps1 for the identical bug in
# HIMMEL-1309). `$IsWindows` is a PowerShell 6+ AUTOMATIC VARIABLE — under
# Windows PowerShell 5.1 it is simply UNDEFINED ($null), so the obvious
# `if (-not $IsWindows)` evaluates TRUE and the script exits 0 announcing
# "non-Windows" on the exact platform it exists for.
#
# That path is reachable in production, not theoretical: codex-sweep-cadence.sh's
# resolve_pwsh falls back to `powershell` when `pwsh` is not on PATH, so an
# adopter without PowerShell 7 gets an armed daily cadence whose sweep leg
# no-ops on every fire while the runner log records a clean rc=0 — a silent,
# self-reporting success that never sweeps anything.
#
# 5.1 ships only on Windows, so an undefined $IsWindows means Windows; $env:OS
# is the explicit corroborating signal rather than an assumption.
function Test-OnWindows {
  param([AllowNull()]$IsWindowsValue, [AllowNull()][AllowEmptyString()][string]$OsEnv)
  if ($null -eq $IsWindowsValue) { return ($OsEnv -eq 'Windows_NT') }
  return [bool]$IsWindowsValue
}

# --- HIMMEL-1509: render-lease registry + kill-ledger helpers -----------------

# Branch -> lease-dir slug, mirroring render-lease.sh's render_lease_slug
# EXACTLY (HIMMEL-1509 r6, codex-2): [A-Za-z0-9._-] passes through; every
# other UTF-8 BYTE becomes '+HH' (two uppercase hex; '/' -> +2F, '+' itself
# -> +2B). '+' only ever starts a fixed-width escape, so the map is
# injective - distinct branches can never share a lease dir. The sweep does
# not slug branches today (it matches leases by record fields), but any
# future PS consumer MUST use this and never re-derive the mapping.
function Get-RenderLeaseSlug {
  param([AllowNull()][AllowEmptyString()][string]$Branch)
  if (-not $Branch) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Branch)) {
    $c = [string][char][int]$b
    if ($c -cmatch '^[A-Za-z0-9._-]$') {
      [void]$sb.Append($c)
    } else {
      [void]$sb.Append('+' + ([int]$b).ToString('X2'))
    }
  }
  return $sb.ToString()
}

# Parse a proc-tree Windows identity string (`win:<pid>:<startticks>`) into its
# parts, or $null for anything else (posix identities, malformed, empty).
function Get-RenderLeaseIdentityParts {
  param([AllowNull()][AllowEmptyString()][string]$Identity)
  if (-not $Identity) { return $null }
  if ($Identity -match '^win:(\d+):(\d+)$') {
    try {
      return [pscustomobject]@{ WinPid = [int]$Matches[1]; StartTicks = [long]$Matches[2] }
    } catch { return $null }
  }
  return $null
}

# lease.record is KEY<TAB>VALUE, one pair per line (render-lease.sh writer).
function ConvertFrom-RenderLeaseRecord {
  param([AllowNull()][AllowEmptyCollection()][string[]]$Lines)
  $map = @{}
  foreach ($line in @($Lines)) {
    if (-not $line) { continue }
    $idx = ([string]$line).IndexOf("`t")
    if ($idx -lt 1) { continue }
    $map[([string]$line).Substring(0, $idx)] = ([string]$line).Substring($idx + 1)
  }
  return $map
}

# TTL parity with the bash launcher (HIMMEL-1509 r3, glm-4): render-lease.sh
# honors RENDER_LEASE_TTL_SECS (default 600s), so the sweep resolves the SAME
# env knob - raising the launcher TTL must never make a launcher-live lease
# look sweep-stale. Non-numeric/non-positive values fall back to the default;
# odd second counts round UP (sparing errs long, never short).
function Get-RenderLeaseTtlMinutes {
  param([AllowNull()][AllowEmptyString()][string]$EnvValue)
  $secs = 600
  if ($EnvValue -and $EnvValue -match '^\d+$') {
    try {
      $candidate = [int]$EnvValue
      if ($candidate -gt 0) { $secs = $candidate }
    } catch { }
  }
  return [int][math]::Ceiling($secs / 60.0)
}

# Lock stale-break parity (HIMMEL-1509 r5, glm-2): the bash twin honors
# RENDER_LEASE_LOCK_STALE_SECS (default 600s, render-lease.sh), so the sweep
# resolves the SAME knob for Lock-RenderLeaseRegistry's age break - a raised
# env must never let the sweep age-break cross-space locks earlier than the
# launcher expects. Identical conversion contract to the TTL resolver
# (positive-int seconds, fall back on garbage/zero, round UP).
function Get-RenderLeaseLockStaleMinutes {
  param([AllowNull()][AllowEmptyString()][string]$EnvValue)
  return (Get-RenderLeaseTtlMinutes -EnvValue $EnvValue)
}

# Freshness gate for SPARING (protective), so its skew posture deliberately
# differs from the cxc client-lease validator: a FUTURE timestamp still reads
# fresh here - clock skew must never enable a kill. Unparseable -> not fresh
# (the lease then falls through to the leader-identity probe, not to a kill).
function Test-RenderLeaseHeartbeatFresh {
  param(
    [AllowNull()][AllowEmptyString()][string]$HeartbeatText,
    [datetime]$NowUtc = [datetime]::UtcNow,
    [int]$TtlMinutes = 10
  )
  if (-not $HeartbeatText) { return $false }
  $hb = $null
  try { $hb = ([datetimeoffset]::Parse($HeartbeatText.Trim())).UtcDateTime } catch { return $false }
  $age = ($NowUtc.ToUniversalTime() - $hb).TotalMinutes
  return ($age -le $TtlMinutes)
}

# Classify one lease against the enumeration snapshot:
#   live         = fresh heartbeat, OR recorded leader pid present in the
#                  snapshot with a creation time matching the recorded start
#                  ticks (2s tolerance, same anchor as Test-ProcessStartMatches),
#                  OR a leaderless launch-phase record whose started_at is
#                  still fresh (the launcher may not have bound yet), OR a
#                  leader ABSENT from (or recycled within) the snapshot while
#                  the record itself is still fresh - a lease bound AFTER this
#                  snapshot has a leader the snapshot cannot contain, so
#                  absence only proves death against a snapshot newer than the
#                  launch (HIMMEL-1509 r6, codex-1);
#   stale        = leader confirmed gone (absent from the snapshot or recycled
#                  into a different creation time) AND the record is past the
#                  TTL;
#   unverifiable = unreadable record, or a leader whose identity cannot be
#                  checked - fail-closed, the caller defers instead of killing.
function Get-RenderLeaseDisposition {
  param(
    [Parameter(Mandatory)]$Lease,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [datetime]$NowUtc = [datetime]::UtcNow,
    [int]$TtlMinutes = 10
  )
  if ($Lease.PSObject.Properties['Unreadable'] -and $Lease.Unreadable) { return 'unverifiable' }
  $heartbeatText = $null
  if ($Lease.PSObject.Properties['Heartbeat']) { $heartbeatText = [string]$Lease.Heartbeat }
  if (Test-RenderLeaseHeartbeatFresh -HeartbeatText $heartbeatText -NowUtc $NowUtc -TtlMinutes $TtlMinutes) { return 'live' }
  $startedText = $null
  if ($Lease.PSObject.Properties['StartedAt']) { $startedText = [string]$Lease.StartedAt }
  $identity = $null
  if ($Lease.PSObject.Properties['LeaderIdentity']) { $identity = [string]$Lease.LeaderIdentity }
  $parts = Get-RenderLeaseIdentityParts -Identity $identity
  if ($null -eq $parts) {
    if (Test-RenderLeaseHeartbeatFresh -HeartbeatText $startedText -NowUtc $NowUtc -TtlMinutes $TtlMinutes) { return 'live' }
    return 'unverifiable'
  }
  $leader = $null
  foreach ($p in $Procs) {
    if ([int]$p.ProcessId -eq $parts.WinPid) { $leader = $p; break }
  }
  if ($null -eq $leader) {
    # r6 codex-1: a leader bound after the snapshot cannot appear in it. A
    # fresh record (started_at inside the TTL; a fresh heartbeat already
    # returned live above) keeps the lease LIVE; only absent + stale-record
    # falls through to stale.
    if (Test-RenderLeaseHeartbeatFresh -HeartbeatText $startedText -NowUtc $NowUtc -TtlMinutes $TtlMinutes) { return 'live' }
    return 'stale'
  }
  $creationProp = $leader.PSObject.Properties['CreationDate']
  if (-not $creationProp -or $null -eq $creationProp.Value) { return 'unverifiable' }
  $creationTicks = $null
  try { $creationTicks = ([datetime]$creationProp.Value).ToUniversalTime().Ticks } catch { return 'unverifiable' }
  if ([math]::Abs(($creationTicks - $parts.StartTicks) / 10000000.0) -le 2) { return 'live' }
  # Same cross-snapshot race as the absent-leader case: the snapshot pid may
  # be a PRE-launch process whose pid the post-snapshot leader reused.
  if (Test-RenderLeaseHeartbeatFresh -HeartbeatText $startedText -NowUtc $NowUtc -TtlMinutes $TtlMinutes) { return 'live' }
  return 'stale'
}

function Get-RenderLeaseDispositions {
  param(
    [AllowEmptyCollection()][object[]]$Leases = @(),
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [datetime]$NowUtc = [datetime]::UtcNow,
    [int]$TtlMinutes = 10
  )
  $out = New-Object System.Collections.ArrayList
  foreach ($lease in @($Leases)) {
    [void]$out.Add([pscustomobject]@{
      Lease = $lease
      State = (Get-RenderLeaseDisposition -Lease $lease -Procs $Procs -NowUtc $NowUtc -TtlMinutes $TtlMinutes)
    })
  }
  # No unary comma: callers consume via @(...) (Get-CodexOrphanTrees style).
  return $out.ToArray()
}

# Map each orphan tree to a kill decision under the lease dispositions:
#   spared   = a LIVE lease claims the tree (recorded token, or lease-strict
#              broker --cwd equals the lease worktree) -> untouchable;
#   deferred = an UNVERIFIABLE lease might claim it (cwd match, worktree-less
#              unverifiable lease, or the tree's own cwd is unresolvable while
#              any live/unverifiable lease exists - HIMMEL-1474 r3 ambiguity
#              posture) -> not killed this pass;
#   kill     = no lease claims it -> proceeds to the existing name + identity
#              verified stop.
function Select-RenderLeaseKillActions {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Trees,
    [AllowEmptyCollection()][object[]]$Dispositions = @(),
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs
  )
  $byPid = @{}
  foreach ($p in $Procs) { $byPid[[string]$p.ProcessId] = $p }
  $liveTokens = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  $liveCwds = New-Object System.Collections.ArrayList
  $unvCwds = New-Object System.Collections.ArrayList
  $unvGlobal = $false
  foreach ($d in @($Dispositions)) {
    $lease = $d.Lease
    $worktree = $null
    if ($lease.PSObject.Properties['Worktree']) { $worktree = [string]$lease.Worktree }
    if ($d.State -eq 'live') {
      if ($lease.PSObject.Properties['Tokens']) {
        foreach ($t in @($lease.Tokens)) { if ($t) { [void]$liveTokens.Add([string]$t) } }
      }
      if ($worktree) { [void]$liveCwds.Add($worktree) } else { $unvGlobal = $true }
    } elseif ($d.State -eq 'unverifiable') {
      if ($worktree) { [void]$unvCwds.Add($worktree) } else { $unvGlobal = $true }
    }
  }
  $anyLeaseSignal = ($liveTokens.Count -gt 0 -or $liveCwds.Count -gt 0 -or $unvCwds.Count -gt 0 -or $unvGlobal)
  $out = New-Object System.Collections.ArrayList
  foreach ($t in @($Trees)) {
    $action = 'kill'
    $reason = ''
    if ($liveTokens.Contains([string]$t.Token)) {
      $action = 'spared'; $reason = 'live-lease-token'
    } else {
      $broker = $byPid[[string]$t.BrokerPid]
      $brokerCwd = $null
      if ($broker) { $brokerCwd = Get-BrokerLeaseCwd -CommandLine ([string]$broker.CommandLine) }
      if (Test-PathResolvable -Path $brokerCwd) {
        foreach ($c in $liveCwds) {
          if (Test-PathEquivalent -Left $brokerCwd -Right ([string]$c)) { $action = 'spared'; $reason = 'live-lease-cwd'; break }
        }
        if ($action -eq 'kill') {
          foreach ($c in $unvCwds) {
            if (Test-PathEquivalent -Left $brokerCwd -Right ([string]$c)) { $action = 'deferred'; $reason = 'unverifiable-lease-cwd'; break }
          }
        }
        if ($action -eq 'kill' -and $unvGlobal) { $action = 'deferred'; $reason = 'unverifiable-lease' }
      } elseif ($anyLeaseSignal) {
        $action = 'deferred'; $reason = 'unresolvable-broker-cwd'
      }
    }
    [void]$out.Add([pscustomobject]@{ Tree = $t; Action = $action; Reason = $reason })
  }
  # No unary comma: callers consume via @(...) (Get-CodexOrphanTrees style).
  return $out.ToArray()
}

# Replay-guard parity with the main pass (HIMMEL-1509 r2, codex-1): a lease
# can protect a render by WORKTREE alone (its tokens file may not exist yet),
# so -FromLedger must not kill just because the recorded token set is empty.
# Protection = recorded tokens of live/unverifiable leases, PLUS the token of
# every snapshot broker whose lease-strict --cwd matches a live/unverifiable
# lease worktree, PLUS ambiguous brokers (unresolvable cwd) whenever any lease
# signal exists; a worktree-less live/unverifiable lease protects everything.
# AnySignal lets callers fail closed on entries that carry no token at all.
function Get-RenderLeaseReplayGuard {
  param(
    [AllowEmptyCollection()][object[]]$Dispositions = @(),
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs
  )
  $tokens = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  $cwds = New-Object System.Collections.ArrayList
  $protectAll = $false
  $anySignal = $false
  foreach ($d in @($Dispositions)) {
    if ($d.State -eq 'stale') { continue }
    $anySignal = $true
    $lease = $d.Lease
    if ($lease.PSObject.Properties['Tokens']) {
      foreach ($t in @($lease.Tokens)) { if ($t) { [void]$tokens.Add([string]$t) } }
    }
    $worktree = $null
    if ($lease.PSObject.Properties['Worktree']) { $worktree = [string]$lease.Worktree }
    if ($worktree) { [void]$cwds.Add($worktree) } else { $protectAll = $true }
  }
  if (-not $protectAll -and $anySignal) {
    foreach ($p in @($Procs)) {
      if (-not (Test-IsCodexAppServerBroker -Proc $p)) { continue }
      $brokerToken = Get-CxcToken -CommandLine ([string]$p.CommandLine)
      if (-not $brokerToken) { continue }
      $brokerCwd = Get-BrokerLeaseCwd -CommandLine ([string]$p.CommandLine)
      if (Test-PathResolvable -Path $brokerCwd) {
        foreach ($c in $cwds) {
          if (Test-PathEquivalent -Left $brokerCwd -Right ([string]$c)) { [void]$tokens.Add([string]$brokerToken); break }
        }
      } else {
        # Same ambiguity posture as Select-RenderLeaseKillActions: a broker
        # with no provable path binding is untouchable while any lease exists.
        [void]$tokens.Add([string]$brokerToken)
      }
    }
  }
  return [pscustomobject]@{ Tokens = $tokens; ProtectAll = $protectAll; AnySignal = $anySignal }
}

# Ledger entries are keyed by pid + recorded creation time, so a `consumed`
# record can only ever retire the exact process incarnation it names.
function Get-KillLedgerEntryKey {
  param([Parameter(Mandatory)]$Entry)
  $entryPid = ''
  $creation = ''
  if ($Entry.PSObject.Properties['pid'] -and $null -ne $Entry.pid) { $entryPid = [string]$Entry.pid }
  if ($Entry.PSObject.Properties['creation'] -and $null -ne $Entry.creation) { $creation = [string]$Entry.creation }
  return "$entryPid|$creation"
}

# Parse the append-only JSONL kill-ledger: return the `kill-failed` entries not
# yet retired by a matching `consumed` record. Malformed lines are skipped
# (they can only ever hide evidence, never authorize a kill).
function ConvertFrom-KillLedger {
  param([AllowNull()][AllowEmptyCollection()][string[]]$Lines)
  $consumed = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
  $entries = New-Object System.Collections.ArrayList
  foreach ($line in @($Lines)) {
    if (-not $line) { continue }
    $o = $null
    try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    if ($null -eq $o -or -not $o.PSObject.Properties['type']) { continue }
    switch ([string]$o.type) {
      'consumed' { [void]$consumed.Add((Get-KillLedgerEntryKey -Entry $o)) }
      'kill-failed' { [void]$entries.Add($o) }
    }
  }
  $out = New-Object System.Collections.ArrayList
  foreach ($e in $entries) {
    if (-not $consumed.Contains((Get-KillLedgerEntryKey -Entry $e))) { [void]$out.Add($e) }
  }
  # No unary comma: callers consume via @(...) (Get-CodexOrphanTrees style).
  return $out.ToArray()
}

# Judge a ledger entry against the LIVE process it names:
#   match        = same creation time (2s) AND the live name is allow-listed
#                  -> the recorded orphan incarnation, killable;
#   recycled     = live creation time provably differs -> the orphan is gone,
#                  the entry is consumable, the live process untouchable;
#   unverifiable = missing/unreadable identity data on either side ->
#                  fail-closed: never kill, never consume. STRICTER than
#                  Test-ProcessStartMatches by design: a ledger kill is
#                  elective, so a lost probe drops the kill, not the guard.
function Get-KillLedgerEntryLiveState {
  param(
    [Parameter(Mandatory)]$Entry,
    [AllowNull()][AllowEmptyString()][string]$LiveName,
    [AllowNull()]$LiveStart
  )
  $creationProp = $Entry.PSObject.Properties['creation']
  if (-not $creationProp -or -not $creationProp.Value) { return 'unverifiable' }
  if ($null -eq $LiveStart) { return 'unverifiable' }
  $recorded = $null
  $live = $null
  try {
    # PS7 ConvertFrom-Json auto-converts ISO strings to [datetime] (Local
    # kind); stringifying that and re-parsing shifts by the UTC offset, so
    # branch on the actual representation instead of round-tripping.
    if ($creationProp.Value -is [datetime]) {
      $recorded = ([datetime]$creationProp.Value).ToUniversalTime()
    } else {
      $recorded = ([datetimeoffset]::Parse([string]$creationProp.Value)).UtcDateTime
    }
    $live = ([datetime]$LiveStart).ToUniversalTime()
  } catch { return 'unverifiable' }
  if ([math]::Abs(($live - $recorded).TotalSeconds) -gt 2) { return 'recycled' }
  if (-not $LiveName -or -not (Test-ProcessNameAllowed -Name $LiveName)) { return 'unverifiable' }
  return 'match'
}

# --- registry IO (invoked only by the production path / IO-aware tests) -------

# Read every lease under the registry root. Per-lease read failures mark that
# lease Unreadable (-> unverifiable downstream); a top-level enumeration
# failure THROWS so the caller can refuse the kill pass.
function Get-RenderLeaseRecords {
  param([AllowNull()][AllowEmptyString()][string]$RegistryPath)
  $out = New-Object System.Collections.ArrayList
  # No unary comma on either return: callers consume via @(...).
  if (-not $RegistryPath -or -not (Test-Path -LiteralPath $RegistryPath)) { return $out.ToArray() }
  foreach ($dir in @(Get-ChildItem -LiteralPath $RegistryPath -Directory -Force -ErrorAction Stop)) {
    if ($dir.Name.StartsWith('.')) { continue }
    $rec = [ordered]@{
      Name = $dir.Name; Path = $dir.FullName
      Branch = $null; Worktree = $null; LeaderIdentity = $null; StartedAt = $null
      Heartbeat = $null; Tokens = @(); Unreadable = $false
    }
    try {
      $lines = @(Get-Content -LiteralPath (Join-Path $dir.FullName 'lease.record') -ErrorAction Stop)
      $map = ConvertFrom-RenderLeaseRecord -Lines $lines
      if ($map.ContainsKey('branch')) { $rec.Branch = $map['branch'] } else { $rec.Unreadable = $true }
      if ($map.ContainsKey('worktree')) { $rec.Worktree = $map['worktree'] }
      if ($map.ContainsKey('leader_identity')) { $rec.LeaderIdentity = $map['leader_identity'] }
      if ($map.ContainsKey('started_at')) { $rec.StartedAt = $map['started_at'] }
    } catch { $rec.Unreadable = $true }
    try { $rec.Heartbeat = [string](Get-Content -LiteralPath (Join-Path $dir.FullName 'heartbeat') -Raw -ErrorAction Stop) } catch { }
    try { $rec.Tokens = @(Get-Content -LiteralPath (Join-Path $dir.FullName 'tokens') -ErrorAction Stop | Where-Object { $_ }) } catch { $rec.Tokens = @() }
    [void]$out.Add([pscustomobject]$rec)
  }
  return $out.ToArray()
}

# Registry mutex: mkdir of .registry.lock, mirroring render-lease.sh. Owner is
# tagged `win:<pid>` here. Stale-break disposition (HIMMEL-1509 r4, matching
# the bash twin): a same-space owner probed ALIVE is NEVER broken - not even
# by age (a long kill pass or mid-claim launcher legitimately holds it;
# contenders wait out their retries and the caller refuses); a same-space
# owner probed DEAD is broken immediately; only a cross-space (`msys:`) or
# unverifiable owner falls back to the AGE break, and each break logs which
# disposition fired. Returns the lock path or $null when every attempt stayed
# contended (caller must then refuse kills).
function Lock-RenderLeaseRegistry {
  param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [int]$Attempts = 10,
    [int]$DelayMs = 500,
    [int]$StaleMinutes = 10
  )
  $lockPath = Join-Path $RegistryPath '.registry.lock'
  for ($i = 0; $i -lt $Attempts; $i++) {
    try {
      [void](New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop)
      try { Set-Content -LiteralPath (Join-Path $lockPath 'owner.pid') -Value "win:$PID" } catch { }
      return $lockPath
    } catch { }
    $stale = $false
    $ownerLive = $false
    $owner = $null
    try { $owner = [string](Get-Content -LiteralPath (Join-Path $lockPath 'owner.pid') -Raw -ErrorAction Stop) } catch { }
    if ($owner -and $owner.Trim() -match '^win:(\d+)$') {
      try {
        [void](Get-Process -Id ([int]$Matches[1]) -ErrorAction Stop)
        $ownerLive = $true
      } catch { $stale = $true }
    }
    if ($stale) {
      Write-Host ('[sweep-codex-orphans] render-lease: breaking registry lock held by confirmed-dead owner ({0})' -f $owner.Trim())
    } elseif (-not $ownerLive) {
      # Cross-space or unverifiable owner: age is the only safe judge. A
      # verified-live owner never reaches this branch.
      try {
        $age = ([datetime]::UtcNow - (Get-Item -LiteralPath $lockPath -Force -ErrorAction Stop).CreationTimeUtc).TotalMinutes
        if ($age -gt $StaleMinutes) {
          $stale = $true
          $ownerLabel = '(unreadable)'
          if ($owner) { $ownerLabel = $owner.Trim() }
          Write-Host ('[sweep-codex-orphans] render-lease: age-breaking registry lock with cross-space/unverifiable owner ({0}, older than {1}min)' -f $ownerLabel, $StaleMinutes)
        }
      } catch { }
    }
    if ($stale) { Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds $DelayMs
  }
  return $null
}

# Owner-verified release (HIMMEL-1509 r7, codex-1; mirrors
# render_lease_lock_release): remove the lock ONLY when its owner record
# names this process - a former holder whose lock was broken must never
# delete a successor's newly acquired lock. A mismatched or unreadable owner
# leaves the lock (the dead-owner / age breaks self-heal it) and says so.
function Unlock-RenderLeaseRegistry {
  param([Parameter(Mandatory)][string]$LockPath)
  if (-not (Test-Path -LiteralPath $LockPath)) { return }
  $owner = $null
  try { $owner = ([string](Get-Content -LiteralPath (Join-Path $LockPath 'owner.pid') -Raw -ErrorAction Stop)).Trim() } catch { }
  if ($owner -ceq "win:$PID") {
    Remove-Item -LiteralPath $LockPath -Recurse -Force -ErrorAction SilentlyContinue
    return
  }
  $ownerLabel = '(unreadable)'
  if ($owner) { $ownerLabel = $owner }
  Write-Host ('[sweep-codex-orphans] render-lease: NOT releasing registry lock: owner record {0} is not this process (win:{1}) - it was re-acquired after a break; leaving it to its owner' -f $ownerLabel, $PID)
}

function Add-KillLedgerLine {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
  Add-Content -LiteralPath $Path -Value (ConvertTo-Json -Compress -InputObject $Object)
}

if ($AsLibrary) { return }

# --- production path ---------------------------------------------------------

# OS guard: the broker leak is a Windows-observed pattern; on any other OS there
# is nothing to sweep. Exit 0 (not an error) after a clear message.
if (-not (Test-OnWindows -IsWindowsValue $IsWindows -OsEnv $env:OS)) {
  Write-Host "[sweep-codex-orphans] non-Windows host (broker leak is a Windows pattern) - nothing to sweep."
  exit 0
}

$ErrorActionPreference = 'Stop'

# HIMMEL-1509: resolve the render-lease registry + kill-ledger locations once.
$renderLeaseRegistry = $RegistryPath
if (-not $renderLeaseRegistry) { $renderLeaseRegistry = [string]$env:RENDER_LEASE_DIR }
if (-not $renderLeaseRegistry) { $renderLeaseRegistry = Join-Path ([string]$env:USERPROFILE) '.claude\handover\bridge\render-leases' }
$killLedgerPath = $LedgerPath
if (-not $killLedgerPath) { $killLedgerPath = Join-Path $renderLeaseRegistry 'kill-ledger.jsonl' }
# Launcher TTL parity (r3 glm-4): one resolution, passed to every disposition.
$renderLeaseTtl = Get-RenderLeaseTtlMinutes -EnvValue ([string]$env:RENDER_LEASE_TTL_SECS)
# Launcher lock-stale parity (r5 glm-2): same, for the registry-lock age break.
$renderLeaseLockStale = Get-RenderLeaseLockStaleMinutes -EnvValue ([string]$env:RENDER_LEASE_LOCK_STALE_SECS)

try {
  $records = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    ForEach-Object {
      [pscustomobject]@{
        ProcessId        = [int]$_.ProcessId
        ParentProcessId  = [int]$_.ParentProcessId
        Name             = [string]$_.Name
        CommandLine      = [string]$_.CommandLine
        WorkingSetSize   = [long]($_.WorkingSetSize)
        # Identity anchor for the kill loop's recycled-pid check (may be $null
        # for processes whose creation time WMI does not expose to the caller).
        CreationDate     = $_.CreationDate
      }
    })
} catch {
  Write-Error "[sweep-codex-orphans] could not enumerate processes: $_"
  exit 1
}

# --- HIMMEL-1509: -FromLedger, the sanctioned orchestrator consume path ------
# Kills ONLY identity-verified unconsumed ledger entries: live process present,
# creation time matching the recorded identity, name allow-listed, and not
# protected by a live/unverifiable render lease. Without -Kill it only lists.
if ($FromLedger) {
  if (-not (Test-Path -LiteralPath $killLedgerPath)) {
    Write-Host "[sweep-codex-orphans] kill-ledger: absent at $killLedgerPath - nothing to consume."
    exit 0
  }
  $leaseLock = $null
  if ($Kill) {
    # HIMMEL-1509 r3 (codex-1): unconditional create+lock before any replay
    # kill, same as the main kill path - a missing registry never skips the
    # lock (a first concurrent render can create it mid-replay).
    try { [void](New-Item -ItemType Directory -Force -Path $renderLeaseRegistry -ErrorAction Stop) } catch {
      Write-Host "[sweep-codex-orphans] render-lease: outcome=refused reason=registry-unusable - no ledger entry was acted on."
      exit 1
    }
    $leaseLock = Lock-RenderLeaseRegistry -RegistryPath $renderLeaseRegistry -StaleMinutes $renderLeaseLockStale
    if (-not $leaseLock) {
      Write-Host "[sweep-codex-orphans] render-lease: outcome=refused reason=lock-unavailable - no ledger entry was acted on."
      exit 1
    }
  }
  # try/finally holds the lock release (HIMMEL-1509 r2, glm-4 parity): an
  # exception mid-replay must not strand the lock into the 10-min stale
  # reclaim. PowerShell runs finally on `exit` too.
  try {
  $renderLeases = @()
  if (Test-Path -LiteralPath $renderLeaseRegistry) {
    try { $renderLeases = @(Get-RenderLeaseRecords -RegistryPath $renderLeaseRegistry) } catch {
      Write-Host "[sweep-codex-orphans] render-lease: outcome=refused reason=registry-unreadable - no ledger entry was acted on."
      exit 1
    }
  }
  $dispositions = @(Get-RenderLeaseDispositions -Leases $renderLeases -Procs $records -TtlMinutes $renderLeaseTtl)
  $replayGuard = Get-RenderLeaseReplayGuard -Dispositions $dispositions -Procs $records
  $ledgerEntries = @()
  try { $ledgerEntries = @(ConvertFrom-KillLedger -Lines @(Get-Content -LiteralPath $killLedgerPath -ErrorAction Stop)) } catch {
    Write-Host "[sweep-codex-orphans] kill-ledger: outcome=refused reason=ledger-unreadable"
    exit 1
  }
  $ledgerKilled = 0
  $ledgerConsumed = 0
  $ledgerSkipped = 0
  foreach ($entry in $ledgerEntries) {
    $entryPid = 0
    try { $entryPid = [int]$entry.pid } catch { $ledgerSkipped++; continue }
    if ($entryPid -le 0) { $ledgerSkipped++; continue }
    $entryToken = ''
    if ($entry.PSObject.Properties['token'] -and $null -ne $entry.token) { $entryToken = [string]$entry.token }
    # Lease protection has main-pass parity (r2 codex-1): recorded or
    # cwd-derived protected tokens, a protect-everything lease, or an entry
    # with no token at all while any live/unverifiable lease exists.
    if ($replayGuard.ProtectAll -or
        ($entryToken -and $replayGuard.Tokens.Contains($entryToken)) -or
        (-not $entryToken -and $replayGuard.AnySignal)) {
      Write-Host "[sweep-codex-orphans] kill-ledger: pid=$entryPid token=$entryToken action=skipped reason=lease-protected"
      $ledgerSkipped++
      continue
    }
    $live = $null
    try { $live = Get-Process -Id $entryPid -ErrorAction Stop } catch { $live = $null }
    # Dry-run honesty (r3 codex-2): without -Kill nothing is appended, so the
    # per-entry label and the summary both say "would-consume"/"would-kill".
    $consumeLabel = 'consumed'
    if (-not $Kill) { $consumeLabel = 'would-consume' }
    if ($null -eq $live) {
      if ($Kill) { Add-KillLedgerLine -Path $killLedgerPath -Object ([ordered]@{ type = 'consumed'; ts = [datetime]::UtcNow.ToString('o'); pid = $entryPid; creation = $entry.creation; reason = 'gone' }) }
      Write-Host "[sweep-codex-orphans] kill-ledger: pid=$entryPid token=$entryToken action=$consumeLabel reason=gone"
      $ledgerConsumed++
      continue
    }
    $liveStart = $null
    try { $liveStart = $live.StartTime } catch { $liveStart = $null }
    $state = Get-KillLedgerEntryLiveState -Entry $entry -LiveName ([string]$live.ProcessName) -LiveStart $liveStart
    if ($state -eq 'match') {
      if ($Kill) {
        try {
          Stop-Process -Id $entryPid -Force -ErrorAction Stop
          Add-KillLedgerLine -Path $killLedgerPath -Object ([ordered]@{ type = 'consumed'; ts = [datetime]::UtcNow.ToString('o'); pid = $entryPid; creation = $entry.creation; reason = 'swept' })
          Write-Host "[sweep-codex-orphans] kill-ledger: pid=$entryPid token=$entryToken action=killed reason=identity-verified"
          $ledgerKilled++
        } catch {
          Write-Warning "[sweep-codex-orphans] kill-ledger: pid=$entryPid could not be stopped: $_"
          $ledgerSkipped++
        }
      } else {
        Write-Host "[sweep-codex-orphans] kill-ledger: pid=$entryPid token=$entryToken action=would-kill reason=identity-verified"
        $ledgerKilled++
      }
    } elseif ($state -eq 'recycled') {
      if ($Kill) { Add-KillLedgerLine -Path $killLedgerPath -Object ([ordered]@{ type = 'consumed'; ts = [datetime]::UtcNow.ToString('o'); pid = $entryPid; creation = $entry.creation; reason = 'recycled' }) }
      Write-Host "[sweep-codex-orphans] kill-ledger: pid=$entryPid token=$entryToken action=$consumeLabel reason=recycled"
      $ledgerConsumed++
    } else {
      Write-Host "[sweep-codex-orphans] kill-ledger: pid=$entryPid token=$entryToken action=skipped reason=unverifiable"
      $ledgerSkipped++
    }
  }
  if ($Kill) {
    Write-Host ("[sweep-codex-orphans] kill-ledger: {0} unconsumed entr(y/ies): {1} killed, {2} consumed, {3} skipped." -f $ledgerEntries.Count, $ledgerKilled, $ledgerConsumed, $ledgerSkipped)
  } else {
    Write-Host ("[sweep-codex-orphans] kill-ledger: {0} unconsumed entr(y/ies): would kill {1}, would consume {2}, {3} skipped (dry run - nothing written; re-run with -Kill)." -f $ledgerEntries.Count, $ledgerKilled, $ledgerConsumed, $ledgerSkipped)
  }
  exit 0
  } finally {
    if ($leaseLock) { Unlock-RenderLeaseRegistry -LockPath $leaseLock }
  }
}

# Build the broker-tree exclusion union once for liveness classification, the
# Layer A render gate, and the blind-client gate. Layer B leases are read only
# from each broker token's TEMP directory, then validated against this snapshot.
$brokerTreePids = Get-CodexBrokerTreePids -Procs $records
$clientLeases = @(Get-CodexClientLeases -Procs $records -TempRoot ([string]$env:TEMP))
$trees = @(Get-CodexOrphanTrees -Procs $records -BrokerTreePids $brokerTreePids -ClientLeases $clientLeases)
$outsideRenderPids = Get-UnattributedCodexAdversarialRenderPids -Procs $records -BrokerTreePids $brokerTreePids -ClientLeases $clientLeases

# byPid lookup for working-set summation + name-verified kill.
$byPid = @{}
foreach ($p in $records) { $byPid[[string]$p.ProcessId] = $p }

if ($trees.Count -eq 0) {
  Write-Host "[sweep-codex-orphans] no orphaned Codex app-server-broker trees found."
  exit 0
}

# Sum working set across a tree (bytes -> MB).
function Get-TreeWSMB {
  param([Parameter(Mandatory)][int[]]$Pids)
  $bytes = 0L
  foreach ($procId in $Pids) {
    $rec = $byPid[[string]$procId]
    if ($rec -and $rec.WorkingSetSize) { $bytes += [long]$rec.WorkingSetSize }
  }
  return [math]::Round($bytes / 1MB, 1)
}

$rows = $trees | ForEach-Object {
  [pscustomobject]@{
    BrokerPID = $_.BrokerPid
    Token     = $_.Token
    Cwd       = $_.Cwd
    TreeProcs = $_.TreeProcCount
    TreeWSMB  = (Get-TreeWSMB -Pids $_.TreePids)
  }
}

$totalProcs = ($trees | Measure-Object -Property TreeProcCount -Sum).Sum
$totalMB = [math]::Round((($rows | Measure-Object -Property TreeWSMB -Sum).Sum), 1)
$flatPids = ($trees | ForEach-Object { $_.TreePids } | Sort-Object -Unique)

Write-Host ("[sweep-codex-orphans] {0} orphaned broker tree(s), {1} proc(s), ~{2} MB:" -f $trees.Count, $totalProcs, $totalMB)
foreach ($t in $trees) {
  Write-Host ("[sweep-codex-orphans] orphan evidence: token cxc-{0}-codex-app-server; no visible outside-broker-tree process command line referenced it." -f $t.Token)
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("[sweep-codex-orphans] flat PID list ({0}): {1}" -f $flatPids.Count, ($flatPids -join ', '))

# Blind-client gate (silent-failure CR): a plausible outside client whose
# CommandLine WMI hides may hold a pipe we cannot see, so every ORPHAN verdict
# above is suspect. Warn always; refuse -Kill (report stays useful, nothing is
# stopped). The broker-tree union excludes hidden descendants from this gate.
# NB: NO @() wrap on the call (HIMMEL-930) - Get-BlindClientPids returns via
# unary comma so the array survives raw assignment (wrapping it in @() would
# re-box an EMPTY result into a 1-element wrapper, permanently tripping this
# gate: Count=1 even with zero blind clients).
$blindClients = Get-BlindClientPids -Procs $records -BrokerTreePids $brokerTreePids
if ($blindClients.Count -gt 0) {
  Write-Warning ("[sweep-codex-orphans] client pid(s) {0} have no visible CommandLine (elevation/session gap) - the client-liveness signal is unreliable; orphan classifications above may be WRONG." -f ($blindClients -join ', '))
}
if (Test-ShouldDeferCodexKill -OutsideRenderPids $outsideRenderPids) {
  Write-Warning ("[sweep-codex-orphans] outside-broker-tree codex adversarial render pid(s) {0} are live but carry no attributable cxc token - Layer A will defer the entire -Kill pass." -f ($outsideRenderPids -join ', '))
}

if (-not $Kill) {
  # HIMMEL-1509 report-only lease view (unlocked read; the -Kill pass re-reads
  # authoritatively under the registry lock).
  $renderLeases = @()
  if (Test-Path -LiteralPath $renderLeaseRegistry) {
    try { $renderLeases = @(Get-RenderLeaseRecords -RegistryPath $renderLeaseRegistry) } catch {
      Write-Warning "[sweep-codex-orphans] render-lease: registry unreadable ($renderLeaseRegistry) - a -Kill run would refuse."
    }
  }
  $renderDispositions = @(Get-RenderLeaseDispositions -Leases $renderLeases -Procs $records -TtlMinutes $renderLeaseTtl)
  foreach ($d in $renderDispositions) {
    Write-Host ('[sweep-codex-orphans] render-lease: name={0} state={1}' -f $d.Lease.Name, $d.State)
  }
  $killActions = @(Select-RenderLeaseKillActions -Trees $trees -Dispositions $renderDispositions -Procs $records)
  $wouldKillTrees = New-Object System.Collections.ArrayList
  foreach ($a in $killActions) {
    if ($a.Action -eq 'kill') { [void]$wouldKillTrees.Add($a.Tree) }
    else { Write-Host ('[sweep-codex-orphans] render-lease: token={0} broker={1} action={2} reason={3}' -f $a.Tree.Token, $a.Tree.BrokerPid, $a.Action, $a.Reason) }
  }
  # Report the KILLABLE subset distinctly (r3 glm-3): the candidate totals
  # above include lease-spared/deferred trees a -Kill run would not touch.
  $wouldKillPids = @($wouldKillTrees | ForEach-Object { $_.TreePids } | Sort-Object -Unique)
  $wouldKillMB = 0
  if ($wouldKillPids.Count -gt 0) { $wouldKillMB = Get-TreeWSMB -Pids ([int[]]$wouldKillPids) }
  Write-Host "[sweep-codex-orphans] dry run (default). Re-run with -Kill to name-verified-stop the above + clean stale broker.pid files."
  Write-Host ("[sweep-codex-orphans] would sweep {0} of {1} tree(s) ({2} lease-spared/deferred): {3} proc(s), ~{4} MB in the killable subset (all candidates: {5} proc(s), ~{6} MB)." -f $wouldKillTrees.Count, $trees.Count, ($trees.Count - $wouldKillTrees.Count), $wouldKillPids.Count, $wouldKillMB, $totalProcs, $totalMB)
  exit 0
}

if (Test-ShouldDeferCodexKill -OutsideRenderPids $outsideRenderPids) {
  Write-Host "[sweep-codex-orphans] deferred -Kill: at least one outside-tree codex adversarial render is live; no process was stopped."
  exit 0
}

if ($blindClients.Count -gt 0) {
  Write-Warning "[sweep-codex-orphans] refusing -Kill while plausible outside client command lines are invisible - re-run from a context that can see claude.exe/ChatGPT.exe/node.exe/bun.exe clients (e.g. the same elevation as the clients)."
  exit 1
}

# HIMMEL-1509: authoritative render-lease read UNDER THE REGISTRY LOCK before
# any kill. Live-lease trees are untouchable regardless of command-line
# visibility; unverifiable leases defer their trees; an unavailable lock or
# unreadable registry refuses the whole pass (fail-closed).
$leaseLock = $null
$renderLeases = @()
# HIMMEL-1509 r3 (codex-1): the registry lock is UNCONDITIONAL before any
# kill. "Registry absent" must never mean "skip the lock" - the first
# concurrent render CREATES the registry and its lease after an existence
# check would have passed, leaving the sweep killing with no authoritative
# locked read. The sweep therefore creates the registry dir itself and locks
# it; an EMPTY locked registry is the correct no-leases proof.
try { [void](New-Item -ItemType Directory -Force -Path $renderLeaseRegistry -ErrorAction Stop) } catch {
  Write-Host "[sweep-codex-orphans] render-lease: outcome=refused reason=registry-unusable - no process was stopped."
  exit 1
}
$leaseLock = Lock-RenderLeaseRegistry -RegistryPath $renderLeaseRegistry -StaleMinutes $renderLeaseLockStale
if (-not $leaseLock) {
  Write-Host "[sweep-codex-orphans] render-lease: outcome=refused reason=lock-unavailable - no process was stopped."
  exit 1
}
# try/finally holds the lock release (HIMMEL-1509 r2, glm-4): an exception
# anywhere in the kill/ledger section must not strand the lock into the 10-min
# stale reclaim. PowerShell runs finally on `exit` too. Body indentation is
# left flat to keep the guarded region diffable.
try {
try { $renderLeases = @(Get-RenderLeaseRecords -RegistryPath $renderLeaseRegistry) } catch {
  Write-Host "[sweep-codex-orphans] render-lease: outcome=refused reason=registry-unreadable - no process was stopped."
  exit 1
}
$renderDispositions = @(Get-RenderLeaseDispositions -Leases $renderLeases -Procs $records -TtlMinutes $renderLeaseTtl)
foreach ($d in $renderDispositions) {
  Write-Host ('[sweep-codex-orphans] render-lease: name={0} state={1}' -f $d.Lease.Name, $d.State)
}
$killActions = @(Select-RenderLeaseKillActions -Trees $trees -Dispositions $renderDispositions -Procs $records)
$killTrees = New-Object System.Collections.ArrayList
foreach ($a in $killActions) {
  if ($a.Action -eq 'kill') { [void]$killTrees.Add($a.Tree) }
  else { Write-Host ('[sweep-codex-orphans] render-lease: token={0} broker={1} action={2} reason={3}' -f $a.Tree.Token, $a.Tree.BrokerPid, $a.Action, $a.Reason) }
}
$leaseExcludedTrees = $trees.Count - $killTrees.Count
$killFlatPids = @($killTrees | ForEach-Object { $_.TreePids } | Sort-Object -Unique)
# pid -> token map so a stop-failure can be led into the kill-ledger with its
# tree identity attached.
$pidTokenMap = @{}
foreach ($t in $killTrees) {
  foreach ($treePid in $t.TreePids) { $pidTokenMap[[string]$treePid] = [string]$t.Token }
}
$ledgerFailed = New-Object System.Collections.ArrayList

# -Kill: name-verified stop. A pid is stopped ONLY if (a) its current
# ProcessName is in the allow set AND (b) its live StartTime matches the
# enumeration snapshot's CreationDate - (a) defends against reuse into an
# unrelated image, (b) against reuse into ANOTHER allow-listed image
# (codex-1 round 2). A mismatch on either is reported and skipped (never
# killed).
$killed = 0
$skippedName = 0
$skippedRecycled = 0
$skippedGone = 0
$killedPids = New-Object System.Collections.ArrayList
$killedBrokerPids = New-Object System.Collections.Generic.HashSet[int]
$brokerPidSet = New-Object System.Collections.Generic.HashSet[int]
foreach ($t in $killTrees) { [void]$brokerPidSet.Add([int]$t.BrokerPid) }
foreach ($procId in $killFlatPids) {
  $rec = $byPid[[string]$procId]            # enumeration snapshot (identity anchor)
  $liveNow = $null
  try { $liveNow = Get-Process -Id $procId -ErrorAction Stop } catch { $liveNow = $null }
  if ($null -eq $liveNow) { $skippedGone++; continue }   # already gone
  $curName = [string]$liveNow.ProcessName
  # Only the LIVE current name decides ([codex-1] CR fix): falling back to the
  # snapshot name would kill a pid recycled into a disallowed image whenever
  # the ORIGINAL image was allow-listed - the exact reuse window this guard
  # exists for. Test-ProcessNameAllowed strips .exe, so the extension
  # difference between Get-Process.ProcessName and the CIM snapshot name
  # needs no snapshot fallback.
  $ok = Test-ProcessNameAllowed -Name $curName
  if (-not $ok) {
    Write-Warning "[sweep-codex-orphans] pid $procId now '$curName' (not in allow set) - SKIP (pid-reuse safety)."
    $skippedName++
    continue
  }
  # Same-name recycling passes the name gate; creation time is the identity.
  $liveStart = $null
  try { $liveStart = $liveNow.StartTime } catch { $liveStart = $null }   # access-denied on some procs -> name gate only
  $snapStart = $null
  if ($rec) { $snapStart = $rec.CreationDate }
  if (-not (Test-ProcessStartMatches -SnapshotCreation $snapStart -LiveStart $liveStart)) {
    Write-Warning "[sweep-codex-orphans] pid $procId ('$curName') start time differs from the enumeration snapshot (recycled pid) - SKIP (pid-reuse safety)."
    $skippedRecycled++
    continue
  }
  try {
    Stop-Process -Id $procId -Force -ErrorAction Stop
    $killed++
    [void]$killedPids.Add([int]$procId)
    if ($brokerPidSet.Contains([int]$procId)) { [void]$killedBrokerPids.Add([int]$procId) }
  } catch {
    Write-Warning "[sweep-codex-orphans] could not stop pid $procId ('$curName'): $_"
    # HIMMEL-1509: this pid passed every classification + name + identity gate
    # and only the stop itself was refused (e.g. the HIMMEL-1508 Session-0
    # elevation gap) - exactly the evidence the kill-ledger exists to carry.
    $snapCreationIso = $null
    if ($rec -and $rec.PSObject.Properties['CreationDate'] -and $null -ne $rec.CreationDate) {
      try { $snapCreationIso = ([datetime]$rec.CreationDate).ToUniversalTime().ToString('o') } catch { $snapCreationIso = $null }
    }
    $failedToken = $null
    if ($pidTokenMap.ContainsKey([string]$procId)) { $failedToken = $pidTokenMap[[string]$procId] }
    [void]$ledgerFailed.Add([pscustomobject]@{ Pid = [int]$procId; Name = $curName; Creation = $snapCreationIso; Token = $failedToken })
  }
}

# HIMMEL-1509: append the verified-but-unstoppable pids to the kill-ledger and
# retire (`consumed`) entries whose recorded process is confirmed gone.
if ($ledgerFailed.Count -gt 0) {
  try {
    if (-not (Test-Path -LiteralPath $renderLeaseRegistry)) { [void](New-Item -ItemType Directory -Force -Path $renderLeaseRegistry) }
    foreach ($f in $ledgerFailed) {
      Add-KillLedgerLine -Path $killLedgerPath -Object ([ordered]@{
        type = 'kill-failed'; ts = [datetime]::UtcNow.ToString('o')
        token = $f.Token; pid = $f.Pid; name = $f.Name; creation = $f.Creation
        reason = 'stop-failed'
      })
    }
    Write-Host ("[sweep-codex-orphans] kill-ledger: appended {0} stop-failed entr(y/ies) to {1}" -f $ledgerFailed.Count, $killLedgerPath)
  } catch {
    Write-Warning "[sweep-codex-orphans] could not append to kill-ledger ($killLedgerPath): $_"
  }
}
if (Test-Path -LiteralPath $killLedgerPath) {
  try {
    $ledgerRetired = 0
    foreach ($entry in @(ConvertFrom-KillLedger -Lines @(Get-Content -LiteralPath $killLedgerPath -ErrorAction Stop))) {
      $entryPid = 0
      try { $entryPid = [int]$entry.pid } catch { continue }
      if ($entryPid -le 0) { continue }
      $entryGone = $false
      try { [void](Get-Process -Id $entryPid -ErrorAction Stop) } catch { $entryGone = $true }
      if ($entryGone) {
        Add-KillLedgerLine -Path $killLedgerPath -Object ([ordered]@{ type = 'consumed'; ts = [datetime]::UtcNow.ToString('o'); pid = $entryPid; creation = $entry.creation; reason = 'gone' })
        $ledgerRetired++
      }
    }
    if ($ledgerRetired -gt 0) { Write-Host ("[sweep-codex-orphans] kill-ledger: consumed {0} resolved entr(y/ies)." -f $ledgerRetired) }
  } catch {
    Write-Warning "[sweep-codex-orphans] could not consume kill-ledger entries ($killLedgerPath): $_"
  }
}
} finally {
  if ($leaseLock) { Unlock-RenderLeaseRegistry -LockPath $leaseLock }
}

# Clean stale $env:TEMP\cxc-<token>\broker.pid files - ONLY for trees whose
# broker was CONFIRMED stopped above (silent-failure CR: a tree whose broker
# kill failed or was skipped is still alive; deleting its pid file would strip
# a live broker's own bookkeeping while the summary reads as "stale removed").
$tempRoot = [string]$env:TEMP
$sweptTokens = @($trees | Where-Object { $killedBrokerPids.Contains([int]$_.BrokerPid) } | ForEach-Object { $_.Token } | Where-Object { $_ })
$pidFilesRemoved = 0
if ($tempRoot -and $sweptTokens.Count -gt 0 -and (Test-Path -LiteralPath $tempRoot)) {
  foreach ($tok in $sweptTokens) {
    # Charset gate before the path join (codex CR round 3): a token from a
    # crafted command line could carry ..\ traversal - never join it.
    if (-not (Test-CxcTokenPathSafe -Token $tok)) {
      Write-Warning "[sweep-codex-orphans] token '$tok' contains non-path-safe characters - skipping its broker.pid cleanup."
      continue
    }
    $pidFile = Join-Path $tempRoot "cxc-$tok\broker.pid"
    if (Test-Path -LiteralPath $pidFile) {
      try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction Stop; $pidFilesRemoved++ } catch {
        Write-Warning "[sweep-codex-orphans] could not remove $pidFile`: $_"
      }
    }
  }
}

# Reclaimed MB from pids ACTUALLY stopped, not the candidate total (codex CR
# round 5): skipped / failed stops must not inflate the success report. The
# candidate total stays as context so partial sweeps are visible at a glance.
$reclaimedMB = 0
if ($killedPids.Count -gt 0) { $reclaimedMB = Get-TreeWSMB -Pids ([int[]]$killedPids.ToArray()) }
$sweepFailed = $killFlatPids.Count - $killed - $skippedGone - $skippedName - $skippedRecycled
Write-Host ("[sweep-codex-orphans] {0} candidate tree(s) ({1} lease-spared/deferred): stopped {2} of {3} proc(s) ({4} name-skipped, {5} recycled-skipped, {6} already-gone, {7} stop-failed), removed {8} stale broker.pid file(s). ~{9} MB reclaimed (candidates totalled ~{10} MB)." `
  -f $trees.Count, $leaseExcludedTrees, $killed, $killFlatPids.Count, $skippedName, $skippedRecycled, $skippedGone, $sweepFailed, $pidFilesRemoved, $reclaimedMB, $totalMB)

exit 0
