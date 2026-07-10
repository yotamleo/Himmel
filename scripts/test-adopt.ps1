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

# HIMMEL-842 CR round-2 (F1): scripts/jira/dist + scripts/jira/node_modules are
# gitignored build artifacts that MAY already exist in this checkout (a primary
# checkout that ran adopt.ps1/setup.ps1 before). Build-JiraCli's "already
# built" skip fires the instant either is present, which would make scenarios
# E-J below assert on the WRONG branch. Move any existing dist/node_modules
# aside for the whole suite; sentinel-tracked, restored unconditionally in the
# outer finally (mirrors the old scenario-H-only pattern, now suite-wide).
$RealJiraDist = Join-Path $ScriptDir 'jira\dist'
$RealJiraNodeModules = Join-Path $ScriptDir 'jira\node_modules'
$DistBackup = $null
$NodeModulesBackup = $null
if (Test-Path $RealJiraDist) {
    $DistBackup = Join-Path $TMP 'dist-backup'
    Move-Item -Path $RealJiraDist -Destination $DistBackup
}
if (Test-Path $RealJiraNodeModules) {
    $NodeModulesBackup = Join-Path $TMP 'node_modules-backup'
    Move-Item -Path $RealJiraNodeModules -Destination $NodeModulesBackup
}
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
  Write-Host "== scenario C: node-without-npm + no JS package manager (HIMMEL-842) -> Require-Tools fails upfront =="
  # Separate stub dir so this does not perturb scenarios A/B (which must reach
  # Install-Plugins). Same hard-required stubs (git/jq/python3 + claude soft) PLUS
  # node.cmd, but NO npm.cmd and NO bun. The scrubbed PATH (stub + System32 +
  # SystemRoot) keeps real node/npm/bun off PATH, so the broken distro-node state
  # (node present, npm absent, bun absent) is reproduced hermetically.
  $StubDirC = Join-Path $TMP "binC"
  $TargetC  = Join-Path $TMP "targetC"
  New-Item -ItemType Directory -Force -Path $StubDirC,$TargetC | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetC '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetC '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3","claude","node")) {
    Set-Content -Path (Join-Path $StubDirC "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirC "jq.cmd") -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"

  $env:Path = "$StubDirC;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outC = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetC 2>&1 | Out-String
    $codeC = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }

  if ($codeC -ne 0) { Pass "node-without-npm + no bun exits non-zero" } else { Fail "node-without-npm + no bun should exit non-zero" }
  if (($outC -match "npm") -and ($outC -match "bun.sh") -and ($outC -match "(?i)nodesource")) { Pass "error names npm + bun.sh + NodeSource install hints" } else { Fail "error missing npm/bun.sh/nodesource hint (got: $outC)" }

  Write-Host ""
  Write-Host "== scenario D: node-without-npm + bun present (HIMMEL-842) -> soft warn only, adopt proceeds =="
  # bun covers every himmel JS build, so this must NOT hard-fail (mirror of
  # test-adopt.sh scenario 13). -DryRun keeps the run side-effect-free and lets
  # Require-Tools' escalation logic be exercised without a working pwsh child
  # stub for Install-Plugins/Wire-StatuslineCore/Wire-HimmelRepoCore (claude
  # omitted -> Install-Plugins skips; -DryRun -> the rest short-circuit before
  # any child pwsh call).
  $StubDirD = Join-Path $TMP "binD"
  $TargetD  = Join-Path $TMP "targetD"
  New-Item -ItemType Directory -Force -Path $StubDirD,$TargetD | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetD '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetD '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3","node","bun")) {
    Set-Content -Path (Join-Path $StubDirD "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirD "jq.cmd") -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"

  $env:Path = "$StubDirD;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outD = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetD -DryRun 2>&1 | Out-String
    $codeD = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }

  if ($codeD -eq 0) { Pass "node-without-npm + bun present proceeds (rc=0)" } else { Fail "node-without-npm + bun present should proceed, got rc=$codeD" }
  if ($outD -match "npm") { Pass "soft-warn mentions npm" } else { Fail "missing npm soft-warn (got: $outD)" }
  if ($outD -match "no JS package manager") { Fail "must NOT hard-fail when bun present (saw hard-fail message)" } else { Pass "no hard-fail message when bun present" }

  Write-Host ""
  Write-Host "== scenario E: Build-JiraCli success path (stub npm exit 0) (HIMMEL-842 gap 3) =="
  # No -DryRun: exercises the real build branch. `claude` omitted so
  # Install-Plugins skips (ClaudeAvailable=$false); Wire-StatuslineCore /
  # Wire-HimmelRepoCore still shell out to a pwsh child unconditionally, so a
  # pwsh.cmd stub that exits 0 is required. dist/index.js is not actually
  # created by the npm stub -- the assertion is on the reported outcome.
  $StubDirE = Join-Path $TMP "binE"
  $TargetE  = Join-Path $TMP "targetE"
  New-Item -ItemType Directory -Force -Path $StubDirE,$TargetE | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetE '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetE '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3")) {
    Set-Content -Path (Join-Path $StubDirE "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirE "jq.cmd")   -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirE "pwsh.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirE "npm.cmd")  -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"

  $env:Path = "$StubDirE;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outE = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetE 2>&1 | Out-String
    $codeE = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }

  if ($codeE -eq 0) { Pass "Build-JiraCli success path: adopt exits 0" } else { Fail "Build-JiraCli success path should exit 0, got rc=$codeE" }
  if ($outE -match "Building jira CLI") { Pass "Build-JiraCli prints the build header" } else { Fail "missing 'Building jira CLI' header (got: $outE)" }
  if ($outE -match "jira CLI built") { Pass "Build-JiraCli reports built" } else { Fail "missing 'jira CLI built' success message (got: $outE)" }
  if ($outE -match "jira CLI build failed") { Fail "success path must not print a build-failed warning" } else { Pass "success path prints no build-failed warning" }

  Write-Host ""
  Write-Host "== scenario F: Build-JiraCli WARN-not-fail (stub npm exit 1) (HIMMEL-842 gap 3) =="
  # A failing build must WARN with the manual command and adopt must still
  # exit 0 -- matches Wire-QmdCore's contract; a broken jira build never
  # aborts adopt.
  $StubDirF = Join-Path $TMP "binF"
  $TargetF  = Join-Path $TMP "targetF"
  New-Item -ItemType Directory -Force -Path $StubDirF,$TargetF | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetF '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetF '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3")) {
    Set-Content -Path (Join-Path $StubDirF "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirF "jq.cmd")   -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirF "pwsh.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirF "npm.cmd")  -Encoding ASCII -Value "@echo off`r`nexit /b 1`r`n"

  $env:Path = "$StubDirF;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outF = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetF 2>&1 | Out-String
    $codeF = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }

  if ($codeF -eq 0) { Pass "Build-JiraCli WARN-not-fail: adopt exits 0 on a build failure" } else { Fail "Build-JiraCli WARN-not-fail should exit 0, got rc=$codeF" }
  if ($outF -match "WARNING.*jira CLI build failed") { Pass "Build-JiraCli prints the build-failed WARNING" } else { Fail "missing build-failed WARNING (got: $outF)" }
  if ($outF -match [regex]::Escape("npm install") -and $outF -match [regex]::Escape("npm run build")) { Pass "WARNING includes the manual command" } else { Fail "missing manual command in WARNING (got: $outF)" }

  Write-Host ""
  Write-Host "== scenario G: Build-JiraCli skip when no JS package manager (HIMMEL-842 gap 3) =="
  # npm AND bun both absent -> Build-JiraCli skips with the manual command and
  # never attempts a build. Real run (no -DryRun) exercises the skip branch,
  # not the DRY branch.
  $StubDirG = Join-Path $TMP "binG"
  $TargetG  = Join-Path $TMP "targetG"
  New-Item -ItemType Directory -Force -Path $StubDirG,$TargetG | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetG '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetG '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3")) {
    Set-Content -Path (Join-Path $StubDirG "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirG "jq.cmd")   -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirG "pwsh.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"

  $env:Path = "$StubDirG;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outG = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetG 2>&1 | Out-String
    $codeG = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }

  if ($codeG -eq 0) { Pass "Build-JiraCli skip path: adopt exits 0" } else { Fail "Build-JiraCli skip path should exit 0, got rc=$codeG" }
  if ($outG -match [regex]::Escape("jira CLI: skipping build (no npm or bun")) { Pass "Build-JiraCli prints the no-pm skip note" } else { Fail "missing no-pm skip note (got: $outG)" }
  if ($outG -match "Building jira CLI") { Fail "no-pm path must NOT attempt a build (saw build header)" } else { Pass "no-pm path attempts no build" }

  Write-Host ""
  Write-Host "== scenario H: Build-JiraCli idempotent when dist AND node_modules already built (HIMMEL-842 gap 3, F3: skip requires BOTH) =="
  # The suite-wide move-aside above guarantees scripts/jira/dist and
  # scripts/jira/node_modules are both absent entering this scenario; create
  # both so Build-JiraCli's "already built" branch fires. Removed right after
  # (dist/ and node_modules/ are gitignored, so this never pollutes git); the
  # outer finally restores the real ones unconditionally regardless.
  New-Item -ItemType Directory -Force -Path $RealJiraDist | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $RealJiraDist 'index.js') | Out-Null
  New-Item -ItemType Directory -Force -Path $RealJiraNodeModules | Out-Null
  $StubDirH = Join-Path $TMP "binH"
  $TargetH  = Join-Path $TMP "targetH"
  New-Item -ItemType Directory -Force -Path $StubDirH,$TargetH | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetH '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetH '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3")) {
    Set-Content -Path (Join-Path $StubDirH "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirH "jq.cmd")   -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirH "pwsh.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"

  $env:Path = "$StubDirH;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outH = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetH 2>&1 | Out-String
    $codeH = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  }

  if ($codeH -eq 0) { Pass "Build-JiraCli idempotent path: adopt exits 0" } else { Fail "Build-JiraCli idempotent path should exit 0, got rc=$codeH" }
  if ($outH -match [regex]::Escape("jira CLI dist already built")) { Pass "Build-JiraCli prints the already-built skip" } else { Fail "missing 'already built' skip (got: $outH)" }
  if ($outH -match "Building jira CLI") { Fail "already-built path must NOT attempt a build" } else { Pass "already-built path attempts no build" }

  Write-Host ""
  Write-Host "== scenario I: Build-JiraCli builds when dist present but node_modules ABSENT (HIMMEL-842 gap 3, F3) =="
  # A stale dist/ without node_modules/ previously passed as "already built"
  # then failed at runtime -- F3 requires BOTH halves present to skip.
  New-Item -ItemType Directory -Force -Path $RealJiraDist | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $RealJiraDist 'index.js') | Out-Null
  # node_modules stays absent (suite-wide baseline).
  $StubDirI = Join-Path $TMP "binI"
  $TargetI  = Join-Path $TMP "targetI"
  New-Item -ItemType Directory -Force -Path $StubDirI,$TargetI | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetI '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetI '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3")) {
    Set-Content -Path (Join-Path $StubDirI "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirI "jq.cmd")   -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirI "pwsh.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirI "npm.cmd")  -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"

  $env:Path = "$StubDirI;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outI = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetI 2>&1 | Out-String
    $codeI = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
  }

  if ($codeI -eq 0) { Pass "dist-present/node_modules-absent: adopt exits 0" } else { Fail "dist-present/node_modules-absent should exit 0, got rc=$codeI" }
  if ($outI -match "Building jira CLI") { Pass "Build-JiraCli builds (does not skip) when node_modules absent" } else { Fail "missing build header -- should NOT skip (got: $outI)" }
  if ($outI -match [regex]::Escape("jira CLI dist already built")) { Fail "must NOT take the already-built skip branch" } else { Pass "no already-built skip message" }

  Write-Host ""
  Write-Host "== scenario J: Build-JiraCli bun branch, REAL invocation (HIMMEL-842 gap 3, F5) =="
  # npm absent, bun stubbed; assert the bun install/build lines actually ran
  # (success path is enough per F5). No -DryRun -- the bun branch was
  # previously only exercised via -DryRun (scenario D).
  $StubDirJ = Join-Path $TMP "binJ"
  $TargetJ  = Join-Path $TMP "targetJ"
  New-Item -ItemType Directory -Force -Path $StubDirJ,$TargetJ | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetJ '.claude') | Out-Null
  Set-Content -Path (Join-Path $TargetJ '.claude\settings.json') -Value '{}'
  foreach ($name in @("git","python3")) {
    Set-Content -Path (Join-Path $StubDirJ "$name.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  }
  Set-Content -Path (Join-Path $StubDirJ "jq.cmd")   -Encoding ASCII -Value "@echo off`r`necho {}`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirJ "pwsh.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDirJ "bun.cmd")  -Encoding ASCII -Value @"
@echo off
if "%1"=="install" echo BUN_INSTALL_STUB_RAN& exit /b 0
if "%1%2"=="runbuild" echo BUN_BUILD_STUB_RAN& exit /b 0
exit /b 0
"@

  $env:Path = "$StubDirJ;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $outJ = & $realPwsh -NoProfile -NonInteractive -File $Installer -Profile core -Scope project -Target $TargetJ 2>&1 | Out-String
    $codeJ = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }

  if ($codeJ -eq 0) { Pass "Build-JiraCli bun real-invocation: adopt exits 0" } else { Fail "Build-JiraCli bun real-invocation should exit 0, got rc=$codeJ" }
  if ($outJ -match "BUN_INSTALL_STUB_RAN") { Pass "bun install ran" } else { Fail "bun install did not run (got: $outJ)" }
  if ($outJ -match "BUN_BUILD_STUB_RAN") { Pass "bun run build ran" } else { Fail "bun run build did not run (got: $outJ)" }
  if ($outJ -match "jira CLI built") { Pass "Build-JiraCli reports built" } else { Fail "missing success message (got: $outJ)" }

  Write-Host ""
  if ($script:fails -eq 0) { Write-Host "ALL PASS" } else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
} finally {
  Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  if ($DistBackup) { Move-Item -Path $DistBackup -Destination $RealJiraDist }
  if ($NodeModulesBackup) { Move-Item -Path $NodeModulesBackup -Destination $RealJiraNodeModules }
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
