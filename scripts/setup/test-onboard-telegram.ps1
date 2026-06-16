# test-onboard-telegram.ps1 — PowerShell smoke test for
# scripts/setup/onboard-telegram.ps1 (HIMMEL-227; PS sibling of
# test-onboard-telegram.sh, CR round 1). Everything runs against a temp
# TELEGRAM_CHANNEL_DIR — never touches the operator's real channel dir,
# access.json, or the live bridge.
#
# Run: pwsh -NoProfile -File scripts/setup/test-onboard-telegram.ps1

$ErrorActionPreference = 'Continue'
$script:Failed = 0
$Cli = Join-Path $PSScriptRoot 'onboard-telegram.ps1'

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

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('himmel-onboard-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $Tmp | Out-Null

$Channel    = Join-Path $Tmp 'channels\telegram'
$EnvFile    = Join-Path $Channel '.env'
$AccessFile = Join-Path $Channel 'access.json'

$SavedChannelDir = $env:TELEGRAM_CHANNEL_DIR
$env:TELEGRAM_CHANNEL_DIR = $Channel

function Invoke-Onboard {
    $out = ('' | & pwsh -NoProfile -File $Cli 2>&1 | Out-String)
    $script:Rc = $LASTEXITCODE
    return $out
}

try {
    # 1. fresh machine: dir + .env template created, access.json NOT created
    $out = Invoke-Onboard
    Assert-Rc 'fresh run exits 0' 0 $script:Rc
    if (Test-Path $Channel) {
        Write-Host 'PASS channel dir created'
    } else {
        Write-Host 'FAIL channel dir not created'; $script:Failed++
    }
    if ((Test-Path $EnvFile) -and (Select-String -Path $EnvFile -Pattern '^TELEGRAM_BOT_TOKEN=$' -Quiet)) {
        Write-Host 'PASS .env template created with empty token'
    } else {
        Write-Host 'FAIL .env template missing or malformed'; $script:Failed++
    }
    if (Test-Path $AccessFile) {
        Write-Host 'FAIL access.json was created -- onboarding must NEVER write it'; $script:Failed++
    } else {
        Write-Host 'PASS access.json not created'
    }
    Assert-Has 'fresh run reports missing pairing' 'access.json: MISSING' $out
    Assert-Has 'fresh run prints bridge bring-up' 'bridge bring-up' $out
    Assert-Has 'fresh run mentions warp' 'Warp integration' $out

    # 2. idempotence: existing .env (with a token) is never rewritten
    Set-Content -Path $EnvFile -Value "TELEGRAM_BOT_TOKEN=123:abc`n# operator custom line" -NoNewline
    $before = Get-Content -Raw $EnvFile
    $out = Invoke-Onboard
    Assert-Rc 're-run exits 0' 0 $script:Rc
    $after = Get-Content -Raw $EnvFile
    if ($before -eq $after) {
        Write-Host 'PASS existing .env untouched'
    } else {
        Write-Host 'FAIL existing .env was modified'; $script:Failed++
    }
    Assert-Has 're-run reports token set' '.env: present (token set)' $out

    # 3. existing pairing is reported, file untouched
    Set-Content -Path $AccessFile -Value '{"allowFrom":["42"]}' -NoNewline
    $before = Get-Content -Raw $AccessFile
    $out = Invoke-Onboard
    Assert-Rc 'paired run exits 0' 0 $script:Rc
    $after = Get-Content -Raw $AccessFile
    if ($before -eq $after) {
        Write-Host 'PASS access.json untouched'
    } else {
        Write-Host 'FAIL access.json was modified'; $script:Failed++
    }
    Assert-Has 'paired run reports pairing configured' 'pairing configured' $out

    # 4. empty-token .env is flagged but not rewritten
    Set-Content -Path $EnvFile -Value "# comment only`nTELEGRAM_BOT_TOKEN=" -NoNewline
    $before = Get-Content -Raw $EnvFile
    $out = Invoke-Onboard
    Assert-Rc 'empty-token run exits 0' 0 $script:Rc
    $after = Get-Content -Raw $EnvFile
    if ($before -eq $after) {
        Write-Host 'PASS empty-token .env untouched'
    } else {
        Write-Host 'FAIL empty-token .env was rewritten'; $script:Failed++
    }
    Assert-Has 'empty token flagged' 'TELEGRAM_BOT_TOKEN is empty' $out
} finally {
    $env:TELEGRAM_CHANNEL_DIR = $SavedChannelDir
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
