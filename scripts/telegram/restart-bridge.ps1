# restart-bridge.ps1 — safely (re)start the Telegram bridge on Windows.
#
# Why this exists: the bridge enforces a SINGLE getUpdates owner per bot token.
# Duplicate pollers (left over from prior sessions or a failed launch) cause
# repeated "409 Conflict: terminated by other getUpdates request" and the bridge
# never settles. The naive fix `taskkill /F /IM bun.exe` blanket-kills EVERY bun
# process on the machine (unrelated work too) — which the auto-mode classifier
# correctly refuses. This script instead kills ONLY the bun processes whose
# command line runs the bridge (the bun supervisor.ts / poller.ts processes —
# matched by entrypoint name, not a scripts/telegram path), then starts exactly
# one supervisor, then verifies it settled (no 409).
#
# Usage (from anywhere):
#   pwsh -File scripts/telegram/restart-bridge.ps1
#   pwsh -File scripts/telegram/restart-bridge.ps1 -Repo C:/path/to/himmel
#   pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly   # report, don't touch
#
# HIMMEL-1510 additions — the sanctioned, agent-invocable remediation verb
# (modeled on HIMMEL-1509's sweep-codex-orphans.ps1 `-FromLedger -Kill`):
#   pwsh -File scripts/telegram/restart-bridge.ps1 -FromLedger              # dry run: validate + report, touch nothing
#   pwsh -File scripts/telegram/restart-bridge.ps1 -FromLedger -Kill        # validated kill + scheduled-task relaunch
#   pwsh -File scripts/telegram/restart-bridge.ps1 -Watchdog                # report offset-age staleness, touch nothing
#   pwsh -File scripts/telegram/restart-bridge.ps1 -Watchdog -Kill          # remediate (-FromLedger -Kill) ONLY if stale
#
# Exit codes: 0 = bridge up + clean (or a dry-run/watchdog report finding nothing
# wrong); 1 = usage/env error, or -FromLedger has nothing valid to act on; 2 =
# started but still seeing 409 / no proven progress after the settle window, or
# a stale watchdog report with no -Kill to remediate it (needs investigation).
[CmdletBinding()]
param(
  [string]$Repo = $(if ($env:HIMMEL_REPO) { $env:HIMMEL_REPO } else { (Resolve-Path "$PSScriptRoot/../..").Path }),
  # HIMMEL-1510: 12s was the pre-progress-verify default. It is now too short —
  # poller.ts long-polls getUpdates with a 30s Telegram timeout, so on a QUIET
  # bridge (no inbound Telegram traffic during the window) neither the offset
  # file nor a poll heartbeat can appear before ~30s even when everything is
  # healthy. 35s comfortably clears that worst case.
  [int]$SettleSeconds = 35,
  [switch]$StatusOnly,
  # HIMMEL-1510: the sanctioned, agent-invocable restart verb — modeled on
  # HIMMEL-1509's sweep-codex-orphans.ps1 `-FromLedger -Kill`. Reads
  # ~/.claude/handover/bridge/supervisor.pid — the bun supervisor's own pidfile
  # IS the ledger ({"supervisor":<pid>,"poller":<pid|null>}) — and VALIDATES
  # each pid's LIVE identity (alive, Name=bun.exe, exact expected entrypoint, and
  # created no later than the ledger write) before touching it; a
  # 0/missing/malformed/non-numeric entry, or a pid that no longer belongs to
  # the bridge (pid reuse), is REFUSED, never
  # killed. Without -Kill this only validates + reports (touches nothing);
  # with -Kill it stops ONLY the validated pid(s) and relaunches via the
  # HimmelTelegramBridge scheduled task (falling back to the same detached
  # cmd /c launch used below when that task is absent).
  [switch]$FromLedger,
  [switch]$Kill,
  # HIMMEL-1510: "poller alive but neither appending nor advancing the offset"
  # was invisible before this — bridgeProcs>=1 and conflictLines==0 were BOTH
  # true throughout the entire 2026-08-03 ~16h wedge. -Watchdog reports (and,
  # combined with -Kill, remediates via the -FromLedger path above) when the
  # offset file's age exceeds -OffsetAgeThresholdSeconds while bridge procs are
  # still alive.
  [switch]$Watchdog,
  [int]$OffsetAgeThresholdSeconds = 1800,
  # Rotated supervisor.log files to retain (HIMMEL-1510) — see the rotation
  # comment below for why this replaced the prior Set-Content clobber.
  [int]$LogKeep = 20,
  # Dot-source seam for the hermetic test: define the pure functions, then
  # return WITHOUT touching the live process table or the bridge.
  [switch]$AsLibrary
)

# Attribute a `bun server.ts` that survived OUTSIDE the reaped bridge set
# (HIMMEL-1309). `server.ts` is the entry point of EVERY himmel codex plugin MCP
# server, not just telegram-himmel's, and this script used to call all of them a
# "rogue telegram-himmel child … live 2nd getUpdates consumer" on the bare
# `server.ts` cmdline alone. On 2026-07-27 that reported 45 `luna-correlate` MCP
# servers as telegram rogues and sent an investigation down the wrong path (it is
# the wrong diagnosis recorded in HIMMEL-1309's own description). The launcher's
# `--cwd <plugin>` is the identity, so read it before claiming telegram.
# Returns 'telegram' | 'codex-plugin' | 'unattributable'.
function Get-ServerTsAttribution {
  param([Parameter(Mandatory)]$Proc, [Parameter(Mandatory)][hashtable]$ByPid)
  $parent = $null
  if ($null -ne $Proc.ParentProcessId) { $parent = $ByPid[[string]$Proc.ParentProcessId] }
  if ($null -eq $parent) { return 'unattributable' }        # launcher already gone
  $pcl = [string]$parent.CommandLine
  if (-not $pcl) { return 'unattributable' }                # launcher cmdline not readable
  if ($pcl -match '(?:^|\s)--cwd[ =](?:"([^"]+)"|(\S+))') {
    $cwd = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
    if (($cwd -replace '\\', '/') -match '(?i)/telegram-himmel(?:[/@]|$)') { return 'telegram' }
    return 'codex-plugin'
  }
  if ($pcl -match '(?i)telegram-himmel') { return 'telegram' }
  if ($pcl -match '(?i)[\\/]\.codex[\\/]plugins[\\/]cache[\\/]') { return 'codex-plugin' }
  return 'unattributable'
}

