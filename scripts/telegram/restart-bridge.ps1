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
# Exit codes: 0 = bridge up + clean; 1 = usage/env error; 2 = started but still
# seeing 409 after the settle window (needs investigation).

[CmdletBinding()]
param(
  [string]$Repo = $(if ($env:HIMMEL_REPO) { $env:HIMMEL_REPO } else { (Resolve-Path "$PSScriptRoot/../..").Path }),
  [int]$SettleSeconds = 12,
  [switch]$StatusOnly,
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

if ($AsLibrary) { return }

$ErrorActionPreference = 'Stop'
$bridgeDir = Join-Path $Repo 'scripts/telegram'
$logDir    = Join-Path $env:USERPROFILE '.claude/channels/telegram'
$log       = Join-Path $logDir 'supervisor.log'

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

$existing = @(Get-BridgeProcs)
Write-Host ("[restart-bridge] found {0} bridge bun process(es): {1}" -f $existing.Count, (($existing | ForEach-Object { $_.ProcessId }) -join ', '))

if ($StatusOnly) {
  $conflicts = if (Test-Path $log) { (Select-String -Path $log -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count } else { 0 }
  Write-Host ("[restart-bridge] status-only: bridgeProcs={0} conflictLines={1} log={2}" -f $existing.Count, $conflicts, $log)
  exit 0
}

# Kill ONLY those PIDs (scoped — not /IM bun.exe).
foreach ($p in $existing) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host "[restart-bridge] stopped bridge pid $($p.ProcessId)" }
  catch { Write-Warning "[restart-bridge] could not stop pid $($p.ProcessId): $_" }
}
if ($existing.Count) { Start-Sleep -Seconds 2 }

# Fresh log, start exactly one supervisor — FULLY detached so it survives this
# script exiting. IMPORTANT: we do NOT use Start-Process -RedirectStandardOutput
# here. That makes the PARENT (pwsh) own the child's stdout pipe; when pwsh exits,
# the pipe breaks and bun dies (observed: bridgeProcs=0 within seconds). Instead
# we launch `cmd /c "bun supervisor.ts > log 2>&1"` so CMD owns the file
# redirection and the bun grandchild keeps its own handles after pwsh is gone.
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Set-Content -Path $log -Value '' -Encoding utf8
$env:HIMMEL_REPO = $Repo
$cmdline = 'bun supervisor.ts > "{0}" 2>&1' -f $log
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdline `
          -WorkingDirectory $bridgeDir -WindowStyle Hidden -PassThru
Write-Host "[restart-bridge] launched supervisor (cmd pid $($proc.Id)); settling ${SettleSeconds}s…"
Start-Sleep -Seconds $SettleSeconds

# Verify: bridge procs present + no 409 in the fresh log.
$now = @(Get-BridgeProcs)
$conflicts = 0
if (Test-Path $log)        { $conflicts += (Select-String -Path $log        -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }
if (Test-Path "$log.err")  { $conflicts += (Select-String -Path "$log.err"  -Pattern 'Conflict|409' -ErrorAction SilentlyContinue).Count }

Write-Host ("[restart-bridge] after start: bridgeProcs={0} conflictLines={1}" -f $now.Count, $conflicts)

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

if ($now.Count -ge 1 -and $conflicts -eq 0) {
  Write-Host "[restart-bridge] OK — bridge up, single owner, no 409."
  exit 0
} else {
  Write-Warning "[restart-bridge] bridge did NOT settle cleanly (procs=$($now.Count) conflicts=$conflicts). Inspect $log."
  exit 2
}
