# test-unwire-pretooluse-hooks.ps1 -- committed PS test for unwire-pretooluse-hooks.ps1.
# Covers: removes the UNIVERSAL trio + inject-initiative; SC12 sibling survives;
# HIMMEL-DEV-ONLY hooks survive; idempotent; absent -> no-op; invalid JSON refused;
# -Scope project -Target. Run: pwsh -File test-unwire-pretooluse-hooks.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$unwire = Join-Path $here 'unwire-pretooluse-hooks.ps1'
. $unwire
$fails = 0
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}
function JqVal($file, $expr) { Get-Content $file -Raw | jq -r $expr }

$td = Join-Path ([System.IO.Path]::GetTempPath()) ("unwireph-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $td | Out-Null

$fixture = '{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[
        {"type":"command","command":"bash C:/h/scripts/hooks/auto-approve-safe-bash.sh"},
        {"type":"command","command":"bash /opt/rtk-hook-guard.sh"}
      ]},
      {"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/block-edit-on-main.sh"}]},
      {"matcher":"Bash|PowerShell|Read|Grep","hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/block-read-secrets.sh"}]},
      {"matcher":"*","hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/auto-arm-on-cap.sh"}]}
    ],
    "SessionStart": [
      {"hooks":[
        {"type":"command","command":"bash C:/h/scripts/hooks/check-update-available.sh"},
        {"type":"command","command":"bash C:/h/scripts/hooks/inject-initiative.sh"}
      ]}
    ]
  }
}'

# 1. removes the trio, keeps rtk guard + dev-only auto-arm.
$s1 = Join-Path $td 's1.json'; $fixture | Set-Content $s1 -Encoding utf8
Remove-PretooluseHooks -SettingsPath $s1 | Out-Null
Check 'trio removed (auto-approve)' (JqVal $s1 '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length') '0'
Check 'rtk guard survives'          (JqVal $s1 '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length') '1'
Check 'dev-only auto-arm survives'  (JqVal $s1 '[.hooks.PreToolUse[].hooks[].command | select(test("auto-arm-on-cap"))] | length') '1'

# 2. SC12: inject-initiative spliced, check-update-available survives.
Check 'inject-initiative removed' (JqVal $s1 '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length') '0'
Check 'SC12 sibling survives'     (JqVal $s1 '[.hooks.SessionStart[].hooks[].command | select(test("check-update-available"))] | length') '1'

# 3. SessionStart stanza pruned when it ONLY held inject-initiative.
$s3 = Join-Path $td 's3.json'
'{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/inject-initiative.sh"}]}]}}' | Set-Content $s3 -Encoding utf8
Remove-PretooluseHooks -SettingsPath $s3 | Out-Null
Check 'empty SessionStart pruned' (JqVal $s3 '.hooks.SessionStart | length') '0'

# 4. idempotent re-run -> identical bytes.
$b1 = Get-Content $s1 -Raw
Remove-PretooluseHooks -SettingsPath $s1 | Out-Null
Check 'idempotent re-run' (Get-Content $s1 -Raw) $b1

# 5. absent -> no-op, not created.
$s5 = Join-Path $td 'missing.json'
Remove-PretooluseHooks -SettingsPath $s5 | Out-Null
Check 'absent -> not created' (Test-Path $s5) $false

# 6. invalid JSON -> throws, file unchanged.
$s6 = Join-Path $td 's6.json'; 'nope {' | Set-Content $s6 -Encoding utf8
$threw = $false
try { Remove-PretooluseHooks -SettingsPath $s6 | Out-Null } catch { $threw = $true }
if ($threw) { Write-Host 'ok - refuses invalid JSON' } else { Write-Host 'FAIL: invalid JSON not refused'; $fails++ }
Check 'invalid file unchanged' ((Get-Content $s6 -Raw).Trim()) 'nope {'

# 7. -Scope project -Target resolves <repo>/.claude/settings.json.
$proj = Join-Path $td 'proj'; New-Item -ItemType Directory -Force (Join-Path $proj '.claude') | Out-Null
$fixture | Set-Content (Join-Path $proj '.claude/settings.json') -Encoding utf8
& pwsh -NoProfile -File $unwire -Scope project -Target $proj | Out-Null
Check 'project-scope trio gone' (JqVal (Join-Path $proj '.claude/settings.json') '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length') '0'
Check 'project-scope dev hook kept' (JqVal (Join-Path $proj '.claude/settings.json') '[.hooks.PreToolUse[].hooks[].command | select(test("auto-arm-on-cap"))] | length') '1'

# 8. -DryRun mutates nothing.
$s8 = Join-Path $td 's8.json'; $fixture | Set-Content $s8 -Encoding utf8; $b8 = Get-Content $s8 -Raw
Remove-PretooluseHooks -SettingsPath $s8 -DryRun | Out-Null
Check 'dry-run no mutation' (Get-Content $s8 -Raw) $b8

Remove-Item -Recurse -Force $td
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
