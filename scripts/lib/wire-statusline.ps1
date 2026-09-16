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
#      to ${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/claude-hud/config.json --
#      the config dir, always, never the settings file's own directory
#      (HIMMEL-2892: it is per-user config, not per-project).
#   4. Drops the hud's RUNTIME cache state in that same dir whenever the wiring
#      actually CHANGED (HIMMEL-3065) -- see Remove-HimmelHudCacheState.
# Idempotent, atomic (temp + move), non-destructive (other keys preserved;
# file + parent dir created if absent). Normalizes JSON through `jq --indent 2`
# when jq is on PATH (matches win11.ps1's Write-SettingsJson), else falls back
# to ConvertTo-Json.

[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$HimmelPath
)

# The Claude Code config dir -- twin of the bash lib's
# _wire_statusline_config_dir(), and of the hud's own getClaudeConfigDir()
# (marketplace/plugins/claude-hud/src/claude-config-dir.ts): CLAUDE_CONFIG_DIR
# wins, TRIMMED, with a leading `~` expanded; otherwise <home>/.claude.
# IsNullOrWhiteSpace already treated a whitespace-only value as unset; the
# explicit Trim() below extends that to a PADDED value, so a directory written
# here is the same one the hud reads it back from. $env:HOME is unset on
# Windows PowerShell 5.1, so USERPROFILE is the fallback there.
function Get-ClaudeConfigDir {
    $homeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $d = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrWhiteSpace($d)) { return (Join-Path $homeDir '.claude') }
    $d = $d.Trim()
    if ($d -eq '~') { return $homeDir }
    if ($d.StartsWith('~/')) { return (Join-Path $homeDir $d.Substring(2)) }
    return $d
}

# Drop the hud's RUNTIME cache state -- everything the hud writes under its
# plugin dir EXCEPT the config.json this script owns (HIMMEL-3065). Twin of the
# bash lib's _wire_statusline_purge_hud_cache; see its header for why this is a
# denylist and why only a CHANGED wiring may call it.
#
# Every file operation here and in the publish below carries -ErrorAction Stop.
# `pwsh -File` runs under $ErrorActionPreference = 'Continue' (and setup.ps1
# relaxes EAP around its own bash invocations), so without it a failed
# Get-ChildItem or Remove-Item is NON-terminating: the caller's catch never
# fires, the purge reports success, and the staged files publish anyway --
# leaving the twins disagreeing on the one invariant that makes a failed purge
# retryable, since the bash side's `rm -rf || return 1` does fail loudly.
function Remove-HimmelHudCacheState {
    param([Parameter(Mandatory = $true)] [string]$HudDir)

    if (-not (Test-Path $HudDir)) { return }
    $dropped = $false
    foreach ($entry in Get-ChildItem -LiteralPath $HudDir -Force -ErrorAction Stop) {
        # Dotfiles are skipped in both directions: the hud's own
        # interrupted-write temp files are inert, and the caller stages its new
        # config as .config.json.tmp so this purge cannot delete it.
        if ($entry.Name -eq 'config.json' -or $entry.Name.StartsWith('.')) { continue }
        Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
        $dropped = $true
    }
    if ($dropped) { Write-Host "  dropped stale hud cache state -> $HudDir" }
}

