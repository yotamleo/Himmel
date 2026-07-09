<#
  Focused helper test for machine-setup/win11.ps1 (HIMMEL-802). win11.ps1 is
  administrator-gated and mutates the machine, so this extracts only its
  Invoke-NonFatal helper and verifies a failed native command inside the block
  is recorded as a non-fatal failure. try/catch alone does not catch that case.
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Source = Join-Path $ScriptDir "win11.ps1"

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-win11-native-test-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
try {
  $raw = Get-Content -LiteralPath $Source -Raw
  $start = $raw.IndexOf("function Invoke-NonFatal")
  $end = $raw.IndexOf("function Write-SettingsJson")
  if ($start -lt 0 -or $end -le $start) { throw "could not extract Invoke-NonFatal from $Source" }
  Invoke-Expression $raw.Substring($start, $end - $start)

  $failNative = Join-Path $TMP "fail-native.ps1"
  Set-Content -Path $failNative -Encoding UTF8 -Value 'exit 29'
  $Script:Step = 7
  $Script:Failures = @()

  Write-Host "== scenario A: native failure inside Invoke-NonFatal block is recorded =="
  Invoke-NonFatal "stub native failure" { & $failNative }
  if ($Script:Failures.Count -eq 1) { Pass "native failure recorded as non-fatal failure" } else { Fail "native failure should be recorded exactly once, got $($Script:Failures.Count)" }
  if ($Script:Failures -match "stub native failure") { Pass "failure names the failed step" } else { Fail "failure did not name the failed step" }

  Write-Host ""
  if ($script:fails -eq 0) { Write-Host "ALL PASS" } else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
} finally {
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
