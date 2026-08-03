# codex-render-client-lease.ps1 (HIMMEL-1474) - publish a short-lived client
# lease while a pr-check codex adversarial render is alive. The sweep validates
# every field independently; this writer is best-effort and fail-open.
# HIMMEL-1509: when -LeaseDir names a render-lease registry entry (see
# scripts/lib/render-lease.sh), each heartbeat iteration also refreshes that
# lease's `heartbeat` file and records the cxc tokens observed for the render's
# cwd in its `tokens` file - the sweep's strongest liveness signal, independent
# of command-line visibility. Still best-effort: registry writes never affect
# the cxc client-lease loop.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][int]$ClientPid,
  [int]$HeartbeatSeconds = 60,
  [string]$LeaseDir
)

$ErrorActionPreference = 'Stop'
if ($HeartbeatSeconds -le 0) { exit 0 }
$isWindowsHost = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { [bool]$IsWindows } else { $env:OS -eq 'Windows_NT' }
if (-not $isWindowsHost) { exit 0 }

function Get-BrokerToken {
  param([string]$CommandLine)
  if ($CommandLine -match 'cxc-(\S+?)-codex-app-server') { return $Matches[1] }
  return $null
}

function Get-BrokerCwd {
  param([string]$CommandLine)
  if ($CommandLine -match '(?:^|\s)--cwd[ =](?:"([^"]+)"|(\S+))') {
    if ($Matches[1]) { return $Matches[1] }
    return $Matches[2]
  }
  return $null
}

function Get-NormalizedPath {
  param([string]$Path)
  if (-not $Path) { return $null }
  try { return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/')) } catch { return $null }
}

# `$PID` is a read-only automatic variable: the identity helper must never bind
# that name or the heartbeat dies before its first write (HIMMEL-1474 r2).
function Test-ClientIdentity {
  param([int]$ClientProcessId, [datetime]$ExpectedStartUtc)
  try {
    $proc = Get-Process -Id $ClientProcessId -ErrorAction Stop
    return ([math]::Abs(($proc.StartTime.ToUniversalTime() - $ExpectedStartUtc).TotalSeconds) -le 2)
  } catch { return $false }
}

try {
  $client = Get-Process -Id $ClientPid -ErrorAction Stop
  $clientStartUtc = $client.StartTime.ToUniversalTime()
  $clientStartText = $clientStartUtc.ToString('o')
  $cwd = Get-NormalizedPath -Path ([string](Get-Location).ProviderPath)
  if (-not $cwd) { exit 0 }
} catch { exit 0 }

$tempRoot = [string]$env:TEMP
if (-not $tempRoot) { exit 0 }
$leaseName = 'client-lease-{0}-{1}.json' -f $ClientPid, $clientStartUtc.Ticks
$writtenPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

try {
  while (Test-ClientIdentity -ClientProcessId $ClientPid -ExpectedStartUtc $clientStartUtc) {
    $heartbeat = [datetime]::UtcNow.ToString('o')
    # HIMMEL-1509: refresh the registry lease heartbeat FIRST, before the
    # broker scan can fail - a live render must stay provably live even while
    # its broker is not yet up or WMI is unavailable. Atomic tmp+move; the
    # Test-Path guard never resurrects a released lease dir.
    if ($LeaseDir -and (Test-Path -LiteralPath $LeaseDir)) {
      $registryHbPath = Join-Path $LeaseDir 'heartbeat'
      $registryHbTmp = "$registryHbPath.tmp-$PID"
      try {
        Set-Content -LiteralPath $registryHbTmp -Value $heartbeat -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $registryHbTmp -Destination $registryHbPath -Force
      } catch {
        Remove-Item -LiteralPath $registryHbTmp -Force -ErrorAction SilentlyContinue
      }
    }
    $leaseTokens = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $brokers = @()
    try {
      $brokers = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -ieq 'node.exe' -and [string]$_.CommandLine -match 'app-server-broker\.mjs\s+serve'
      })
    } catch { $brokers = @() }

    foreach ($broker in $brokers) {
      $commandLine = [string]$broker.CommandLine
      $token = Get-BrokerToken -CommandLine $commandLine
      $brokerCwd = Get-NormalizedPath -Path (Get-BrokerCwd -CommandLine $commandLine)
      if (-not $token -or $token -notmatch '^[A-Za-z0-9_-]+$') { continue }
      if (-not [string]::Equals($cwd, $brokerCwd, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      [void]$leaseTokens.Add($token)

      # $tokenLeaseDir, NOT $leaseDir: PowerShell names are case-insensitive,
      # so a local named $leaseDir would CLOBBER the -LeaseDir registry param
      # after the first iteration and starve the registry heartbeat into the
      # cxc token dir (HIMMEL-1509 r2 critical).
      $tokenLeaseDir = Join-Path $tempRoot "cxc-$token"
      if (-not (Test-Path -LiteralPath $tokenLeaseDir)) { continue }
      $leasePath = Join-Path $tokenLeaseDir $leaseName
      $tempPath = "$leasePath.tmp-$PID"
      $payload = [ordered]@{
        clientPid       = $ClientPid
        clientStartTime = $clientStartText
        cwd             = $cwd
        heartbeat       = $heartbeat
      } | ConvertTo-Json -Compress
      try {
        Set-Content -LiteralPath $tempPath -Value $payload -Encoding UTF8 -NoNewline
        Move-Item -LiteralPath $tempPath -Destination $leasePath -Force
        [void]$writtenPaths.Add($leasePath)
      } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
      }
    }
    # HIMMEL-1509 r9 (codex-2): the tokens file tracks EVERY observation, not
    # just non-empty ones - a stale token set must never outlive its broker
    # and keep protecting unrelated orphan trees. An empty scan removes the
    # file, degrading token protection to the sweep's cwd-matching fallback
    # (which follows reality), never to a dead broker's recorded token.
    if ($LeaseDir -and (Test-Path -LiteralPath $LeaseDir)) {
      $tokensPath = Join-Path $LeaseDir 'tokens'
      if ($leaseTokens.Count -gt 0) {
        $tokensTmp = "$tokensPath.tmp-$PID"
        try {
          Set-Content -LiteralPath $tokensTmp -Value (@($leaseTokens) -join "`n") -Encoding UTF8
          Move-Item -LiteralPath $tokensTmp -Destination $tokensPath -Force
        } catch {
          Remove-Item -LiteralPath $tokensTmp -Force -ErrorAction SilentlyContinue
        }
      } else {
        Remove-Item -LiteralPath $tokensPath -Force -ErrorAction SilentlyContinue
      }
    }
    Start-Sleep -Seconds $HeartbeatSeconds
  }
} finally {
  foreach ($leasePath in $writtenPaths) {
    Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
  }
}

exit 0
