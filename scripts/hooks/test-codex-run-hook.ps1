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
$fakeBash = Join-Path $T 'fake-bash.cmd'
[System.IO.File]::WriteAllText($fakeBash, "@echo off`r`nexit /b 99`r`n")

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

    # 1b) Explicit sandbox mode is the tracked hook setup; it should behave like
    #     the default sandbox path and still propagate non-block guardrail rc.
    Push-Location $T
    $fout = ('fromstdin' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox dummy.sh 2>&1 | Out-String)
    $frc = $LASTEXITCODE
    Pop-Location

    Check "explicit --sandbox flag preserves non-block rc propagation (rc=7)" ($frc -eq 7)
    Check "explicit --sandbox flag still forwards stdin" ($fout -match 'STDIN=\[fromstdin')

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

    # 2b) NON-PERMISSION lifecycle exit-2 (HIMMEL-565): a guardrail that exits 2 on
    #     a non-permission event (PostToolUse auto-arm success) must surface its
    #     message via additionalContext, NOT a bogus PreToolUse permission deny.
    Push-Location $T
    $pout = ('{"hook_event_name":"PostToolUse"}' | & cmd.exe /c '.codex\run-hook.cmd' blocker.sh 2>&1 | Out-String)
    $prc = $LASTEXITCODE
    Pop-Location
    Check "PostToolUse exit-2 -> wrapper exits 0 (signal is in stdout JSON)" ($prc -eq 0)
    Check "PostToolUse exit-2 -> hookEventName mirrors PostToolUse" ($pout -match '"hookEventName":"PostToolUse"')
    Check "PostToolUse exit-2 -> surfaces additionalContext" ($pout -match '"additionalContext"')
    Check "PostToolUse exit-2 -> must NOT emit a permission decision" ($pout -notmatch 'permissionDecision')
    Check "PostToolUse exit-2 -> guardrail stderr becomes the additionalContext reason" ($pout -match 'blocking-reason-xyz')

    # 2c) Coherence: SessionStart exit-2 follows the same non-permission contract.
    Push-Location $T
    $ssout = ('{"hook_event_name":"SessionStart"}' | & cmd.exe /c '.codex\run-hook.cmd' blocker.sh 2>&1 | Out-String)
    $ssrc = $LASTEXITCODE
    Pop-Location
    Check "SessionStart exit-2 -> wrapper exits 0" ($ssrc -eq 0)
    Check "SessionStart exit-2 -> hookEventName mirrors SessionStart" ($ssout -match '"hookEventName":"SessionStart"')
    Check "SessionStart exit-2 -> surfaces additionalContext" ($ssout -match '"additionalContext"')
    Check "SessionStart exit-2 -> must NOT emit a permission decision" ($ssout -notmatch 'permissionDecision')

    # 2e) Unknown/garbage inbound event on exit-2 normalises to PostToolUse — never
    #     echoes the raw event string into the hookEventName const, never a deny.
    Push-Location $T
    $unkout = ('{"hook_event_name":"Stop"}' | & cmd.exe /c '.codex\run-hook.cmd' blocker.sh 2>&1 | Out-String)
    $unkrc = $LASTEXITCODE
    Pop-Location
    Check "unknown-event exit-2 -> wrapper exits 0" ($unkrc -eq 0)
    Check "unknown-event exit-2 -> normalised to PostToolUse" ($unkout -match '"hookEventName":"PostToolUse"')
    Check "unknown-event exit-2 -> must NOT echo the raw event string" ($unkout -notmatch '"Stop"')
    Check "unknown-event exit-2 -> must NOT emit a permission decision" ($unkout -notmatch 'permissionDecision')

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

    # 3c) Git Bash exists but cannot start inside the hook sandbox -> fail closed
    #     before the adapter path. This preserves normal guardrail rc propagation
    #     (dummy.sh rc=7 above) while making a broken bash runtime a deny.
    $oldHookBash = $env:HIMMEL_CODEX_HOOK_BASH
    $env:HIMMEL_CODEX_HOOK_BASH = $fakeBash
    Push-Location $T
    $sout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox dummy.sh 2>&1 | Out-String)
    $rc4 = $LASTEXITCODE
    Pop-Location
    if ($null -eq $oldHookBash) { Remove-Item Env:\HIMMEL_CODEX_HOOK_BASH -ErrorAction SilentlyContinue }
    else { $env:HIMMEL_CODEX_HOOK_BASH = $oldHookBash }
    Check "explicit --sandbox bash startup failure -> fail-closed deny (rc 0)" (($rc4 -eq 0) -and ($sout -match '"permissionDecision":"deny"') -and ($sout -match 'Git Bash failed startup check'))

    # 3d) No-sandbox diagnostics skip the startup smoke check and surface the
    #     raw child rc. The tracked hook config must not use this mode.
    $oldHookBash = $env:HIMMEL_CODEX_HOOK_BASH
    $env:HIMMEL_CODEX_HOOK_BASH = $fakeBash
    Push-Location $T
    $nsout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --no-sandbox dummy.sh 2>&1 | Out-String)
    $rc5 = $LASTEXITCODE
    Pop-Location
    if ($null -eq $oldHookBash) { Remove-Item Env:\HIMMEL_CODEX_HOOK_BASH -ErrorAction SilentlyContinue }
    else { $env:HIMMEL_CODEX_HOOK_BASH = $oldHookBash }
    Check "explicit --no-sandbox skips startup deny and surfaces child rc" (($rc5 -eq 99) -and ($nsout -notmatch '"permissionDecision":"deny"'))
}
finally {
    Remove-Item Env:\HIMMEL_CODEX_HOOK_BASH -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $T -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) { Write-Host 'OK: all cases passed'; exit 0 }
else { Write-Host "FAIL: $($script:failures) case(s) failed"; exit 1 }
