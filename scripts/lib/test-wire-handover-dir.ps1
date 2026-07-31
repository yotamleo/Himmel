# test-wire-handover-dir.ps1 -- committed PS test for wire-handover-dir.ps1
# (HIMMEL-839). Mirrors test-wire-luna-vault.ps1's shape (its own .env merge
# is genuinely new logic, and clobbering a sibling key is the highest-risk
# failure on the operator's primary platform, so it gets a real assertion, not
# parity-by-inspection). No case-8 "seam" test here: unlike LUNA_VAULT_PATH
# (consumed by vault-resolve.ps1), handover_root() has no PowerShell
# consumer -- it is read directly from the process env by bash-only handover
# tooling (scripts/lib/handover-path.sh). The final block is the cross-twin
# parity check: feed the same input to wire-handover-dir.sh (via Git Bash) and
# .ps1 and assert byte-identical .env.HANDOVER_DIR (skipped if bash absent).
# Run: pwsh -File test-wire-handover-dir.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wire = Join-Path $here 'wire-handover-dir.ps1'
$fails = 0
function Check($name, $got, $want) {
    if ($got -eq $want) { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}

$td = Join-Path ([System.IO.Path]::GetTempPath()) ("wirehd-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $td | Out-Null

# 1. existing sibling env key preserved + HANDOVER_DIR added.
$s1 = Join-Path $td 's1.json'
'{"statusLine":{"type":"command"},"env":{"HIMMEL_REPO":"C:/himmel"}}' | Set-Content $s1 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s1 -HandoverDir 'C:/Documents/luna/handovers' | Out-Null
$c1 = Get-Content $s1 -Raw | ConvertFrom-Json
Check 'sibling env key preserved' $c1.env.HIMMEL_REPO 'C:/himmel'
Check 'top-level key preserved'   $c1.statusLine.type 'command'
Check 'HANDOVER_DIR added'        $c1.env.HANDOVER_DIR 'C:/Documents/luna/handovers'

# 2. missing file -> created with env.HANDOVER_DIR.
$s2 = Join-Path $td 's2.json'
& pwsh -NoProfile -File $wire -SettingsPath $s2 -HandoverDir 'C:/Documents/luna/handovers' | Out-Null
$c2 = Get-Content $s2 -Raw | ConvertFrom-Json
Check 'create on missing file' $c2.env.HANDOVER_DIR 'C:/Documents/luna/handovers'

# 3. backslash -> forward-slashed.
$s3 = Join-Path $td 's3.json'
& pwsh -NoProfile -File $wire -SettingsPath $s3 -HandoverDir 'C:\Users\me\Documents\luna\handovers' | Out-Null
$c3 = Get-Content $s3 -Raw | ConvertFrom-Json
Check 'backslash forward-slashed' $c3.env.HANDOVER_DIR 'C:/Users/me/Documents/luna/handovers'

# 4. invalid JSON -> exit 1, file unchanged.
$s4 = Join-Path $td 's4.json'
'not json {' | Set-Content $s4 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s4 -HandoverDir 'C:/Documents/luna/handovers' 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host 'FAIL: invalid JSON not refused'; $fails++ }
else { Write-Host 'ok - refuses invalid JSON' }
Check 'invalid file unchanged' ((Get-Content $s4 -Raw).Trim()) 'not json {'

# 5. last-write-wins: re-run with a DIFFERENT target overwrites, keeps sibling.
# (Callers -- adopt.ps1's Wire-HandoverDirLuna -- are expected to check for an
# existing value BEFORE calling this; the wire script itself stays a dumb,
# unconditional setter, same division of labor as wire-luna-vault.ps1.)
$s5 = Join-Path $td 's5.json'
'{"env":{"HANDOVER_DIR":"C:/Documents/luna-old/handovers","KEEP":"x"}}' | Set-Content $s5 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s5 -HandoverDir 'C:/Documents/luna-new/handovers' | Out-Null
$c5 = Get-Content $s5 -Raw | ConvertFrom-Json
Check 'last-write-wins overwrite' $c5.env.HANDOVER_DIR 'C:/Documents/luna-new/handovers'
Check 'overwrite keeps sibling'   $c5.env.KEEP 'x'

# 6. idempotent -> second run identical bytes (PS serializer path).
$s6 = Join-Path $td 's6.json'
& pwsh -NoProfile -File $wire -SettingsPath $s6 -HandoverDir 'C:/Documents/luna/handovers' | Out-Null
$h6a = Get-Content $s6 -Raw
& pwsh -NoProfile -File $wire -SettingsPath $s6 -HandoverDir 'C:/Documents/luna/handovers' | Out-Null
Check 'idempotent re-run' (Get-Content $s6 -Raw) $h6a

# 7. whitespace-only file -> treated as {}, not refused.
$s7 = Join-Path $td 's7.json'
"   `n" | Set-Content $s7 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s7 -HandoverDir 'C:/Documents/luna/handovers' | Out-Null
$c7 = Get-Content $s7 -Raw | ConvertFrom-Json
Check 'whitespace file -> created' $c7.env.HANDOVER_DIR 'C:/Documents/luna/handovers'

# 8. cross-twin parity: same backslash input to .sh (Git Bash) and .ps1 must
#    yield byte-identical .env.HANDOVER_DIR. Skip cleanly if no Git Bash.
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $gitBash)) {
    $bc = Get-Command bash -ErrorAction SilentlyContinue
    $gitBash = if ($bc -and $bc.Source -notmatch 'System32') { $bc.Source } else { $null }
}
if ($gitBash) {
    $shWire = (Join-Path $here 'wire-handover-dir.sh').Replace('\', '/')
    $pIn = 'C:\Users\me\Documents\luna\handovers'
    $shOut = (Join-Path $td 'parity_sh.json').Replace('\', '/')
    $psOut = Join-Path $td 'parity_ps.json'
    & $gitBash $shWire $shOut $pIn | Out-Null
    & pwsh -NoProfile -File $wire -SettingsPath $psOut -HandoverDir $pIn | Out-Null
    $shVal = (Get-Content $shOut -Raw | ConvertFrom-Json).env.HANDOVER_DIR
    $psVal = (Get-Content $psOut -Raw | ConvertFrom-Json).env.HANDOVER_DIR
    Check 'cross-twin .sh/.ps1 parity (HANDOVER_DIR)' $psVal $shVal
} else {
    Write-Host 'skip - cross-twin parity (Git Bash not found)'
}

Remove-Item -Recurse -Force $td
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
