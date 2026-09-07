# unwire-statusline.ps1 -- PowerShell counterpart of unwire-statusline.sh.
# Rolls back .statusLine in a Claude Code settings.json ONLY when it points at a
# himmel statusLine -- the hud renderer (marketplace/plugins/claude-hud/dist/index.js;
# HIMMEL-718), the where-are-we wrapper (HIMMEL-538), or the older vendored bar.
# A user's own statusLine is left untouched. Shells out to jq for byte-parity
# with the bash twin.
#
#   Remove-Statusline -SettingsPath <path> [-HimmelPath <path>]
# Direct:  pwsh -File unwire-statusline.ps1 -SettingsPath <path> [-HimmelPath <path>]
#
# With -HimmelPath -> REPOINT .statusLine.command to the bash-bar fallback
#   (HIMMEL-718 migration rollback; the .env.CLAUDE_HUD_ALLOW_EXTRA_CMD gate is
#   deliberately left in place, harmless when the bash bar renders — same as the
#   bash twin). Without it -> REMOVE .statusLine (uninstall).

[CmdletBinding()]
param([string]$SettingsPath, [string]$HimmelPath)

function Remove-Statusline {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [string]$HimmelPath
    )
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "unwire-statusline: jq required" }
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
        if ($LASTEXITCODE -ne 0) { throw "unwire-statusline: $SettingsPath is not valid JSON -- refusing to modify" }
        # Matches the himmel statusLine in any of its shapes; a user's own custom
        # statusLine matches none and is left alone.
        $matchRe = 'marketplace/plugins/claude-hud/dist/index[.]js|scripts/(statusline/bin/statusline|where-are-we/statusline)[.]sh'
        if ($HimmelPath) {
            $himmelFwd = $HimmelPath.Replace('\', '/')
            $cmd = "bash `"$himmelFwd/scripts/where-are-we/statusline.sh`""
            $filter = 'if ((.statusLine.command? // "") | test($re)) then .statusLine.command = $cmd else . end'
            $out = $raw | jq --indent 2 --arg re $matchRe --arg cmd $cmd $filter
        } else {
            $filter = 'if ((.statusLine.command? // "") | test($re)) then del(.statusLine) else . end'
            $out = $raw | jq --indent 2 --arg re $matchRe $filter
        }
        if ($LASTEXITCODE -ne 0) { throw "unwire-statusline: jq transform failed" }
        $tmp = "$SettingsPath.unwiresl.tmp"
        # UTF-8 without BOM (HIMMEL-365/408): Set-Content -Encoding utf8 BOMs on PS 5.1.
        [System.IO.File]::WriteAllText($tmp, ($out -join "`n") + "`n")
        Move-Item -Path $tmp -Destination $SettingsPath -Force
        if ($HimmelPath) {
            Write-Host "  repointed himmel statusLine to bash-bar fallback (if present) -> $SettingsPath"
        } else {
            Write-Host "  removed himmel statusLine (if present) -> $SettingsPath"
        }
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
        $global:OutputEncoding = $prevOutEncodingPref
    }
}

if ($SettingsPath) {
    try { Remove-Statusline -SettingsPath $SettingsPath -HimmelPath $HimmelPath } catch { Write-Error $_; exit 1 }
}
