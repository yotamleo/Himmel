<#
.SYNOPSIS
  Provision himmel under the Codex CLI (HIMMEL-597) — the codex-CLI half of the
  install split, twin of scripts/codex/install-himmel-codex.sh.

.DESCRIPTION
  Manages user-global plugin state in ~/.codex/config.toml the SAME way
  scripts/hermes/install-himmel-profile.ps1 provisions the hermes side:
    hermes side : scripts/hermes/install-himmel-profile.{sh,ps1}  (CR/model profile)
    codex side  : scripts/codex/install-himmel-codex.{sh,ps1}     (this file)

  Drives the `codex` CLI (codex plugin marketplace add / codex plugin add) — never
  hand-edits config.toml — so Codex owns all config writes (trust hashes, MCP
  secrets, long-path marketplace sources). NON-DESTRUCTIVE + idempotent: registers
  the himmel marketplace only when absent and enables the himmel plugin set; never
  removes or disables anything; re-runs are no-ops.

  Default plugin set (all @himmel): himmel-ops handover obsidian-triage telegram-himmel.
  -All also enables luna-correlate + pr-review-toolkit-himmel.
  -Plugins <csv> overrides the set. -DryRun reports intended changes, mutates nothing.
  Env overrides: CODEX_BIN (codex CLI path).
#>
# PositionalBinding=$false + a remaining-args catch so a bash-style flag
# (e.g. --dry-run) or a stray bareword is REJECTED rather than silently bound to
# -Plugins — which would otherwise flip a dry-run into a live mutation and a
# garbage `plugin add --dry-run@himmel`. Mirrors the .sh `*) exit 2` arm.
[CmdletBinding(PositionalBinding=$false)]
param(
  [switch]$DryRun,
  [switch]$All,
  [string]$Plugins = "",
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Rest
)

$ErrorActionPreference = "Stop"
if ($Rest -and $Rest.Count -gt 0) {
  Write-Error "unknown argument(s): $($Rest -join ' ') (use -DryRun / -All / -Plugins <csv>)"
  exit 2
}
$Marketplace = "himmel"   # the himmel marketplace name (marketplace/.claude-plugin/marketplace.json)

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$MarketPath = Join-Path $RepoRoot "marketplace"

# --- resolve the codex CLI ---
$Codex = $null
if ($env:CODEX_BIN) {
  if (Test-Path $env:CODEX_BIN) { $Codex = $env:CODEX_BIN }
  else { Write-Error "codex CLI not found (CODEX_BIN set to non-existent path)"; exit 1 }
} elseif (Get-Command codex -ErrorAction SilentlyContinue) {
  $Codex = (Get-Command codex).Source
}
if (-not $Codex) { Write-Error "codex CLI not found (set CODEX_BIN, or install Codex)"; exit 1 }

if (-not (Test-Path $MarketPath)) { Write-Error "himmel marketplace dir not found at $MarketPath"; exit 1 }

# --- resolve the plugin set ---
if ($Plugins) {
  $PluginSet = @($Plugins -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else {
  $PluginSet = @("himmel-ops","handover","obsidian-triage","telegram-himmel")
  if ($All) { $PluginSet += @("luna-correlate","pr-review-toolkit-himmel") }
}

Write-Host "codex CLI   : $Codex"
Write-Host "marketplace : $Marketplace ($MarketPath)"
if ($DryRun) { Write-Host "mode        : DRY-RUN (no changes will be made)" }

$changed = 0

# helper: first whitespace-delimited token of a line (Trim first so a leading-
# whitespace line yields its real first token, matching awk's $1 in the .sh twin)
function First-Token([string]$line) { ($line.Trim() -split "\s+", 2)[0] }

# --- 1. register the himmel marketplace if absent ---
$mkList = (& $Codex plugin marketplace list 2>$null) | Out-String
$mkPresent = $false
foreach ($line in ($mkList -split "`r?`n")) {
  if ((First-Token $line) -eq $Marketplace) { $mkPresent = $true; break }
}
if ($mkPresent) {
  Write-Host "UNCHANGED   : marketplace '$Marketplace' already registered"
} else {
  if ($DryRun) { Write-Host "WOULD ADD   : marketplace '$Marketplace' -> $MarketPath" }
  else {
    & $Codex plugin marketplace add $MarketPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "plugin marketplace add failed (exit $LASTEXITCODE) for $MarketPath" }
    Write-Host "CHANGED     : registered marketplace '$Marketplace' -> $MarketPath"
  }
  $changed++
}

# --- 2. enable each plugin in the set if not already installed+enabled ---
# `codex plugin list` groups rows per-marketplace; each plugin row's first column
# is the FULL selector `name@marketplace` (verified live: `himmel-ops@himmel`),
# status column reads "installed, enabled". Match the exact selector AND enabled.
$plList = (& $Codex plugin list 2>$null) | Out-String
$plLines = $plList -split "`r?`n"
foreach ($p in $PluginSet) {
  $sel = "$p@$Marketplace"
  $enabled = $false
  foreach ($line in $plLines) {
    if (((First-Token $line) -eq $sel) -and ($line -match "installed, enabled")) { $enabled = $true; break }
  }
  if ($enabled) {
    Write-Host "UNCHANGED   : $sel (installed, enabled)"
  } else {
    if ($DryRun) { Write-Host "WOULD ADD   : $sel" }
    else {
      & $Codex plugin add $sel | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "plugin add failed (exit $LASTEXITCODE) for $sel" }
      Write-Host "CHANGED     : enabled $sel"
    }
    $changed++
  }
}

# --- 3. sanitize external-plugin hooks.json (HIMMEL-651) ---
# Codex versions BEFORE rust-v0.143.0 reject a top-level `description` key that
# several external plugins ship in their hooks.json ("unknown field
# description") and skip those hooks at boot. Strip it so codex boots clean.
# Idempotent + non-fatal (cosmetic cleanup must never fail the install).
# DEPRECATED (HIMMEL-1104): upstream fixed this in rust-v0.143.0 (PR #30229), so
# on that version or newer this phase mutates external plugin files for no
# benefit. Removing the phase is tracked in HIMMEL-1114.
Write-Host ""
Write-Host "--- 3. sanitize external-plugin hooks.json (codex strict-parser workaround) ---"
$sanitizer = Join-Path $PSScriptRoot "sanitize-plugin-hooks.ps1"
try {
  if ($DryRun) { & $sanitizer -DryRun } else { & $sanitizer }
  if ($LASTEXITCODE -ne 0) { throw "sanitize step failed (exit $LASTEXITCODE)" }
} catch {
  Write-Warning "sanitize step failed (non-fatal): $($_.Exception.Message)"
}

Write-Host ""
if ($DryRun) {
  Write-Host "DRY-RUN: $changed change(s) would be made. Re-run without -DryRun to apply."
} elseif ($changed -eq 0) {
  Write-Host "OK: himmel already provisioned under Codex (nothing to do)."
} else {
  Write-Host "OK: himmel provisioned under Codex ($changed change(s))."
  Write-Host "    Restart Codex so the newly-enabled plugins load; new project hooks are"
  Write-Host "    trust-hashed on first use (interactive Codex prompts once)."
}
