# New-machine setup for the himmel repo.
# Run once after cloning: .\scripts\setup.ps1 [-WithCs] [-WithJira]
#
# -WithCs   : install claude-squad (cs) at the end of setup. Without the
#             switch, interactive shells prompt; non-interactive shells skip.
#             See docs/setup/claude-squad.md.
# -WithJira : require Jira configuration — abort if JIRA_PROJECT_KEY is
#             unset. Without the switch the check downgrades to a skip
#             notice (HIMMEL-285).
# -FillEnv  : after creating .env, interactively prompt for each must-set value
#             (Enter to skip). Non-interactive shells no-op. Shells out to the
#             bash fill-env.sh (Git Bash verified in [0/10]). (HIMMEL-453)

[CmdletBinding()]
param(
    [switch]$WithCs,
    [switch]$WithJira,
    [switch]$FillEnv
)

# $RepoRoot is resolved AFTER the [0/10] preflight (R6, HIMMEL-460): the preflight
# may auto-install git, so `git rev-parse` must not run before it.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Surface Ctrl-C / pipeline failures rather than letting the script
# continue past a broken step. Mirrors `trap ... INT TERM` in setup.sh.
$ErrorActionPreference = 'Stop'
trap { Write-Host "setup interrupted: $_" -ForegroundColor Red; exit 1 }

Write-Host "==> himmel setup"
Write-Host ""

# --- prereq verify (HIMMEL-123) ---
# Fail fast with install hints. PowerShell setup runs only the
# PS-friendly path (pre-commit + jira plugin); operator-facing tooling
# expects Git Bash for the bash-driven scripts. We still verify the
# foundational tools so the operator knows what's missing.
Write-Host "[0/10] Verifying foundational tools on PATH..."
$missing = @()
$hints = @{
    'git'     = 'https://git-scm.com (includes Git Bash on Windows)'
    'node'    = 'https://nodejs.org (need v18+; nvm-windows or fnm also works)'
    'npm'     = 'bundled with node 18+; if missing, reinstall node'
    'bun'     = 'irm bun.sh/install.ps1 | iex (runs handover armed-resume, qmd search, the Telegram bridge, obsidian-triage tools)'
    'python'  = 'https://python.org (3.10+); used by this PS setup + bash fallbacks'
    'jq'      = 'choco install jq | scoop install jq | winget install jqlang.jq'
    'gh'      = 'https://cli.github.com (GitHub CLI v2.x)'
    'bash'    = 'Install Git for Windows (Git Bash) — most operator scripts need bash'
}
foreach ($tool in @('git', 'node', 'npm', 'bun', 'python', 'jq', 'gh', 'bash')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $missing += $tool
    }
}

# R6 (HIMMEL-460): best-effort FETCH of the auto-installable missing tools
# (git/jq/python) via winget -> scoop -> choco BEFORE failing. The rest keep the
# flag-loud fallback below. Mirrors setup.sh's ensure-tools step.
if ($missing.Count -gt 0) {
    $wingetIds = @{ 'git' = 'Git.Git'; 'jq' = 'jqlang.jq'; 'python' = 'Python.Python.3.12' }
    $installer = $null
    if (Get-Command winget -ErrorAction SilentlyContinue) { $installer = 'winget' }
    elseif (Get-Command scoop -ErrorAction SilentlyContinue) { $installer = 'scoop' }
    elseif (Get-Command choco -ErrorAction SilentlyContinue) { $installer = 'choco' }
    if ($installer) {
        Write-Host "  Missing: $($missing -join ', ') — attempting auto-install via $installer..."
        foreach ($tool in $missing) {
            if (-not $wingetIds.ContainsKey($tool)) {
                Write-Host "    no known $installer package for '$tool' — install it manually." -ForegroundColor Yellow
                continue
            }
            try {
                switch ($installer) {
                    'winget' { winget install --id $wingetIds[$tool] --silent --accept-source-agreements --accept-package-agreements | Out-Null }
                    'scoop'  { scoop install $tool | Out-Null }
                    'choco'  { choco install $tool -y | Out-Null }
                }
            } catch {
                Write-Host "    $installer install '$tool' failed — install it manually." -ForegroundColor Yellow
            }
        }
        $missing = @($missing | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    } else {
        Write-Host "  No supported installer (winget/scoop/choco) found — cannot auto-install." -ForegroundColor Yellow
    }
}

if ($missing.Count -gt 0) {
    Write-Error "missing required tools: $($missing -join ', ')"
    Write-Host "  Install hints (see docs/setup/new-machine.md for full per-platform table):" -ForegroundColor Yellow
    foreach ($tool in $missing) {
        Write-Host "    $($tool.PadRight(10)) — $($hints[$tool])" -ForegroundColor Yellow
    }
    exit 1
}
Write-Host "  All foundational tools present."
Write-Host ""

# --- repo root (relocated past the preflight — R6, HIMMEL-460) ---
# git is now guaranteed present; safe to resolve the checkout root.
$RepoRoot = git rev-parse --show-toplevel
Set-Location $RepoRoot

# --- Claude Code CLI (the runtime himmel harnesses) — soft check ---
# Soft, not hard-fail: setup configures the repo and never invokes claude, so a
# missing claude must not break repo-tooling setup. But himmel IS a Claude Code
# harness — you need claude to USE it — so warn loudly with an install hint.
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "  NOTE: 'claude' (Claude Code CLI) not found - himmel is a Claude Code harness;" -ForegroundColor Yellow
    Write-Host "        you need it to use himmel. Install: irm https://claude.ai/install.ps1 | iex" -ForegroundColor Yellow
    Write-Host ""
}

