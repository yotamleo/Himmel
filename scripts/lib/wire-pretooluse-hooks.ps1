# wire-pretooluse-hooks.ps1 -- PowerShell counterpart of wire-pretooluse-hooks.sh.
# Merges himmel's UNIVERSAL hooks into a Claude Code settings.json idempotently.
# Shells out to jq for the JSON transform so output is byte-identical to the bash
# twin (jq is a required tool; the bash lib + wire-himmel-repo.ps1 already rely on
# it). Two functions:
#   Set-PretooluseHooks  -SettingsPath <path> -Prefix <prefix> [-DryRun]
#   Set-SessionStartHook -SettingsPath <path> -Prefix <prefix> -HookBasename <name> [-DryRun]
#
# Dedup is by hook BASENAME with REPLACE semantics (a re-run repairs a bad/moved
# install, never double-wires). Forward-slashes + quotes the hook path so a
# Windows backslash path does not collapse when the hook command is parsed.
#
# Dot-source to get the functions, or invoke directly:
#   pwsh -File wire-pretooluse-hooks.ps1 -SettingsPath <path> -Prefix <prefix> [-DryRun]

[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$Prefix,
    [switch]$DryRun
)

function Read-SettingsBase {
    param([Parameter(Mandatory = $true)][string]$SettingsPath, [string]$Who)
    if (Test-Path $SettingsPath) {
        $raw = Get-Content $SettingsPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return '{}' }
        $raw | jq -e . > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "$Who`: $SettingsPath is not valid JSON -- refusing to overwrite"
        }
        return $raw
    }
    $dir = Split-Path $SettingsPath
    if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
    return '{}'
}

function Write-SettingsAtomic {
    param([Parameter(Mandatory = $true)][string]$SettingsPath, [Parameter(Mandatory = $true)][string]$Json)
    $tmp = "$SettingsPath.wirehooks.tmp"
    # UTF-8 *without* BOM, version-independent: `Set-Content -Encoding utf8` emits
    # a BOM under Windows PowerShell 5.1, which has broken settings.json consumers
    # before (HIMMEL-365/408). WriteAllText(string,string) is BOM-less on all hosts.
    [System.IO.File]::WriteAllText($tmp, $Json + "`n")
    Move-Item -Path $tmp -Destination $SettingsPath -Force
}

function Set-PretooluseHooks {
    param(
        [Parameter(Mandatory = $true)] [string]$SettingsPath,
        [Parameter(Mandatory = $true)] [string]$Prefix,
        [switch]$DryRun
    )
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "wire-pretooluse-hooks: jq required" }
    $pfx = $Prefix.Replace('\', '/')
    $desired = @"
[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$pfx/scripts/hooks/auto-approve-safe-bash.sh\""}]},
  {"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash \"$pfx/scripts/hooks/block-edit-on-main.sh\""}]},
  {"matcher":"Bash|PowerShell|Read|Grep","hooks":[{"type":"command","command":"bash \"$pfx/scripts/hooks/block-read-secrets.sh\""}]}
]
"@
    if ($DryRun) { Write-Host "DRY: merge 3 PreToolUse hook stanzas into $SettingsPath (prefix: $Prefix)"; return }
    $base = Read-SettingsBase -SettingsPath $SettingsPath -Who 'wire-pretooluse-hooks'
    $filter = @'
.hooks = (.hooks // {})
| .hooks.PreToolUse = (
    ((.hooks.PreToolUse // [])
      | map(.hooks = ((.hooks // [])
          | map(select((.command // "")
                | test("scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)[.]sh") | not))))
      | map(select((.hooks | length) > 0)))
    + $add
  )
'@
    $out = $base | jq --indent 2 --argjson add $desired $filter
    if ($LASTEXITCODE -ne 0) { throw "wire-pretooluse-hooks: jq transform failed" }
    Write-SettingsAtomic -SettingsPath $SettingsPath -Json ($out -join "`n")
    Write-Host "  wired PreToolUse hooks -> $SettingsPath"
}

function Set-SessionStartHook {
    param(
        [Parameter(Mandatory = $true)] [string]$SettingsPath,
        [Parameter(Mandatory = $true)] [string]$Prefix,
        [Parameter(Mandatory = $true)] [string]$HookBasename,
        [switch]$DryRun
    )
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw "wire-pretooluse-hooks: jq required" }
    $pfx = $Prefix.Replace('\', '/')
    $cmd = "bash `"$pfx/scripts/hooks/$HookBasename`""
    $basepat = "scripts/hooks/" + ($HookBasename -replace '\.', '[.]')
    if ($DryRun) { Write-Host "DRY: merge SessionStart hook $HookBasename into $SettingsPath (prefix: $Prefix)"; return }
    $base = Read-SettingsBase -SettingsPath $SettingsPath -Who 'wire-pretooluse-hooks'
    $filter = @'
.hooks = (.hooks // {})
| .hooks.SessionStart = ((.hooks.SessionStart // [])
    | map(.hooks = ((.hooks // [])
        | map(select((.command // "") | test($basepat) | not))))
    | map(select((.hooks | length) > 0)))
| (.hooks.SessionStart | map(has("matcher") | not) | index(true)) as $idx
| if $idx == null
  then .hooks.SessionStart += [{"hooks":[{"type":"command","command":$cmd}]}]
  else .hooks.SessionStart[$idx].hooks += [{"type":"command","command":$cmd}]
  end
'@
    $out = $base | jq --indent 2 --arg cmd $cmd --arg basepat $basepat $filter
    if ($LASTEXITCODE -ne 0) { throw "wire-pretooluse-hooks: jq transform failed" }
    Write-SettingsAtomic -SettingsPath $SettingsPath -Json ($out -join "`n")
    Write-Host "  wired SessionStart $HookBasename -> $SettingsPath"
}

# Direct invocation (SettingsPath + Prefix supplied) wires the PreToolUse trio.
# Dot-sourcing with no args just defines the functions.
if ($SettingsPath -and $Prefix) {
    try {
        Set-PretooluseHooks -SettingsPath $SettingsPath -Prefix $Prefix -DryRun:$DryRun
    } catch {
        Write-Error $_
        exit 1
    }
}
