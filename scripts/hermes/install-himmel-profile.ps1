<#
.SYNOPSIS
  Provision the ADDITIVE `himmel_agent` hermes profile (HIMMEL-557, HIMMEL-744)
  — himmel's main-tier orchestrator (Codex / GPT-5.5) — then wire parity_guard
  into EVERY hermes profile (universal guard).

.DESCRIPTION
  himmel owns only himmel_agent's SOUL/identity; SOUL stays per-role. The guard
  does NOT: it is universal (HIMMEL-744). Non-clobbering — an existing
  luna_vault_guard is swapped, a profile with no guard has parity_guard ADDED
  (other unrelated hooks preserved). Safe to re-run (idempotent).

  -ParityGuard <csv>   By default the universal pass covers the `default`
  profile and all others. -ParityGuard narrows that pass to the named profiles
  only (all is the explicit form of the default).

  Env overrides: HERMES_HOME, HERMES_BIN, HERMES_PY.
#>
[CmdletBinding()]
param([string]$ParityGuard = "")

$ErrorActionPreference = "Stop"
$Profile_ = "himmel_agent"
$AssetDir = Join-Path $PSScriptRoot "assets"
$SoulAsset = Join-Path $AssetDir "himmel-agent.SOUL.md"
$GuardAsset = Join-Path $AssetDir "parity_guard.py"
$Wire = Join-Path $AssetDir "wire_parity_guard.py"
$Sync = Join-Path $AssetDir "sync_model_aliases.py"

foreach ($f in @($SoulAsset, $GuardAsset, $Wire, $Sync)) {
  if (-not (Test-Path $f)) { throw "missing asset: $f" }
}

# --- resolve hermes install root ---
$HomeDir = if ($env:HERMES_HOME) { $env:HERMES_HOME }
           elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "hermes" }
           else { Join-Path $HOME ".local/share/hermes" }
if (-not (Test-Path $HomeDir)) { throw "hermes home not found at $HomeDir — is hermes installed? (set HERMES_HOME)" }

# --- resolve hermes CLI ---
$Hermes = $null
if ($env:HERMES_BIN -and (Test-Path $env:HERMES_BIN)) { $Hermes = $env:HERMES_BIN }
elseif (Get-Command hermes -ErrorAction SilentlyContinue) { $Hermes = (Get-Command hermes).Source }
else {
  foreach ($p in @("$HomeDir/hermes-agent/venv/Scripts/hermes.exe","$HomeDir/hermes-agent/venv/bin/hermes")) {
    if (Test-Path $p) { $Hermes = $p; break }
  }
}
if (-not $Hermes) { throw "hermes CLI not found (set HERMES_BIN)" }

# --- resolve python interpreter (hook command + wiring) ---
$Py = $null
if ($env:HERMES_PY -and (Test-Path $env:HERMES_PY)) { $Py = $env:HERMES_PY }
else {
  foreach ($p in @("$HomeDir/hermes-agent/venv/Scripts/python.exe","$HomeDir/hermes-agent/venv/bin/python")) {
    if (Test-Path $p) { $Py = $p; break }
  }
}
if (-not $Py) {
  $c = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
  if ($c) { $Py = $c.Source }
}
if (-not $Py) { throw "no python interpreter found (set HERMES_PY)" }

$GuardDest = Join-Path $HomeDir "agent-hooks/parity_guard.py"
$HaDir = Join-Path $HomeDir "profiles/$Profile_"
$HaConfig = Join-Path $HaDir "config.yaml"
$HaSoul = Join-Path $HaDir "SOUL.md"

Write-Host "hermes home : $HomeDir"
Write-Host "hermes CLI  : $Hermes"
Write-Host "interpreter : $Py"

# 1. install the guard into agent-hooks (idempotent)
New-Item -ItemType Directory -Force -Path (Join-Path $HomeDir "agent-hooks") | Out-Null
Copy-Item $GuardAsset $GuardDest -Force
Write-Host "installed   : $GuardDest"

