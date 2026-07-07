# Smoke test for scripts/statusline/check-hud-drift.ps1 (HIMMEL-718 Task 1.2).
#
# Builds throwaway git repos with a fixture vendored tree, exercises each rc
# case, asserts exact rc. Mirrors test-check-hud-drift.sh (the bash suite is
# the spec); same subprocess pattern as test-doc-guard.ps1.
# Usage: pwsh -File scripts/statusline/test-check-hud-drift.ps1
$ErrorActionPreference = 'Stop'
$SCRIPT = Join-Path $PSScriptRoot 'check-hud-drift.ps1'
$HUD_REL = 'marketplace/plugins/claude-hud'
$script:fails = 0

function Pass([string]$m) { "  PASS  $m" }
function Fail([string]$m) { "  FAIL  $m"; $script:fails++ }

function New-TestRepo {
    $r = Join-Path ([System.IO.Path]::GetTempPath()) ("hd-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $r -Force | Out-Null
    & git -C $r init -q 2>$null
    & git -C $r config user.email 't@t'
    & git -C $r config user.name  't'
    New-Item -Path (Join-Path $r '.himmel-dev') -ItemType File -Force | Out-Null
    $hud = Join-Path $r $HUD_REL
    New-Item -ItemType Directory -Path (Join-Path $hud 'dist')   -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $hud 'config') -Force | Out-Null
    # Fixture mirrors the .sh suite: spaced path, mixed-case names (ordinal
    # sort), root config.js + VENDORED.mdx (exclude-regex boundary hazards).
    Set-Content -LiteralPath (Join-Path $hud 'dist/index.js') -Value 'console.log(1)'
    Set-Content -LiteralPath (Join-Path $hud 'dist/my file.js') -Value 'spaced'
    Set-Content -LiteralPath (Join-Path $hud 'README.md')     -Value '# upstream readme'
    Set-Content -LiteralPath (Join-Path $hud 'Zebra.js')      -Value 'zebra'
    Set-Content -LiteralPath (Join-Path $hud 'apple.js')      -Value 'apple'
    Set-Content -LiteralPath (Join-Path $hud 'config.js')     -Value 'root-config'
    Set-Content -LiteralPath (Join-Path $hud 'VENDORED.mdx')  -Value 'mdx'
    Set-Content -LiteralPath (Join-Path $hud '.gitignore')    -Value '!dist/'
    Set-Content -LiteralPath (Join-Path $hud 'config/himmel-config.json') -Value '{}'
    Set-Content -LiteralPath (Join-Path $hud 'VENDORED.md') -Value @'
pinned_commit:        deadbeef
vendored_tree_hash:   __SET_BY_check-hud-drift.sh__
'@
    & git -C $r add -f $HUD_REL 2>$null
    & git -C $r commit -qm seed 2>$null
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
    $psi.WorkingDirectory       = $RepoDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    foreach ($e in [System.Environment]::GetEnvironmentVariables(
            [System.EnvironmentVariableTarget]::Process).GetEnumerator()) {
        $psi.EnvironmentVariables[$e.Key] = $e.Value
    }
    foreach ($k in @('HUD_DRIFT_OK')) {
        $psi.EnvironmentVariables.Remove($k)
    }
    foreach ($k in $Env.Keys) {
        $psi.EnvironmentVariables[$k] = $Env[$k]
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $script:LastGuardOutput = $out + $err
    return $proc.ExitCode
}

# New-PinnedRepo: New-TestRepo + -Write + commit, so verify starts clean.
function New-PinnedRepo {
    $r = New-TestRepo
    if ((Invoke-Guard -RepoDir $r -ScriptArgs @('-Write')) -ne 0) { throw "-Write failed during fixture setup" }
    & git -C $r add -f $HUD_REL 2>$null
    & git -C $r commit -qm pin 2>$null
    return $r
}

# Case (a): clean tree + matching pin -> rc=0
$r = New-PinnedRepo
if ((Invoke-Guard -RepoDir $r) -eq 0) { Pass '(a) clean tree + matching pin -> rc=0' }
else { Fail '(a) clean tree + matching pin -> rc=0' }

# -Write sets vendored_tree_hash + writes VENDORED.manifest
$md = Get-Content -LiteralPath (Join-Path $r "$HUD_REL/VENDORED.md") -Raw
$manifestPath = Join-Path $r "$HUD_REL/VENDORED.manifest"
if ($md -notmatch '__SET_BY' -and $md -match '(?m)^vendored_tree_hash:\s+[0-9a-f]{64}' -and
    (Test-Path -LiteralPath $manifestPath) -and (Get-Item -LiteralPath $manifestPath).Length -gt 0) {
    Pass '-Write sets vendored_tree_hash + writes VENDORED.manifest'
} else { Fail '-Write sets vendored_tree_hash + writes VENDORED.manifest' }

# Placeholder pin (never written) -> rc=1
$r = New-TestRepo
if ((Invoke-Guard -RepoDir $r) -eq 1) { Pass 'placeholder pin (never written) -> rc=1' }
else { Fail 'placeholder pin (never written) -> rc=1' }

# Case (b): mutated upstream file w/o pin bump -> rc=1 + ONLY that path offending
$r = New-PinnedRepo
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/dist/index.js") -Value 'tampered'
$rc = Invoke-Guard -RepoDir $r
if ($rc -eq 1 -and $script:LastGuardOutput -match 'dist/index\.js' -and
    $script:LastGuardOutput -notmatch 'README\.md') {
    Pass '(b) mutated upstream file w/o pin bump -> rc=1 + ONLY that path offending'
} else { Fail '(b) mutated upstream file w/o pin bump -> rc=1 + ONLY that path offending' }

# Case (b2): deleted upstream file -> rc=1
$r = New-PinnedRepo
Remove-Item -LiteralPath (Join-Path $r "$HUD_REL/README.md") -Force
if ((Invoke-Guard -RepoDir $r) -eq 1) { Pass '(b2) deleted upstream file -> rc=1' }
else { Fail '(b2) deleted upstream file -> rc=1' }

# Case (c): -Write after mutation (pin bump) -> verify rc=0
$r = New-PinnedRepo
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/dist/index.js") -Value 'tampered'
if ((Invoke-Guard -RepoDir $r -ScriptArgs @('-Write')) -eq 0 -and (Invoke-Guard -RepoDir $r) -eq 0) {
    Pass '(c) -Write after mutation (pin bump) -> verify rc=0'
} else { Fail '(c) -Write after mutation (pin bump) -> verify rc=0' }

# Case (d): himmel-owned edits NOT tripped -> rc=0
$r = New-PinnedRepo
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/VENDORED.md") -Value 'note'
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/.gitignore")  -Value '!dist/**'
Set-Content -LiteralPath (Join-Path $r "$HUD_REL/config/himmel-config.json") -Value '{"a":1}'
if ((Invoke-Guard -RepoDir $r) -eq 0) { Pass '(d) himmel-owned edits NOT tripped -> rc=0' }
else { Fail '(d) himmel-owned edits NOT tripped -> rc=0' }

# No-op without .himmel-dev marker -> rc=0
$r = New-PinnedRepo
Remove-Item -LiteralPath (Join-Path $r '.himmel-dev') -Force
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/dist/index.js") -Value 'tampered'
if ((Invoke-Guard -RepoDir $r) -eq 0) { Pass 'no-op without .himmel-dev marker -> rc=0' }
else { Fail 'no-op without .himmel-dev marker -> rc=0' }

# HUD_DRIFT_OK=1 bypasses -> rc=0
$r = New-PinnedRepo
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/dist/index.js") -Value 'tampered'
if ((Invoke-Guard -RepoDir $r -Env @{ HUD_DRIFT_OK = '1' }) -eq 0) { Pass 'HUD_DRIFT_OK=1 bypasses -> rc=0' }
else { Fail 'HUD_DRIFT_OK=1 bypasses -> rc=0' }

# Outside a git repo -> rc=2 (fail-closed)
$nr = Join-Path ([System.IO.Path]::GetTempPath()) ("hd-nogit-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $nr -Force | Out-Null
if ((Invoke-Guard -RepoDir $nr) -eq 2) { Pass 'outside a git repo -> rc=2 (fail-closed)' }
else { Fail 'outside a git repo -> rc=2 (fail-closed)' }

# Vendored dir missing in a marked repo -> rc=2 (fail-closed)
$r = New-TestRepo
Remove-Item -LiteralPath (Join-Path $r $HUD_REL) -Recurse -Force
if ((Invoke-Guard -RepoDir $r) -eq 2) { Pass 'vendored dir missing in a marked repo -> rc=2 (fail-closed)' }
else { Fail 'vendored dir missing in a marked repo -> rc=2 (fail-closed)' }

# VENDORED.md missing (dir present) -> rc=2 (fail-closed)
$r = New-TestRepo
Remove-Item -LiteralPath (Join-Path $r "$HUD_REL/VENDORED.md") -Force
if ((Invoke-Guard -RepoDir $r) -eq 2) { Pass 'VENDORED.md missing (dir present) -> rc=2 (fail-closed)' }
else { Fail 'VENDORED.md missing (dir present) -> rc=2 (fail-closed)' }

# vendored_tree_hash line absent -> verify rc=2, -Write rc=2 (no silent no-op)
$r = New-PinnedRepo
Set-Content -LiteralPath (Join-Path $r "$HUD_REL/VENDORED.md") -Value 'pinned_commit:        deadbeef'
if ((Invoke-Guard -RepoDir $r) -eq 2 -and (Invoke-Guard -RepoDir $r -ScriptArgs @('-Write')) -eq 2) {
    Pass 'vendored_tree_hash line absent -> verify rc=2, -Write rc=2 (no silent no-op)'
} else { Fail 'vendored_tree_hash line absent -> verify rc=2, -Write rc=2 (no silent no-op)' }

# All-owned tree (no upstream-derived files) -> rc=2 (fail-closed). Exercises
# the PS-specific $relList.Count -eq 0 guard, unexercised on the Windows path.
$r = New-TestRepo
& git -C $r rm -q -f "$HUD_REL/dist/index.js" "$HUD_REL/dist/my file.js" "$HUD_REL/README.md" `
    "$HUD_REL/Zebra.js" "$HUD_REL/apple.js" "$HUD_REL/config.js" "$HUD_REL/VENDORED.mdx" 2>$null
& git -C $r commit -qm strip 2>$null
if ((Invoke-Guard -RepoDir $r) -eq 2) { Pass 'all-owned tree (no upstream-derived files) -> rc=2 (fail-closed)' }
else { Fail 'all-owned tree (no upstream-derived files) -> rc=2 (fail-closed)' }

# -Write refuses on missing tracked file -> rc=1 + MISSING path
$r = New-PinnedRepo
Remove-Item -LiteralPath (Join-Path $r "$HUD_REL/README.md") -Force
$rc = Invoke-Guard -RepoDir $r -ScriptArgs @('-Write')
if ($rc -eq 1 -and $script:LastGuardOutput -match 'MISSING' -and $script:LastGuardOutput -match 'README\.md') {
    Pass '-Write refuses on missing tracked file -> rc=1 + MISSING path'
} else { Fail '-Write refuses on missing tracked file -> rc=1 + MISSING path' }

# Exclude-regex boundaries: root config.js + VENDORED.mdx ARE in scope -> rc=1
$r = New-PinnedRepo
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/config.js") -Value 'tampered'
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/VENDORED.mdx") -Value 'tampered'
$rc = Invoke-Guard -RepoDir $r
if ($rc -eq 1 -and $script:LastGuardOutput -match 'config\.js' -and $script:LastGuardOutput -match 'VENDORED\.mdx') {
    Pass 'exclude-regex boundaries: root config.js + VENDORED.mdx ARE in scope -> rc=1'
} else { Fail 'exclude-regex boundaries: root config.js + VENDORED.mdx ARE in scope -> rc=1' }

# Spaced path survives offending-path report intact
$r = New-PinnedRepo
Add-Content -LiteralPath (Join-Path $r "$HUD_REL/dist/my file.js") -Value 'tampered'
$rc = Invoke-Guard -RepoDir $r
if ($rc -eq 1 -and $script:LastGuardOutput -match 'dist/my file\.js') {
    Pass 'spaced path survives offending-path report intact'
} else { Fail 'spaced path survives offending-path report intact' }

if ($script:fails -eq 0) {
    'OK: all cases passed'
    exit 0
} else {
    "FAIL: $script:fails case(s) failed"
    exit 1
}
