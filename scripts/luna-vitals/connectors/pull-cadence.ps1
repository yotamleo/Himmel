<#
.SYNOPSIS
  ALPHA opt-in - cadence pull wrapper for the Google Health connector.
  PowerShell 7 twin of pull-cadence.sh (HIMMEL-609).

.DESCRIPTION
  Runs `bun google-health.ts pull` for a yesterday-to-today window and
  stops at the artifact file. The operator reviews the artifact and runs
  `luna-vitals write` separately. This wrapper does NOT call write.

  Exit codes:
    0  - success; artifact path printed to stdout.
    75 - re-consent needed (OAuth token expired/revoked); see stderr.
    *  - connector error; original message already on stderr.

  Environment variables honoured:
    FROM                     Override pull window start (YYYY-MM-DD).
                             Default: yesterday (UTC).
    TO                       Override pull window end (YYYY-MM-DD).
                             Default: today (UTC).
    LUNA_VITALS_ARTIFACT_DIR Artifact output directory.
                             Default: .gh-vitals/ sibling to this script.
    PULL_CMD                 TEST SEAM: if set, run as a pwsh subprocess
                             instead of the real connector.
                             Example: $env:PULL_CMD = 'exit 75'

.EXAMPLE
  pwsh -File pull-cadence.ps1
  TO=2026-06-29 FROM=2026-06-28 pwsh -File pull-cadence.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RECONSENT_EXIT = 75

# -- resolve paths ------------------------------------------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Repo root is three levels up from scripts/luna-vitals/connectors/.
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..\..\..'))

# -- date window --------------------------------------------------------------

$resolvedTo   = if ($env:TO)   { $env:TO }   else { (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') }
$resolvedFrom = if ($env:FROM) { $env:FROM } else { (Get-Date).ToUniversalTime().AddDays(-1).ToString('yyyy-MM-dd') }

# -- artifact output ----------------------------------------------------------

$artifactDir = if ($env:LUNA_VITALS_ARTIFACT_DIR) {
    $env:LUNA_VITALS_ARTIFACT_DIR
} else {
    Join-Path $scriptDir '..' '.gh-vitals'
}
$artifactDir = [System.IO.Path]::GetFullPath($artifactDir)
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$artifact = Join-Path $artifactDir "gh-$resolvedTo.json"

# -- run pull -----------------------------------------------------------------

$pullRc = 0
$ErrorActionPreference = 'Continue'
if ($env:PULL_CMD) {
    # TEST-ONLY seam — must never be set in a production scheduler env.
    # PULL_CMD is a PowerShell snippet run in a subprocess.
    # Example: $env:PULL_CMD = 'exit 75'
    & pwsh -NoProfile -Command $env:PULL_CMD
    $pullRc = $LASTEXITCODE
} else {
    # Set-Location to repo root so bun auto-loads .env from <repo>/.env (bun reads .env from CWD).
    Set-Location $repoRoot
    & bun "$scriptDir\google-health.ts" pull --from $resolvedFrom --to $resolvedTo --out $artifact
    $pullRc = $LASTEXITCODE
}
$ErrorActionPreference = 'Stop'

# -- handle result ------------------------------------------------------------

if ($pullRc -eq $RECONSENT_EXIT) {
    [Console]::Error.WriteLine("[pull-cadence] re-consent needed: Google Health OAuth token has expired or was revoked.")
    [Console]::Error.WriteLine("[pull-cadence] To re-auth, run auth-url then auth-exchange:")
    [Console]::Error.WriteLine("  1. bun $scriptDir\google-health.ts auth-url")
    [Console]::Error.WriteLine("     (open the printed URL in a browser and grant access)")
    [Console]::Error.WriteLine("  2. bun $scriptDir\google-health.ts auth-exchange --code <code>")
    exit $RECONSENT_EXIT
}

if ($pullRc -ne 0) {
    [Console]::Error.WriteLine("[pull-cadence] error: connector pull exited with code $pullRc")
    exit $pullRc
}

# -- success ------------------------------------------------------------------

Write-Output $artifact
[Console]::Error.WriteLine("[pull-cadence] review the artifact above; operator inspects it first, then land it:")
[Console]::Error.WriteLine("  1. bun $repoRoot\scripts\luna-vitals\cli.ts merge --det $artifact --out <merged.json>")
[Console]::Error.WriteLine("  2. bun $repoRoot\scripts\luna-vitals\cli.ts write <merged.json> --dir <50-Vitals path>")

exit 0
