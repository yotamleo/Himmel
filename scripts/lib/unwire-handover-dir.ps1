# unwire-handover-dir.ps1 -- PowerShell counterpart of unwire-handover-dir.sh.
# Removes env.HANDOVER_DIR from a Claude Code settings.json; all other env keys
# are preserved; an env object left empty is pruned. Shells out to jq for byte-parity.
#
#   Remove-HandoverDir -SettingsPath <path>
# Direct:  pwsh -File unwire-handover-dir.ps1 -SettingsPath <path>

[CmdletBinding()]
param([string]$SettingsPath)

function Remove-HandoverDir {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "unwire-handover-dir: jq required" }
    if (-not (Test-Path $SettingsPath)) { return }
    $raw = Get-Content $SettingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $raw | jq -e . > $null 2>&1
    if ($LASTEXITCODE -ne 0) { throw "unwire-handover-dir: $SettingsPath is not valid JSON -- refusing to modify" }
    $filter = 'del(.env.HANDOVER_DIR) | if (has("env") and (.env == {})) then del(.env) else . end'
    $out = $raw | jq --indent 2 $filter
    if ($LASTEXITCODE -ne 0) { throw "unwire-handover-dir: jq transform failed" }
    $tmp = "$SettingsPath.unwirehd.tmp"
    # UTF-8 without BOM (HIMMEL-365/408): Set-Content -Encoding utf8 BOMs on PS 5.1.
    [System.IO.File]::WriteAllText($tmp, ($out -join "`n") + "`n")
    Move-Item -Path $tmp -Destination $SettingsPath -Force
    Write-Host "  removed env.HANDOVER_DIR (if present) -> $SettingsPath"
}

if ($SettingsPath) {
    try { Remove-HandoverDir -SettingsPath $SettingsPath } catch { Write-Error $_; exit 1 }
}
