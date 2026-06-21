# Unit test for .codex/run-hook.cmd + .codex/codex-hook-adapter.sh — the Codex
# hook wrapper + decision adapter (HIMMEL-427). Tests the WINDOWS (cmd.exe)
# branch of the polyglot on its native interpreter (cmd.exe via PowerShell). The
# Unix/bash branch is covered by the .sh twin. Mirrors the .sh assertions:
# CLAUDE_PROJECT_DIR derived+exported, stdin forwarded, a non-block exit code
# PROPAGATES, and an exit-2 block is translated to Codex's JSON deny on stdout.

$ErrorActionPreference = 'Continue'
$HOOKS   = $PSScriptRoot
$WRAPPER = Join-Path $HOOKS '..' | Join-Path -ChildPath '..' | Join-Path -ChildPath '.codex' | Join-Path -ChildPath 'run-hook.cmd'
$ADAPTER = Join-Path $HOOKS '..' | Join-Path -ChildPath '..' | Join-Path -ChildPath '.codex' | Join-Path -ChildPath 'codex-hook-adapter.sh'

$script:failures = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path -LiteralPath $WRAPPER)) { Write-Host "wrapper not found: $WRAPPER"; exit 1 }
if (-not (Test-Path -LiteralPath $ADAPTER)) { Write-Host "adapter not found: $ADAPTER"; exit 1 }

$T = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path (Join-Path $T '.codex') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $T 'scripts\hooks') -Force | Out-Null
Copy-Item -LiteralPath $WRAPPER -Destination (Join-Path $T '.codex\run-hook.cmd')
Copy-Item -LiteralPath $ADAPTER -Destination (Join-Path $T '.codex\codex-hook-adapter.sh')
# Guardrails (LF-only so Git Bash runs them cleanly).
$dummy = "read -r line || true`necho `"PROJDIR=[`$CLAUDE_PROJECT_DIR]`"`necho `"STDIN=[`$line]`"`nexit 7`n"
[System.IO.File]::WriteAllText((Join-Path $T 'scripts\hooks\dummy.sh'), $dummy)
$blocker = "read -r line || true`necho `"blocking-reason-xyz`" >&2`nexit 2`n"
[System.IO.File]::WriteAllText((Join-Path $T 'scripts\hooks\blocker.sh'), $blocker)

try {
    # 1) ALLOW path: non-block exit code propagates; env + stdin forwarded.
    Push-Location $T
    $out = ('fromstdin' | & cmd.exe /c '.codex\run-hook.cmd' dummy.sh 2>&1 | Out-String)
    $rc = $LASTEXITCODE
    Pop-Location

    Check "non-block exit code propagates (rc=7)" ($rc -eq 7)
    $expected = (Resolve-Path -LiteralPath $T).Path
    Check "CLAUDE_PROJECT_DIR derived from wrapper location + exported" ($out -match [regex]::Escape("PROJDIR=[$expected]"))
    # Match the prefix only — PowerShell pipes CRLF, so `read -r` may keep a
    # trailing \r inside the brackets; stdin forwarding is what we're asserting.
    Check "stdin forwarded to the guardrail" ($out -match 'STDIN=\[fromstdin')

    # 2) BLOCK path: exit 2 -> Codex JSON deny on stdout, wrapper exits 0. Use a
    #    DISTINCT inbound event so the hookEventName mirror is load-bearing and the
    #    non-PreToolUse path is covered.
    Push-Location $T
    $bout = ('{"hook_event_name":"PermissionRequest"}' | & cmd.exe /c '.codex\run-hook.cmd' blocker.sh 2>&1 | Out-String)
    $brc = $LASTEXITCODE
    Pop-Location

    Check "block -> wrapper exits 0 (decision is in stdout JSON)" ($brc -eq 0)
    Check "block -> emits permissionDecision deny" ($bout -match '"permissionDecision":"deny"')
    Check "block -> guardrail stderr becomes the deny reason" ($bout -match 'blocking-reason-xyz')
    Check "block -> hookEventName mirrors the inbound event" ($bout -match '"hookEventName":"PermissionRequest"')

    # 3) FAIL-CLOSED paths: a bare exit 2 fails OPEN under Codex, so precondition
    #    errors must emit a JSON deny (rc 0) instead.
    # 3a) Missing script name -> fail-closed deny (rc 0).
    Push-Location $T
    $nout = ('' | & cmd.exe /c '.codex\run-hook.cmd' 2>&1 | Out-String)
    $rc2 = $LASTEXITCODE
    Pop-Location
    Check "missing script name -> fail-closed deny (rc 0)" (($rc2 -eq 0) -and ($nout -match '"permissionDecision":"deny"'))
    # 3b) Referenced guardrail file does not exist -> fail-closed deny (rc 0).
    Push-Location $T
    $gout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' nonexistent-guardrail.sh 2>&1 | Out-String)
    $rc3 = $LASTEXITCODE
    Pop-Location
    Check "missing guardrail file -> fail-closed deny (rc 0)" (($rc3 -eq 0) -and ($gout -match '"permissionDecision":"deny"'))
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $T -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) { Write-Host 'OK: all cases passed'; exit 0 }
else { Write-Host "FAIL: $($script:failures) case(s) failed"; exit 1 }