# --- JIRA_PROJECT_KEY verify (HIMMEL-146; gated per HIMMEL-285) ---
# Mirrors scripts/setup/check-jira-key.sh: hard-fail only with -WithJira.
Write-Host "[0.4/10] Verifying JIRA_PROJECT_KEY..."
if ($env:JIRA_PROJECT_KEY) {
    Write-Host "  JIRA_PROJECT_KEY=$($env:JIRA_PROJECT_KEY)"
} elseif ($WithJira) {
    Write-Host "ERROR: JIRA_PROJECT_KEY is not set." -ForegroundColor Red
    Write-Host "  -WithJira requires JIRA_PROJECT_KEY (e.g. ACME, HIMMEL)." -ForegroundColor Yellow
    Write-Host "  Fix: add JIRA_PROJECT_KEY=<your-key> to .env (see .env.example)" -ForegroundColor Yellow
    Write-Host "  or set it in the shell, then re-run: .\scripts\setup.ps1 -WithJira" -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "  Skipped: JIRA_PROJECT_KEY not set (Jira is optional without -WithJira)."
    Write-Host "  Set JIRA_* in .env and re-run with -WithJira to enable."
}
Write-Host ""

# --- Python / pre-commit ---
Write-Host "[1/10] Installing pre-commit..."
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Error "python not found. Install Python 3.10+ first."
    exit 1
}
python -m pip install pre-commit --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Error "pip install pre-commit failed (exit $LASTEXITCODE)."
    exit 1
}

Write-Host "[2/10] Installing git hooks (pre-commit, pre-push, commit-msg)..."
python -m pre_commit install
python -m pre_commit install --hook-type pre-push
python -m pre_commit install --hook-type commit-msg

Write-Host "[3/10] Installing Jira CLI..."
if (Get-Command node -ErrorAction SilentlyContinue) {
    if ((Test-Path "$RepoRoot\scripts\jira\node_modules") -and (Test-Path "$RepoRoot\scripts\jira\dist\index.js")) {
        Write-Host "  jira CLI already built (node_modules + dist present) -- skipping install + build"
        Write-Host "  (force rebuild: Remove-Item -Recurse -Force scripts\jira\node_modules,scripts\jira\dist; .\scripts\setup.ps1)"
    } else {
        Push-Location "$RepoRoot\scripts\jira"
        npm install --silent
        npm run build --silent
        npm link
        Pop-Location
        Write-Host "  jira CLI installed. Run: jira --help"
    }
} else {
    Write-Host "  node not found -- skipping Jira CLI. Install Node 18+ then run:"
    Write-Host "  cd scripts\jira; npm install; npm run build; npm link"
}

# --- qmd collection ---
# Mirror of scripts/lib/qmd-bin.sh (bash) — pwsh cannot source bash, so
# resolver logic is duplicated. UPDATE BOTH when changing resolution
# rules; scripts/lib/test-qmd-bin.sh is the canonical behavior spec.
#
# Honors $env:BUN_INSTALL for relocated bun roots, matching the bash lib.
$QmdBunRoot = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $HOME '.bun' }
$QmdBunJs = Join-Path $QmdBunRoot 'install\global\node_modules\@tobilu\qmd\dist\cli\qmd.js'
$QmdInstallHint = 'bun add -g @tobilu/qmd@latest --ignore-scripts'

