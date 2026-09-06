# Smoke test for scripts/gen-changelog.ps1
# Usage: pwsh -File scripts/hooks/test-gen-changelog.ps1
# Exit 0 if all cases pass, 1 otherwise.
$ErrorActionPreference = 'Stop'

$HOOKS = Split-Path -Parent $MyInvocation.MyCommand.Path
$GEN   = Join-Path (Split-Path -Parent $HOOKS) 'gen-changelog.ps1'

$failures = 0

function setup_commits {
    $r = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ } | Select-Object -ExpandProperty FullName
    git -C $r init -q
    git -C $r config user.email 't@t'
    git -C $r config user.name 't'
    git -C $r commit -q --allow-empty -m 'chore: initial scaffold'
    git -C $r commit -q --allow-empty -m 'feat: baseline feature'
    git -C $r commit -q --allow-empty -m 'fix: baseline bug fix'
    return $r
}

function run_test {
    param([string]$name, [scriptblock]$body)
    try {
        & $body
        Write-Host "  PASS  $name"
    } catch {
        Write-Host "  FAIL  $name ($_)"
        $script:failures++
    }
}

# ---------------------------------------------------------------------------
# Test 1: idempotent on immediate re-run
# ---------------------------------------------------------------------------
run_test "idempotent on immediate re-run" {
    $r = setup_commits
    Set-Location $r
    pwsh -File $GEN
    $a = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    pwsh -File $GEN
    $b = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($a -ne $b) { throw "CHANGELOG changed on re-run" }
}

# ---------------------------------------------------------------------------
# Test 2: non-conventional commit lands under Other
# ---------------------------------------------------------------------------
run_test "non-conventional commit lands under Other" {
    $r = setup_commits
    Set-Location $r
    git -C $r commit -q --allow-empty -m 'random no-type subject'
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($content -notmatch '### Other') { throw "Missing ### Other section" }
    if ($content -notmatch 'random no-type subject') { throw "Missing commit subject" }
}

# ---------------------------------------------------------------------------
# Test 3: feat lands under Added
# ---------------------------------------------------------------------------
run_test "feat lands under Added" {
    $r = setup_commits
    Set-Location $r
    git -C $r commit -q --allow-empty -m 'feat: shiny thing'
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    # Check that "shiny thing" appears after "### Added"
    if ($content -notmatch '(?s)### Added.*shiny thing') { throw "shiny thing not under Added" }
}

# ---------------------------------------------------------------------------
# Test 4: output is end-of-file-fixer clean (LF, single trailing newline)
# ---------------------------------------------------------------------------
run_test "output is end-of-file-fixer clean (LF, single trailing newline)" {
    $r = setup_commits
    Set-Location $r
    pwsh -File $GEN
    $raw = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($raw -match "`r") { throw "output contains CR (expected LF-only)" }
    if ($raw -match "`n`n$") { throw "output ends with a blank line (expected single trailing newline)" }
    if ($raw -notmatch "`n$") { throw "output missing trailing newline" }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if ($failures -eq 0) {
    Write-Host "OK: all cases passed"
    exit 0
} else {
    Write-Host "FAIL: $failures case(s) failed"
    exit 1
}
