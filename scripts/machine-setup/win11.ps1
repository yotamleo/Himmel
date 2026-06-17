#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory=$true)]
    [string]$LunaRemote
)

$ErrorActionPreference = 'Stop'

# ── Paths ───────────────────────────────────────────────────────────────────
$HimmelPath     = "$env:USERPROFILE\Documents\github\himmel"
$LunaVaultPath  = "$env:USERPROFILE\Documents\luna"
$ClaudeDir      = "$env:USERPROFILE\.claude"
$RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# ── Progress ────────────────────────────────────────────────────────────────
$TotalSteps = 18
$Script:Step = 0
$Script:Failures = @()

function Write-Step($msg) {
    $Script:Step++
    Write-Host ""
    Write-Host "══════════════════════════════════════════════"
    Write-Host "[$($Script:Step)/$TotalSteps] $msg"
    Write-Host "══════════════════════════════════════════════"
}

function Invoke-NonFatal([string]$label, [scriptblock]$block) {
    try { & $block }
    catch {
        Write-Host "  WARNING: $label failed — continuing"
        $Script:Failures += "Step $($Script:Step): $label"
    }
}

function Write-SettingsJson([string]$Path, $Settings) {
    # HIMMEL-264: ConvertTo-Json reformats the whole file (4-space indent,
    # \uXXXX escapes) — cosmetic churn vs the jq-written form ubuntu.sh
    # produces. Normalize through `jq --indent 2` when jq is on PATH
    # (installed by the core-tools step); fall back to raw ConvertTo-Json
    # output otherwise. Atomic write: temp file + move.
    $json = $Settings | ConvertTo-Json -Depth 20
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        $normalized = $json | jq --indent 2 .
        if ($LASTEXITCODE -eq 0 -and $normalized) {
            $json = $normalized -join "`n"
        }
    }
    Set-Content -Path "$Path.new" -Value $json -Encoding utf8
    Move-Item -Path "$Path.new" -Destination $Path -Force
}

# ── Fatal steps (1–6) ───────────────────────────────────────────────────────
Write-Step "Update package manager"
winget upgrade --all --silent --accept-source-agreements --accept-package-agreements

Write-Step "Install core tools: git, Node LTS, Python, jq, shellcheck, gitleaks"
# shellcheck + gitleaks are referenced directly by .pre-commit-config.yaml hooks;
# pre-commit downloads its own binaries inside the hook framework, but local
# direct invocation (manual lint runs, smoke tests) needs them on PATH.
winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements
winget install --id OpenJS.NodeJS.LTS -e --silent --accept-source-agreements --accept-package-agreements
winget install --id Python.Python.3 -e --silent --accept-source-agreements --accept-package-agreements
winget install --id jqlang.jq -e --silent --accept-source-agreements --accept-package-agreements
winget install --id koalaman.shellcheck -e --silent --accept-source-agreements --accept-package-agreements
winget install --id Gitleaks.Gitleaks -e --silent --accept-source-agreements --accept-package-agreements

# Refresh PATH for current session after winget installs
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")

Write-Step "Install nvm-windows + Node from .nvmrc"
if (-not (Get-Command nvm.exe -ErrorAction SilentlyContinue)) {
    winget install --id CoreyButler.NVMforWindows -e --silent --accept-package-agreements --accept-source-agreements
    # winget updates the registry PATH but the current process needs a refresh
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
    # Verify nvm.exe is now available after PATH refresh
    if (-not (Get-Command nvm.exe -ErrorAction SilentlyContinue)) {
        Write-Error "nvm.exe still not on PATH after install + PATH refresh. Open a new shell and re-run, or add nvm to PATH manually."
        exit 1
    }
}
$NodeVersion = (Get-Content (Join-Path $RepoRoot '.nvmrc')).Trim()
nvm install $NodeVersion
nvm use $NodeVersion
$Actual = (node --version) -replace '^v(\d+).*', '$1'
$Expect = $NodeVersion -replace '^v?(\d+).*', '$1'
if ($Actual -ne $Expect) {
    Write-Error "node major $Actual != expected $Expect from .nvmrc"
    exit 1
}
Write-Host "Node $(node --version) active (.nvmrc=$NodeVersion)"

Write-Step "Install uv + uvx"
irm https://astral.sh/uv/install.ps1 | iex
# Refresh PATH so uv is available
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")
uv --version