# --- HIMMEL-1510: pure helpers for the -FromLedger verb, log rotation, and the
# offset-age watchdog. Kept pure (fed injected data, never touching the live
# process table / filesystem) so the hermetic test can exercise every branch
# via -AsLibrary, same seam as Get-ServerTsAttribution above. ---

# Validates ONE ledger pid entry against a live process snapshot ($ByPid, keyed
# by [string]pid — same shape Get-BridgeProcs/the caller build from
# Get-CimInstance Win32_Process). Refuses (returns $false) on: missing/$null,
# non-integer, <= 0 (closes the pid=0 relic gap — a zero entry must never fall
# through to a broad kill), not present in $ByPid (dead OR the pid-REUSE guard —
# a recycled pid belonging to an unrelated process is not in the bridge's own
# snapshot... note $ByPid is a LIVE snapshot, so a reused pid IS present; the
# identity + creation-time checks below are what actually catch reuse), name
# mismatch, a command line that doesn't run the expected bridge role, or a
# process created AFTER the ledger was written. That final check is the specific
# pid-reuse discriminator: a replacement process cannot own the same pid until
# after the bridge process died, while the genuine process necessarily existed
# before its supervisor recorded that pid in the ledger.
function Test-LedgerPidValid {
  param(
    $Pid_,
    [Parameter(Mandatory)][ValidateSet('supervisor', 'poller')][string]$Role,
    [Parameter(Mandatory)][datetime]$LedgerLastWriteTime,
    [Parameter(Mandatory)][hashtable]$ByPid
  )
  if ($null -eq $Pid_) { return $false }
  if (-not ([int64]::TryParse([string]$Pid_, [ref]$null))) { return $false }
  $n = [int64]$Pid_
  if ($n -le 0) { return $false }
  $proc = $ByPid[[string]$n]
  if ($null -eq $proc) { return $false }                    # not alive (or a recycled pid this snapshot never saw)
  if ($proc.Name -ne 'bun.exe') { return $false }            # pid-reuse guard: same number, different process
  $cl = [string]$proc.CommandLine
  if (-not $cl) { return $false }
  if (-not ($cl -match "(?i)(?:^|[\\/\s])$Role\.ts(?:\s|$)")) { return $false }
  if ($null -eq $proc.CreationDate) { return $false }
  $created = ([datetime]$proc.CreationDate).ToUniversalTime()
  if ($created -gt $LedgerLastWriteTime.ToUniversalTime()) { return $false }
  return $true
}

# Rotated-log naming (HIMMEL-1510): `<base>.<yyyyMMdd-HHmmss-fffffff><ext>`
# alongside the live log. Fractional-second precision prevents two independent
# restart actions in the same second from targeting the same rotated log.
function Get-RotatedLogPath {
  param([Parameter(Mandatory)][string]$LogPath, [Parameter(Mandatory)][datetime]$Now)
  $dir = Split-Path -Parent $LogPath
  $base = [System.IO.Path]::GetFileNameWithoutExtension($LogPath)
  $ext = [System.IO.Path]::GetExtension($LogPath)
  $stamp = $Now.ToString('yyyyMMdd-HHmmss-fffffff')
  return Join-Path $dir "$base.$stamp$ext"
}

# Offset-age computation (HIMMEL-1510), pure: seconds between $Now and the
# offset file's last-write time. Never negative (a clock skew or a $Now passed
# before $LastWriteTime clamps to 0, not a misleading negative "age").
function Get-OffsetAgeSeconds {
  param([Parameter(Mandatory)][datetime]$LastWriteTime, [Parameter(Mandatory)][datetime]$Now)
  $age = ($Now - $LastWriteTime).TotalSeconds
  if ($age -lt 0) { return 0 }
  return $age
}

# The bridge watchdog state — three distinct answers, not a bool. A live bridge
# is STALE when its offset is old OR unavailable AND its poll heartbeat is also
# absent/old; OK otherwise (a recent heartbeat still proves a quiet bridge is
# polling, so a long no-traffic offset is NOT an alarm). DOWN is the zero-process
# case (HIMMEL-1520): the prior boolean Test-BridgeStale returned $false for
# ProcessCount==0, so -Watchdog printed OK and exited 0 on a fully-crashed
# bridge — a dead bridge read as healthy. DOWN must be decided BEFORE any
# staleness reasoning, and is reported distinctly. Returns 'DOWN' | 'STALE' | 'OK'.
function Get-BridgeWatchdogState {
  param(
    [Parameter(Mandatory)][int]$ProcessCount,
    $OffsetAgeSeconds,
    $HeartbeatTime,
    [Parameter(Mandatory)][datetime]$Now,
    [Parameter(Mandatory)][int]$ThresholdSeconds
  )
  if ($ProcessCount -lt 1) { return 'DOWN' }
  $heartbeatRecent = $false
  if ($null -ne $HeartbeatTime) {
    $heartbeatAge = Get-OffsetAgeSeconds -LastWriteTime $HeartbeatTime.ToUniversalTime() -Now $Now.ToUniversalTime()
    $heartbeatRecent = $heartbeatAge -le $ThresholdSeconds
  }
  $offsetStaleOrUnknown = ($null -eq $OffsetAgeSeconds) -or ($OffsetAgeSeconds -gt $ThresholdSeconds)
  if ($offsetStaleOrUnknown -and (-not $heartbeatRecent)) { return 'STALE' }
  return 'OK'
}

# The CRITICAL fix: real post-restart liveness proof, pure. bridgeProcs>=1 and
# conflictLines==0 were BOTH true for the entire 2026-08-03 ~16h wedge — process
# existence and an empty 409 grep prove nothing about whether the poll loop is
# actually making progress. Progress is proven by EITHER: the offset file's
# mtime moved forward at/after the UTC restart timestamp (a real getUpdates
# cycle from the NEW poller ingested >=1 new message), OR a poll-heartbeat log
# line (poller.ts, HIMMEL-1510) appeared at/after the restart — the second arm
# exists because a QUIET bridge (no new Telegram traffic during the settle
# window) never touches the offset file at all; that must not read as "stuck".
function Test-BridgeProgressed {
  param(
    $OffsetMTimeBefore,
    $OffsetMTimeAfter,
    $HeartbeatAfter,
    [Parameter(Mandatory)][datetime]$RestartedAt
  )
  $offsetMoved = ($null -ne $OffsetMTimeAfter) -and ($OffsetMTimeAfter -ge $RestartedAt) -and (($null -eq $OffsetMTimeBefore) -or ($OffsetMTimeAfter -gt $OffsetMTimeBefore))
  $heartbeatSeen = ($null -ne $HeartbeatAfter) -and ($HeartbeatAfter -ge $RestartedAt)
  return ($offsetMoved -or $heartbeatSeen)
}

