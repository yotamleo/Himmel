# New-machine setup for the luna-brain repo (Windows PowerShell).
# Run once after cloning: .\scripts\setup.ps1 [-Medical]
#   -Medical: also apply the salus medical-vault overlay (medic skill +
#   PHI-egress floor + skin scaffolds). Lockstep with setup.sh --medical.
param([switch]$Medical)

# --- [0/6] git state ---
# Lockstep with setup.sh: a non-repo download is initialized + scaffold-committed;
# a local vault with no remote gets a .single-writer marker; a clone/remote is
# left as-is. Set $RepoRoot ourselves so a non-repo `git rev-parse` can't blank it.
$RepoRoot = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $RepoRoot) {
    $RepoRoot = "$RepoRoot".Trim()
    Set-Location $RepoRoot
    if ([string]::IsNullOrWhiteSpace(((git remote) -join ''))) {
        if (-not (Test-Path (Join-Path $RepoRoot '.single-writer'))) {
            New-Item -ItemType File -Path (Join-Path $RepoRoot '.single-writer') | Out-Null
            Write-Host "[0/6] Local-only vault: created .single-writer (commits/pushes go to main by design)."
        }
    }
} else {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Set-Location $RepoRoot
    git init -b main 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { git init 2>$null | Out-Null; git symbolic-ref HEAD refs/heads/main }
    # Path-scoped initial commit — NEVER `git add -A`. The protection is the
    # explicit allow-list (an untracked secret is never in the loop), NOT index
    # ordering; .gitignore is staged first only so the first tracked state
    # carries the ignore rules.
    git add .gitignore 2>$null
    foreach ($p in @('.env.example', '.gitattributes', '.pre-commit-config.yaml', '.vault-template.json', 'README.md', '_CLAUDE.md', 'index.md', 'log.md', 'scripts', 'marketplace', 'docs', '_Templates', '00-Inbox', '10-Projects', '20-Areas', '30-Resources', '40-Archive', '50-Journal', '60-Maps')) {
        if (Test-Path (Join-Path $RepoRoot $p)) { git add $p 2>$null }
    }
    New-Item -ItemType File -Path (Join-Path $RepoRoot '.single-writer') -Force | Out-Null
    # Report honestly — on a fresh machine git identity may be unset, aborting the
    # commit. Don't claim "committed" when HEAD is unborn.
    git commit -q -m "chore: initial luna-brain scaffold" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[0/6] Initialized git repo (main) + committed scaffold; created .single-writer marker."
    } else {
        Write-Host "[0/6] Initialized git repo (main) + created .single-writer, but the scaffold commit did NOT land (git identity unset, or a hook blocked it). Set a git identity and run 'git add -A; git commit -m \"initial scaffold\"' before enabling autosync." -ForegroundColor Yellow
    }
}

$ErrorActionPreference = 'Stop'
trap { Write-Host "setup interrupted: $_" -ForegroundColor Red; exit 1 }

Write-Host "==> luna-brain setup"
Write-Host ""

# --- [1/6] foundational tools ---
Write-Host "[1/6] Verifying foundational tools on PATH..."
$missing = @()
$hints = @{
    'git'    = 'https://git-scm.com (includes Git Bash on Windows)'
    'python' = 'https://python.org (3.10+); used for pre-commit'
    'bash'   = 'Install Git for Windows (Git Bash) -- vault scripts run under bash'
}
foreach ($tool in @('git', 'python', 'bash')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $missing += $tool
    }
}
if ($missing.Count -gt 0) {
    Write-Host "ERROR: missing required tools: $($missing -join ', ')" -ForegroundColor Red
    foreach ($tool in $missing) {
        Write-Host "    $($tool.PadRight(8)) -- $($hints[$tool])" -ForegroundColor Yellow
    }
    exit 1
}
Write-Host "  All foundational tools present."
Write-Host ""

# --- [2/6] USER_SLUG resolution ---
# Shells out to bash + scripts/lib/user-slug.sh so the resolver lives in
# one source of truth (sourced by the bash setup path too). Mirrors the
# pattern himmel's setup.ps1 uses for handover-link.sh.
Write-Host "[2/6] Resolving USER_SLUG..."
$GitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $GitBash)) {
    $BashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($BashCmd) { $GitBash = $BashCmd.Source }
}
if (-not (Test-Path $GitBash)) {
    Write-Host "ERROR: bash not found -- required for USER_SLUG resolution. Install Git for Windows." -ForegroundColor Red
    exit 1
}
$UserSlugScript = (Join-Path $RepoRoot 'scripts\lib\_print-user-slug.sh').Replace('\', '/')
# Run helper bash script directly so PS does not have to deal with
# quoting '&&' / '$()' / escaped quotes inside `bash -c "..."`. The
# helper sources user-slug.sh + prints the slug. EAP relaxed for the
# bash invocation so its stderr diagnostic does not surface as a PS
# ErrorRecord under $ErrorActionPreference='Stop'.
$savedEAP = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $ResolvedSlug = & $GitBash $UserSlugScript 2>&1 | ForEach-Object { "$_" }
} finally {
    $ErrorActionPreference = $savedEAP
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: USER_SLUG resolution failed:" -ForegroundColor Red
    $ResolvedSlug | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    exit 1
}
$env:USER_SLUG = ($ResolvedSlug | Select-Object -Last 1).ToString().Trim()
$ResolvedSlug | ForEach-Object { Write-Host "  $_" }
Write-Host ""