Write-Step "Install Claude Code CLI (native installer — no npm dependency)"
Invoke-RestMethod "https://claude.ai/install.ps1" | Invoke-Expression
$env:Path = "$env:LOCALAPPDATA\Programs\ClaudeCode;$env:Path"
claude --version

Write-Step "Install RTK"
$RtkTag = (Invoke-RestMethod "https://api.github.com/repos/rtk-ai/rtk/releases/latest").tag_name
$RtkZip = "rtk-x86_64-pc-windows-msvc.zip"
$RtkUrl = "https://github.com/rtk-ai/rtk/releases/download/$RtkTag/$RtkZip"
$RtkTemp = "$env:TEMP\rtk.zip"
$RtkInstallDir = "$env:LOCALAPPDATA\Programs\rtk"

Invoke-WebRequest $RtkUrl -OutFile $RtkTemp
New-Item -ItemType Directory -Force $RtkInstallDir | Out-Null
Expand-Archive -Path $RtkTemp -DestinationPath $RtkInstallDir -Force
Remove-Item $RtkTemp -Force

$UserPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
$PathParts = $UserPath -split ';' | Where-Object { $_ -ne '' }
if ($PathParts -notcontains $RtkInstallDir) {
    [System.Environment]::SetEnvironmentVariable("PATH", ($PathParts + $RtkInstallDir -join ';'), "User")
}
$env:PATH = "$env:PATH;$RtkInstallDir"

rtk init -g
rtk --version

Write-Step "Clone himmel + run repo setup"
$HimmelParent = Split-Path $HimmelPath -Parent
New-Item -ItemType Directory -Force $HimmelParent | Out-Null
git clone https://github.com/yotamleo/Himmel.git $HimmelPath
Push-Location $HimmelPath

# HIMMEL-105: gate the clone for core.hooksPath misconfiguration BEFORE
# running pre-commit install (inside setup.ps1). See comment in ubuntu.sh
# for context. $ErrorActionPreference='Stop' at the top of this script
# means a nonzero exit from check-hookspath.ps1 aborts setup.
pwsh -NoProfile -File ".\scripts\hooks\check-hookspath.ps1"
if ($LASTEXITCODE -ne 0) {
    throw "check-hookspath.ps1 failed (exit $LASTEXITCODE) — refusing to run setup.ps1 on a misconfigured clone."
}

.\scripts\setup.ps1
Pop-Location

Write-Step "Build scripts/jira/dist + scripts/himmel-run/dist"
Push-Location (Join-Path $HimmelPath 'scripts/jira')
npm ci
npm run build
Pop-Location
Push-Location (Join-Path $HimmelPath 'scripts/himmel-run')
npm ci
npm run build
Pop-Location

Write-Step "Add himmel-run to user PATH"
$BinDir = Join-Path $HimmelPath 'scripts/himmel-run/bin'
$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($UserPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$UserPath;$BinDir", 'User')
    Write-Host "Added $BinDir to user PATH (restart shell to pick up)"
} else {
    Write-Host "himmel-run/bin already in user PATH"
}

# ── Non-fatal steps (9–16) ──────────────────────────────────────────────────
# statusline is vendored at $HimmelPath\scripts\statusline (HIMMEL-331) — no clone needed.

Write-Step "Copy Claude config"
Invoke-NonFatal "copy Claude config" {
    New-Item -ItemType Directory -Force $ClaudeDir | Out-Null
    Copy-Item "$HimmelPath\docs\setup\global-claude-md.md" "$ClaudeDir\CLAUDE.md" -Force
    Copy-Item "$HimmelPath\docs\setup\rtk-md.md" "$ClaudeDir\RTK.md" -Force
}

Write-Step "Install obsidian-second-brain skill"
Invoke-NonFatal "obsidian-second-brain plugin" {
    $PluginsDir = "$ClaudeDir\plugins"
    New-Item -ItemType Directory -Force $PluginsDir | Out-Null
    git clone https://github.com/eugeniughelbur/obsidian-second-brain.git `
        "$PluginsDir\obsidian-second-brain"
    $GitBash = "C:\Program Files\Git\bin\bash.exe"
    Push-Location "$PluginsDir\obsidian-second-brain"
    try {
        & $GitBash -c "./install.sh"
    } finally {
        Pop-Location
    }
}

