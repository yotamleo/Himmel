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
#   -WithGraphify     Opt in to installing the graphify knowledge-graph CLI
#                     (himmel fork) during a `core`/`all` adopt. Off by
#                     default -- the adoption verdict stays open (HIMMEL-621);
#                     this switch only installs the CLI (never over an
#                     existing foreign install -- see scripts/lib/graphify-bin.sh).
#   -SkipHooks        Opt out of placing the git gate hooks (pre-commit,
#                     commit-msg, pre-push) in -Target. On by default
#                     (HIMMEL-2441) so a fresh adopt is gated from its first
#                     commit; mirrors uninstall.ps1's own -SkipHooks.
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
    [switch]$FillEnv,
    [switch]$WithGraphify,
    [switch]$SkipHooks
)

$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Capture whether -LunaTarget was passed explicitly BEFORE the default fills it,
# so `-Profile luna -LunaTarget` can honor it (HIMMEL-458 critic #3).
$LunaTargetSet = $PSBoundParameters.ContainsKey('LunaTarget')

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$HimmelRoot  = (Resolve-Path (Join-Path $ScriptDir '..')).Path

# Default-to-available, mirroring adopt.sh's `${CLAUDE_AVAILABLE:-1}` (HIMMEL-600).
# Require-Tools flips this to $false when `claude` is absent; initializing it here
# keeps the flag an explicit boolean (never $null) so Install-Plugins' read is
# unambiguous and strict-mode-safe.
$script:ClaudeAvailable = $true

# Same pattern for `bun` (HIMMEL-752 G2): Require-Tools flips this to $false when
# `bun` is absent; Wire-QmdCore consults it to skip qmd cleanly.
$script:BunAvailable = $true

# Shared wire helpers (PreToolUse trio + SessionStart) -- one implementation for
# adopt.ps1 and setup.ps1 (HIMMEL install/uninstall symmetry).
. (Join-Path $ScriptDir 'lib/wire-pretooluse-hooks.ps1')

