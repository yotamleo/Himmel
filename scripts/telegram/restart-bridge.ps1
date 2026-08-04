# restart-bridge.ps1 — safely (re)start the Telegram bridge on Windows.
#
# Why this exists: the bridge enforces a SINGLE getUpdates owner per bot token.
# Duplicate pollers (left over from prior sessions or a failed launch) cause
# repeated "409 Conflict: terminated by other getUpdates request" and the bridge
# never settles. The naive fix `taskkill /F /IM bun.exe` blanket-kills EVERY bun
# process on the machine (unrelated work too) — which the auto-mode classifier
# correctly refuses. This script instead kills ONLY the bun processes whose
# command line runs the bridge (supervisor.ts / poller.ts under scripts/telegram),
# then starts exactly one supervisor, then verifies it settled (no 409).
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

# A live bridge is stale when its offset is old OR unavailable, AND its poll
# heartbeat is also absent/old. Missing offset data is WEDGED rather than a
# separate blind state: with live processes but no recent positive liveness
# signal, the watchdog has the same safe remediation available and must not
# report OK. A recent heartbeat still proves a quiet bridge is polling.
function Test-BridgeStale {
  param(
    [Parameter(Mandatory)][int]$ProcessCount,
    $OffsetAgeSeconds,
    $HeartbeatTime,
    [Parameter(Mandatory)][datetime]$Now,
    [Parameter(Mandatory)][int]$ThresholdSeconds
  )
  $heartbeatRecent = $false
  if ($null -ne $HeartbeatTime) {
    $heartbeatAge = Get-OffsetAgeSeconds -LastWriteTime $HeartbeatTime.ToUniversalTime() -Now $Now.ToUniversalTime()
    $heartbeatRecent = $heartbeatAge -le $ThresholdSeconds
  }
  $offsetStaleOrUnknown = ($null -eq $OffsetAgeSeconds) -or ($OffsetAgeSeconds -gt $ThresholdSeconds)
  return ($ProcessCount -ge 1) -and $offsetStaleOrUnknown -and (-not $heartbeatRecent)
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

if ($AsLibrary) { return }

$ErrorActionPreference = 'Stop'
$bridgeDir     = Join-Path $Repo 'scripts/telegram'
$logDir        = Join-Path $env:USERPROFILE '.claude/channels/telegram'
$log           = Join-Path $logDir 'supervisor.log'
# HIMMEL-1510: ~/.claude/handover/bridge is the bun bridge's own root (bus.ts
# defaultRoot, overridable via $env:BRIDGE_ROOT) — supervisor.pid (the ledger)
# and offset both live there.
$bridgeRootDir = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT } else { Join-Path $env:USERPROFILE '.claude/handover/bridge' }
$ledgerPath    = Join-Path $bridgeRootDir 'supervisor.pid'
$offsetPath    = Join-Path $bridgeRootDir 'offset'
$TaskName      = 'HimmelTelegramBridge'

if (-not (Test-Path (Join-Path $bridgeDir 'supervisor.ts'))) {
  Write-Error "supervisor.ts not found under $bridgeDir — pass -Repo <himmel root>."
  exit 1
}

# Find ONLY the bun processes that are running a Telegram bridge. Two families:
#   1. the v2 bun bridge — supervisor.ts / poller.ts under scripts/telegram;
#   2. the ROGUE `telegram-himmel` PLUGIN bridge (HIMMEL-225) — a stray
#      `bun run …/telegram-himmel … start` launcher and its `bun server.ts`
#      child, left by an abandoned `claude --channels` session. That pair is a
#      2nd getUpdates consumer → 409 storm → the v2 bridge goes deaf, and the
#      original supervisor/poller-only match let it slip through.
# Uses CIM so we can read the full CommandLine — Get-Process can't.
#
# Scoping (deliberately tight — never reap unrelated bun work): the launcher is
# matched by its `telegram-himmel` path; its `bun server.ts` child carries NO
# plugin marker in its own CommandLine, so we match it by PARENT-PID LINKAGE to
# a launcher we already identified — NOT by a bare `server.ts` cmdline grep
# (which would also kill an unrelated `bun server.ts`). Trade-off: a server.ts
# child orphaned by a dead launcher is missed — the SAFE direction (under-reap,
# never over-reap); rerun once the launcher is gone, or kill it by PID.
function Get-BridgeProcs {
  $all = @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'" | Where-Object { $_.CommandLine })
  $core   = @($all | Where-Object { $_.CommandLine -match 'scripts[\\/]+telegram' -or $_.CommandLine -match '(supervisor|poller)\.ts' })
  $plugin = @($all | Where-Object { $_.CommandLine -match 'telegram-himmel' })
  $pluginPids = @($plugin | ForEach-Object { $_.ProcessId })
  $children = @($all | Where-Object { ($pluginPids -contains $_.ParentProcessId) -and ($_.CommandLine -match 'server\.ts') })
  @($core) + @($plugin) + @($children) | Sort-Object ProcessId -Unique
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
}