function Invoke-Qmd {
    param([Parameter(ValueFromRemainingArguments=$true)] [string[]] $QmdArgs)
    if ((Test-Path $script:QmdBunJs) -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        & bun $script:QmdBunJs @QmdArgs
    } elseif (Get-Command qmd -ErrorAction SilentlyContinue) {
        & qmd @QmdArgs
    } else {
        $global:LASTEXITCODE = 127
    }
}

# Presence check ONLY — does not invoke the binary, so real runtime
# errors reach the caller instead of being masked as "qmd not installed".
function Test-Qmd {
    if ((Test-Path $script:QmdBunJs) -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        return $true
    }
    return [bool](Get-Command qmd -ErrorAction SilentlyContinue)
}

Write-Host "[4/10] Registering qmd collection 'himmel'..."
# Neutralize the broken qmd plugin-cache stub first so plain `qmd` works
# inside Claude's Bash tool too (HIMMEL-163). The fixer is bash; Git Bash is
# a verified prereq ([0/10]) so it is always present here. Native exe non-zero
# exits do NOT throw in pwsh -- check $LASTEXITCODE explicitly.
& bash "$RepoRoot/scripts/lib/fix-qmd-stub.sh"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: fix-qmd-stub failed (rc=$LASTEXITCODE) -- continuing."
}
if (Test-Qmd) {
    # Merge stderr into success stream (pwsh's `2>&1`) so the captured payload
    # contains qmd's actual error message on `list` failure, matching the
    # bash side. Without this, bun/qmd stderr would print to host but never
    # land in $listOut, and the WARNING would have no detail to indent.
    $listOut = Invoke-Qmd collection list 2>&1
    $listRc = $LASTEXITCODE
    if ($listRc -ne 0) {
        Write-Host "  WARNING: qmd collection list failed (rc=$listRc) -- skipping registration."
        $listOut | ForEach-Object { Write-Host "    $_" }
    } elseif ($listOut -match '^himmel\b') {
        Write-Host "  Collection 'himmel' already registered -- skipping."
    } else {
        # Native exe non-zero exits do NOT throw in pwsh — check $LASTEXITCODE
        # explicitly. try/catch here would be dead code for the actual failure mode.
        Invoke-Qmd collection add $RepoRoot --name himmel
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: qmd collection add failed (rc=$LASTEXITCODE) -- continuing."
        }
    }
} else {
    Write-Host "  qmd not available -- skipping. Install: $QmdInstallHint"
}

