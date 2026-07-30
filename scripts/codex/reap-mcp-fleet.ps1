# reap-mcp-fleet.ps1 (HIMMEL-741) - report/reap ORPHANED Codex MCP-fleet processes.
#
# WHY: the Codex app-server (`codex.exe app-server`, launched via
# app-server-broker.mjs) spawns a fleet of ~5-6 MCP server processes per job
# (node_repl.exe, `uvx mcp-obsidian`, `bun ... --cwd <codex plugin cache> start`
# and their `bun server.ts` grandchildren) and does NOT reap them when the job
# ends. Repeated jobs pile up dozens of leaked node/bun/uvx processes on this
# Windows box. This tool surfaces (default) or terminates (--kill) ONLY the
# fleet processes whose Codex app-server ancestor is GONE - never a fleet with a
# live app-server (that fleet is legitimately in use).
#
# HIMMEL-840 EXTENSION: the codex-exec CLI sandbox (a DIFFERENT lane than the
# app-server above, dispatched via dispatch-codex-exec.sh) leaks its own MCP
# fleet - plain `npx <mcp-server>` under `cmd.exe` wrappers with NO codex path
# marker of their own once the `codex.exe` supervisor is gone, structurally
# invisible to the Test-CodexOwned fingerprint above. Two new primitives close
# that gap:
#   -RootPid <pid> [-StartedAt <epoch>] [-Kill] - report/reap every LIVE
#     descendant of a given (possibly dead) root pid, walking ParentProcessId
#     links down from RootPid over the current table (the dispatcher's own
#     EXIT trap calls this with its codex child's pid right after that child
#     exits - anything still alive under it is, by construction, a leak).
#     -StartedAt guards pid-reuse: a would-be descendant whose own
#     CreationDate predates the job start is excluded (it belongs to whatever
#     unrelated process now holds that pid, not our job).
#   Registry-driven maintenance (default mode, no -RootPid): in addition to
#     the app-server orphan scan above, reads the job registry dispatch-
#     codex-exec.sh writes (CODEX_JOBS_DIR, default
#     ~/.himmel/state/codex-exec-jobs/*.json) and, for every entry whose
#     codex_pid is dead (the dispatcher's own EXIT-trap reap never ran, or
#     died before it could - e.g. a SIGKILL), reports (default) / reaps
#     (-Kill) its descendants the same way, removing the entry under -Kill.
#     Also prints a summary line (registered jobs live/dead, dead-job fleet
#     count, app-server orphan count) plus an OBSERVABILITY-ONLY count of
#     MCP-shaped processes with a dead direct parent that carry no codex
#     lineage evidence at all (unregistered/historic leaks) - counted, never
#     killed (no marker to prove they are ours; the conservative "when unsure,
#     exclude" rule from the app-server fingerprint applies here too).
#
# HIMMEL-1328 EXTENSION: a second, entirely distinct leak class - duplicate
# MCP-fleet children under a LIVE app-server. Get-OrphanFleet above only ever
# fires when the supervisor is DEAD; a job that respawns its fleet (e.g. one
# `luna-correlate` MCP server per retried request) while the app-server stays
# alive the whole time produces N live instances of the same server under one
# supervisor, and the orphan scan truthfully reports 0 - the ancestor chain is
# fully live, so nothing is "orphaned". Observed on this machine 2026-07-28:
# one live codex.exe had 5 concurrent luna-correlate servers, a second had 3
# more - 8 processes silently holding memory with zero signal anywhere. Report-
# only (no -Kill for this class - killing a duplicate under a live supervisor
# is a separate, riskier decision the operator has not made): for each LIVE
# app-server (Name codex.exe - never the broker; multiple live app-servers
# under one broker are the ALREADY-DOCUMENTED normal topology below, not a
# duplicate), groups its IMMEDIATE children by server identity (the plugin-
# cache package name for a `bun --cwd .../plugins/cache/<vendor>/<name>/...`
# launch, the leading package argument for `uvx`/`npx`, else the process
# Name) and flags any identity with more than one live instance. Printed as
# its own report block plus its own summary-line count, distinct from the
# orphan count (HIMMEL-1328: "0 orphans, 8 duplicates" must be expressible).
#
# GROUNDING (verified on this machine, 2026-07-07):
#   Live topology, one app-server subtree (`Get-CimInstance Win32_Process`):
#     codex.exe app-server (pid 51184)               <- SUPERVISOR
#       |- node_repl.exe   ...\OpenAI\Codex\runtimes\cua_node\...\node_repl.exe
#       |- uvx.exe         "...\uvx.exe" mcp-obsidian
#       |- bun.exe         run --cwd C:/Users/.../.codex/plugins/cache/himmel/luna-correlate/... start
#       |    \- bun.exe    server.ts        (grandchild, no codex marker of its own)
#       \- bun.exe         run --cwd C:/Users/.../.codex/plugins/cache/himmel/telegram-himmel/... start
#   The broker that owns the app-server:
#     node ...\.claude\plugins\cache\openai-codex\codex\1.0.5\scripts\app-server-broker.mjs serve ...
#   Multiple app-servers (51184 / 28748 / 61016 / desktop-app 66900) each carry
#   their own fleet -> that duplication IS the flood.
#
# FINGERPRINT (deliberately conservative - "when unsure, exclude"):
#   codex-owned  = own CommandLine references a codex-only path
#                  (OpenAI\Codex\runtimes  OR  \.codex\plugins\cache\)  OR  Name=node_repl.exe.
#                  These survive their parent's death (own cmdline still proves lineage).
#   supervisor   = Name codex.exe/Codex.exe (app-server + desktop app)  OR  app-server-broker.mjs.
#   A process is ORPHANED when it is codex-owned (or a descendant of a codex-owned
#   process still in the table) AND walking its ParentProcessId chain reaches a
#   dead/absent ancestor WITHOUT passing a LIVE supervisor.
#   Bare `uvx mcp-obsidian` / `bun server.ts` whose whole codex parent chain has
#   already vanished are NOT reaped (no codex marker to prove lineage) - the SAFE
#   under-reap direction, mirroring restart-bridge.ps1's server.ts handling.
#
# USAGE:
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1            # report-only (default; app-server scan + registry maintenance)
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1 -Kill     # terminate the orphans + dead-job registry fleets
#   pwsh -NoProfile -File scripts/codex/reap-mcp-fleet.ps1 -RootPid <pid> [-StartedAt <epoch>] [-Kill]
#                                                                     # HIMMEL-840: report/reap descendants of one root pid
# Exit codes: 0 = ran (report or kill); 1 = usage/enumeration error.

