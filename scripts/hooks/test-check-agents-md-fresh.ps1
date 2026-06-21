# Smoke test for scripts/hooks/check-agents-md-fresh.ps1 (HIMMEL-471).
# Builds throwaway git repos, exercises each rc case, asserts exact rc.
# PowerShell twin of test-check-agents-md-fresh.sh. The hook validates the
# STAGED INDEX, so setups COMMIT an initial fresh pair then stage edits.

$ErrorActionPreference = 'Continue'
$HOOKS  = $PSScriptRoot
$SCRIPT = Join-Path $HOOKS 'check-agents-md-fresh.ps1'
$GEN    = Join-Path $HOOKS '..' | Join-Path -ChildPath 'agents-md' | Join-Path -ChildPath 'generate.mjs'

$script:failures = 0

function Invoke-Regen([string]$R) {
    $env:AGENTS_MD_SOURCE = Join-Path $R 'CLAUDE.md'
    $env:AGENTS_MD_TARGET = Join-Path $R 'AGENTS.md'
    & node $GEN --write | Out-Null
    Remove-Item Env:AGENTS_MD_SOURCE, Env:AGENTS_MD_TARGET -ErrorAction SilentlyContinue
}

function New-Repo {
    param([switch]$NoMarker, [switch]$NoAgents)
    $R = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $R | Out-Null
    & git -C $R init -q
    & git -C $R config user.email t@t; & git -C $R config user.name t
    if (-not $NoMarker) { New-Item -ItemType File -Path (Join-Path $R '.himmel-dev') | Out-Null }
    "# Fixture Rules`n`nDo the thing. Use judgement on trivial tasks.`n" | Set-Content -LiteralPath (Join-Path $R 'CLAUDE.md') -NoNewline
    if (-not $NoAgents) {
        Invoke-Regen $R
        & git -C $R add CLAUDE.md AGENTS.md; & git -C $R commit -qm init | Out-Null
    }
    return $R
}

function Run-Test {
    param([string]$Name, [int]$Want, [scriptblock]$Body)
    $rc = & $Body
    if ($rc -eq $Want) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name (rc=$rc, want $Want)"; $script:failures++ }
    Remove-Item Env:AGENTS_MD_OK -ErrorAction SilentlyContinue
}

Run-Test "no-op without .himmel-dev marker (rc=0)" 0 {
    $R = New-Repo -NoMarker; Push-Location $R
    Add-Content CLAUDE.md "`nx`n"; & git add CLAUDE.md 2>$null
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

Run-Test "no-op when no relevant file staged (rc=0)" 0 {
    $R = New-Repo; Push-Location $R
    'hi' | Set-Content other.txt; & git add other.txt 2>$null
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

Run-Test "fresh: CLAUDE.md edit + regenerated AGENTS.md both staged (rc=0)" 0 {
    $R = New-Repo; Push-Location $R
    Add-Content CLAUDE.md "`nA new rule.`n"; Invoke-Regen $R; & git add CLAUDE.md AGENTS.md 2>$null
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

Run-Test "stale: CLAUDE.md staged, AGENTS.md NOT (index stale, worktree consistent) -> block (rc=1)" 1 {
    $R = New-Repo; Push-Location $R
    Add-Content CLAUDE.md "`nAn extra rule.`n"; Invoke-Regen $R; & git add CLAUDE.md 2>$null
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

Run-Test "AGENTS.md absent from index while a generator input is staged -> block (rc=1)" 1 {
    $R = New-Repo -NoAgents; Push-Location $R
    & git add CLAUDE.md 2>$null
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

Run-Test "AGENTS_MD_OK=1 bypasses a stale tree (rc=0)" 0 {
    $R = New-Repo; Push-Location $R
    Add-Content CLAUDE.md "`nAn extra rule.`n"; & git add CLAUDE.md 2>$null
    $env:AGENTS_MD_OK = '1'
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

Run-Test "CRLF AGENTS.md in index does NOT false-positive (rc=0)" 0 {
    $R = New-Repo; Push-Location $R
    Add-Content CLAUDE.md "`nA new rule.`n"; Invoke-Regen $R
    $crlf = (Get-Content -LiteralPath AGENTS.md -Raw) -replace "`r?`n", "`r`n"
    Set-Content -LiteralPath AGENTS.md -Value $crlf -NoNewline
    & git add CLAUDE.md AGENTS.md 2>$null
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

Run-Test "cannot-evaluate: staged CLAUDE.md has an @include -> fail-closed (rc=2)" 2 {
    $R = New-Repo; Push-Location $R
    "# Fixture`n@RTK.md`nmore`n" | Set-Content CLAUDE.md -NoNewline; & git add CLAUDE.md 2>$null
    & pwsh -NoProfile -File $SCRIPT *>$null; $rc = $LASTEXITCODE; Pop-Location; $rc
}

if ($script:failures -eq 0) { Write-Host 'OK: all cases passed'; exit 0 }
else { Write-Host "FAIL: $($script:failures) case(s) failed"; exit 1 }
