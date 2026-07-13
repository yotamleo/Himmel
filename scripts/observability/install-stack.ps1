param(
  [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)
  Write-Output "[observability] $Message"
}

function Invoke-PackageInstall {
  param(
    [string]$Name,
    [string[]]$WingetIds,
    [string]$ScoopName
  )

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    foreach ($wingetId in $WingetIds) {
      Write-Step "Installing $Name with winget id $wingetId"
      winget install --id $wingetId -e --silent --accept-source-agreements --accept-package-agreements
      if ($LASTEXITCODE -eq 0) { return }
    }
    Write-Warning "winget install failed for $Name; trying scoop when available"
  }

  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    # prometheus / grafana / windows_exporter live in the extras bucket;
    # adding it is idempotent-ish (fails benignly when already registered).
    Write-Step "Ensuring scoop extras bucket"
    scoop bucket add extras 2>$null | Out-Null
    Write-Step "Installing $Name with scoop package $ScoopName"
    scoop install $ScoopName
    if ($LASTEXITCODE -eq 0) { return }
  }

  Write-Warning "Could not install $Name automatically. Install it manually, then re-run this script."
}

function Resolve-RequiredCommand {
  param(
    [string]$DisplayName,
    [string[]]$Names
  )

  foreach ($name in $Names) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  throw "Required command for $DisplayName was not found on PATH after install attempt: $($Names -join ', ')"
}

