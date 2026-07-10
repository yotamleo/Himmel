# preflight-adopter.ps1 — standalone check-only adopter preflight (HIMMEL-842
# fix-batch). An adopter can run this BEFORE committing to adopt.ps1 to surface
# the common fresh-machine gaps (uv/pipx, npm-less distro node, unbuilt
# scripts/jira/dist) in one pass, instead of discovering them one abort at a
# time across three downstream scripts. Counterpart of preflight-adopter.sh;
# keep both in lockstep.
#
# Dot-sources scripts/lib/preflight-adopter.ps1 — the SAME shared checks adopt.ps1
# calls — so the two entry points can never drift (operator answer Q4: "BOTH
# standalone check-only AND auto-invoked").
#
# Advisory-first, matching adopt.ps1's WARN-not-fail culture: prints WARN lines
# and ALWAYS exits 0 unless -Strict is passed (then any WARN exits 1, for use in
# CI / a verification pass where "does this reach zero warnings" is the thing
# being measured). No fixes are applied — adopt.ps1 does the building; this only
# reports.
#
# Usage:
#   pwsh preflight-adopter.ps1 [-Strict] [-Help]

[CmdletBinding()]
param(
    [switch]$Strict,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# -h/-Help parity with preflight-adopter.sh's --help: dump this script's own
# leading comment header (stripped of the "# " prefix) and exit 0.
if ($Help) {
    foreach ($line in (Get-Content -LiteralPath $PSCommandPath)) {
        if ($line -notmatch '^#') { break }
        Write-Host ($line -replace '^# ?', '')
    }
    exit 0
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$HimmelRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path

. (Join-Path $ScriptDir 'lib\preflight-adopter.ps1')

Write-Host "==> himmel adopter preflight (check-only)"

# Run each shared check, counting how many WARN. adopt.ps1 calls these same
# functions, so the two entry points can never drift.
$warns = 0
if (-not (Test-PreflightUvPipx))       { $warns++ }
if (-not (Test-PreflightNpmInvocable)) { $warns++ }
if (-not (Test-PreflightJiraDist))     { $warns++ }

if ($warns -gt 0) {
    Write-Host "──── $warns warning(s). adopt.ps1 will warn on these too."
    Write-Host "──── Re-run with -Strict to exit non-zero on any warning."
} else {
    Write-Host "──── preflight clean (0 warnings)."
}

if ($Strict -and ($warns -gt 0)) { exit 1 }
exit 0
