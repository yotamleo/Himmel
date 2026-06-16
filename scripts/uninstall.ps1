# uninstall.ps1 — offboard the himmel operator surface (HIMMEL-227).
# PowerShell counterpart of uninstall.sh. Symmetric teardown of what
# setup.ps1 + install-plugins.ps1 onboard:
#
#   [1/5] stop the telegram bun bridge      (bun supervisor.ts --kill)
#   [2/5] remove telegram pairing + bridge state
#   [3/5] remove HIMMEL-Resume-* scheduled tasks + HimmelTelegramBridge
#   [4/5] uninstall Claude plugins + marketplaces (uninstall-plugins.ps1)
#   [5/5] uninstall git hooks (pre-commit/pre-push/commit-msg)
#
# Destructive. Fail-closed: without -Yes an interactive run prompts; a
# non-interactive run aborts (rc=2). -DryRun prints actions only.
#
# Usage:
#   pwsh -File scripts/uninstall.ps1 [-DryRun] [-Yes]
#        [-KeepTelegramState] [-SkipPlugins] [-SkipTasks] [-SkipHooks]
#
# Env overrides (tests): $env:TELEGRAM_CHANNEL_DIR, $env:BRIDGE_ROOT

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$KeepTelegramState,
    [switch]$SkipPlugins,
    [switch]$SkipTasks,
    [switch]$SkipHooks
)

$RepoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')

$ChannelDir = if ($env:TELEGRAM_CHANNEL_DIR) { $env:TELEGRAM_CHANNEL_DIR }
              else { Join-Path $HOME '.claude\channels\telegram' }
$BridgeRoot = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT }
              else { Join-Path $HOME '.claude\handover\bridge' }

# Locale-independent existence check for an exact scheduled-task name.
# Returns $true if the task exists, $false if absent. Throws only on
# schtasks.exe itself being unavailable (should never happen on Windows).
# Tests shadow this function to avoid real schtasks.exe calls.
function Test-ScheduledTaskExists {
    param([string]$TaskName)
    schtasks.exe /query /tn $TaskName *> $null
    return $LASTEXITCODE -eq 0
}

Write-Host "==> himmel uninstall (offboard)"
Write-Host ""
Write-Host "This will:"
Write-Host "  1. stop the telegram bun bridge (if running)"
if (-not $KeepTelegramState) {
    Write-Host "  2. REMOVE telegram pairing + bridge state:"
    Write-Host "       $ChannelDir   (bot-token .env + access.json)"
    Write-Host "       $BridgeRoot   (sessions, inbox/outbox, supervisor state)"
} else {
    Write-Host "  2. keep telegram state (-KeepTelegramState)"
}
if (-not $SkipTasks) {
    Write-Host "  3. remove HIMMEL-Resume-* scheduled tasks + HimmelTelegramBridge logon task"
} else {
    Write-Host "  3. keep scheduled tasks (-SkipTasks)"
}
if (-not $SkipPlugins) {
    Write-Host "  4. uninstall Claude plugins + marketplaces from settings-template"
    Write-Host "     (USER-SCOPE: affects every repo on this machine)"
} else {
    Write-Host "  4. keep Claude plugins (-SkipPlugins)"
}
if (-not $SkipHooks) {
    Write-Host "  5. uninstall this repo's git hooks (pre-commit/pre-push/commit-msg)"
} else {
    Write-Host "  5. keep git hooks (-SkipHooks)"
}
Write-Host ""

if ($DryRun) {
    Write-Host "(dry-run -- nothing will be executed)"
} elseif (-not $Yes) {
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $resp = Read-Host "Proceed? [y/N]"
        if ($resp -notmatch '^[yY]') { Write-Host "Aborted."; exit 2 }
    } else {
        Write-Host "ERROR: non-interactive run without -Yes -- aborting (fail-closed)." -ForegroundColor Red
        Write-Host "  Re-run with -Yes to confirm, or -DryRun to preview."
        exit 2
    }
}
Write-Host ""

