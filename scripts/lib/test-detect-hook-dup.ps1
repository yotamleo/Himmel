# test-detect-hook-dup.ps1 -- committed PS test for detect-hook-dup.ps1 (SC5).
# Warns iff a UNIVERSAL hook is wired at BOTH user + a NON-himmel project; silent
# in-repo and when nothing is shared. (SC11's benign-double-fire uses the bash
# hooks and lives in test-detect-hook-dup.sh.) Run: pwsh -File test-detect-hook-dup.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$det = Join-Path $here 'detect-hook-dup.ps1'
$fails = 0
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}

$td = Join-Path ([System.IO.Path]::GetTempPath()) ("dhd-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $td | Out-Null
$user = Join-Path $td 'user.json'
'{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /user/scripts/hooks/auto-approve-safe-bash.sh"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"bash /user/scripts/hooks/inject-initiative.sh"}]}]}}' | Set-Content $user -Encoding utf8

# SC5a: non-himmel project sharing a UNIVERSAL hook → warning.
New-Item -ItemType Directory -Force (Join-Path $td 'proj/.claude') | Out-Null
$proj = Join-Path $td 'proj/.claude/settings.json'
'{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /proj/scripts/hooks/auto-approve-safe-bash.sh"}]}]}}' | Set-Content $proj -Encoding utf8
$out = & pwsh -NoProfile -File $det -UserSettings $user -ProjectSettings $proj -HimmelRoot '/opt/himmel' 2>&1 | Out-String
Check 'SC5 warns on non-himmel dup' ($out -match 'BOTH user and project scope') $true
Check 'SC5 lists the dup hook'      ($out -match 'auto-approve-safe-bash') $true

# SC5b: in-repo (project == himmel's own settings) → silent.
$himmel = Join-Path $td 'himmel'
New-Item -ItemType Directory -Force (Join-Path $himmel '.claude') | Out-Null
$himmelSettings = Join-Path $himmel '.claude/settings.json'
Copy-Item $user $himmelSettings
$out = & pwsh -NoProfile -File $det -UserSettings $user -ProjectSettings $himmelSettings -HimmelRoot $himmel 2>&1 | Out-String
Check 'SC5 silent in-repo' ($out -match 'BOTH user and project') $false

# SC5c: project shares nothing → silent.
New-Item -ItemType Directory -Force (Join-Path $td 'proj2/.claude') | Out-Null
$proj2 = Join-Path $td 'proj2/.claude/settings.json'
'{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /p2/scripts/hooks/other.sh"}]}]}}' | Set-Content $proj2 -Encoding utf8
$out = & pwsh -NoProfile -File $det -UserSettings $user -ProjectSettings $proj2 -HimmelRoot '/opt/himmel' 2>&1 | Out-String
Check 'SC5 silent when no shared hook' ($out -match 'BOTH user and project') $false

# SC5d: SessionStart inject-initiative dup detected.
New-Item -ItemType Directory -Force (Join-Path $td 'proj3/.claude') | Out-Null
$proj3 = Join-Path $td 'proj3/.claude/settings.json'
'{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /p3/scripts/hooks/inject-initiative.sh"}]}]}}' | Set-Content $proj3 -Encoding utf8
$out = & pwsh -NoProfile -File $det -UserSettings $user -ProjectSettings $proj3 -HimmelRoot '/opt/himmel' 2>&1 | Out-String
Check 'SC5 detects SessionStart dup' ($out -match 'inject-initiative') $true

Remove-Item -Recurse -Force $td
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
