# test-wire-luna-vault.ps1 -- committed PS test for wire-luna-vault.ps1
# (HIMMEL-458). The .env merge is genuinely new logic vs the statusline twin's
# single-object set, and clobbering a sibling key (e.g. HIMMEL_REPO) is the
# highest-risk failure on the operator's primary platform -- so it gets a real
# assertion, not parity-by-inspection. The final block is the F1-SC4 CROSS-TWIN
# parity check: feed the same input to wire-luna-vault.sh (via Git Bash) and
# .ps1 and assert byte-identical .env.LUNA_VAULT_PATH (skipped if bash absent).
# Run: pwsh -File test-wire-luna-vault.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wire = Join-Path $here 'wire-luna-vault.ps1'
$fails = 0
function Check($name, $got, $want) {
    if ($got -eq $want) { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}

$td = Join-Path ([System.IO.Path]::GetTempPath()) ("wirelv-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $td | Out-Null

# 1. existing sibling env key preserved + LUNA_VAULT_PATH added (F1-SC2).
$s1 = Join-Path $td 's1.json'
'{"statusLine":{"type":"command"},"env":{"HIMMEL_REPO":"C:/himmel"}}' | Set-Content $s1 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s1 -VaultPath 'C:/Documents/luna' | Out-Null
$c1 = Get-Content $s1 -Raw | ConvertFrom-Json
Check 'sibling env key preserved' $c1.env.HIMMEL_REPO 'C:/himmel'
Check 'top-level key preserved'   $c1.statusLine.type 'command'
Check 'LUNA_VAULT_PATH added'      $c1.env.LUNA_VAULT_PATH 'C:/Documents/luna'

# 2. missing file -> created with env.LUNA_VAULT_PATH.
$s2 = Join-Path $td 's2.json'
& pwsh -NoProfile -File $wire -SettingsPath $s2 -VaultPath 'C:/Documents/luna' | Out-Null
$c2 = Get-Content $s2 -Raw | ConvertFrom-Json
Check 'create on missing file' $c2.env.LUNA_VAULT_PATH 'C:/Documents/luna'

# 3. backslash -> forward-slashed.
$s3 = Join-Path $td 's3.json'
& pwsh -NoProfile -File $wire -SettingsPath $s3 -VaultPath 'C:\Users\me\Documents\luna' | Out-Null
$c3 = Get-Content $s3 -Raw | ConvertFrom-Json
Check 'backslash forward-slashed' $c3.env.LUNA_VAULT_PATH 'C:/Users/me/Documents/luna'

# 4. invalid JSON -> exit 1, file unchanged (F1-SC3).
$s4 = Join-Path $td 's4.json'
'not json {' | Set-Content $s4 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s4 -VaultPath 'C:/Documents/luna' 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host 'FAIL: invalid JSON not refused'; $fails++ }
else { Write-Host 'ok - refuses invalid JSON' }
Check 'invalid file unchanged' ((Get-Content $s4 -Raw).Trim()) 'not json {'

# 5. last-adopt-wins (F1-SC6): re-run with a DIFFERENT target overwrites, keeps sibling.
$s5 = Join-Path $td 's5.json'
'{"env":{"LUNA_VAULT_PATH":"C:/Documents/luna-old","KEEP":"x"}}' | Set-Content $s5 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s5 -VaultPath 'C:/Documents/luna-new' | Out-Null
$c5 = Get-Content $s5 -Raw | ConvertFrom-Json
Check 'last-adopt-wins overwrite' $c5.env.LUNA_VAULT_PATH 'C:/Documents/luna-new'
Check 'overwrite keeps sibling'   $c5.env.KEEP 'x'

# 6. idempotent -> second run identical bytes (PS serializer path).
$s6 = Join-Path $td 's6.json'
& pwsh -NoProfile -File $wire -SettingsPath $s6 -VaultPath 'C:/Documents/luna' | Out-Null
$h6a = Get-Content $s6 -Raw
& pwsh -NoProfile -File $wire -SettingsPath $s6 -VaultPath 'C:/Documents/luna' | Out-Null
Check 'idempotent re-run' (Get-Content $s6 -Raw) $h6a

# 7. whitespace-only file -> treated as {}, not refused.
$s7 = Join-Path $td 's7.json'
"   `n" | Set-Content $s7 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s7 -VaultPath 'C:/Documents/luna' | Out-Null
$c7 = Get-Content $s7 -Raw | ConvertFrom-Json
Check 'whitespace file -> created' $c7.env.LUNA_VAULT_PATH 'C:/Documents/luna'

# 8. F1-SC4 cross-twin parity: same backslash input to .sh (Git Bash) and .ps1
#    must yield byte-identical .env.LUNA_VAULT_PATH. Skip cleanly if no Git Bash.
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $gitBash)) {
    $bc = Get-Command bash -ErrorAction SilentlyContinue
    $gitBash = if ($bc -and $bc.Source -notmatch 'System32') { $bc.Source } else { $null }
}
if ($gitBash) {
    $shWire = (Join-Path $here 'wire-luna-vault.sh').Replace('\', '/')
    $pIn = 'C:\Users\me\Documents\luna'
    $shOut = (Join-Path $td 'parity_sh.json').Replace('\', '/')
    $psOut = Join-Path $td 'parity_ps.json'
    & $gitBash $shWire $shOut $pIn | Out-Null
    & pwsh -NoProfile -File $wire -SettingsPath $psOut -VaultPath $pIn | Out-Null
    $shVal = (Get-Content $shOut -Raw | ConvertFrom-Json).env.LUNA_VAULT_PATH
    $psVal = (Get-Content $psOut -Raw | ConvertFrom-Json).env.LUNA_VAULT_PATH
    Check 'F1-SC4 .sh/.ps1 parity (LUNA_VAULT_PATH)' $psVal $shVal
} else {
    Write-Host 'skip - F1-SC4 parity (Git Bash not found)'
}

Remove-Item -Recurse -Force $td
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
