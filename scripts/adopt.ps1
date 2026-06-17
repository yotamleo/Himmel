# adopt.ps1 — one-click installer: bring the himmel harness and/or the luna
# vault scaffold into your own repo (project scope) or user scope.
# PowerShell counterpart of adopt.sh — keep both in lockstep.
#
# Usage:
#   pwsh adopt.ps1 -Profile <core|luna|all> -Scope <project|user> `
#                  [-Target PATH] [-LunaTarget PATH] [-DryRun]
#
# Profiles (logical blocks):
#   core  Portable hooks + guardrails lib + worktree commands + the marketplace
#         plugins/skills + a requirements check. (NOT jira/qmd/telegram/handover.)
#   luna  The luna second-brain vault scaffold (templates/luna-second-brain).
#   all   core + luna.
#
# Scope (applies to `core`):
#   project  Copy portable scripts into <Target>, wire the PreToolUse hooks into
#            <Target>/.claude/settings.json, install plugins -Scope project.
#   user     Install plugins -Scope user and wire ~/.claude/settings.json hooks
#            to reference THIS himmel clone (scripts not copied per-repo).
#
# Flags:
#   -Target PATH      Where core lands (project scope) / vault dir for
#                     -Profile luna. Default: current directory.
#   -LunaTarget PATH  Vault dir when -Profile all. Default: ~/Documents/luna.
#   -DryRun           Print actions instead of doing them.
#
# Idempotent: re-running adds nothing already present.

[CmdletBinding()]
param(
    [ValidateSet('core', 'luna', 'all')]
    [string]$Profile = 'core',
    [ValidateSet('project', 'user')]
    [string]$Scope = 'project',
    [string]$Target,
    [string]$LunaTarget,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$HimmelRoot  = (Resolve-Path (Join-Path $ScriptDir '..')).Path
if (-not $Target)     { $Target     = (Get-Location).Path }
if (-not $LunaTarget) { $LunaTarget = Join-Path $HOME 'Documents\luna' }

$PortableFiles = @(
    'scripts/hooks/auto-approve-safe-bash.sh',
    'scripts/hooks/block-edit-on-main.sh',
    'scripts/hooks/block-read-secrets.sh',
    'scripts/guardrails/lib.sh',
    'scripts/guardrails/guard-gh.sh',
    'scripts/lib/py-armor.sh',
    'scripts/clean-garden.sh',
    'scripts/worktree.sh',
    'scripts/clean.sh',
    'scripts/_new-worktree.sh'
)

function Require-Tools {
    $missing = @()
    foreach ($t in @('git', 'jq', 'python3', 'claude')) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
    }
    if ($missing.Count -gt 0) {
        Write-Error "missing required tools: $($missing -join ', ') (see $HimmelRoot\docs\setup\new-machine.md)"
    }
}

function Copy-Portable {
    Write-Host "──── Copying portable core into $Target ────"
    foreach ($f in $PortableFiles) {
        $src = Join-Path $HimmelRoot $f
        $dst = Join-Path $Target $f
        if ($DryRun) { Write-Host "DRY: copy $f"; continue }
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item -Force $src $dst
        Write-Host "  $f"
    }
}

