<#
  test-preflight-adopter.ps1 — smoke tests for the standalone check-only
  adopter preflight PS1 twin (HIMMEL-842 CR round-2, F4):
  scripts/preflight-adopter.ps1 + its shared lib scripts/lib/preflight-adopter.ps1.

  Mirrors scripts/test-preflight-adopter.sh's scenarios. Hermetic full-PATH-
  replacement style like test-adopt.ps1 scenarios C-H: each scenario points
  $env:Path at a throwaway stub dir + System32 + SystemRoot only (no real
  uv/pipx/node/npm/bun can leak in), invokes a REAL pwsh child process, and
  asserts on $LASTEXITCODE + captured output.

  scripts/jira/dist + scripts/jira/node_modules in THIS worktree (gitignored
  build artifacts Test-PreflightJiraDist reads via $HimmelRoot, which
  preflight-adopter.ps1 derives from its own script path == this repo) are
  moved aside at suite start so every scenario starts from a known "absent"
  baseline, then restored unconditionally in the outer finally.

  Covers:
    1. standalone, fully clean env -> "0 warnings", exit 0.
    2. standalone, pipx present (uv absent) -> clean, exit 0 (F6).
    3. standalone, uv+pipx both absent -> WARN, exit 0 (non-strict default).
    4. standalone, node present + npm absent -> WARN, exit 0 (non-strict).
    5. standalone, jira dist+node_modules absent -> WARN, exit 0 (non-strict).
    6. -Strict with a WARN present -> exit 1.
    7. -Strict with a fully clean env -> exit 0.
    8. structural: adopt.ps1's Require-Tools reuses the shared lib functions
       (dot-sources scripts/lib/preflight-adopter.ps1, calls each Test-Preflight*
       function) instead of duplicating the check/warn-text logic.
    9. F2: Test-PreflightJiraDist WARNs + returns $false when $HimmelRoot unset.
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Preflight = Join-Path $ScriptDir "preflight-adopter.ps1"
$Lib       = Join-Path $ScriptDir "lib\preflight-adopter.ps1"
$AdoptPs1  = Join-Path $ScriptDir "adopt.ps1"

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }

if (-not (Test-Path $Preflight)) { Write-Host "FAIL: $Preflight not found" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Lib))       { Write-Host "FAIL: $Lib not found" -ForegroundColor Red; exit 1 }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-preflight-test-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null

# scripts/jira/dist + scripts/jira/node_modules are gitignored build artifacts
# in THIS worktree — move any existing ones aside so every scenario below
# starts from a known "absent" baseline. Restored unconditionally in the
# outer finally, alongside the scratch dir.
$RealJiraDist        = Join-Path $ScriptDir 'jira\dist'
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

$realPwsh = (Get-Command pwsh -CommandType Application).Source
$oldPath = $env:Path

