<#
  Smoke test for luna-upgrade-all.ps1 (HIMMEL-462) — verifies the PowerShell
  forwarder locates Git Bash and delegates to luna-upgrade-all.sh: --help exits
  0, and a sweep against an empty temp roots dir exits 0 without touching real
  vaults. The exhaustive engine behavior coverage lives in test-luna-upgrade-all.sh;
  this only proves the .ps1 twin wires through correctly.
  Run: pwsh scripts/test-luna-upgrade-all.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1  = Join-Path $here 'luna-upgrade-all.ps1'
$failed = 0
function Assert([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "PASS $label" }
    else { Write-Host "FAIL $label $detail"; $script:failed++ }
}

# Resolve the himmel repo root (this script lives at scripts/test-luna-upgrade-all.ps1
# inside the worktree; the template is at templates/luna-second-brain relative to root).
$repoRoot    = Split-Path -Parent $here
$templateDir = Join-Path $repoRoot 'templates\luna-second-brain'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("lua-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # Point HOME at a temp dir so the sweep never reads the real registry or
    # real vault roots. Use an empty roots dir so no vaults are discovered.
    $fakeHome   = Join-Path $tmp 'home'
    $emptyRoots = Join-Path $tmp 'roots'
    New-Item -ItemType Directory -Force -Path $fakeHome   | Out-Null
    New-Item -ItemType Directory -Force -Path $emptyRoots | Out-Null

    # --help: must exit 0 and print usage.
    $out = & pwsh -NoProfile -File $ps1 --help 2>&1 | Out-String
    Assert '--help exit 0' ($LASTEXITCODE -eq 0) "rc=$LASTEXITCODE"
    Assert '--help prints usage' ($out -match 'sweep|apply|restore') "out=$out"

    # sweep against empty roots + temp HOME: no vaults found, must exit 0.
    # Pass --template-dir so the engine can resolve upgrade.sh without needing
    # the real $HOME to contain the himmel checkout.
    $env:HOME = $fakeHome
    $out2 = & pwsh -NoProfile -File $ps1 sweep --roots $emptyRoots --template-dir $templateDir 2>&1 | Out-String
    Assert 'sweep empty-roots exit 0' ($LASTEXITCODE -eq 0) "rc=$LASTEXITCODE out=$out2"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -eq 0) { Write-Host 'All luna-upgrade-all.ps1 smoke tests passed.' }
else { Write-Host "$failed test(s) failed."; exit 1 }
