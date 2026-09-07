# unwire-himmel-repo.ps1 -- PowerShell counterpart of unwire-himmel-repo.sh.
# Removes env.HIMMEL_REPO from a Claude Code settings.json; all other env keys are
# preserved; an env object left empty is pruned. Shells out to jq for byte-parity.
#
#   Remove-HimmelRepo -SettingsPath <path>
# Direct:  pwsh -File unwire-himmel-repo.ps1 -SettingsPath <path>

[CmdletBinding()]
param([string]$SettingsPath)

function Remove-HimmelRepo {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "unwire-himmel-repo: jq required" }
    if (-not (Test-Path $SettingsPath)) { return }
    $raw = Get-Content $SettingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    # Captured native stdout is decoded via [Console]::OutputEncoding, the
    # legacy OEM codepage here, not UTF-8 (HIMMEL-2256; dot-sourcing this
    # library must not mutate the caller's console encoding at top level).
    # Save/restore around the capture so the caller's encoding is unchanged
    # on every exit path, including a thrown error.
    #
    # Piping TEXT INTO jq's stdin is a separate direction governed by the
    # $OutputEncoding preference variable, not [Console]::OutputEncoding --
    # on Windows PowerShell 5.1 it defaults to ASCIIEncoding, silently
    # replacing every non-ASCII char with `?` before jq ever sees it
    # (HIMMEL-2256 twin bug). Must be set at global scope: a bare
    # $OutputEncoding assignment inside a function is function-local and the
    # child process never sees it.
    #
    # BOM-less: [Encoding]::UTF8 emits EF BB BF on stdin, which older jq rejects.
    $prevOutputEncoding = [Console]::OutputEncoding
    $prevOutEncodingPref = $global:OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $global:OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $raw | jq -e . > $null 2>&1
        if ($LASTEXITCODE -ne 0) { throw "unwire-himmel-repo: $SettingsPath is not valid JSON -- refusing to modify" }
        $filter = 'del(.env.HIMMEL_REPO) | if (has("env") and (.env == {})) then del(.env) else . end'
        $out = $raw | jq --indent 2 $filter
        if ($LASTEXITCODE -ne 0) { throw "unwire-himmel-repo: jq transform failed" }
        $tmp = "$SettingsPath.unwirehr.tmp"
        # UTF-8 without BOM (HIMMEL-365/408): Set-Content -Encoding utf8 BOMs on PS 5.1.
        [System.IO.File]::WriteAllText($tmp, ($out -join "`n") + "`n")
        Move-Item -Path $tmp -Destination $SettingsPath -Force
        Write-Host "  removed env.HIMMEL_REPO (if present) -> $SettingsPath"
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
        $global:OutputEncoding = $prevOutEncodingPref
    }
}

if ($SettingsPath) {
    try { Remove-HimmelRepo -SettingsPath $SettingsPath } catch { Write-Error $_; exit 1 }
}
