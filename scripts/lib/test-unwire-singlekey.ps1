# test-unwire-singlekey.ps1 -- committed PS test for the single-key unwire helpers
# (unwire-statusline.ps1, unwire-himmel-repo.ps1, unwire-luna-vault.ps1; SC6).
# Plus a .sh/.ps1 byte-parity assertion (both libs normalize through `jq --indent 2`,
# so identical input must yield identical output). Run:
#   pwsh -File test-unwire-singlekey.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'unwire-statusline.ps1')
. (Join-Path $here 'unwire-himmel-repo.ps1')
. (Join-Path $here 'unwire-luna-vault.ps1')
$fails = 0
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}
function JqVal($file, $expr) { Get-Content $file -Raw | jq -r $expr }

$td = Join-Path ([System.IO.Path]::GetTempPath()) ("unwiresk-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $td | Out-Null

# 1. statusline: removes himmel statusLine, preserves siblings.
$s = Join-Path $td 'sl1.json'
'{"statusLine":{"type":"command","command":"bash \"C:/h/scripts/statusline/bin/statusline.sh\""},"env":{"X":"1"}}' | Set-Content $s -Encoding utf8
Remove-Statusline -SettingsPath $s | Out-Null
Check 'statusLine removed'      (JqVal $s 'has("statusLine")') 'false'
Check 'statusLine sibling kept' (JqVal $s '.env.X') '1'

# 2. non-himmel statusLine left untouched.
$s = Join-Path $td 'sl2.json'
'{"statusLine":{"type":"command","command":"bash /opt/my-own-statusline.sh"}}' | Set-Content $s -Encoding utf8
Remove-Statusline -SettingsPath $s | Out-Null
Check 'custom statusLine preserved' (JqVal $s '.statusLine.command') 'bash /opt/my-own-statusline.sh'

# 3. himmel-repo: removes key, preserves siblings.
$s = Join-Path $td 'hr1.json'
'{"env":{"HIMMEL_REPO":"C:/h","HIMMEL_INITIATIVE":"all"}}' | Set-Content $s -Encoding utf8
Remove-HimmelRepo -SettingsPath $s | Out-Null
Check 'HIMMEL_REPO removed'    (JqVal $s '.env.HIMMEL_REPO // "ABSENT"') 'ABSENT'
Check 'HIMMEL_INITIATIVE kept' (JqVal $s '.env.HIMMEL_INITIATIVE') 'all'

# 4. himmel-repo: env pruned when empty.
$s = Join-Path $td 'hr2.json'
'{"statusLine":{"x":1},"env":{"HIMMEL_REPO":"C:/h"}}' | Set-Content $s -Encoding utf8
Remove-HimmelRepo -SettingsPath $s | Out-Null
Check 'empty env pruned' (JqVal $s 'has("env")') 'false'

# 5. luna-vault: removes key, preserves siblings.
$s = Join-Path $td 'lv1.json'
'{"env":{"LUNA_VAULT_PATH":"C:/v","HIMMEL_REPO":"C:/h"}}' | Set-Content $s -Encoding utf8
Remove-LunaVault -SettingsPath $s | Out-Null
Check 'LUNA_VAULT_PATH removed' (JqVal $s '.env.LUNA_VAULT_PATH // "ABSENT"') 'ABSENT'
Check 'HIMMEL_REPO kept'        (JqVal $s '.env.HIMMEL_REPO') 'C:/h'

# 6. shared invariants: absent file -> no-op; invalid JSON refused.
$missing = Join-Path $td 'missing.json'
Remove-HimmelRepo -SettingsPath $missing | Out-Null
Check 'absent -> not created' (Test-Path $missing) $false
$bad = Join-Path $td 'bad.json'; 'nope {' | Set-Content $bad -Encoding utf8
$threw = $false
try { Remove-LunaVault -SettingsPath $bad | Out-Null } catch { $threw = $true }
if ($threw) { Write-Host 'ok - refuses invalid JSON' } else { Write-Host 'FAIL: invalid JSON not refused'; $fails++ }

# 7. .sh/.ps1 byte-parity (skip if Git Bash unavailable -- never the System32 WSL stub).
$gitBash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $gitBash)) {
    $bc = Get-Command bash -ErrorAction SilentlyContinue
    if ($bc -and $bc.Source -notmatch 'System32') { $gitBash = $bc.Source } else { $gitBash = $null }
}
if ($gitBash) {
    $pairs = @(
        @{ ps = { param($p) Remove-HimmelRepo -SettingsPath $p }; sh = 'unwire-himmel-repo.sh'; json = '{"env":{"HIMMEL_REPO":"C:/h","HIMMEL_INITIATIVE":"all"}}' },
        @{ ps = { param($p) Remove-LunaVault -SettingsPath $p };  sh = 'unwire-luna-vault.sh';  json = '{"env":{"LUNA_VAULT_PATH":"C:/v","K":"1"}}' },
        @{ ps = { param($p) Remove-Statusline -SettingsPath $p }; sh = 'unwire-statusline.sh';  json = '{"statusLine":{"type":"command","command":"bash \"C:/h/scripts/statusline/bin/statusline.sh\""},"env":{"X":"1"}}' }
    )
    foreach ($pair in $pairs) {
        $pf = Join-Path $td ("par-ps-" + $pair.sh + ".json")
        $sf = Join-Path $td ("par-sh-" + $pair.sh + ".json")
        $pair.json | Set-Content $pf -Encoding utf8
        $pair.json | Set-Content $sf -Encoding utf8
        & $pair.ps $pf | Out-Null
        & $gitBash (Join-Path $here $pair.sh).Replace('\','/') $sf.Replace('\','/') | Out-Null
        $pOut = (Get-Content $pf -Raw).Replace("`r`n","`n").TrimEnd("`n")
        $sOut = (Get-Content $sf -Raw).Replace("`r`n","`n").TrimEnd("`n")
        Check ("parity " + $pair.sh) $pOut $sOut
    }
} else {
    Write-Host 'skip - .sh/.ps1 parity (Git Bash not found)'
}

Remove-Item -Recurse -Force $td
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
