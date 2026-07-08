<#
  Hermetic tests for install-himmel-profile.ps1 (HIMMEL-782) — asserts the
  Windows twin traps NATIVE exit codes at mutation sites the same way the
  .sh twin's `set -euo pipefail` does ($ErrorActionPreference="Stop" alone
  does not catch a failed native call). Stub `hermes`/python binaries (ps1
  scripts driven by env flags) simulate a failure at each mutation site;
  the installer runs in a CHILD pwsh so a scenario's throw/exit cannot
  terminate this harness. Covers the `profile list` PROBE too: its exit
  code is intentionally not checked (see the installer's own comment), so
  a failing probe must still let the run finish successfully.
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Installer = Join-Path $ScriptDir "install-himmel-profile.ps1"

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-profile-test-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
try {
  # --- stub hermes CLI: profile list / profile create, failure gated by env flags ---
  $HermesStub = Join-Path $TMP "hermes-stub.ps1"
  Set-Content -Path $HermesStub -Encoding UTF8 -Value @'
$H = $env:HERMES_HOME
$a = $args
if ($a[0] -eq "profile" -and $a[1] -eq "list") {
  if ($env:HERMES_STUB_FAIL_LIST -eq "1") { exit 7 }
  "default"
  $pdir = Join-Path $H "profiles"
  if (Test-Path $pdir) { Get-ChildItem $pdir -Directory | ForEach-Object { $_.Name } }
  exit 0
}
if ($a[0] -eq "profile" -and $a[1] -eq "create") {
  if ($env:HERMES_STUB_FAIL_CREATE -eq "1") { exit 3 }
  $name = $a[2]
  New-Item -ItemType Directory -Force -Path (Join-Path $H "profiles/$name") | Out-Null
  Copy-Item (Join-Path $H "config.yaml") (Join-Path $H "profiles/$name/config.yaml") -Force
  exit 0
}
exit 0
'@

  # --- stub python interpreter: dispatches on the script filename it's asked
  #     to run (sync_model_aliases.py / wire_parity_guard.py), failure gated
  #     by env flags (set vs ensure distinguished by subcommand arg) ---
  $PyStub = Join-Path $TMP "py-stub.ps1"
  Set-Content -Path $PyStub -Encoding UTF8 -Value @'
$a = $args
$name = Split-Path $a[0] -Leaf
switch ($name) {
  "sync_model_aliases.py" {
    if ($env:HERMES_STUB_FAIL_SYNC -eq "1") { exit 5 }
    exit 0
  }
  "wire_parity_guard.py" {
    $sub = $a[1]
    if ($sub -eq "set" -and $env:HERMES_STUB_FAIL_WIRE_SET -eq "1") { exit 6 }
    if ($sub -eq "ensure" -and $env:HERMES_STUB_FAIL_WIRE_ENSURE -eq "1") { exit 9 }
    exit 0
  }
  default { exit 0 }
}
'@

  function New-Home([switch]$SeedProfile) {
    $h = Join-Path $TMP ("home-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
    New-Item -ItemType Directory -Force -Path (Join-Path $h "agent-hooks") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $h "profiles") | Out-Null
    Set-Content -Path (Join-Path $h "config.yaml") -Value "model:`n  default: gpt-5.5`nhooks: {}`n"
    Set-Content -Path (Join-Path $h "SOUL.md") -Value "# root soul`n"
    if ($SeedProfile) {
      # pre-seed himmel_agent so the create step is skipped (refresh path) -
      # isolates the sync/set/ensure mutation sites from the create site.
      New-Item -ItemType Directory -Force -Path (Join-Path $h "profiles/himmel_agent") | Out-Null
      Set-Content -Path (Join-Path $h "profiles/himmel_agent/config.yaml") -Value "model:`n  default: gpt-5.5`nhooks: {}`n"
    }
    return $h
  }

  # runs the installer in a CHILD pwsh; returns @{ Out=<string>; Code=<int> }
  function Invoke-Installer([string]$homeDir, [hashtable]$flags = @{}) {
    $env:HERMES_HOME = $homeDir
    $env:HERMES_BIN = $HermesStub
    $env:HERMES_PY = $PyStub
    foreach ($k in $flags.Keys) { Set-Item -Path "Env:$k" -Value $flags[$k] }
    try {
      $out = & pwsh -NoProfile -File $Installer 2>&1 | Out-String
      $code = $LASTEXITCODE
    } finally {
      Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
      Remove-Item Env:HERMES_BIN -ErrorAction SilentlyContinue
      Remove-Item Env:HERMES_PY -ErrorAction SilentlyContinue
      foreach ($k in $flags.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    }
    return @{ Out = $out; Code = $code }
  }

  Write-Host "== scenario A: happy path (no stub failures) -> exit 0 =="
  $h = New-Home
  $r = Invoke-Installer $h
  if ($r.Code -eq 0) { Pass "clean run exits 0" } else { Fail "clean run exit=$($r.Code) (want 0): $($r.Out)" }

  Write-Host "== scenario B: profile-list PROBE fails -> run still succeeds (not a mutation) =="
  $h = New-Home
  $r = Invoke-Installer $h @{ HERMES_STUB_FAIL_LIST = "1" }
  if ($r.Code -eq 0) { Pass "failing probe does not fail the run" } else { Fail "probe failure should not be fatal, got exit=$($r.Code): $($r.Out)" }

  Write-Host "== scenario C: profile create fails (mutation) -> throws, names the step + exit code =="
  $h = New-Home
  $r = Invoke-Installer $h @{ HERMES_STUB_FAIL_CREATE = "1" }
  if ($r.Code -ne 0) { Pass "failed create exits non-zero" } else { Fail "failed create should exit non-zero" }
  if ($r.Out -match "profile create failed" -and $r.Out -match "exit 3") { Pass "error names profile-create step + exit code" } else { Fail "error message missing step/exit-code detail (got: $($r.Out))" }

  Write-Host "== scenario D: sync_model_aliases.py fails (mutation) -> throws, names the step + exit code =="
  $h = New-Home -SeedProfile
  $r = Invoke-Installer $h @{ HERMES_STUB_FAIL_SYNC = "1" }
  if ($r.Code -ne 0) { Pass "failed sync exits non-zero" } else { Fail "failed sync should exit non-zero" }
  if ($r.Out -match "sync_model_aliases.py failed" -and $r.Out -match "exit 5") { Pass "error names sync step + exit code" } else { Fail "error message missing step/exit-code detail (got: $($r.Out))" }

  Write-Host "== scenario E: wire_parity_guard.py set fails (mutation) -> throws, names the step + exit code =="
  $h = New-Home -SeedProfile
  $r = Invoke-Installer $h @{ HERMES_STUB_FAIL_WIRE_SET = "1" }
  if ($r.Code -ne 0) { Pass "failed wire-set exits non-zero" } else { Fail "failed wire-set should exit non-zero" }
  if ($r.Out -match "wire_parity_guard.py set failed" -and $r.Out -match "exit 6") { Pass "error names wire-set step + exit code" } else { Fail "error message missing step/exit-code detail (got: $($r.Out))" }

  Write-Host "== scenario F: wire_parity_guard.py ensure fails (universal-guard mutation) -> throws, names the step + exit code =="
  $h = New-Home -SeedProfile
  $r = Invoke-Installer $h @{ HERMES_STUB_FAIL_WIRE_ENSURE = "1" }
  if ($r.Code -ne 0) { Pass "failed wire-ensure exits non-zero" } else { Fail "failed wire-ensure should exit non-zero" }
  if ($r.Out -match "wire_parity_guard.py ensure failed" -and $r.Out -match "exit 9") { Pass "error names wire-ensure step + exit code" } else { Fail "error message missing step/exit-code detail (got: $($r.Out))" }

  Write-Host ""
  if ($script:fails -eq 0) { Write-Host "ALL PASS" } else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
}
finally {
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
