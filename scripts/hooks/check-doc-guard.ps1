# Doc-guard: block ADDING a himmel command/skill without updating its catalog.
# himmel-contributor-only (gated by .himmel-dev). pre-commit = staged set;
# -PrePush = push range. rc: 0 pass | 1 violation | 2 cannot-evaluate.
#
# Windows PowerShell twin of check-doc-guard.sh (HIMMEL-454).
param([switch]$PrePush)

$MAP = Join-Path $PSScriptRoot 'doc-guard-map.tsv'

# DOC_GUARD_FORCE_ERR checked first, before everything else.
if ($env:DOC_GUARD_FORCE_ERR -eq '1') {
    Write-Error "-> doc-guard: DOC_GUARD_FORCE_ERR=1 -- forced cannot-evaluate"
    exit 2
}

# .himmel-dev marker gate: resolve repo root via git rev-parse --show-toplevel.
$top = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $top) {
    Write-Error "-> doc-guard: cannot resolve repo root -- fail-closed"
    exit 2
}
$markerPath = Join-Path $top '.himmel-dev'
if (-not (Test-Path -LiteralPath $markerPath)) {
    # Not a contributor checkout -> no-op.
    exit 0
}

if ($env:DOC_GUARD_OK -eq '1') {
    Write-Host "-> doc-guard: DOC_GUARD_OK=1 -- skipping (verify catalog manually)" -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path -LiteralPath $MAP)) {
    Write-Error "-> doc-guard: map file missing -- fail-closed"
    exit 2
}

# Determine added/touched file sets based on mode.
if ($PrePush) {
    # Detached HEAD or on main/master: nothing to check.
    $branch = & git rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Error "-> doc-guard: cannot resolve HEAD -- fail-closed"; exit 2 }
    if ($branch -eq 'HEAD' -or $branch -eq 'main' -or $branch -eq 'master') { exit 0 }

    if ($env:DOC_GUARD_NO_FETCH -ne '1') {
        # Try to fetch default branch; ignore errors (offline is acceptable).
        $defaultBranch = 'main'
        foreach ($cand in @('origin/main','origin/master','main','master')) {
            $null = & git rev-parse --verify --quiet $cand 2>$null
            if ($LASTEXITCODE -eq 0) {
                $defaultBranch = $cand -replace '^origin/',''
                break
            }
        }
        & git fetch -q origin $defaultBranch 2>$null
    }

    # Resolve base: prefer origin/<default> then <default>.
    $base = $null
    foreach ($cand in @('origin/main','origin/master','main','master')) {
        $null = & git rev-parse --verify --quiet $cand 2>$null
        if ($LASTEXITCODE -eq 0) { $base = $cand; break }
    }
    if (-not $base) {
        if ($env:DOC_GUARD_NO_FETCH -eq '1') {
            Write-Host "-> doc-guard: no base + NO_FETCH -- skipping (verify catalog manually)" -ForegroundColor Yellow
            exit 0
        }
        Write-Error "-> doc-guard: no diff base after fetch -- fail-closed"
        exit 2
    }

    $added = & git diff --diff-filter=A --name-only "$base...HEAD" 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Error "-> doc-guard: cannot compute range diff -- fail-closed"; exit 2 }
    $touched = & git diff --name-only "$base...HEAD" 2>$null
    if (-not $touched) { $touched = @() }
} else {
    # Pre-commit mode (default).
    $added   = & git diff --cached --name-only --diff-filter=A 2>$null
    $touched = & git diff --cached --name-only 2>$null
    if (-not $touched) { $touched = @() }
}

# Normalise to arrays of strings.
if (-not $added) { $added = @() }
$addedLines   = @($added   | Where-Object { $_ -ne '' })
$touchedLines = @($touched | Where-Object { $_ -ne '' })

if ($addedLines.Count -eq 0) { exit 0 }

# Read map (skip blanks and comment lines).
$mapLines = Get-Content -LiteralPath $MAP | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }

$violations = @()
foreach ($line in $mapLines) {
    $parts = $line -split "`t", 4
    if ($parts.Count -lt 4) { continue }
    $strength = $parts[0].Trim(); $trigger = $parts[1].Trim()
    $regex    = $parts[2].Trim(); $doc     = $parts[3].Trim()
    if (-not $regex -or -not $doc) { continue }
    if ($strength -ne 'block' -or $trigger -ne 'add') { continue }

    # Path-keying: if the required doc does not exist on disk, the pair is inert.
    if (-not (Test-Path -LiteralPath (Join-Path $top $doc))) { continue }

    $hit = $addedLines | Where-Object { $_ -match $regex } | Select-Object -First 1
    if ($hit) {
        $docTouched = $touchedLines | Where-Object { $_ -eq $doc }
        if (-not $docTouched) {
            $violations += "     $hit  ->  must also update $doc"
        }
    }
}

if ($violations.Count -eq 0) { exit 0 }

$msg = @(
    'doc-guard: a command/skill was ADDED without updating its catalog.'
    ''
)
$msg += $violations
$msg += @(
    ''
    '   Fix: update the named doc in this change, or bypass for a doc-irrelevant'
    '   add with  DOC_GUARD_OK=1 git commit ...  (per-session env, not a prefix).'
)
Write-Host ([string]::Join([System.Environment]::NewLine, $msg)) -ForegroundColor Red
exit 1
