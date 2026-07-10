# install-plugins.ps1 — install all true-flagged Claude Code plugins listed
# in docs/setup/settings-template.json. PowerShell counterpart of
# install-plugins.sh.
#
# Reads `enabledPlugins` (installing only entries flagged `true` —
# HIMMEL-816) and `extraKnownMarketplaces` from the template,
# registers each marketplace via `claude plugin marketplace add`, sets
# `autoUpdate: true` on every template-flagged marketplace already registered in
# the scope's settings.json (the CLI has no auto-update flag, so this is patched
# straight into that file — HIMMEL-365), then installs each plugin via
# `claude plugin install <plugin>@<marketplace> --scope <scope>`. Both CLI calls
# are idempotent.
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

# Loud, classified diagnostics for a `claude` CLI step (PS twin of run_step in
# install-plugins.sh). Advisory only — never aborts; the end presence-verify is
# authoritative. (A native non-zero exit does NOT throw in PowerShell, so the old
# try/catch almost never fired — this checks $LASTEXITCODE explicitly.) Benign
# "already installed/registered" stays a quiet line; anything else surfaces the
# step + the captured CLI output.
function Invoke-Step {
    param([string[]]$Cmd)
    if ($DryRun) { Write-Host "DRY: $($Cmd -join ' ')"; return }
    $out = (& $Cmd[0] @($Cmd | Select-Object -Skip 1) 2>&1 | Out-String)
    $rc  = $LASTEXITCODE
    if ($rc -eq 0) { return }
    if ($out -match 'already (installed|registered|exists)') {
        Write-Host "    (already present, skipping): $($Cmd -join ' ')"
    } else {
        Write-Host "    !! step FAILED (exit $rc): $($Cmd -join ' ')"
        $out.TrimEnd() -split "`n" | ForEach-Object { Write-Host "       | $($_.TrimEnd())" }
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
    Invoke-Step @('claude', 'plugin', 'marketplace', 'add', $val, '--scope', $Scope)
}

# ── Enable marketplace auto-update (HIMMEL-365) ──────────────────────────────
# `claude plugin marketplace add` writes each settings.json entry WITHOUT
# autoUpdate, so a fresh install leaves auto-update OFF (only a manual /plugin UI
# toggle ever turned it on, and that never propagated to new machines). The CLI
# has no auto-update flag, so set the canonical field
# (extraKnownMarketplaces.<name>.autoUpdate, mirrored into the runtime
# known_marketplaces.json) directly in the scope's settings file, for every
# template entry flagged autoUpdate. Patch only entries already registered there,
# so a marketplace-name vs template-key mismatch can't create an orphan entry.
$settingsFile = switch ($Scope) {
    'user'    { Join-Path $HOME '.claude\settings.json' }
    'project' { Join-Path $PWD.Path '.claude\settings.json' }
    'local'   { Join-Path $PWD.Path '.claude\settings.local.json' }
}
Write-Host "──── Enabling marketplace auto-update ($settingsFile) ────"
$autoNames = @($cfg.extraKnownMarketplaces.PSObject.Properties |
    Where-Object { $_.Value.autoUpdate -eq $true } |
    ForEach-Object { $_.Name })
foreach ($name in $autoNames) {
    if ($DryRun) {
        Write-Host "DRY: set autoUpdate=true for '$name' in $settingsFile"
        continue
    }
    if (-not (Test-Path $settingsFile)) {
        Write-Host "  skip: $name (no $settingsFile)"; continue
    }
    try { $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json }
    catch { Write-Host "  skip: $settingsFile not valid JSON — refusing to patch"; continue }
    $mkts = $settings.extraKnownMarketplaces
    if (-not $mkts -or ($mkts.PSObject.Properties.Name -notcontains $name)) {
        Write-Host "  skip: '$name' not registered in $settingsFile"; continue
    }
    $mkts.$name | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $true -Force
    # Write UTF-8 WITHOUT BOM, to a temp then atomic Move-Item: `Set-Content
    # -Encoding utf8` emits a BOM on Windows PowerShell 5.1 (none on pwsh 7),
    # and a leading BOM makes Node's JSON.parse reject the file — so a manual
    # 5.1 run would corrupt the operator's real settings.json. WriteAllText with
    # UTF8Encoding($false) is BOM-free on both; the temp+move mirrors the bash
    # twin's crash-safety (-Depth 100 covers settings.json's nesting).
    $tmp = "$settingsFile.autoupdate.tmp"
    [System.IO.File]::WriteAllText($tmp, ($settings | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -Force -LiteralPath $tmp -Destination $settingsFile
    Write-Host "  autoUpdate=true: $name"
}

# ── Install plugins ─────────────────────────────────────────────────────────
Write-Host "──── Installing plugins ($Scope scope) ────"
# Only install template entries flagged true — a false-flagged entry (the
# HIMMEL-816 lean profile) must NOT be installed, or the lean template
# silently re-creates the pre-lean maximal set on every fresh machine
# (HIMMEL-816 follow-up gap).
$specs = @($cfg.enabledPlugins.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Name })
foreach ($spec in $specs) {
    Write-Host "  install: $spec"
    Invoke-Step @('claude', 'plugin', 'install', $spec, '--scope', $Scope)
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