[CmdletBinding()]
param(
  [switch]$Kill,
  # HIMMEL-840: single-root descendant-reap primitive (dispatch-codex-exec.sh's
  # own EXIT trap). 0 = not provided (a real pid is never 0) -> default mode.
  [int]$RootPid = 0,
  [string]$StartedAt = '',
  # Dot-source seam for the hermetic test: define the functions, then return
  # WITHOUT scanning the live process table.
  [switch]$AsLibrary
)

# --- pure predicates + filter (fed a records array; unit-tested directly) ----

function Test-CodexOwned {
  param([Parameter(Mandatory)]$Proc)
  if ($Proc.Name -and ($Proc.Name -ieq 'node_repl.exe')) { return $true }
  $cl = [string]$Proc.CommandLine
  if (-not $cl) { return $false }
  return ($cl -match 'OpenAI[\\/]+Codex[\\/]+runtimes') -or ($cl -match '[\\/]+\.codex[\\/]+plugins[\\/]+cache[\\/]+')
}

function Test-FleetSupervisor {
  param([Parameter(Mandatory)]$Proc)
  if ($Proc.Name -and ($Proc.Name -ieq 'codex.exe')) { return $true }
  $cl = [string]$Proc.CommandLine
  if ($cl -and ($cl -match 'app-server-broker\.mjs')) { return $true }
  return $false
}

# Walk the ParentProcessId chain over the supplied (live) record set.
# Returns a hashtable: HasLiveSupervisor (bool), UnderCodex (bool - an ancestor
# is codex-owned), DeadAncestorPid (first parent pid absent from the table, or $null).
function Resolve-Ancestry {
  param([Parameter(Mandatory)]$Proc, [Parameter(Mandatory)][hashtable]$ByPid)
  $hasSup = $false; $underCodex = $false; $deadPid = $null
  $seen = @{}
  $cur = $Proc.ParentProcessId
  $depth = 0
  while ($null -ne $cur -and $cur -ne 0 -and $depth -lt 64) {
    $depth++
    if ($seen.ContainsKey([string]$cur)) { break }   # pid-reuse cycle guard
    $seen[[string]$cur] = $true
    if (-not $ByPid.ContainsKey([string]$cur)) { $deadPid = $cur; break }  # ancestor gone
    $anc = $ByPid[[string]$cur]
    if (Test-FleetSupervisor -Proc $anc) { $hasSup = $true; break }
    if (Test-CodexOwned -Proc $anc)      { $underCodex = $true }
    $cur = $anc.ParentProcessId
  }
  return @{ HasLiveSupervisor = $hasSup; UnderCodex = $underCodex; DeadAncestorPid = $deadPid }
}

