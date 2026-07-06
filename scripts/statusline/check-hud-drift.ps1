# hud-drift: fail when the vendored claude-hud tree diverges from its recorded
# pin (HIMMEL-718 Task 1.2). himmel-contributor-only (gated by .himmel-dev).
#
# Windows PowerShell twin of check-hud-drift.sh — keep both in lockstep.
# Default: verify; -Write: recompute and record (pin bump / first vendor).
# rc: 0 pass | 1 drift | 2 cannot-evaluate (fail-closed).
param([switch]$Write)

$HUD_REL  = 'marketplace/plugins/claude-hud'
# himmel-owned paths under $HUD_REL, excluded from the drift hash (keep in
# sync with VENDORED.md "himmel-owned files" + the .sh twin's OWNED_RE).
# Right-anchored file alternatives; matched case-SENSITIVELY (-cnotmatch)
# to keep byte parity with the .sh twin's grep -vE.
$OWNED_RE = '^(VENDORED\.md$|VENDORED\.manifest$|\.gitignore$|config/)'

$top = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $top) {
    Write-Error "-> hud-drift: cannot resolve repo root -- fail-closed"
    exit 2
}
if (-not (Test-Path -LiteralPath (Join-Path $top '.himmel-dev'))) {
    # Not a contributor checkout -> no-op.
    exit 0
}
if ($env:HUD_DRIFT_OK -eq '1') {
    Write-Host "-> hud-drift: HUD_DRIFT_OK=1 -- skipping (verify the vendored tree manually)" -ForegroundColor Yellow
    exit 0
}

$hudDir     = Join-Path $top $HUD_REL
$vendoredMd = Join-Path $hudDir 'VENDORED.md'
$manifest   = Join-Path $hudDir 'VENDORED.manifest'
if (-not (Test-Path -LiteralPath $hudDir)) {
    Write-Error "-> hud-drift: $HUD_REL missing in a .himmel-dev checkout -- fail-closed"; exit 2
}
if (-not (Test-Path -LiteralPath $vendoredMd)) {
    Write-Error "-> hud-drift: $HUD_REL/VENDORED.md missing -- fail-closed"; exit 2
}

# Enumerate upstream-derived files: tracked (incl. staged-new) under $HUD_REL,
# minus himmel-owned. Paths relative to $HUD_REL, LC_ALL=C-style ordinal sort
# (must match the .sh twin's manifest ordering byte-for-byte).
$files = & git -C $top ls-files -- $HUD_REL 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "-> hud-drift: git ls-files failed -- fail-closed"; exit 2 }
$rel = @($files | Where-Object { $_ } |
    ForEach-Object { $_ -replace "^$([regex]::Escape($HUD_REL))/", '' } |
    Where-Object { $_ -cnotmatch $OWNED_RE })
# Ordinal sort (matches the .sh twin's LC_ALL=C sort byte-for-byte).
$relList = [System.Collections.Generic.List[string]]::new()
foreach ($f in $rel) { $relList.Add($f) }
$relList.Sort([System.StringComparer]::Ordinal)
if ($relList.Count -eq 0) {
    Write-Error "-> hud-drift: no upstream-derived files tracked under $HUD_REL -- fail-closed"; exit 2
}

$missing  = @()
$sb = [System.Text.StringBuilder]::new()
foreach ($f in $relList) {
    $abs = Join-Path $hudDir $f
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) {
        $missing += $f
        continue
    }
    $h = & git -C $top hash-object -- "$HUD_REL/$f" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $h) {
        Write-Error "-> hud-drift: hash-object failed on $f -- fail-closed"; exit 2
    }
    [void]$sb.Append("$h  $f`n")
}
$computed = $sb.ToString()

$sha = [System.Security.Cryptography.SHA256]::Create()
$agg = ([System.BitConverter]::ToString(
    $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($computed))
) -replace '-', '').ToLowerInvariant()

