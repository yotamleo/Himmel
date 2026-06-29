# salus medical-vault overlay (PowerShell twin of lib/salus-overlay.sh).
# Dot-source then call: Invoke-SalusOverlay -RepoRoot <path>
#   - code/config assets (.claude/skills/medic, egress hook, settings.json) →
#     always (re)installed; settings.json only if absent.
#   - _-root scaffolds (_skin-photo-archive.md, _derm-visit-prep.template.md,
#     _media/skin/) → scaffold-new ONLY; never overwrites operator content.
#   - appends the medical posture block to _CLAUDE.md once (idempotent via the
#     ASCII 'salus-posture-block' marker).
#   - drops the .salus-profile marker (upgrade gates on it).
# Returns $true on success, $false if the overlay dir is missing.
function Invoke-SalusOverlay {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $ov = Join-Path $RepoRoot '_profiles/salus'
    if (-not (Test-Path $ov)) {
        Write-Host "salus-overlay: overlay not found at $ov" -ForegroundColor Red
        return $false
    }
    $today = Get-Date -Format 'yyyy-MM-dd'
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot '.claude/skills') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot '.claude/hooks') | Out-Null
    Copy-Item -Recurse -Force (Join-Path $ov '.claude/skills/medic') (Join-Path $RepoRoot '.claude/skills/')
    Copy-Item -Force (Join-Path $ov '.claude/hooks/block-cloud-egress.sh') (Join-Path $RepoRoot '.claude/hooks/')
    $settings = Join-Path $RepoRoot '.claude/settings.json'
    if (-not (Test-Path $settings)) {
        Copy-Item -Force (Join-Path $ov '.claude/settings.json') $settings
    } else {
        Write-Host "salus-overlay: .claude/settings.json exists -- not overwritten; ensure it wires PreToolUse .* -> bash `$CLAUDE_PROJECT_DIR/.claude/hooks/block-cloud-egress.sh" -ForegroundColor Yellow
    }
    foreach ($f in @('_skin-photo-archive.md', '_derm-visit-prep.template.md')) {
        $dest = Join-Path $RepoRoot $f
        if (-not (Test-Path $dest)) {
            ((Get-Content -Raw (Join-Path $ov $f)) -replace '<scaffold-date>', $today) |
                Set-Content -NoNewline -Encoding utf8 $dest
        }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot '_media/skin') | Out-Null
    $gk = Join-Path $RepoRoot '_media/skin/.gitkeep'
    if (-not (Test-Path $gk)) { Copy-Item -Force (Join-Path $ov '_media/skin/.gitkeep') $gk }
    $claudeMd = Join-Path $RepoRoot '_CLAUDE.md'
    if ((Test-Path $claudeMd) -and -not (Select-String -Path $claudeMd -Pattern 'salus-posture-block' -SimpleMatch -Quiet)) {
        Add-Content -Path $claudeMd -Value ''
        Get-Content -Raw (Join-Path $ov '_CLAUDE.salus.md') | Add-Content -Path $claudeMd
    }
    Set-Content -Path (Join-Path $RepoRoot '.salus-profile') -Encoding utf8 `
        -Value 'salus medical-vault profile - managed by setup --medical / upgrade'
    return $true
}