function Set-HimmelStatusLine {
    param(
        [Parameter(Mandatory = $true)] [string]$SettingsPath,
        [Parameter(Mandatory = $true)] [string]$HimmelPath
    )

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

        # Forward-slash the himmel path so the `node "..."` command is valid.
        $himmelFwd = $HimmelPath.Replace('\', '/')
        $cmd = "node `"$himmelFwd/marketplace/plugins/claude-hud/dist/index.js`""

        # The hud's plugin dir is per-USER (the config dir), never derived from
        # the settings path -- see (3) below. Resolved up here because both
        # halves of the changed-wiring test in (4) are read BEFORE the write.
        $hudDir = Join-Path (Get-ClaudeConfigDir) 'plugins/claude-hud'
        $hudConfigPath = Join-Path $hudDir 'config.json'
        # [string] cast: Get-Content -Raw returns $null for a 0-byte file, and
        # $null.TrimEnd() would throw in the comparison below.
        $prevHudCfg = if (Test-Path $hudConfigPath) { [string](Get-Content $hudConfigPath -Raw) } else { '' }

        $settingsDir = Split-Path $SettingsPath -Parent
        if (-not $settingsDir) { $settingsDir = '.' }

        $prevCmd = ''
        if (Test-Path $SettingsPath) {
            $raw = Get-Content $SettingsPath -Raw
            if ([string]::IsNullOrWhiteSpace($raw)) {
                # Empty / whitespace-only file → start from {} (ConvertFrom-Json
                # returns $null on empty input, which then throws on property access).
                $cfg = [pscustomobject]@{}
            } else {
                try {
                    $cfg = $raw | ConvertFrom-Json
                    # `"statusLine": null` is valid JSON and makes the
                    # property EXIST while its value is $null, so the property
                    # test alone is not enough to dereference it (codex-1).
                    if ($null -ne $cfg.statusLine -and $cfg.statusLine.PSObject.Properties['command']) {
                        $prevCmd = [string]$cfg.statusLine.command
                    }
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

        # (3) Stage the hud config under the CONFIG DIR, substituting this clone's
        # path for the <himmel-path> placeholder. Guarded on the source existing so
        # tests wiring against a synthetic himmel path stay a pure statusLine/env op.
        # HIMMEL-2892: the destination is ${CLAUDE_CONFIG_DIR:-~/.claude}, never
        # $settingsDir -- even for a PROJECT settings path. The hud reads its
        # config from the config dir, so a copy beside a project's
        # .claude/settings.json is inert AND an untracked file inside a repo.
        $hudSrc = "$himmelFwd/marketplace/plugins/claude-hud/config/himmel-config.json"
        $hudCfg = ''
        $hudTmp = ''
        if (Test-Path $hudSrc) {
            New-Item -ItemType Directory -Force $hudDir | Out-Null
            $hudCfg = (Get-Content $hudSrc -Raw).Replace('<himmel-path>', $himmelFwd).Replace("`r`n", "`n")
            # Staged as a DOTFILE so the purge below (which runs before
            # anything is published) skips it — see the bash twin's comment.
            $hudTmp = Join-Path $hudDir '.config.json.tmp'
            # UTF-8 without BOM; single trailing LF (matches the bash twin's printf).
            [System.IO.File]::WriteAllText($hudTmp, $hudCfg.TrimEnd("`n") + "`n")
            # Validate the substituted config is still JSON before publishing it — a
            # JSON-breaking himmel path would otherwise yield a config.json the
            # renderer fails on silently at render time. jq is optional here (matches
            # the ConvertTo-Json fallback below); skip the check when it is absent.
            if (Get-Command jq -ErrorAction SilentlyContinue) {
                & jq -e . $hudTmp *> $null
                if ($LASTEXITCODE -ne 0) {
                    Remove-Item -LiteralPath $hudTmp -Force
                    throw "wire-statusline: substituted hud config is not valid JSON — refusing to write"
                }
            }
        }

        # Stage the transformed settings BEFORE the purge, so anything that can
        # fail still leaves the old wiring on disk (CR round 6 — the bash twin's
        # (2) carries the reasoning).
        $json = $cfg | ConvertTo-Json -Depth 20
        if (Get-Command jq -ErrorAction SilentlyContinue) {
            $normalized = $json | jq --indent 2 .
            if ($LASTEXITCODE -eq 0 -and $normalized) { $json = $normalized -join "`n" }
        }
        # -ErrorAction Stop for the same reason the purge and the publishes carry
        # it: under the 'Continue' preference `pwsh -File` runs with, a failed
        # staging write is NON-terminating, and the run would go on to purge the
        # caches and publish the config before the settings rename finally threw.
        Set-Content -Path "$SettingsPath.new" -Value $json -Encoding utf8 -ErrorAction Stop

        # (4) HIMMEL-3065: the wiring CHANGED when either half differs from what
        # was already on this machine -- a different hud config, or an EXISTING
        # statusLine command that pointed somewhere else (a moved or renamed
        # clone, an older himmel instance). Both are compared against values
        # captured BEFORE anything is published; a re-run that changes neither
        # purges nothing, so a live session keeps its snapshots. Trailing
        # newlines are normalized out of the config comparison, matching the
        # bash twin's $(cat ...).
        # The command half requires a NON-EMPTY $prevCmd — see the bash twin's
        # header for why (codex-2: $SettingsPath may be a PROJECT file while
        # the caches are per-USER, so a machine's second project would
        # otherwise purge every other project's live snapshots).
        # The purge runs BEFORE either file is published, and a failed purge
        # throws with NOTHING written (CR round 2) — publish-then-purge left a
        # failed purge unrepeatable, because the retry saw wiring that already
        # matched and took the no-change path.
        # -cne, not -ne: PowerShell's -ne is case-INSENSITIVE, so a case-only
        # difference in the clone path or a config value would compare equal
        # here and publish without invalidating the cached state, while the bash
        # twin's string comparison treats it as a change. The twins have to
        # agree on what counts as a changed wiring.
        $cfgChanged = $hudCfg -and ($prevHudCfg.TrimEnd("`n") -cne $hudCfg.TrimEnd("`n"))
        $cmdChanged = $prevCmd -and ($prevCmd -cne $cmd)
        if ($cmdChanged -or $cfgChanged) {
            try {
                Remove-HimmelHudCacheState -HudDir $hudDir
            } catch {
                if ($hudTmp -and (Test-Path $hudTmp)) { Remove-Item -LiteralPath $hudTmp -Force }
                if (Test-Path "$SettingsPath.new") { Remove-Item -LiteralPath "$SettingsPath.new" -Force }
                throw
            }
        }

        # (5) Publish the staged hud config FIRST, the settings file LAST — the
        # two renames cannot be one atomic operation, and this order leaves a
        # failed second rename on the OLD statusLine command with a refreshed
        # config, which the next run still detects and re-wires. See the bash
        # twin's (4) for the full reasoning.
        if ($hudTmp -and (Test-Path $hudTmp)) {
            Move-Item -Path $hudTmp -Destination $hudConfigPath -Force -ErrorAction Stop
        }
        Move-Item -Path "$SettingsPath.new" -Destination $SettingsPath -Force -ErrorAction Stop
        Write-Host "  wired statusLine → $SettingsPath"
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
        $global:OutputEncoding = $prevOutEncodingPref
    }
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
