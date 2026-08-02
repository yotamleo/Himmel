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
# THE TEST (client-side pipe-token liveness - the VALIDATED signal):
#   A broker tree is LIVE  iff  any process OUTSIDE every broker tree has a
#   command line that references the same `cxc-<token>-codex-app-server` pipe
#   (that is the client still holding it). Otherwise the tree is an ORPHAN.
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
#   2. Build the union of every broker tree, then collect the set of tokens
#      referenced by any process OUTSIDE that union. Excluding all broker roots
#      and descendants prevents their own pipe arguments from self-marking live.
#      A broker whose token is NOT in that set is an ORPHAN.
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
# USAGE:
#   pwsh -NoProfile -File scripts/cleanup/sweep-codex-orphans.ps1           # dry run (default): report orphan trees
#   pwsh -NoProfile -File scripts/cleanup/sweep-codex-orphans.ps1 -Kill     # name-verified stop + stale broker.pid cleanup
# Exit codes: 0 = nothing to sweep OR sweep done (prints count + estimated MB);
#             1 = usage / enumeration error.
# Non-Windows: exits 0 with a message (the broker leak is a Windows-observed
# pattern; the pure functions still dot-source-load for cross-platform tests).

[CmdletBinding()]
param(
  [switch]$Kill,
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

# Pure classification: the orphan brokers in $Procs - brokers whose token no
# outside-tree process references. Each returned record carries BrokerPid,
# Token, Cwd. The broker-tree union is built once and excludes roots plus all
# descendants before tokens are collected. Dead-parent and codex.exe-descendant
# remain INTENTIONALLY ignored (documented false signals).
function Get-CodexOrphanBrokers {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [AllowNull()]$BrokerTreePids = $null
  )
  if ($null -eq $BrokerTreePids) { $BrokerTreePids = Get-CodexBrokerTreePids -Procs $Procs }
  $liveTokens = Get-LiveClientTokens -Procs $Procs -BrokerTreePids $BrokerTreePids
  $out = New-Object System.Collections.ArrayList
  foreach ($p in $Procs) {
    if (-not (Test-IsCodexAppServerBroker -Proc $p)) { continue }
    $tok = Get-CxcToken -CommandLine ([string]$p.CommandLine)
    if ($null -eq $tok) { continue }
    if ($liveTokens -contains $tok) { continue }   # an outside client still holds it -> LIVE
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
    [AllowNull()]$BrokerTreePids = $null
  )
  $orphans = @(Get-CodexOrphanBrokers -Procs $Procs -BrokerTreePids $BrokerTreePids)
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

if ($AsLibrary) { return }

# --- production path ---------------------------------------------------------

# OS guard: the broker leak is a Windows-observed pattern; on any other OS there
# is nothing to sweep. Exit 0 (not an error) after a clear message.
if (-not (Test-OnWindows -IsWindowsValue $IsWindows -OsEnv $env:OS)) {
  Write-Host "[sweep-codex-orphans] non-Windows host (broker leak is a Windows pattern) - nothing to sweep."
  exit 0
}

$ErrorActionPreference = 'Stop'

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

# Build the broker-tree exclusion union once for both liveness classification
# and the blind-client gate; no process inside any tree can be client evidence.
$brokerTreePids = Get-CodexBrokerTreePids -Procs $records
$trees = @(Get-CodexOrphanTrees -Procs $records -BrokerTreePids $brokerTreePids)

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

if (-not $Kill) {
  Write-Host "[sweep-codex-orphans] dry run (default). Re-run with -Kill to name-verified-stop the above + clean stale broker.pid files."
  Write-Host ("[sweep-codex-orphans] would sweep {0} tree(s), {1} proc(s), ~{2} MB." -f $trees.Count, $totalProcs, $totalMB)
  exit 0
}

if ($blindClients.Count -gt 0) {
  Write-Warning "[sweep-codex-orphans] refusing -Kill while plausible outside client command lines are invisible - re-run from a context that can see claude.exe/ChatGPT.exe/node.exe/bun.exe clients (e.g. the same elevation as the clients)."
  exit 1
}

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
foreach ($t in $trees) { [void]$brokerPidSet.Add([int]$t.BrokerPid) }
foreach ($procId in $flatPids) {
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
  }
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
$sweepFailed = $flatPids.Count - $killed - $skippedGone - $skippedName - $skippedRecycled
Write-Host ("[sweep-codex-orphans] {0} candidate tree(s): stopped {1} of {2} proc(s) ({3} name-skipped, {4} recycled-skipped, {5} already-gone, {6} stop-failed), removed {7} stale broker.pid file(s). ~{8} MB reclaimed (candidates totalled ~{9} MB)." `
  -f $trees.Count, $killed, $flatPids.Count, $skippedName, $skippedRecycled, $skippedGone, $sweepFailed, $pidFilesRemoved, $reclaimedMB, $totalMB)

exit 0
