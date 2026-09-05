# Regression test (HIMMEL-589) — WINDOWS (cmd.exe) branch. The Unix/bash branch
# is covered by the .sh twin (which also exercises merged-pr end-to-end).
#
# Asserts the two plugin-delivered SECURITY guards are wired into
# .codex/hooks.json and FIRE under the Codex plugin-hook env on Windows, where
# Codex sets CLAUDE_PLUGIN_ROOT but NOT CLAUDE_PROJECT_DIR. run-hook.cmd's
# cmd.exe branch derives the repo root from its own location, so the guard runs
# even with CLAUDE_PROJECT_DIR unset.
#
# block-docker-privesc is self-contained (no git/forge), so it is the Windows
# behavioral anchor here. block-merged-pr-commit's logic runs inside Git Bash
# once dispatched; the cmd.exe->bash handoff is proven generically by
# test-codex-run-hook.ps1, and its firing is asserted by the .sh twin.

$ErrorActionPreference = 'Continue'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$HOOKS     = $PSScriptRoot
$REPO_ROOT = (Resolve-Path (Join-Path $HOOKS '..' | Join-Path -ChildPath '..')).Path
$HOOKS_JSON = Join-Path $REPO_ROOT '.codex\hooks.json'

$script:failures = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path -LiteralPath $HOOKS_JSON)) { Write-Host ".codex/hooks.json not found: $HOOKS_JSON"; exit 1 }

$cfg = Get-Content -Raw -LiteralPath $HOOKS_JSON | ConvertFrom-Json
$pre = @($cfg.hooks.PreToolUse)

function Wired-Blocks([string]$guard) {
    $found = @()
    foreach ($b in $pre) {
        foreach ($h in @($b.hooks)) {
            if ($h.commandWindows -like "*$guard*") { $found += $b; break }
        }
    }
    return $found
}

# ── 1) Static wiring ────────────────────────────────────────────────────────
foreach ($g in @('block-docker-privesc.sh', 'block-merged-pr-commit.sh')) {
    $blocks = @(Wired-Blocks $g)
    Check "$g wired into .codex/hooks.json" ($blocks.Count -gt 0)
    if ($blocks.Count -gt 0) {
        $cmds = (@($blocks.hooks) | ForEach-Object { $_.commandWindows }) -join ' '
        $matchers = (@($blocks) | ForEach-Object { $_.matcher }) -join '|'
        Check "$g routed through run-hook.cmd" ($cmds -like '*run-hook.cmd*')
        Check "$g matches both Bash and PowerShell" (($matchers -like '*Bash*') -and ($matchers -like '*PowerShell*'))
    }
}

# ── 2) Behavioral: docker-privesc fires through the cmd.exe branch ──────────
$oldProj = $env:CLAUDE_PROJECT_DIR
$oldPlugin = $env:CLAUDE_PLUGIN_ROOT
Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
$env:CLAUDE_PLUGIN_ROOT = 'C:\nonexistent\codex\plugin-root'
try {
    $privesc = '{"tool_name":"Bash","tool_input":{"command":"docker run --rm -v /etc:/host-etc:rw ubuntu:22.04 cat /host-etc/shadow"}}'
    $benign  = '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'

    Push-Location $REPO_ROOT
    $dout = ($privesc | & cmd.exe /c '.codex\run-hook.cmd' --sandbox block-docker-privesc.sh 2>&1 | Out-String)
    Pop-Location
    Check "docker-privesc: root-equiv mount denied (CLAUDE_PROJECT_DIR unset)" ($dout -match '"permissionDecision":"deny"')

    Push-Location $REPO_ROOT
    $bout = ($benign | & cmd.exe /c '.codex\run-hook.cmd' --sandbox block-docker-privesc.sh 2>&1 | Out-String)
    Pop-Location
    Check "docker-privesc: benign command allowed" ($bout -notmatch '"permissionDecision":"deny"')
}
finally {
    if ($null -eq $oldProj) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $oldProj }
    if ($null -eq $oldPlugin) { Remove-Item Env:\CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue } else { $env:CLAUDE_PLUGIN_ROOT = $oldPlugin }
}

if ($script:failures -eq 0) { Write-Host 'OK: all cases passed'; exit 0 }
else { Write-Host "FAIL: $($script:failures) case(s) failed"; exit 1 }
