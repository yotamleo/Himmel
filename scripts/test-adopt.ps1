<#
  Hermetic native-exit test for adopt.ps1 (HIMMEL-802). The child run uses
  stub tools on PATH; the stub pwsh fails only the install-plugins.ps1 child
  call so the test proves adopt.ps1 itself checks that native exit code.
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Installer = Join-Path $ScriptDir "adopt.ps1"

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-adopt-native-test-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
try {
  $StubDir = Join-Path $TMP "bin"
  $Target = Join-Path $TMP "target"
  New-Item -ItemType Directory -Force -Path $StubDir,$Target | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Target '.claude') | Out-Null
  Set-Content -Path (Join-Path $Target '.claude\settings.json') -Value '{}'
  $Log = Join-Path $TMP "calls.log"
  Set-Content -Path $Log -Value "" -NoNewline

  foreach ($name in @("git","python3","claude")) {
    Set-Content -Path (Join-Path $StubDir "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDir "jq.cmd") -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDir "pwsh.cmd") -Encoding ASCII -Value @"
@echo off
echo %*>> "%ADOPT_STUB_LOG%"
echo %* | findstr /i "install-plugins.ps1" >nul
if %errorlevel%==0 exit /b 23
exit /b 0
"@

  $realPwsh = (Get-Command pwsh -CommandType Application).Source
  $oldPath = $env:Path
  $oldLog = $env:ADOPT_STUB_LOG
  $env:Path = "$StubDir;$env:SystemRoot\System32;$env:SystemRoot"
  $env:ADOPT_STUB_LOG = $Log
  try {
    $out = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $Target 2>&1 | Out-String
    $code = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    if ($null -eq $oldLog) { Remove-Item Env:ADOPT_STUB_LOG -ErrorAction SilentlyContinue } else { $env:ADOPT_STUB_LOG = $oldLog }
  }

  Write-Host "== scenario A: install-plugins child fails (mutation) -> exits non-zero, names the step + exit code =="
  if ($code -ne 0) { Pass "failed install-plugins exits non-zero" } else { Fail "failed install-plugins should exit non-zero" }
  if ($out -match "install-plugins failed" -and $out -match "exit \d+") { Pass "error names install-plugins step + exit code" } else { Fail "error message missing install-plugins step/exit-code detail (got: $out)" }

  Write-Host ""
  Write-Host "== scenario B: -Scope user (no Push-Location branch in Install-Plugins) hits the same check =="
  # -Scope user reads/writes `$HOME\.claude\settings.json` (adopt.ps1 line ~408)
  # instead of -Target's `.claude\settings.json` — redirect the child process's
  # HOME to a sandboxed fake profile so this test never touches the real
  # operator ~/.claude/settings.json.
  $UserHome = Join-Path $TMP "userhome"
  New-Item -ItemType Directory -Force -Path (Join-Path $UserHome '.claude') | Out-Null
  Set-Content -Path (Join-Path $UserHome '.claude\settings.json') -Value '{}'

  $oldUserProfile = $env:USERPROFILE
  $env:Path = "$StubDir;$env:SystemRoot\System32;$env:SystemRoot"
  $env:ADOPT_STUB_LOG = $Log
  $env:USERPROFILE = $UserHome
  try {
    $outB = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope user 2>&1 | Out-String
    $codeB = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    $env:USERPROFILE = $oldUserProfile
    if ($null -eq $oldLog) { Remove-Item Env:ADOPT_STUB_LOG -ErrorAction SilentlyContinue } else { $env:ADOPT_STUB_LOG = $oldLog }
  }

  if ($codeB -ne 0) { Pass "user-scope failed install-plugins exits non-zero" } else { Fail "user-scope failed install-plugins should exit non-zero" }
  if ($outB -match "install-plugins failed" -and $outB -match "exit \d+") { Pass "user-scope error names install-plugins step + exit code" } else { Fail "user-scope error message missing install-plugins step/exit-code detail (got: $outB)" }

  Write-Host ""
  if ($script:fails -eq 0) { Write-Host "ALL PASS" } else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
} finally {
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
