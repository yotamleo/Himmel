# uninstall.ps1 — offboard the himmel operator surface (HIMMEL-227).
# PowerShell counterpart of uninstall.sh. Symmetric teardown of what
# setup.ps1 + install-plugins.ps1 onboard:
#
#   [1/7] stop the telegram bun bridge      (bun supervisor.ts --kill)
#   [2/7] remove telegram pairing + bridge state
#   [3/7] remove HIMMEL-Resume-* scheduled tasks + HimmelTelegramBridge
#   [4/7] uninstall Claude plugins + marketplaces (uninstall-plugins.ps1)
#   [5/7] uninstall git hooks (pre-commit/pre-push/commit-msg)
#   [6/7] unwire ~/.claude/settings.json (statusLine, env.HIMMEL_REPO,
#         env.LUNA_VAULT_PATH, env.HANDOVER_DIR, the UNIVERSAL hooks — what
#         setup.ps1/adopt wired)
#   [7/7] remove the himmelctl cache + state dir ~/.claude/himmel
#         (install-profile.json, state.json — HIMMEL-2459)
#
# Destructive. Fail-closed: without -Yes an interactive run prompts; a
# non-interactive run aborts (rc=2). -DryRun prints actions only.
#
# A step that HAD to run and could not — its tool is unresolvable — is named
# with where it was searched, and the run exits 2 WITHOUT printing "Uninstall
# complete." (HIMMEL-2458). The PATH-layer cause behind that ticket is
# Linux-only (a non-login shell missing ~/.local/bin), but the failure it
# produced is not: on any platform a missing `claude` or `python` used to leave
# every plugin installed and every git hook firing while the run reported
# success at rc=0. The resolver here is the Windows analogue — PATH first, then
# the locations setup.ps1 / the installers write into.
#
# Usage:
#   pwsh -File scripts/uninstall.ps1 [-DryRun] [-Yes]
#        [-KeepTelegramState] [-SkipPlugins] [-SkipTasks] [-SkipHooks]
#        [-SkipSettings]
#
# Env overrides (tests): $env:TELEGRAM_CHANNEL_DIR, $env:BRIDGE_ROOT,
# $env:HIMMEL_USER_SETTINGS, $env:HIMMELCTL_CACHE_DIR

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$KeepTelegramState,
    [switch]$SkipPlugins,
    [switch]$SkipTasks,
    [switch]$SkipHooks,
    [switch]$SkipSettings
)

$RepoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')

$ChannelDir = if ($env:TELEGRAM_CHANNEL_DIR) { $env:TELEGRAM_CHANNEL_DIR }
              else { Join-Path $HOME '.claude\channels\telegram' }
$BridgeRoot = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT }
              else { Join-Path $HOME '.claude\handover\bridge' }
# Test override so the [6/7] settings-unwire targets a temp file, not the real one.
$UserSettings = if ($env:HIMMEL_USER_SETTINGS) { $env:HIMMEL_USER_SETTINGS }
                else { Join-Path $HOME '.claude\settings.json' }
# Same override himmelctl reads (scripts/himmelctl/bin.js) — the [7/7] target.
$HimmelCacheDir = if ($env:HIMMELCTL_CACHE_DIR) { $env:HIMMELCTL_CACHE_DIR }
                  else { Join-Path $HOME '.claude\himmel' }

# Steps that HAD to run and could not. Non-empty => rc=2 and no completion
# claim (HIMMEL-2458).
$StepsIncomplete = [System.Collections.Generic.List[string]]::new()

# Resolve-Tool <name> — full path to the tool, or $null. PATH first, then the
# places the installers write into. Windows has no login/non-login PATH split,
# but a tool installed into a user directory that the invoking process's PATH
# snapshot predates is the same blind spot.
function Resolve-Tool {
    param([string]$Name)
    foreach ($cand in (Get-ToolCandidates $Name)) {
        if ([string]::IsNullOrWhiteSpace($cand)) { continue }
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    }
    return $null
}

