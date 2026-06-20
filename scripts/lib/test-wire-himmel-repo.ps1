# test-wire-himmel-repo.ps1 -- committed PS test for wire-himmel-repo.ps1
# (HIMMEL-453). The .env merge is genuinely new logic vs the statusline twin's
# single-object set, and clobbering a sibling key (e.g. HIMMEL_INITIATIVE) is the
# highest-risk failure on the operator's primary platform -- so it gets a real
# assertion, not parity-by-inspection. Run: pwsh -File test-wire-himmel-repo.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wire = Join-Path $here 'wire-himmel-repo.ps1'
$fails = 0
function Check($name, $got, $want) {
    if ($got -eq $want) { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}

$td = Join-Path ([System.IO.Path]::GetTempPath()) ("wirehr-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $td | Out-Null

# 1. existing sibling env key preserved + HIMMEL_REPO added.
$s1 = Join-Path $td 's1.json'
'{"statusLine":{"type":"command"},"env":{"HIMMEL_INITIATIVE":"all"}}' | Set-Content $s1 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s1 -HimmelPath 'C:/himmel' | Out-Null
$c1 = Get-Content $s1 -Raw | ConvertFrom-Json
Check 'sibling env key preserved' $c1.env.HIMMEL_INITIATIVE 'all'
Check 'top-level key preserved'   $c1.statusLine.type 'command'
Check 'HIMMEL_REPO added'         $c1.env.HIMMEL_REPO 'C:/himmel'

# 2. missing file -> created with env.HIMMEL_REPO.
$s2 = Join-Path $td 's2.json'
& pwsh -NoProfile -File $wire -SettingsPath $s2 -HimmelPath 'C:/himmel' | Out-Null
$c2 = Get-Content $s2 -Raw | ConvertFrom-Json
Check 'create on missing file' $c2.env.HIMMEL_REPO 'C:/himmel'

# 3. backslash -> forward-slashed.
$s3 = Join-Path $td 's3.json'
& pwsh -NoProfile -File $wire -SettingsPath $s3 -HimmelPath 'C:\Users\me\himmel' | Out-Null
$c3 = Get-Content $s3 -Raw | ConvertFrom-Json
Check 'backslash forward-slashed' $c3.env.HIMMEL_REPO 'C:/Users/me/himmel'

# 4. invalid JSON -> exit 1, file unchanged.
$s4 = Join-Path $td 's4.json'
'not json {' | Set-Content $s4 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s4 -HimmelPath 'C:/himmel' 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host 'FAIL: invalid JSON not refused'; $fails++ }
else { Write-Host 'ok - refuses invalid JSON' }
Check 'invalid file unchanged' ((Get-Content $s4 -Raw).Trim()) 'not json {'

# 5. replace an EXISTING HIMMEL_REPO value (the update arm of the PS branch).
$s5 = Join-Path $td 's5.json'
'{"env":{"HIMMEL_REPO":"C:/old","KEEP":"x"}}' | Set-Content $s5 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s5 -HimmelPath 'C:/new' | Out-Null
$c5 = Get-Content $s5 -Raw | ConvertFrom-Json
Check 'replaces existing value' $c5.env.HIMMEL_REPO 'C:/new'
Check 'replace keeps sibling'   $c5.env.KEEP 'x'

# 6. idempotent -> second run identical bytes (PS serializer path).
$s6 = Join-Path $td 's6.json'
& pwsh -NoProfile -File $wire -SettingsPath $s6 -HimmelPath 'C:/himmel' | Out-Null
$h6a = Get-Content $s6 -Raw
& pwsh -NoProfile -File $wire -SettingsPath $s6 -HimmelPath 'C:/himmel' | Out-Null
Check 'idempotent re-run' (Get-Content $s6 -Raw) $h6a

# 7. whitespace-only file -> treated as {}, not refused.
$s7 = Join-Path $td 's7.json'
"   `n" | Set-Content $s7 -Encoding utf8
& pwsh -NoProfile -File $wire -SettingsPath $s7 -HimmelPath 'C:/himmel' | Out-Null
$c7 = Get-Content $s7 -Raw | ConvertFrom-Json
Check 'whitespace file -> created' $c7.env.HIMMEL_REPO 'C:/himmel'

Remove-Item -Recurse -Force $td
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
