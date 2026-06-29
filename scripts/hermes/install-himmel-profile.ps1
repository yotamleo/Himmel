<#
.SYNOPSIS
  Provision the ADDITIVE `himmel_agent` hermes profile (HIMMEL-557) — himmel's
  main-tier orchestrator (Codex / GPT-5.5) with the parity_guard.

.DESCRIPTION
  NON-DESTRUCTIVE: never overwrites your `default` or any other existing
  profile's SOUL.md or hooks. himmel does not own your hermes identity — it
  only adds this one named profile. Safe to re-run (idempotent).

  -ParityGuard all | <csv>   ALSO points the named (or all other) profiles at
  parity_guard, but only by swapping an existing luna_vault_guard hook; a
  profile with no such hook is left untouched (never clobbered).

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

foreach ($f in @($SoulAsset, $GuardAsset, $Wire)) {
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
$existing = (& $Hermes profile list 2>$null | Out-String)
if ($existing -match "(^|\W)$Profile_(\W|$)") {
  Write-Host "profile     : $Profile_ exists — refreshing assets (non-destructive)"
} else {
  Write-Host "profile     : creating $Profile_ (clone of default)"
  & $Hermes profile create $Profile_ --clone-from default --description "himmel's main-tier orchestrator (Codex/GPT-5.5): code, repos, PRs, research, vault, writing. parity_guard (secret + catastrophic-shell fences kept). The main puller when Claude is scarce." | Out-Null
}
if (-not (Test-Path $HaDir)) { throw "$Profile_ profile dir missing after create" }

# 3. install the main-tier SOUL onto himmel_agent (this profile is ours to own)
Copy-Item $SoulAsset $HaSoul -Force
Write-Host "installed   : $HaSoul"

# 4. wire himmel_agent's pre_tool_call hook -> parity_guard (full set)
& $Py $Wire set $HaConfig $GuardDest $Py

# 5. optional: apply parity_guard to other profiles (swap-only, non-destructive)
if ($ParityGuard) {
  $targets = @()
  if ($ParityGuard -eq "all") {
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
    if (Test-Path $cfg) { & $Py $Wire swap $cfg }
    else { Write-Warning "config not found: $cfg" }
  }
}

Write-Host "OK: himmel_agent provisioned. Reach it with:  hermes profile use $Profile_"
Write-Host "    Restart the gateway and approve the hook once: hermes gateway restart"
