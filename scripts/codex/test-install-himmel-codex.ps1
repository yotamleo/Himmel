<#
  Hermetic tests for install-himmel-codex.ps1 (HIMMEL-597) — Windows twin of
  test-install-himmel-codex.sh. A stub `codex` CLI (codex-stub.ps1) simulates
  `plugin marketplace list/add` + `plugin list/add`, driven by test-controlled
  state files, logging every mutating call. The installer runs in a child pwsh
  so a scenario's `exit 1` cannot terminate this harness.
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Installer = Join-Path $ScriptDir "install-himmel-codex.ps1"

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }
function Assert-LogHas($log,$needle,$msg)   { if ((Test-Path $log) -and (Select-String -SimpleMatch -Quiet -Pattern $needle -Path $log)) { Pass $msg } else { Fail "$msg (missing '$needle')" } }
function Assert-LogLacks($log,$needle,$msg) { if ((Test-Path $log) -and (Select-String -SimpleMatch -Quiet -Pattern $needle -Path $log)) { Fail "$msg (unexpected '$needle')" } else { Pass $msg } }
function Assert-Count($log,$needle,$want,$msg) {
  $n = 0
  if (Test-Path $log) { $n = (Select-String -SimpleMatch -Pattern $needle -Path $log | Measure-Object).Count }
  if ($n -eq $want) { Pass $msg } else { Fail "$msg (count '$needle' = $n, want $want)" }
}

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("himmel-codex-test-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
try {
  # --- stub codex CLI ---
  $Stub = Join-Path $TMP "codex-stub.ps1"
  Set-Content -Path $Stub -Encoding UTF8 -Value @'
$S = $env:CODEX_STUB_STATE
$a = $args
function Log($m) { Add-Content -Path (Join-Path $S "calls.log") -Value $m }
if ($a[0] -eq "plugin" -and $a[1] -eq "marketplace" -and $a[2] -eq "list") {
  "MARKETPLACE                  ROOT"
  $mf = Join-Path $S "marketplaces.txt"
  if (Test-Path $mf) { Get-Content $mf | ForEach-Object { if ($_) { "{0}  /fake/{1}" -f $_, $_ } } }
  exit 0
}
if ($a[0] -eq "plugin" -and $a[1] -eq "marketplace" -and $a[2] -eq "add") { Log "marketplace add $($a[3])"; exit 0 }
if ($a[0] -eq "plugin" -and $a[1] -eq "list") {
  "PLUGIN                                   STATUS              VERSION  PATH"
  $pf = Join-Path $S "plugins.txt"
  if (Test-Path $pf) { Get-Content $pf | ForEach-Object { if ($_) { $p = $_ -split "`t"; "{0}  {1}  local  /fake/{2}" -f $p[0], $p[1], $p[0] } } }
  exit 0
}
if ($a[0] -eq "plugin" -and $a[1] -eq "add")    { Log "plugin add $($a[2])"; exit 0 }
if ($a[0] -eq "plugin" -and $a[1] -eq "remove") { Log "plugin remove $($a[2])"; exit 0 }
exit 0
'@

  function New-State($name) {
    $s = Join-Path $TMP $name
    if (Test-Path $s) { Remove-Item $s -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $s | Out-Null
    Set-Content -Path (Join-Path $s "marketplaces.txt") -Value "" -NoNewline
    Set-Content -Path (Join-Path $s "plugins.txt") -Value "" -NoNewline
    Set-Content -Path (Join-Path $s "calls.log") -Value "" -NoNewline
    return $s
  }

  # run installer in a CHILD pwsh; returns @{ Out=<string>; Code=<int> }
  function Invoke-Installer($state, [string[]]$iargs, [string]$codexBin) {
    if (-not $codexBin) { $codexBin = $Stub }
    $env:CODEX_BIN = $codexBin
    $env:CODEX_STUB_STATE = $state
    # CODEX_HOME -> an empty temp dir so the wired sanitize-plugin-hooks step
    # (HIMMEL-651) finds no plugin cache and no-ops, keeping the test hermetic
    # (never touches the real ~/.codex cache).
    $env:CODEX_HOME = Join-Path $TMP "codex-home"
    try {
      $out = & pwsh -NoProfile -File $Installer @iargs 2>&1 | Out-String
      $code = $LASTEXITCODE
    } finally {
      Remove-Item Env:CODEX_BIN -ErrorAction SilentlyContinue
      Remove-Item Env:CODEX_STUB_STATE -ErrorAction SilentlyContinue
      Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    }
    return @{ Out = $out; Code = $code }
  }

  $DefaultSet = @("himmel-ops","handover","obsidian-triage","telegram-himmel")

  Write-Host "== scenario A: fresh machine (no himmel marketplace, no plugins) =="
  $S = New-State "A"
  Set-Content (Join-Path $S "marketplaces.txt") "openai-bundled"
  Set-Content (Join-Path $S "plugins.txt") "browser@openai-bundled`tinstalled, enabled"
  Invoke-Installer $S @() | Out-Null
  $log = Join-Path $S "calls.log"
  Assert-LogHas  $log "marketplace add" "registers himmel marketplace when absent"
  Assert-Count   $log "plugin add" 4 "adds all 4 default plugins"
  foreach ($p in $DefaultSet) { Assert-LogHas $log "plugin add $p@himmel" "adds $p" }

  Write-Host "== scenario B: idempotent (marketplace present, all installed+enabled) =="
  $S = New-State "B"
  Set-Content (Join-Path $S "marketplaces.txt") "openai-bundled`r`nhimmel"
  ($DefaultSet | ForEach-Object { "$_@himmel`tinstalled, enabled" }) -join "`r`n" | Set-Content (Join-Path $S "plugins.txt")
  Invoke-Installer $S @() | Out-Null
  $log = Join-Path $S "calls.log"
  Assert-LogLacks $log "marketplace add" "no re-register when himmel marketplace present"
  Assert-LogLacks $log "plugin add" "no re-add when all targets enabled (idempotent)"

  Write-Host "== scenario C: one target not installed (others enabled) =="
  $S = New-State "C"
  Set-Content (Join-Path $S "marketplaces.txt") "himmel"
  @("himmel-ops@himmel`tnot installed",
    "handover@himmel`tinstalled, enabled",
    "obsidian-triage@himmel`tinstalled, enabled",
    "telegram-himmel@himmel`tinstalled, enabled") -join "`r`n" | Set-Content (Join-Path $S "plugins.txt")
  Invoke-Installer $S @() | Out-Null
  $log = Join-Path $S "calls.log"
  Assert-Count   $log "plugin add" 1 "adds exactly the one missing plugin"
  Assert-LogHas  $log "plugin add himmel-ops@himmel" "adds the not-installed himmel-ops"
  Assert-LogLacks $log "plugin add handover@himmel" "leaves already-enabled handover untouched"

  Write-Host "== scenario D: -DryRun reports but does not mutate =="
  $S = New-State "D"
  Set-Content (Join-Path $S "marketplaces.txt") "openai-bundled"
  $r = Invoke-Installer $S @("-DryRun")
  $log = Join-Path $S "calls.log"
  Assert-LogLacks $log "marketplace add" "-DryRun issues no marketplace add"
  Assert-LogLacks $log "plugin add" "-DryRun issues no plugin add"
  if ($r.Out -match "(?i)would|dry") { Pass "-DryRun reports intended changes" } else { Fail "-DryRun gave no change report" }

  Write-Host "== scenario E: codex CLI missing -> exit 1, no calls =="
  $S = New-State "E"
  $r = Invoke-Installer $S @() (Join-Path $TMP "nope-not-a-codex")
  if ($r.Code -eq 1) { Pass "missing codex CLI exits 1" } else { Fail "missing codex CLI exit=$($r.Code) (want 1)" }
  Assert-LogLacks (Join-Path $S "calls.log") "add" "no calls when codex CLI missing"

  Write-Host "== scenario F: non-destructive (never removes/disables) =="
  $S = New-State "F"
  Set-Content (Join-Path $S "marketplaces.txt") "himmel"
  Set-Content (Join-Path $S "plugins.txt") "himmel-ops@himmel`tnot installed"
  Invoke-Installer $S @() | Out-Null
  $log = Join-Path $S "calls.log"
  Assert-LogLacks $log "remove" "never calls plugin/marketplace remove"
  Assert-LogLacks $log "--disable" "never disables a plugin"

  Write-Host "== scenario G: -Plugins override =="
  $S = New-State "G"
  Set-Content (Join-Path $S "marketplaces.txt") "himmel"
  $r = Invoke-Installer $S @("-Plugins","himmel-ops")
  $log = Join-Path $S "calls.log"
  Assert-Count   $log "plugin add" 1 "-Plugins restricts the set to one"
  Assert-LogHas  $log "plugin add himmel-ops@himmel" "-Plugins adds the named plugin"

  Write-Host "== scenario H: bash-style / unknown arg -> rejected, no mutation =="
  $S = New-State "H"
  Set-Content (Join-Path $S "marketplaces.txt") "himmel"
  # a bash-style --dry-run must NOT silently bind to -Plugins and mutate
  $r = Invoke-Installer $S @("--dry-run")
  if ($r.Code -ne 0) { Pass "bash-style --dry-run rejected (exit non-zero)" } else { Fail "--dry-run should be rejected by the .ps1, not bound to -Plugins" }
  Assert-LogLacks (Join-Path $S "calls.log") "add" "no mutation on rejected arg"
  # a stray bareword is likewise rejected
  $S2 = New-State "H2"; Set-Content (Join-Path $S2 "marketplaces.txt") "himmel"
  $r2 = Invoke-Installer $S2 @("himmel-ops")
  if ($r2.Code -ne 0) { Pass "stray bareword rejected (exit non-zero)" } else { Fail "stray bareword should be rejected" }

  Write-Host "== scenario I: @marketplace discrimination (same plugin name, different marketplace) =="
  $S = New-State "I"
  Set-Content (Join-Path $S "marketplaces.txt") "himmel`r`nopenai-bundled"
  Set-Content (Join-Path $S "plugins.txt") "himmel-ops@openai-bundled`tinstalled, enabled"
  Invoke-Installer $S @("-Plugins","himmel-ops") | Out-Null
  Assert-LogHas (Join-Path $S "calls.log") "plugin add himmel-ops@himmel" "still adds himmel-ops@himmel despite same name in another marketplace"

  Write-Host "== scenario J: marketplace name exact-match (near-miss must not satisfy) =="
  $S = New-State "J"
  Set-Content (Join-Path $S "marketplaces.txt") "himmel-extra"
  Invoke-Installer $S @("-Plugins","himmel-ops") | Out-Null
  Assert-LogHas (Join-Path $S "calls.log") "marketplace add" "registers 'himmel' when only 'himmel-extra' present (no substring false-match)"

  Write-Host ""
  if ($script:fails -eq 0) { Write-Host "ALL PASS" } else { Write-Host "$($script:fails) FAILED" -ForegroundColor Red; exit 1 }
}
finally {
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