# Get-ToolCandidates <name> — every place Resolve-Tool looks, in order. Printed
# verbatim when the tool is absent, so "where did it look?" is answerable from
# the failure message alone.
function Get-ToolCandidates {
    param([string]$Name)
    $out = [System.Collections.Generic.List[string]]::new()
    $onPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($onPath -and $onPath.Source) { $out.Add($onPath.Source) }
    $candidateDirs = [System.Collections.Generic.List[string]]::new()
    $candidateDirs.Add((Join-Path $HOME '.local\bin'))
    $candidateDirs.Add((Join-Path $HOME '.bun\bin'))
    $candidateDirs.Add((Join-Path $HOME '.claude\local'))
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $candidateDirs.Add((Join-Path $env:APPDATA 'npm'))
    }
    foreach ($dir in $candidateDirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        foreach ($ext in @('.cmd', '.exe', '.bat', '')) {
            $out.Add((Join-Path $dir "$Name$ext"))
        }
    }
    return $out
}

# Add-IncompleteStep <step> <tool> — record the gap and say where we looked.
function Add-IncompleteStep {
    param([string]$Step, [string]$Tool)
    Write-Host "  ERROR: '$Tool' not found -- this step did NOT run." -ForegroundColor Red
    Write-Host "  looked in: $((Get-ToolCandidates $Tool) -join ' ')" -ForegroundColor Red
    $StepsIncomplete.Add("$Step`: '$Tool' not found")
}