# 2. create himmel_agent if missing (clone default for working keys/config)
# probe, not a mutation: a nonzero exit here (e.g. no profiles yet) is
# indistinguishable from "list succeeded but himmel_agent isn't in it" for
# our purposes, so $LASTEXITCODE is intentionally not checked - the
# post-create Test-Path below is the real assertion.
$existing = (& $Hermes profile list 2>$null | Out-String)
if ($existing -match "(^|\W)$Profile_(\W|$)") {
  Write-Host "profile     : $Profile_ exists — refreshing assets (non-destructive)"
} else {
  Write-Host "profile     : creating $Profile_ (clone of default)"
  & $Hermes profile create $Profile_ --clone-from default --description "himmel's main-tier orchestrator (Codex/GPT-5.5): code, repos, PRs, research, vault, writing. parity_guard (secret + catastrophic-shell fences kept). The main puller when Claude is scarce." | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "hermes profile create failed (exit $LASTEXITCODE) creating $Profile_" }
}
if (-not (Test-Path $HaDir)) { throw "$Profile_ profile dir missing after create" }

# 3. install the main-tier SOUL onto himmel_agent (this profile is ours to own)
Copy-Item $SoulAsset $HaSoul -Force
Write-Host "installed   : $HaSoul"

# 4. sync the root config's model_aliases block onto himmel_agent (HIMMEL-737):
#    the one-shot dispatch path loads the PROFILE config, not the root config,
#    so a profile cloned before the aliases existed never picks them up on
#    its own - keep it synced on every create/refresh.
& $Py $Sync (Join-Path $HomeDir "config.yaml") $HaConfig
# $ErrorActionPreference=Stop does NOT trap native exit codes - check
# explicitly so a failed sync cannot end in "OK: provisioned" (CR finding).
if ($LASTEXITCODE -ne 0) { throw "sync_model_aliases.py failed (exit $LASTEXITCODE) syncing model_aliases into $HaConfig" }

# 5. wire himmel_agent's pre_tool_call hook -> parity_guard (full set)
& $Py $Wire set $HaConfig $GuardDest $Py
if ($LASTEXITCODE -ne 0) { throw "wire_parity_guard.py set failed (exit $LASTEXITCODE) wiring $HaConfig" }

# 6. universal guard (HIMMEL-744): ensure parity_guard on EVERY other profile.
#    Default (no flag) = the `default` profile + all others. -ParityGuard <csv>
#    narrows to named profiles; all is the explicit form of the default. ensure
#    is non-clobbering: swaps a luna_vault_guard, adds the guard where none
#    exists, no-ops if already on parity_guard.
$targets = @()
if ((-not $ParityGuard) -or ($ParityGuard -eq "all")) {
  $targets += (Join-Path $HomeDir "config.yaml")   # default
  $pdir = Join-Path $HomeDir "profiles"
  if (Test-Path $pdir) {
    foreach ($d in Get-ChildItem $pdir -Directory) {
      if ($d.Name -eq $Profile_) { continue }
      $c = Join-Path $d.FullName "config.yaml"
      if (Test-Path $c) { $targets += $c }
    }
  }
} else {
  foreach ($name in ($ParityGuard -split ",")) {
    $name = $name.Trim()
    if (-not $name) { continue }
    if ($name -eq "default") { $targets += (Join-Path $HomeDir "config.yaml") }
    else { $targets += (Join-Path $HomeDir "profiles/$name/config.yaml") }
  }
}
foreach ($cfg in $targets) {
  if (Test-Path $cfg) {
    & $Py $Wire ensure $cfg $GuardDest $Py
    if ($LASTEXITCODE -ne 0) { throw "wire_parity_guard.py ensure failed (exit $LASTEXITCODE) wiring $cfg" }
  }
  else { Write-Warning "config not found: $cfg" }
}

Write-Host "OK: himmel_agent provisioned. Reach it with:  hermes profile use $Profile_"
Write-Host "    Restart the gateway and approve the hook once: hermes gateway restart"
