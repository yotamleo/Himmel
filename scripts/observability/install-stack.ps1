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

Invoke-PackageInstall -Name 'Prometheus' -WingetIds @('Prometheus.Prometheus') -ScoopName 'prometheus'
Invoke-PackageInstall -Name 'Grafana OSS' -WingetIds @('GrafanaLabs.GrafanaOSS', 'GrafanaLabs.Grafana.OSS', 'GrafanaLabs.Grafana') -ScoopName 'grafana'
Invoke-PackageInstall -Name 'windows_exporter' -WingetIds @('Prometheus.WindowsExporter', 'prometheus-community.windows_exporter') -ScoopName 'windows_exporter'
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Invoke-PackageInstall -Name 'Bun' -WingetIds @('Oven-sh.Bun') -ScoopName 'bun'
}

# winget/scoop add PATH entries this session cannot see yet; refresh from the
# registry scopes so Resolve-RequiredCommand works on a clean machine.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$prometheusExe = Resolve-RequiredCommand -DisplayName 'Prometheus' -Names @('prometheus.exe', 'prometheus')
$grafanaExe = Resolve-RequiredCommand -DisplayName 'Grafana' -Names @('grafana-server.exe', 'grafana-server')
$windowsExporterExe = Resolve-RequiredCommand -DisplayName 'windows_exporter' -Names @('windows_exporter.exe', 'windows_exporter')
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
  -Arguments "--homepath `"$grafanaHome`" --config `"$grafanaIni`"" `
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
