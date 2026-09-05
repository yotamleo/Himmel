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

# backfilled_tag_commits -- Finding-2 repro (HIMMEL-2250 CR): a backfilled
# ANNOTATED tag on an OLDER commit gets a newer creatordate than a
# lightweight tag on a NEWER commit; `--sort=-creatordate` would order it
# first and compute the `<prev>..<tag>` ranges against the wrong predecessor.
function backfilled_tag_commits {
    $r = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ } | Select-Object -ExpandProperty FullName
    git -C $r init -q
    git -C $r config user.email 't@t'
    git -C $r config user.name 't'
    $env:GIT_AUTHOR_DATE = '2020-01-01T00:00:00'
    $env:GIT_COMMITTER_DATE = '2020-01-01T00:00:00'
    git -C $r commit -q --allow-empty -m 'feat: ancient feature'
    $env:GIT_AUTHOR_DATE = '2020-06-01T00:00:00'
    $env:GIT_COMMITTER_DATE = '2020-06-01T00:00:00'
    git -C $r commit -q --allow-empty -m 'feat: middle feature'
    Remove-Item Env:\GIT_AUTHOR_DATE, Env:\GIT_COMMITTER_DATE
    git -C $r tag v0.2.0
    git -C $r tag -a v0.1.0 HEAD~1 -m 'backfilled v0.1.0'
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