# --- .env ---
Write-Host "[5/10] Checking .env..."
if (-not (Test-Path ".env")) {
    if (Test-Path ".env.example") {
        Copy-Item ".env.example" ".env"
        Write-Host "  Created .env from .env.example -- fill in JIRA_API_TOKEN before running: jira list"
    } else {
        Write-Host "  No .env.example found -- skipping"
    }
} else {
    Write-Host "  .env already exists -- skipping"
}
# -FillEnv (HIMMEL-453): prompt for the must-set values via the bash fill-env.sh
# (one implementation). Default-off; non-interactive shells no-op inside
# fill-env.sh. Resolve GIT Bash explicitly -- a bare `bash` on Windows often
# resolves to the System32 WSL stub, which cannot read C:/... paths.
if ($FillEnv -and (Test-Path ".env")) {
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if (-not (Test-Path $gitBash)) {
        $bc = Get-Command bash -ErrorAction SilentlyContinue
        $gitBash = if ($bc -and $bc.Source -notmatch 'System32') { $bc.Source } else { $null }
    }
    if (-not $gitBash) {
        Write-Host "  -FillEnv skipped: Git Bash not found (edit .env by hand)." -ForegroundColor Yellow
    } else {
        $fe   = (Join-Path $RepoRoot "scripts/setup/fill-env.sh").Replace('\', '/')
        $envF = (Join-Path $RepoRoot ".env").Replace('\', '/')
        $exF  = (Join-Path $RepoRoot ".env.example").Replace('\', '/')
        $savedEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $gitBash $fe $envF $exF
            if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: fill-env failed; continuing." -ForegroundColor Yellow }
        } finally {
            $ErrorActionPreference = $savedEAP
        }
    }
} elseif (Test-Path ".env") {
    Write-Host "  (re-run with -FillEnv to be prompted for .env values)"
}

# --- handover root ---
# Reports where Claude will read/write handover state (per HIMMEL-118
# resolver). Bash-only -- shells out to scripts/handover-link.sh via
# Git for Windows bash. Skipped with a note if bash is unavailable.
#
# Use `doctor` (not `status`) so misconfig exits non-zero and we take
# the WARNING branch -- `status` always rc=0 even when HANDOVER_DIR is
# unresolvable.
#
# Use Write-Host (not Write-Warning) so the WARNING output is NOT
# suppressed by `$WarningPreference = 'SilentlyContinue'`, which is
# common in CI / scripted contexts. The misconfig branch is the whole
# point of step 6 -- if it can be silenced by a caller's preference,
# the gate has no teeth.
Write-Host "[6/10] Handover root check..."
$GitBash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $GitBash)) {
    $BashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($BashCmd) {
        $GitBash = $BashCmd.Source
    }
}
if (Test-Path $GitBash) {
    # Pass the script as an argument (bash <script> <args>) rather than
    # via `-c "bash '$script' doctor"` -- the latter spawns a redundant
    # nested bash process AND is fragile if $RepoRoot ever contains a
    # single quote. bash handles a script-path positional arg fine and
    # doesn't need the file to have execute bits (Windows NTFS lacks
    # them anyway).
    $HandoverScript = (Join-Path $RepoRoot "scripts\handover-link.sh").Replace('\', '/')
    # EAP-relax + try/finally (HIMMEL-150 back-port from luna-brain).
    # Under $ErrorActionPreference='Stop' (set at the top of this script),
    # bash stderr captured via 2>&1 surfaces as a terminating PS ErrorRecord
    # and trips the trap. Relax EAP for the bash invocation only; wrap in
    # try/finally so the restore runs even on a thrown error.
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $HandoverOutput = & $GitBash $HandoverScript doctor 2>&1 | ForEach-Object { "$_" }
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    if ($LASTEXITCODE -eq 0) {
        $HandoverOutput | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  WARNING: handover-link doctor reported misconfiguration:" -ForegroundColor Yellow
        $HandoverOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        Write-Host "  Fix by either unsetting `$env:HANDOVER_DIR (falls back to <repo>\handovers)" -ForegroundColor Yellow
        Write-Host "  or pointing it at an existing directory before launching Claude Code." -ForegroundColor Yellow
        Write-Host "  Setup continues -- re-run handover-link doctor at any time to verify." -ForegroundColor Yellow
    }
} else {
    Write-Host "  bash not found -- skipping handover-link check."
    Write-Host "  Install Git for Windows so scripts/handover-link.sh can run."
}

Write-Host ""

# --- telegram onboarding (HIMMEL-227) ---
# Scaffold-only: creates the channel dir + bot-token .env template, reports
# pairing/bridge status, prints the operator next-steps. It NEVER writes
# access.json and NEVER starts the bridge (operator-managed -- injection
# surface + single-getUpdates-owner rule). Non-fatal: a fresh machine
# legitimately has none of this configured yet.
Write-Host "[7/10] Telegram bridge onboarding..."
$savedEAP = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts\setup\onboard-telegram.ps1")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: onboard-telegram reported a problem; setup continues." -ForegroundColor Yellow
    }
} finally {
    $ErrorActionPreference = $savedEAP
}
Write-Host ""

# --- Claude plugins (HIMMEL-359) ---
# The standalone-himmel path (this script) is what README + getting-started
# point new users at, then tell them to run /handover — so it installs the
# marketplace plugins (handover, triage, obsidian, …), not just the repo
# tooling. User scope (~/.claude); setup.ps1 has no scope/profile flag.
# Idempotent. Skipped with a notice when claude is not on PATH.
Write-Host "[8/10] Installing Claude plugins (user scope)..."
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts\machine-setup\install-plugins.ps1") `
            -Scope user -HimmelPath $RepoRoot
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: install-plugins reported a problem; setup continues." -ForegroundColor Yellow
        }
    } finally {
        $ErrorActionPreference = $savedEAP
    }
} else {
    Write-Host "  Skipped: 'claude' not on PATH (install it, then re-run setup)."
}
Write-Host ""

