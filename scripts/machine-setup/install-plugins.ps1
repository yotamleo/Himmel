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

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
# HIMMEL-2353: honor $env:CLAUDE_CONFIG_DIR like the sibling
# reconcile-enabled-plugins.ps1:69 idiom — a hermetic-test seam, not a
# per-call-site flag (a bare $HOME here is what let a test suite reach the
# operator's real settings.json).
$settingsFile = switch ($Scope) {
    'user'    { $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }; Join-Path $cfgDir 'settings.json' }
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
    # HIMMEL-2324: an unpredictable suffix, not the fixed "$settingsFile.autoupdate.tmp"
    # — a fixed name lets anyone with write access to this directory pre-plant
    # a symlink/reparse point there before we get here, so the write below (or
    # the Move-Item) lands through it. GetRandomFileName() keeps the temp in
    # the SAME directory as $settingsFile (Move-Item stays a same-volume
    # rename) and makes the path un-guessable — pre-planting is infeasible —
    # but a name alone is not exclusive-create: it's what closes the hole
    # together with FileMode.CreateNew below (CR round 1, codex-1: WriteAllText
    # creates-or-TRUNCATES and follows a reparse point if one exists at $tmp).
    # CreateNew throws if anything already exists at the path, including a
    # reparse point — the real O_EXCL equivalent.
    $tmp = "$settingsFile.autoupdate." + [System.IO.Path]::GetRandomFileName()
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($settings | ConvertTo-Json -Depth 100))
    # HIMMEL-2324 (CR round 7, codex-8): the create+write+move used to run with
    # no catch at all -- under this script's $ErrorActionPreference = Stop, a
    # Write or Move-Item failure did not just leak $tmp, it ABORTED THE WHOLE
    # INSTALLER, contradicting this site's own tolerant design (a cosmetic
    # patch must not abort under set -e / Stop). Wrap create+write+move in one
    # try/catch: on any failure, remove the orphaned temp and skip/continue
    # like every other failure at this site, instead of leaking or aborting.
    try {
        $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
        Move-Item -Force -LiteralPath $tmp -Destination $settingsFile
    } catch {
        Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
        Write-Host "  skip: $name (write/move failed -- $settingsFile left unchanged)"
        continue
    }
    Write-Host "  autoUpdate=true: $name"
}

# ── Snapshot enabledPlugins BEFORE the install loop (HIMMEL-2733) ───────────
# `claude plugin install <spec> --scope <scope>` WRITES
# enabledPlugins["<spec>"] = $true as a side effect -- verified against the
# real CLI in an empty CLAUDE_CONFIG_DIR (marketplace add + install, then
# enabledPlugins already carries the spec as true). So a live read of
# $settingsFile taken AFTER the install loop below can no longer tell "the
# operator already had this true" apart from "the install loop itself just
# wrote true for every on-demand spec it touched" -- that confusion is what
# let a fresh machine ship the on-demand tier ENABLED (the opposite of this
# ticket; bash twin: install-plugins.sh). Snapshot here, before any install
# runs: the on-demand registration step further down treats a spec as an
# operator override only when it is present AND $true in THIS pre-install
# snapshot, never in the post-install live map. A missing $settingsFile at
# this point (a genuinely fresh machine) yields an empty snapshot -- no
# overrides, not a skip.
$preInstallEnabled = [PSCustomObject]@{}
if (Test-Path $settingsFile) {
    try {
        $preInstallSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json
        if ($preInstallSettings.enabledPlugins) { $preInstallEnabled = $preInstallSettings.enabledPlugins }
    } catch { }
}
function Test-PreInstallOverride([string]$spec) {
    $p = $preInstallEnabled.PSObject.Properties[$spec]
    return ($null -ne $p -and $p.Value -eq $true)
}

# ── Install plugins ─────────────────────────────────────────────────────────
Write-Host "──── Installing plugins ($Scope scope) ────"
# HIMMEL-2733 two-tier profile: the install set is enabledPlugins-true (the
# ALWAYS tier) UNION onDemandPlugins' keys (the ON-DEMAND tier — installed so
# it's reachable in one command, but left DISABLED; see the on-demand step
# below). A `false`-flagged entry ABSENT from onDemandPlugins must still NOT
# be installed, or the lean template silently re-creates the pre-lean maximal
# set on every fresh machine (HIMMEL-816 follow-up gap). Select-Object -Unique
# dedupes the (normally disjoint) union.
$alwaysSpecs = @($cfg.enabledPlugins.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Name })
$onDemandSpecs = @()
if ($cfg.onDemandPlugins) { $onDemandSpecs = @($cfg.onDemandPlugins.PSObject.Properties.Name) }
$specs = @($alwaysSpecs + $onDemandSpecs | Select-Object -Unique)
foreach ($spec in $specs) {
    Write-Host "  install: $spec"
    Invoke-Step @('claude', 'plugin', 'install', $spec, '--scope', $Scope)
}

# ── Verify (post-install presence check, HIMMEL-361) ─────────────────────────
# `claude plugin install` can legitimately exit non-zero on an already-installed
# plugin, so install exit codes can't tell a real failure from an idempotent
# no-op — which is exactly how a failed handover@himmel install used to look
# identical to "already installed". Verify by PRESENCE instead: list the
# installed plugins and confirm every spec in $specs is there -- HIMMEL-2733:
# that's the WHOLE install set (ALWAYS tier + ON-DEMAND tier), so a missing
# on-demand plugin is a real install failure too. Skipped under -DryRun
# (nothing was installed).
if ($DryRun) {
    Write-Host '──── Done (dry-run; verify skipped) ────'
    exit 0
}