# Pure orphan filter. $Procs = array of records exposing ProcessId,
# ParentProcessId, Name, CommandLine (CreationDate optional). Returns the orphan
# records annotated with a DeadAncestorPid note.
function Get-OrphanFleet {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $byPid = @{}
  foreach ($p in $Procs) { if ($null -ne $p.ProcessId) { $byPid[[string]$p.ProcessId] = $p } }
  $out = New-Object System.Collections.ArrayList
  foreach ($p in $Procs) {
    $isCodex = Test-CodexOwned -Proc $p
    # A supervisor (the app-server / broker) is NEVER a reap target.
    if (Test-FleetSupervisor -Proc $p) { continue }
    $anc = Resolve-Ancestry -Proc $p -ByPid $byPid
    $fleetRelated = $isCodex -or $anc.UnderCodex
    # Orphan requires EVIDENCE of a broken chain (a dead/absent ancestor pid),
    # not merely the absence of a recognized supervisor: a codex-owned process
    # whose fully-live chain roots at PID 0 or an unrecognized supervisor
    # variant must never be reaped (conservative under-reap).
    if ($fleetRelated -and -not $anc.HasLiveSupervisor -and $null -ne $anc.DeadAncestorPid) {
      $p | Add-Member -NotePropertyName DeadAncestorPid -NotePropertyValue $anc.DeadAncestorPid -Force
      [void]$out.Add($p)
    }
  }
  return $out.ToArray()
}

# Test-AppServerSupervisor (HIMMEL-1328) - narrower than Test-FleetSupervisor:
# true only for the actual MCP-fleet owner (codex.exe app-server / desktop
# app), never the broker. Multiple LIVE app-servers under one broker are a
# normal, already-documented topology (see GROUNDING above) and must never be
# flagged as duplicates - only an app-server's OWN immediate MCP-fleet
# children are candidates for the duplicate-instance check below.
function Test-AppServerSupervisor {
  param([Parameter(Mandatory)]$Proc)
  return [bool]($Proc.Name -and ($Proc.Name -ieq 'codex.exe'))
}