Write-Step "Rewrite git@github.com SSH URLs to HTTPS (public-repo clone fix)"
Invoke-NonFatal "git insteadOf" {
    # Some marketplaces (e.g. claude-obsidian) declare plugin sources with
    # `git@github.com:` URLs. Public repos clone fine over HTTPS — only the
    # URL form requires an SSH key. Rewrite globally so `claude plugin
    # install` succeeds without configuring a GitHub deploy key.
    $existing = git config --global --get-all url."https://github.com/".insteadOf 2>$null
    if ($existing -notcontains 'git@github.com:') {
        git config --global --add url."https://github.com/".insteadOf 'git@github.com:'
        Write-Host '  added: git insteadOf rule'
    } else {
        Write-Host '  already configured'
    }
}

Write-Step "Install Claude plugins from manifest"
# Scope choice: user = ~/.claude (every project); project = this repo's
# .claude/settings.json (shared on clone). The third scope `local` is
# reachable only via install-plugins.ps1 -Scope local, not this prompt.
# Empty input keeps the user default.
$scopeRaw = Read-Host "Install plugins at [u]ser scope (all projects) or [p]roject scope (this repo only)? [default: user]"
$PluginScope = if (-not [string]::IsNullOrWhiteSpace($scopeRaw) -and $scopeRaw.Trim() -match '^[Pp]') { 'project' } else { 'user' }
Write-Host "  -> installing at $PluginScope scope"
Invoke-NonFatal "install plugins from manifest" {
    & pwsh -NoProfile -File "$HimmelPath\scripts\machine-setup\install-plugins.ps1" `
        -Scope $PluginScope -HimmelPath $HimmelPath
}

Invoke-NonFatal "caveman Windows patch" {
    $CavemanScript = "$ClaudeDir\plugins\marketplaces\caveman\src\mcp-servers\caveman-shrink\index.js"
    if (Test-Path $CavemanScript) {
        $content = Get-Content $CavemanScript -Raw
        if ($content -notlike "*shell: true*") {
            $old = "stdio: ['pipe', 'pipe', 'inherit'],`r`n  });"
            $new = "stdio: ['pipe', 'pipe', 'inherit'],`r`n    shell: true,`r`n  });"
            $content.Replace($old, $new) | Set-Content $CavemanScript -NoNewline
            Write-Host "  Applied caveman shell:true patch"
        } else {
            Write-Host "  Caveman patch already applied"
        }
    } else {
        Write-Host "  Caveman not yet pulled — run claude once to trigger plugin pull, then re-run script"
    }
}

Write-Step "Clone Luna vault + install pre-commit hooks"
Invoke-NonFatal "Luna vault setup" {
    $LunaParent = Split-Path $LunaVaultPath -Parent
    New-Item -ItemType Directory -Force $LunaParent | Out-Null

    # Migrate legacy double-nested layout: $LunaVaultPath\luna\.git but no
    # $LunaVaultPath\.git. Previous versions of this script cloned to
    # Documents\luna\luna which left Obsidian opening the empty wrapper
    # Documents\luna\ instead of the real vault. Move repo contents up.
    $NestedGit  = Join-Path $LunaVaultPath 'luna\.git'
    $OuterGit   = Join-Path $LunaVaultPath '.git'
    if ((Test-Path $NestedGit) -and -not (Test-Path $OuterGit)) {
        Write-Host '  migrating double-nested luna\luna -> luna'
        $WrapperObsidian = Join-Path $LunaVaultPath '.obsidian'
        if (Test-Path $WrapperObsidian) {
            $Backup = "$WrapperObsidian.wrapper-backup.$(Get-Date -UFormat %s)"
            Rename-Item -Path $WrapperObsidian -NewName (Split-Path $Backup -Leaf)
        }
        $Inner = Join-Path $LunaVaultPath 'luna'
        Get-ChildItem -Path $Inner -Force | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $LunaVaultPath
        }
        Remove-Item -Path $Inner -Force
    }

    if (Test-Path (Join-Path $LunaVaultPath '.git')) {
        Write-Host '  luna vault already present - skipping clone'
    } else {
        git clone $LunaRemote $LunaVaultPath
    }

    Push-Location $LunaVaultPath
    try {
        uv tool install pre-commit
        pre-commit install
        pre-commit install --hook-type pre-push
    } finally {
        Pop-Location
    }
}

Write-Step "Patch ~/.claude/settings.json"
Invoke-NonFatal "patch settings.json" {
    $NodePath = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not $NodePath) { $NodePath = "C:\Program Files\nodejs\node.exe" }

    $SettingsFile = "$ClaudeDir\settings.json"
    $TemplatePath = "$HimmelPath\docs\setup\settings-template.json"
    $Template = Get-Content $TemplatePath -Raw | ConvertFrom-Json

    # statusLine is wired separately via scripts/lib/wire-statusline.ps1 after
    # this patch (HIMMEL-359) — single source of truth, so it is NOT set here.
    $Template | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{
        "obsidian-vault" = [PSCustomObject]@{
            command = "uvx"
            args    = @("mcp-obsidian", $LunaVaultPath)
        }
    }) -Force

    $himmelMarketplace = [PSCustomObject]@{
        source = [PSCustomObject]@{ source = "directory"; path = "$HimmelPath\marketplace" }
    }
    $Template.extraKnownMarketplaces | Add-Member -NotePropertyName "himmel" `
        -NotePropertyValue $himmelMarketplace -Force

    # HIMMEL-105: guard against silent regression — if a future template
    # refactor removes or reshapes .hooks.SessionStart[0].hooks, the append
    # below would clobber the caveman-activate SessionStart entry without
    # surfacing any error (PowerShell null property access returns $null
    # silently, and `@($null) + entry` would still produce a 1-element
    # array, hiding the loss). Assert the expected pre-patch shape first;
    # throw loudly on mismatch so Invoke-NonFatal logs a clear failure.
    if (-not $Template.hooks -or
        -not $Template.hooks.SessionStart -or
        $Template.hooks.SessionStart.Count -lt 1 -or
        -not ($Template.hooks.SessionStart[0].hooks -is [System.Array])) {
        throw "settings-template.json missing .hooks.SessionStart[0].hooks (expected array) — refusing to patch (would clobber existing entries)"
    }

    $ups = $Template.hooks.UserPromptSubmit[0].hooks[0].command
    $ss  = $Template.hooks.SessionStart[0].hooks[0].command
    $Template.hooks.UserPromptSubmit[0].hooks[0].command = `
        $ups -replace '<node-path>', $NodePath -replace '<claude-dir>', $ClaudeDir
    $Template.hooks.SessionStart[0].hooks[0].command = `
        $ss  -replace '<node-path>', $NodePath -replace '<claude-dir>', $ClaudeDir

    # HIMMEL-105: append the check-hookspath.ps1 SessionStart entry. Only
    # the pwsh entry is registered on Windows — the bash sibling would
    # fail with "bash: command not found" every session start on machines
    # without Git Bash on PATH, logging a confusing warning. The Linux
    # path adds the bash entry via ubuntu.sh; the cross-platform template
    # carries neither so each setup script can register the right one.
    $himmelFwd = $HimmelPath.Replace('\', '/')
    $psHookspathEntry = [PSCustomObject]@{
        type    = 'command'
        command = "pwsh -NoProfile -File `"$himmelFwd/scripts/hooks/check-hookspath.ps1`""
        shell   = 'powershell'
        timeout = 10
    }
    # Append to the existing SessionStart[0].hooks array (the caveman one).
    $existingHooks = @($Template.hooks.SessionStart[0].hooks) + $psHookspathEntry
    $Template.hooks.SessionStart[0].hooks = $existingHooks

    # HIMMEL-264: resolve <himmel-path> placeholders the template carries
    # in PreToolUse commands (the rtk-hook-guard entry) so a freshly
    # written settings.json never holds a dangling placeholder.
    foreach ($group in @($Template.hooks.PreToolUse)) {
        foreach ($h in @($group.hooks)) {
            if ($h.command -like '*<himmel-path>*') {
                $h.command = $h.command.Replace('<himmel-path>', $himmelFwd)
            }
        }
    }

    # Strip SessionEnd from the template — the next step ("Configure end-session-wiki
    # SessionEnd hook") owns that key end-to-end and prompts the user for the right
    # interpreter subset. Writing placeholder commands here would leave dangling
    # `<himmel-path>` strings if the user skips that step.
    if ($Template.hooks.PSObject.Properties.Name -contains 'SessionEnd') {
        $Template.hooks.PSObject.Properties.Remove('SessionEnd')
    }

    if (Test-Path $SettingsFile) {
        # Shallow merge — existing top-level keys win on conflict (idempotent re-runs).
        # Nested objects (hooks, mcpServers) are NOT deep-merged: if existing settings.json
        # has a `hooks` key, the patch's `hooks` is dropped entirely. Acceptable for a
        # setup script where settings.json is typically absent on first run.
        $existing = Get-Content $SettingsFile -Raw
        $mergedObj = $Template | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        ($existing | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $mergedObj | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value -Force
        }
        Write-SettingsJson $SettingsFile $mergedObj
    } else {
        Write-SettingsJson $SettingsFile $Template
    }

    # statusLine via the shared helper (HIMMEL-359) — runs after the write so it
    # is authoritative and refreshes any stale path on idempotent re-runs.
    & pwsh -NoProfile -File "$HimmelPath\scripts\lib\wire-statusline.ps1" `
        -SettingsPath $SettingsFile -HimmelPath $HimmelPath
    # Surface a helper failure so the enclosing Invoke-NonFatal logs it (parity
    # with ubuntu.sh's `|| fail_nonfatal`); native exit codes don't auto-throw.
    if ($LASTEXITCODE -ne 0) { throw "wire-statusline failed (exit $LASTEXITCODE)" }
}

Write-Step "Configure end-session-wiki SessionEnd hook"
Invoke-NonFatal "register SessionEnd hook" {
    $SettingsFile = "$ClaudeDir\settings.json"
    $HooksRoot    = "$HimmelPath\scripts\hooks"
    $PsHookPath   = "$HooksRoot\end-session-wiki.ps1"
    $ShHookPath   = ($HooksRoot.Replace('\', '/')) + "/end-session-wiki.sh"

    if (-not (Test-Path $PsHookPath)) {
        throw "Hook script not found: $PsHookPath — clone himmel first"
    }

    # Prompt for interpreter subset (default Both)
    $promptMsg = "Register SessionEnd hook for end-session-wiki? " +
                 "[P]owerShell only, [B]ash only (Git Bash), Both, [S]kip [default: Both]"
    $choiceRaw = Read-Host $promptMsg
    if ([string]::IsNullOrWhiteSpace($choiceRaw)) { $choiceRaw = 'Both' }
    switch -Regex ($choiceRaw.Trim()) {
        '^[Pp]'           { $choice = 'PowerShell' }
        '^[Bb]'           { $choice = 'Bash' }
        '^[Ss]'           { $choice = 'Skip' }
        '^([Oo]|[Bb]oth)' { $choice = 'Both' }
        default           { $choice = 'Both' }
    }

    if ($choice -eq 'Skip') {
        Write-Host "  Skipped SessionEnd registration. Re-run this script or edit $SettingsFile manually."
        return
    }

    # Build the hook entries the user picked
    $hookEntries = @()
    if ($choice -eq 'PowerShell' -or $choice -eq 'Both') {
        $hookEntries += [PSCustomObject]@{
            type    = 'command'
            command = "pwsh -NoProfile -File `"$PsHookPath`""
            shell   = 'powershell'
            timeout = 30
        }
    }
    if ($choice -eq 'Bash' -or $choice -eq 'Both') {
        $hookEntries += [PSCustomObject]@{
            type    = 'command'
            command = "bash `"$ShHookPath`""
            shell   = 'bash'
            timeout = 30
        }
    }

    # Read existing settings.json (must exist — the previous step created it)
    if (-not (Test-Path $SettingsFile)) {
        throw "Settings file missing: $SettingsFile — patch settings.json step did not run"
    }
    $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json

    # Ensure hooks key exists
    if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
        $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    # Decide what to do if SessionEnd already configured
    $existingSessionEnd = $null
    if ($settings.hooks.PSObject.Properties.Name -contains 'SessionEnd') {
        $existingSessionEnd = $settings.hooks.SessionEnd
    }

    $action = 'Overwrite'
    if ($existingSessionEnd) {
        $existPrompt = "SessionEnd already configured. [O]verwrite / [A]ppend / [S]kip [default: Skip]"
        $existRaw = Read-Host $existPrompt
        if ([string]::IsNullOrWhiteSpace($existRaw)) { $existRaw = 'Skip' }
        switch -Regex ($existRaw.Trim()) {
            '^[Oo]' { $action = 'Overwrite' }
            '^[Aa]' { $action = 'Append' }
            '^[Ss]' { $action = 'Skip' }
            default { $action = 'Skip' }
        }
    }

    if ($action -eq 'Skip') {
        Write-Host "  Skipped: existing SessionEnd preserved as-is."
        return
    }

    # Backup before any write
    $ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $BackupFile = "$SettingsFile.bak.$ts"
    Copy-Item $SettingsFile $BackupFile -Force
    Write-Host "  Backed up: $BackupFile"

    # Build the new SessionEnd array
    if ($action -eq 'Append' -and $existingSessionEnd) {
        # Append a new top-level matcher group with our hooks
        $merged = @()
        $merged += $existingSessionEnd
        $merged += [PSCustomObject]@{ hooks = $hookEntries }
        $newSessionEnd = $merged
    } else {
        # Overwrite (or no prior entry): single matcher group
        $newSessionEnd = @( [PSCustomObject]@{ hooks = $hookEntries } )
    }

    # Patch settings.hooks.SessionEnd
    if ($settings.hooks.PSObject.Properties.Name -contains 'SessionEnd') {
        $settings.hooks.SessionEnd = $newSessionEnd
    } else {
        $settings.hooks | Add-Member -NotePropertyName 'SessionEnd' -NotePropertyValue $newSessionEnd -Force
    }

    Write-SettingsJson $SettingsFile $settings

    Write-Host "  Registered SessionEnd: $choice. Hook scripts at: $HooksRoot"
}

Write-Step "Register auto-arm-on-cap PreToolUse hook (HIMMEL-220)"
Invoke-NonFatal "register auto-arm hook" {
    # User-level registration so EVERY repo's sessions get cap protection
    # (the himmel checkout carries its own project-level wiring in
    # .claude/settings.json; this covers luna / yotam_docs / etc).
    # The hook resolves its lib + arm-resume relative to its own location,
    # so an absolute himmel path works from any cwd. Runs via Git Bash.
    $SettingsFile = "$ClaudeDir\settings.json"
    $ArmHookPath  = ("$HimmelPath\scripts\hooks".Replace('\', '/')) + "/auto-arm-on-cap.sh"

    if (-not (Test-Path "$HimmelPath\scripts\hooks\auto-arm-on-cap.sh")) {
        throw "Hook script not found: $HimmelPath\scripts\hooks\auto-arm-on-cap.sh — clone himmel first"
    }
    if (-not (Test-Path $SettingsFile)) {
        throw "Settings file missing: $SettingsFile — patch settings.json step did not run"
    }

    $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
    if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
        $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    # Idempotent: skip if any PreToolUse command already references the hook.
    $already = $false
    if ($settings.hooks.PSObject.Properties.Name -contains 'PreToolUse') {
        foreach ($group in @($settings.hooks.PreToolUse)) {
            foreach ($h in @($group.hooks)) {
                if ($h.command -like '*auto-arm-on-cap.sh*') { $already = $true }
            }
        }
    }
    if ($already) {
        Write-Host "  Already registered — skipping (idempotent)."
        return
    }

    $promptMsg = "Register auto-arm-on-cap PreToolUse hook (auto-arms a resume at 90% usage)? [Y]es/[n]o [default: Y]"
    $choiceRaw = Read-Host $promptMsg
    if ([string]::IsNullOrWhiteSpace($choiceRaw)) { $choiceRaw = 'Y' }
    if ($choiceRaw.Trim() -match '^[Nn]') {
        Write-Host "  Skipped auto-arm registration. Re-run this script or edit $SettingsFile manually."
        return
    }

    $ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $SettingsFile "$SettingsFile.bak.$ts" -Force
    Write-Host "  Backed up: $SettingsFile.bak.$ts"

    $armEntry = [PSCustomObject]@{
        matcher = '*'
        hooks   = @([PSCustomObject]@{ type = 'command'; command = "bash `"$ArmHookPath`"" })
    }
    if ($settings.hooks.PSObject.Properties.Name -contains 'PreToolUse') {
        $settings.hooks.PreToolUse = @($settings.hooks.PreToolUse) + $armEntry
    } else {
        $settings.hooks | Add-Member -NotePropertyName 'PreToolUse' -NotePropertyValue @($armEntry) -Force
    }

    Write-SettingsJson $SettingsFile $settings
    Write-Host "  Registered auto-arm-on-cap (PreToolUse, matcher *). Hook script at: $ArmHookPath"
    Write-Host "  Kill switch: AUTO_ARM_DISABLE=1 in the launching shell."
}

Write-Step "Swap rtk hook for rtk-hook-guard wrapper (HIMMEL-241)"
Invoke-NonFatal "swap rtk hook for guard" {
    # `rtk init -g` registers bare `rtk hook claude`, which rewrites
    # `find ...` to `rtk find ...` — but `rtk find` rejects compound
    # predicates (-not/-exec/...), silently breaking every LUNA runbook
    # scan. rtk-hook-guard.sh delegates to rtk and passes compound finds
    # through unrewritten; everything else keeps the rtk rewrite.
    $SettingsFile = "$ClaudeDir\settings.json"
    $GuardPath    = ("$HimmelPath\scripts\hooks".Replace('\', '/')) + "/rtk-hook-guard.sh"

    if (-not (Test-Path "$HimmelPath\scripts\hooks\rtk-hook-guard.sh")) {
        throw "Hook script not found: $HimmelPath\scripts\hooks\rtk-hook-guard.sh — clone himmel first"
    }
    if (-not (Test-Path $SettingsFile)) {
        throw "Settings file missing: $SettingsFile — patch settings.json step did not run"
    }

    $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json

    # Distinguish "no PreToolUse key at all" from "key present but no rtk
    # entry" — the old code printed the misleading "No 'rtk hook claude'
    # entry found" for both (HIMMEL-264).
    if (-not (($settings.PSObject.Properties.Name -contains 'hooks') -and
              ($settings.hooks.PSObject.Properties.Name -contains 'PreToolUse'))) {
        Write-Host "  No hooks.PreToolUse in settings.json — skipping (did rtk init -g run?)."
        return
    }

    # Swap EVERY bare `rtk hook claude` entry (extra flags included) —
    # even when a guard entry already exists (a re-run of `rtk init -g`
    # after a swap re-adds a raw entry the old guard-presence early-exit
    # never replaced; HIMMEL-264).
    $guardPresent = $false
    $swapped = 0
    foreach ($group in @($settings.hooks.PreToolUse)) {
        foreach ($h in @($group.hooks)) {
            if ($h.command -like '*rtk-hook-guard.sh*') {
                $guardPresent = $true
            } elseif ($h.command -match '^\s*rtk\s+hook\s+claude(\s|$)') {
                $h.command = "bash `"$GuardPath`""
                $swapped++
            }
        }
    }
    if ($swapped -eq 0) {
        if ($guardPresent) {
            Write-Host "  Already swapped — skipping (idempotent)."
        } else {
            Write-Host "  No 'rtk hook claude' entry found — skipping (did rtk init -g run?)."
        }
        return
    }

    $ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item $SettingsFile "$SettingsFile.bak.$ts" -Force
    Write-Host "  Backed up: $SettingsFile.bak.$ts"

    Write-SettingsJson $SettingsFile $settings
    Write-Host "  Swapped $swapped 'rtk hook claude' entry(s) -> bash $GuardPath"
}

Write-Step "Install Obsidian + open vault"
Invoke-NonFatal "Obsidian install" {
    $ver = (Invoke-RestMethod "https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest").tag_name
    $verNum = $ver.TrimStart('v')
    $url = "https://github.com/obsidianmd/obsidian-releases/releases/download/$ver/Obsidian-$verNum.exe"
    $installer = "$env:TEMP\Obsidian-setup.exe"
    Invoke-WebRequest $url -OutFile $installer
    Start-Process $installer -ArgumentList "/S" -Wait
    Remove-Item $installer -Force
    Start-Process "obsidian://open?vault=luna"
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════"
Write-Host "SETUP COMPLETE"
Write-Host "════════════════════════════════════════"
if ($Script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Non-fatal failures:"
    $Script:Failures | ForEach-Object { Write-Host "  - $_" }
}
Write-Host ""
Write-Host "MANUAL STEPS REMAINING:"
Write-Host "  1. Fill JIRA_API_TOKEN in $HimmelPath\.env"
Write-Host "  2. Configure Atlassian MCP token in $ClaudeDir\settings.json"
Write-Host "  3. Run qmd embed inside Claude Code (himmel project)"
Write-Host "  4. Verify: rtk --version | rtk gain | jira list | claude /obsidian-daily"