# Locale-independent existence check for an exact scheduled-task name.
# Returns $true if the task exists, $false if absent. Throws only on
# schtasks.exe itself being unavailable (should never happen on Windows).
# Tests shadow this function to avoid real schtasks.exe calls.
# Obviously wrong Remove-Item target (empty / a root / $HOME itself)?
# $true = refuse. CANONICALIZE BOTH SIDES FIRST: a plain string compare passes
# `$HOME\.`, `$HOME\..\<user>` and `$HOME/` — all of which resolve TO $HOME and
# would take the operator's home directory with them. GetFullPath normalizes
# without requiring the path to exist. An unresolvable path is treated as
# suspicious (fail-closed) rather than removed.
function Test-SuspiciousRemovePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    # Raw-spelling check BEFORE normalisation: GetFullPath('C:') resolves a
    # bare drive letter to the drive-RELATIVE CURRENT DIRECTORY, not the
    # drive root, so the root-comparison below would miss it entirely.
    if ($Path -match '^[A-Za-z]:[\\/]?$') { return $true }
    # A wildcard is not a path: -Path on Remove-Item/Test-Path expands it, and
    # 'C:\*' passes every root/home comparison below. Refuse the characters
    # PowerShell treats as wildcards outright — the target is env-configurable.
    if ($Path -match '[\*\?\[\]]') { return $true }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
        $homeFull = [System.IO.Path]::GetFullPath($HOME).TrimEnd('\','/')
    } catch {
        return $true
    }
    # Refuse anything that IS its own path root. This covers `C:\` and `D:\`
    # (which the old `Length -le 3` heuristic caught) AND a UNC share root like
    # `\\server\share`, which it did not — that one is long, is not $HOME, and
    # would have been recursively deleted.
    $root = ''
    try { $root = [System.IO.Path]::GetPathRoot($full) } catch { return $true }
    if ([string]::IsNullOrWhiteSpace($root)) { return $true }
    if ($full -eq $root.TrimEnd('\','/')) { return $true }
    return ($full -eq $homeFull)
}

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
if (-not $SkipSettings) {
    Write-Host "  6. unwire ~/.claude/settings.json (statusLine, HIMMEL_REPO,"
    Write-Host "     LUNA_VAULT_PATH, HANDOVER_DIR, UNIVERSAL hooks -- non-himmel keys untouched)"
} else {
    Write-Host "  6. keep ~/.claude/settings.json wiring (-SkipSettings)"
}
Write-Host "  7. REMOVE the himmelctl cache + state: $HimmelCacheDir"
Write-Host "     (install-profile.json, state.json -- a re-install would otherwise"
Write-Host "     start from the previous install's profile)"
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

# --- [1/7] stop the bridge ---------------------------------------------------
# $BridgeMaybeRunning gates step 2: removing state while a supervisor may
# still be live would be recreated by it, and its open handles make the
# Remove-Item fail partway on Windows.
$BridgeMaybeRunning = $false
Write-Host "[1/7] Stopping telegram bridge..."
$PidFile = Join-Path $BridgeRoot 'supervisor.pid'
if (-not (Test-Path -LiteralPath $PidFile)) {
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

# --- [2/7] remove telegram pairing + bridge state ------------------------------
Write-Host "[2/7] Removing telegram pairing + bridge state..."
if ($KeepTelegramState) {
    Write-Host "  kept (-KeepTelegramState)."
} elseif ($BridgeMaybeRunning) {
    Write-Host "  SKIPPED: step 1 could not stop the bridge -- a running supervisor would" -ForegroundColor Yellow
    Write-Host "  recreate (or hold locks on) state under $BridgeRoot. Kill the bridge" -ForegroundColor Yellow
    Write-Host "  manually, then re-run uninstall." -ForegroundColor Yellow
} else {
    foreach ($dir in @($ChannelDir, $BridgeRoot)) {
        # Refuse obviously wrong paths (empty / root / $HOME itself).
        if (Test-SuspiciousRemovePath $dir) {
            Write-Host "  WARN: refusing to remove suspicious path: '$dir'" -ForegroundColor Yellow
            continue
        }
        if (Test-Path -LiteralPath $dir) {
            if ($DryRun) {
                Write-Host "DRY: Remove-Item -Recurse -Force -LiteralPath $dir"
            } else {
                # A locked file (e.g. a live process holding handles) makes
                # Remove-Item fail partway with EAP=Continue -- catch the
                # error AND re-test existence so a partial delete is never
                # reported as success (token .env/access.json residue).
                $rmErr = $null
                try {
                    Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction Stop
                } catch {
                    $rmErr = $_
                }
                # If the remove threw, always WARN — Test-Path can false-negative
                # on access-denied, so silently skipping the WARN would leave
                # residue without any operator notice.
                if ($rmErr -or (Test-Path -LiteralPath $dir)) {
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

# --- [3/7] remove scheduled tasks ----------------------------------------------
Write-Host "[3/7] Removing scheduled tasks (HIMMEL-Resume-*, HimmelTelegramBridge)..."
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

# --- [4/7] uninstall plugins + marketplaces -------------------------------------
Write-Host "[4/7] Uninstalling Claude plugins + marketplaces..."
$ClaudeBin = if ($SkipPlugins) { $null } else { Resolve-Tool 'claude' }
if ($SkipPlugins) {
    Write-Host "  kept (-SkipPlugins)."
} elseif (-not $ClaudeBin) {
    Add-IncompleteStep '[4/7] Claude plugins + marketplaces' 'claude'
} else {
    Write-Host "  using: $ClaudeBin"
    $plugArgs = @()
    if ($DryRun) { $plugArgs += '-DryRun' }
    # uninstall-plugins.ps1 resolves `claude` itself, so the resolved directory
    # has to be on the CHILD's PATH — passing the path alone leaves the child
    # just as blind as this script was.
    $savedPath = $env:PATH
    try {
        $env:PATH = "$(Split-Path -Parent $ClaudeBin);$env:PATH"
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\machine-setup\uninstall-plugins.ps1') @plugArgs
    } finally {
        $env:PATH = $savedPath
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARN: uninstall-plugins.ps1 reported failures -- re-run it directly to inspect." -ForegroundColor Yellow
    }
}
Write-Host ""

# --- [5/7] uninstall git hooks ----------------------------------------------------
# Mirror of setup.ps1 step 2 (which installs via python -m pre_commit).
Write-Host "[5/7] Uninstalling git hooks (this repo)..."
$PythonBin = if ($SkipHooks) { $null } else { Resolve-Tool 'python' }
if ($SkipHooks) {
    Write-Host "  kept (-SkipHooks)."
} elseif (-not $PythonBin) {
    Add-IncompleteStep '[5/7] git hooks' 'python'
} else {
    Write-Host "  using: $PythonBin"
    Push-Location $RepoRoot
    try {
        foreach ($hookType in @($null, 'pre-push', 'commit-msg')) {
            $cmd = @($PythonBin, '-m', 'pre_commit', 'uninstall')
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

# --- [6/7] unwire user-scope settings.json (HIMMEL-460) ----------------------
# Symmetric inverse of setup.ps1 [9/10] + adopt -Scope user: remove the
# statusLine, env.HIMMEL_REPO, env.LUNA_VAULT_PATH, env.HANDOVER_DIR
# (HIMMEL-839), and the UNIVERSAL hooks. Each helper removes ONLY its own
# key/stanza (refuses invalid JSON, preserves every non-himmel key). The
# single-key helpers have no dry-run flag, so -DryRun is gated here;
# unwire-pretooluse-hooks has its own switch.
Write-Host "[6/7] Unwiring ~/.claude/settings.json (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, HANDOVER_DIR, hooks)..."
if ($SkipSettings) {
    Write-Host "  kept (-SkipSettings)."
} elseif (-not (Test-Path -LiteralPath $UserSettings)) {
    Write-Host "  no $UserSettings -- nothing to unwire."
} elseif ($DryRun) {
    Write-Host "DRY: unwire statusLine (himmel), env.HIMMEL_REPO, env.LUNA_VAULT_PATH, env.HANDOVER_DIR from $UserSettings"
    & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\lib\unwire-pretooluse-hooks.ps1') -SettingsPath $UserSettings -DryRun
} else {
    foreach ($u in @('unwire-statusline', 'unwire-himmel-repo', 'unwire-luna-vault', 'unwire-handover-dir')) {
        & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts\lib\$u.ps1") -SettingsPath $UserSettings
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARN: $u reported a problem; setup-state may remain." -ForegroundColor Yellow
        }
    }
    & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\lib\unwire-pretooluse-hooks.ps1') -SettingsPath $UserSettings
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARN: unwire-pretooluse-hooks reported a problem." -ForegroundColor Yellow
    }
}
Write-Host ""

# --- [7/7] remove the himmelctl cache + state (HIMMEL-2459) ------------------
# install-profile.json + state.json survived a COMPLETE uninstall, so a
# re-install started against the PREVIOUS install's profile and state ledger.
Write-Host "[7/7] Removing himmelctl cache + state ($HimmelCacheDir)..."
if (Test-SuspiciousRemovePath $HimmelCacheDir) {
    # A refusal is not a teardown: the cache is still there. Unlike step [2/7],
    # where the guard protects an OPTIONAL removal, this step is required, so a
    # refusal is an incomplete step and must not end in "Uninstall complete."
    Write-Host "  ERROR: refusing to remove suspicious path: '$HimmelCacheDir'" -ForegroundColor Red
    $StepsIncomplete.Add("[7/7] himmelctl cache: refused a suspicious HIMMELCTL_CACHE_DIR ('$HimmelCacheDir')")
} elseif (-not (Test-Path -LiteralPath $HimmelCacheDir)) {
    Write-Host "  absent, skipping: $HimmelCacheDir"
} else {
    # Name the known state files before removing, so -DryRun is auditable.
    foreach ($f in @('install-profile.json', 'state.json')) {
        $p = Join-Path $HimmelCacheDir $f
        if (Test-Path -LiteralPath $p -PathType Leaf) { Write-Host "  contains: $p" }
    }
    if ($DryRun) {
        Write-Host "DRY: Remove-Item -Recurse -Force -LiteralPath $HimmelCacheDir"
    } else {
        # Same partial-delete discipline as step 2: a throw AND a re-test, so a
        # locked file is never reported as a successful removal.
        $rmErr = $null
        try {
            Remove-Item -Recurse -Force -LiteralPath $HimmelCacheDir -ErrorAction Stop
        } catch {
            $rmErr = $_
        }
        if ($rmErr -or (Test-Path -LiteralPath $HimmelCacheDir)) {
            # A failed removal is residue that survives the uninstall — the
            # exact thing HIMMEL-2458 says must not end in "Uninstall
            # complete." at rc=0.
            $detail = if ($rmErr) { " -- $rmErr" } else { '' }
            Write-Host "  ERROR: failed to remove $HimmelCacheDir$detail" -ForegroundColor Red
            Write-Host "  residue remains under $HimmelCacheDir -- remove it manually." -ForegroundColor Red
            $StepsIncomplete.Add("[7/7] himmelctl cache: $HimmelCacheDir could not be removed")
        } else {
            Write-Host "  removed: $HimmelCacheDir"
        }
    }
}
Write-Host ""

# A step that HAD to run and could not is not a completed uninstall — saying so,
# and exiting non-zero, is the point of HIMMEL-2458.
if ($StepsIncomplete.Count -gt 0) {
    Write-Host "Uninstall INCOMPLETE -- $($StepsIncomplete.Count) step(s) did not run:" -ForegroundColor Red
    foreach ($s in $StepsIncomplete) { Write-Host "  - $s" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Nothing was removed by those steps. Put the tool on PATH and re-run,"
    Write-Host "or pass -SkipPlugins / -SkipHooks to accept the gap deliberately."
    exit 2
}

Write-Host "Uninstall complete."
Write-Host ""
Write-Host "NOT touched (by design):"
Write-Host "  - ~/.claude/settings.json non-himmel keys (MCP config, your own hooks, rtk guard)"
Write-Host "  - the himmel clone itself, .env, and worktrees"
Write-Host "  - ~/.claude/handover/registry.json + handover state outside the bridge root"