# HIMMEL-1519: is this command line a CORE bridge process (the v2 supervisor /
# poller)? Pure predicate extracted from Get-BridgeProcs so the matcher is
# hermetically testable — the over-reap it fixes WAS a matcher bug. The genuine
# bridge command lines are literally `bun supervisor.ts` / `bun poller.ts` with
# NO path (verified against the live table and this script's own
# `bun supervisor.ts > log 2>&1` launch), so the match keys on the ENTRYPOINT
# NAME as a discrete token — NOT on a `scripts/telegram` path prefix. The lane
# dispatchers spawn-claudex.ts / spawn-glm.ts DO live under scripts/telegram, so
# a path matcher reaps every live lane dispatch as a "bridge process" (a
# read-only -Watchdog once reported a live lane worker that way, and the
# flagless restart path force-kills everything Get-BridgeProcs returns). The
# token anchors (boundary before, whitespace/end after) also reject substrings
# like `mysupervisor.ts` or `supervisor.ts.bak`. Returns [bool].
function Test-BridgeCoreProc {
  param([Parameter(Mandatory)][string]$CommandLine)
  return $CommandLine -match '(?:^|[\\/\s])(?:supervisor|poller)\.ts(?:\s|$)'
}

# HIMMEL-1519/1520: preserve the full bridge process union for conflict
# remediation while exposing the core supervisor/poller set separately for
# liveness decisions. A rogue plugin is a conflict, not evidence that v2 lives.
function Get-BridgeProcSets {
  # AllowEmptyCollection is load-bearing (HIMMEL-1519 CR r2): a fully-crashed
  # bridge yields ZERO bun.exe processes, and a Mandatory [object[]] REFUSES an
  # empty array at parameter binding -- so without this the script would die
  # with a binding error on exactly the dead-bridge case the DOWN state exists
  # to report.
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes)
  $all = @($Processes | Where-Object { $_.CommandLine })
  $core = @($all | Where-Object { Test-BridgeCoreProc -CommandLine $_.CommandLine })
  $plugin = @($all | Where-Object { $_.CommandLine -match 'telegram-himmel' })
  $pluginPids = @($plugin | ForEach-Object { $_.ProcessId })
  $children = @($all | Where-Object { ($pluginPids -contains $_.ParentProcessId) -and ($_.CommandLine -match 'server\.ts') })
  $bridge = @(@($core) + @($plugin) + @($children) | Sort-Object ProcessId -Unique)
  return [pscustomobject]@{ Core = $core; All = $bridge }
}

# Runs the ledger-validated stops through an injectable action so the failure
# path is hermetically testable. Every failure is returned to the caller; none
# may be downgraded to a warning followed by relaunch.
function Invoke-ValidatedBridgeStops {
  param(
    [Parameter(Mandatory)][object[]]$Entries,
    [scriptblock]$StopAction = { param($ProcessId) Stop-Process -Id $ProcessId -Force -ErrorAction Stop }
  )
  $failures = @()
  foreach ($e in $Entries) {
    try {
      & $StopAction ([int]$e.pid)
      Write-Host "[restart-bridge] -FromLedger: stopped $($e.label) pid $($e.pid)"
    } catch {
      $failures += [pscustomobject]@{ label = $e.label; pid = [int]$e.pid; error = [string]$_ }
    }
  }
  return $failures
}

function Test-BridgeRelaunchSafe {
  param([object[]]$StopFailures, [object[]]$Survivors)
  return (@($StopFailures).Count -eq 0 -and @($Survivors).Count -eq 0)
}

# HIMMEL-1519 round 2 finding A: is an absent/unreadable ledger allowed to fall
# through instead of an automatic refusal? Only for the DOWN-remediation entry
# (-Watchdog -Kill when the watchdog itself classified the bridge DOWN) — the
# supervisor's circuit breaker calls clearPidfile() before it exits
# (supervisor.ts), so the single most common fully-crashed state leaves NO
# ledger at all, and that must not be indistinguishable from "nothing to
# validate, refuse". An ordinary `-FromLedger -Kill` invocation (the operator
# asked to kill validated pids) keeps refusing on an absent ledger — this
# predicate only ever returns $false (do not refuse for ledger-absence alone)
# when $IsDownRemediation is $true; the caller still runs the stricter
# zero-owner proof below before actually relaunching.
function Test-FromLedgerAbsentLedgerRefuses {
  param([Parameter(Mandatory)][bool]$LedgerAbsent, [Parameter(Mandatory)][bool]$IsDownRemediation)
  return ($LedgerAbsent -and (-not $IsDownRemediation))
}

# HIMMEL-1519 round 2 finding B: the ledger-less / zero-validated relaunch has
# no ledger to cross-check pids against, so it must clear a STRICTER emptiness
# bar than $BridgeProcs (Get-BridgeProcs) alone. Get-BridgeProcs deliberately
# misses a `bun server.ts` orphaned by a dead telegram-himmel launcher (see the
# trade-off comment above Get-BridgeProcSnapshot) — harmless before this
# relaunch fork could ever fire, now a real 2nd-getUpdates-owner risk. Scans
# $AllBun for any `server.ts` process not already in $BridgeProcs and keeps it
# UNLESS Get-ServerTsAttribution says it's another codex plugin's MCP server
# (the one attribution that is provably never a Telegram getUpdates consumer) —
# 'telegram' and 'unattributable' both count as plausible owners, matched by
# name so a clean machine with only unrelated codex-plugin bun processes still
# proceeds (the anti-fail-closed-forever bar).
function Get-PlausibleGetUpdatesOwners {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BridgeProcs,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllBun
  )
  $byPid = @{}
  foreach ($b in $AllBun) { $byPid[[string]$b.ProcessId] = $b }
  $bridgePids = @($BridgeProcs | ForEach-Object { $_.ProcessId })
  $extraOwners = @($AllBun | Where-Object {
    $_.CommandLine -and ($_.CommandLine -match 'server\.ts') -and
    ($bridgePids -notcontains $_.ProcessId) -and
    ((Get-ServerTsAttribution -Proc $_ -ByPid $byPid) -ne 'codex-plugin')
  })
  return @(@($BridgeProcs) + @($extraOwners) | Sort-Object ProcessId -Unique)
}

