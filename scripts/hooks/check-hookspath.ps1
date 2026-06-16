# Detects core.hooksPath misconfiguration that silently bypasses git hooks.
# See scripts/hooks/check-hookspath.sh for the full background — this file
# mirrors that script for native PowerShell on Windows.
#
# Exit codes:
#   0 — OK or bypassed
#   1 — misconfigured
#   2 — internal error
#
# Bypass: $env:HOOKSPATH_OK = '1'

$ErrorActionPreference = 'Stop'

# --- Capability check ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("check-hookspath: git not on PATH — refusing to evaluate")
    exit 2
}

# Bypass first (silence noisy machines without needing the rest of the deps).
if ($env:HOOKSPATH_OK -eq '1') {
    [Console]::Error.WriteLine("-> check-hookspath: HOOKSPATH_OK=1 — skipping (WARNING: verify core.hooksPath is correct)")
    exit 0
}

# Are we inside a git repo? If not, exit 0 quietly.
& git rev-parse --is-inside-work-tree *>$null
if ($LASTEXITCODE -ne 0) {
    exit 0
}

# Read the setting. `--get` returns nonzero on unset; tolerate that.
$val = (& git config --get core.hooksPath 2>$null)
if ($LASTEXITCODE -ne 0) { $val = "" }
if ($null -eq $val) { $val = "" }
$val = $val.Trim()

if ([string]::IsNullOrEmpty($val)) {
    exit 0
}

# Resolve toplevel.
$toplevel = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($toplevel)) {
    [Console]::Error.WriteLine("check-hookspath: could not resolve repo toplevel — refusing to evaluate")
    exit 2
}
$toplevel = $toplevel.Trim()

# git-common-dir = the SHARED .git directory across linked worktrees. In a
# `git worktree add`-created worktree, --show-toplevel returns the linked
# worktree dir but --git-common-dir returns the primary repo's `.git` —
# that's where the canonical pre-commit hooks live. Accept core.hooksPath
# pointing inside EITHER as valid (mirrors the bash sibling).
$gitCommonDir = (& git rev-parse --git-common-dir 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitCommonDir)) {
    [Console]::Error.WriteLine("check-hookspath: could not resolve git-common-dir — refusing to evaluate")
    exit 2
}
$gitCommonDir = $gitCommonDir.Trim()
# Anchor relative git-common-dir against toplevel (git versions differ).
if (-not [System.IO.Path]::IsPathRooted($gitCommonDir)) {
    $gitCommonDir = Join-Path $toplevel $gitCommonDir
}

# Resolve relative path against worktree top (matches git semantics).
# CAREFUL: [Path]::IsPathRooted("C:foo") returns TRUE on Windows even
# though `C:foo` is drive-relative (resolves to per-drive cwd, NOT to
# C:\foo). Treat that as relative and join with the worktree top.
# A path counts as absolute iff IsPathRooted AND (it starts with `/` or
# `\` OR there's a separator immediately after the drive colon).
$isAbsolute = [System.IO.Path]::IsPathRooted($val) -and
              ($val -match '^[/\\]' -or $val -match '^[A-Za-z]:[/\\]')
if ($isAbsolute) {
    $resolvedVal = $val
} else {
    $resolvedVal = Join-Path $toplevel $val
}

# Exists check.
if (-not (Test-Path -LiteralPath $resolvedVal)) {
    @"
[BLOCK] check-hookspath: core.hooksPath points at a path that does not exist.

    core.hooksPath = $val
    resolves to    = $resolvedVal
    repo toplevel  = $toplevel

Git is silently SKIPPING all hooks because the hooks dir is gone. This is
the HIMMEL-45 class of bug — every pre-commit + pre-push gate is bypassed.

Fix:
    git config --unset core.hooksPath
    pre-commit install --hook-type pre-commit
    pre-commit install --hook-type pre-push
    pre-commit install --hook-type commit-msg

Bypass (NOT recommended):
    `$env:HOOKSPATH_OK = '1'
"@ | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 1
}

# Canonicalise all three sides. Resolve-Path follows symlinks AND requires
# the path to exist — `Test-Path` above already guarantees existence for
# the val side. The toplevel and git-common-dir sides usually exist too,
# but the catch-block below handles the edge cases (deleted worktree
# target behind a stale junction, partially-broken `.git` linkage, etc.).
try {
    $realVal = (Resolve-Path -LiteralPath $resolvedVal).Path
    $realTop = (Resolve-Path -LiteralPath $toplevel).Path
    $realGcd = (Resolve-Path -LiteralPath $gitCommonDir).Path
} catch {
    [Console]::Error.WriteLine("check-hookspath: canonicalisation failed — $_")
    exit 2
}

# Strip trailing slash/backslash for clean prefix compare.
$realVal = $realVal.TrimEnd('\', '/')
$realTop = $realTop.TrimEnd('\', '/')
$realGcd = $realGcd.TrimEnd('\', '/')

# Case-insensitive compare on Windows (NTFS is case-insensitive by default).
$cmp = [StringComparison]::OrdinalIgnoreCase

function Test-Inside([string]$child, [string]$parent, [System.StringComparison]$c) {
    if ($child.Equals($parent, $c)) { return $true }
    if ($child.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, $c)) { return $true }
    if ($child.StartsWith($parent + '/', $c)) { return $true }
    return $false
}

$isInside = (Test-Inside $realVal $realTop $cmp) -or
            (Test-Inside $realVal $realGcd $cmp)

if (-not $isInside) {
    @"
[BLOCK] check-hookspath: core.hooksPath points OUTSIDE the current repo.

    core.hooksPath  = $val
    resolves to     = $realVal
    repo toplevel   = $realTop
    git-common-dir  = $realGcd

Git is loading hooks from a directory that is not part of this repo.

Fix:
    git config --unset core.hooksPath
    pre-commit install --hook-type pre-commit
    pre-commit install --hook-type pre-push
    pre-commit install --hook-type commit-msg

Bypass (NOT recommended):
    `$env:HOOKSPATH_OK = '1'
"@ | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 1
}

exit 0
