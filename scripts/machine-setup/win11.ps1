#Requires -RunAsAdministrator
param(
    [string]$LunaRemote = ""
)

$ErrorActionPreference = 'Stop'

# CR r2 (HIMMEL-887): fail CLOSED on -LunaRemote BEFORE any provisioning.
# The old script cloned the remote vault itself; the delegated himmelctl flow
# does not support remote-vault restore yet (HIMMEL-755 scope), so accepting
# the flag and silently dropping it would let a machine rebuild complete
# WITHOUT the operator's vault.
if ($LunaRemote) {
    Write-Error -ErrorAction Continue "-LunaRemote is not supported by the delegated himmelctl flow yet (HIMMEL-755)."
    Write-Error -ErrorAction Continue "  Clone the vault manually first:  git clone $LunaRemote `"$env:USERPROFILE\Documents\luna`""
    Write-Error -ErrorAction Continue "  then re-run this script WITHOUT -LunaRemote."
    exit 1
}

# ── Paths ───────────────────────────────────────────────────────────────────
$HimmelPath     = "$env:USERPROFILE\Documents\github\himmel"
$RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# ── Progress ────────────────────────────────────────────────────────────────
$TotalSteps = 8
$Script:Step = 0

function Write-Step($msg) {
    $Script:Step++
    Write-Host ""
    Write-Host "══════════════════════════════════════════════"
    Write-Host "[$($Script:Step)/$TotalSteps] $msg"
    Write-Host "══════════════════════════════════════════════"
}

# Invoke-Fatal: runs $block and throws (aborting the script, $ErrorActionPreference
# = 'Stop') if the LAST native call inside it left a nonzero $LASTEXITCODE. Wrap
# ONE native call per invocation (as done throughout the steps below) to get a
# check per call.
function Invoke-Fatal([string]$label, [scriptblock]$block) {
    $global:LASTEXITCODE = 0
    & $block
    if ($LASTEXITCODE -ne 0) { throw "$label failed (exit $LASTEXITCODE)" }
}

# ── Steps (1–8) ─────────────────────────────────────────────────────────────
Write-Step "Update package manager"
Invoke-Fatal "winget upgrade --all" { winget upgrade --all --silent --accept-source-agreements --accept-package-agreements }

Write-Step "Install core tools: git, Node LTS, Python, jq, shellcheck, gitleaks"
# shellcheck + gitleaks are referenced directly by .pre-commit-config.yaml hooks;
# pre-commit downloads its own binaries inside the hook framework, but local
# direct invocation (manual lint runs, smoke tests) needs them on PATH.
Invoke-Fatal "winget install Git.Git" { winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements }
Invoke-Fatal "winget install OpenJS.NodeJS.LTS" { winget install --id OpenJS.NodeJS.LTS -e --silent --accept-source-agreements --accept-package-agreements }
Invoke-Fatal "winget install Python.Python.3" { winget install --id Python.Python.3 -e --silent --accept-source-agreements --accept-package-agreements }
Invoke-Fatal "winget install jqlang.jq" { winget install --id jqlang.jq -e --silent --accept-source-agreements --accept-package-agreements }
Invoke-Fatal "winget install koalaman.shellcheck" { winget install --id koalaman.shellcheck -e --silent --accept-source-agreements --accept-package-agreements }
Invoke-Fatal "winget install Gitleaks.Gitleaks" { winget install --id Gitleaks.Gitleaks -e --silent --accept-source-agreements --accept-package-agreements }

# Refresh PATH for current session after winget installs
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")

Write-Step "Install nvm-windows + Node from .nvmrc"
if (-not (Get-Command nvm.exe -ErrorAction SilentlyContinue)) {
    Invoke-Fatal "winget install CoreyButler.NVMforWindows" { winget install --id CoreyButler.NVMforWindows -e --silent --accept-package-agreements --accept-source-agreements }
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
Invoke-Fatal "nvm install $NodeVersion" { nvm install $NodeVersion }
Invoke-Fatal "nvm use $NodeVersion" { nvm use $NodeVersion }
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
Invoke-Fatal "uv --version" { uv --version }

Write-Step "Install Claude Code CLI (native installer — no npm dependency)"
Invoke-RestMethod "https://claude.ai/install.ps1" | Invoke-Expression
$env:Path = "$env:LOCALAPPDATA\Programs\ClaudeCode;$env:Path"
Invoke-Fatal "claude --version" { claude --version }

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

Invoke-Fatal "rtk init -g" { rtk init -g }
Invoke-Fatal "rtk --version" { rtk --version }

Write-Step "Clone himmel repo"
$HimmelParent = Split-Path $HimmelPath -Parent
New-Item -ItemType Directory -Force $HimmelParent | Out-Null
Invoke-Fatal "git clone himmel" { git clone https://github.com/yotamleo/himmel.git $HimmelPath }
Push-Location $HimmelPath

# HIMMEL-105: gate the clone for core.hooksPath misconfiguration BEFORE any
# further tooling runs. See comment in ubuntu.sh for context.
# $ErrorActionPreference='Stop' at the top of this script means a nonzero
# exit from check-hookspath.ps1 aborts setup.
pwsh -NoProfile -File ".\scripts\hooks\check-hookspath.ps1"
if ($LASTEXITCODE -ne 0) {
    throw "check-hookspath.ps1 failed (exit $LASTEXITCODE) — refusing to continue on a misconfigured clone."
}
Pop-Location

Write-Step "Delegate himmel/luna wiring to himmelctl bootstrap (HIMMEL-887)"
# HIMMEL-887: this script is soft-deprecated for himmel/luna WIRING — the
# provisioning above (steps 1-6, full toolchain) is unchanged and stays the
# source of truth (locked decision O4: zero capability loss). Wiring (Claude
# config, plugins, luna vault, settings.json patching, hooks registration, …)
# now runs via `himmelctl bootstrap`, which re-execs into `himmelctl install`
# once node is confirmed present (it always is here — step 3 just installed
# it) — one wiring implementation instead of two drifting copies. Hard-remove
# of this now-deprecated shim script itself (once its toolchain-provisioning
# role is also absorbed) is deferred to the HIMMEL-755 fork.
# (-LunaRemote fail-closes at the top of the script — CR r2 — so no
# remote-vault handling is needed here.)
#
# CR r4: delegate FROM the himmel clone, not from wherever the operator
# launched this shim. The wizard's role/scope inference reads the CWD's git
# origin, and scope=project wires .claude into the CWD — delegating from the
# launch directory would target the WRONG repo. The wizard is interactive by
# design: an unattended/non-TTY run fails loud with remediation (documented
# posture); this Set-Location only guarantees that when it DOES run, its
# inference targets the himmel clone deterministically.
Write-Host "NOTICE: himmel/luna wiring in this script is soft-deprecated (HIMMEL-887) -- delegating to himmelctl bootstrap. Hard-remove deferred to HIMMEL-755."
Set-Location $HimmelPath
# Pin HIMMELCTL_REPO_ROOT to this clone so a stale inherited value can't
# redirect the bootstrap hand-off at a different repo's bin.js (HIMMEL-935 / CR #1126).
$env:HIMMELCTL_REPO_ROOT = $HimmelPath
& (Join-Path $HimmelPath 'scripts\himmelctl\bootstrap.ps1')
exit $LASTEXITCODE
