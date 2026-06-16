# uninstall-plugins.ps1 — remove all Claude Code plugins listed in
# docs/setup/settings-template.json. PowerShell counterpart of
# uninstall-plugins.sh; mirror of install-plugins.ps1 (HIMMEL-227 offboard).
#
# Uninstalls each `enabledPlugins` key via `claude plugin uninstall`, then
# removes each `extraKnownMarketplaces` name via
# `claude plugin marketplace remove` (plugins first).
#
# WARNING: plugins are user-scope — removing them affects EVERY repo on
# this machine. Run via scripts/uninstall.ps1 (confirmation-gated) or pass
# -DryRun first.
#
# Each CLI call's exit code is checked: failures are WARNed per call,
# counted, and the script exits 1 if any call failed (so the calling
# uninstall.ps1 can surface it). A not-installed plugin / unregistered
# marketplace also reports non-zero — inspect the per-call WARN lines.
#
# Usage:
#   pwsh uninstall-plugins.ps1 [-DryRun] [-Template PATH]

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Template
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..\..')

if (-not $Template) { $Template = Join-Path $RepoRoot 'docs\setup\settings-template.json' }

if (-not (Test-Path $Template)) { Write-Error "template missing: $Template"; exit 1 }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error 'claude CLI required on PATH'; exit 1
}

function Invoke-OrDry {
    # Runs the command and RETURNS its exit code (0 under -DryRun).
    # NB: a native command's non-zero exit does NOT throw — even under
    # $ErrorActionPreference = 'Stop' — so callers must check the returned
    # rc; a try/catch around this call never fires for CLI failures.
    param([string[]]$Cmd)
    if ($DryRun) {
        Write-Host "DRY: $($Cmd -join ' ')"
        return 0
    }
    & $Cmd[0] @($Cmd | Select-Object -Skip 1) | Out-Host
    return $LASTEXITCODE
}

# No <himmel-path> expansion needed — uninstall consumes only object KEYS.
$cfg = Get-Content $Template -Raw | ConvertFrom-Json
$failures = 0

# ── Uninstall plugins ───────────────────────────────────────────────────────
Write-Host '──── Uninstalling plugins ────'
foreach ($spec in $cfg.enabledPlugins.PSObject.Properties.Name) {
    Write-Host "  uninstall: $spec"
    $rc = Invoke-OrDry @('claude', 'plugin', 'uninstall', $spec)
    if ($rc -ne 0) {
        Write-Host "    WARN: uninstall failed (rc=$rc) -- not installed, or a transient failure" -ForegroundColor Yellow
        $failures++
    }
}

# ── Remove marketplaces ─────────────────────────────────────────────────────
Write-Host '──── Removing marketplaces ────'
foreach ($name in $cfg.extraKnownMarketplaces.PSObject.Properties.Name) {
    Write-Host "  marketplace remove: $name"
    $rc = Invoke-OrDry @('claude', 'plugin', 'marketplace', 'remove', $name)
    if ($rc -ne 0) {
        Write-Host "    WARN: marketplace remove failed (rc=$rc) -- not registered, or a transient failure" -ForegroundColor Yellow
        $failures++
    }
}

Write-Host '──── Done ────'
if ($failures -gt 0) {
    Write-Host "WARN: $failures uninstall/remove call(s) failed -- inspect the lines above." -ForegroundColor Yellow
    exit 1
}
exit 0
