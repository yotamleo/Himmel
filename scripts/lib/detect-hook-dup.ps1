# detect-hook-dup.ps1 -- PowerShell counterpart of detect-hook-dup.sh (R4,
# HIMMEL-460). ADVISORY warning (always rc 0) when a himmel UNIVERSAL hook is
# wired at BOTH user and a project's settings.json. Suppressed in-repo. Uses jq
# for parity (no-ops without it).
#
#   pwsh -File detect-hook-dup.ps1 -UserSettings <p> -ProjectSettings <p> -HimmelRoot <p>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$UserSettings,
    [Parameter(Mandatory = $true)][string]$ProjectSettings,
    [Parameter(Mandatory = $true)][string]$HimmelRoot
)

$Universal = @('auto-approve-safe-bash', 'block-edit-on-main', 'block-read-secrets', 'inject-initiative')

function _DhdNorm([string]$p) { ($p -replace '\\', '/').TrimEnd('/') }

function _DhdHasHook([string]$settings, [string]$base) {
    if (-not (Test-Path $settings)) { return $false }
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { return $false }
    Get-Content $settings -Raw | jq -e . > $null 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    $pat = "scripts/hooks/$base[.]sh"
    Get-Content $settings -Raw | jq -e --arg pat $pat 'any(.. | (.command? // empty) | strings; test($pat))' > $null 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Invoke-DetectHookDup {
    param([string]$UserSettings, [string]$ProjectSettings, [string]$HimmelRoot)
    if ((_DhdNorm $ProjectSettings) -eq (_DhdNorm (Join-Path $HimmelRoot '.claude/settings.json'))) {
        return  # in-repo: himmel devs are expected to have both
    }
    $dups = @()
    foreach ($b in $Universal) {
        if ((_DhdHasHook $UserSettings $b) -and (_DhdHasHook $ProjectSettings $b)) { $dups += $b }
    }
    if ($dups.Count -gt 0) {
        $projRepo = Split-Path (Split-Path $ProjectSettings)
        Write-Host "  NOTE: these himmel UNIVERSAL hooks are wired at BOTH user and project scope (they fire twice):" -ForegroundColor Yellow
        foreach ($b in $dups) { Write-Host "    - $b" -ForegroundColor Yellow }
        Write-Host "  The double-fire is benign + idempotent. To remove the redundant project copy, run:" -ForegroundColor Yellow
        Write-Host "    bash $HimmelRoot/scripts/lib/unwire-pretooluse-hooks.sh --scope project --target $projRepo" -ForegroundColor Yellow
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DetectHookDup -UserSettings $UserSettings -ProjectSettings $ProjectSettings -HimmelRoot $HimmelRoot
}