# Merge the three PreToolUse hook stanzas into a settings.json, idempotently.
function Wire-Settings([string]$SettingsPath, [string]$Prefix) {
    $desired = @(
        [pscustomobject]@{ matcher = 'Bash'; hooks = @([pscustomobject]@{ type = 'command'; command = "bash $Prefix/scripts/hooks/auto-approve-safe-bash.sh" }) },
        [pscustomobject]@{ matcher = 'Edit|Write|MultiEdit|NotebookEdit'; hooks = @([pscustomobject]@{ type = 'command'; command = "bash $Prefix/scripts/hooks/block-edit-on-main.sh" }) },
        [pscustomobject]@{ matcher = 'Bash|PowerShell|Read|Grep'; hooks = @([pscustomobject]@{ type = 'command'; command = "bash $Prefix/scripts/hooks/block-read-secrets.sh" }) }
    )
    if ($DryRun) { Write-Host "DRY: merge 3 PreToolUse hook stanzas into $SettingsPath (prefix: $Prefix)"; return }
    New-Item -ItemType Directory -Force (Split-Path $SettingsPath) | Out-Null

    if (Test-Path $SettingsPath) {
        $cfg = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    } else {
        $cfg = [pscustomobject]@{}
    }
    if (-not $cfg.PSObject.Properties['hooks']) {
        $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $cfg.hooks.PSObject.Properties['PreToolUse']) {
        $cfg.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @()
    }
    $existing = @($cfg.hooks.PreToolUse)
    $existingCmds = @($existing | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
    $toAdd = @()
    foreach ($d in $desired) {
        if ($existingCmds -notcontains $d.hooks[0].command) { $toAdd += $d }
    }
    $cfg.hooks.PreToolUse = @($existing + $toAdd)
    $cfg | ConvertTo-Json -Depth 12 | Set-Content $SettingsPath -Encoding utf8
    Write-Host "  wired PreToolUse hooks → $SettingsPath"
}

function Install-Plugins {
    Write-Host "──── Installing plugins (-Scope $Scope) ────"
    $pluginArgs = @('-Scope', $Scope)
    if ($DryRun) { $pluginArgs += '-DryRun' }
    $ip = Join-Path $HimmelRoot 'scripts\machine-setup\install-plugins.ps1'
    if ($Scope -eq 'project') {
        # project scope writes to the CWD's .claude/settings.json — run from
        # $Target so plugins land in the adopted repo, not the himmel clone.
        Push-Location $Target
        try { & pwsh -NoProfile -File $ip @pluginArgs } finally { Pop-Location }
    } else {
        & pwsh -NoProfile -File $ip @pluginArgs
    }
}

# statusLine — part of the core harness (HIMMEL-359). Wired into the
# scope-appropriate settings.json via the shared helper. Both scopes reference
# THIS himmel clone's vendored statusline (never copied per-repo).
function Wire-StatuslineCore {
    $settings = if ($Scope -eq 'project') {
        Join-Path $Target '.claude\settings.json'
    } else {
        Join-Path $HOME '.claude\settings.json'
    }
    if ($DryRun) {
        Write-Host "DRY: wire statusLine → $settings (himmel: $HimmelRoot)"
        return
    }
    $wsl = Join-Path $HimmelRoot 'scripts\lib\wire-statusline.ps1'
    & pwsh -NoProfile -File $wsl -SettingsPath $settings -HimmelPath $HimmelRoot
    # Parity with adopt.sh (set -e aborts on a non-zero helper): surface failure.
    if ($LASTEXITCODE -ne 0) { throw "wire-statusline failed (exit $LASTEXITCODE)" }
}

function Do-Core {
    Require-Tools
    if ($Scope -eq 'project') {
        Copy-Portable
        Wire-Settings (Join-Path $Target '.claude\settings.json') '$CLAUDE_PROJECT_DIR'
        Write-Host "  worktree commands: bash $Target/scripts/worktree.sh feat/slug"
    } else {
        Wire-Settings (Join-Path $HOME '.claude\settings.json') $HimmelRoot
        Write-Host "  worktree commands run from the himmel clone: bash $HimmelRoot/scripts/worktree.sh feat/slug"
    }
    Install-Plugins
    Wire-StatuslineCore
    Write-Host "  (optional) pre-commit gates: see $HimmelRoot\docs\setup\use-on-your-project.md"
}

function Do-Luna([string]$Dest) {
    Write-Host "──── Scaffolding luna vault → $Dest ────"
    if ((Test-Path $Dest) -and -not $DryRun) {
        Write-Host "  $Dest already exists — skipping copy (re-run the vault's own setup to update)"
    } elseif (-not $DryRun) {
        Copy-Item -Recurse -Force (Join-Path $HimmelRoot 'templates\luna-second-brain') $Dest
    } else {
        Write-Host "DRY: copy templates\luna-second-brain → $Dest"
    }
    Write-Host "  next: cd `"$Dest`"; bash scripts/setup.sh   (idempotent; prints the plugin-install commands)"
}

$dryNote = if ($DryRun) { ' (dry-run)' } else { '' }
Write-Host "==> himmel adopt — profile=$Profile scope=$Scope$dryNote"
switch ($Profile) {
    'core' { Do-Core }
    'luna' { Do-Luna $Target }
    'all'  { Do-Core; Do-Luna $LunaTarget }
}
Write-Host "──── Done ────"
