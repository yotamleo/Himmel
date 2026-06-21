# unwire-pretooluse-hooks.ps1 -- PowerShell counterpart of unwire-pretooluse-hooks.sh.
# Removes himmel's UNIVERSAL hooks (PreToolUse trio + SessionStart inject-initiative)
# from a Claude Code settings.json by BASENAME, preserving every non-himmel hook and
# the HIMMEL-DEV-ONLY hooks. Shells out to jq for byte-parity with the bash twin.
#
#   Remove-PretooluseHooks -SettingsPath <path> [-DryRun]
#
# Usage (direct):
#   pwsh -File unwire-pretooluse-hooks.ps1 -SettingsPath <path> [-DryRun]
#   pwsh -File unwire-pretooluse-hooks.ps1 -Scope project -Target <repo> [-DryRun]
#
# Idempotent (absent -> no-op), atomic (temp + move), refuses invalid JSON,
# preserves siblings (SC12: a SessionStart sibling like check-update-available.sh
# survives). Requires jq.

[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$Scope,
    [string]$Target,
    [switch]$DryRun
)

$script:UnwirePrePat = 'scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)[.]sh'
$script:UnwireSsPat  = 'scripts/hooks/inject-initiative[.]sh'

function Remove-PretooluseHooks {
    param(
        [Parameter(Mandatory = $true)] [string]$SettingsPath,
        [switch]$DryRun
    )
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "unwire-pretooluse-hooks: jq required" }
    if (-not (Test-Path $SettingsPath)) {
        if ($DryRun) { Write-Host "DRY: $SettingsPath absent -> no-op" }
        return
    }
    $raw = Get-Content $SettingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if ($DryRun) { Write-Host "DRY: $SettingsPath empty -> no-op" }
        return
    }
    $raw | jq -e . > $null 2>&1
    if ($LASTEXITCODE -ne 0) { throw "unwire-pretooluse-hooks: $SettingsPath is not valid JSON -- refusing to modify" }
    if ($DryRun) {
        Write-Host "DRY: remove UNIVERSAL himmel hooks (PreToolUse trio + SessionStart inject-initiative) from $SettingsPath"
        return
    }
    $filter = @'
if (.hooks // {} | has("PreToolUse")) then
  .hooks.PreToolUse = ((.hooks.PreToolUse)
    | map(.hooks = ((.hooks // []) | map(select((.command // "") | test($pre) | not))))
    | map(select((.hooks | length) > 0)))
else . end
| if (.hooks // {} | has("SessionStart")) then
    .hooks.SessionStart = ((.hooks.SessionStart)
      | map(.hooks = ((.hooks // []) | map(select((.command // "") | test($ss) | not))))
      | map(select((.hooks | length) > 0)))
  else . end
'@
    $out = $raw | jq --indent 2 --arg pre $script:UnwirePrePat --arg ss $script:UnwireSsPat $filter
    if ($LASTEXITCODE -ne 0) { throw "unwire-pretooluse-hooks: jq transform failed" }
    $tmp = "$SettingsPath.unwirehooks.tmp"
    # UTF-8 without BOM (see wire-pretooluse-hooks.ps1) -- never BOM-corrupt the
    # operator's real settings.json on the teardown path.
    [System.IO.File]::WriteAllText($tmp, ($out -join "`n") + "`n")
    Move-Item -Path $tmp -Destination $SettingsPath -Force
    Write-Host "  removed UNIVERSAL himmel hooks -> $SettingsPath"
}

# Direct invocation. Dot-sourcing with no args just defines the function.
if ($Scope -eq 'project') {
    if (-not $Target) { Write-Error "unwire-pretooluse-hooks: -Scope project requires -Target <repo>"; exit 2 }
    $SettingsPath = Join-Path $Target '.claude/settings.json'
}
if ($SettingsPath) {
    try {
        Remove-PretooluseHooks -SettingsPath $SettingsPath -DryRun:$DryRun
    } catch {
        Write-Error $_
        exit 1
    }
}