# tag_commits — HIMMEL-2250 version-tag-grouping fixture: chore/feat before
# v0.1.0, a fix after it, a non-version tag that must not become a section,
# then a newest feat. Mirrors the fixture in the ticket brief.
function tag_commits {
    $r = setup_commits
    git -C $r tag v0.1.0
    git -C $r commit -q --allow-empty -m 'fix: post-release fix'
    git -C $r tag recovered-stash
    git -C $r commit -q --allow-empty -m 'feat: newest thing'
    return $r
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
# Test 5: tagless repo -> single Unreleased section (no churn on the pre-
# HIMMEL-2250 shape)
# ---------------------------------------------------------------------------
run_test "tagless repo produces a single Unreleased section" {
    $r = setup_commits
    Set-Location $r
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    $unreleasedCount = ([regex]::Matches($content, '## \[Unreleased\]')).Count
    if ($unreleasedCount -ne 1) { throw "expected exactly one ## [Unreleased], got $unreleasedCount" }
    if ($content -match '## \[v') { throw "tagless repo must not emit a version section" }
}

# ---------------------------------------------------------------------------
# Test 6: version-tag grouping
# ---------------------------------------------------------------------------
run_test "version-tag grouping splits Unreleased from the tagged release" {
    $r = tag_commits
    Set-Location $r
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($content -notmatch '## \[v0\.1\.0\] - \d{4}-\d{2}-\d{2}') { throw "missing dated v0.1.0 heading" }
    if ($content -notmatch '(?s)## \[Unreleased\].*newest thing.*## \[v0\.1\.0\]') { throw "newest thing not in Unreleased, before v0.1.0" }
    if ($content -notmatch '(?s)## \[v0\.1\.0\].*baseline feature') { throw "baseline feature not under v0.1.0" }
}

# ---------------------------------------------------------------------------
# Test 7: non-version tag is ignored
# ---------------------------------------------------------------------------
run_test "non-version tag produces no section" {
    $r = tag_commits
    Set-Location $r
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($content -match '## \[recovered-stash\]') { throw "non-version tag must not become a release section" }
}

# ---------------------------------------------------------------------------
# Test 8: idempotent with tags present
# ---------------------------------------------------------------------------
run_test "idempotent on immediate re-run (tags present)" {
    $r = tag_commits
    Set-Location $r
    pwsh -File $GEN
    $a = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    pwsh -File $GEN
    $b = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($a -ne $b) { throw "CHANGELOG changed on re-run" }
}

# ---------------------------------------------------------------------------
# Test 9: --check exits 0 and writes nothing when current
# ---------------------------------------------------------------------------
run_test "--check exits 0 when CHANGELOG.md is current" {
    $r = tag_commits
    Set-Location $r
    pwsh -File $GEN
    $before = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    $checkOutput = pwsh -File $GEN --check
    $code = $LASTEXITCODE
    $after = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($code -ne 0) { throw "expected exit 0, got $code" }
    if ($checkOutput -notmatch 'OK gen-changelog: CHANGELOG.md is current') { throw "missing OK message: $checkOutput" }
    if ($before -ne $after) { throw "--check must not modify CHANGELOG.md" }
}

# ---------------------------------------------------------------------------
# Test 10: --check exits 1 and writes nothing when stale
# ---------------------------------------------------------------------------
run_test "--check exits 1 when CHANGELOG.md is stale" {
    $r = tag_commits
    Set-Location $r
    pwsh -File $GEN
    $before = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    git -C $r commit -q --allow-empty -m 'feat: not yet in the changelog'
    $checkOutput = pwsh -File $GEN --check
    $code = $LASTEXITCODE
    $after = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($code -ne 1) { throw "expected exit 1, got $code" }
    if ($checkOutput -notmatch 'STALE gen-changelog: CHANGELOG\.md is \d+ entr\(ies\) behind') { throw "missing STALE message: $checkOutput" }
    if ($before -ne $after) { throw "--check must not modify CHANGELOG.md" }
}

# ---------------------------------------------------------------------------
# Test 11-13: CR-round regression cases (HIMMEL-2250 findings 1, 2, 4)
# ---------------------------------------------------------------------------
run_test "--check reports the true entry count when a new commit opens a new section" {
    $r = setup_commits
    Set-Location $r
    pwsh -File $GEN
    git -C $r commit -q --allow-empty -m 'weird non-conventional subject'
    $checkOutput = pwsh -File $GEN --check
    $code = $LASTEXITCODE
    if ($code -ne 1) { throw "expected exit 1, got $code" }
    if ($checkOutput -notmatch 'STALE gen-changelog: CHANGELOG\.md is 1 entr\(ies\) behind') { throw "expected count 1, got: $checkOutput" }
}

run_test "ancestry ordering handles a backfilled annotated tag" {
    $r = backfilled_tag_commits
    Set-Location $r
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    # v0.2.0 (2 commits) must sort before v0.1.0 (1 commit, backfilled with a
    # newer creatordate) -- ancestry order, not creatordate order.
    if ($content -notmatch '(?s)## \[v0\.2\.0\].*### Added.*middle feature.*## \[v0\.1\.0\].*### Added.*ancient feature') {
        throw "sections not in ancestry order (v0.2.0 before v0.1.0): $content"
    }
    if (([regex]::Matches($content, 'middle feature')).Count -ne 1) { throw "middle feature duplicated" }
    if (([regex]::Matches($content, 'ancient feature')).Count -ne 1) { throw "ancient feature duplicated" }
    if ($content -match '(?s)## \[Unreleased\](.*?)## \[v0\.2\.0\]') {
        if ($matches[1] -match '###') { throw "Unreleased should be empty (HEAD is at v0.2.0)" }
    } else {
        throw "could not locate Unreleased section"
    }
}

run_test "--check on missing CHANGELOG.md reports missing, not 0 entries behind" {
    $r = setup_commits
    Set-Location $r
    if (Test-Path (Join-Path $r 'CHANGELOG.md')) { throw "fixture unexpectedly has CHANGELOG.md" }
    $checkOutput = pwsh -File $GEN --check
    $code = $LASTEXITCODE
    if ($code -ne 1) { throw "expected exit 1, got $code" }
    if ($checkOutput -notmatch 'STALE gen-changelog: CHANGELOG\.md is missing') { throw "missing STALE-missing message: $checkOutput" }
    if (Test-Path (Join-Path $r 'CHANGELOG.md')) { throw "--check must not create CHANGELOG.md" }
}

# ---------------------------------------------------------------------------
# Test 14-16: CR finding 2 -- version-tag glob accepted non-version tags
# ---------------------------------------------------------------------------
run_test "glob-matching but non-version tag (v1-backup) creates no changelog section" {
    $r = setup_commits
    Set-Location $r
    git -C $r tag v1-backup
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($content -match [regex]::Escape('[v1-backup]')) { throw "v1-backup got a changelog section" }
}

run_test "too-few-components tag (v1.2) creates no changelog section" {
    $r = setup_commits
    Set-Location $r
    git -C $r tag v1.2
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($content -match [regex]::Escape('[v1.2]')) { throw "v1.2 got a changelog section" }
}

run_test "pre-release tag (v0.1.0-rc.1) DOES get a changelog section" {
    $r = setup_commits
    Set-Location $r
    git -C $r tag v0.1.0-rc.1
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    if ($content -notmatch [regex]::Escape('[v0.1.0-rc.1]')) { throw "v0.1.0-rc.1 did not get a changelog section" }
}

# ---------------------------------------------------------------------------
# Test 19-20: CR round 3 -- misleading-zero drift message + same-commit tag
# tie-break (HIMMEL-2250 findings 1, 2)
# ---------------------------------------------------------------------------
run_test "tag-only drift (no new commits) reports true staleness, not a misleading zero count" {
    $r = setup_commits
    Set-Location $r
    pwsh -File $GEN
    git -C $r tag v0.1.0
    $checkOutput = pwsh -File $GEN --check
    $code = $LASTEXITCODE
    if ($code -ne 1) { throw "expected exit 1, got $code" }
    if ($checkOutput -match '0 entr\(ies\) behind') { throw "misleading zero count leaked through: $checkOutput" }
    if ($checkOutput -notmatch '^STALE gen-changelog: CHANGELOG\.md structure changed with no new entries') { throw "missing new drift wording: $checkOutput" }
}

run_test "same-commit tags: release sorts before pre-release on an ancestry tie" {
    $r = setup_commits
    Set-Location $r
    git -C $r tag v0.1.0-rc.1
    git -C $r tag v0.1.0
    pwsh -File $GEN
    $content = Get-Content (Join-Path $r 'CHANGELOG.md') -Raw
    $order = [regex]::Matches($content, '^## \[[^\]]*\]', 'Multiline') | ForEach-Object { $_.Value }
    $expected = @('## [Unreleased]', '## [v0.1.0]', '## [v0.1.0-rc.1]')
    if (@(Compare-Object $order $expected -SyncWindow 0).Count -ne 0) { throw "section order was $($order -join ', ')" }
}

# ---------------------------------------------------------------------------
# Test 17: CR finding 1 -- --check must do a TRUE byte comparison, not a text
# one. Get-Content -Raw text-decodes, which disagrees with the .sh twin's
# `cmp` in both directions: false STALE on a byte-identical non-ASCII file
# under Windows PowerShell 5.1, and false CURRENT on a file that differs only
# by a UTF-8 BOM (text-equal, byte-different) under both 5.1 and pwsh 7.
# ---------------------------------------------------------------------------
run_test "--check byte comparison: non-ASCII is CURRENT when byte-identical, STALE when a BOM is added" {
    $r = setup_commits
    Set-Location $r
    git -C $r commit -q --allow-empty -m 'feat: widen support — from A to B, C → D'
    pwsh -File $GEN
    $checkOutput = pwsh -File $GEN --check
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "expected exit 0 (current) for a byte-identical non-ASCII file, got $code : $checkOutput" }

    # Prepend a UTF-8 BOM: text-equal, byte-different. A true byte compare
    # must catch this; Get-Content -Raw text decoding would not.
    $path = Join-Path $r 'CHANGELOG.md'
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $bom = [byte[]](0xEF,0xBB,0xBF)
    [System.IO.File]::WriteAllBytes($path, $bom + $bytes)
    $checkOutput2 = pwsh -File $GEN --check
    $code2 = $LASTEXITCODE
    if ($code2 -ne 1) { throw "expected exit 1 (stale) for a BOM'd file, got $code2 : $checkOutput2" }
}

# ---------------------------------------------------------------------------
# Test 18: git-log subprocess capture must decode non-ASCII as UTF-8, not the
# console's legacy OEM codepage (HIMMEL-2250 CR round 2: this is the actual
# root cause behind a 437-vs-1 --check count divergence found on a real repo
# -- PowerShell was mis-decoding every commit subject with an em dash/arrow
# on capture, corrupting both the written CHANGELOG.md content and the
# --check entry count for any repo with non-ASCII commit history).
# ---------------------------------------------------------------------------
run_test "non-ASCII commit subject round-trips correctly (no mis-decoded bytes)" {
    $r = setup_commits
    Set-Location $r
    git -C $r commit -q --allow-empty -m 'feat: widen support — from A to B, C → D'
    pwsh -File $GEN
    $path = Join-Path $r 'CHANGELOG.md'
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch [regex]::Escape('widen support — from A to B, C → D')) {
        throw "non-ASCII commit subject was mis-decoded on git-log capture: $text"
    }
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
