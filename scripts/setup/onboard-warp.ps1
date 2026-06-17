# onboard-warp.ps1 — Warp integration onboarding for a fresh machine
# (HIMMEL-360, split out of onboard-telegram.ps1). PowerShell counterpart of
# onboard-warp.sh; called from scripts/setup.ps1, also safe standalone:
#   pwsh -File scripts/setup/onboard-warp.ps1
#
# VERIFY-ONLY, by design (mirror of the bash sibling):
#   The Warp integration is repo-local skills (.claude/commands/open-warp.md +
#   oz-offload.md — ship with the clone, nothing to install) + the
#   warp@claude-code-warp plugin (installed by install-plugins.ps1) + the Warp
#   app itself. This script only verifies the Warp binary and prints hints.
#
# Env overrides (tests): $env:WARP_EXE
#
# Exit codes: 0 = ok (a missing Warp binary is a reported next-step — the warp
#             skills simply no-op without it).

[CmdletBinding()]
param()

Write-Host "-- Warp integration onboarding (verify-only) --"
Write-Host "  skills: /open-warp + /oz-offload are repo-local (.claude/commands/) -- ship with the clone"
Write-Host "  plugin: warp@claude-code-warp installs via scripts/machine-setup/install-plugins.ps1"
$WarpExe = if ($env:WARP_EXE) { $env:WARP_EXE }
           else { Join-Path $env:LOCALAPPDATA 'Programs\Warp\warp.exe' }
if (Get-Command warp -ErrorAction SilentlyContinue) {
    Write-Host "  warp binary: $((Get-Command warp).Source)"
} elseif (Test-Path $WarpExe) {
    Write-Host "  warp binary: $WarpExe"
} else {
    Write-Host "  warp binary: MISSING -- install from https://www.warp.dev (warp skills no-op without it)"
}

exit 0
