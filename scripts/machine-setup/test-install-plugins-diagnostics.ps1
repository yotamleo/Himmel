# test-install-plugins-diagnostics.ps1 — install-plugins.ps1 surfaces a real
# step failure LOUDLY (with the CLI's own output) and exits non-zero via the
# presence-verify, while a benign "already installed" re-run stays exit 0.
# PowerShell twin of test-install-plugins-diagnostics.sh (HIMMEL-438 — C2).
# Keep in lockstep with the .sh when changing either.
#
# Run: pwsh -NoProfile -File scripts/machine-setup/test-install-plugins-diagnostics.ps1

$ErrorActionPreference = 'Continue'
$script:Failed = 0
$Cli = Join-Path $PSScriptRoot 'install-plugins.ps1'

if (-not $IsWindows) {
    Write-Host 'SKIP: not Windows — the claude.cmd stub needs cmd.exe'
    Write-Host 'PASS (skipped)'
    exit 0
}

function Assert-Rc {
    param([string]$Label, [int]$Expected, [int]$Actual)
    if ($Actual -eq $Expected) { Write-Host "PASS $Label (rc=$Actual)" }
    else { Write-Host "FAIL $Label -- expected rc=$Expected, got rc=$Actual"; $script:Failed++ }
}
function Assert-Has {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) { Write-Host "PASS $Label" }
    else { Write-Host "FAIL $Label -- output missing: $Needle"; $script:Failed++ }
}
function Assert-Lacks {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) { Write-Host "FAIL $Label -- output unexpectedly contains: $Needle"; $script:Failed++ }
    else { Write-Host "PASS $Label" }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('himmel-plugindiag-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Tmp | Out-Null
$StubDir = Join-Path $Tmp 'bin'
New-Item -ItemType Directory -Force $StubDir | Out-Null

# autoUpdate:false → the script never patches a real settings.json.
$Template = Join-Path $Tmp 'settings-template.json'
@'
{
  "enabledPlugins": { "foo@mp": true },
  "extraKnownMarketplaces": { "mp": { "source": { "source": "github", "repo": "x/y" }, "autoUpdate": false } }
}
'@ | Set-Content -Path $Template

# Stub claude.cmd: marketplace add → ok; install → env-driven (FAIL/BENIGN);
# list → echo $Present. goto labels (NOT paren blocks): `exit /b N` inside an
# `if (...)` block does not propagate errorlevel in cmd.exe.
function Set-Stub {
    param([string[]]$Present)
    $lines = @(
        '@echo off',
        'if not "%1"=="plugin" exit /b 0',
        'if "%2"=="marketplace" exit /b 0',
        'if "%2"=="install" goto :install',
        'if "%2"=="list" goto :list',
        'exit /b 0',
        ':install',
        'if defined STUB_INSTALL_FAIL goto :installfail',
        'if defined STUB_INSTALL_BENIGN goto :installbenign',
        'exit /b 0',
        ':installfail',
        'echo error: failed to clone marketplace: network unreachable 1>&2',
        'exit /b 1',
        ':installbenign',
        'echo Plugin already installed',
        'exit /b 1',
        ':list'
    )
    foreach ($p in $Present) { $lines += "echo   $p" }
    $lines += 'exit /b 0'
    Set-Content -Path (Join-Path $StubDir 'claude.cmd') -Value $lines
}

$Pwsh = (Get-Command pwsh).Source
$SavedPath = $env:PATH

function Invoke-Install {
    $out = (& $Pwsh -NoProfile -File $Cli -Template $Template -Scope user 2>&1 | Out-String)
    $script:Rc = $LASTEXITCODE
    return $out
}

try {
    $env:PATH = "$StubDir;$env:PATH"

    # 1. real install failure → loud diagnostics + non-zero (verify misses foo)
    Set-Stub @()
    $env:STUB_INSTALL_FAIL = '1'; Remove-Item Env:STUB_INSTALL_BENIGN -ErrorAction SilentlyContinue
    $out = Invoke-Install
    Assert-Rc   'real failure exits non-zero' 1 $script:Rc
    Assert-Has  'real failure prints loud marker' 'step FAILED' $out
    Assert-Has  'real failure surfaces CLI text' 'network unreachable' $out

    # 2. benign already-installed + present in list → quiet + exit 0
    Set-Stub @('foo@mp')
    Remove-Item Env:STUB_INSTALL_FAIL -ErrorAction SilentlyContinue; $env:STUB_INSTALL_BENIGN = '1'
    $out = Invoke-Install
    Assert-Rc    'benign re-run exits 0' 0 $script:Rc
    Assert-Has   'benign prints quiet marker' 'already present' $out
    Assert-Lacks 'benign does not print step FAILED' 'step FAILED' $out
}
finally {
    $env:PATH = $SavedPath
    Remove-Item Env:STUB_INSTALL_FAIL, Env:STUB_INSTALL_BENIGN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

if ($script:Failed -gt 0) { Write-Host "`n$($script:Failed) assertion(s) FAILED"; exit 1 }
Write-Host "`nPASS"
exit 0