# --- statusline + HIMMEL_REPO (HIMMEL-359 / HIMMEL-453) ---
# Wire the himmel statusline AND env.HIMMEL_REPO into ~/.claude/settings.json via
# the shared helpers. Both write settings.json, need no claude binary, idempotent.
Write-Host "[9/10] Wiring statusline + HIMMEL_REPO + UNIVERSAL hooks (user scope)..."
$settingsJson = Join-Path $HOME ".claude\settings.json"
$savedEAP = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts\lib\wire-statusline.ps1") `
        -SettingsPath $settingsJson -HimmelPath $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: wire-statusline failed; setup continues." -ForegroundColor Yellow
    }
    & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts\lib\wire-himmel-repo.ps1") `
        -SettingsPath $settingsJson -HimmelPath $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: wire-himmel-repo failed; setup continues." -ForegroundColor Yellow
    }
    # R3 (HIMMEL-460): wire the UNIVERSAL hooks (PreToolUse trio + SessionStart
    # inject-initiative) at USER scope so a session launched anywhere gets them.
    . (Join-Path $RepoRoot "scripts\lib\wire-pretooluse-hooks.ps1")
    try { Set-PretooluseHooks -SettingsPath $settingsJson -Prefix $RepoRoot } catch { Write-Host "  WARNING: wire-pretooluse-hooks failed; setup continues." -ForegroundColor Yellow }
    try { Set-SessionStartHook -SettingsPath $settingsJson -Prefix $RepoRoot -HookBasename 'inject-initiative.sh' } catch { Write-Host "  WARNING: wire SessionStart inject-initiative failed; setup continues." -ForegroundColor Yellow }
    # R4 (HIMMEL-460): advise on user/project hook duplication (silent in-repo).
    & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts\lib\detect-hook-dup.ps1") `
        -UserSettings $settingsJson -ProjectSettings (Join-Path $RepoRoot ".claude\settings.json") -HimmelRoot $RepoRoot
} finally {
    $ErrorActionPreference = $savedEAP
}
Write-Host ""

# --- claude-squad (cs) -- OPTIONAL (HIMMEL-151) ---
# Opt-in only. Triggered by -WithCs OR interactive prompt (default N).
# Non-interactive shells without the switch skip silently.
#
# Failure here is non-fatal: cs is optional. WARN and continue.
Write-Host "[10/10] OPTIONAL: claude-squad (cs)..."
$installCs = $false
if ($WithCs) {
    $installCs = $true
} elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $resp = Read-Host "  Install claude-squad (cs) now? [y/N]"
    if ($resp -match '^[yY]') { $installCs = $true }
} else {
    Write-Host "  Skipped (non-interactive, no -WithCs switch)."
}

