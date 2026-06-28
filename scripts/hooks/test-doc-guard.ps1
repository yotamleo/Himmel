# Smoke test for scripts/hooks/check-doc-guard.ps1 (HIMMEL-454).
#
# Builds throwaway git repos, exercises each rc case, asserts exact rc.
# Usage: pwsh -File scripts/hooks/test-doc-guard.ps1
#
# The script under test is run IN PLACE from the real tree (same pattern as the
# bash suite): it resolves doc-guard-map.tsv via $PSScriptRoot, so it must
# stay where that sibling file lives. Only the git repo is a tempdir.
# We Set-Location into the tempdir so git commands pick up the right repo.
$ErrorActionPreference = 'Stop'
$SCRIPT = Join-Path $PSScriptRoot 'check-doc-guard.ps1'
$script:fails = 0

function Pass([string]$m) { "  PASS  $m" }
function Fail([string]$m) { "  FAIL  $m"; $script:fails++ }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

function New-TestRepo {
    $r = Join-Path ([System.IO.Path]::GetTempPath()) ("dg-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $r -Force | Out-Null
    & git -C $r init -q 2>$null
    & git -C $r config user.email 't@t'
    & git -C $r config user.name  't'
    New-Item -Path (Join-Path $r '.himmel-dev') -ItemType File -Force | Out-Null
    return $r
}

function New-TestRepoNoMarker {
    $r = New-TestRepo
    Remove-Item -LiteralPath (Join-Path $r '.himmel-dev') -Force
    return $r
}

# Invoke the script in a subprocess so Set-Location and env vars don't leak.
function Invoke-Guard {
    param(
        [string]$RepoDir,
        [string[]]$ScriptArgs = @(),
        [hashtable]$Env = @{}
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName  = (Get-Command pwsh).Source
    $argStr = "-NoProfile -NonInteractive -File `"$SCRIPT`""
    if ($ScriptArgs.Count -gt 0) { $argStr += ' ' + ($ScriptArgs -join ' ') }
    $psi.Arguments = $argStr
    $psi.WorkingDirectory        = $RepoDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    # Copy current env into the child, then apply overrides.
    foreach ($e in [System.Environment]::GetEnvironmentVariables(
            [System.EnvironmentVariableTarget]::Process).GetEnumerator()) {
        $psi.EnvironmentVariables[$e.Key] = $e.Value
    }
    # Remove env vars we want unset by default.
    foreach ($k in @('DOC_GUARD_OK','DOC_GUARD_FORCE_ERR','DOC_GUARD_NO_FETCH')) {
        $psi.EnvironmentVariables.Remove($k)
    }
    foreach ($k in $Env.Keys) {
        $psi.EnvironmentVariables[$k] = $Env[$k]
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    [void]$proc.StandardOutput.ReadToEnd()
    [void]$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return $proc.ExitCode
}

# ---------------------------------------------------------------------------
# Case 1: blocks added command without catalog staged (rc=1)
# ---------------------------------------------------------------------------
$r1 = New-TestRepo
try {
    New-Item -Path (Join-Path $r1 '.claude\commands') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r1 'docs')             -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r1 '.claude\commands\foo.md') -ItemType File -Force | Out-Null
    New-Item -Path (Join-Path $r1 'docs\commands-catalog.md') -ItemType File -Force | Out-Null
    # Stage the command file only (not the catalog)
    & git -C $r1 add '.claude/commands/foo.md' 2>$null
    $rc = Invoke-Guard -RepoDir $r1
    if ($rc -eq 1) { Pass 'blocks added command without catalog (rc=1)' }
    else           { Fail "blocks added command without catalog: expected rc=1, got $rc" }
} finally { Remove-Item -LiteralPath $r1 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Case 2: passes added command WITH catalog staged (rc=0)
# ---------------------------------------------------------------------------
$r2 = New-TestRepo
try {
    New-Item -Path (Join-Path $r2 '.claude\commands') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r2 'docs')             -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r2 '.claude\commands\foo.md') -ItemType File -Force | Out-Null
    New-Item -Path (Join-Path $r2 'docs\commands-catalog.md') -ItemType File -Force | Out-Null
    & git -C $r2 add '.claude/commands/foo.md' 'docs/commands-catalog.md' 2>$null
    $rc = Invoke-Guard -RepoDir $r2
    if ($rc -eq 0) { Pass 'passes added command WITH catalog staged (rc=0)' }
    else           { Fail "passes added command WITH catalog staged: expected rc=0, got $rc" }
} finally { Remove-Item -LiteralPath $r2 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Case 3: no-op without .himmel-dev marker (rc=0)
# ---------------------------------------------------------------------------
$r3 = New-TestRepoNoMarker
try {
    New-Item -Path (Join-Path $r3 '.claude\commands') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r3 '.claude\commands\foo.md') -ItemType File -Force | Out-Null
    & git -C $r3 add '.claude/commands/foo.md' 2>$null
    $rc = Invoke-Guard -RepoDir $r3
    if ($rc -eq 0) { Pass 'no-op without .himmel-dev marker (rc=0)' }
    else           { Fail "no-op without .himmel-dev marker: expected rc=0, got $rc" }
} finally { Remove-Item -LiteralPath $r3 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Case 4: DOC_GUARD_OK=1 bypass (rc=0)
# ---------------------------------------------------------------------------
$r4 = New-TestRepo
try {
    New-Item -Path (Join-Path $r4 '.claude\commands') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r4 'docs')             -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r4 '.claude\commands\foo.md') -ItemType File -Force | Out-Null
    New-Item -Path (Join-Path $r4 'docs\commands-catalog.md') -ItemType File -Force | Out-Null
    & git -C $r4 add '.claude/commands/foo.md' 2>$null
    $rc = Invoke-Guard -RepoDir $r4 -Env @{ DOC_GUARD_OK = '1' }
    if ($rc -eq 0) { Pass 'DOC_GUARD_OK=1 bypasses (rc=0)' }
    else           { Fail "DOC_GUARD_OK=1 bypass: expected rc=0, got $rc" }
} finally { Remove-Item -LiteralPath $r4 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Case 5: DOC_GUARD_FORCE_ERR=1 exits 2
# ---------------------------------------------------------------------------
$r5 = New-TestRepo
try {
    $rc = Invoke-Guard -RepoDir $r5 -Env @{ DOC_GUARD_FORCE_ERR = '1' }
    if ($rc -eq 2) { Pass 'DOC_GUARD_FORCE_ERR=1 exits 2' }
    else           { Fail "DOC_GUARD_FORCE_ERR=1: expected rc=2, got $rc" }
} finally { Remove-Item -LiteralPath $r5 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Case 6: blocks added plugin manifest without llms.txt (rc=1)
# ---------------------------------------------------------------------------
$r6 = New-TestRepo
try {
    New-Item -Path (Join-Path $r6 'marketplace\plugins\foo\.claude-plugin') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r6 'llms.txt') -ItemType File -Force | Out-Null
    New-Item -Path (Join-Path $r6 'marketplace\plugins\foo\.claude-plugin\plugin.json') -ItemType File -Force | Out-Null
    & git -C $r6 add 'marketplace/plugins/foo/.claude-plugin/plugin.json' 2>$null
    $rc = Invoke-Guard -RepoDir $r6
    if ($rc -eq 1) { Pass 'blocks added plugin manifest without llms.txt (rc=1)' }
    else           { Fail "blocks added plugin manifest without llms.txt: expected rc=1, got $rc" }
} finally { Remove-Item -LiteralPath $r6 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Case 7: passes added plugin manifest WITH llms.txt staged (rc=0)
# ---------------------------------------------------------------------------
$r7 = New-TestRepo
try {
    New-Item -Path (Join-Path $r7 'marketplace\plugins\foo\.claude-plugin') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r7 'llms.txt') -ItemType File -Force | Out-Null
    New-Item -Path (Join-Path $r7 'marketplace\plugins\foo\.claude-plugin\plugin.json') -ItemType File -Force | Out-Null
    & git -C $r7 add 'marketplace/plugins/foo/.claude-plugin/plugin.json' 'llms.txt' 2>$null
    $rc = Invoke-Guard -RepoDir $r7
    if ($rc -eq 0) { Pass 'passes added plugin manifest WITH llms.txt (rc=0)' }
    else           { Fail "passes added plugin manifest WITH llms.txt: expected rc=0, got $rc" }
} finally { Remove-Item -LiteralPath $r7 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Case 8: non-manifest file under a plugin does NOT require llms.txt (rc=0)
# ---------------------------------------------------------------------------
$r8 = New-TestRepo
try {
    New-Item -Path (Join-Path $r8 'marketplace\plugins\foo\lib') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $r8 'llms.txt') -ItemType File -Force | Out-Null
    New-Item -Path (Join-Path $r8 'marketplace\plugins\foo\lib\util.sh') -ItemType File -Force | Out-Null
    & git -C $r8 add 'marketplace/plugins/foo/lib/util.sh' 2>$null
    $rc = Invoke-Guard -RepoDir $r8
    if ($rc -eq 0) { Pass 'non-manifest file under a plugin does NOT require llms.txt (rc=0)' }
    else           { Fail "non-manifest under plugin: expected rc=0, got $rc" }
} finally { Remove-Item -LiteralPath $r8 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if ($script:fails -eq 0) { 'ALL PASS'; exit 0 }
else                     { "$($script:fails) FAILED"; exit 1 }
