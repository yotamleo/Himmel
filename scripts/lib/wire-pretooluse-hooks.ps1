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
# Windows backslash path does not collapse when the hook command is parsed, and
# SHELL-ESCAPES it for the double-quoted context it lands in (HIMMEL-2905) --
# see $WireHookCmdJq below.
#
# The PreToolUse block MERGES; it is never regenerated (HIMMEL-2892). himmel
# owns exactly one field of an entry it installed -- that entry's `command`.
# The stanza's matcher, its position, the entry's timeout, and every foreign
# stanza or co-located foreign entry survive byte-for-byte. A hook registered
# under two DISTINCT matchers keeps both registrations (dedup is per matcher).
#
# Dot-source to get the functions, or invoke directly:
#   pwsh -File wire-pretooluse-hooks.ps1 -SettingsPath <path> -Prefix <prefix> [-DryRun]

[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$Prefix,
    [switch]$DryRun
)

# The hook-command composer, VERBATIM twin of WIRE_HOOK_CMD_JQ in
# wire-pretooluse-hooks.sh -- keep the two byte-identical. Both the PreToolUse
# specs and the SessionStart hook object are built through it.
#
# HIMMEL-2892 round 6 / HIMMEL-2905: jq escapes the JSON layer, but the
# `command` it carries is a SHELL string Claude Code hands to a shell. It lands
# inside DOUBLE quotes, where exactly four characters keep their meaning -- `\`,
# `"`, `$` and a backtick -- so shesc() backslash-escapes those four and nothing
# else. Before this, a checkout at e.g. `/opt/we"ird/clone` yielded
# `bash "/opt/we"ird/clone/.../X.sh"`, whose unmatched quote is a syntax error:
# the hook never ran and every installed guard was silently inert there.
#
# The ONE exemption is the project-scope prefix, the literal UNEXPANDED
# `$CLAUDE_PROJECT_DIR` that Claude Code expands at hook-fire time -- escaping
# its `$` would point every project-scope hook at a path that does not exist.
# $rel, the hook BASENAME, gets no exemption: it is an ARGUMENT of the public
# Set-SessionStartHook, not a hardcoded literal (CodeRabbit, PR #612).
$WireHookCmdJq = @'
  def shesc($p):
    $p | split("\\") | join("\\\\")
       | split("\"") | join("\\\"")
       | split("$")  | join("\\$")
       | split("`")  | join("\\`");
  def hookcmd($pfx; $rel):
    "bash \"" + (if $pfx == "$CLAUDE_PROJECT_DIR" then $pfx else shesc($pfx) end)
    + "/scripts/hooks/" + shesc($rel) + "\"";
'@

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
    #
    # Built by `jq -n --arg pfx`, never by interpolating $pfx into JSON TEXT
    # (CodeRabbit round 1): a path may contain a `"`, which makes hand-written
    # JSON malformed; jq then rejects --argjson outright and the settings file
    # goes unwired while the caller reads success. The jq program below is the
    # bash twin's, verbatim.
    $specsProgram = $WireHookCmdJq + @'
    def spec($name; $matcher):
      hookcmd($pfx; $name + ".sh") as $cmd
      | { pat: ("scripts/hooks/" + $name + "[.]sh"),
          cmd: $cmd,
          stanza: { matcher: $matcher, hooks: [ { type: "command", command: $cmd } ] } };
    [ spec("auto-approve-safe-bash"; "Bash"),
      spec("block-edit-on-main"; "Edit|Write|MultiEdit|NotebookEdit"),
      spec("block-read-secrets"; "Bash|PowerShell|Read|Grep") ]
'@
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
        # jq builds the specs so the prefix is ESCAPED, not interpolated (see
        # $specsProgram above). Inside the encoding guard: jq output is captured.
        $specs = (& jq -n --arg pfx $pfx $specsProgram) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "wire-pretooluse-hooks: jq failed to build the hook specs" }
        $base = Read-SettingsBase -SettingsPath $SettingsPath -Who 'wire-pretooluse-hooks'
        # Verbatim twin of WIRE_PRETOOLUSE_MERGE_JQ in wire-pretooluse-hooks.sh
        # -- keep the two byte-identical. MERGE, never regenerate: every entry
        # matching a spec has its `command` rewritten in place (matcher,
        # position, timeout and every foreign entry survive untouched), and a
        # canonical stanza is appended only when nothing matched (HIMMEL-2892).
        # Dedup is per (spec, MATCHER): a hook registered under two DISTINCT
        # matchers keeps both registrations; only a repeat under a matcher
        # already carrying it is dropped (CR round 1, [codex-1]).
        $filter = @'
  def wire($spec):
    (reduce .[] as $st ({seen: [], out: []};
       ($st.matcher) as $m
       | (reduce ($st.hooks // [])[] as $h ({seen: .seen, hooks: []};
            if (($h.command // "") | test($spec.pat))
            then (if (.seen | any(. == $m))
                  then .
                  else {seen: (.seen + [$m]), hooks: (.hooks + [$h | .command = $spec.cmd])}
                  end)
            else {seen: .seen, hooks: (.hooks + [$h])}
            end)) as $r
       | {seen: $r.seen,
          out: (.out + (if ($r.hooks | length) > 0 then [$st | .hooks = $r.hooks] else [] end))}
     )) as $acc
    | if ($acc.seen | length) > 0 then $acc.out else ($acc.out + [$spec.stanza]) end;
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
    # The command is composed by jq (hookcmd), never by PowerShell string
    # interpolation, so it carries exactly the same shell escaping as the
    # PreToolUse trio and the bash twin (HIMMEL-2905). The dedup test is built
    # from the SAME escaped string inside the same jq program (CR round 3), so
    # the two can never disagree and no regex-escaping is needed.
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
        $filter = $WireHookCmdJq + @'
hookcmd($pfx; $hook) as $cmd
| ("scripts/hooks/" + shesc($hook)) as $needle
| .hooks = (.hooks // {})
| .hooks.SessionStart = ((.hooks.SessionStart // [])
    | map(.hooks = ((.hooks // [])
        | map(select((.command // "") | contains($needle) | not))))
    | map(select((.hooks | length) > 0)))
| (.hooks.SessionStart | map(has("matcher") | not) | index(true)) as $idx
| if $idx == null
  then .hooks.SessionStart += [{"hooks":[{"type":"command","command":$cmd}]}]
  else .hooks.SessionStart[$idx].hooks += [{"type":"command","command":$cmd}]
  end
'@
        $out = $base | jq --indent 2 --arg pfx $pfx --arg hook $HookBasename $filter
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
