# unwire-statusline.ps1 -- PowerShell counterpart of unwire-statusline.sh.
# Removes .statusLine from a Claude Code settings.json ONLY when it points at the
# himmel statusline binary (a user's own statusLine is left untouched). Shells out
# to jq for byte-parity with the bash twin.
#
#   Remove-Statusline -SettingsPath <path>
# Direct:  pwsh -File unwire-statusline.ps1 -SettingsPath <path>

[CmdletBinding()]
param([string]$SettingsPath)

function Remove-Statusline {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "unwire-statusline: jq required" }
    if (-not (Test-Path $SettingsPath)) { return }
    $raw = Get-Content $SettingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $raw | jq -e . > $null 2>&1
    if ($LASTEXITCODE -ne 0) { throw "unwire-statusline: $SettingsPath is not valid JSON -- refusing to modify" }
    $filter = 'if ((.statusLine.command? // "") | test("scripts/statusline/bin/statusline[.]sh")) then del(.statusLine) else . end'
    $out = $raw | jq --indent 2 $filter
    if ($LASTEXITCODE -ne 0) { throw "unwire-statusline: jq transform failed" }
    $tmp = "$SettingsPath.unwiresl.tmp"
    # UTF-8 without BOM (HIMMEL-365/408): Set-Content -Encoding utf8 BOMs on PS 5.1.
    [System.IO.File]::WriteAllText($tmp, ($out -join "`n") + "`n")
    Move-Item -Path $tmp -Destination $SettingsPath -Force
    Write-Host "  removed himmel statusLine (if present) -> $SettingsPath"
}

if ($SettingsPath) {
    try { Remove-Statusline -SettingsPath $SettingsPath } catch { Write-Error $_; exit 1 }
}