if ($installCs) {
    # $tmp is created partway through (Step 3) and must be cleaned up in the
    # finally regardless of where failure occurred. Initialize to $null so the
    # finally guard is safe when winget/gh fails before $tmp is ever set.
    $tmp = $null
    try {
        # Step 1: psmux (native Windows tmux clone). Idempotent winget call.
        if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                throw "winget not found. Install 'App Installer' from the Microsoft Store, or install psmux manually per docs\setup\claude-squad.md."
            }
            Write-Host "  Installing psmux via winget..."
            winget install --id marlocarlo.psmux --silent --accept-source-agreements --accept-package-agreements
            # winget returns non-zero for benign cases (already-installed,
            # no-applicable-update). Re-check Get-Command after the call
            # instead of trusting the exit code alone.
            if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) {
                throw "winget install psmux failed (exit $LASTEXITCODE) and psmux still not on PATH."
            }
        } else {
            Write-Host "  psmux already installed -- skipping."
        }

        # Step 2: cs.exe from upstream releases (maintainer-signed).
        # Fork mirror exists for source audit but has no published releases yet.
        if (Get-Command cs -ErrorAction SilentlyContinue) {
            Write-Host "  cs already on PATH at $((Get-Command cs).Source) -- skipping."
        } else {
            # Capture stderr too so failure messages are visible in the catch.
            # Redirecting to $null hides gh auth / rate-limit / network errors
            # and forces the operator to re-run interactively to diagnose.
            $ghOutput = gh api repos/smtg-ai/claude-squad/releases/latest --jq .tag_name 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "gh api failed (exit $LASTEXITCODE): $ghOutput. Try 'gh auth status' to verify auth."
            }
            $tag = ($ghOutput | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($tag)) {
                throw "gh api returned empty tag for smtg-ai/claude-squad/releases/latest. Run 'gh api repos/smtg-ai/claude-squad/releases/latest' to debug."
            }
            $ver = $tag.TrimStart('v')
            $asset = "claude-squad_${ver}_windows_amd64.zip"
            $url = "https://github.com/smtg-ai/claude-squad/releases/download/v${ver}/${asset}"

            # Step 3: download the asset. Wrapped so a network/404 failure
            # names THIS step (not the generic last-exception message). $tmp is
            # set here; the finally block owns its cleanup from now on.
            $tmp = Join-Path $env:TEMP "cs-install-$(Get-Random)"
            New-Item -ItemType Directory -Force $tmp | Out-Null
            $zip = Join-Path $tmp "cs.zip"
            Write-Host "  Downloading $asset ..."
            try {
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            } catch {
                Write-Host "  Step 3 (download) failed for $url." -ForegroundColor Yellow
                throw
            }

            # Step 4: size sanity check. The asset is ~5MB; anything under
            # 100KB is almost certainly an HTML error page (404 / rate-limit),
            # not the binary. Catch it here with a clear message instead of
            # letting Expand-Archive fail with a cryptic zip error.
            $zipSize = (Get-Item $zip).Length
            if ($zipSize -lt 100KB) {
                throw "downloaded cs.zip is only $zipSize bytes (< 100KB) -- likely an HTML error page from $url, not the binary. Check the release exists and gh auth is valid."
            }

            # Step 5: extract.
            try {
                Expand-Archive -Force -Path $zip -DestinationPath $tmp
            } catch {
                Write-Host "  Step 5 (extract) failed for $zip." -ForegroundColor Yellow
                throw
            }

            # Step 6: place cs.exe.
            $binDir = Join-Path $HOME ".local\bin"
            New-Item -ItemType Directory -Force $binDir | Out-Null
            try {
                Move-Item -Force (Join-Path $tmp "claude-squad.exe") (Join-Path $binDir "cs.exe")
            } catch {
                Write-Host "  Step 6 (place cs.exe) failed for $binDir." -ForegroundColor Yellow
                throw
            }

            # Step 7: add to User PATH if not present. Git Bash inherits this so
            # no .bashrc edit is needed.
            try {
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($userPath -notlike "*$binDir*") {
                    [Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
                    Write-Host "  Added $binDir to User PATH (new shells only)."
                }
            } catch {
                Write-Host "  Step 7 (update User PATH) failed for $binDir." -ForegroundColor Yellow
                throw
            }
            $env:Path = "$env:Path;$binDir"

            # Step 8: version probe.
            try {
                & (Join-Path $binDir "cs.exe") version | ForEach-Object { Write-Host "  $_" }
            } catch {
                Write-Host "  Step 8 (cs.exe version probe) failed." -ForegroundColor Yellow
                throw
            }
        }
    } catch {
        Write-Host "  WARNING: claude-squad install failed: $_" -ForegroundColor Yellow
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor Yellow
        Write-Host "  See docs\setup\claude-squad.md for manual install." -ForegroundColor Yellow
    } finally {
        # Always remove the temp dir, even on failure mid-download/extract.
        # Guarded: $tmp is $null if we failed before it was set (winget/gh).
        if ($tmp -and (Test-Path $tmp)) {
            Remove-Item -Recurse -Force $tmp
        }
    }
} else {
    if (-not $WithCs -and [Environment]::UserInteractive) {
        Write-Host "  Skipped. See docs\setup\claude-squad.md to install later."
    }
}
Write-Host ""

Write-Host "Setup complete."
Write-Host ""
Write-Host "NEXT: read docs/getting-started.md (clone-to-first-loop in ~15 min),"
Write-Host "      then start your first loop with /worktree."
Write-Host ""
Write-Host "Quick checks:"
Write-Host "  - python -m pre_commit run --all-files   # all hooks green"
Write-Host "  - qmd status                             # qmd index registered"
if ($WithJira -or $env:JIRA_PROJECT_KEY) {
    Write-Host "  - Edit .env (set JIRA_API_TOKEN), then: jira list"
} else {
    Write-Host "  - Jira is optional: set JIRA_* in .env when ready, then: jira list"
}
Write-Host ""
Write-Host "Everything beyond the core is opt-in (Jira, luna vault, Telegram, hermes) -"
Write-Host "the harness runs without any of them. You stay in control: every guard has an"
Write-Host "off-switch (see docs/getting-started.md and docs/internals/enforcement.md)."
Write-Host ""
Write-Host "Handover state: Mode A (default) lives in <repo>\handovers\, tracked in git."
Write-Host "  Mode B: `$env:HANDOVER_DIR = 'C:\path\to\external\handovers' in the launching"
Write-Host "  shell to keep it in a separate repo. The resolver fails closed on a bad path."
