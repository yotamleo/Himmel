# test-onboard-warp.ps1 — PowerShell smoke test for scripts/setup/onboard-warp.ps1
# (HIMMEL-360; PS sibling of test-onboard-warp.sh). Runs against a controlled
# $env:WARP_EXE + a minimal $env:PATH so the result never depends on whether
# Warp is actually installed on the test machine.
#
# Run: pwsh -NoProfile -File scripts/setup/test-onboard-warp.ps1

$ErrorActionPreference = 'Continue'
$script:Failed = 0
$Cli = Join-Path $PSScriptRoot 'onboard-warp.ps1'

function Assert-Rc {
    param([string]$Label, [int]$Expected, [int]$Actual)
    if ($Actual -eq $Expected) {
        Write-Host "PASS $Label (rc=$Actual)"
    } else {
        Write-Host "FAIL $Label -- expected rc=$Expected, got rc=$Actual"
        $script:Failed++
    }
}

function Assert-Has {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) {
        Write-Host "PASS $Label"
    } else {
        Write-Host "FAIL $Label -- output missing: $Needle"
        $script:Failed++
    }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('himmel-warp-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Tmp | Out-Null

# Resolve pwsh by full path so a minimized $env:PATH can't hide it from the
# child invocation.
$Pwsh = (Get-Command pwsh).Source
# Minimal PATH that (almost certainly) has no `warp`, so Get-Command warp is
# deterministic. System32 covers what `pwsh -File` needs.
$MinPath = Join-Path $env:SystemRoot 'System32'

$SavedPath    = $env:PATH
$SavedWarpExe = $env:WARP_EXE

function Invoke-Warp {
    $out = (& $Pwsh -NoProfile -File $Cli 2>&1 | Out-String)
    $script:Rc = $LASTEXITCODE
    return $out
}

try {
    # 1. binary MISSING: WARP_EXE points nowhere, warp not on PATH
    $env:PATH = $MinPath
    $env:WARP_EXE = Join-Path $Tmp 'none.exe'
    $out = Invoke-Warp
    Assert-Rc 'missing run exits 0' 0 $script:Rc
    Assert-Has 'missing run reports MISSING' 'warp binary: MISSING' $out
    Assert-Has 'missing run prints skills line' '/open-warp' $out
    Assert-Has 'missing run prints plugin line' 'warp@claude-code-warp' $out

    # 2. binary present via WARP_EXE (not on PATH)
    $warpExe = Join-Path $Tmp 'warp.exe'
    Set-Content -Path $warpExe -Value '' -NoNewline
    $env:PATH = $MinPath
    $env:WARP_EXE = $warpExe
    $out = Invoke-Warp
    Assert-Rc 'WARP_EXE run exits 0' 0 $script:Rc
    Assert-Has 'WARP_EXE run reports the path' $warpExe $out

    # 3. binary present on PATH takes precedence over WARP_EXE
    $binDir = Join-Path $Tmp 'bin'
    New-Item -ItemType Directory -Force $binDir | Out-Null
    Set-Content -Path (Join-Path $binDir 'warp.cmd') -Value '@echo off'
    $env:PATH = "$binDir;$MinPath"
    $env:WARP_EXE = Join-Path $Tmp 'none.exe'
    $out = Invoke-Warp
    Assert-Rc 'PATH-warp run exits 0' 0 $script:Rc
    Assert-Has 'PATH-warp run reports a PATH location' 'warp.cmd' $out
} finally {
    $env:PATH = $SavedPath
    $env:WARP_EXE = $SavedWarpExe
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host 'ALL PASS'
    exit 0
} else {
    Write-Host "$script:Failed FAILURE(S)"
    exit 1
}
