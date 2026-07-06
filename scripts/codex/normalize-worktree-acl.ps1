<#
.SYNOPSIS
Normalize inherited ACLs for a Codex worktree's top-level child directories.

.DESCRIPTION
Windows-only helper for aged Codex worktrees whose subdirectories missed the
sandbox SID inheritance granted at the worktree root. Given a path under a
.claude\worktrees\<name> segment, this script runs:

  icacls <child-directory> /reset /T /C /Q

for each top-level child directory. It deliberately never resets the worktree
root, because the root carries the explicit Codex sandbox SID ACE that must
survive. If no Codex dispatch chokepoint is available, run manually before an
unattended Codex lane dispatch:

  pwsh -NoProfile -File scripts\codex\normalize-worktree-acl.ps1 <worktree>
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$WorktreePath,

  [Parameter()]
  [string]$IcaclsPath = 'icacls'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Err([string]$Message) {
  [Console]::Error.WriteLine("normalize-worktree-acl: $Message")
}

try {
  $root = (Resolve-Path -LiteralPath $WorktreePath).ProviderPath
} catch {
  Write-Err "path not found: $WorktreePath"
  exit 2
}

$fullRoot = [System.IO.Path]::GetFullPath($root)
$normalized = $fullRoot -replace '/', '\'
$parts = @($normalized -split '\\+')
$underWorktree = $false
for ($i = 0; $i -lt ($parts.Count - 2); $i++) {
  if (($parts[$i] -ieq '.claude') -and ($parts[$i + 1] -ieq 'worktrees') -and ($parts[$i + 2] -ne '')) {
    $underWorktree = $true
    break
  }
}
if (-not $underWorktree) {
  Write-Err "refusing to reset ACLs outside a .claude\worktrees\<name> path: $fullRoot"
  exit 2
}

$children = @(Get-ChildItem -LiteralPath $fullRoot -Directory -Force)
$failed = $false
foreach ($child in $children) {
  & $IcaclsPath $child.FullName '/reset' '/T' '/C' '/Q'
  if ($LASTEXITCODE -ne 0) {
    $failed = $true
  }
}

if ($failed) { exit 1 }
exit 0
