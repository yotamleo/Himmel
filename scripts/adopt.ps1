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
#   -FillEnv          Interactively fill the himmel clone's .env (creates it from
#                     .env.example if absent). Needs Git Bash. Enter to skip a var.
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
    [switch]$DryRun,
    [switch]$FillEnv
)

$ErrorActionPreference = 'Stop'

# Capture whether -LunaTarget was passed explicitly BEFORE the default fills it,
# so `-Profile luna -LunaTarget` can honor it (HIMMEL-458 critic #3).
$LunaTargetSet = $PSBoundParameters.ContainsKey('LunaTarget')

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
# The hook path is FORWARD-SLASHED and QUOTED: an unquoted Windows backslash path
# (`bash C:\Users\...\X.sh`) collapses when the hook command is parsed by a shell
# (`\U`->`U`), so the hook silently never fires. Dedup is by hook
# BASENAME with REPLACE semantics — a re-run repairs a bad install, never dups.
function Wire-Settings([string]$SettingsPath, [string]$Prefix) {
    $pfx = $Prefix.Replace('\', '/')   # forward-slash any backslashes in the prefix
    $desired = @(
        [pscustomobject]@{ matcher = 'Bash'; hooks = @([pscustomobject]@{ type = 'command'; command = "bash `"$pfx/scripts/hooks/auto-approve-safe-bash.sh`"" }) },
        [pscustomobject]@{ matcher = 'Edit|Write|MultiEdit|NotebookEdit'; hooks = @([pscustomobject]@{ type = 'command'; command = "bash `"$pfx/scripts/hooks/block-edit-on-main.sh`"" }) },
        [pscustomobject]@{ matcher = 'Bash|PowerShell|Read|Grep'; hooks = @([pscustomobject]@{ type = 'command'; command = "bash `"$pfx/scripts/hooks/block-read-secrets.sh`"" }) }
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
    # Drop only the himmel hook OBJECTS (not whole stanzas), keep stanzas that
    # still have hooks, then append the fresh stanzas. Hook-object granularity
    # preserves a non-himmel hook (rtk-hook-guard / operator's own) co-located in
    # the SAME hooks[] array as a himmel hook (basename REPLACE, not append).
    $himmelRe = 'scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)\.sh'
    $kept = @()
    foreach ($st in @($cfg.hooks.PreToolUse)) {
        $keepHooks = @($st.hooks | Where-Object { $_.command -notmatch $himmelRe })
        if ($keepHooks.Count -gt 0) {
            $st.hooks = $keepHooks
            $kept += $st
        }
    }
    $cfg.hooks.PreToolUse = @($kept + $desired)
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

# env.HIMMEL_REPO — default-by-install (HIMMEL-453). Sibling of
# Wire-StatuslineCore: write THIS himmel clone's path into the scope-appropriate
# settings.json so the leg resolver + minerva anchor get it without a manual set.
function Wire-HimmelRepoCore {
    $settings = if ($Scope -eq 'project') {
        Join-Path $Target '.claude\settings.json'
    } else {
        Join-Path $HOME '.claude\settings.json'
    }
    if ($DryRun) {
        Write-Host "DRY: wire env.HIMMEL_REPO → $settings (himmel: $HimmelRoot)"
        return
    }
    $whr = Join-Path $HimmelRoot 'scripts\lib\wire-himmel-repo.ps1'
    & pwsh -NoProfile -File $whr -SettingsPath $settings -HimmelPath $HimmelRoot
    if ($LASTEXITCODE -ne 0) { throw "wire-himmel-repo failed (exit $LASTEXITCODE)" }
}

# env.LUNA_VAULT_PATH — persist the scaffolded vault path (HIMMEL-458) so the
# end-session-wiki resolver finds it without a manual export. Sibling of
# Wire-HimmelRepoCore; written to the scope-appropriate settings.json.
function Wire-LunaVaultPath([string]$Dest) {
    $settings = if ($Scope -eq 'project') {
        Join-Path $Target '.claude\settings.json'
    } else {
        Join-Path $HOME '.claude\settings.json'
    }
    if ($DryRun) {
        Write-Host "DRY: wire env.LUNA_VAULT_PATH → $settings (vault: $Dest)"
        return
    }
    $wlv = Join-Path $HimmelRoot 'scripts\lib\wire-luna-vault.ps1'
    & pwsh -NoProfile -File $wlv -SettingsPath $settings -VaultPath $Dest
    if ($LASTEXITCODE -ne 0) { throw "wire-luna-vault failed (exit $LASTEXITCODE)" }
}

# -FillEnv (HIMMEL-453): fill the himmel clone's .env via the bash fill-env.sh.
# Targets $HimmelRoot\.env for BOTH scopes (adopt copies hooks, never the Jira
# CLI, so an adopted repo always uses the clone's CLI reading $HimmelRoot\.env).
# Resolve GIT Bash explicitly -- a bare `bash` often resolves to the System32 WSL
# stub, which cannot read C:/... paths. Require-Tools does not verify bash.
function FillEnv-Core {
    if ($DryRun) { Write-Host "DRY: fill $HimmelRoot\.env"; return }
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if (-not (Test-Path $gitBash)) {
        $bc = Get-Command bash -ErrorAction SilentlyContinue
        $gitBash = if ($bc -and $bc.Source -notmatch 'System32') { $bc.Source } else { $null }
    }
    if (-not $gitBash) {
        Write-Host "  -FillEnv skipped: Git Bash not found (edit .env by hand)." -ForegroundColor Yellow
        return
    }
    $envF = Join-Path $HimmelRoot '.env'
    $exF  = Join-Path $HimmelRoot '.env.example'
    if ((-not (Test-Path $envF)) -and (Test-Path $exF)) { Copy-Item $exF $envF }
    if (-not (Test-Path $envF)) { return }
    $fe = (Join-Path $HimmelRoot 'scripts/setup/fill-env.sh').Replace('\', '/')
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $gitBash $fe $envF.Replace('\', '/') $exF.Replace('\', '/')
        if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: fill-env failed; continuing." -ForegroundColor Yellow }
    } finally {
        $ErrorActionPreference = $savedEAP
    }
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
    Wire-HimmelRepoCore
    if ($FillEnv) { FillEnv-Core }
    Write-Host "  (optional) pre-commit gates: see $HimmelRoot\docs\setup\use-on-your-project.md"
}

function Do-Luna([string]$Dest) {
    Write-Host "──── Scaffolding luna vault → $Dest ────"
    if ((Test-Path $Dest) -and -not $DryRun) {
        Write-Host "  $Dest already exists — skipping copy (re-run the vault's own setup to update)"
    } elseif (-not $DryRun) {
        $parent = Split-Path $Dest
        if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
        Copy-Item -Recurse -Force (Join-Path $HimmelRoot 'templates\luna-second-brain') $Dest
    } else {
        Write-Host "DRY: copy templates\luna-second-brain → $Dest"
    }
    # Persist the vault path UNCONDITIONALLY — a re-run over an existing scaffold
    # must still wire a previously-unwired install (HIMMEL-458).
    Wire-LunaVaultPath $Dest
    Write-Host "  next: cd `"$Dest`"; bash scripts/setup.sh   (idempotent; prints the plugin-install commands)"
}

$dryNote = if ($DryRun) { ' (dry-run)' } else { '' }
Write-Host "==> himmel adopt — profile=$Profile scope=$Scope$dryNote"
switch ($Profile) {
    'core' { Do-Core }
    # `luna` historically used -Target; also honor an explicit -LunaTarget so the
    # intuitive `-Profile luna -LunaTarget` is no longer a silent no-op
    # (HIMMEL-458 critic #3). -Target still wins when -LunaTarget is absent.
    'luna' { if ($LunaTargetSet) { Do-Luna $LunaTarget } else { Do-Luna $Target } }
    'all'  { Do-Core; Do-Luna $LunaTarget }
}
Write-Host "──── Done ────"
