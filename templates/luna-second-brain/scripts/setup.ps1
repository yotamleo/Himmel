# New-machine setup for the luna-brain repo (Windows PowerShell).
# Run once after cloning: .\scripts\setup.ps1

$RepoRoot = git rev-parse --show-toplevel
Set-Location $RepoRoot

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

Write-Host ""
Write-Host "Setup complete."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. (optional) Edit .env to override USER_SLUG / HANDOVER_DIR defaults."
Write-Host "  2. Install the SHA-pinned plugin marketplace from inside Claude Code:"
Write-Host ""
Write-Host "       claude plugin marketplace add $RepoRoot\marketplace"
Write-Host "       claude plugin install claude-obsidian@luna-brain"
Write-Host "       claude plugin install obsidian@luna-brain"
Write-Host ""
Write-Host "  3. (optional) Install obsidian-second-brain for PARA capture/daily/project skills."
Write-Host "     This is a 3rd-party install.sh (review before piping to bash):"
Write-Host "       https://github.com/eugeniughelbur/obsidian-second-brain#install"
Write-Host ""
Write-Host "  4. python -m pre_commit run --all-files   # verify all hooks green"
Write-Host ""
Write-Host "Open the vault folder in Obsidian to start using it."
