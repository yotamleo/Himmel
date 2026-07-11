# test-win11-shim.ps1 — HIMMEL-887 T8. win11.ps1 is soft-deprecated: it KEEPS
# its full-toolchain provisioning (locked O4 option (b) — zero capability
# loss) but stops doing himmel/luna WIRING itself and delegates that to
# `himmelctl bootstrap` (the correct entry for a node-less machine; `install`
# directly would fail pre-node).
#
# win11.ps1 itself is #Requires -RunAsAdministrator and mutates the machine
# (winget installs, PATH edits) — this test does NOT execute it. Instead it
# statically parses the source text and asserts:
#   A. capability-regression guard — every winget package id (+ nvm/uv/
#      claude/rtk markers) the OLD script's fatal provisioning block
#      installed is still present in the source. ("banners gone" alone is
#      NOT sufficient.)
#   B. order assertion — the last provisioning marker appears before the
#      deprecation notice, which appears before the delegated bootstrap
#      invocation — AND (CR r4) a `Set-Location $HimmelPath` sits between
#      the notice and the bootstrap call, so the wizard's cwd-based
#      role/scope inference targets the himmel clone, never the operator's
#      launch directory.
#   C. CR r2 fail-closed -LunaRemote guard — the delegated flow can't
#      restore a remote vault yet (HIMMEL-755), so the source must carry an
#      exit-1 guard on $LunaRemote that sits BEFORE the first provisioning
#      step, and the old silently-dropping "NOTE: -LunaRemote was passed"
#      branch must be gone. (Static, like A/B — this script is
#      #Requires -RunAsAdministrator and is never executed by the test.)

$ErrorActionPreference = 'Stop'

$repoRoot = (& git rev-parse --show-toplevel).Trim()
$target = Join-Path $repoRoot 'scripts\machine-setup\win11.ps1'
if (-not (Test-Path $target)) {
    Write-Error "FAIL: $target not found"
    exit 1
}

$source = Get-Content -Raw $target

function Fail([string]$msg) {
    Write-Error "FAIL: $msg"
    exit 1
}

# ── Case A: capability-regression guard ─────────────────────────────────────
# The committed expected winget-id list (HIMMEL-887 T8) — every tool the old
# win11.ps1's fatal provisioning block (steps 1-6) installed, before wiring
# was dropped. If this list shrinks, provisioning capability regressed.
$expectedWingetIds = @(
    'Git.Git',
    'OpenJS.NodeJS.LTS',
    'Python.Python.3',
    'jqlang.jq',
    'koalaman.shellcheck',
    'Gitleaks.Gitleaks',
    'CoreyButler.NVMforWindows'
)

$idMatches = [regex]::Matches($source, 'winget install --id (\S+)')
$actualIds = $idMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

foreach ($id in $expectedWingetIds) {
    if ($actualIds -notcontains $id) {
        Fail "caseA: winget id regressed -- missing '$id' (found: $($actualIds -join ', '))"
    }
}

if ($source -notmatch 'nvm install') { Fail "caseA: nvm install call missing" }
if ($source -notmatch [regex]::Escape('astral.sh/uv/install.ps1')) { Fail "caseA: uv provisioning missing" }
if ($source -notmatch [regex]::Escape('claude.ai/install.ps1')) { Fail "caseA: claude CLI provisioning missing" }
if ($source -notmatch [regex]::Escape('rtk-ai/rtk/releases')) { Fail "caseA: rtk provisioning missing" }

Write-Output "ok: caseA every tool the old win11.ps1 provisioned ($($expectedWingetIds -join ', '), nvm, uv, claude, rtk) is still provisioned"

# ── Case B: order assertion (provisioning < notice < delegated bootstrap) ──
$provisionMarker = 'Invoke-Fatal "rtk --version"'
$noticeMarker    = 'soft-deprecated'
$bootstrapMarker = 'scripts\himmelctl\bootstrap.ps1'

$provisionIdx = $source.IndexOf($provisionMarker)
$noticeIdx    = $source.IndexOf($noticeMarker)
$bootstrapIdx = $source.IndexOf($bootstrapMarker)

if ($provisionIdx -lt 0) { Fail "caseB: no provisioning marker found ('$provisionMarker')" }
if ($noticeIdx -lt 0) { Fail "caseB: no deprecation-notice marker found ('$noticeMarker')" }
if ($bootstrapIdx -lt 0) { Fail "caseB: no delegated bootstrap marker found ('$bootstrapMarker')" }

if (-not ($provisionIdx -lt $noticeIdx)) {
    Fail "caseB: provisioning (offset $provisionIdx) did not happen before the deprecation notice (offset $noticeIdx)"
}
if (-not ($noticeIdx -lt $bootstrapIdx)) {
    Fail "caseB: deprecation notice (offset $noticeIdx) did not happen before the delegated bootstrap invocation (offset $bootstrapIdx)"
}

# CR r4: the delegation must run FROM the himmel clone (the wizard's
# role/scope inference reads the CWD's git origin; scope=project wires
# .claude into the CWD). Statically require a Set-Location to $HimmelPath
# between the notice and the bootstrap invocation.
$setLocMarker = 'Set-Location $HimmelPath'
$setLocIdx = $source.IndexOf($setLocMarker)
if ($setLocIdx -lt 0) { Fail "caseB: no '$setLocMarker' found -- the bootstrap delegation must run with cwd=`$HimmelPath (CR r4)" }
if (-not (($noticeIdx -lt $setLocIdx) -and ($setLocIdx -lt $bootstrapIdx))) {
    Fail "caseB: '$setLocMarker' (offset $setLocIdx) must sit between the notice (offset $noticeIdx) and the bootstrap invocation (offset $bootstrapIdx)"
}

Write-Output "ok: caseB provisioning ($provisionIdx) < notice ($noticeIdx) < Set-Location `$HimmelPath ($setLocIdx) < delegated bootstrap ($bootstrapIdx)"

# ── Case C: -LunaRemote fail-closed guard sits BEFORE any provisioning ─────
$guardMatch = [regex]::Match($source, '(?s)if \(\$LunaRemote\) \{.*?exit 1\s*\}')
if (-not $guardMatch.Success) {
    Fail "caseC: no fail-closed -LunaRemote guard (if (`$LunaRemote) { ... exit 1 }) found in the source"
}
if ($guardMatch.Value -notmatch 'not supported') {
    Fail "caseC: the -LunaRemote guard is missing the not-supported error message"
}
if ($guardMatch.Value -notmatch 'Clone the vault manually first') {
    Fail "caseC: the -LunaRemote guard is missing the manual-clone remediation line"
}
$firstProvisionIdx = $source.IndexOf('Write-Step "Update package manager"')
if ($firstProvisionIdx -lt 0) { Fail "caseC: no first-provisioning marker found" }
if (-not ($guardMatch.Index -lt $firstProvisionIdx)) {
    Fail "caseC: the -LunaRemote guard (offset $($guardMatch.Index)) must sit BEFORE the first provisioning step (offset $firstProvisionIdx)"
}
if ($source -match 'NOTE: -LunaRemote was passed') {
    Fail "caseC: the old silently-dropping 'NOTE: -LunaRemote was passed' branch must be gone (fail-closed replaces it)"
}
Write-Output "ok: caseC -LunaRemote fail-closed guard (offset $($guardMatch.Index)) sits before provisioning (offset $firstProvisionIdx); silent-drop NOTE gone"

Write-Output "PASS"