# --- [1/5] stop the bridge ---------------------------------------------------
# $BridgeMaybeRunning gates step 2: removing state while a supervisor may
# still be live would be recreated by it, and its open handles make the
# Remove-Item fail partway on Windows.
$BridgeMaybeRunning = $false
Write-Host "[1/5] Stopping telegram bridge..."
$PidFile = Join-Path $BridgeRoot 'supervisor.pid'
if (-not (Test-Path $PidFile)) {
    Write-Host "  no supervisor.pid under $BridgeRoot -- bridge not running, skipping."
} elseif (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "  WARN: supervisor.pid exists but bun is not on PATH -- cannot stop the bridge." -ForegroundColor Yellow
    Write-Host "  Inspect: pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly" -ForegroundColor Yellow
    $BridgeMaybeRunning = $true
} else {
    $TelegramDir = Join-Path $RepoRoot 'scripts\telegram'
    if ($DryRun) {
        Write-Host "DRY: bun --cwd $TelegramDir supervisor.ts --kill   (BRIDGE_ROOT=$BridgeRoot)"
    } else {
        $savedBridgeRoot = $env:BRIDGE_ROOT
        try {
            $env:BRIDGE_ROOT = $BridgeRoot
            & bun --cwd $TelegramDir supervisor.ts --kill
            # rc: 0 = killed/already gone, 1 = pidfile absent, 2 = pidfile
            # unreadable/corrupt OR a signal failed (e.g. EPERM) -> bridge
            # MAY still be running (supervisor keeps the pidfile then).
            if ($LASTEXITCODE -ge 2) {
                Write-Host "  WARN: supervisor --kill rc=$LASTEXITCODE -- bridge may still be running; check manually." -ForegroundColor Yellow
                $BridgeMaybeRunning = $true
            }
        } finally {
            $env:BRIDGE_ROOT = $savedBridgeRoot
        }
    }
}
Write-Host ""

# --- [2/5] remove telegram pairing + bridge state ------------------------------
Write-Host "[2/5] Removing telegram pairing + bridge state..."
if ($KeepTelegramState) {
    Write-Host "  kept (-KeepTelegramState)."
} elseif ($BridgeMaybeRunning) {
    Write-Host "  SKIPPED: step 1 could not stop the bridge -- a running supervisor would" -ForegroundColor Yellow
    Write-Host "  recreate (or hold locks on) state under $BridgeRoot. Kill the bridge" -ForegroundColor Yellow
    Write-Host "  manually, then re-run uninstall." -ForegroundColor Yellow
} else {
    foreach ($dir in @($ChannelDir, $BridgeRoot)) {
        # Refuse obviously wrong paths (empty / root / $HOME itself).
        if ([string]::IsNullOrWhiteSpace($dir) -or
            $dir.TrimEnd('\','/') -eq $HOME.TrimEnd('\','/') -or
            $dir.TrimEnd('\','/').Length -le 3) {
            Write-Host "  WARN: refusing to remove suspicious path: '$dir'" -ForegroundColor Yellow
            continue
        }
        if (Test-Path $dir) {
            if ($DryRun) {
                Write-Host "DRY: Remove-Item -Recurse -Force $dir"
            } else {
                # A locked file (e.g. a live process holding handles) makes
                # Remove-Item fail partway with EAP=Continue -- catch the
                # error AND re-test existence so a partial delete is never
                # reported as success (token .env/access.json residue).
                $rmErr = $null
                try {
                    Remove-Item -Recurse -Force $dir -ErrorAction Stop
                } catch {
                    $rmErr = $_
                }
                # If the remove threw, always WARN — Test-Path can false-negative
                # on access-denied, so silently skipping the WARN would leave
                # residue without any operator notice.
                if ($rmErr -or (Test-Path $dir)) {
                    $detail = if ($rmErr) { " -- $rmErr" } else { '' }
                    Write-Host "  WARN: failed to remove $dir$detail" -ForegroundColor Yellow
                    Write-Host "  residue remains under $dir -- remove it manually." -ForegroundColor Yellow
                } else {
                    Write-Host "  removed: $dir"
                }
            }
        } else {
            Write-Host "  absent, skipping: $dir"
        }
    }
    Write-Host "  NOTE: deleting the local token does NOT revoke it -- if decommissioning"
    Write-Host "  the bot, revoke the token via @BotFather too."
}
Write-Host ""

# --- [3/5] remove scheduled tasks ----------------------------------------------
Write-Host "[3/5] Removing scheduled tasks (HIMMEL-Resume-*, HimmelTelegramBridge)..."
if ($SkipTasks) {
    Write-Host "  kept (-SkipTasks)."
} else {
    # One fail-loud enumeration: a single Get-ScheduledTask sweep returns the
    # full task list (empty match = genuinely nothing to do) but THROWS with
    # -ErrorAction Stop on CIM/service/access failure. The previous empty
    # `catch {}` + SilentlyContinue pair masked those failures as the
    # misleading "no matching scheduled tasks found."
    $taskNames = @()
    $queryFailed = $false
    # Use targeted queries rather than a full catalog sweep so a single corrupt
    # third-party task doesn't abort the entire step (Get-ScheduledTask with no
    # filter enumerates ALL tasks and throws on the first bad one).
    # Each pattern is independent — one pattern's failure must not block the
    # other's deletions.

    # Wildcard pattern: Get-ScheduledTask returns empty on no-match, only throws
    # on real CIM/service failure.
    try {
        $matched = @(Get-ScheduledTask -TaskName 'HIMMEL-Resume-*' -ErrorAction Stop |
                     Select-Object -ExpandProperty TaskName)
        $taskNames += $matched
    } catch {
        $queryFailed = $true
        Write-Host "  WARN: scheduled-task query failed for 'HIMMEL-Resume-*' -- $_" -ForegroundColor Yellow
        Write-Host "  HIMMEL-Resume-* / HimmelTelegramBridge tasks may remain." -ForegroundColor Yellow
    }

    # Exact-name pattern: Get-ScheduledTask throws when the task is absent
    # (exception type and message vary by PS/Windows version and locale).
    # Pre-check existence via schtasks.exe rc (locale-independent native binary);
    # only call Get-ScheduledTask when the pre-check confirms presence.
    # If the pre-check says present but Get-ScheduledTask then throws, that is a
    # real failure — set $queryFailed and WARN.
    if (Test-ScheduledTaskExists 'HimmelTelegramBridge') {
        try {
            $matched = @(Get-ScheduledTask -TaskName 'HimmelTelegramBridge' -ErrorAction Stop |
                         Select-Object -ExpandProperty TaskName)
            $taskNames += $matched
        } catch {
            $queryFailed = $true
            Write-Host "  WARN: scheduled-task query failed for 'HimmelTelegramBridge' -- $_" -ForegroundColor Yellow
            Write-Host "  HIMMEL-Resume-* / HimmelTelegramBridge tasks may remain." -ForegroundColor Yellow
        }
    }
    # rc != 0 from the pre-check → task simply absent → silently skip, do NOT touch $queryFailed.
    if (-not $queryFailed) {
        if ($taskNames.Count -eq 0) {
            Write-Host "  no matching scheduled tasks found."
        } else {
            foreach ($task in $taskNames) {
                if ($DryRun) {
                    Write-Host "DRY: Unregister-ScheduledTask -TaskName $task -Confirm:`$false"
                } else {
                    try {
                        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
                        Write-Host "  deleted scheduled task: $task"
                    } catch {
                        Write-Host "  WARN: failed to delete scheduled task: $task -- $_" -ForegroundColor Yellow
                    }
                }
            }
        }
    }
}
Write-Host ""

# --- [4/5] uninstall plugins + marketplaces -------------------------------------
Write-Host "[4/5] Uninstalling Claude plugins + marketplaces..."
if ($SkipPlugins) {
    Write-Host "  kept (-SkipPlugins)."
} elseif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "  claude CLI not on PATH -- skipping (nothing to uninstall through)."
} else {
    $plugArgs = @()
    if ($DryRun) { $plugArgs += '-DryRun' }
    & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\machine-setup\uninstall-plugins.ps1') @plugArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARN: uninstall-plugins.ps1 reported failures -- re-run it directly to inspect." -ForegroundColor Yellow
    }
}
Write-Host ""

