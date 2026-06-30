<#
  Smoke test for the C4 (HIMMEL-438) PowerShell twins — setup.ps1's git-state
  bootstrap + vault-autosync.ps1. Proves the PS ports wire through on Windows;
  the exhaustive behaviour (gate matrix, secret-block) is covered by the bash
  twin test-vault-git.sh. SKIPs loud if pre-commit is unavailable (Precondition B).
  Run: pwsh scripts/test-vault-git.ps1
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$TR = (Resolve-Path (Join-Path $here '..')).Path
$failed = 0
function Assert([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "PASS $label" } else { Write-Host "FAIL $label $detail"; $script:failed++ }
}

if (-not (Get-Command pre-commit -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP all — pre-commit not on PATH (Precondition B)"; exit 0
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP all — git not on PATH"; exit 0
}

$env:USER_SLUG = 'luna-test'
$env:GIT_AUTHOR_NAME = 'luna-test'; $env:GIT_AUTHOR_EMAIL = 'lt@example.com'
$env:GIT_COMMITTER_NAME = 'luna-test'; $env:GIT_COMMITTER_EMAIL = 'lt@example.com'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("c4ps-" + [System.IO.Path]::GetRandomFileName())
$V = Join-Path $tmp 'vault'
New-Item -ItemType Directory -Force -Path $V | Out-Null
try {
    foreach ($f in @('.gitignore', '.gitattributes', '.pre-commit-config.yaml', '.gitleaks.toml', '.env.example', '.vault-template.json', 'README.md', '_CLAUDE.md', 'index.md', 'log.md', 'Welcome.md')) {
        Copy-Item (Join-Path $TR $f) (Join-Path $V $f)
    }
    Copy-Item -Recurse (Join-Path $TR 'scripts') (Join-Path $V 'scripts')
    foreach ($d in @('00-Inbox', '10-Projects', '20-Areas', '30-Resources', '40-Archive', '50-Journal', '60-Maps', '_Templates')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $V $d) | Out-Null
    }

    # --- setup.ps1 git-state bootstrap (non-repo -> init + commit + marker) ---
    # Invoke from inside the vault (the documented `cd vault; .\scripts\setup.ps1`)
    # so repo detection roots at the vault, not an enclosing repo. The git-state
    # step is [0/6]; assert its side effects regardless of whether the later
    # pre-commit-install step completes on this host.
    $env:HANDOVER_DIR = Join-Path $V 'handovers'
    Push-Location $V
    & pwsh -NoProfile -File (Join-Path $V 'scripts\setup.ps1') *> (Join-Path $tmp 'setup.log')
    Pop-Location
    git -C $V rev-parse HEAD *> $null
    Assert 'setup.ps1 bootstrap: HEAD exists' ($LASTEXITCODE -eq 0)
    Assert 'setup.ps1 bootstrap: .single-writer created' (Test-Path (Join-Path $V '.single-writer'))
    Assert 'setup.ps1 bootstrap: .single-writer excluded from git' (-not ((git -C $V ls-files) -match 'single-writer'))

    # Install hooks directly for the autosync cases (decoupled from setup.ps1's
    # pre-commit-install step, which depends on the host python having pip).
    Push-Location $V; pre-commit install *> $null; Pop-Location
    $hooksOk = Test-Path (Join-Path $V '.git\hooks\pre-commit')
    Assert 'pre-commit hooks installable' $hooksOk

    if (-not $hooksOk) {
        Write-Host "SKIP autosync cases — hooks absent (Precondition B)"
    } else {
        $autosync = Join-Path $V 'scripts\vault-autosync.ps1'
        Set-Content -NoNewline -Path (Join-Path $V '.env') -Value "TOKEN_VALUE=x`n"
        Set-Content -NoNewline -Path (Join-Path $V '00-Inbox\sync-note.md') -Value "autosync content`n"
        $base = (git -C $V rev-list --count HEAD).Trim()

        # OFF -> no commit.
        $env:LUNA_VAULT_AUTOSYNC = ''
        Push-Location $V; & pwsh -NoProfile -File $autosync *> $null; Pop-Location
        Assert 'autosync OFF: exit 0' ($LASTEXITCODE -eq 0)
        Assert 'autosync OFF: no new commit' (((git -C $V rev-list --count HEAD).Trim()) -eq $base)

        # ON + no remote -> no-op.
        $env:LUNA_VAULT_AUTOSYNC = '1'
        Push-Location $V; & pwsh -NoProfile -File $autosync *> $null; Pop-Location
        Assert 'autosync ON no-remote: exit 0 no-op' ($LASTEXITCODE -eq 0)
        Assert 'autosync ON no-remote: no new commit' (((git -C $V rev-list --count HEAD).Trim()) -eq $base)

        # ON + bare remote -> commit + push through pre-commit.
        $bare = Join-Path $tmp 'bare.git'
        git init --bare -b main $bare *> $null
        git -C $V remote add origin $bare
        Push-Location $V; & pwsh -NoProfile -File $autosync *> (Join-Path $tmp 'a3.log'); Pop-Location
        Assert 'autosync ON + bare remote: exit 0' ($LASTEXITCODE -eq 0)
        Assert 'autosync commit landed' (([int]((git -C $V rev-list --count HEAD).Trim())) -gt ([int]$base))
        $tree = git -C $V ls-tree -r HEAD --name-only
        Assert 'autosync: .env excluded from commit' (-not ($tree -match '^\.env$'))
        Assert 'autosync: .single-writer excluded from commit' (-not ($tree -match 'single-writer'))
        Assert 'autosync: sync-note committed' ([bool]($tree -match 'sync-note'))
        git -C $bare rev-parse --verify main *> $null
        Assert 'autosync: bare remote received main' ($LASTEXITCODE -eq 0)

        # Clone-with-remote (no marker, past unborn HEAD): autosync must recreate
        # .single-writer itself so its on-main commit clears worktree-isolation.
        Remove-Item -Force (Join-Path $V '.single-writer')
        $eBase = (git -C $V rev-list --count HEAD).Trim()
        Set-Content -NoNewline -Path (Join-Path $V '00-Inbox\clone-note.md') -Value "clone content`n"
        $env:LUNA_VAULT_AUTOSYNC = '1'
        Push-Location $V; & pwsh -NoProfile -File $autosync *> $null; Pop-Location
        Assert 'clone autosync: exit 0' ($LASTEXITCODE -eq 0)
        Assert 'clone autosync recreated .single-writer' (Test-Path (Join-Path $V '.single-writer'))
        Assert 'clone autosync commit landed past unborn HEAD' (([int]((git -C $V rev-list --count HEAD).Trim())) -gt ([int]$eBase))

        # Phase G (HIMMEL-501) — auto-fixer resilience.
        # A churny .md note (hard-break = 2 trailing spaces, no final newline):
        # pre-commit must NOT rewrite it, so the commit isn't aborted.
        $gBase = (git -C $V rev-list --count HEAD).Trim()
        $mdPath = Join-Path $V '00-Inbox\md-fixer.md'
        Set-Content -NoNewline -Path $mdPath -Value "first line  `nsecond line"
        $mdOrig = Get-Content -Raw $mdPath
        Push-Location $V; & pwsh -NoProfile -File $autosync *> $null; Pop-Location
        Assert 'G1 autosync with churny .md: exit 0 (not blocked)' ($LASTEXITCODE -eq 0)
        Assert 'G2 autosync commit landed' (([int]((git -C $V rev-list --count HEAD).Trim())) -gt ([int]$gBase))
        Assert 'G3 .md left UNMODIFIED by pre-commit' ((Get-Content -Raw $mdPath) -eq $mdOrig)

        # An allowlisted code/config file a fixer DOES rewrite still lands
        # (re-stage + retry). Vault notes/sources are off the fixer allowlist, so
        # a `.toml` is used to force a rewrite.
        $g2Base = (git -C $V rev-list --count HEAD).Trim()
        Set-Content -NoNewline -Path (Join-Path $V '00-Inbox\data.toml') -Value "key = ""value""   `n"
        Push-Location $V; & pwsh -NoProfile -File $autosync *> $null; Pop-Location
        Assert 'G4 autosync recovers from fixer-modified allowlisted file: exit 0' ($LASTEXITCODE -eq 0)
        Assert 'G5 retry committed after fixer ran' (([int]((git -C $V rev-list --count HEAD).Trim())) -gt ([int]$g2Base))
        Assert 'G6 data.toml landed in committed tree' ([bool]((git -C $V ls-tree -r HEAD --name-only) -match 'data\.toml'))
        Assert 'G7 fixer-retry result pushed to remote' (((git -C $bare rev-parse main).Trim()) -eq ((git -C $V rev-parse HEAD).Trim()))

        # The retry must NOT weaken the egress guard: an allowlisted file with
        # BOTH a fixer defect (trailing whitespace) AND a planted secret stays
        # blocked through the re-stage pass — nothing committed, nothing pushed.
        $g8Local = (git -C $V rev-parse HEAD).Trim()
        $g8Bare = (git -C $bare rev-parse main).Trim()
        $akp = 'AKIA'; $aks = '1234567890ABCDEF'
        Set-Content -Path (Join-Path $V '30-Resources\leak.toml') -Value "note = ""leaky data""   `naws_key = ""$akp$aks"""
        Push-Location $V; & pwsh -NoProfile -File $autosync *> $null; Pop-Location
        Assert 'G8 fixer-defect + secret (allowlisted): blocked through retry (non-zero)' ($LASTEXITCODE -ne 0)
        Assert 'G9 local HEAD unchanged (retry did not commit the secret)' (((git -C $V rev-parse HEAD).Trim()) -eq $g8Local)
        Assert 'G10 bare remote unchanged (nothing pushed)' (((git -C $bare rev-parse main).Trim()) -eq $g8Bare)

        # Phase H (HIMMEL-615) — a non-ASCII (Hebrew) source-note name must NOT
        # crash the trailing-whitespace fixer NOR get rewritten. This is the
        # native-Windows runner, where the cp1252 UnicodeEncodeError actually
        # fires (Linux only ever validates the "not rewritten" half). The name
        # is built from char code points so this source stays ASCII.
        Remove-Item -Force (Join-Path $V '30-Resources\leak.toml') # drop G8's uncommitted secret
        $hBase = (git -C $V rev-list --count HEAD).Trim()
        $heb = ([char]0x05EA + [char]0x05D9 + [char]0x05E7 + '.txt') # Hebrew "tik.txt"
        $hebPath = Join-Path $V (Join-Path '00-Inbox' $heb)
        Set-Content -NoNewline -Path $hebPath -Value "verbatim line with trailing space   `nsecond line`n"
        $hebOrig = Get-Content -Raw $hebPath
        Push-Location $V; & pwsh -NoProfile -File $autosync *> $null; Pop-Location
        Assert 'H1 autosync with a Hebrew-named .txt: exit 0 (no UnicodeEncodeError)' ($LASTEXITCODE -eq 0)
        Assert 'H2 autosync commit landed' (([int]((git -C $V rev-list --count HEAD).Trim())) -gt ([int]$hBase))
        Assert 'H3 Hebrew .txt left UNMODIFIED (no silent whitespace mangling)' ((Get-Content -Raw $hebPath) -eq $hebOrig)
        git -C $V ls-files --error-unmatch -- "00-Inbox/$heb" *> $null
        Assert 'H4 Hebrew .txt is tracked in the committed tree' ($LASTEXITCODE -eq 0)
    }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -eq 0) { Write-Host 'All vault-git C4 PowerShell smoke tests passed.' }
else { Write-Host "$failed test(s) failed."; exit 1 }
