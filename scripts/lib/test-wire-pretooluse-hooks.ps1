# test-wire-pretooluse-hooks.ps1 -- committed PS test for wire-pretooluse-hooks.ps1.
# Covers: PreToolUse trio wired + forward-slashed/quoted; dedup-by-basename across
# a clone-path change (SC8); rtk guard preserved; SessionStart shared-array merge +
# sibling survival; idempotent; invalid JSON refused; the hook path is
# SHELL-ESCAPED while the project-scope $CLAUDE_PROJECT_DIR literal survives
# unexpanded (HIMMEL-2905). Run:
#   pwsh -File test-wire-pretooluse-hooks.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wire = Join-Path $here 'wire-pretooluse-hooks.ps1'
. $wire
$fails = 0
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}
function JqVal($file, $expr) { Get-Content $file -Raw | jq -r $expr }

$td = Join-Path ([System.IO.Path]::GetTempPath()) ("wireph-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $td | Out-Null

# 1. missing file -> 3 stanzas, forward-slashed + quoted.
$s1 = Join-Path $td 's1.json'
Set-PretooluseHooks -SettingsPath $s1 -Prefix 'C:/himmel' | Out-Null
Check '3 PreToolUse stanzas'     (JqVal $s1 '.hooks.PreToolUse | length') '3'
Check 'auto-approve quoted path' (JqVal $s1 '.hooks.PreToolUse[0].hooks[0].command') 'bash "C:/himmel/scripts/hooks/auto-approve-safe-bash.sh"'

# 2. backslash prefix -> forward-slashed.
$s2 = Join-Path $td 's2.json'
Set-PretooluseHooks -SettingsPath $s2 -Prefix 'C:\Users\me\himmel' | Out-Null
Check 'backslash forward-slashed' (JqVal $s2 '.hooks.PreToolUse[1].hooks[0].command') 'bash "C:/Users/me/himmel/scripts/hooks/block-edit-on-main.sh"'

# 3. SC8: clone-path change -> still exactly 3, new path.
$s3 = Join-Path $td 's3.json'
Set-PretooluseHooks -SettingsPath $s3 -Prefix 'C:/old/himmel' | Out-Null
Set-PretooluseHooks -SettingsPath $s3 -Prefix 'C:/new/himmel' | Out-Null
Check 'clone-path change: still 3'  (JqVal $s3 '.hooks.PreToolUse | length') '3'
Check 'clone-path change: new path' (JqVal $s3 '.hooks.PreToolUse[0].hooks[0].command') 'bash "C:/new/himmel/scripts/hooks/auto-approve-safe-bash.sh"'

# 4. rtk guard co-located in the Bash stanza survives; himmel object replaced.
$s4 = Join-Path $td 's4.json'
'{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rtk-hook-guard.sh"},{"type":"command","command":"bash /old/scripts/hooks/auto-approve-safe-bash.sh"}]}]}}' | Set-Content $s4 -Encoding utf8
Set-PretooluseHooks -SettingsPath $s4 -Prefix 'C:/himmel' | Out-Null
Check 'rtk guard survives' (JqVal $s4 '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length') '1'
Check 'himmel object no-dup' (JqVal $s4 '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length') '1'

# 5. SessionStart shared-array merge: inject-initiative beside a sibling.
$s5 = Join-Path $td 's5.json'
'{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /x/scripts/hooks/check-update-available.sh"}]}]}}' | Set-Content $s5 -Encoding utf8
Set-SessionStartHook -SettingsPath $s5 -Prefix 'C:/himmel' -HookBasename 'inject-initiative.sh' | Out-Null
Check 'SessionStart stanza count' (JqVal $s5 '.hooks.SessionStart | length') '1'
Check 'sibling check-update kept' (JqVal $s5 '[.hooks.SessionStart[].hooks[].command | select(test("check-update-available"))] | length') '1'
Check 'inject-initiative added'   (JqVal $s5 '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length') '1'

# 6. SessionStart dedup across changed clone path -> single object, new path.
Set-SessionStartHook -SettingsPath $s5 -Prefix 'C:/moved/himmel' -HookBasename 'inject-initiative.sh' | Out-Null
Check 'inject-initiative dedup'    (JqVal $s5 '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length') '1'

# 7. idempotent PreToolUse re-run -> identical bytes.
$s7 = Join-Path $td 's7.json'
Set-PretooluseHooks -SettingsPath $s7 -Prefix 'C:/himmel' | Out-Null
$b7 = Get-Content $s7 -Raw
Set-PretooluseHooks -SettingsPath $s7 -Prefix 'C:/himmel' | Out-Null
Check 'PreToolUse idempotent' (Get-Content $s7 -Raw) $b7

# 7c. whitespace-only existing file -> treated as {} (not refused), 3 stanzas.
$s7c = Join-Path $td 's7c.json'
"   `n" | Set-Content $s7c -Encoding utf8
Set-PretooluseHooks -SettingsPath $s7c -Prefix 'C:/himmel' | Out-Null
Check 'whitespace file -> 3 stanzas' (JqVal $s7c '.hooks.PreToolUse | length') '3'

# 7d. BOM-less output: the written file must NOT start with a UTF-8 BOM (EF BB BF).
$bytes = [System.IO.File]::ReadAllBytes($s7c)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Check 'no UTF-8 BOM written' $hasBom $false

# 8. invalid JSON -> throws (caught), file unchanged.
$s8 = Join-Path $td 's8.json'
'nope {' | Set-Content $s8 -Encoding utf8
$threw = $false
try { Set-PretooluseHooks -SettingsPath $s8 -Prefix 'C:/himmel' | Out-Null } catch { $threw = $true }
if ($threw) { Write-Host 'ok - refuses invalid JSON' } else { Write-Host 'FAIL: invalid JSON not refused'; $fails++ }
Check 'invalid file unchanged' ((Get-Content $s8 -Raw).Trim()) 'nope {'

# 9. HIMMEL-2905: a prefix carrying shell metacharacters is SHELL-ESCAPED for
# the double-quoted context the command lands in — twin of case 8f in
# test-wire-pretooluse-hooks.sh. Pre-fix the composer emitted
# `bash "/opt/we"ird/clone/.../X.sh"`, whose unmatched quote is a syntax error,
# so the hook never ran and every installed guard was silently inert there.
# Asserted as a string equality rather than the bash twin's `bash -n -c`
# round-trip, so the case needs no bash on PATH; the bash twin carries the
# round-trip proof.
$s9 = Join-Path $td 's9.json'
Set-PretooluseHooks -SettingsPath $s9 -Prefix '/opt/we"ird/clone' | Out-Null
Check 'quote in prefix: block still wired' (JqVal $s9 '.hooks.PreToolUse | length') '3'
Check 'quote in prefix: path is shell-escaped' (JqVal $s9 '.hooks.PreToolUse[0].hooks[0].command') 'bash "/opt/we\"ird/clone/scripts/hooks/auto-approve-safe-bash.sh"'
$s9b = Join-Path $td 's9b.json'
Set-SessionStartHook -SettingsPath $s9b -Prefix '/opt/we"ird/clone' -HookBasename 'inject-initiative.sh' | Out-Null
Check 'quote in prefix: SessionStart path is shell-escaped' (JqVal $s9b '.hooks.SessionStart[0].hooks[0].command') 'bash "/opt/we\"ird/clone/scripts/hooks/inject-initiative.sh"'

# 9b. CodeRabbit on PR #612: the hook BASENAME goes through the same escaper.
# It is an ARGUMENT of Set-SessionStartHook, not a hardcoded literal like the
# trio's names, so leaving it unescaped covered only half the composer's input.
$s9c = Join-Path $td 's9c.json'
Set-SessionStartHook -SettingsPath $s9c -Prefix 'C:/himmel' -HookBasename 'we"ird-hook.sh' | Out-Null
Check 'quote in basename: basename is shell-escaped' (JqVal $s9c '.hooks.SessionStart[0].hooks[0].command') 'bash "C:/himmel/scripts/hooks/we\"ird-hook.sh"'

# 10. NEGATIVE control for 9 (load-bearing): the project-scope prefix is the
# literal, UNEXPANDED $CLAUDE_PROJECT_DIR that Claude Code expands at hook-fire
# time. Escaping its `$` would point every project-scope hook at a path that
# does not exist. Without this case, 9 would pass on a blanket escape.
$s10 = Join-Path $td 's10.json'
Set-PretooluseHooks -SettingsPath $s10 -Prefix '$CLAUDE_PROJECT_DIR' | Out-Null
Check 'project scope: unexpanded literal kept' (JqVal $s10 '.hooks.PreToolUse[0].hooks[0].command') 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh"'
$s10b = Join-Path $td 's10b.json'
Set-SessionStartHook -SettingsPath $s10b -Prefix '$CLAUDE_PROJECT_DIR' -HookBasename 'inject-initiative.sh' | Out-Null
Check 'project scope: SessionStart keeps the literal' (JqVal $s10b '.hooks.SessionStart[0].hooks[0].command') 'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/inject-initiative.sh"'

Remove-Item -Recurse -Force $td
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
