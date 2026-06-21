# Drift guard: block a commit where AGENTS.md is stale vs CLAUDE.md (HIMMEL-471).
# AGENTS.md is generated from CLAUDE.md (scripts/agents-md/generate.mjs); this
# keeps the two from drifting. himmel-dev-only (gated by .himmel-dev, mirrors
# doc-guard) -- no-op in adopter clones. Fires only when CLAUDE.md / AGENTS.md /
# scripts/agents-md/* is staged. rc: 0 pass | 1 stale | 2 cannot-evaluate.
#
# Windows PowerShell twin of check-agents-md-fresh.sh.

$GEN = Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'agents-md' | Join-Path -ChildPath 'generate.mjs'

# .himmel-dev marker gate: resolve repo root via git rev-parse --show-toplevel.
$top = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $top) {
    Write-Error "-> agents-md-fresh: cannot resolve repo root -- fail-closed"
    exit 2
}
if (-not (Test-Path -LiteralPath (Join-Path $top '.himmel-dev'))) {
    # Not a himmel-dev checkout -> no-op.
    exit 0
}

if ($env:AGENTS_MD_OK -eq '1') {
    Write-Host "-> agents-md-fresh: AGENTS_MD_OK=1 -- skipping (verify AGENTS.md manually)" -ForegroundColor Yellow
    exit 0
}

# Trigger only when an input that affects AGENTS.md is staged.
$staged = & git diff --cached --name-only 2>$null
if (-not $staged) { $staged = @() }
$relevant = @($staged | Where-Object { $_ -match '^CLAUDE\.md$|^AGENTS\.md$|^scripts/agents-md/' })
if ($relevant.Count -eq 0) { exit 0 }

if (-not (Test-Path -LiteralPath $GEN)) {
    Write-Error "-> agents-md-fresh: generator missing ($GEN) -- fail-closed"
    exit 2
}

# Validate the STAGED index content (what will be committed), NOT the working
# tree — a partial `git add CLAUDE.md` (without the regenerated AGENTS.md) must
# be caught even when the working tree happens to be consistent. Start-Process
# -RedirectStandardOutput writes the raw blob byte-faithfully (the PS pipeline
# would mangle trailing newline / BOM). Index specs are repo-root-relative.
function Get-StagedBlob([string]$spec, [string]$outFile) {
    $errFile = "$outFile.err"
    $p = Start-Process -FilePath git -ArgumentList @('show', $spec) `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -NoNewWindow -Wait -PassThru
    Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    return $p.ExitCode
}

$tmpd = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmpd | Out-Null
try {
    if ((Get-StagedBlob ':CLAUDE.md' (Join-Path $tmpd 'CLAUDE.md')) -ne 0) {
        Write-Error "-> agents-md-fresh: CLAUDE.md not in index -- fail-closed"; exit 2
    }
    if ((Get-StagedBlob ':AGENTS.md' (Join-Path $tmpd 'AGENTS.md')) -ne 0) {
        # A generator input is staged but AGENTS.md is absent from the index ->
        # the regenerated file was never staged (drift). Block as stale.
        $msg = @(
            'agents-md-fresh: AGENTS.md is missing from the commit (not staged).'
            '   Fix: node scripts/agents-md/generate.mjs --write   (then stage AGENTS.md)'
        )
        Write-Host ([string]::Join([System.Environment]::NewLine, $msg)) -ForegroundColor Red
        exit 1
    }
    $pre = Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'agents-md' | Join-Path -ChildPath 'preamble.md'
    $deb = Join-Path $PSScriptRoot '..' | Join-Path -ChildPath 'agents-md' | Join-Path -ChildPath 'debrand.json'
    if ((Get-StagedBlob ':scripts/agents-md/preamble.md' (Join-Path $tmpd 'preamble.md')) -eq 0) { $pre = Join-Path $tmpd 'preamble.md' }
    if ((Get-StagedBlob ':scripts/agents-md/debrand.json' (Join-Path $tmpd 'debrand.json')) -eq 0) { $deb = Join-Path $tmpd 'debrand.json' }

    $env:AGENTS_MD_SOURCE   = Join-Path $tmpd 'CLAUDE.md'
    $env:AGENTS_MD_TARGET   = Join-Path $tmpd 'AGENTS.md'
    $env:AGENTS_MD_PREAMBLE = $pre
    $env:AGENTS_MD_DEBRAND  = $deb
    & node $GEN --check
    $genRc = $LASTEXITCODE
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tmpd -ErrorAction SilentlyContinue
}

switch ($genRc) {
    0 { exit 0 }
    1 {
        $msg = @(
            'agents-md-fresh: AGENTS.md is STALE vs CLAUDE.md.'
            '   Fix: node scripts/agents-md/generate.mjs --write   (then stage AGENTS.md)'
            '   Bypass a doc-irrelevant edit with  AGENTS_MD_OK=1 git commit ...  (session env, not a prefix).'
        )
        Write-Host ([string]::Join([System.Environment]::NewLine, $msg)) -ForegroundColor Red
        exit 1
    }
    default {
        Write-Error "-> agents-md-fresh: generator cannot evaluate (see message above) -- fail-closed"
        exit 2
    }
}