# Get-ServerIdentity (HIMMEL-1328) - normalizes a fleet child's CommandLine
# into the "which server is this" identity used to group duplicates. Prefers
# the plugin-cache package name (distinguishes `luna-correlate` from
# `telegram-himmel` even though both launch as bun.exe), then the LEADING
# package argument of a uvx/npx invocation - including the `cmd.exe /c npx
# <pkg>` wrapper shape the HIMMEL-840 EXTENSION above documents (without this,
# every cmd.exe-wrapped npx server would collapse into one "cmd.exe" bucket
# regardless of which package it launches - a false-positive risk for two
# genuinely different servers, not just repeated instances of one). Falls
# back to the process Name when nothing more specific is found.
#
# KNOWN LIMITATION, deliberately deferred (codex adversarial review,
# HIMMEL-1328): the plugin-cache branch captures only the PACKAGE segment
# (`luna-correlate`), discarding the VENDOR segment that precedes it
# (`himmel`) - two different vendors publishing a same-named package would
# collapse to one identity. Every plugin observed on this host (and in this
# file's own GROUNDING) installs under the single `himmel` vendor namespace,
# so this is real for a multi-vendor deployment but not for this one; fixing
# it means changing the captured identity shape (`vendor/package`), which
# ripples through every existing fixture/assertion below - deferred rather
# than done reflexively at the tail of an already-long review cycle. File a
# follow-up ticket if a multi-vendor plugin cache is ever in play.
#
# Takes the FIRST qualifying token, not the last (panel review, HIMMEL-1328):
# uvx/npx CLI convention is `uvx|npx [flags] <package> [package's own args]`,
# so the package name is the leading positional argument, not the trailing
# one - `uvx mcp-obsidian --extra positional-arg` must resolve to
# `mcp-obsidian`, not `positional-arg`.
#
# Walks the split tokens in order rather than filtering the whole array at
# once (codex adversarial review, HIMMEL-1328 - two rounds): a naive
# "drop flag names, take the first survivor" filter still fails when a flag
# TAKES A VALUE - the value itself has no `-` prefix, so it survives the
# filter and gets mistaken for the package. `uvx --python 3.12 server-a` and
# `--python 3.12 server-b` both resolved to `3.12`; `uvx --from ./local-pkg
# mcp-server` resolved to `./local-pkg` - both reproduced directly before
# fixing. $ValueTakingFlags is a best-effort, not exhaustive, list of the
# uvx/npx (uv/npm) flags known to consume a following value; the walk skips
# a listed flag AND its value together, skips any OTHER `-`-leading token
# alone (an unknown or boolean flag), and returns the first remaining token
# that also isn't a path fragment, a bare version number, an npx/uvx/cmd
# executable name itself, or a Windows-style `/flag` (cmd.exe's own
# switches, e.g. `/e:ON`, when this walk is scanning a `cmd.exe /c npx ...`
# wrapper's full command line). The `[:\\]` exclusion drops a split artifact
# from a quoted Windows path containing a space (e.g. `"C:\Program
# Files\nodejs\npx.cmd"` splits into `C:\Program` + `Files\...` on the
# quote/whitespace delimiter) so that fragment can never be picked ahead of
# the real package token that follows it.
#
# Tokenization (CodeRabbit App review, HIMMEL-1328): splitting on runs of
# quote-or-whitespace chars (`-split '["\s]+'`) fragments a QUOTED,
# space-containing flag VALUE into multiple raw tokens, so `$i += 2` only
# consumes the first fragment and a later fragment (e.g. `dir` from `--with
# "some dir"`) reaches the candidate filter and gets mistaken for the
# package - reproduced directly before fixing. `[regex]::Matches` with
# `"[^"]+"|[^"\s]+` keeps a non-empty quoted span as ONE token instead. A
# naive quote-aware pattern like `"[^"]*"|\S+` (permitting EMPTY quoted
# content, and matching quote chars via `\S`) looks equivalent but breaks
# the doubled-quote `cmd.exe /c "".." "` fixture below: it turns the
# adjacent opening quotes into a spurious empty `""` token (which then
# passes every filter and is returned as `""`) and leaves a stray trailing
# quote glued onto the real package token. Requiring non-empty quoted
# content, and excluding bare quote chars from the plain-token alternative,
# avoids both - adjacent/unpaired quote chars are simply skipped, matching
# the old delimiter-based split's behavior for that fixture. Filtering runs
# against the quote-stripped token ($tUnquoted) rather than the raw one, so
# a whole quoted span (e.g. a quoted `.exe` path) is still caught by the
# extension/colon/backslash exclusions the same way a delimiter-split
# fragment of it would have been.
$script:ValueTakingUvxNpxFlags = @(
  '--python', '-p', '--from', '--with', '--package',
  '--index', '--index-url', '--extra-index-url', '--index-strategy',
  '--config-file', '--project', '--directory'
)
function Get-ServerIdentity {
  param([Parameter(Mandatory)]$Proc)
  $cl = [string]$Proc.CommandLine
  if ($cl) {
    if ($cl -match '[\\/]+\.codex[\\/]+plugins[\\/]+cache[\\/]+[^\\/]+[\\/]+([^\\/]+)[\\/]+') {
      return $Matches[1]
    }
    $isUvxNpx = $Proc.Name -and ($Proc.Name -ieq 'uvx.exe' -or $Proc.Name -ieq 'npx.exe')
    $isCmdNpx = $Proc.Name -and ($Proc.Name -ieq 'cmd.exe') -and ($cl -match 'npx(\.cmd)?["\s]')
    if ($isUvxNpx -or $isCmdNpx) {
      $rawTokens = @([regex]::Matches($cl, '"[^"]+"|[^"\s]+') | ForEach-Object { $_.Value })
      $i = 0
      while ($i -lt $rawTokens.Count) {
        $t = $rawTokens[$i]
        if ($script:ValueTakingUvxNpxFlags -contains $t) { $i += 2; continue }  # skip the flag AND its value
        if ($t -match '^-') { $i += 1; continue }                              # skip an unknown/boolean flag alone
        $tUnquoted = $t.Trim('"')
        $isCandidate = ($tUnquoted -notmatch '^/') -and ($tUnquoted -notmatch '\.(exe|cmd)$') -and
          ($tUnquoted -notmatch '^(cmd|npx|uvx)$') -and ($tUnquoted -notmatch '[:\\]') -and
          ($tUnquoted -notmatch '^\d+(\.\d+)*$')
        if ($isCandidate) { return $tUnquoted }
        $i += 1
      }
    }
  }
  # A generic OS shell/wrapper OR generic language-runtime launcher is never
  # itself a distinct server identity - falling back to its bare Name would
  # group unrelated invocations as if they were the same duplicated server,
  # corrupting the report (panel + codex adversarial review, HIMMEL-1328;
  # `node.exe`/`bun.exe`/`uvx.exe`/`npx.exe` added on a follow-up panel round
  # - glm-3 - same reasoning as the shell wrappers: a bare `node.exe`/
  # `bun.exe` child that does NOT match the plugin-cache regex above, or a
  # `uvx.exe`/`npx.exe` child whose command line yields zero tokens above,
  # could launch ANY package - the executable name alone identifies nothing).
  # Return $null instead of guessing; Get-DuplicateFleets excludes children
  # with no resolved identity from grouping entirely rather than lump them
  # under a meaningless shared key. Every OTHER process shape (node_repl.exe,
  # qmd.exe, tokensave.exe, ...) still falls through to its own bare Name
  # below - those ARE legitimate, already-observed distinct server identities
  # in their own right (a purpose-built binary name IS the identity), unlike
  # a generic runtime/wrapper that says nothing about what it is running.
  if ($Proc.Name -and ($Proc.Name -in @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'conhost.exe', 'node.exe', 'bun.exe', 'uvx.exe', 'npx.exe'))) {
    return $null
  }
  return [string]$Proc.Name
}

