<#
  Hermetic native-exit test for setup.ps1 (HIMMEL-802). The child run resolves
  a fake repo root through stub git and uses stub native tools. The python stub
  fails only the pre_commit install mutation so setup.ps1 must stop there with
  the native exit code instead of drifting into later setup steps.
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Installer = Join-Path $ScriptDir "setup.ps1"

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-setup-native-test-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
try {
  $StubDir = Join-Path $TMP "bin"
  $FakeRoot = Join-Path $TMP "repo"
  $FakeHome = Join-Path $TMP "home"
  New-Item -ItemType Directory -Force -Path $StubDir,$FakeRoot,$FakeHome | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $FakeRoot "scripts\jira") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $FakeRoot "scripts\lib") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $FakeRoot "scripts\setup") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $FakeRoot "scripts\machine-setup") | Out-Null
  Set-Content -Path (Join-Path $FakeRoot ".env.example") -Value "JIRA_API_TOKEN=`n"
  Set-Content -Path (Join-Path $FakeRoot "scripts\lib\fix-qmd-stub.sh") -Encoding ASCII -Value "#!/usr/bin/env bash`nexit 0`n"
  Set-Content -Path (Join-Path $FakeRoot "scripts\handover-link.sh") -Encoding ASCII -Value "#!/usr/bin/env bash`nexit 0`n"

  foreach ($name in @("node","npm","bun","jq","gh","bash","claude","pwsh")) {
    Set-Content -Path (Join-Path $StubDir "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDir "git.cmd") -Encoding ASCII -Value @"
@echo off
echo %* | findstr /i "rev-parse" >nul
if %errorlevel%==0 (
  echo %SETUP_FAKE_ROOT%
  exit /b 0
)
exit /b 0
"@
  Set-Content -Path (Join-Path $StubDir "python.cmd") -Encoding ASCII -Value @"
@echo off
if "%1"=="-m" if "%2"=="pre_commit" if "%3"=="install" exit /b 17
exit /b 0
"@

  $realPwsh = (Get-Command pwsh -CommandType Application).Source
  $oldPath = $env:Path
  $oldRoot = $env:SETUP_FAKE_ROOT
  $oldHome = $env:HOME
  $oldUserProfile = $env:USERPROFILE
  $env:Path = "$StubDir;$env:SystemRoot\System32;$env:SystemRoot"
  $env:SETUP_FAKE_ROOT = $FakeRoot
  $env:HOME = $FakeHome
  $env:USERPROFILE = $FakeHome
  try {
    $out = & $realPwsh -NoProfile -NonInteractive -File $Installer 2>&1 | Out-String
    $code = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    if ($null -eq $oldRoot) { Remove-Item Env:SETUP_FAKE_ROOT -ErrorAction SilentlyContinue } else { $env:SETUP_FAKE_ROOT = $oldRoot }
    if ($null -eq $oldHome) { Remove-Item Env:HOME -ErrorAction SilentlyContinue } else { $env:HOME = $oldHome }
    if ($null -eq $oldUserProfile) { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $oldUserProfile }
  }

  Write-Host "== scenario A: pre_commit hook install fails (mutation) -> exits non-zero, names the step + exit code =="
  if ($code -ne 0) { Pass "failed pre_commit install exits non-zero" } else { Fail "failed pre_commit install should exit non-zero" }
  if ($out -match "pre_commit install failed" -and $out -match "exit 17") { Pass "error names pre_commit install step + exit code" } else { Fail "error message missing pre_commit install step/exit-code detail (got: $out)" }

  Write-Host ""
  if ($script:fails -eq 0) { Write-Host "ALL PASS" } else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
} finally {
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