# HIMMEL-1519: the -FromLedger -Kill "zero validated pid" fork. Before this
# fix, zero validated ledger pids ALWAYS refused (exit 1) — but that shape is
# also exactly the DOWN state (HIMMEL-1520: zero live bridge processes means
# neither ledger pid can ever validate), so the one state most needing this
# remediation verb could never reach it. This reuses Test-BridgeRelaunchSafe's
# own safety definition (no survivors) rather than a new ad hoc check: a live
# unaccounted-for bridge process means the ledger is merely stale and refusing
# is correct; zero live processes is DOWN — nothing to kill, no possible 2nd
# getUpdates owner, safe to proceed. HIMMEL-1519 round 2 finding B widened the
# survivor set from a bare Get-BridgeProcs probe to Get-PlausibleGetUpdatesOwners
# (adds the orphaned-server.ts scan) — both probes stay injectable purely so
# this fork is hermetically testable without touching the live process table.
function Test-FromLedgerZeroValidatedProceed {
  param(
    [scriptblock]$ProbeAction = { Get-BridgeProcs },
    [scriptblock]$AllBunProbeAction = { @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'") }
  )
  $liveProcs = @(& $ProbeAction)
  $allBun = @(& $AllBunProbeAction)
  $owners = @(Get-PlausibleGetUpdatesOwners -BridgeProcs $liveProcs -AllBun $allBun)
  return Test-BridgeRelaunchSafe -StopFailures @() -Survivors $owners
}

# HIMMEL-1519 round 3: the validated-stop branch's post-stop survivor probe --
# the killed-branch analog of Test-FromLedgerZeroValidatedProceed. After
# Invoke-ValidatedBridgeStops has stopped the ledger-validated pid(s) and the
# settle sleep has elapsed, refuse to relaunch if ANY plausible getUpdates
# owner survives. Get-BridgeProcs deliberately misses a `bun server.ts`
# orphaned by a dead telegram-himmel launcher (the accepted under-reap, see the
# trade-off comment above Get-BridgeProcSnapshot); before round 3 THIS probe
# was a bare Get-BridgeProcs, so such an orphan survived UNSEEN,
# Test-BridgeRelaunchSafe returned safe, and the script relaunched into a 2nd
# getUpdates owner / 409 storm -- the precise outcome the guard exists to
# prevent (same defect class as round 2 finding B, one branch over). The probe
# takes a FRESH bun.exe snapshot (process state changed when the validated pids
# were stopped), and shares the orphan-aware safety definition with its
# zero-validated sibling; both probes stay injectable purely so each fork is
# hermetically testable without touching the live process table.
function Test-ValidatedStopRelaunchSafe {
  param(
    [scriptblock]$ProbeAction = { Get-BridgeProcs },
    [scriptblock]$AllBunProbeAction = { @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'") }
  )
  $liveProcs = @(& $ProbeAction)
  $allBun = @(& $AllBunProbeAction)
  $owners = @(Get-PlausibleGetUpdatesOwners -BridgeProcs $liveProcs -AllBun $allBun)
  return Test-BridgeRelaunchSafe -StopFailures @() -Survivors $owners
}

# HIMMEL-1519: the scheduled-task-preferred / cmd-fallback relaunch dispatch,
# extracted from inline code (mirrors Invoke-ValidatedBridgeStops's
# injectable-action pattern) so it is hermetically testable — no real process
# launches or scheduled task fires in a test. Returns 'scheduled-task' or
# 'cmd-fallback' so the caller logs the same outcome message it always has.
function Invoke-BridgeRelaunch {
  param(
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$BridgeDir,
    [Parameter(Mandatory)][string]$LogPath,
    [scriptblock]$GetTaskAction = { param($Name) Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue },
    [scriptblock]$StartTaskAction = { param($Name) Start-ScheduledTask -TaskName $Name },
    [scriptblock]$StartProcessAction = { param($Dir, $CmdLine) Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $CmdLine -WorkingDirectory $Dir -WindowStyle Hidden -PassThru }
  )
  $task = & $GetTaskAction $TaskName
  if ($task) {
    & $StartTaskAction $TaskName
    return 'scheduled-task'
  }
  $cmdline = 'bun supervisor.ts > "{0}" 2>&1' -f $LogPath
  & $StartProcessAction $BridgeDir $cmdline | Out-Null
  return 'cmd-fallback'
}

if ($AsLibrary) { return }

$ErrorActionPreference = 'Stop'
$bridgeDir     = Join-Path $Repo 'scripts/telegram'
$logDir        = Join-Path $env:USERPROFILE '.claude/channels/telegram'
$log           = Join-Path $logDir 'supervisor.log'
# HIMMEL-1510: ~/.claude/handover/bridge is the bun bridge's own root (bus.ts
# defaultRoot, overridable via $env:BRIDGE_ROOT) — supervisor.pid (the ledger)
# and offset both live there. HIMMEL-1520: an explicitly empty override cannot
# be represented safely with Join-Path, so reject it clearly instead of either
# silently choosing a different root or crashing with an obscure binding error.
if ($null -ne $env:BRIDGE_ROOT -and $env:BRIDGE_ROOT.Length -eq 0) {
  Write-Error '[restart-bridge] BRIDGE_ROOT is set to an empty value. Unset BRIDGE_ROOT to use ~/.claude/handover/bridge, or set it to a non-empty bridge root path.' -ErrorAction Continue
  exit 1
}
$bridgeRootDir = if ($null -ne $env:BRIDGE_ROOT) { $env:BRIDGE_ROOT } else { Join-Path $env:USERPROFILE '.claude/handover/bridge' }
$ledgerPath    = Join-Path $bridgeRootDir 'supervisor.pid'
$offsetPath    = Join-Path $bridgeRootDir 'offset'
$TaskName      = 'HimmelTelegramBridge'

if (-not (Test-Path (Join-Path $bridgeDir 'supervisor.ts'))) {
  Write-Error "supervisor.ts not found under $bridgeDir — pass -Repo <himmel root>."
  exit 1
}

# Find ONLY the bun processes that are running a Telegram bridge. Two families:
#   1. the v2 bun bridge — `bun supervisor.ts` / `bun poller.ts` (HIMMEL-1519:
#      matched by ENTRYPOINT NAME via Test-BridgeCoreProc, NOT by a
#      scripts/telegram path — the genuine command lines carry NO path, and the
#      lane dispatchers spawn-claudex.ts / spawn-glm.ts DO live under
#      scripts/telegram, so the old `scripts[\\/]+telegram` arm reaped every
#      live lane dispatch as a "bridge process");
#   2. the ROGUE `telegram-himmel` PLUGIN bridge (HIMMEL-225) — a stray
#      `bun run …/telegram-himmel … start` launcher and its `bun server.ts`
#      child, left by an abandoned `claude --channels` session. That pair is a
#      2nd getUpdates consumer → 409 storm → the v2 bridge goes deaf, and the
#      original supervisor/poller-only match let it slip through.
# Uses CIM so we can read the full CommandLine — Get-Process can't.
#
# Scoping (never reap unrelated bun work): the core match is the entrypoint-name
# predicate Test-BridgeCoreProc (token-anchored supervisor.ts/poller.ts); the
# plugin launcher is matched by its `telegram-himmel` path; its `bun server.ts`
# child carries NO plugin marker in its own CommandLine, so we match it by
# PARENT-PID LINKAGE to a launcher we already identified — NOT by a bare
# `server.ts` cmdline grep (which would also kill an unrelated `bun server.ts`).
# Trade-off: a server.ts child orphaned by a dead launcher is missed — the SAFE
# direction (under-reap, never over-reap); rerun once the launcher is gone, or
# kill it by PID.
function Get-BridgeProcSnapshot {
  $all = @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'")
  return Get-BridgeProcSets -Processes $all
}

function Get-BridgeProcs {
  $snapshot = Get-BridgeProcSnapshot
  return @($snapshot.All)
}

# HIMMEL-1510: parse the ledger; $null on anything unreadable/malformed —
# callers refuse rather than guess.
function Read-BridgeLedger {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) { return $null }
  try { return (Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
  catch { return $null }
}

# HIMMEL-1510: last poll-heartbeat timestamp in $LogPath (poller.ts prints
# `[poller] heartbeat: …` on every successful getUpdates, ISO-timestamped by
# installTimestampedLogging), or $null if none is present.
function Get-LastHeartbeatTime {
  param([Parameter(Mandatory)][string]$LogPath)
  if (-not (Test-Path $LogPath)) { return $null }
  $matches_ = @(Select-String -Path $LogPath -Pattern '^\[([0-9TZ:\.\-]+)\] \[poller\] heartbeat:' -ErrorAction SilentlyContinue)
  if (-not $matches_.Count) { return $null }
  $m = [regex]::Match($matches_[-1].Line, '^\[([0-9TZ:\.\-]+)\]')
  if (-not $m.Success) { return $null }
  try { return [datetime]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
  catch { return $null }
}

# HIMMEL-1510: rotate (never clobber) supervisor.log. restart-bridge.ps1 used to
# `Set-Content -Path $log -Value ''` on every restart — that destroyed the Jul
# 31–Aug 2 outage evidence, then did it AGAIN on 2026-08-03 wiping the wedge's
# own logs. Now the prior log is moved aside with a timestamp and a fresh one
# started; only the oldest rotated logs beyond -LogKeep are pruned.
function Invoke-LogRotation {
  param([Parameter(Mandatory)][string]$LogPath, [Parameter(Mandatory)][string]$LogDir, [Parameter(Mandatory)][int]$Keep)
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  if (Test-Path $LogPath) {
    $rotated = Get-RotatedLogPath -LogPath $LogPath -Now (Get-Date)
    Move-Item -Path $LogPath -Destination $rotated -Force
    Write-Host "[restart-bridge] rotated prior log to $rotated"
    $base = [System.IO.Path]::GetFileNameWithoutExtension($LogPath)
    $ext = [System.IO.Path]::GetExtension($LogPath)
    $old = @(Get-ChildItem -Path $LogDir -Filter "$base.*$ext" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
    foreach ($o in $old) {
      Remove-Item -Path $o.FullName -Force -ErrorAction SilentlyContinue
      Write-Host "[restart-bridge] pruned old rotated log $($o.Name)"
    }
  }
  New-Item -ItemType File -Path $LogPath -Force | Out-Null

  # HIMMEL-1520 #2: rotate the sibling .err in lockstep with the main log. The
  # post-restart verify counts Conflict|409 lines in BOTH $log and $log.err, so
  # a stale 409 surviving in an unrotated $log.err would hold conflicts>0
  # forever and make every subsequent restart exit 2 — fail-closed-forever, same
  # family as HIMMEL-1501/1465. Rotated (not clobbered) only when it already
  # exists; nothing in the known launch paths writes here (stderr is merged into
  # $log via 2>&1), so a stray empty file is never created.
  $errPath = "$LogPath.err"
  if (Test-Path $errPath) {
    $rotatedErr = Get-RotatedLogPath -LogPath $errPath -Now (Get-Date)
    Move-Item -Path $errPath -Destination $rotatedErr -Force
    Write-Host "[restart-bridge] rotated prior err log to $rotatedErr"
    $errBase = [System.IO.Path]::GetFileNameWithoutExtension($errPath)
    $errExt = [System.IO.Path]::GetExtension($errPath)
    $oldErr = @(Get-ChildItem -Path $LogDir -Filter "$errBase.*$errExt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
    foreach ($o in $oldErr) {
      Remove-Item -Path $o.FullName -Force -ErrorAction SilentlyContinue
      Write-Host "[restart-bridge] pruned old rotated err log $($o.Name)"
    }
    New-Item -ItemType File -Path $errPath -Force | Out-Null
  }
}

$existingSnapshot = Get-BridgeProcSnapshot
$existing = @($existingSnapshot.All)
$coreExisting = @($existingSnapshot.Core)
Write-Host ("[restart-bridge] found {0} bridge bun process(es), {1} core: {2}" -f $existing.Count, $coreExisting.Count, (($existing | ForEach-Object { $_.ProcessId }) -join ', '))
$offsetMTimeBefore = if (Test-Path $offsetPath) { (Get-Item $offsetPath).LastWriteTimeUtc } else { $null }

if ($StatusOnly) {
  $conflicts = if (Test-Path $log) { (Select-String -Path $log -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count } else { 0 }
  Write-Host ("[restart-bridge] status-only: bridgeProcs={0} conflictLines={1} log={2}" -f $existing.Count, $conflicts, $log)
  exit 0
}

# --- HIMMEL-1510: -Watchdog — detect "alive but not progressing" -----------
# bridgeProcs>=1 and conflictLines==0 were BOTH true for the entire 2026-08-03
# ~16h wedge; this is the structural catch. Report-only unless -Kill is also
# passed, in which case a STALE or DOWN finding falls through into the exact
# same validated -FromLedger -Kill remediation below (never a broad kill).
# HIMMEL-1519 round 2: $downRemediation marks the DOWN-remediation entry
# specifically (not STALE) — it is the only caller allowed to fall through an
# absent ledger below (Finding A). Default $false so a direct `-FromLedger`
# invocation (never went through this block) always keeps the ledger required.
$downRemediation = $false
if ($Watchdog) {
  $watchdogNow = (Get-Date).ToUniversalTime()
  $offsetAge = if ($null -ne $offsetMTimeBefore) { Get-OffsetAgeSeconds -LastWriteTime $offsetMTimeBefore -Now $watchdogNow } else { $null }
  $heartbeatTime = Get-LastHeartbeatTime -LogPath $log
  $state = Get-BridgeWatchdogState -ProcessCount $coreExisting.Count -OffsetAgeSeconds $offsetAge -HeartbeatTime $heartbeatTime -Now $watchdogNow -ThresholdSeconds $OffsetAgeThresholdSeconds
  $offsetAgeDisplay = if ($null -ne $offsetAge) { [math]::Round($offsetAge) } else { 'n/a' }
  if ($state -eq 'OK') {
    Write-Host ("[restart-bridge] watchdog: OK — coreBridgeProcs={0} offsetAgeSec={1} threshold={2}" -f $coreExisting.Count, $offsetAgeDisplay, $OffsetAgeThresholdSeconds)
    exit 0
  }
  if ($state -eq 'DOWN') {
    Write-Warning ("[restart-bridge] watchdog: DOWN — coreBridgeProcs=0 (no supervisor/poller alive). offsetAgeSec={0}. A fully-crashed bridge was reported OK here before HIMMEL-1520." -f $offsetAgeDisplay)
  } else {
    Write-Warning ("[restart-bridge] watchdog: WEDGED — coreBridgeProcs={0} but neither offset nor poll heartbeat advanced within {1}s (offsetAgeSec={2}). Poller is alive but not making progress." -f $coreExisting.Count, $OffsetAgeThresholdSeconds, $offsetAgeDisplay)
  }
  if (-not $Kill) {
    Write-Warning "[restart-bridge] watchdog: re-run with -Watchdog -Kill to remediate (validated kill + scheduled-task relaunch)."
    exit 2
  }
  Write-Host "[restart-bridge] watchdog: -Kill given — remediating via the -FromLedger path."
  $FromLedger = $true
  $downRemediation = ($state -eq 'DOWN')
}

# --- HIMMEL-1510: -FromLedger [-Kill] — the sanctioned, agent-invocable verb -
if ($FromLedger) {
  # Snapshot the timestamp BEFORE the content. If the supervisor rewrites the
  # ledger between these reads, the older timestamp can only cause a safe
  # refusal; reading content first could pair a stale pid with a newer mtime.
  $ledgerItem = Get-Item -Path $ledgerPath -ErrorAction SilentlyContinue
  $ledger = Read-BridgeLedger -Path $ledgerPath
  $ledgerAbsent = ($null -eq $ledger -or $null -eq $ledgerItem)

  # HIMMEL-1519 round 2 finding A: an absent/unreadable ledger refuses UNLESS
  # this is the DOWN-remediation entry — the supervisor's circuit breaker
  # deletes the ledger before it exits, so the most common fully-crashed state
  # has none, and this verb's entire reason for existing must still be able to
  # self-heal it. An ordinary `-FromLedger -Kill` invocation still refuses here
  # (Test-FromLedgerAbsentLedgerRefuses only ever says "don't refuse" when
  # $downRemediation is true).
  if (Test-FromLedgerAbsentLedgerRefuses -LedgerAbsent $ledgerAbsent -IsDownRemediation $downRemediation) {
    Write-Warning "[restart-bridge] -FromLedger: ledger unreadable/absent at $ledgerPath — refusing (nothing to validate)."
    exit 1
  }

  $toKill = @()
  if ($ledgerAbsent) {
    Write-Warning "[restart-bridge] -FromLedger: ledger unreadable/absent at $ledgerPath during DOWN remediation — nothing to validate; falling through to the zero-owner safety check."
  } else {
    $ledgerLastWriteTime = $ledgerItem.LastWriteTimeUtc
    $allBun = @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'" | Where-Object { $_.CommandLine })
    $byPid = @{}
    foreach ($b in $allBun) { $byPid[[string]$b.ProcessId] = $b }

    $entries = @(
      [pscustomobject]@{ label = 'supervisor'; pid = $ledger.supervisor }
      [pscustomobject]@{ label = 'poller';     pid = $ledger.poller }
    )
    foreach ($e in $entries) {
      if (Test-LedgerPidValid -Pid_ $e.pid -Role $e.label -LedgerLastWriteTime $ledgerLastWriteTime -ByPid $byPid) {
        Write-Host ("[restart-bridge] -FromLedger: {0} pid {1} VALIDATED (bun.exe, expected role, predates ledger) — {2}" -f $e.label, $e.pid, $(if ($Kill) { 'killing' } else { 'would kill' }))
        $toKill += $e
      } else {
        Write-Warning ("[restart-bridge] -FromLedger: {0} pid {1} REFUSED (missing/zero/malformed/not-alive/name/role/creation-time mismatch) — will NOT be touched" -f $e.label, $e.pid)
      }
    }
  }

  if (-not $Kill) {
    Write-Host "[restart-bridge] -FromLedger dry run (default) — nothing touched. Re-run with -Kill to stop the validated pid(s) above and relaunch."
    exit 0
  }
  if ($toKill.Count -eq 0) {
    # HIMMEL-1519: no validated pid (or no ledger at all, finding A) is ALSO
    # the DOWN state's exact shape — do not conflate it with a stale ledger
    # sitting beside a live unaccounted process. HIMMEL-1519 round 2 finding B:
    # this ledger-less fork has no ledger to cross-check pids against, so
    # Test-FromLedgerZeroValidatedProceed scans for an orphaned server.ts via
    # Get-PlausibleGetUpdatesOwners. Round 3 applied the SAME orphan-aware scan
    # to the validated-stop survivor check below, so the two forks now share
    # the safety definition; the remaining difference is probe TIMING.
    # Non-blocking cleanup: nothing can have changed
    # process state between here and the post-relaunch decision below (no
    # Stop-Process ran in this branch), so this probe is NOT repeated —
    # collapsing it would be unsafe only for the killed branch, which still
    # re-probes after its Start-Sleep below.
    if (-not (Test-FromLedgerZeroValidatedProceed)) {
      $owners = @(Get-PlausibleGetUpdatesOwners -BridgeProcs (Get-BridgeProcs) -AllBun @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'"))
      Write-Warning ("[restart-bridge] -FromLedger -Kill: no validated pid(s) — refusing to relaunch blind: {0} plausible getUpdates owner(s) still present (PID(s): {1}). The ledger may be stale/absent, or a bridge/orphan process survives; investigate before rerunning." -f $owners.Count, (($owners | ForEach-Object { $_.ProcessId }) -join ', '))
      exit 1
    }
    Write-Host "[restart-bridge] -FromLedger -Kill: no validated pid(s) and zero plausible getUpdates owner(s) alive (DOWN) — nothing to kill, no possible 2nd owner; proceeding to relaunch."
  } else {
    $stopFailures = @(Invoke-ValidatedBridgeStops -Entries $toKill)
    if (-not (Test-BridgeRelaunchSafe -StopFailures $stopFailures -Survivors @())) {
      Write-Warning ("[restart-bridge] -FromLedger -Kill: refusing to relaunch — Stop-Process failed for validated PID(s): {0}. Relaunching now could add a 2nd getUpdates owner and cause a 409 storm. Stop each PID manually (Stop-Process -Id <pid> -Force), verify it is gone, then rerun. Error(s): {1}" -f (($stopFailures | ForEach-Object { $_.pid }) -join ', '), (($stopFailures | ForEach-Object { $_.error }) -join '; '))
      exit 1
    }
    Start-Sleep -Seconds 2

    # HIMMEL-1520 #3: refuse to relaunch while ANY plausible getUpdates owner
    # survives the validated stop. That includes a ledger-validated pid whose
    # Stop-Process returned but which has not actually exited yet, a bridge
    # process absent from a stale ledger, AND an orphaned `bun server.ts`
    # whose launcher already died (which Get-BridgeProcs deliberately misses —
    # the accepted under-reap). HIMMEL-1519 round 3: that orphan is the exact
    # class round 2 finding B closed in the zero-validated fork one branch
    # above, and it is just as able to win getUpdates ownership here, so this
    # post-stop survivor probe goes through Get-PlausibleGetUpdatesOwners over a
    # FRESH bun.exe snapshot (taken after the stops and this settle sleep) —
    # exactly as that fork does — not the bare Get-BridgeProcs probe it used
    # before. This FRESH probe is the one the non-blocking cleanup above
    # intentionally does NOT collapse with the zero-validated fork's probe,
    # because state changed since (Stop-Process ran here); the orphan-aware
    # safety definition is shared with that fork, the probe INSTANCE is not.
    if (-not (Test-ValidatedStopRelaunchSafe)) {
      $survivors = @(Get-PlausibleGetUpdatesOwners -BridgeProcs (Get-BridgeProcs) -AllBun @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'"))
      Write-Warning ("[restart-bridge] -FromLedger -Kill: refusing to relaunch — {0} plausible getUpdates owner(s) survived the validated stop (PID(s): {1}): a validated PID that did not exit, a bridge process absent from the ledger, or an orphaned 'bun server.ts' Get-BridgeProcs does not match. Relaunching now would add a 2nd getUpdates owner and cause a 409 storm. Stop the survivor(s) by PID (Stop-Process -Id <pid> -Force), verify they are gone, then rerun." -f $survivors.Count, (($survivors | ForEach-Object { $_.ProcessId }) -join ', '))
      exit 1
    }
  }

  Invoke-LogRotation -LogPath $log -LogDir $logDir -Keep $LogKeep
  $env:HIMMEL_REPO = $Repo
  $restartedAt = (Get-Date).ToUniversalTime()

  # Prefer the scheduled task (HimmelTelegramBridge, install-logon-task.ps1) —
  # the operator's own remediation path: right token env, right RunLevel,
  # detached from THIS process's lifetime. Fall back to the same cmd /c launch
  # the default path below uses only when the task isn't registered.
  $relaunchKind = Invoke-BridgeRelaunch -TaskName $TaskName -BridgeDir $bridgeDir -LogPath $log
  if ($relaunchKind -eq 'scheduled-task') {
    Write-Host "[restart-bridge] -FromLedger -Kill: relaunched via scheduled task $TaskName"
  } else {
    Write-Warning "[restart-bridge] -FromLedger -Kill: $TaskName scheduled task not registered — falling back to a detached launch (see scripts/telegram/install-logon-task.ps1 to register it)."
  }
  Write-Host "[restart-bridge] -FromLedger -Kill: settling ${SettleSeconds}s…"
  Start-Sleep -Seconds $SettleSeconds

  $nowSnapshot = Get-BridgeProcSnapshot
  $now = @($nowSnapshot.All)
  $nowCore = @($nowSnapshot.Core)
  $conflicts = 0
  # HIMMEL-1519 round 2 (non-blocking #1): check $log.err too, matching the
  # default (non-ledger) verifier below — a stray 409 written to the sibling
  # .err file must not be invisible here just because this path only checked
  # the main log.
  if (Test-Path $log)       { $conflicts += (Select-String -Path $log       -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
  if (Test-Path "$log.err") { $conflicts += (Select-String -Path "$log.err" -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
  $offsetMTimeAfter = if (Test-Path $offsetPath) { (Get-Item $offsetPath).LastWriteTimeUtc } else { $null }
  $heartbeatAfter = Get-LastHeartbeatTime -LogPath $log
  $progressed = Test-BridgeProgressed -OffsetMTimeBefore $offsetMTimeBefore -OffsetMTimeAfter $offsetMTimeAfter -HeartbeatAfter $heartbeatAfter -RestartedAt $restartedAt

  Write-Host ("[restart-bridge] -FromLedger -Kill: after restart: coreBridgeProcs={0} allBridgeProcs={1} conflictLines={2} progressed={3}" -f $nowCore.Count, $now.Count, $conflicts, $progressed)
  if ($nowCore.Count -ge 1 -and $conflicts -eq 0 -and $progressed) {
    Write-Host "[restart-bridge] -FromLedger -Kill: OK — bridge up, single owner, no 409, real progress proven."
    exit 0
  } else {
    Write-Warning "[restart-bridge] -FromLedger -Kill: did NOT settle cleanly (coreProcs=$($nowCore.Count) allBridgeProcs=$($now.Count) conflicts=$conflicts progressed=$progressed). Inspect $log."
    exit 2
  }
}

# Kill ONLY those PIDs (scoped — not /IM bun.exe).
foreach ($p in $existing) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host "[restart-bridge] stopped bridge pid $($p.ProcessId)" }
  catch { Write-Warning "[restart-bridge] could not stop pid $($p.ProcessId): $_" }
}
if ($existing.Count) { Start-Sleep -Seconds 2 }

# Rotate (never clobber — HIMMEL-1510), start exactly one supervisor — FULLY
# detached so it survives this script exiting. IMPORTANT: we do NOT use
# Start-Process -RedirectStandardOutput here. That makes the PARENT (pwsh) own
# the child's stdout pipe; when pwsh exits, the pipe breaks and bun dies
# (observed: bridgeProcs=0 within seconds). Instead we launch
# `cmd /c "bun supervisor.ts > log 2>&1"` so CMD owns the file redirection and
# the bun grandchild keeps its own handles after pwsh is gone.
Invoke-LogRotation -LogPath $log -LogDir $logDir -Keep $LogKeep
$env:HIMMEL_REPO = $Repo
$restartedAt = (Get-Date).ToUniversalTime()
$cmdline = 'bun supervisor.ts > "{0}" 2>&1' -f $log
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdline `
          -WorkingDirectory $bridgeDir -WindowStyle Hidden -PassThru
Write-Host "[restart-bridge] launched supervisor (cmd pid $($proc.Id)); settling ${SettleSeconds}s…"
Start-Sleep -Seconds $SettleSeconds

# Verify: bridge procs present + no 409 in the fresh log + REAL PROGRESS proven
# (HIMMEL-1510 — bridgeProcs>=1 and conflictLines==0 were BOTH true for the
# entire 2026-08-03 ~16h wedge; process existence and an empty grep prove
# nothing about whether the poll loop is actually making progress).
$nowSnapshot = Get-BridgeProcSnapshot
$now = @($nowSnapshot.All)
$nowCore = @($nowSnapshot.Core)
$conflicts = 0
if (Test-Path $log)        { $conflicts += (Select-String -Path $log        -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
if (Test-Path "$log.err")  { $conflicts += (Select-String -Path "$log.err"  -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
$offsetMTimeAfter = if (Test-Path $offsetPath) { (Get-Item $offsetPath).LastWriteTimeUtc } else { $null }
$heartbeatAfter = Get-LastHeartbeatTime -LogPath $log
$progressed = Test-BridgeProgressed -OffsetMTimeBefore $offsetMTimeBefore -OffsetMTimeAfter $offsetMTimeAfter -HeartbeatAfter $heartbeatAfter -RestartedAt $restartedAt

Write-Host ("[restart-bridge] after start: coreBridgeProcs={0} allBridgeProcs={1} conflictLines={2} progressed={3}" -f $nowCore.Count, $now.Count, $conflicts, $progressed)

# Orphan warning (HIMMEL-228, re-scoped HIMMEL-1309): Get-BridgeProcs reaps the
# rogue `bun server.ts` child only by PARENT-PID linkage to a live
# telegram-himmel launcher (the safe under-reap). If the launcher already died,
# its orphaned server.ts child is a live 2nd getUpdates consumer that we did NOT
# reap — yet the verify below could still print "OK". Surface such orphans by
# PID — but ATTRIBUTE them first: most `bun server.ts` on this box are other
# codex plugins' MCP servers and have nothing to do with telegram.
$allBun = @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'")
$bunByPid = @{}
foreach ($b in $allBun) { $bunByPid[[string]$b.ProcessId] = $b }
$reapedPids = @($now | ForEach-Object { $_.ProcessId })
$orphans = @($allBun | Where-Object { $_.CommandLine -and $_.CommandLine -match 'server\.ts' -and ($reapedPids -notcontains $_.ProcessId) })
$byKind = @{ telegram = @(); 'codex-plugin' = @(); unattributable = @() }
foreach ($o in $orphans) { $byKind[(Get-ServerTsAttribution -Proc $o -ByPid $bunByPid)] += $o }

if ($byKind['telegram'].Count) {
  Write-Warning ("[restart-bridge] {0} orphaned telegram-himmel 'bun server.ts' process(es) survive OUTSIDE the bridge set (PID(s): {1}) — a rogue child whose launcher already died. It is a live 2nd getUpdates consumer; kill it by PID (Stop-Process -Id <pid> -Force) then rerun." -f $byKind['telegram'].Count, (($byKind['telegram'] | ForEach-Object { $_.ProcessId }) -join ', '))
}
if ($byKind['codex-plugin'].Count) {
  Write-Host ("[restart-bridge] note: {0} 'bun server.ts' process(es) belong to OTHER codex plugin MCP servers (PID(s): {1}) — not telegram, not a getUpdates consumer, nothing to do here. Duplicates of those are scripts/codex/reap-superseded-fleets.ps1's job." -f $byKind['codex-plugin'].Count, (($byKind['codex-plugin'] | ForEach-Object { $_.ProcessId }) -join ', '))
}
if ($byKind['unattributable'].Count) {
  Write-Warning ("[restart-bridge] {0} 'bun server.ts' process(es) could not be attributed (PID(s): {1}) — their launcher is gone or its command line is unreadable, so this may be a telegram rogue OR another codex plugin's MCP server. Check the PID before killing it." -f $byKind['unattributable'].Count, (($byKind['unattributable'] | ForEach-Object { $_.ProcessId }) -join ', '))
}

if ($nowCore.Count -ge 1 -and $conflicts -eq 0 -and $progressed) {
  Write-Host "[restart-bridge] OK — bridge up, single owner, no 409, real progress proven."
  exit 0
} else {
  Write-Warning "[restart-bridge] bridge did NOT settle cleanly (coreProcs=$($nowCore.Count) allBridgeProcs=$($now.Count) conflicts=$conflicts progressed=$progressed). Inspect $log."
  exit 2
}