# Get-DuplicateFleets (HIMMEL-1328) - pure grouping filter, sibling to
# Get-OrphanFleet. For each LIVE app-server (Test-AppServerSupervisor), groups
# its IMMEDIATE children (ParentProcessId = the app-server's own pid) by
# Get-ServerIdentity and flags any identity with more than one live instance.
# This is deliberately independent of Resolve-Ancestry/Get-OrphanFleet - every
# process involved here is fully live, so "orphan" evidence (a dead ancestor)
# neither applies nor is required. Returns group records: SupervisorPid,
# Identity, Count, Pids (array of the duplicate instances' ProcessIds).
function Get-DuplicateFleets {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs)
  $out = New-Object System.Collections.ArrayList
  $supervisors = @($Procs | Where-Object { Test-AppServerSupervisor -Proc $_ })
  foreach ($sup in $supervisors) {
    # Exclude children Get-ServerIdentity refuses to identify (a generic
    # shell/wrapper Name with no more specific signal - see its own comment)
    # BEFORE grouping, so they never collapse into one meaningless "$null" bucket.
    #
    # Stale-PPID guard (codex adversarial review, HIMMEL-1328): Windows does
    # NOT clear a process's recorded ParentProcessId when its real parent
    # exits, so pid reuse can make an unrelated, long-dead-parent process
    # appear as a "child" of a freshly-started supervisor that was simply
    # assigned the same pid its true parent used to hold. reap-superseded-
    # fleets.ps1's Select-VerifiedDescendants solves the identical problem
    # for a DIFFERENT (kill-context) walk in this same directory - mirror its
    # convention (2s tolerance for creation-time rounding/conversion, per its
    # own comment) rather than inventing a new one. Deliberately BEST-EFFORT,
    # not fail-closed like that kill-context sibling: this file's own
    # Get-OrphanFleet/Resolve-Ancestry above never required CreationDate
    # either, and a report-only false positive is a much lower-stakes miss
    # than a wrongful kill - so when CreationDate is unavailable on either
    # side (e.g. a hermetic test fixture that never sets it), the check is
    # skipped rather than excluding the child outright.
    $supCreated = $null
    if ($sup.PSObject.Properties['CreationDate'] -and ($sup.CreationDate -is [datetime])) { $supCreated = $sup.CreationDate }
    $children = @($Procs | Where-Object {
      if ($_.ParentProcessId -ne $sup.ProcessId) { return $false }
      if (-not (Get-ServerIdentity -Proc $_)) { return $false }
      if ($null -ne $supCreated -and $_.PSObject.Properties['CreationDate'] -and ($_.CreationDate -is [datetime])) {
        if ((New-TimeSpan -Start $supCreated -End $_.CreationDate).TotalSeconds -lt -2) { return $false }  # predates the supervisor - stale PPID, not a real child
      }
      return $true
    })
    if ($children.Count -eq 0) { continue }
    $groups = $children | Group-Object -Property { Get-ServerIdentity -Proc $_ }
    foreach ($g in $groups) {
      if ($g.Count -le 1) { continue }
      [void]$out.Add([pscustomobject]@{
        SupervisorPid = $sup.ProcessId
        Identity      = $g.Name
        Count         = $g.Count
        Pids          = @($g.Group | ForEach-Object { $_.ProcessId })
      })
    }
  }
  return $out.ToArray()
}

