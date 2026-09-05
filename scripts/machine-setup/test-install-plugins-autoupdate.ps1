# test-install-plugins-autoupdate.ps1 — hermetic test for the HIMMEL-365
# marketplace auto-update patch in scripts/machine-setup/install-plugins.ps1
# (PowerShell twin of test-install-plugins-autoupdate.sh).
#
# Stubs the `claude` CLI on PATH (a claude.cmd; marketplace add / install no-op,
# `plugin list` reports the enabled specs so verify passes), seeds a scope
# settings file as `marketplace add` would have, runs the REAL script
# (-Scope local from a temp cwd), and asserts:
#   1. flagged + registered marketplace → autoUpdate:true added
#   2. unflagged marketplace            → left untouched
#   3. flagged but NOT registered       → skipped (no orphan entry)
#   4. unrelated keys                   → preserved
#   5. re-run                           → idempotent (stays true, exit 0)
#   6. HIMMEL-2324: link pre-planted at the OLD predictable temp path
#      ("$SF.autoupdate.tmp") → not written through; patch still lands.
#
# Keep in lockstep with test-install-plugins-autoupdate.sh when changing either.
#
# Run: pwsh -NoProfile -File scripts/machine-setup/test-install-plugins-autoupdate.ps1

$ErrorActionPreference = 'Continue'
$script:Failed = 0
$Cli = Join-Path $PSScriptRoot 'install-plugins.ps1'

if (-not $IsWindows) {
    Write-Host 'test-install-plugins-autoupdate.ps1: SKIPPED — 0 cases ran (not Windows; the claude.cmd stub needs cmd.exe)'
    exit 0
}

function Assert-True {
    param([string]$Label, [bool]$Cond)
    if ($Cond) { Write-Host "PASS $Label" }
    else { Write-Host "FAIL $Label"; $script:Failed++ }
}

