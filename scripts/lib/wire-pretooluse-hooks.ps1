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
# The PreToolUse block MERGES; it is never regenerated (HIMMEL-2892). himmel
# owns exactly one field of an entry it installed -- that entry's `command`.
# The stanza's matcher, its position, the entry's timeout, and every foreign
# stanza or co-located foreign entry survive byte-for-byte.
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
    # One spec per himmel-owned hook -- twin of the bash lib's $specs. `pat`
    # identifies an entry THIS installer owns, `cmd` is the command it must
    # carry after the merge, `stanza` is appended only when the target carries
    # no such entry at all (HIMMEL-2892).
    $specs = @"
[
  {"pat":"scripts/hooks/auto-approve-safe-bash[.]sh",
   "cmd":"bash \"$pfx/scripts/hooks/auto-approve-safe-bash.sh\"",
   "stanza":{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$pfx/scripts/hooks/auto-approve-safe-bash.sh\""}]}},
  {"pat":"scripts/hooks/block-edit-on-main[.]sh",
   "cmd":"bash \"$pfx/scripts/hooks/block-edit-on-main.sh\"",
   "stanza":{"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash \"$pfx/scripts/hooks/block-edit-on-main.sh\""}]}},
  {"pat":"scripts/hooks/block-read-secrets[.]sh",
   "cmd":"bash \"$pfx/scripts/hooks/block-read-secrets.sh\"",
   "stanza":{"matcher":"Bash|PowerShell|Read|Grep","hooks":[{"type":"command","command":"bash \"$pfx/scripts/hooks/block-read-secrets.sh\""}]}}
]
"@
    if ($DryRun) { Write-Host "DRY: merge 3 PreToolUse hook stanzas into $SettingsPath (prefix: $Prefix)"; return }

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
        $base = Read-SettingsBase -SettingsPath $SettingsPath -Who 'wire-pretooluse-hooks'
        # Verbatim twin of WIRE_PRETOOLUSE_MERGE_JQ in wire-pretooluse-hooks.sh
        # -- keep the two byte-identical. MERGE, never regenerate: the first
        # entry matching a spec has its `command` rewritten in place (matcher,
        # position, timeout and every foreign entry survive untouched), later
        # duplicates are dropped, and a canonical stanza is appended only when
        # nothing matched (HIMMEL-2892).
        $filter = @'
  def wire($spec):
    (reduce .[] as $st ({seen: false, out: []};
       (reduce ($st.hooks // [])[] as $h ({seen: .seen, hooks: []};
          if (($h.command // "") | test($spec.pat))
          then (if .seen
                then .
                else {seen: true, hooks: (.hooks + [$h | .command = $spec.cmd])}
                end)
          else {seen: .seen, hooks: (.hooks + [$h])}
          end)) as $r
       | {seen: $r.seen,
          out: (.out + (if ($r.hooks | length) > 0 then [$st | .hooks = $r.hooks] else [] end))}
     )) as $acc
    | if $acc.seen then $acc.out else ($acc.out + [$spec.stanza]) end;
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = (reduce $specs[] as $spec ((.hooks.PreToolUse // []); wire($spec)))
'@
        $out = $base | jq --indent 2 --argjson specs $specs $filter
        if ($LASTEXITCODE -ne 0) { throw "wire-pretooluse-hooks: jq transform failed" }
        Write-SettingsAtomic -SettingsPath $SettingsPath -Json ($out -join "`n")
        Write-Host "  wired PreToolUse hooks -> $SettingsPath"
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
        $global:OutputEncoding = $prevOutEncodingPref
    }
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
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
        $global:OutputEncoding = $prevOutEncodingPref
    }
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
