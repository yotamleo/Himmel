# wire-statusline.ps1 — PowerShell counterpart of wire-statusline.sh
# (HIMMEL-359). Single source of truth for wiring the himmel statusLine into a
# Claude Code settings.json. Used by adopt.ps1, setup.ps1, and
# machine-setup/win11.ps1.
#
# Dot-source to get Set-HimmelStatusLine, or invoke directly:
#   pwsh -File wire-statusline.ps1 -SettingsPath <path> -HimmelPath <path>
#
# Sets .statusLine = { type: "command",
#   command: 'bash "<himmel>/scripts/statusline/bin/statusline.sh"' }
# Idempotent, atomic (temp + move), non-destructive (other keys preserved;
# file + parent dir created if absent). Normalizes JSON through `jq --indent 2`
# when jq is on PATH (matches win11.ps1's Write-SettingsJson), else falls back
# to ConvertTo-Json.

[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$HimmelPath
)

function Set-HimmelStatusLine {
    param(
        [Parameter(Mandatory = $true)] [string]$SettingsPath,
        [Parameter(Mandatory = $true)] [string]$HimmelPath
    )

    # Forward-slash the himmel path so the `bash "..."` command is valid.
    $himmelFwd = $HimmelPath.Replace('\', '/')
    $cmd = "bash `"$himmelFwd/scripts/statusline/bin/statusline.sh`""

    if (Test-Path $SettingsPath) {
        $raw = Get-Content $SettingsPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            # Empty / whitespace-only file → start from {} (ConvertFrom-Json
            # returns $null on empty input, which then throws on property access).
            $cfg = [pscustomobject]@{}
        } else {
            try {
                $cfg = $raw | ConvertFrom-Json
            } catch {
                # Throw (not Write-Error+return): the script entry point converts
                # this to `exit 1` so `-File` callers see a non-zero code, matching
                # the bash twin's `return 1`. Write-Error alone exits 0 under the
                # default child $ErrorActionPreference='Continue'.
                throw "wire-statusline: $SettingsPath is not valid JSON — refusing to overwrite"
            }
        }
    } else {
        # Split-Path returns '' for a bare filename with no directory — guard so
        # New-Item is not handed an empty path.
        $dir = Split-Path $SettingsPath
        if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $cfg = [pscustomobject]@{}
    }

    $statusLine = [pscustomobject]@{ type = 'command'; command = $cmd }
    if ($cfg.PSObject.Properties['statusLine']) {
        $cfg.statusLine = $statusLine
    } else {
        $cfg | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine -Force
    }

    $json = $cfg | ConvertTo-Json -Depth 20
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        $normalized = $json | jq --indent 2 .
        if ($LASTEXITCODE -eq 0 -and $normalized) { $json = $normalized -join "`n" }
    }
    Set-Content -Path "$SettingsPath.new" -Value $json -Encoding utf8
    Move-Item -Path "$SettingsPath.new" -Destination $SettingsPath -Force
    Write-Host "  wired statusLine → $SettingsPath"
}

# Direct invocation (both args supplied) runs the function. Dot-sourcing with
# no args just defines it.
if ($SettingsPath -and $HimmelPath) {
    try {
        Set-HimmelStatusLine -SettingsPath $SettingsPath -HimmelPath $HimmelPath
    } catch {
        # Surface as a non-zero exit so `-File` callers (setup.ps1 etc.) can
        # detect the refusal — dot-source callers catch the throw themselves.
        Write-Error $_
        exit 1
    }
}
