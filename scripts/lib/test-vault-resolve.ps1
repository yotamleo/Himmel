# Smoke test (executable spec) for scripts/lib/vault-resolve.ps1 — HIMMEL-403.
# Run: pwsh scripts/lib/test-vault-resolve.ps1
$ErrorActionPreference = 'Stop'   # any unhandled error must fail the run, not skip checks
. (Join-Path $PSScriptRoot 'vault-resolve.ps1')

$script:fails = 0
function Check([string]$desc, [string]$expected, [string]$actual) {
    if ($expected -eq $actual) { "ok   - $desc" }
    else { "FAIL - $desc`n      expected=[$expected]`n      actual=  [$actual]"; $script:fails++ }
}

$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("vr-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$cfg = Join-Path $SB 'cfg.json'
$noreg = Join-Path $SB 'none.json'
function MkCfg([string]$json) { Set-Content -LiteralPath $cfg -Value $json -NoNewline }

$docDocs = Join-Path $SB 'home\Documents'

try {
    # ---- backward-compat ----
    $env:LUNA_VAULT_PATH = ''
    $env:USERPROFILE = (Join-Path $SB 'home')
    MkCfg '{"enabled":true}'
    Check 'undeclared -> default luna' (Join-Path $docDocs 'luna') (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)

    MkCfg '{"vault_path":"C:\\explicit"}'
    $env:LUNA_VAULT_PATH = 'C:\env'
    Check 'vault_path wins' 'C:\explicit' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)

    MkCfg '{"enabled":true}'
    $env:LUNA_VAULT_PATH = 'C:\envvault'
    Check 'LUNA_VAULT_PATH env' 'C:\envvault' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)

    # F1-SC5 (HIMMEL-458): the value wire-luna-vault writes to settings.json
    # .env.LUNA_VAULT_PATH is actually consumed at resolver step 3. Empty config
    # object + empty registry -> falls through to LUNA_VAULT_PATH.
    MkCfg '{}'
    $env:LUNA_VAULT_PATH = 'C:\scaffolded'
    Check 'F1-SC5 LUNA_VAULT_PATH consumed (empty cfg+reg)' 'C:\scaffolded' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)

    # default via registry[luna] (literal ~/ preserved)
    Set-Content -LiteralPath (Join-Path $SB 'regluna.json') -Value '{"vaults":{"luna":"~/Documents/luna-alt"}}' -NoNewline
    MkCfg '{"enabled":true}'
    $env:LUNA_VAULT_PATH = ''
    Check 'default via registry[luna]' '~/Documents/luna-alt' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath (Join-Path $SB 'regluna.json'))

    # ---- name validation (fail-closed) ----
    $env:LUNA_VAULT_PATH = 'C:\should_not_be_used'
    foreach ($bad in @('', '.', '..', '../x', 'a/b', '-x', '~x', 'a b', 'a$b', 'a;b', 'a..b')) {
        MkCfg ('{"vault":"' + $bad + '"}')
        Check "invalid vault '$bad' -> skip" '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)
    }

    # ---- registry lookup ----
    Set-Content -LiteralPath (Join-Path $SB 'reg.json') -Value '{"vaults":{"luna-medic":"~/Documents/luna-medic"}}' -NoNewline
    MkCfg '{"vault":"luna-medic"}'
    Check 'registry hit (literal ~/)' '~/Documents/luna-medic' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath (Join-Path $SB 'reg.json'))

    Set-Content -LiteralPath (Join-Path $SB 'reg2.json') -Value '{"vaults":{"x":"~/../../etc"}}' -NoNewline
    MkCfg '{"vault":"x"}'
    Check 'registry traversal value -> skip' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath (Join-Path $SB 'reg2.json'))

    Set-Content -LiteralPath (Join-Path $SB 'bad.json') -Value 'not json{' -NoNewline
    MkCfg '{"vault":"nope"}'
    $env:LUNA_VAULT_PATH = ''
    Check 'malformed registry, no conv vault -> skip' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath (Join-Path $SB 'bad.json'))

    # ---- convention + .obsidian marker ----
    New-Item -ItemType Directory -Path (Join-Path $docDocs 'realvault\.obsidian') -Force | Out-Null
    MkCfg '{"vault":"realvault"}'
    Check 'convention + .obsidian' (Join-Path $docDocs 'realvault') (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)

    New-Item -ItemType Directory -Path (Join-Path $docDocs 'notavault') -Force | Out-Null
    MkCfg '{"vault":"notavault"}'
    Check 'convention no .obsidian -> skip' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)

    MkCfg '{"vault":"futurevault"}'
    Check 'dry_run bypasses marker' (Join-Path $docDocs 'futurevault') (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg -DryRun $true)

    # ---- CR follow-ups (HIMMEL-403 review) ----
    # registry present but THIS key absent -> convention fallback
    Set-Content -LiteralPath (Join-Path $SB 'reg3.json') -Value '{"vaults":{"other":"/somewhere"}}' -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $docDocs 'medic\.obsidian') -Force | Out-Null
    MkCfg '{"vault":"medic"}'
    Check 'registry missing key -> convention' (Join-Path $docDocs 'medic') (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath (Join-Path $SB 'reg3.json'))

    # malformed config that DECLARES a vault -> fail-closed skip (NOT default)
    $env:LUNA_VAULT_PATH = 'C:\should_not_be_used'
    Set-Content -LiteralPath $cfg -Value '{"vault":"luna-medic" BROKEN' -NoNewline
    Check 'malformed config -> skip (not default)' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)
    $env:LUNA_VAULT_PATH = ''

    # name longer than 64 chars -> skip BECAUSE of the cap (dry-run bypasses the
    # marker, so only the length cap can force a skip here).
    MkCfg ('{"vault":"' + ('a' * 65) + '"}')
    Check '65-char name -> skip (cap, not marker)' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg -DryRun $true)

    # registry value not absolute -> skip
    Set-Content -LiteralPath (Join-Path $SB 'reg4.json') -Value '{"vaults":{"rel":"relative/path"}}' -NoNewline
    MkCfg '{"vault":"rel"}'
    Check 'non-absolute registry value -> skip' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath (Join-Path $SB 'reg4.json'))

    # registry value that is an array (not a string) -> ignored -> skip
    Set-Content -LiteralPath (Join-Path $SB 'reg5.json') -Value '{"vaults":{"arr":["/a","/b"]}}' -NoNewline
    MkCfg '{"vault":"arr"}'
    Check 'array registry value -> skip' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath (Join-Path $SB 'reg5.json'))

    # valid JSON but NOT an object -> fail-closed skip (parity with bash).
    # '[{"vault":"luna"}]' guards the single-element-array auto-unwrap.
    $env:LUNA_VAULT_PATH = 'C:\should_not_be_used'
    foreach ($nonobj in @('null', 'false', '[]', '"str"', '42', '[{"vault":"luna"}]')) {
        Set-Content -LiteralPath $cfg -Value $nonobj -NoNewline
        Check "non-object config '$nonobj' -> skip" '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)
    }
    # empty config file -> skip (not default)
    Set-Content -LiteralPath $cfg -Value '' -NoNewline
    Check 'empty config file -> skip' '' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)
    $env:LUNA_VAULT_PATH = ''

    # UTF-8 BOM-prefixed config/registry must still PARSE, not fail-closed
    # (HIMMEL-408). PS 5.1 `Set-Content -Encoding utf8` writes exactly this BOM.
    $bomEnc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($cfg, '{"vault_path":"C:\\bomvault"}', $bomEnc)
    Check 'BOM-prefixed config parses (not skip)' 'C:\bomvault' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $noreg)

    $bomReg = Join-Path $SB 'regbom.json'
    [System.IO.File]::WriteAllText($bomReg, '{"vaults":{"bomreg":"C:\\bomreg"}}', $bomEnc)
    MkCfg '{"vault":"bomreg"}'
    Check 'BOM-prefixed registry resolves name' 'C:\bomreg' (Resolve-VaultRoot -ConfigPath $cfg -RegistryPath $bomReg)

    $script:reached = $true
}
finally {
    Remove-Item -LiteralPath $SB -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $script:reached) { 'FAILED: test did not run to completion'; exit 1 }
if ($script:fails -eq 0) { 'ALL PASS'; exit 0 } else { "$($script:fails) FAILED"; exit 1 }
