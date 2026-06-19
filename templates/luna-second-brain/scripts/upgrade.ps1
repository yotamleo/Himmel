<#
.SYNOPSIS
  Content-preserving vault/template upgrade (HIMMEL-389) — PowerShell twin.

.DESCRIPTION
  Windows entry point for the vault upgrade. The upgrade engine is upgrade.sh
  (bash): it needs git merge-file (3-way _CLAUDE.md merge), sha256sum, and
  python3 — the same toolchain every other himmel hook already requires. Rather
  than maintain a second, drifting implementation of the merge/classification
  logic, this twin locates Git Bash and runs upgrade.sh with the same arguments.

.PARAMETER Args
  Forwarded verbatim to upgrade.sh: --template-dir DIR, --vault-dir DIR,
  --dry-run, --yes.

.EXAMPLE
  pwsh scripts/upgrade.ps1 --dry-run
  pwsh scripts/upgrade.ps1 --template-dir C:\src\himmel\templates\luna-second-brain --yes
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$upgradeSh = Join-Path $scriptDir 'upgrade.sh'

if (-not (Test-Path -LiteralPath $upgradeSh)) {
    Write-Error "upgrade.ps1: cannot find upgrade.sh next to this script at $upgradeSh"
    exit 2
}

# Locate GIT BASH specifically. A bare `bash` on PATH is often the WSL stub
# (C:\Windows\System32\bash.exe), which can't see C:/... paths — so prefer the
# Git for Windows install, then bash derived from the `git` command, and only
# fall back to a PATH `bash` last.
$bash = $null
$cands = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)
$gitCmd = (Get-Command git -ErrorAction SilentlyContinue).Source
if ($gitCmd) {
    # git.exe is at <GitRoot>\cmd\git.exe; bash is at <GitRoot>\bin\bash.exe.
    $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCmd)
    $cands += (Join-Path $gitRoot 'bin\bash.exe')
}
foreach ($cand in $cands) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { $bash = $cand; break }
}
if (-not $bash) {
    $pathBash = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if ($pathBash -and $pathBash -notmatch 'System32') { $bash = $pathBash }
}
if (-not $bash) {
    Write-Error "upgrade.ps1: Git Bash not found. Install Git for Windows (it provides bash + sha256sum + git), or run 'bash scripts/upgrade.sh' directly."
    exit 2
}

# Git Bash mangles Windows backslash paths in argv; forward-slash form
# (C:/Users/...) is accepted by bash and by the engine's cd/find. Convert the
# script path and every forwarded arg (path values like --template-dir C:\...).
$shArgs = @($upgradeSh.Replace('\', '/'))
foreach ($a in $Args) { $shArgs += $a.Replace('\', '/') }

& $bash @shArgs
exit $LASTEXITCODE
