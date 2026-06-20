# wire-himmel-repo.ps1 -- PowerShell counterpart of wire-himmel-repo.sh
# (HIMMEL-453). Sets .env.HIMMEL_REPO in a Claude Code settings.json to the
# himmel clone path. Sibling of wire-statusline.ps1 -- same shape, but it MERGES
# into the existing .env object (preserving HIMMEL_INITIATIVE and any other env
# keys) instead of replacing a single top-level object.
#
# Dot-source to get Set-HimmelRepo, or invoke directly:
#   pwsh -File wire-himmel-repo.ps1 -SettingsPath <path> -HimmelPath <path>
#
# Idempotent, atomic (temp + move), non-destructive (other keys preserved; file
# + parent dir created if absent). Normalizes JSON through `jq --indent 2` when
# jq is on PATH (matches the statusline twin), else falls back to ConvertTo-Json.

[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$HimmelPath
)

function Set-HimmelRepo {
    param(
        [Parameter(Mandatory = $true)] [string]$SettingsPath,
        [Parameter(Mandatory = $true)] [string]$HimmelPath
    )

    # Forward-slash so the stored value is a valid Git-Bash path even when a
    # caller passes a Windows backslash path.
    $repoFwd = $HimmelPath.Replace('\', '/')

    if (Test-Path $SettingsPath) {
        $raw = Get-Content $SettingsPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $cfg = [pscustomobject]@{}
        } else {
            try {
                $cfg = $raw | ConvertFrom-Json
            } catch {
                # Throw (not Write-Error+return): the entry point converts this to
                # `exit 1` so `-File` callers see a non-zero code, matching the
                # bash twin's `return 1`.
                throw "wire-himmel-repo: $SettingsPath is not valid JSON -- refusing to overwrite"
            }
        }
    } else {
        $dir = Split-Path $SettingsPath
        if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $cfg = [pscustomobject]@{}
    }

    # Ensure an .env object exists, then set/replace only the HIMMEL_REPO member
    # (all sibling env keys preserved).
    if (-not $cfg.PSObject.Properties['env'] -or $null -eq $cfg.env) {
        $cfg | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($cfg.env.PSObject.Properties['HIMMEL_REPO']) {
        $cfg.env.HIMMEL_REPO = $repoFwd
    } else {
        $cfg.env | Add-Member -NotePropertyName HIMMEL_REPO -NotePropertyValue $repoFwd -Force
    }

    $json = $cfg | ConvertTo-Json -Depth 20
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        $normalized = $json | jq --indent 2 .
        if ($LASTEXITCODE -eq 0 -and $normalized) { $json = $normalized -join "`n" }
    }
    Set-Content -Path "$SettingsPath.new" -Value $json -Encoding utf8
    Move-Item -Path "$SettingsPath.new" -Destination $SettingsPath -Force
    Write-Host "  set env.HIMMEL_REPO -> $SettingsPath"
}

# Direct invocation (both args supplied) runs the function. Dot-sourcing with no
# args just defines it.
if ($SettingsPath -and $HimmelPath) {
    try {
        Set-HimmelRepo -SettingsPath $SettingsPath -HimmelPath $HimmelPath
    } catch {
        Write-Error $_
        exit 1
    }
}
