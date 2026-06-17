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
$specs = @($cfg.enabledPlugins.PSObject.Properties.Name)
foreach ($spec in $specs) {
    Write-Host "  install: $spec"
    try { Invoke-OrDry @('claude', 'plugin', 'install', $spec, '--scope', $Scope) }
    catch { Write-Host "    (non-zero — already installed or transient failure)" }
}

# ── Verify (post-install presence check, HIMMEL-361) ─────────────────────────
# `claude plugin install` can legitimately exit non-zero on an already-installed
# plugin, so install exit codes can't tell a real failure from an idempotent
# no-op — which is exactly how a failed handover@himmel install used to look
# identical to "already installed". Verify by PRESENCE instead: list the
# installed plugins and confirm every enabledPlugins spec is there. Skipped
# under -DryRun (nothing was installed).
if ($DryRun) {
    Write-Host '──── Done (dry-run; verify skipped) ────'
    exit 0
}

Write-Host '──── Verifying installed plugins ────'
# Fail closed: a verify step that cannot run has confirmed NOTHING, so it must
# not report success (the silent pass HIMMEL-361 kills). 2>&1 captures stderr so
# the failure branch can show WHY. Capture $LASTEXITCODE IMMEDIATELY (before any
# further pipeline can reset it — same idiom as setup.ps1's qmd step).
$listLines = & claude plugin list 2>&1
$listRc = $LASTEXITCODE
if ($listRc -ne 0) {
    Write-Host "ERROR: 'claude plugin list' failed -- cannot verify plugin installs:"
    $listLines | ForEach-Object { Write-Host "    $_" }
    exit 1
}
# Pull the bare <plugin>@<marketplace> tokens out of the list output; membership
# below uses -cnotcontains (case-sensitive) to match the bash twin's grep -F.
# -Width keeps long spec lines from wrapping mid-token.
$listOutput = ($listLines | Out-String -Width 4096)
$installedSpecs = [regex]::Matches($listOutput, '[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+') |
    ForEach-Object { $_.Value }

$missing = @($specs | Where-Object { $installedSpecs -cnotcontains $_ })
if ($missing.Count -gt 0) {
    Write-Host "ERROR: $($missing.Count) plugin(s) not present after install:"
    foreach ($spec in $missing) {
        Write-Host "    $spec -- retry: claude plugin install $spec --scope $Scope"
    }
    exit 1
}

Write-Host "  All $($specs.Count) enabled plugins present."
Write-Host '──── Done ────'
