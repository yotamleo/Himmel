<#
  Smoke test for upgrade.ps1 (HIMMEL-389) — verifies the PowerShell twin locates
  Git Bash and delegates to upgrade.sh: a --dry-run mutates nothing, and a --yes
  run applies the engine's overwrite policy. The exhaustive per-file behavior is
  covered by test-upgrade.sh; this only proves the twin wires through correctly.
  Run: pwsh scripts/test-upgrade.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1  = Join-Path $here 'upgrade.ps1'
$failed = 0
function Assert([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "PASS $label" }
    else { Write-Host "FAIL $label $detail"; $script:failed++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("upgps-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $T = Join-Path $tmp 'tmpl'; $V = Join-Path $tmp 'vault'
    New-Item -ItemType Directory -Force -Path (Join-Path $T 'marketplace\.claude-plugin') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $T 'scripts\hooks') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $V 'scripts\hooks') | Out-Null
    Set-Content -NoNewline -Path (Join-Path $T 'marketplace\.claude-plugin\marketplace.json') -Value '{"metadata":{"version":"1.0.0"}}'
    Set-Content -NoNewline -Path (Join-Path $T 'scripts\hooks\check-commit-msg.sh') -Value "TEMPLATE-VERSION`n"
    Set-Content -NoNewline -Path (Join-Path $T '_CLAUDE.md') -Value "# Manual`n"
    Set-Content -NoNewline -Path (Join-Path $V '.vault-template.json') -Value '{"template":"luna-second-brain","version":"0.9.0","upgraded_at":"2026-01-01T00:00:00Z"}'
    Set-Content -NoNewline -Path (Join-Path $V 'scripts\hooks\check-commit-msg.sh') -Value "STALE`n"

    $hook = Join-Path $V 'scripts\hooks\check-commit-msg.sh'
    $before = (Get-FileHash $hook -Algorithm SHA256).Hash

    # Dry-run: exit 0, prints the banner, mutates nothing.
    $out = & pwsh -NoProfile -File $ps1 --template-dir $T --vault-dir $V --dry-run 2>&1 | Out-String
    Assert 'dry-run exit 0' ($LASTEXITCODE -eq 0) "rc=$LASTEXITCODE"
    Assert 'dry-run prints upgrade banner' ($out -match 'luna-second-brain upgrade') "out=$out"
    Assert 'dry-run mutates nothing' ((Get-FileHash $hook -Algorithm SHA256).Hash -eq $before)

    # Apply: the diverged hook is restored to the template version.
    & pwsh -NoProfile -File $ps1 --template-dir $T --vault-dir $V --yes *> $null
    Assert 'apply exit 0' ($LASTEXITCODE -eq 0) "rc=$LASTEXITCODE"
    $tmplHash = (Get-FileHash (Join-Path $T 'scripts\hooks\check-commit-msg.sh') -Algorithm SHA256).Hash
    Assert 'apply restores hook to template' ((Get-FileHash $hook -Algorithm SHA256).Hash -eq $tmplHash)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# T26 (HIMMEL-521): the REAL template's two version sources must agree.
# upgrade.sh/.ps1 read marketplace.json metadata.version (authoritative);
# setup.ps1 seeds a new vault from .vault-template.json. If they drift,
# /luna-upgrade reports "already current" even when template content shipped
# (the HIMMEL-501 regression). Guard so the anchors can never diverge again.
$realTmpl = Split-Path -Parent $here
$mktVer  = (Get-Content -Raw (Join-Path $realTmpl 'marketplace\.claude-plugin\marketplace.json') | ConvertFrom-Json).metadata.version
$seedVer = (Get-Content -Raw (Join-Path $realTmpl '.vault-template.json') | ConvertFrom-Json).version
Assert 'T26 marketplace.json metadata.version == .vault-template.json version (no drift)' ($mktVer -eq $seedVer) "marketplace=$mktVer seed=$seedVer"

Write-Host ''
if ($failed -eq 0) { Write-Host 'All upgrade.ps1 smoke tests passed.' }
else { Write-Host "$failed test(s) failed."; exit 1 }
