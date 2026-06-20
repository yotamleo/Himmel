<#
  vault-autosync.ps1 — OPT-IN auto-commit + push for a luna-brain vault.
  Lockstep with vault-autosync.sh.

  OFF by default. A vault's content IS the product, so when enabled this stages
  everything (`git add -A`) and commits THROUGH pre-commit — NEVER --no-verify —
  so the vault's gitleaks + secret hooks BLOCK any commit containing an API key
  BEFORE it can be committed or pushed. .gitignore (.env, .single-writer, …) is
  the second layer. Push targets the configured remote only.

  Enable explicitly (never defaulted on):
    $env:LUNA_VAULT_AUTOSYNC = '1'; pwsh -File scripts\vault-autosync.ps1

  Behaviour:
    OFF             → no commit, no push, no network.
    ON  + no remote → logged no-op.
    ON  + remote    → git add -A; commit (through pre-commit); push.
#>
function Log($m) { Write-Host "[vault-autosync] $m" }

# --- flag gate (default OFF) ---
$flag = ("$($env:LUNA_VAULT_AUTOSYNC)").Trim().ToLower()
if ($flag -notin @('1', 'true', 'on', 'yes')) {
    Log "LUNA_VAULT_AUTOSYNC is off — no commit, no push, no network. (set LUNA_VAULT_AUTOSYNC=1 to enable)"
    exit 0
}

$RepoRoot = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $RepoRoot) {
    Log "not inside a git repo — nothing to sync."
    exit 0
}
Set-Location "$RepoRoot".Trim()

# ON requires a remote — autosync's whole job is to push.
if ([string]::IsNullOrWhiteSpace(((git remote) -join ''))) {
    Log "enabled but no remote is configured — nothing to push (no-op)."
    exit 0
}

if ([string]::IsNullOrWhiteSpace(((git status --porcelain) -join ''))) {
    Log "working tree clean — nothing to commit."
    exit 0
}

# The commit lands on `main` (a vault is single-writer by design); the
# worktree-isolation guard requires the .single-writer marker. Enabling
# LUNA_VAULT_AUTOSYNC is the operator's explicit opt-in, so ensure the marker
# exists — a clone WITH a remote won't have one (setup leaves clones as-is),
# and without it this commit would be hard-blocked.
$marker = Join-Path $RepoRoot '.single-writer'
if (-not (Test-Path $marker)) {
    New-Item -ItemType File -Path $marker | Out-Null
    Log "created .single-writer (autosync commits to main; the flag is your opt-in)."
}

# Stage the whole vault — its content is the product.
git add -A
if ($LASTEXITCODE -ne 0) {
    Log "git add -A failed — NOT committing or pushing."
    exit 1
}

# Commit THROUGH pre-commit (NEVER --no-verify): the gitleaks/secret hooks are
# the egress guard. A blocked commit exits non-zero, and the push below is gated
# on this success, so nothing leaves.
git commit -q -m "chore: vault autosync"
if ($LASTEXITCODE -ne 0) {
    # Distinguish a benign "nothing left to commit" (a pre-commit auto-fixer may
    # have re-cleaned the tree) from a real block — a gitleaks/secret rejection
    # or a hook that modified files leaves the tree dirty.
    if ([string]::IsNullOrWhiteSpace(((git status --porcelain) -join ''))) {
        Log "nothing to commit after hooks ran — no-op."
        exit 0
    }
    Log "commit BLOCKED by pre-commit (secret detected, or a hook modified files) — NOT pushing."
    exit 1
}
Log "committed."

$remote = (git remote | Select-Object -First 1)
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
git push $remote $branch
if ($LASTEXITCODE -ne 0) {
    Log "push to $remote/$branch failed."
    exit 1
}
Log "pushed to $remote/$branch."