if ($Write) {
    if ($missing.Count -gt 0) {
        Write-Host "hud-drift: refusing -Write, tracked vendored files missing on disk:" -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "     MISSING  $_" -ForegroundColor Red }
        exit 1
    }
    # -replace on a missing line is a silent no-op — require the line up front
    # so -Write cannot claim success without recording the pin.
    $md = Get-Content -LiteralPath $vendoredMd -Raw
    if ($md -notmatch '(?m)^vendored_tree_hash:') {
        Write-Error "-> hud-drift: VENDORED.md has no vendored_tree_hash: line to record into -- fail-closed"; exit 2
    }
    # Guarded writes: a .NET IO exception must fail-closed as rc=2 with the
    # twin's own diagnostic, not abort as rc=1 with a raw stack trace.
    try {
        [System.IO.File]::WriteAllText($manifest, $computed)
    } catch {
        Write-Error "-> hud-drift: manifest write failed -- fail-closed"; exit 2
    }
    # [^\r\n]* (not .*$) so a CRLF file keeps its \r on the rewritten line.
    $md = $md -replace '(?m)^vendored_tree_hash:[^\r\n]*', "vendored_tree_hash:   $agg  # sha256 over VENDORED.manifest"
    try {
        [System.IO.File]::WriteAllText($vendoredMd, $md)
    } catch {
        Write-Error "-> hud-drift: VENDORED.md write failed -- fail-closed"; exit 2
    }
    if ((Get-Content -LiteralPath $vendoredMd -Raw) -notmatch [regex]::Escape("vendored_tree_hash:   $agg")) {
        Write-Error "-> hud-drift: pin not recorded after rewrite -- fail-closed"; exit 2
    }
    Write-Host "-> hud-drift: recorded vendored_tree_hash=$agg (+ $($relList.Count - $missing.Count) files in VENDORED.manifest)"
    Write-Host "  Commit $HUD_REL/VENDORED.md + $HUD_REL/VENDORED.manifest with the pin bump."
    exit 0
}

$recorded = $null
foreach ($line in (Get-Content -LiteralPath $vendoredMd)) {
    if ($line -match '^vendored_tree_hash:\s*(\S+)') { $recorded = $Matches[1]; break }
}
if (-not $recorded) {
    Write-Error "-> hud-drift: no vendored_tree_hash line in VENDORED.md -- fail-closed"; exit 2
}
if ($recorded -notmatch '^[0-9a-f]{64}$') {
    Write-Host "hud-drift: vendored_tree_hash is unset ($recorded)." -ForegroundColor Red
    Write-Host "   Record the pin:  pwsh scripts/statusline/check-hud-drift.ps1 -Write" -ForegroundColor Red
    exit 1
}

if ($agg -eq $recorded -and $missing.Count -eq 0) { exit 0 }

Write-Host "hud-drift: vendored claude-hud tree diverges from the recorded pin." -ForegroundColor Red
$missing | ForEach-Object { Write-Host "     MISSING  $_" -ForegroundColor Red }
if (Test-Path -LiteralPath $manifest) {
    Write-Host "   offending paths (vs VENDORED.manifest):" -ForegroundColor Red
    $oldLines = @(Get-Content -LiteralPath $manifest | Where-Object { $_ })
    $newLines = @($computed -split "`n" | Where-Object { $_ })
    $oldSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$oldLines)
    $newSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$newLines)
    $offending = @{}
    foreach ($l in $oldLines) { if (-not $newSet.Contains($l)) { $offending[($l -split '  ', 2)[1]] = $true } }
    foreach ($l in $newLines) { if (-not $oldSet.Contains($l)) { $offending[($l -split '  ', 2)[1]] = $true } }
    $offending.Keys | Sort-Object | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
} else {
    Write-Host "   (VENDORED.manifest missing -- cannot list offending paths)" -ForegroundColor Red
}
Write-Host @"
   If this is an INTENTIONAL pin bump / re-vendor:
     pwsh scripts/statusline/check-hud-drift.ps1 -Write   # then commit VENDORED.md + VENDORED.manifest
   Otherwise restore the file(s) to the pinned content (see VENDORED.md).
   Bypass (rare):  HUD_DRIFT_OK=1 git commit ...  (per-session env, not a prefix).
"@ -ForegroundColor Red
exit 1