# --- [5/5] uninstall git hooks ----------------------------------------------------
# Mirror of setup.ps1 step 2 (which installs via python -m pre_commit).
Write-Host "[5/5] Uninstalling git hooks (this repo)..."
if ($SkipHooks) {
    Write-Host "  kept (-SkipHooks)."
} elseif (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "  python not on PATH -- skipping."
} else {
    Push-Location $RepoRoot
    try {
        foreach ($hookType in @($null, 'pre-push', 'commit-msg')) {
            $cmd = @('python', '-m', 'pre_commit', 'uninstall')
            if ($hookType) { $cmd += @('--hook-type', $hookType) }
            if ($DryRun) {
                Write-Host "DRY: $($cmd -join ' ')"
            } else {
                & $cmd[0] @($cmd | Select-Object -Skip 1)
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  WARN: '$($cmd -join ' ')' failed (rc=$LASTEXITCODE)." -ForegroundColor Yellow
                }
            }
        }
    } finally {
        Pop-Location
    }
}
Write-Host ""

Write-Host "Uninstall complete."
Write-Host ""
Write-Host "NOT touched (by design):"
Write-Host "  - ~/.claude/settings.json (hooks/MCP config -- prune manually if wanted)"
Write-Host "  - the himmel clone itself, .env, and worktrees"
Write-Host "  - ~/.claude/handover/registry.json + handover state outside the bridge root"