$existing = @(Get-BridgeProcs)
Write-Host ("[restart-bridge] found {0} bridge bun process(es): {1}" -f $existing.Count, (($existing | ForEach-Object { $_.ProcessId }) -join ', '))
$offsetMTimeBefore = if (Test-Path $offsetPath) { (Get-Item $offsetPath).LastWriteTimeUtc } else { $null }

if ($StatusOnly) {
  $conflicts = if (Test-Path $log) { (Select-String -Path $log -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count } else { 0 }
  Write-Host ("[restart-bridge] status-only: bridgeProcs={0} conflictLines={1} log={2}" -f $existing.Count, $conflicts, $log)
  exit 0
}

# --- HIMMEL-1510: -Watchdog — detect "alive but not progressing" -----------
# bridgeProcs>=1 and conflictLines==0 were BOTH true for the entire 2026-08-03
# ~16h wedge; this is the structural catch. Report-only unless -Kill is also
# passed, in which case a STALE finding falls through into the exact same
# validated -FromLedger -Kill remediation below (never a broad kill).
if ($Watchdog) {
  $watchdogNow = (Get-Date).ToUniversalTime()
  $offsetAge = if ($null -ne $offsetMTimeBefore) { Get-OffsetAgeSeconds -LastWriteTime $offsetMTimeBefore -Now $watchdogNow } else { $null }
  $heartbeatTime = Get-LastHeartbeatTime -LogPath $log
  $stale = Test-BridgeStale -ProcessCount $existing.Count -OffsetAgeSeconds $offsetAge -HeartbeatTime $heartbeatTime -Now $watchdogNow -ThresholdSeconds $OffsetAgeThresholdSeconds
  $offsetAgeDisplay = if ($null -ne $offsetAge) { [math]::Round($offsetAge) } else { 'n/a' }
  if (-not $stale) {
    Write-Host ("[restart-bridge] watchdog: OK — bridgeProcs={0} offsetAgeSec={1} threshold={2}" -f $existing.Count, $offsetAgeDisplay, $OffsetAgeThresholdSeconds)
    exit 0
  }
  Write-Warning ("[restart-bridge] watchdog: WEDGED — bridgeProcs={0} but neither offset nor poll heartbeat advanced within {1}s (offsetAgeSec={2}). Poller is alive but not making progress." -f $existing.Count, $OffsetAgeThresholdSeconds, $offsetAgeDisplay)
  if (-not $Kill) {
    Write-Warning "[restart-bridge] watchdog: re-run with -Watchdog -Kill to remediate (validated kill + scheduled-task relaunch)."
    exit 2
  }
  Write-Host "[restart-bridge] watchdog: -Kill given — remediating via the -FromLedger path."
  $FromLedger = $true
}

# --- HIMMEL-1510: -FromLedger [-Kill] — the sanctioned, agent-invocable verb -
if ($FromLedger) {
  # Snapshot the timestamp BEFORE the content. If the supervisor rewrites the
  # ledger between these reads, the older timestamp can only cause a safe
  # refusal; reading content first could pair a stale pid with a newer mtime.
  $ledgerItem = Get-Item -Path $ledgerPath -ErrorAction SilentlyContinue
  $ledger = Read-BridgeLedger -Path $ledgerPath
  if ($null -eq $ledger -or $null -eq $ledgerItem) {
    Write-Warning "[restart-bridge] -FromLedger: ledger unreadable/absent at $ledgerPath — refusing (nothing to validate)."
    exit 1
  }
  $ledgerLastWriteTime = $ledgerItem.LastWriteTimeUtc
  $allBun = @(Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'" | Where-Object { $_.CommandLine })
  $byPid = @{}
  foreach ($b in $allBun) { $byPid[[string]$b.ProcessId] = $b }

  $entries = @(
    [pscustomobject]@{ label = 'supervisor'; pid = $ledger.supervisor }
    [pscustomobject]@{ label = 'poller';     pid = $ledger.poller }
  )
  $toKill = @()
  foreach ($e in $entries) {
    if (Test-LedgerPidValid -Pid_ $e.pid -Role $e.label -LedgerLastWriteTime $ledgerLastWriteTime -ByPid $byPid) {
      Write-Host ("[restart-bridge] -FromLedger: {0} pid {1} VALIDATED (bun.exe, expected role, predates ledger) — {2}" -f $e.label, $e.pid, $(if ($Kill) { 'killing' } else { 'would kill' }))
      $toKill += $e
    } else {
      Write-Warning ("[restart-bridge] -FromLedger: {0} pid {1} REFUSED (missing/zero/malformed/not-alive/name/role/creation-time mismatch) — will NOT be touched" -f $e.label, $e.pid)
    }
  }

  if (-not $Kill) {
    Write-Host "[restart-bridge] -FromLedger dry run (default) — nothing touched. Re-run with -Kill to stop the validated pid(s) above and relaunch."
    exit 0
  }
  if ($toKill.Count -eq 0) {
    Write-Warning "[restart-bridge] -FromLedger -Kill: no validated pid(s) — refusing to relaunch blind (the ledger may be stale; investigate before rerunning)."
    exit 1
  }

  foreach ($e in $toKill) {
    try { Stop-Process -Id $e.pid -Force -ErrorAction Stop; Write-Host "[restart-bridge] -FromLedger: stopped $($e.label) pid $($e.pid)" }
    catch { Write-Warning "[restart-bridge] -FromLedger: could not stop $($e.label) pid $($e.pid): $_" }
  }
  Start-Sleep -Seconds 2

  Invoke-LogRotation -LogPath $log -LogDir $logDir -Keep $LogKeep
  $env:HIMMEL_REPO = $Repo
  $restartedAt = (Get-Date).ToUniversalTime()

  # Prefer the scheduled task (HimmelTelegramBridge, install-logon-task.ps1) —
  # the operator's own remediation path: right token env, right RunLevel,
  # detached from THIS process's lifetime. Fall back to the same cmd /c launch
  # the default path below uses only when the task isn't registered.
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($task) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "[restart-bridge] -FromLedger -Kill: relaunched via scheduled task $TaskName"
  } else {
    Write-Warning "[restart-bridge] -FromLedger -Kill: $TaskName scheduled task not registered — falling back to a detached launch (see scripts/telegram/install-logon-task.ps1 to register it)."
    $cmdline = 'bun supervisor.ts > "{0}" 2>&1' -f $log
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdline `
      -WorkingDirectory $bridgeDir -WindowStyle Hidden -PassThru | Out-Null
  }
  Write-Host "[restart-bridge] -FromLedger -Kill: settling ${SettleSeconds}s…"
  Start-Sleep -Seconds $SettleSeconds

  $now = @(Get-BridgeProcs)
  $conflicts = 0
  if (Test-Path $log) { $conflicts += (Select-String -Path $log -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
  $offsetMTimeAfter = if (Test-Path $offsetPath) { (Get-Item $offsetPath).LastWriteTimeUtc } else { $null }
  $heartbeatAfter = Get-LastHeartbeatTime -LogPath $log
  $progressed = Test-BridgeProgressed -OffsetMTimeBefore $offsetMTimeBefore -OffsetMTimeAfter $offsetMTimeAfter -HeartbeatAfter $heartbeatAfter -RestartedAt $restartedAt

  Write-Host ("[restart-bridge] -FromLedger -Kill: after restart: bridgeProcs={0} conflictLines={1} progressed={2}" -f $now.Count, $conflicts, $progressed)
  if ($now.Count -ge 1 -and $conflicts -eq 0 -and $progressed) {
    Write-Host "[restart-bridge] -FromLedger -Kill: OK — bridge up, single owner, no 409, real progress proven."
    exit 0
  } else {
    Write-Warning "[restart-bridge] -FromLedger -Kill: did NOT settle cleanly (procs=$($now.Count) conflicts=$conflicts progressed=$progressed). Inspect $log."
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
$now = @(Get-BridgeProcs)
$conflicts = 0
if (Test-Path $log)        { $conflicts += (Select-String -Path $log        -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
if (Test-Path "$log.err")  { $conflicts += (Select-String -Path "$log.err"  -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
$offsetMTimeAfter = if (Test-Path $offsetPath) { (Get-Item $offsetPath).LastWriteTimeUtc } else { $null }
$heartbeatAfter = Get-LastHeartbeatTime -LogPath $log
$progressed = Test-BridgeProgressed -OffsetMTimeBefore $offsetMTimeBefore -OffsetMTimeAfter $offsetMTimeAfter -HeartbeatAfter $heartbeatAfter -RestartedAt $restartedAt

Write-Host ("[restart-bridge] after start: bridgeProcs={0} conflictLines={1} progressed={2}" -f $now.Count, $conflicts, $progressed)

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

if ($now.Count -ge 1 -and $conflicts -eq 0 -and $progressed) {
  Write-Host "[restart-bridge] OK — bridge up, single owner, no 409, real progress proven."
  exit 0
} else {
  Write-Warning "[restart-bridge] bridge did NOT settle cleanly (procs=$($now.Count) conflicts=$conflicts progressed=$progressed). Inspect $log."
  exit 2
}