# ── Register on-demand plugins as disabled (HIMMEL-2733) ────────────────────
# Normalize BEFORE presence verification: a partial install or failed `plugin
# list` must still undo successful installs' enabledPlugins=$true side effects.
# Otherwise a retry snapshots those installer-written values as deliberate
# overrides and leaves the fresh on-demand tier enabled forever. This step does
# not claim install success; verification below remains authoritative.
#
# An override is present AND $true in the PRE-INSTALL snapshot. Every other
# on-demand key is written $false, while a value already true before this run
# stays true. A resolved local-scope settings.local.json is a real target here;
# keep the malformed-JSON refusal, unpredictable same-directory temp +
# FileMode.CreateNew, BOM-free encoding, atomic move, and cleanup semantics.
#
# NOTE: the bash twin has a HIMMEL-2292 force-enable step and this PowerShell
# installer does not (a pre-existing gap documented by its diagnostics suite).
# This normalization is independent: it only writes false for non-overrides.
$onDemandKeys = @()
if ($cfg.onDemandPlugins) { $onDemandKeys = @($cfg.onDemandPlugins.PSObject.Properties.Name) }
if ($onDemandKeys.Count -gt 0 -and (Test-Path $settingsFile)) {
    try { $liveSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json }
    catch {
        Write-Host "  ERROR: $settingsFile is not valid JSON -- refusing to register on-demand plugins"
        exit 1
    }
    if (-not $liveSettings.enabledPlugins) {
        $liveSettings | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $nonOverrideOnDemand = @($onDemandKeys | Where-Object { -not (Test-PreInstallOverride $_) })
    if ($nonOverrideOnDemand.Count -gt 0) {
        Write-Host '──── Registering on-demand plugins as disabled (installed, not enabled) ────'
        foreach ($spec in $nonOverrideOnDemand) {
            Write-Host "  disable (on-demand): $spec"
            $liveSettings.enabledPlugins | Add-Member -NotePropertyName $spec -NotePropertyValue $false -Force
        }
        $tmp = "$settingsFile.ondemand." + [System.IO.Path]::GetRandomFileName()
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($liveSettings | ConvertTo-Json -Depth 100))
        try {
            $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
            Move-Item -Force -LiteralPath $tmp -Destination $settingsFile
        } catch {
            Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
            Write-Host "  ERROR: on-demand write/move failed -- $settingsFile left unchanged"
            exit 1
        }
    }
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

# ── Reconcile enabledPlugins to the lean floor (HIMMEL-1032) ─────────────────
# Additive install already leaves a FRESH machine lean; the subtractive reconcile
# only matters on a RE-RUN over pre-existing drift, where it would DISABLE plugins
# the user may have enabled. OPT-IN only, identical to himmel-update
# (HIMMEL_RECONCILE_PLUGINS) — never disable a user's plugins on a plain
# re-install. Twin of the bash install-plugins.sh reconcile step.
$reconcile = Join-Path $ScriptDir 'reconcile-enabled-plugins.ps1'
# -cin (case-sensitive), matching the bash twin's `case … in 1|all|true|yes)` —
# plain -in would also accept TRUE/YES, diverging from the shell gate.
if ($env:HIMMEL_RECONCILE_PLUGINS -cin @('1', 'all', 'true', 'yes')) {
    if (Test-Path $reconcile) {
        Write-Host '──── Reconciling enabledPlugins to lean floor (HIMMEL_RECONCILE_PLUGINS) ────'
        # The reconciler calls `exit N` (via Die) on validation failure, which does
        # NOT throw — so a try/catch would miss it. Check $LASTEXITCODE after the call.
        try { & $reconcile -Settings $settingsFile -Template $Template }
        catch { Write-Host "  warn: plugin-set reconcile failed (non-fatal): $_" }
        if ($LASTEXITCODE -ne 0) { Write-Host "  warn: plugin-set reconcile exited $LASTEXITCODE (non-fatal)." }
    } else {
        # Opted in but the reconciler is missing — enforcement would be a silent
        # no-op, and the "set the flag" hint below is wrong (it IS set). Warn.
        Write-Host "  warn: HIMMEL_RECONCILE_PLUGINS is set but reconcile-enabled-plugins.ps1 not found ($reconcile) - lean floor NOT enforced."
    }
} else {
    Write-Host '  (install is additive-only; set HIMMEL_RECONCILE_PLUGINS=1 to also disable drifted plugins down to the lean floor)'
}

# ── Install summary: on-demand tier (HIMMEL-2733) ────────────────────────────
# Discoverability, not enforcement: name what just landed installed-but-
# disabled and how to reach it, plus the doc-only onDemandConnectors tier
# himmel never installs (a per-machine Chrome extension / claude.ai connector
# toggle) -- no installer reads that key to write anything.
if ($onDemandKeys.Count -gt 0) {
    Write-Host '──── On-demand tier (installed, disabled by default) ────'
    foreach ($name in $onDemandKeys) {
        Write-Host "  $name -- $($cfg.onDemandPlugins.$name.neededBy)"
    }
    if ($Scope -ceq 'user') {
        Write-Host '  Enable one:  /profile enable <spec>     (or: claude plugin enable <spec> --scope user)'
    } else {
        Write-Host "  Enable one:  claude plugin enable <spec> --scope $Scope"
    }
}
if ($cfg.onDemandConnectors) {
    $connectorNames = ($cfg.onDemandConnectors.PSObject.Properties.Name -join ', ')
    if ($connectorNames) {
        Write-Host "  Not installed by himmel -- enable in the Chrome extension / claude.ai connectors: $connectorNames"
    }
}

Write-Host '──── Done ────'