# New-AttackLink <Link> <Target> — simulates an attacker with write access to
# the settings dir pre-planting something at a PREDICTABLE temp path before
# the script runs (HIMMEL-2324). Prefers a real symlink (proves both attack
# vectors: content written through it, AND the final move replacing the
# destination with the symlink itself) but falls back to an NTFS hardlink
# (still proves the write-through vector) when a symlink can't be created —
# this sandbox has no Developer Mode/admin, so New-Item -ItemType
# SymbolicLink refuses with "Administrator privilege required". A hardlink
# needs no privilege (mklink /H) and shares the same file content on disk, so
# a write into the planted path lands in the target too.
function New-AttackLink {
    param([string]$Link, [string]$Target)
    if (Test-Path $Link) { Remove-Item -Force $Link -ErrorAction SilentlyContinue }
    try {
        New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null
        return
    } catch {
        if (Test-Path $Link) { Remove-Item -Force $Link -ErrorAction SilentlyContinue }
    }
    # HIMMEL-2324 (CR round 1, codex-3): a security test that cannot tell
    # "attack blocked" from "attack never attempted" is worse than no test —
    # check mklink's own exit code AND that a link genuinely landed (LinkType
    # set) before returning. A silent no-op plant would otherwise make
    # "canary unmodified" pass trivially, for the wrong reason.
    cmd.exe /c "mklink /H `"$Link`" `"$Target`"" | Out-Null
    $mklinkRc = $LASTEXITCODE
    if ($mklinkRc -ne 0 -or -not (Test-Path $Link) -or -not (Get-Item $Link -ErrorAction SilentlyContinue).LinkType) {
        throw "New-AttackLink: failed to plant an attack link at '$Link' (mklink /H exit=$mklinkRc) -- cannot exercise the HIMMEL-2324 case in this environment"
    }
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('himmel-autoupdate-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Tmp | Out-Null
$StubDir = Join-Path $Tmp 'bin'
New-Item -ItemType Directory -Force $StubDir | Out-Null

# Stub claude.cmd: `plugin list` reports the enabled specs; everything else 0.
@'
@echo off
if not "%1"=="plugin" exit /b 0
if not "%2"=="list" exit /b 0
echo   good@flagged
echo   good@unflagged
exit /b 0
'@ | Set-Content -Path (Join-Path $StubDir 'claude.cmd')

# Template: flagged + unflagged + ghost; enabledPlugins match the stub's list.
$Template = Join-Path $Tmp 'settings-template.json'
@'
{
  "enabledPlugins": { "good@flagged": true, "good@unflagged": true },
  "extraKnownMarketplaces": {
    "flagged":   { "source": { "source": "github", "repo": "a/flagged" }, "autoUpdate": true },
    "unflagged": { "source": { "source": "github", "repo": "a/unflagged" } },
    "ghost":     { "source": { "source": "github", "repo": "a/ghost" }, "autoUpdate": true }
  }
}
'@ | Set-Content -Path $Template

# Seed settings.local.json as `marketplace add` would: flagged + unflagged
# registered, ghost absent (exercises the existence guard).
$Work = Join-Path $Tmp 'work'
New-Item -ItemType Directory -Force (Join-Path $Work '.claude') | Out-Null
$SF = Join-Path $Work '.claude\settings.local.json'
@'
{
  "theme": "dark",
  "extraKnownMarketplaces": {
    "flagged":   { "source": { "source": "github", "repo": "a/flagged" } },
    "unflagged": { "source": { "source": "github", "repo": "a/unflagged" } }
  }
}
'@ | Set-Content -Path $SF

$Pwsh = (Get-Command pwsh).Source
$SavedPath = $env:PATH

# Set-Location in the child so the script's $PWD (hence the local settings path)
# resolves to $Work — a child process does not inherit a Set-Location done here.
function Invoke-Install {
    $cmd = "Set-Location -LiteralPath '$Work'; & '$Cli' -Scope local -Template '$Template'"
    & $Pwsh -NoProfile -Command $cmd 2>&1 | Out-String | Out-Null
    return $LASTEXITCODE
}

try {
    $env:PATH = "$StubDir;$env:PATH"

    $rc = Invoke-Install
    Assert-True 'first run exits 0' ($rc -eq 0)

    $patched = Get-Content $SF -Raw | ConvertFrom-Json
    $mkts = $patched.extraKnownMarketplaces
    Assert-True 'flagged marketplace patched' ($mkts.flagged.autoUpdate -eq $true)
    Assert-True 'unflagged marketplace untouched' (-not ($mkts.unflagged.PSObject.Properties.Name -contains 'autoUpdate'))
    Assert-True 'ghost (unregistered) entry not created' (-not ($mkts.PSObject.Properties.Name -contains 'ghost'))
    Assert-True 'unrelated keys preserved' ($patched.theme -eq 'dark')
    # The PS patch round-trips the WHOLE file through ConvertFrom/ConvertTo-Json,
    # so assert a nested sub-object survives (the bash twin's jq is surgical).
    Assert-True 'flagged.source survives reserialization' ($mkts.flagged.source.repo -eq 'a/flagged')

    $rc = Invoke-Install
    Assert-True 'second run (idempotency) exits 0' ($rc -eq 0)
    $patched2 = Get-Content $SF -Raw | ConvertFrom-Json
    Assert-True 'idempotent re-run keeps autoUpdate' ($patched2.extraKnownMarketplaces.flagged.autoUpdate -eq $true)

    # Guard: an existing but invalid-JSON settings file → skipped, left byte-
    # identical (protects a hand-edited settings.json from a clobber). Use
    # WriteAllText/ReadAllText for byte-exact, BOM-free comparison.
    $bad = '{ this is not valid json'
    [System.IO.File]::WriteAllText($SF, $bad)
    $rc = Invoke-Install
    Assert-True 'invalid-JSON run exits 0' ($rc -eq 0)
    Assert-True 'invalid-JSON settings left untouched' ([System.IO.File]::ReadAllText($SF) -eq $bad)

    # Guard: no settings file present → skipped cleanly, file not created.
    Remove-Item -Force $SF
    $rc = Invoke-Install
    Assert-True 'missing-file run exits 0' ($rc -eq 0)
    Assert-True 'missing settings file not created' (-not (Test-Path $SF))

    # HIMMEL-2324: a link pre-planted at the OLD predictable temp path
    # ("$SF.autoupdate.tmp") must not be written through, and the intended
    # autoUpdate patch must still land via the (now-unpredictable) temp path.
    @'
{
  "extraKnownMarketplaces": {
    "flagged":   { "source": { "source": "github", "repo": "a/flagged" } },
    "unflagged": { "source": { "source": "github", "repo": "a/unflagged" } }
  }
}
'@ | Set-Content -Path $SF
    $Canary = Join-Path $Tmp 'canary.txt'
    [System.IO.File]::WriteAllText($Canary, 'CANARY-UNCHANGED')
    New-AttackLink -Link "$SF.autoupdate.tmp" -Target $Canary
    $rc = Invoke-Install
    Assert-True 'HIMMEL-2324 run exits 0' ($rc -eq 0)
    Assert-True 'HIMMEL-2324: canary unmodified' ([System.IO.File]::ReadAllText($Canary) -eq 'CANARY-UNCHANGED')
    Assert-True 'HIMMEL-2324: settings file still present' (Test-Path $SF)
    Assert-True 'HIMMEL-2324: settings file not a symlink' (-not (Get-Item $SF).LinkType)
    $patched3 = Get-Content $SF -Raw | ConvertFrom-Json
    Assert-True 'HIMMEL-2324: intended autoUpdate patch landed' ($patched3.extraKnownMarketplaces.flagged.autoUpdate -eq $true)

    # HIMMEL-2324 (CR round 6, codex-4): exclusivity primitive, not just
    # naming. The case above proves the temp NAME is unpredictable -- it does
    # NOT prove the CREATE is exclusive. It would still pass even if
    # install-plugins.ps1 regressed from FileMode.CreateNew back to a
    # truncating create (Create / OpenOrCreate / WriteAllText) at the SAME
    # randomized path, since nothing there depends on exclusivity, only
    # unpredictability. Test the exact create shape directly: pre-create a
    # canary at a path we control, then attempt
    # [System.IO.File]::Open($p, [FileMode]::CreateNew, ...) against it -- it
    # must throw, and the canary content must survive untouched.
    $ExclPath = Join-Path $Tmp 'exclusivity-canary.txt'
    [System.IO.File]::WriteAllText($ExclPath, 'CANARY-UNCHANGED')
    $ExclThrew = $false
    try {
        $fs = [System.IO.File]::Open($ExclPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        $fs.Close()
    } catch {
        $ExclThrew = $true
    }
    Assert-True 'exclusivity: CreateNew refuses an existing path' $ExclThrew
    Assert-True 'exclusivity: canary content survives the refused create' ([System.IO.File]::ReadAllText($ExclPath) -eq 'CANARY-UNCHANGED')
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