# Adopter preflight checks (HIMMEL-842). Provides the shared WARN-not-fail
# checks (uv/pipx, npm-less-node, jira-dist) consumed by Require-Tools below.
# The standalone scripts/preflight-adopter.ps1 runner dot-sources the same lib,
# so the two entry points report identically and can't drift (operator answer Q4).
. (Join-Path $ScriptDir 'lib/preflight-adopter.ps1')

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
    # git/jq/python3 are the harness-agnostic core deps — hard-required.
    foreach ($t in @('git', 'jq', 'python3')) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
    }
    if ($missing.Count -gt 0) {
        Write-Error "missing required tools: $($missing -join ', ') (see $HimmelRoot\docs\setup\new-machine.md)"
    }
    # `claude` is SOFT (HIMMEL-600): only the plugin-install step needs the CLI;
    # a Codex-only (or any non-Claude) adopter still gets the harness-agnostic core.
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $script:ClaudeAvailable = $false
        Write-Warning "'claude' not found — installing the harness-agnostic core only; skipping the Claude plugin-install step (Codex-only adopter is fine)."
    }
    # `bun` is SOFT (HIMMEL-752 G2): only the qmd wiring needs it; the
    # harness-agnostic core + git gates run without it. Warn with the install
    # hint; Wire-QmdCore consults $script:BunAvailable and skips qmd cleanly.
    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
        $script:BunAvailable = $false
        Write-Warning "'bun' not found — qmd search will be skipped; install: https://bun.sh (runs handover armed-resume, qmd search, the Telegram bridge, obsidian-triage tools)"
    }
    # HIMMEL-842 adopter preflight: the shared advisory checks (uv/pipx,
    # npm-less-node, jira-dist) live in scripts/lib/preflight-adopter.ps1 and are
    # also run by the standalone scripts/preflight-adopter.ps1 runner. Each
    # returns $false (after Write-Warning) when its gap is present. The
    # npm-less-node case escalates to a HARD fail below when there is no JS
    # package manager at all (npm AND bun both absent): adopt is about to build
    # dist/ artifacts (Build-JiraCli) and cannot proceed without one. When bun is
    # present it covers every himmel JS build, so the shared warning stays
    # advisory and adopt proceeds.
    $npmGap = -not (Test-PreflightNpmInvocable)
    Test-PreflightUvPipx | Out-Null
    Test-PreflightJiraDist | Out-Null
    if ($npmGap -and ($script:BunAvailable -eq $false)) {
        Write-Error "'node' found but 'npm' is missing (Ubuntu's nodejs ships without npm) and 'bun' is absent -- no JS package manager. Install bun (works for all himmel builds): https://bun.sh OR Node + npm via NodeSource: https://github.com/nodesource/distributions"
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

function Install-Plugins {
    if ($script:ClaudeAvailable -eq $false) {
        Write-Host "──── Skipping plugin install ('claude' not found — non-Claude adopter) ────"
        return
    }
    Write-Host "──── Installing plugins (-Scope $Scope) ────"
    $pluginArgs = @('-Scope', $Scope)
    if ($DryRun) { $pluginArgs += '-DryRun' }
    $ip = Join-Path $HimmelRoot 'scripts\machine-setup\install-plugins.ps1'
    if ($Scope -eq 'project') {
        # project scope writes to the CWD's .claude/settings.json — run from
        # $Target so plugins land in the adopted repo, not the himmel clone.
        Push-Location $Target
        try {
            & pwsh -NoProfile -File $ip @pluginArgs
            $pluginRc = $LASTEXITCODE
        } finally { Pop-Location }
    } else {
        & pwsh -NoProfile -File $ip @pluginArgs
        $pluginRc = $LASTEXITCODE
    }
    if ($pluginRc -ne 0) { throw "install-plugins failed (exit $pluginRc)" }
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

# Wire-UserClaudeMd (HIMMEL-2038): append himmel's "working principles" block
# to a user-scope rule file. Those four defaults (think before coding /
# simplicity first / surgical changes / goal-driven execution) used to live in
# himmel's always-on project CLAUDE.md; they are general engineering defaults,
# not himmel invariants, so adopters get them once at user scope instead of
# paying for them in every himmel session. Self-contained (no PS lib-sourcing
# equivalent exists for this -- mirrors how the qmd helpers above live inline
# in this file rather than in a sourced lib.ps1).
#
# One TARGET per call, by design: Do-Core calls it twice -- once for Claude
# Code's ~/.claude/CLAUDE.md, once for Codex's ~/.codex/AGENTS.md -- so a
# Codex adopter isn't left with the principles nowhere. Hermes is not a
# target: its himmel_agent profile SOUL already states the same four.
#
# The payload is extracted at RUN TIME from the marker range in
# docs/setup/user-scope-claude-md-template.md (single source of truth), never
# duplicated here.
#
# Idempotent / never destructive:
#   - target exists AND already has the marker -> skip, unchanged.
#   - target exists, no marker, but looks like it already states the
#     principles by hand (heuristic phrase match) -> skip, unchanged.
#   - target exists, no marker, no heuristic match -> APPEND (blank line +
#     payload), never truncate/overwrite.
#   - target absent -> create it with just the payload.
# WARN-not-fail wrapper (this step must never abort the rest of adopt):
# delegates to Wire-UserClaudeMdInner and catches any exception it throws.
function Wire-UserClaudeMd {
    param(
        [string]$TemplatePath,
        [string]$TargetPath
    )
    try {
        Wire-UserClaudeMdInner -TemplatePath $TemplatePath -TargetPath $TargetPath
    } catch {
        Write-Host "  WARNING: user CLAUDE.md wiring failed - continuing. ($_)" -ForegroundColor Yellow
    }
}

function Wire-UserClaudeMdInner {
    param(
        [string]$TemplatePath,
        [string]$TargetPath
    )
    $marker = 'HIMMEL:working-principles'
    # ponytail: distinctive-phrase heuristic, not a real "did the operator
    # already say this" detector -- a hand-written CLAUDE.md phrasing the same
    # idea without this exact phrase would still get appended to. Upgrade
    # path: none planned, a rare double-append is cheaper to fix by hand than
    # a stricter matcher is to build.
    $heuristic = 'simplicity first'

    if (-not (Test-Path $TemplatePath)) {
        Write-Host "  user CLAUDE.md: template not found at $TemplatePath — skipping." -ForegroundColor Yellow
        return
    }
    # -Encoding UTF8: Windows PowerShell 5.1 otherwise reads a BOM-less UTF-8
    # template as ANSI and mojibakes the em dashes (PS 7 defaults to UTF-8).
    $templateText = Get-Content $TemplatePath -Raw -Encoding UTF8
    $beginTag = "<!-- BEGIN $marker -->"
    $endTag = "<!-- END $marker -->"
    $beginIdx = $templateText.IndexOf($beginTag)
    $endIdx = $templateText.IndexOf($endTag)
    if ($beginIdx -lt 0 -or $endIdx -lt 0) {
        Write-Host "  user CLAUDE.md: markers not found in $TemplatePath — skipping." -ForegroundColor Yellow
        return
    }
    $payload = $templateText.Substring($beginIdx, $endIdx + $endTag.Length - $beginIdx)

    if (Test-Path $TargetPath) {
        $existing = Get-Content $TargetPath -Raw -Encoding UTF8
        # Exact BEGIN line, not the bare marker substring (mirrors user-claude-md.sh).
        if ($existing -match [regex]::Escape($beginTag)) {
            Write-Host "  user CLAUDE.md: working-principles block already present — skipping ($TargetPath)"
            return
        }
        if ($existing -match [regex]::Escape($heuristic)) {
            Write-Host "  user CLAUDE.md: no marker, but looks like working principles are already stated by hand (heuristic match on '$heuristic') — skipping, not appending ($TargetPath)"
            return
        }
        if ($DryRun) {
            Write-Host "DRY: append working-principles block → $TargetPath"
            return
        }
        Add-Content -Path $TargetPath -Value "`n$payload" -Encoding utf8
        Write-Host "  user CLAUDE.md: appended working-principles block → $TargetPath"
        return
    }

    if ($DryRun) {
        Write-Host "DRY: create $TargetPath with working-principles block"
        return
    }
    $targetDir = Split-Path $TargetPath
    if ($targetDir) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
    Set-Content -Path $TargetPath -Value $payload -Encoding utf8
    Write-Host "  user CLAUDE.md: created $TargetPath with working-principles block"
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

# env.HANDOVER_DIR — seed the handover state root at the scaffolded luna vault
# (HIMMEL-839). Without this, a fresh adopter's handover state silently
# defaults to the inline <repo-root>/handovers/ stub. Creates <Dest>/handovers
# so Mode B resolves cleanly out of the box. Sibling of Wire-LunaVaultPath;
# $Dest = the scaffolded vault dir.
function Wire-HandoverDirLuna([string]$Dest) {
    $hdir = Join-Path $Dest 'handovers'
    $settings = if ($Scope -eq 'project') {
        Join-Path $Target '.claude\settings.json'
    } else {
        Join-Path $HOME '.claude\settings.json'
    }

    # PRESERVE an operator-selected HANDOVER_DIR (HIMMEL-839 CR round-2): a
    # routine re-adopt must reproduce state, never silently reset it.
    # /handover-setup is documented as "the only place the state-root location
    # is chosen interactively" -- adopt.ps1 must not become a second, silent
    # place that overrides that choice. Two places it could already live:
    #   1. This settings.json's own env.HANDOVER_DIR (a prior adopt run).
    #   2. The primary checkout's .env (set-handover-dir.sh / Mode B -- the
    #      actual file /handover-setup writes to). settings.json env takes
    #      PROCESS-ENV precedence over .env, so writing here would silently
    #      SHADOW that choice even though the .env file itself stayed
    #      untouched. Same rationale as the .sh twin.
    if (Test-Path $settings) {
        $existing = $null
        try {
            $existingCfg = Get-Content $settings -Raw | ConvertFrom-Json
            $existing = $existingCfg.env.HANDOVER_DIR
        } catch {
            $existing = $null
        }
        if ($existing) {
            Write-Host "  env.HANDOVER_DIR already set in $settings ($existing) — leaving it (re-adopt reproduces, never resets; HIMMEL-839)"
            return
        }
    }
    $envFile = Join-Path $HimmelRoot '.env'
    if ((Test-Path $envFile) -and (Select-String -Path $envFile -Pattern '^\s*HANDOVER_DIR=' -Quiet)) {
        Write-Host "  HANDOVER_DIR already set in $envFile (via /handover-setup) — leaving it, not wiring env.HANDOVER_DIR into $settings (HIMMEL-839)"
        return
    }

    if ($DryRun) {
        Write-Host "DRY: mkdir -p $hdir"
        Write-Host "DRY: wire env.HANDOVER_DIR → $settings (handover dir: $hdir)"
        return
    }
    New-Item -ItemType Directory -Force -Path $hdir | Out-Null
    # Canonicalize to an absolute path (HIMMEL-839 CR round-2): a relative
    # -LunaTarget would otherwise persist a CWD-dependent relative path.
    $hdir = (Resolve-Path $hdir).Path
    $whd = Join-Path $HimmelRoot 'scripts\lib\wire-handover-dir.ps1'
    & pwsh -NoProfile -File $whd -SettingsPath $settings -HandoverDir $hdir
    if ($LASTEXITCODE -ne 0) { throw "wire-handover-dir failed (exit $LASTEXITCODE)" }
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

# --- qmd resolver + helpers (HIMMEL-752; mirror of scripts/lib/qmd-bin.sh) ---
# pwsh cannot source bash, so the RESOLVER (Invoke-Qmd/Test-Qmd) + REGISTER
# logic is duplicated inline (parity with setup.ps1's qmd block) -- UPDATE
# qmd-bin.sh + setup.ps1 + adopt.ps1 together; scripts/lib/test-qmd-bin.sh is
# the canonical behavior spec. The INSTALL step (Install-Qmd below) is NOT
# duplicated: it delegates to `bash scripts/lib/qmd-bin.sh install` (HIMMEL-877)
# so the clone/build/junction recipe has exactly one implementation. Honors
# $env:BUN_INSTALL for relocated bun roots.
$QmdBunRoot = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $HOME '.bun' }
$QmdBunJs = Join-Path $QmdBunRoot 'install\global\node_modules\@tobilu\qmd\dist\cli\qmd.js'
# HIMMEL-877: qmd installs from the himmel qmd fork (yotamleo/qmd, pinned to
# an immutable commit SHA rather than a mutable branch — HIMMEL-911 — via
# scripts/lib/qmd-bin.sh), never upstream `bun add -g @tobilu/qmd` --
# that command EPERM-wedges on this project's machines and bun blocks its
# postinstall script.
$QmdInstallHint = "bash `"$HimmelRoot/scripts/lib/qmd-bin.sh`" install"

function Invoke-Qmd {
    param([Parameter(ValueFromRemainingArguments=$true)] [string[]] $QmdArgs)
    if ((Test-Path $script:QmdBunJs) -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        & bun $script:QmdBunJs @QmdArgs
    } elseif (Get-Command qmd -ErrorAction SilentlyContinue) {
        & qmd @QmdArgs
    } else {
        $global:LASTEXITCODE = 127
    }
}

function Test-Qmd {
    if ((Test-Path $script:QmdBunJs) -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        return $true
    }
    return [bool](Get-Command qmd -ErrorAction SilentlyContinue)
}

# Resolve GIT Bash explicitly for the qmd-bin.sh delegation -- same pattern
# as FillEnv-Core below: a bare `bash` often resolves to the System32 (or
# WindowsApps) WSL stub, which cannot run Git-Bash scripts against C:/...
# paths. Require-Tools does NOT verify bash. Returns $null when no usable
# Git Bash exists; callers WARN + skip, never invoke the WSL stub.
function Resolve-QmdGitBash {
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if (Test-Path $gitBash) { return $gitBash }
    $bc = Get-Command bash -ErrorAction SilentlyContinue
    if ($bc -and $bc.Source -notmatch 'System32|WindowsApps') { return $bc.Source }
    return $null
}

# Delegates to the ONE clone/build/junction implementation (HIMMEL-877):
# `bash scripts/lib/qmd-bin.sh install` (git-clone the himmel qmd fork, `bun
# install && bun run build`, then junction/symlink it onto the bun-global
# @tobilu/qmd path -- idempotent, WARN-not-fail). Returns an honest int rc.
function Install-Qmd {
    Write-Host "Installing qmd fork via bash scripts/lib/qmd-bin.sh..."
    $gitBash = Resolve-QmdGitBash
    if (-not $gitBash) {
        Write-Host "  WARNING: Git Bash not found - cannot run the qmd fork installer." -ForegroundColor Yellow
        Write-Host "  Manual: install Git for Windows, then run: bash `"$HimmelRoot/scripts/lib/qmd-bin.sh`" install" -ForegroundColor Yellow
        return 1
    }
    & $gitBash "$HimmelRoot/scripts/lib/qmd-bin.sh" install
    return $LASTEXITCODE
}

# Mirror of qmd_fork_served() via the shared bash CLI verb (HIMMEL-877 CR
# codex-adv-1): the install gate is "fork already served", NOT presence
# (Test-Qmd) -- a machine carrying the old upstream bun-global install is
# qmd-present but must still MIGRATE to the fork. Returns $false when no
# usable Git Bash exists so the install path (which re-checks) is attempted.
function Test-QmdForkServed {
    $gitBash = Resolve-QmdGitBash
    if (-not $gitBash) { return $false }
    & $gitBash "$HimmelRoot/scripts/lib/qmd-bin.sh" fork-served *> $null
    return ($LASTEXITCODE -eq 0)
}

# Mirror of qmd_register_collection(): idempotent + WARN-not-fail, returns an
# honest int rc (0 on a clean add or an already-registered skip).
function Register-QmdCollection([string]$Path, [string]$Name) {
    $listOut = Invoke-Qmd collection list 2>&1
    $listRc = $LASTEXITCODE
    if ($listRc -ne 0) {
        Write-Host "  WARNING: qmd collection list failed (rc=$listRc) - skipping '$Name' registration." -ForegroundColor Yellow
        $listOut | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        return $listRc
    }
    if ($listOut -match "^$Name\b") {
        Write-Host "  Collection '$Name' already registered - skipping."
        return 0
    }
    Invoke-Qmd collection add $Path --name $Name | Out-Null
    $addRc = $LASTEXITCODE
    if ($addRc -ne 0) {
        Write-Host "  WARNING: qmd collection add '$Name' failed (rc=$addRc) - continuing." -ForegroundColor Yellow
        if ($addRc -eq 127) {
            Write-Host "  (rc=127 means the resolver could not find qmd - install: $script:QmdInstallHint)" -ForegroundColor Yellow
        }
        return $addRc
    }
    return 0
}

# Mirror of wire_qmd_core(): fix the broken plugin stub, install the qmd CLI if
# missing, pull the embedding/rerank models, and register the himmel clone.
# Best-effort throughout; never throws (qmd is optional - a failure WARNs).
function Wire-QmdCore {
    if ($script:BunAvailable -eq $false) {
        Write-Host "---- Skipping qmd wiring (bun not found) ----"
        Write-Host "  Install bun to enable qmd search: https://bun.sh"
        return
    }
    Write-Host "---- Wiring qmd search ----"
    # WARN-not-fail structural guarantee (CR fix): on PS configs where
    # $PSNativeCommandUseErrorActionPreference=$true (documented 7.4+ default),
    # a nonzero native exit under EAP='Stop' throws BEFORE the $LASTEXITCODE
    # warn-checks below can run - a broken qmd/bun would then abort adopt.
    # Disable that coupling for the qmd block only; restore in finally.
    $savedNativeEAP = $null
    if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
        $savedNativeEAP = $PSNativeCommandUseErrorActionPreference
    }
    $global:PSNativeCommandUseErrorActionPreference = $false
    try {
    Wire-QmdCoreInner
    } finally {
        if ($null -ne $savedNativeEAP) { $global:PSNativeCommandUseErrorActionPreference = $savedNativeEAP }
    }
}

function Wire-QmdCoreInner {
    # G1: neutralize the broken plugin-cache stub. WARN-not-fail.
    if ($DryRun) {
        Write-Host "DRY: bash $HimmelRoot/scripts/lib/fix-qmd-stub.sh"
    } else {
        # Resolve-QmdGitBash, never a bare `bash`: on Windows that is the
        # System32 WSL stub, which exits 127 on this C:/ path (HIMMEL-1992).
        $gitBash = Resolve-QmdGitBash
        $savedEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            if (-not $gitBash) {
                Write-Host "  WARNING: Git Bash not found - skipping fix-qmd-stub." -ForegroundColor Yellow
            } else {
                & $gitBash "$HimmelRoot/scripts/lib/fix-qmd-stub.sh"
                if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: fix-qmd-stub failed (rc=$LASTEXITCODE) - continuing." -ForegroundColor Yellow }
            }
        } finally {
            $ErrorActionPreference = $savedEAP
        }
    }
    # Install the qmd CLI unless the FORK is already the served install
    # (HIMMEL-877 CR codex-adv-1): gate on Test-QmdForkServed, NOT presence
    # (Test-Qmd) - a machine carrying the old upstream bun-global install is
    # qmd-present but must still MIGRATE to the fork. Install-Qmd re-checks
    # internally as the second line of defense.
    if ($DryRun) {
        if (-not (Test-QmdForkServed)) { Write-Host "DRY: Install-Qmd" }
    } elseif (-not (Test-QmdForkServed)) {
        $installRc = Install-Qmd
        if ($installRc -ne 0) {
            Write-Host "  WARNING: qmd install failed (rc=$installRc) - continuing without qmd." -ForegroundColor Yellow
        } elseif (-not (Test-Qmd)) {
            # CR silent-divergence guard: the bash installer reported success
            # but this pwsh session cannot resolve the install - name both
            # facts + where to look instead of continuing silently.
            Write-Host "  WARNING: qmd install reported success but qmd is still not resolvable from PowerShell." -ForegroundColor Yellow
            Write-Host "  Inspect: $script:QmdBunJs (expected bun-global install path)." -ForegroundColor Yellow
        }
    }
    # G4: pull models (~2.1 GB). Size caveat FIRST so the operator can Ctrl-C
    # before the download, then best-effort pull.
    if ($DryRun) {
        Write-Host "DRY: qmd pull (downloads ~2.1 GB of embedding/rerank models)"
    } elseif (Test-Qmd) {
        Write-Host "  Pulling qmd models (downloads ~2.1 GB of embedding/rerank models)..."
        Invoke-Qmd pull
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: qmd pull failed - semantic search needs the models." -ForegroundColor Yellow
            Write-Host "  Pull manually: qmd pull" -ForegroundColor Yellow
        }
    }
    # Register the himmel clone.
    if ($DryRun) {
        Write-Host "DRY: Register-QmdCollection $HimmelRoot himmel"
    } elseif (Test-Qmd) {
        Register-QmdCollection $HimmelRoot himmel | Out-Null
    }
}

# Delegates to the ONE detect/install implementation (HIMMEL-891):
# `bash scripts/lib/graphify-bin.sh install` (uv-tool-installs graphify from
# the himmel fork, UNLESS an existing install -- himmel-fork or foreign -- is
# already present, in which case it is adopted as-is). Reuses
# Resolve-QmdGitBash (generic bash resolution, not qmd-specific despite the
# name). Returns an honest int rc.
function Install-Graphify {
    Write-Host "Installing graphify via bash scripts/lib/graphify-bin.sh..."
    $gitBash = Resolve-QmdGitBash
    if (-not $gitBash) {
        Write-Host "  WARNING: Git Bash not found - cannot run the graphify installer." -ForegroundColor Yellow
        Write-Host "  Manual: install Git for Windows, then run: bash `"$HimmelRoot/scripts/lib/graphify-bin.sh`" install" -ForegroundColor Yellow
        return 1
    }
    # Route the bash script's stdout through Write-Host (host stream, not the
    # pipeline) instead of letting it fall straight into the function's own
    # output -- otherwise `$installRc = Install-Graphify` captures an ARRAY
    # (every emitted line + the trailing int), and `-ne 0` on that array is
    # true whenever ANY element is nonzero-ish -- a false-positive WARNING on
    # every successful install that prints output (which is all of them).
    & $gitBash "$HimmelRoot/scripts/lib/graphify-bin.sh" install | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
}

# Wire-GraphifyCore -- opt-in install of the graphify knowledge-graph CLI
# (HIMMEL-891). Unlike Wire-QmdCore, this is NOT called unconditionally --
# Do-Core below only calls it when -WithGraphify was passed. WARN-not-fail:
# a missing Git Bash/uv or a network hiccup must not abort adopt. Honors
# -DryRun.
function Wire-GraphifyCore {
    Write-Host "---- Wiring graphify (opt-in, -WithGraphify) ----"
    if ($DryRun) {
        Write-Host "DRY: Install-Graphify"
        Write-Host "DRY: claude mcp add -s $Scope graphify -- <graphify-mcp: absolute path for user/local, bare name for project>"
        return
    }
    # WARN-not-fail structural guarantee (CR-r2): under this script's
    # EAP='Stop', a $PSNativeCommandUseErrorActionPreference=$true config
    # turns the bash installer's nonzero exit into a TERMINATING error
    # before Install-Graphify can return $LASTEXITCODE -- aborting the whole
    # adopt on an optional step. Decouple both for this block only; restore
    # in finally (same guard as Wire-QmdCore / Build-JiraCli).
    $savedNativeEAP = $null
    if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
        $savedNativeEAP = $PSNativeCommandUseErrorActionPreference
    }
    $global:PSNativeCommandUseErrorActionPreference = $false
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $installRc = Install-Graphify
        if ($installRc -ne 0) {
            Write-Host "  WARNING: graphify install failed (rc=$installRc) - continuing without graphify." -ForegroundColor Yellow
        } else {
            # Register the MCP server INSIDE this block: the decoupled native-EAP
            # posture keeps a nonzero `claude mcp get` (not-registered probe) from
            # terminating the adopt.
            Register-GraphifyMcp
            # HIMMEL-2480: price the hook-guard entries in the ADOPTED repo
            # ($Target, not this himmel clone) -- same delegation pattern as
            # Install-Graphify above.
            $gitBashPrice = Resolve-QmdGitBash
            if ($gitBashPrice) {
                & $gitBashPrice "$HimmelRoot/scripts/lib/graphify-bin.sh" price-hooks "$Target" | ForEach-Object { Write-Host $_ }
            } else {
                Write-Host "  graphify hook pricing: Git Bash not found - skipping." -ForegroundColor Yellow
                Write-Host "  Manual: bash `"$HimmelRoot/scripts/lib/graphify-bin.sh`" price-hooks `"$Target`"" -ForegroundColor Yellow
            }
        }
    } finally {
        $ErrorActionPreference = $savedEAP
        if ($null -ne $savedNativeEAP) { $global:PSNativeCommandUseErrorActionPreference = $savedNativeEAP }
    }
}

# Register-GraphifyMcp -- register the graphify MCP server (mcp__graphify__*) at
# the adopt Scope, delegating to the ONE shared implementation in
# scripts/lib/graphify-bin.sh (`register-mcp`) rather than duplicating the
# resolve/add recipe natively (mirrors Install-Graphify's delegation). The bash
# impl resolves the absolute entrypoint + is idempotent + WARN-not-fail.
function Register-GraphifyMcp {
    $gitBash = Resolve-QmdGitBash
    if (-not $gitBash) {
        Write-Host "  graphify MCP: Git Bash not found - skipping registration." -ForegroundColor Yellow
        Write-Host "  Manual: bash `"$HimmelRoot/scripts/lib/graphify-bin.sh`" register-mcp $Scope" -ForegroundColor Yellow
        return
    }
    if ($Scope -eq 'project') {
        # project scope writes the committed .mcp.json relative to CWD (mirrors
        # Install-Plugins) -- run from $Target so it lands in the adopted repo.
        Push-Location $Target
        try {
            & $gitBash "$HimmelRoot/scripts/lib/graphify-bin.sh" register-mcp $Scope | ForEach-Object { Write-Host $_ }
        } finally { Pop-Location }
    } else {
        & $gitBash "$HimmelRoot/scripts/lib/graphify-bin.sh" register-mcp $Scope | ForEach-Object { Write-Host $_ }
    }
}

# Build-JiraCli -- build scripts/jira/dist/index.js (HIMMEL-842 gap 3). dist/ is
# a gitignored build artifact, so a fresh clone bootstrapped via adopt.ps1 hits
# MODULE_NOT_FOUND without this (CLAUDE.md's "worktrees lack dist/" warning is
# scoped too narrowly -- a fresh PRIMARY clone via adopt.ps1 hits the identical
# failure). Ports scripts/setup.sh step [3/10]'s build block, gated on
# npm-or-bun presence (bun covers the Ubuntu node-without-npm case), and
# WARN-not-fail: a build failure warns with the manual command and returns --
# matches Wire-QmdCore's contract so a broken build never aborts an adopt.
# Unlike setup.sh, NO `npm link`: adopted repos invoke the clone's dist/index.js
# directly (`node $HimmelRoot\scripts\jira\dist\index.js`), so a global symlink
# isn't needed. Honors -DryRun.
function Build-JiraCli {
    $jiraDir = Join-Path $HimmelRoot 'scripts\jira'
    # fix-batch F3: skip only when BOTH halves are present — a stale dist/
    # without node_modules/ (gitignored, so a dist/ leftover from a prior
    # build can outlive a node_modules/ wipe) previously passed as "already
    # built" then failed at runtime. Mirrors setup.ps1's invariant (checks both).
    if ((Test-Path (Join-Path $jiraDir 'node_modules')) -and (Test-Path (Join-Path $jiraDir 'dist\index.js'))) {
        Write-Host "  jira CLI dist already built — skipping"
        return
    }
    $pm = $null
    if (Get-Command npm -ErrorAction SilentlyContinue) { $pm = 'npm' }
    elseif (Get-Command bun -ErrorAction SilentlyContinue) { $pm = 'bun' }
    if (-not $pm) {
        Write-Host "  jira CLI: skipping build (no npm or bun — install one to build dist/)." -ForegroundColor Yellow
        Write-Host "  Manual: (cd scripts/jira && npm install && npm run build)" -ForegroundColor Yellow
        return
    }
    Write-Host "──── Building jira CLI (scripts/jira/dist) ────"
    if ($DryRun) { Write-Host "DRY: (cd scripts/jira && $pm install && $pm run build)"; return }
    # WARN-not-fail under EAP='Stop' + PSNativeCommandUseErrorActionPreference:
    # decouple native exit from EAP so a build failure WARNs instead of throwing
    # (mirrors Wire-QmdCore's native-EAP guard). npm takes --silent (matches
    # setup.sh); bun has no --silent flag, so the invocation branches on $pm.
    $savedNativeEAP = $null
    if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
        $savedNativeEAP = $PSNativeCommandUseErrorActionPreference
    }
    $global:PSNativeCommandUseErrorActionPreference = $false
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $buildRc = 0
    try {
        Push-Location $jiraDir
        if ($pm -eq 'npm') {
            & npm install --silent
            $rc1 = $LASTEXITCODE
            if ($rc1 -eq 0) { & npm run build --silent; $buildRc = $LASTEXITCODE } else { $buildRc = $rc1 }
        } else {
            & bun install
            $rc1 = $LASTEXITCODE
            if ($rc1 -eq 0) { & bun run build; $buildRc = $LASTEXITCODE } else { $buildRc = $rc1 }
        }
    } finally {
        Pop-Location
        $ErrorActionPreference = $savedEAP
        if ($null -ne $savedNativeEAP) { $global:PSNativeCommandUseErrorActionPreference = $savedNativeEAP }
    }
    if ($buildRc -eq 0) {
        Write-Host "  jira CLI built. Invoke: node $HimmelRoot\scripts\jira\dist\index.js --help"
    } else {
        Write-Host "  WARNING: jira CLI build failed (exit $buildRc) — continuing (the preflight flagged this too)." -ForegroundColor Yellow
        Write-Host "  Manual: (cd scripts/jira && $pm install && $pm run build)" -ForegroundColor Yellow
    }
}

function Install-PrecommitHooks {
    # HIMMEL-2441: place the git gate hooks by default so an adopter's FIRST
    # commit is actually gated -- mirrors setup.ps1's own [1/9]/[2/9] steps
    # (install pre-commit if missing, then wire all three hook types) against
    # $Target, via `python -m pre_commit` (matching setup.ps1/uninstall.ps1's
    # own Windows mechanism rather than assuming a `pre-commit` exe on PATH).
    # --allow-missing-config keeps this safe for a genuine external adopt
    # target with no .pre-commit-config.yaml of its own: the hook wires in
    # but no-ops on every commit until the adopter's own config exists,
    # rather than hard-failing every commit (measured: a bare `pre-commit
    # install` + commit with zero config exits 1; --allow-missing-config
    # exits 0 and starts gating the moment a config is added, no reinstall
    # needed). WARN-not-fail, matching Build-JiraCli's contract.
    if ($SkipHooks) {
        Write-Host "  git hooks: skipped (-SkipHooks)"
        return
    }
    if (-not (Test-Path (Join-Path $Target '.git'))) {
        Write-Host "  git hooks: skipping ($Target is not a git repo)"
        return
    }
    # HIMMEL-2441/2483 [round-3 panel]: -DryRun must describe the planned
    # install regardless of host state -- checked BEFORE the python
    # Get-Command probe below, same as the .sh twin, so a dry-run's output
    # doesn't depend on whether python happens to be installed.
    if ($DryRun) {
        Write-Host "DRY: (cd $Target && python -m pip install pre-commit --quiet && python -m pre_commit install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push)"
        return
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Host "  WARNING: git hooks: 'python' not found -- skipping. Install Python 3.10+, then re-run." -ForegroundColor Yellow
        return
    }
    Write-Host "──── Installing git gate hooks ($Target) ────"
    # WARN-not-fail under EAP='Stop' + PSNativeCommandUseErrorActionPreference:
    # decouple native exit from EAP so a failed pip/pre_commit invocation WARNs
    # instead of throwing (same guard Build-JiraCli uses above).
    $savedNativeEAP = $null
    if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
        $savedNativeEAP = $PSNativeCommandUseErrorActionPreference
    }
    $global:PSNativeCommandUseErrorActionPreference = $false
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $Target
    try {
        python -m pip install pre-commit --quiet
        $pipRc = $LASTEXITCODE
        $installRc = 1
        if ($pipRc -eq 0) {
            python -m pre_commit install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push
            $installRc = $LASTEXITCODE
        }
        if ($pipRc -eq 0 -and $installRc -eq 0) {
            Write-Host "  git hooks installed (pre-commit, commit-msg, pre-push)."
        } else {
            Write-Host "  WARNING: git hook install failed -- continuing. Manual: (cd $Target && python -m pip install pre-commit && python -m pre_commit install --allow-missing-config --hook-type pre-commit --hook-type commit-msg --hook-type pre-push)" -ForegroundColor Yellow
        }
    } finally {
        Pop-Location
        $ErrorActionPreference = $savedEAP
        if ($null -ne $savedNativeEAP) { $global:PSNativeCommandUseErrorActionPreference = $savedNativeEAP }
    }
}

function Do-Core {
    Require-Tools
    if ($Scope -eq 'project') {
        Copy-Portable
        Set-PretooluseHooks -SettingsPath (Join-Path $Target '.claude\settings.json') -Prefix '$CLAUDE_PROJECT_DIR' -DryRun:$DryRun
        Write-Host "  worktree commands: bash $Target/scripts/worktree.sh feat/slug"
    } else {
        # user scope: wire the full UNIVERSAL set -- the PreToolUse trio AND the
        # SessionStart leg-injector -- so a session launched anywhere gets the legs
        # (parity with setup.ps1 / R3).
        $userSettings = Join-Path $HOME '.claude\settings.json'
        Set-PretooluseHooks -SettingsPath $userSettings -Prefix $HimmelRoot -DryRun:$DryRun
        Set-SessionStartHook -SettingsPath $userSettings -Prefix $HimmelRoot -HookBasename 'inject-initiative.sh' -DryRun:$DryRun
        Write-Host "  worktree commands run from the himmel clone: bash $HimmelRoot/scripts/worktree.sh feat/slug"
    }
    # HIMMEL-2038: the "working principles" defaults were demoted out of himmel's
    # always-on project CLAUDE.md (general engineering defaults, not himmel
    # invariants) -- adopters get them via this user-scope append instead. Runs
    # in BOTH scopes on purpose: the principles live at user scope whichever way
    # core was installed, so a project-scope adopter would otherwise pull the
    # shortened CLAUDE.md and silently lose them. Idempotent, so re-running adopt
    # is also the migration path. WARN-not-fail (see Wire-UserClaudeMd).
    #
    # TWO targets: Claude Code reads ~/.claude/CLAUDE.md, Codex reads
    # ~/.codex/AGENTS.md -- installing only into the Claude-only file would
    # leave a Codex adopter with the principles nowhere.
    $userClaudeMdTemplate = Join-Path $HimmelRoot 'docs\setup\user-scope-claude-md-template.md'
    $userClaudeMdTarget = Join-Path $HOME '.claude\CLAUDE.md'
    Wire-UserClaudeMd -TemplatePath $userClaudeMdTemplate -TargetPath $userClaudeMdTarget
    $userAgentsMdTarget = Join-Path $HOME '.codex\AGENTS.md'
    Wire-UserClaudeMd -TemplatePath $userClaudeMdTemplate -TargetPath $userAgentsMdTarget
    Install-Plugins
    Build-JiraCli
    Wire-QmdCore
    if ($WithGraphify) { Wire-GraphifyCore }
    Wire-StatuslineCore
    Wire-HimmelRepoCore
    if ($FillEnv) { FillEnv-Core }
    Install-PrecommitHooks
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
    # Seed HANDOVER_DIR the same way, same reasoning (HIMMEL-839).
    Wire-HandoverDirLuna $Dest
    # G5 (HIMMEL-752): register the scaffolded vault as a qmd collection so it
    # is queryable immediately. Skip + note when qmd/bun unavailable; WARN-not-fail.
    # For -Profile all, Do-Core (-> Wire-QmdCore) has already installed qmd; for
    # -Profile luna alone it may be absent, in which case Test-Qmd skips cleanly.
    if ($script:BunAvailable -eq $false) {
        Write-Host "  qmd: skipping luna collection registration (bun not found)"
    } elseif ($DryRun) {
        Write-Host "DRY: Register-QmdCollection $Dest luna"
    } elseif (Test-Qmd) {
        # Same native-EAP decoupling as Wire-QmdCore (WARN-not-fail, CR fix).
        $savedNativeEAP = $null
        if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
            $savedNativeEAP = $PSNativeCommandUseErrorActionPreference
        }
        $global:PSNativeCommandUseErrorActionPreference = $false
        try {
            Register-QmdCollection $Dest luna | Out-Null
        } finally {
            if ($null -ne $savedNativeEAP) { $global:PSNativeCommandUseErrorActionPreference = $savedNativeEAP }
        }
    } else {
        Write-Host "  qmd: skipping luna collection registration (qmd not installed)"
    }
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
