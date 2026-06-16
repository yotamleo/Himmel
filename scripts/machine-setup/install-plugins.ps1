# install-plugins.ps1 — install all Claude Code plugins listed in
# docs/setup/settings-template.json. PowerShell counterpart of
# install-plugins.sh.
#
# Reads `enabledPlugins` and `extraKnownMarketplaces` from the template,
# registers each marketplace via `claude plugin marketplace add`, then
# installs each plugin via `claude plugin install <plugin>@<marketplace>
# --scope <scope>`. Both CLI calls are idempotent.
#
# Usage:
#   pwsh install-plugins.ps1 [-DryRun] [-Scope SCOPE] [-Template PATH] [-HimmelPath PATH]
#
# -Scope is user (default, ~/.claude — every project), project (this repo's
# .claude/settings.json, shared on clone), or local (this repo's gitignored
# .claude/settings.local.json). For project/local the target is the CURRENT
# directory — run from the repo you want the plugins scoped to.

[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('user', 'project', 'local')]
    [string]$Scope = 'user',
    [string]$Template,
    [string]$HimmelPath
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..\..')

if (-not $Template)   { $Template   = Join-Path $RepoRoot 'docs\setup\settings-template.json' }
if (-not $HimmelPath) { $HimmelPath = $RepoRoot.Path }

if (-not (Test-Path $Template)) { Write-Error "template missing: $Template"; exit 1 }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error 'claude CLI required on PATH'; exit 1
}

function Invoke-OrDry {
    param([string[]]$Cmd)
    if ($DryRun) {
        Write-Host "DRY: $($Cmd -join ' ')"
    } else {
        & $Cmd[0] @($Cmd | Select-Object -Skip 1)
    }
}

# ── Expand <himmel-path> in template ─────────────────────────────────────────
$raw      = Get-Content $Template -Raw
$expanded = $raw -replace '<himmel-path>', ($HimmelPath -replace '\\', '\\\\')
$cfg      = $expanded | ConvertFrom-Json

# ── Register marketplaces ───────────────────────────────────────────────────
Write-Host '──── Registering marketplaces ────'
foreach ($name in $cfg.extraKnownMarketplaces.PSObject.Properties.Name) {
    $src = $cfg.extraKnownMarketplaces.$name.source
    $val = switch ($src.source) {
        'github'    { $src.repo }
        'directory' { $src.path }
        'url'       { $src.url  }
        default     { $null }
    }
    if (-not $val) { Write-Host "  skip: $name (unknown source type)"; continue }
    Write-Host "  marketplace add: $val"
    try { Invoke-OrDry @('claude', 'plugin', 'marketplace', 'add', $val, '--scope', $Scope) }
    catch { Write-Host "    (non-zero — already registered or transient failure)" }
}

# ── Install plugins ─────────────────────────────────────────────────────────
Write-Host "──── Installing plugins ($Scope scope) ────"
foreach ($spec in $cfg.enabledPlugins.PSObject.Properties.Name) {
    Write-Host "  install: $spec"
    try { Invoke-OrDry @('claude', 'plugin', 'install', $spec, '--scope', $Scope) }
    catch { Write-Host "    (non-zero — already installed or transient failure)" }
}

Write-Host '──── Done ────'
