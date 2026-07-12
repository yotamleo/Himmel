# scripts/himmelctl/bootstrap.ps1 — node-less bootstrap shim for himmelctl
# (HIMMEL-887 T7). For a genuinely node-less clean Windows machine: detect
# node absent, install ONLY node via winget (bun has no reliable winget
# query-by-bare-name match — `winget install node bun` resolves as a single
# bad query — so bun stays an optional post-bootstrap step), then hand off to
# `node scripts/himmelctl/bin.js install`. Nothing else — himmelctl's own
# preflight covers every other hard-gate tool. Posix machines use
# bootstrap.sh instead (brew/apt).
#
# Usage (-ExecutionPolicy Bypass: a clean machine's default policy is
# Restricted, which refuses -File outright):
#   powershell -ExecutionPolicy Bypass -File scripts/himmelctl/bootstrap.ps1 [-DryRun]
#
# HIMMELCTL_REPO_ROOT overrides where bin.js is looked up (same seam bin.js
# itself honors) so a hermetic test can point the hand-off at a stub.

param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = $env:HIMMELCTL_REPO_ROOT
if (-not $repoRoot) {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
}
$binJs = Join-Path $repoRoot 'scripts\himmelctl\bin.js'

$handoffCmd = "node `"$binJs`" install"
$installPlan = 'winget install --id OpenJS.NodeJS.LTS -e'

function Test-NodePresent {
  return [bool](Get-Command node -ErrorAction SilentlyContinue)
}

if (Test-NodePresent) {
  # node-present short-circuit: straight to the hand-off, no install step.
  Write-Output "bootstrap: node found -- handing off to: $handoffCmd"
  if ($DryRun) { exit 0 }
  & node $binJs install
  exit $LASTEXITCODE
}

Write-Output "bootstrap: node not found -- install plan: $installPlan"
Write-Output "bootstrap: hand-off after install: $handoffCmd"
if ($DryRun) { exit 0 }

winget install --id OpenJS.NodeJS.LTS -e
$wingetExit = $LASTEXITCODE
if ($wingetExit -ne 0) {
  Write-Warning "winget install --id OpenJS.NodeJS.LTS -e exited $wingetExit"
}
# bun is optional (needed later for qmd/telegram features); winget has no
# reliable bare-name match for it, so it is never part of the plan above.
Write-Output "bootstrap: bun not installed (optional -- needed later for qmd/telegram features; install from https://bun.sh)"

if (Test-NodePresent) {
  Write-Output "bootstrap: node installed -- handing off to: $handoffCmd"
  & node $binJs install
  exit $LASTEXITCODE
}

# winget genuinely failed AND node is still absent: NOT the PATH-refresh trap
# (HIMMEL-935 / CR #1126). Fail closed with the actual install failure instead
# of the re-run line, which implies success and would loop forever re-running a
# known-failing winget install. ($ErrorActionPreference='Stop' makes Write-Error
# terminating, so this exits non-zero either way.)
if ($wingetExit -ne 0) {
  Write-Error "bootstrap: winget install failed (exit $wingetExit) and node is still not resolvable -- fix the winget failure above and re-run"
  exit 1
}

# PATH-refresh trap (Draft-A §6): winget SUCCEEDED but the fresh install's PATH
# edit is invisible to this process. Print the ONE re-run line rather than
# chaining blindly.
Write-Output "bootstrap: node installed but not resolvable in this shell -- open a new terminal and re-run: powershell -ExecutionPolicy Bypass -File `"$scriptDir\bootstrap.ps1`""
exit 1
