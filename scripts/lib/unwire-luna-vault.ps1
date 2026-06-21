# unwire-luna-vault.ps1 -- PowerShell counterpart of unwire-luna-vault.sh.
# Removes env.LUNA_VAULT_PATH from a Claude Code settings.json; all other env keys
# are preserved; an env object left empty is pruned. Shells out to jq for byte-parity.
#
#   Remove-LunaVault -SettingsPath <path>
# Direct:  pwsh -File unwire-luna-vault.ps1 -SettingsPath <path>

[CmdletBinding()]
param([string]$SettingsPath)

function Remove-LunaVault {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "unwire-luna-vault: jq required" }
    if (-not (Test-Path $SettingsPath)) { return }
    $raw = Get-Content $SettingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $raw | jq -e . > $null 2>&1
    if ($LASTEXITCODE -ne 0) { throw "unwire-luna-vault: $SettingsPath is not valid JSON -- refusing to modify" }
    $filter = 'del(.env.LUNA_VAULT_PATH) | if (has("env") and (.env == {})) then del(.env) else . end'
    $out = $raw | jq --indent 2 $filter
    if ($LASTEXITCODE -ne 0) { throw "unwire-luna-vault: jq transform failed" }
    $tmp = "$SettingsPath.unwirelv.tmp"
    # UTF-8 without BOM (HIMMEL-365/408): Set-Content -Encoding utf8 BOMs on PS 5.1.
    [System.IO.File]::WriteAllText($tmp, ($out -join "`n") + "`n")
    Move-Item -Path $tmp -Destination $SettingsPath -Force
    Write-Host "  removed env.LUNA_VAULT_PATH (if present) -> $SettingsPath"
}

if ($SettingsPath) {
    try { Remove-LunaVault -SettingsPath $SettingsPath } catch { Write-Error $_; exit 1 }
}
