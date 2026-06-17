# test-install-plugins-verify.ps1 — hermetic test for the HIMMEL-361 post-install
# PRESENCE verification in scripts/machine-setup/install-plugins.ps1 (PowerShell
# twin of test-install-plugins-verify.sh; HIMMEL-364).
#
# Stubs the `claude` CLI on PATH (a per-scenario claude.cmd) so nothing touches
# the operator's real plugin set, then drives the real script against a temp
# template and asserts:
#   1. every template plugin present → exit 0 + "All N enabled plugins present"
#   2. one template plugin absent    → exit 1, naming the absent plugin only
#   3. list reports a case-mismatched spec → exit 1 (case-sensitive, matches the
#      bash twin's grep -F)
#   4. `claude plugin list` fails     → fail closed (exit 1), surfaces the error
#   5. --dry-run                      → exit 0, verify skipped
#
# Keep in lockstep with test-install-plugins-verify.sh when changing either.
#
# Run: pwsh -NoProfile -File scripts/machine-setup/test-install-plugins-verify.ps1

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

function Assert-Lacks {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) {
        Write-Host "FAIL $Label -- output unexpectedly contains: $Needle"
        $script:Failed++
    } else {
        Write-Host "PASS $Label"
    }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('himmel-pluginverify-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Tmp | Out-Null
$StubDir = Join-Path $Tmp 'bin'
New-Item -ItemType Directory -Force $StubDir | Out-Null

$Template = Join-Path $Tmp 'settings-template.json'
@'
{
  "enabledPlugins": { "good-a@mp": true, "good-b@mp": true, "bogus@nowhere": true },
  "extraKnownMarketplaces": {}
}
'@ | Set-Content -Path $Template

# Regenerate the stub per scenario. NO paren-block: `exit /b N` inside an
# `if (...)` block does NOT propagate errorlevel in cmd.exe, so the list-failure
# case would wrongly look like success.
function Set-Stub {
    param([string[]]$Present, [bool]$ListFail = $false)
    $lines = @('@echo off', 'if not "%1"=="plugin" exit /b 0', 'if not "%2"=="list" exit /b 0')
    if ($ListFail) {
        $lines += @('echo stub: list boom 1>&2', 'exit /b 3')
    } else {
        foreach ($p in $Present) { $lines += "echo   $p" }
        $lines += 'exit /b 0'
    }
    Set-Content -Path (Join-Path $StubDir 'claude.cmd') -Value $lines
}

$Pwsh = (Get-Command pwsh).Source
$SavedPath = $env:PATH

function Invoke-Install {
    param([string[]]$ExtraArgs = @())
    $out = (& $Pwsh -NoProfile -File $Cli -Template $Template -Scope user @ExtraArgs 2>&1 | Out-String)
    $script:Rc = $LASTEXITCODE
    return $out
}

try {
    $env:PATH = "$StubDir;$env:PATH"

    # 1. all present → exit 0 + summary
    Set-Stub @('good-a@mp', 'good-b@mp', 'bogus@nowhere')
    $out = Invoke-Install
    Assert-Rc 'all-present exits 0' 0 $script:Rc
    Assert-Has 'all-present prints summary' 'All 3 enabled plugins present' $out

    # 2. one absent → exit 1, names it; present ones NOT flagged
    Set-Stub @('good-a@mp', 'good-b@mp')
    $out = Invoke-Install
    Assert-Rc 'missing exits 1' 1 $script:Rc
    Assert-Has 'missing names the absent plugin' 'bogus@nowhere' $out
    Assert-Has 'missing reports a failure count' '1 plugin(s) not present' $out
    Assert-Lacks 'present plugin not flagged' 'good-a@mp --' $out

    # 3. case mismatch → exit 1 (case-sensitive membership)
    Set-Stub @('GOOD-A@MP', 'good-b@mp', 'bogus@nowhere')
    $out = Invoke-Install
    Assert-Rc 'case-mismatch exits 1' 1 $script:Rc
    Assert-Has 'case-mismatch names the lower-case spec' 'good-a@mp' $out

    # 4. `claude plugin list` fails → fail closed + surface error
    Set-Stub @() $true
    $out = Invoke-Install
    Assert-Rc 'list-failure fails closed (exit 1)' 1 $script:Rc
    Assert-Has 'list-failure surfaces claude stderr' 'stub: list boom' $out

    # 5. --dry-run → exit 0, verify skipped
    Set-Stub @()
    $out = Invoke-Install @('-DryRun')
    Assert-Rc 'dry-run exits 0' 0 $script:Rc
    Assert-Has 'dry-run skips verify' 'verify skipped' $out
} finally {
    $env:PATH = $SavedPath
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