# Get-DescendantPids (HIMMEL-840) - pure descendant walk. Returns every LIVE
# pid in $Procs reachable from $RootPid by following ParentProcessId links
# DOWNWARD (children, grandchildren, ...). $RootPid itself need not be present
# in $Procs (it is typically already dead - that is why we are reaping) - a
# direct child still records the dead root's pid as its own ParentProcessId,
# which is all the walk needs to find it. $StartedAtEpoch, when given, guards
# pid-reuse: a candidate descendant whose own CreationDate predates the job
# start is excluded (and its subtree is NOT traversed - conservative
# under-reap, mirrors Get-OrphanFleet's stance).
function Get-DescendantPids {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Procs,
    [Parameter(Mandatory)][int]$RootPid,
    [Nullable[long]]$StartedAtEpoch = $null
  )
  $byParent = @{}
  foreach ($p in $Procs) {
    $key = [string]$p.ParentProcessId
    if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
    [void]$byParent[$key].Add($p)
  }
  $result = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Generic.Queue[int]
  $queue.Enqueue($RootPid)
  $visited = @{}
  $depth = 0
  while ($queue.Count -gt 0 -and $depth -lt 4096) {
    $depth++
    $cur = $queue.Dequeue()
    $curKey = [string]$cur
    if ($visited.ContainsKey($curKey)) { continue }   # pid-reuse cycle guard
    $visited[$curKey] = $true
    if (-not $byParent.ContainsKey($curKey)) { continue }
    foreach ($child in $byParent[$curKey]) {
      if ($null -ne $StartedAtEpoch -and $child.CreationDate -is [datetime]) {
        $childEpoch = [long][DateTimeOffset]::new($child.CreationDate.ToUniversalTime()).ToUnixTimeSeconds()
        if ($childEpoch -lt $StartedAtEpoch) { continue }  # predates the job - not ours (pid-reuse guard)
      }
      [void]$result.Add([int]$child.ProcessId)
      $queue.Enqueue([int]$child.ProcessId)
    }
  }
  return $result.ToArray()
}

# Test-McpShaped (HIMMEL-840, observability-only) - a coarse "looks like an
# MCP-server-launching process" predicate used ONLY for the report-mode
# visibility count of unregistered/historic dead-parent leaks (point 4). It is
# deliberately looser than Test-CodexOwned (no path-marker requirement) and
# MUST NEVER drive a kill decision - it has no lineage evidence, just a name/
# cmdline shape shared by legitimate live-Claude MCP servers too.
function Test-McpShaped {
  param([Parameter(Mandatory)]$Proc)
  if (-not $Proc.Name) { return $false }
  if ($Proc.Name -in @('node.exe', 'bun.exe', 'uvx.exe', 'npx.exe')) { return $true }
  if ($Proc.Name -ieq 'cmd.exe') {
    $cl = [string]$Proc.CommandLine
    return ($cl -match 'npx(\.cmd)?\s')
  }
  return $false
}

if ($AsLibrary) { return }

# --- production path: enumerate the live table, report, optionally kill -------

$ErrorActionPreference = 'Stop'

try {
  $records = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    ForEach-Object {
      [pscustomobject]@{
        ProcessId       = [int]$_.ProcessId
        ParentProcessId = [int]$_.ParentProcessId
        Name            = [string]$_.Name
        CommandLine     = [string]$_.CommandLine
        CreationDate    = $_.CreationDate
      }
    })
} catch {
  Write-Error "[reap-mcp-fleet] could not enumerate processes: $_"
  exit 1
}