try {
  # ── 1. standalone, fully clean env -> "0 warnings", exit 0 ─────────────────
  $StubDir1 = Join-Path $TMP "bin1"
  New-Item -ItemType Directory -Force -Path $StubDir1 | Out-Null
  Set-Content -Path (Join-Path $StubDir1 "uv.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  New-Item -ItemType Directory -Force -Path $RealJiraDist | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $RealJiraDist 'index.js') | Out-Null
  New-Item -ItemType Directory -Force -Path $RealJiraNodeModules | Out-Null

  $env:Path = "$StubDir1;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $out1 = & $realPwsh -NoProfile -NonInteractive -File $Preflight 2>&1 | Out-String
    $code1 = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  }
  if ($code1 -eq 0) { Pass "clean env exits 0" } else { Fail "clean env should exit 0, got rc=$code1" }
  if ($out1 -match "0 warnings") { Pass "clean env reports 0 warnings" } else { Fail "clean env missing '0 warnings' (got: $out1)" }
  if ($out1 -cmatch "WARNING:") { Fail "clean env has an unexpected WARNING (got: $out1)" } else { Pass "clean env has no WARNING" }

  # ── 2. pipx present (uv absent) -> clean, exit 0 (F6: uv OR pipx) ──────────
  $StubDir2 = Join-Path $TMP "bin2"
  New-Item -ItemType Directory -Force -Path $StubDir2 | Out-Null
  Set-Content -Path (Join-Path $StubDir2 "pipx.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  New-Item -ItemType Directory -Force -Path $RealJiraDist | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $RealJiraDist 'index.js') | Out-Null
  New-Item -ItemType Directory -Force -Path $RealJiraNodeModules | Out-Null

  $env:Path = "$StubDir2;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $out2 = & $realPwsh -NoProfile -NonInteractive -File $Preflight 2>&1 | Out-String
    $code2 = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  }
  if ($code2 -eq 0) { Pass "pipx-only exits 0" } else { Fail "pipx-only should exit 0, got rc=$code2" }
  if ($out2 -match "0 warnings") { Pass "pipx-only reports 0 warnings" } else { Fail "pipx-only missing '0 warnings' (got: $out2)" }
  if ($out2 -cmatch "WARNING:") { Fail "pipx-only has an unexpected WARNING (got: $out2)" } else { Pass "pipx-only has no WARNING" }

  # ── 3. uv+pipx both absent -> WARN, exit 0 (non-strict default) ────────────
  $StubDir3 = Join-Path $TMP "bin3"
  New-Item -ItemType Directory -Force -Path $StubDir3 | Out-Null
  New-Item -ItemType Directory -Force -Path $RealJiraDist | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $RealJiraDist 'index.js') | Out-Null
  New-Item -ItemType Directory -Force -Path $RealJiraNodeModules | Out-Null

  $env:Path = "$StubDir3;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $out3 = & $realPwsh -NoProfile -NonInteractive -File $Preflight 2>&1 | Out-String
    $code3 = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  }
  if ($code3 -eq 0) { Pass "uv/pipx gap: non-strict exits 0" } else { Fail "uv/pipx gap should exit 0, got rc=$code3" }
  if ($out3 -match [regex]::Escape("neither 'uv' nor 'pipx' found")) { Pass "uv/pipx gap WARN text present" } else { Fail "missing uv/pipx WARN text (got: $out3)" }
  if ($out3 -match "warning\(s\)") { Pass "uv/pipx gap warning-count summary present" } else { Fail "missing warning-count summary (got: $out3)" }

  # ── 4. node present + npm absent -> WARN, exit 0 (non-strict) ──────────────
  $StubDir4 = Join-Path $TMP "bin4"
  New-Item -ItemType Directory -Force -Path $StubDir4 | Out-Null
  Set-Content -Path (Join-Path $StubDir4 "uv.cmd")   -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  Set-Content -Path (Join-Path $StubDir4 "node.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  New-Item -ItemType Directory -Force -Path $RealJiraDist | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $RealJiraDist 'index.js') | Out-Null
  New-Item -ItemType Directory -Force -Path $RealJiraNodeModules | Out-Null

  $env:Path = "$StubDir4;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $out4 = & $realPwsh -NoProfile -NonInteractive -File $Preflight 2>&1 | Out-String
    $code4 = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  }
  if ($code4 -eq 0) { Pass "node-without-npm: non-strict exits 0" } else { Fail "node-without-npm should exit 0, got rc=$code4" }
  if ($out4 -match [regex]::Escape("'node' found but 'npm' is missing")) { Pass "node-without-npm WARN text present" } else { Fail "missing node-without-npm WARN text (got: $out4)" }

  # ── 5. jira dist+node_modules absent -> WARN, exit 0 (non-strict) ──────────
  $StubDir5 = Join-Path $TMP "bin5"
  New-Item -ItemType Directory -Force -Path $StubDir5 | Out-Null
  Set-Content -Path (Join-Path $StubDir5 "uv.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  # $RealJiraDist / $RealJiraNodeModules stay absent (moved-aside baseline).

  $env:Path = "$StubDir5;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $out5 = & $realPwsh -NoProfile -NonInteractive -File $Preflight 2>&1 | Out-String
    $code5 = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }
  if ($code5 -eq 0) { Pass "jira-dist gap: non-strict exits 0" } else { Fail "jira-dist gap should exit 0, got rc=$code5" }
  if ($out5 -match [regex]::Escape("scripts/jira/dist/index.js not built")) { Pass "jira-dist gap WARN text present" } else { Fail "missing jira-dist WARN text (got: $out5)" }

  # ── 6. -Strict with a WARN present -> exit 1 ────────────────────────────────
  # $RealJiraDist/node_modules absent -> the jira-dist gap alone trips -Strict.
  $StubDir6 = Join-Path $TMP "bin6"
  New-Item -ItemType Directory -Force -Path $StubDir6 | Out-Null
  Set-Content -Path (Join-Path $StubDir6 "uv.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"

  $env:Path = "$StubDir6;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $out6 = & $realPwsh -NoProfile -NonInteractive -File $Preflight -Strict 2>&1 | Out-String
    $code6 = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
  }
  if ($code6 -eq 1) { Pass "-Strict with a WARN present exits 1" } else { Fail "-Strict with a WARN present should exit 1, got rc=$code6" }

  # ── 7. -Strict with a fully clean env -> exit 0 ─────────────────────────────
  $StubDir7 = Join-Path $TMP "bin7"
  New-Item -ItemType Directory -Force -Path $StubDir7 | Out-Null
  Set-Content -Path (Join-Path $StubDir7 "uv.cmd") -Encoding ASCII -Value "@echo off`r`nexit /b 0`r`n"
  New-Item -ItemType Directory -Force -Path $RealJiraDist | Out-Null
  New-Item -ItemType File -Force -Path (Join-Path $RealJiraDist 'index.js') | Out-Null
  New-Item -ItemType Directory -Force -Path $RealJiraNodeModules | Out-Null

  $env:Path = "$StubDir7;$env:SystemRoot\System32;$env:SystemRoot"
  try {
    $out7 = & $realPwsh -NoProfile -NonInteractive -File $Preflight -Strict 2>&1 | Out-String
    $code7 = $LASTEXITCODE
  } finally {
    $env:Path = $oldPath
    Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  }
  if ($code7 -eq 0) { Pass "-Strict with a clean env exits 0" } else { Fail "-Strict with a clean env should exit 0, got rc=$code7" }
  if ($out7 -match "0 warnings") { Pass "-Strict clean env reports 0 warnings" } else { Fail "-Strict clean env missing '0 warnings' (got: $out7)" }

  # ── 8. structural: adopt.ps1's Require-Tools reuses the shared lib ─────────
  # (no duplicated logic, per the HIMMEL-842 spec) instead of re-implementing
  # the check/warn-text logic inline.
  $adoptSrc = Get-Content -Raw -LiteralPath $AdoptPs1
  if ($adoptSrc -notmatch [regex]::Escape('lib/preflight-adopter.ps1') -and $adoptSrc -notmatch [regex]::Escape('lib\preflight-adopter.ps1')) {
    Fail "structural: adopt.ps1 does not dot-source scripts/lib/preflight-adopter.ps1"
  } else {
    Pass "structural: adopt.ps1 dot-sources scripts/lib/preflight-adopter.ps1"
  }
  foreach ($fn in @('Test-PreflightUvPipx','Test-PreflightNpmInvocable','Test-PreflightJiraDist')) {
    if ($adoptSrc -match [regex]::Escape($fn)) { Pass "structural: adopt.ps1's Require-Tools calls $fn" } else { Fail "structural: adopt.ps1's Require-Tools does not call $fn (shared lib function)" }
  }
  # The shared warn text must live in the lib, not be re-typed into adopt.ps1 —
  # a duplicate would let the two entry points drift (the spec's stated risk).
  if ($adoptSrc -match [regex]::Escape("neither 'uv' nor 'pipx' found")) {
    Fail "structural: adopt.ps1 duplicates the uv/pipx warn text instead of reusing the shared lib"
  } else {
    Pass "structural: adopt.ps1 does not duplicate the uv/pipx warn text"
  }

  # ── 9. F2: Test-PreflightJiraDist WARNs + returns $false when $HimmelRoot
  # unset — a caller bug must surface, not silently pass. Dot-source the lib
  # in-process (not via the standalone runner, which always sets $HimmelRoot)
  # with $HimmelRoot left undefined.
  $out9 = & $realPwsh -NoProfile -NonInteractive -Command "`$ErrorActionPreference='Stop'; . '$Lib'; `$r = Test-PreflightJiraDist; Write-Host `"result=`$r`"" 2>&1 | Out-String
  if ($out9 -match "HIMMEL_ROOT not set") { Pass "F2: HIMMEL_ROOT-unset WARN text present" } else { Fail "F2: missing HIMMEL_ROOT-unset WARN text (got: $out9)" }
  if ($out9 -match "result=False") { Pass "F2: Test-PreflightJiraDist returns `$false when `$HimmelRoot unset" } else { Fail "F2: expected result=False (got: $out9)" }

  Write-Host ""
  if ($script:fails -eq 0) { Write-Host "PASS" } else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
} finally {
  Remove-Item -Recurse -Force $RealJiraDist -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $RealJiraNodeModules -ErrorAction SilentlyContinue
  if ($DistBackup) { Move-Item -Path $DistBackup -Destination $RealJiraDist }
  if ($NodeModulesBackup) { Move-Item -Path $NodeModulesBackup -Destination $RealJiraNodeModules }
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
