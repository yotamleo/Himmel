# Hermetic test for the salus medical overlay (PowerShell twin of test-salus-overlay.sh).
# No real data touched: everything happens under a fresh temp vault.
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $PSCommandPath
$TemplateRoot = (Resolve-Path (Join-Path $Here '..')).Path
. (Join-Path $Here 'lib/Salus-Overlay.ps1')

$script:fails = 0
function Check($name, [bool]$cond) {
    if ($cond) { Write-Host "  ok   - $name" }
    else { Write-Host "  FAIL - $name" -ForegroundColor Red; $script:fails++ }
}

# --- fixture: a fresh "vault" with the overlay source + a base _CLAUDE.md ---
$Vault = Join-Path ([System.IO.Path]::GetTempPath()) ("salus-ps-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path (Join-Path $Vault '_profiles') | Out-Null
Copy-Item -Recurse -Force (Join-Path $TemplateRoot '_profiles/salus') (Join-Path $Vault '_profiles/salus')
Set-Content -Path (Join-Path $Vault '_CLAUDE.md') -Value "# base vault _CLAUDE.md`n`nbase rules here.`n"

try {
    Write-Host "== apply (scaffold-new) =="
    if (-not (Invoke-SalusOverlay -RepoRoot $Vault)) { Check "apply returned true" $false }

    Check "medic skill installed"         (Test-Path (Join-Path $Vault '.claude/skills/medic/SKILL.md'))
    Check "egress hook installed"         (Test-Path (Join-Path $Vault '.claude/hooks/block-cloud-egress.sh'))
    Check "settings.json installed"       (Test-Path (Join-Path $Vault '.claude/settings.json'))
    Check "settings wires egress hook"    ([bool](Select-String -Path (Join-Path $Vault '.claude/settings.json') -Pattern 'block-cloud-egress.sh' -Quiet))
    Check "skin archive scaffolded"       (Test-Path (Join-Path $Vault '_skin-photo-archive.md'))
    Check "derm-prep template scaffolded" (Test-Path (Join-Path $Vault '_derm-visit-prep.template.md'))
    Check "media/skin gitkeep present"    (Test-Path (Join-Path $Vault '_media/skin/.gitkeep'))
    Check "posture appended to _CLAUDE"   ([bool](Select-String -Path (Join-Path $Vault '_CLAUDE.md') -Pattern 'salus-posture-block' -SimpleMatch -Quiet))
    Check "base _CLAUDE preserved"        ([bool](Select-String -Path (Join-Path $Vault '_CLAUDE.md') -Pattern 'base rules here' -SimpleMatch -Quiet))
    Check ".salus-profile marker dropped" (Test-Path (Join-Path $Vault '.salus-profile'))

    $dataRows = @(Select-String -Path (Join-Path $Vault '_skin-photo-archive.md') -Pattern '^\| 20[0-9][0-9]-').Count
    Check "skin archive has ZERO data rows" ($dataRows -eq 0)

    # PHI scan must cover .claude (skill + hook) too — parity with the bash test.
    # Literals sourced from the leak denylist (OUTSIDE the repo) so no real PHI is
    # committed here — HIMMEL-638 found the old hardcoded canary list (a real name
    # + medications) leaked into this test. Skipped when the denylist is absent.
    $phiPaths = @((Get-ChildItem -Recurse -File (Join-Path $Vault '.claude')).FullName)
    $phiPaths += (Join-Path $Vault '_skin-photo-archive.md')
    $phiPaths += (Join-Path $Vault '.salus-profile')
    $denylist = if ($env:HIMMEL_LEAK_DENYLIST) { $env:HIMMEL_LEAK_DENYLIST } else { Join-Path $HOME '.claude/himmel-leak-denylist.txt' }
    if (Test-Path $denylist) {
        $terms = Get-Content $denylist | ForEach-Object { $_.Trim() } | Where-Object { $_ -and ($_ -notmatch '^#') }
        $phi = $false
        foreach ($t in $terms) {
            if (Select-String -Path $phiPaths -Pattern $t -SimpleMatch -Quiet) { $phi = $true; break }
        }
        Check "scaffolds are PHI-free (vs leak denylist)" (-not $phi)
    } else {
        Check "scaffolds PHI-free check skipped (no leak denylist)" $true
    }

    Write-Host "== idempotency: re-apply must NOT overwrite operator content =="
    Add-Content -Path (Join-Path $Vault '_skin-photo-archive.md') -Value '| 2026-01-02 | hands | active | x | **eczema** | note |'
    Set-Content -Path (Join-Path $Vault '.claude/settings.json') -Value '{"_sentinel":"do-not-clobber"}'
    Invoke-SalusOverlay -RepoRoot $Vault | Out-Null
    Check "operator data row preserved"   ([bool](Select-String -Path (Join-Path $Vault '_skin-photo-archive.md') -Pattern '2026-01-02 | hands' -SimpleMatch -Quiet))
    Check "existing settings NOT clobbered" ([bool](Select-String -Path (Join-Path $Vault '.claude/settings.json') -Pattern 'do-not-clobber' -SimpleMatch -Quiet))
    $postureCount = @(Select-String -Path (Join-Path $Vault '_CLAUDE.md') -Pattern 'salus-posture-block' -SimpleMatch).Count
    Check "posture appended ONCE (idempotent)" ($postureCount -eq 1)

    Write-Host "== error path: apply against a dir with no overlay must fail =="
    $noov = Join-Path ([System.IO.Path]::GetTempPath()) ("salus-noov-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $noov | Out-Null
    Check "apply on a non-template dir returns false" (-not (Invoke-SalusOverlay -RepoRoot $noov))
    Remove-Item -Recurse -Force $noov -ErrorAction SilentlyContinue
}
finally {
    Remove-Item -Recurse -Force $Vault -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fails -eq 0) { Write-Host "PASS -- salus overlay hermetic test (PowerShell)" }
else { Write-Host "FAIL -- $($script:fails) check(s)" -ForegroundColor Red; exit 1 }