# --- HIMMEL-840: -RootPid mode - report/reap descendants of ONE root pid ----
# (the dispatcher's own EXIT trap, called with its codex child's pid).
if ($RootPid -gt 0) {
  # Entry-point safety parity with the registry-scan path below (which skips a
  # job whose codex_pid is still present in the table): a caller-supplied root
  # pid that is itself still alive must abort, not walk descendants - a live
  # root's own fleet is legitimately in use, not a leak.
  $byPidRoot = @{}
  foreach ($p in $records) { $byPidRoot[[string]$p.ProcessId] = $p }
  if ($byPidRoot.ContainsKey([string]$RootPid)) {
    Write-Host "[reap-mcp-fleet] pid $RootPid is still alive - skipping descendant walk (only reap descendants of a dead root)."
    exit 0
  }
  $startedEpoch = $null
  if ($StartedAt) {
    $parsed = 0L
    if ([long]::TryParse($StartedAt, [ref]$parsed)) { $startedEpoch = $parsed }
  }
  $descendants = @(Get-DescendantPids -Procs $records -RootPid $RootPid -StartedAtEpoch $startedEpoch)
  if ($descendants.Count -eq 0) {
    Write-Host "[reap-mcp-fleet] no live descendants of pid $RootPid."
    exit 0
  }
  Write-Host ("[reap-mcp-fleet] {0} descendant process(es) of pid {1}:" -f $descendants.Count, $RootPid)
  foreach ($d in $descendants) {
    $nm = if ($byPidRoot.ContainsKey([string]$d)) { $byPidRoot[[string]$d].Name } else { '?' }
    Write-Host "  pid $d ($nm)"
  }
  if (-not $Kill) {
    Write-Host "[reap-mcp-fleet] report-only (default). Re-run with -Kill to terminate the above."
    exit 0
  }
  $killedRoot = 0
  foreach ($d in $descendants) {
    try {
      Stop-Process -Id $d -Force -ErrorAction Stop
      $killedRoot++
    } catch {
      Write-Warning "[reap-mcp-fleet] could not kill pid $d`: $_"
    }
  }
  Write-Host ("[reap-mcp-fleet] terminated {0}/{1} descendant(s) of pid {2}." -f $killedRoot, $descendants.Count, $RootPid)
  exit 0
}

# --- default mode: app-server orphan scan + registry-driven maintenance -----

$orphans = @(Get-OrphanFleet -Procs $records)

if ($orphans.Count -eq 0) {
  Write-Host "[reap-mcp-fleet] no orphaned Codex MCP-fleet processes found."
} else {
  $now = Get-Date
  $rows = $orphans | ForEach-Object {
    $ageStr = '?'
    if ($_.CreationDate -is [datetime]) {
      $mins = [int]([math]::Round(($now - $_.CreationDate).TotalMinutes))
      $ageStr = "${mins}m"
    }
    $snip = if ($_.CommandLine) { $_.CommandLine.Substring(0, [Math]::Min(80, $_.CommandLine.Length)) } else { '' }
    [pscustomobject]@{
      PID          = $_.ProcessId
      Name         = $_.Name
      Age          = $ageStr
      DeadAncestor = $_.DeadAncestorPid
      Cmdline      = $snip
    }
  }

  Write-Host ("[reap-mcp-fleet] {0} orphaned Codex MCP-fleet process(es):" -f $orphans.Count)
  $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

  if (-not $Kill) {
    Write-Host "[reap-mcp-fleet] report-only (default). Re-run with -Kill to terminate the above."
  } else {
    $killed = 0
    foreach ($o in $orphans) {
      try {
        Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop
        Write-Host "[reap-mcp-fleet] killed pid $($o.ProcessId) ($($o.Name))"
        $killed++
      } catch {
        Write-Warning "[reap-mcp-fleet] could not kill pid $($o.ProcessId): $_"
      }
    }
    Write-Host ("[reap-mcp-fleet] terminated {0}/{1} orphan(s)." -f $killed, $orphans.Count)
  }
}

# --- HIMMEL-1328: duplicate MCP-fleet children under a LIVE app-server ------
# Distinct leak class from the orphan scan above - every process here is
# fully live throughout, so it is invisible to Get-OrphanFleet by design.
# Report-only: no -Kill wiring for this class (see header).
$duplicates = @(Get-DuplicateFleets -Procs $records)
$duplicateInstanceTotal = 0
if ($duplicates.Count -gt 0) { $duplicateInstanceTotal = ($duplicates | Measure-Object -Property Count -Sum).Sum }