# --- [3/6] pre-commit install ---
Write-Host "[3/6] Installing pre-commit..."
python -m pip install pre-commit --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: pip install pre-commit failed (exit $LASTEXITCODE)." -ForegroundColor Red
    exit 1
}

Write-Host "[4/6] Installing git hooks (pre-commit, pre-push, commit-msg)..."
python -m pre_commit install
python -m pre_commit install --hook-type pre-push
python -m pre_commit install --hook-type commit-msg

# --- [5/6] env-template ---
Write-Host "[5/6] Checking .env..."
if (-not (Test-Path ".env")) {
    if (Test-Path ".env.example") {
        Copy-Item ".env.example" ".env"
        Write-Host "  Created .env from .env.example -- edit if you want to override defaults."
    } else {
        Write-Host "  No .env.example found -- skipping"
    }
} else {
    Write-Host "  .env already exists -- skipping"
}

# --- [6/6] handover root + vault sanity ---
Write-Host "[6/6] Handover root + vault sanity..."
$HandoverScript = (Join-Path $RepoRoot 'scripts\lib\_print-handover-root.sh').Replace('\', '/')
# Run helper bash script directly. Same rationale as USER_SLUG step.
$savedEAP = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $HandoverOutput = & $GitBash $HandoverScript 2>&1 | ForEach-Object { "$_" }
} finally {
    $ErrorActionPreference = $savedEAP
}
if ($LASTEXITCODE -eq 0) {
    $HandoverOutput | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "  WARNING: handover root unresolvable (HANDOVER_DIR set to a missing path?):" -ForegroundColor Yellow
    $HandoverOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Host "  Unset HANDOVER_DIR or point it at an existing directory." -ForegroundColor Yellow
}

$missingDirs = @()
foreach ($d in @('00-Inbox', '10-Projects', '20-Areas', '30-Resources', '40-Archive', '50-Journal', '60-Maps', '_Templates')) {
    if (-not (Test-Path "$RepoRoot\$d")) {
        $missingDirs += $d
    }
}
if ($missingDirs.Count -gt 0) {
    Write-Host "  WARNING: vault PARA dirs missing: $($missingDirs -join ', ')" -ForegroundColor Yellow
    Write-Host "  Re-clone or re-create the scaffold before using vault commands." -ForegroundColor Yellow
} else {
    Write-Host "  Vault PARA dirs present."
}

# --- [7/7] salus medical overlay (optional, -Medical) ---
if ($Medical) {
    Write-Host "[7/7] Applying salus medical-vault overlay..."
    . (Join-Path $RepoRoot 'scripts/lib/Salus-Overlay.ps1')
    if (Invoke-SalusOverlay -RepoRoot $RepoRoot) {
        Write-Host "  salus overlay applied (medic skill + egress floor + skin scaffolds + .salus-profile)."
    } else {
        Write-Host "  ERROR: salus overlay not found -- is this the luna template?" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Setup complete."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. (optional) Edit .env to override USER_SLUG / HANDOVER_DIR defaults."
Write-Host "  2. Install the Obsidian markdown skill pack from inside Claude Code:"
Write-Host ""
Write-Host "       claude plugin marketplace add kepano/obsidian-skills"
Write-Host "       claude plugin install obsidian@obsidian-skills"
Write-Host ""
Write-Host "     (obsidian is Steph Ango's skill pack, from its own upstream marketplace.)"
Write-Host "     (claude-obsidian now ships via the himmel marketplace — install himmel to get it.)"
Write-Host ""
Write-Host "  3. (optional) Install obsidian-second-brain for PARA capture/daily/project skills."
Write-Host "     This is a 3rd-party install.sh (review before piping to bash):"
Write-Host "       https://github.com/eugeniughelbur/obsidian-second-brain#install"
Write-Host ""
Write-Host "  4. python -m pre_commit run --all-files   # verify all hooks green"
Write-Host ""
Write-Host "Session capture (end-session-wiki):"
Write-Host "  Claude Code can auto-capture each session into THIS vault. Configure it"
Write-Host "  in each CODE repo whose sessions you want captured here -- easiest via:"
Write-Host ""
Write-Host "       /end-session-wiki-setup        # run from the code repo; writes the config"
Write-Host ""
Write-Host "  Target precedence (first match wins): per-repo vault_path (abs path) >"
Write-Host "  per-repo vault NAME (distributable; ~/.claude/luna-vaults.json or the"
Write-Host "  ~/Documents/<name> convention) > LUNA_VAULT_PATH env > default ~/Documents/luna."
Write-Host "  This vault's name for BY-NAME routing: $(Split-Path -Leaf $RepoRoot)"
Write-Host "  Full guide: docs/luna/end-session-wiki.md"
Write-Host ""
Write-Host "Open the vault folder in Obsidian to start using it."
