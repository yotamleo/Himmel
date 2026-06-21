<#
.SYNOPSIS
  Multi-vault luna template upgrade sweep (HIMMEL-462) — PowerShell thin forwarder.

.DESCRIPTION
  Windows entry point for the multi-vault upgrade sweep. The engine is
  luna-upgrade-all.sh (bash): it needs git, sha256sum, and python3 — the
  same toolchain every other himmel hook already requires. Rather than
  maintain a second, drifting implementation of the sweep/backup/restore
  logic, this twin locates Git Bash and runs luna-upgrade-all.sh with
  the same arguments.

.PARAMETER Args
  Forwarded verbatim to luna-upgrade-all.sh:
    sweep   [--roots <dirs>] [--registry <path>] [--template-dir <path>] [--porcelain]
    apply   --vault <path> [--template-dir <path>] [--force-unstamped]
    restore --vault <path> [--from <ts>] [--list]

.EXAMPLE
  pwsh scripts/luna-upgrade-all.ps1 --help
  pwsh scripts/luna-upgrade-all.ps1 sweep --roots C:\Users\me\Documents
  pwsh scripts/luna-upgrade-all.ps1 apply --vault C:\Users\me\Documents\my-vault
  pwsh scripts/luna-upgrade-all.ps1 restore --vault C:\Users\me\Documents\my-vault --list
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$engineSh = Join-Path $scriptDir 'luna-upgrade-all.sh'

if (-not (Test-Path -LiteralPath $engineSh)) {
    Write-Error "luna-upgrade-all.ps1: cannot find luna-upgrade-all.sh next to this script at $engineSh"
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
    Write-Error "luna-upgrade-all.ps1: Git Bash not found. Install Git for Windows (it provides bash + sha256sum + git), or run 'bash scripts/luna-upgrade-all.sh' directly."
    exit 2
}

# Git Bash mangles Windows backslash paths in argv; forward-slash form
# (C:/Users/...) is accepted by bash and by the engine's cd/find. Convert the
# script path and every forwarded arg (path values like --vault C:\...).
$shArgs = @($engineSh.Replace('\', '/'))
foreach ($a in $Args) { $shArgs += $a.Replace('\', '/') }

& $bash @shArgs
exit $LASTEXITCODE