if ($duplicates.Count -eq 0) {
  Write-Host "[reap-mcp-fleet] no duplicate MCP-fleet servers found under any live app-server."
} else {
  $dupRows = $duplicates | ForEach-Object {
    [pscustomobject]@{
      Supervisor = $_.SupervisorPid
      Identity   = $_.Identity
      Count      = $_.Count
      Pids       = ($_.Pids -join ',')
    }
  }
  Write-Host ("[reap-mcp-fleet] {0} duplicate MCP-server group(s) under LIVE app-server(s) ({1} instance(s) total):" -f $duplicates.Count, $duplicateInstanceTotal)
  $dupRows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  Write-Host "[reap-mcp-fleet] report-only - duplicates under a live supervisor are never killed by this tool."
}

# --- HIMMEL-840: registry-driven maintenance (visibility surface, point 4) --
# Every job dispatch-codex-exec.sh registered under CODEX_JOBS_DIR whose
# codex_pid is now dead is a leak the dispatcher's own EXIT-trap reap never
# cleaned up (killed before it could run). Report (default) or reap (-Kill)
# its remaining descendants the same way -RootPid does, and drop the entry
# under -Kill (a report-only pass must not mutate state).
$jobsDir = if ($env:CODEX_JOBS_DIR) { $env:CODEX_JOBS_DIR } else { Join-Path $env:USERPROFILE '.himmel\state\codex-exec-jobs' }
$jobFiles = @()
if (Test-Path -LiteralPath $jobsDir) {
  $jobFiles = @(Get-ChildItem -LiteralPath $jobsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
}
$byPidAll = @{}
foreach ($p in $records) { $byPidAll[[string]$p.ProcessId] = $p }

$liveJobs = 0
$deadJobs = 0
$deadFleetTotal = 0
foreach ($jf in $jobFiles) {
  $job = $null
  try { $job = Get-Content -Raw -LiteralPath $jf.FullName | ConvertFrom-Json } catch { continue }
  if (-not $job.codex_pid) { continue }
  $jobPid = [int]$job.codex_pid
  $jobStarted = $null
  if ($job.started_at) {
    $parsedStarted = 0L
    if ([long]::TryParse([string]$job.started_at, [ref]$parsedStarted)) { $jobStarted = $parsedStarted }
  }
  if ($byPidAll.ContainsKey([string]$jobPid)) { $liveJobs++; continue }
  $deadJobs++
  $desc = @(Get-DescendantPids -Procs $records -RootPid $jobPid -StartedAtEpoch $jobStarted)
  $deadFleetTotal += $desc.Count
  if ($desc.Count -gt 0) {
    Write-Host ("[reap-mcp-fleet] registry job {0} (codex pid {1}, dead): {2} descendant fleet process(es)" -f $jf.Name, $jobPid, $desc.Count)
  }
  if ($Kill) {
    foreach ($d in $desc) {
      try { Stop-Process -Id $d -Force -ErrorAction Stop } catch { Write-Warning "[reap-mcp-fleet] could not kill pid $d`: $_" }
    }
    Remove-Item -LiteralPath $jf.FullName -Force -ErrorAction SilentlyContinue
  }
}

# Observability-only: MCP-shaped processes with a dead DIRECT parent that
# carry no codex lineage evidence at all (unregistered/historic leaks - a job
# that predates this registry, or a fleet that lost its own marker). Counted
# for visibility; NEVER reaped (no evidence they are ours - conservative
# under-reap).
$unregisteredDeadParent = 0
foreach ($p in $records) {
  if (-not (Test-McpShaped -Proc $p)) { continue }
  if (-not $byPidAll.ContainsKey([string]$p.ParentProcessId)) { $unregisteredDeadParent++ }
}

Write-Host ("[reap-mcp-fleet] registry: {0} job(s) live, {1} job(s) dead ({2} descendant fleet proc(s)); app-server orphans: {3}; duplicates under live supervisor: {4} instance(s) in {5} group(s) (report-only, never reaped); unregistered dead-parent MCP-shaped proc(s): {6} (report-only, never reaped)" `
  -f $liveJobs, $deadJobs, $deadFleetTotal, $orphans.Count, $duplicateInstanceTotal, $duplicates.Count, $unregisteredDeadParent)

exit 0
