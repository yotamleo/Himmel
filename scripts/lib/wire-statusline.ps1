# wire-statusline.ps1 — PowerShell counterpart of wire-statusline.sh
# (HIMMEL-359). Single source of truth for wiring the himmel statusLine into a
# Claude Code settings.json. Used by adopt.ps1, setup.ps1, and
# machine-setup/win11.ps1.
#
# Dot-source to get Set-HimmelStatusLine, or invoke directly:
#   pwsh -File wire-statusline.ps1 -SettingsPath <path> -HimmelPath <path>
#
# Does THREE things (HIMMEL-718 Task 4.1 — the wiring switch to the forked
# claude-hud renderer; the vendored bash bar is RETAINED as fallback):
#   1. .statusLine = { type: "command",
#        command: 'node "<himmel>/marketplace/plugins/claude-hud/dist/index.js"' }
#   2. .env.CLAUDE_HUD_ALLOW_EXTRA_CMD = "1"  (merged, other env keys preserved)
#   3. Drops the hud config (himmel-config.json with <himmel-path> substituted)
#      to <settings-dir>/plugins/claude-hud/config.json.
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

    # Forward-slash the himmel path so the `node "..."` command is valid.
    $himmelFwd = $HimmelPath.Replace('\', '/')
    $cmd = "node `"$himmelFwd/marketplace/plugins/claude-hud/dist/index.js`""

    $settingsDir = Split-Path $SettingsPath -Parent
    if (-not $settingsDir) { $settingsDir = '.' }

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
        New-Item -ItemType Directory -Force $settingsDir | Out-Null
        $cfg = [pscustomobject]@{}
    }

    # (1) statusLine → hud renderer.
    $statusLine = [pscustomobject]@{ type = 'command'; command = $cmd }
    if ($cfg.PSObject.Properties['statusLine']) {
        $cfg.statusLine = $statusLine
    } else {
        $cfg | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine -Force
    }

    # (2) Merge the extra-cmd gate into .env, preserving every other env key.
    if (-not $cfg.PSObject.Properties['env']) {
        $cfg | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($cfg.env.PSObject.Properties['CLAUDE_HUD_ALLOW_EXTRA_CMD']) {
        $cfg.env.CLAUDE_HUD_ALLOW_EXTRA_CMD = '1'
    } else {
        $cfg.env | Add-Member -NotePropertyName CLAUDE_HUD_ALLOW_EXTRA_CMD -NotePropertyValue '1' -Force
    }

    $json = $cfg | ConvertTo-Json -Depth 20
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        $normalized = $json | jq --indent 2 .
        if ($LASTEXITCODE -eq 0 -and $normalized) { $json = $normalized -join "`n" }
    }
    Set-Content -Path "$SettingsPath.new" -Value $json -Encoding utf8
    Move-Item -Path "$SettingsPath.new" -Destination $SettingsPath -Force

    # (3) Drop the hud config next to settings.json, substituting this clone's
    # path for the <himmel-path> placeholder. Guarded on the source existing so
    # tests wiring against a synthetic himmel path stay a pure statusLine/env op.
    $hudSrc = "$himmelFwd/marketplace/plugins/claude-hud/config/himmel-config.json"
    if (Test-Path $hudSrc) {
        $hudDir = Join-Path $settingsDir 'plugins/claude-hud'
        New-Item -ItemType Directory -Force $hudDir | Out-Null
        $hudCfg = (Get-Content $hudSrc -Raw).Replace('<himmel-path>', $himmelFwd).Replace("`r`n", "`n")
        $hudPath = Join-Path $hudDir 'config.json'
        $hudTmp = "$hudPath.tmp"
        # UTF-8 without BOM; single trailing LF (matches the bash twin's printf).
        [System.IO.File]::WriteAllText($hudTmp, $hudCfg.TrimEnd("`n") + "`n")
        # Validate the substituted config is still JSON before publishing it — a
        # JSON-breaking himmel path would otherwise yield a config.json the
        # renderer fails on silently at render time. jq is optional here (matches
        # the ConvertTo-Json fallback above); skip the check when it is absent.
        if (Get-Command jq -ErrorAction SilentlyContinue) {
            & jq -e . $hudTmp *> $null
            if ($LASTEXITCODE -ne 0) {
                Remove-Item -LiteralPath $hudTmp -Force
                throw "wire-statusline: substituted hud config is not valid JSON — refusing to write"
            }
        }
        Move-Item -Path $hudTmp -Destination $hudPath -Force
    }
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