function Register-LogonTask {
  param(
    [string]$TaskName,
    [string]$Execute,
    [string]$Arguments,
    [string]$WorkingDirectory
  )

  $action = New-ScheduledTaskAction -Execute $Execute -Argument $Arguments -WorkingDirectory $WorkingDirectory
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

  Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "himmel local observability stack task" `
    -Force | Out-Null
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) {
  $RepoRoot = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
} else {
  $RepoRoot = (Resolve-Path $RepoRoot).Path
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'himmel\observability'
$promData = Join-Path $stateRoot 'prometheus-data'
$grafanaData = Join-Path $stateRoot 'grafana-data'
$grafanaLogs = Join-Path $stateRoot 'grafana-logs'
$grafanaPlugins = Join-Path $stateRoot 'grafana-plugins'
New-Item -ItemType Directory -Path $stateRoot, $promData, $grafanaData, $grafanaLogs, $grafanaPlugins -Force | Out-Null

# Pinned official release artifacts into the state root — NO winget/msiexec
# on the default path (live s53 install: Prometheus has no winget package at
# all, and the Grafana / windows_exporter MSIs are perMachine -> an invisible
# UAC wait under automation, msiexec mutex deadlocks). Everything below is
# elevation-free and user-scoped, matching the user-level scheduled tasks.
$promVersion = '3.13.1'
$grafanaVersion = '13.1.0'
$weVersion = '0.31.7'
# Pinned SHA-256 of each artifact, from the projects' published checksum
# files (prometheus sha256sums.txt, dl.grafana.com .sha256, windows_exporter
# sha256sums.txt). Bump these together with the versions.
$promSha256 = '5409abdcac847984ab7869d7814e6e8cff65b4411d62e7477b960b92eadfa08a'
$grafanaSha256 = '2c5c0733fc87129334333987799e26807a5eef1572c40941909d948392cf29f4'
$weSha256 = '288252baf470da41494420250e68b5358992701298f77a36d821992b589eccdd'
$promBinDir = Join-Path $stateRoot "prometheus-$promVersion"
$grafanaHomeDir = Join-Path $stateRoot "grafana-$grafanaVersion"
$weBinDir = Join-Path $stateRoot "windows_exporter-$weVersion"

function Assert-FileHash {
  param([string]$Path, [string]$Expected, [string]$Name)
  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Expected.ToLowerInvariant()) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    throw "SHA-256 mismatch for $Name (expected $Expected, got $actual) - download deleted, refusing to install it."
  }
}

if (-not (Test-Path (Join-Path $promBinDir 'prometheus.exe'))) {
  Write-Step "Downloading Prometheus v$promVersion release zip"
  $promZip = Join-Path $stateRoot "prometheus-$promVersion.zip"
  Invoke-WebRequest -Uri "https://github.com/prometheus/prometheus/releases/download/v$promVersion/prometheus-$promVersion.windows-amd64.zip" -OutFile $promZip
  Assert-FileHash -Path $promZip -Expected $promSha256 -Name 'Prometheus zip'
  Expand-Archive -LiteralPath $promZip -DestinationPath $stateRoot -Force
  # A partial dir from an aborted run would make Move-Item nest instead of rename.
  if (Test-Path $promBinDir) { Remove-Item -LiteralPath $promBinDir -Recurse -Force }
  Move-Item -LiteralPath (Join-Path $stateRoot "prometheus-$promVersion.windows-amd64") -Destination $promBinDir -Force
  Remove-Item -LiteralPath $promZip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $grafanaHomeDir 'bin\grafana.exe'))) {
  Write-Step "Downloading Grafana OSS v$grafanaVersion release zip"
  $grafanaZip = Join-Path $stateRoot "grafana-$grafanaVersion.zip"
  Invoke-WebRequest -Uri "https://dl.grafana.com/oss/release/grafana-$grafanaVersion.windows-amd64.zip" -OutFile $grafanaZip
  Assert-FileHash -Path $grafanaZip -Expected $grafanaSha256 -Name 'Grafana zip'
  Expand-Archive -LiteralPath $grafanaZip -DestinationPath $stateRoot -Force
  Remove-Item -LiteralPath $grafanaZip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $weBinDir 'windows_exporter.exe'))) {
  Write-Step "Downloading windows_exporter v$weVersion release binary"
  New-Item -ItemType Directory -Path $weBinDir -Force | Out-Null
  $weExe = Join-Path $weBinDir 'windows_exporter.exe'
  Invoke-WebRequest -Uri "https://github.com/prometheus-community/windows_exporter/releases/download/v$weVersion/windows_exporter-$weVersion-amd64.exe" -OutFile $weExe
  Assert-FileHash -Path $weExe -Expected $weSha256 -Name 'windows_exporter binary'
}
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Invoke-PackageInstall -Name 'Bun' -WingetIds @('Oven-sh.Bun') -ScoopName 'bun'
}

# winget/scoop add PATH entries this session cannot see yet; refresh from the
# registry scopes so Resolve-RequiredCommand works on a clean machine.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$prometheusExe = if (Test-Path (Join-Path $promBinDir 'prometheus.exe')) {
  Join-Path $promBinDir 'prometheus.exe'
} else {
  Resolve-RequiredCommand -DisplayName 'Prometheus' -Names @('prometheus.exe', 'prometheus')
}
# Modern Grafana ships bin\grafana.exe (the `server` subcommand replaced the
# old grafana-server.exe binary).
$grafanaExe = if (Test-Path (Join-Path $grafanaHomeDir 'bin\grafana.exe')) {
  Join-Path $grafanaHomeDir 'bin\grafana.exe'
} else {
  Resolve-RequiredCommand -DisplayName 'Grafana' -Names @('grafana.exe', 'grafana-server.exe', 'grafana-server')
}
$grafanaServerArgPrefix = ''
if ((Split-Path -Leaf $grafanaExe) -eq 'grafana.exe') { $grafanaServerArgPrefix = 'server ' }
$windowsExporterExe = if (Test-Path (Join-Path $weBinDir 'windows_exporter.exe')) {
  Join-Path $weBinDir 'windows_exporter.exe'
} else {
  Resolve-RequiredCommand -DisplayName 'windows_exporter' -Names @('windows_exporter.exe', 'windows_exporter')
}
$bunExe = Resolve-RequiredCommand -DisplayName 'Bun' -Names @('bun.exe', 'bun')

$prometheusConfig = Join-Path $stateRoot 'prometheus.yml'
Copy-Item -LiteralPath (Join-Path $scriptDir 'prometheus.yml') -Destination $prometheusConfig -Force

$grafanaIni = Join-Path $stateRoot 'grafana.ini'
@"
[server]
http_addr = 127.0.0.1
http_port = 3000

[paths]
data = $($grafanaData.Replace('\', '/'))
logs = $($grafanaLogs.Replace('\', '/'))
plugins = $($grafanaPlugins.Replace('\', '/'))
"@ | Set-Content -LiteralPath $grafanaIni -Encoding utf8

$grafanaBin = Split-Path -Parent $grafanaExe
if ($grafanaBin -like '*\scoop\shims*') {
  # A scoop shim's parent is the shims dir, not Grafana's install root.
  $grafanaHome = (scoop prefix grafana).Trim()
} else {
  $grafanaHome = Split-Path -Parent $grafanaBin
}
$flowExporter = Join-Path $RepoRoot 'scripts\observability\flow-exporter.ts'

Register-LogonTask `
  -TaskName 'himmel-observability-prometheus' `
  -Execute $prometheusExe `
  -Arguments "--config.file=`"$prometheusConfig`" --storage.tsdb.path=`"$promData`" --web.listen-address=127.0.0.1:9090" `
  -WorkingDirectory $stateRoot

Register-LogonTask `
  -TaskName 'himmel-observability-grafana' `
  -Execute $grafanaExe `
  -Arguments "$grafanaServerArgPrefix--homepath `"$grafanaHome`" --config `"$grafanaIni`"" `
  -WorkingDirectory $grafanaHome

Register-LogonTask `
  -TaskName 'himmel-observability-windows-exporter' `
  -Execute $windowsExporterExe `
  -Arguments "--web.listen-address=127.0.0.1:9182" `
  -WorkingDirectory $stateRoot

Register-LogonTask `
  -TaskName 'himmel-observability-flow-exporter' `
  -Execute $bunExe `
  -Arguments "run `"$flowExporter`"" `
  -WorkingDirectory $RepoRoot

# Logon triggers only fire at the NEXT logon; start each task now so the
# verification URLs below are live immediately after install.
foreach ($taskName in @(
    'himmel-observability-prometheus',
    'himmel-observability-grafana',
    'himmel-observability-windows-exporter',
    'himmel-observability-flow-exporter')) {
  Write-Step "Starting $taskName"
  Start-ScheduledTask -TaskName $taskName
}

Write-Output ''
Write-Output 'Verification:'
Write-Output '  Prometheus:       http://127.0.0.1:9090'
Write-Output '  Grafana:          http://127.0.0.1:3000'
Write-Output '  flow exporter:    http://127.0.0.1:9877/metrics'
Write-Output '  windows_exporter: http://127.0.0.1:9182/metrics'
Write-Output '  Scheduled tasks:'
Write-Output '    himmel-observability-prometheus'
Write-Output '    himmel-observability-grafana'
Write-Output '    himmel-observability-windows-exporter'
Write-Output '    himmel-observability-flow-exporter'
