# Unit test for .codex/run-hook.cmd + .codex/codex-hook-adapter.sh — the Codex
# hook wrapper + decision adapter (HIMMEL-427/HIMMEL-2019). Tests the Windows
# wrapper on its native interpreter (cmd.exe via PowerShell). The
# Unix/bash branch is covered by the .sh twin. Mirrors the .sh assertions:
# CLAUDE_PROJECT_DIR derived+exported, stdin forwarded, a non-block exit code
# PROPAGATES, and an exit-2 block is translated to Codex's JSON deny on stdout.

$ErrorActionPreference = 'Continue'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$HOOKS   = $PSScriptRoot
$WRAPPER = Join-Path $HOOKS '..' | Join-Path -ChildPath '..' | Join-Path -ChildPath '.codex' | Join-Path -ChildPath 'run-hook.cmd'
$ADAPTER = Join-Path $HOOKS '..' | Join-Path -ChildPath '..' | Join-Path -ChildPath '.codex' | Join-Path -ChildPath 'codex-hook-adapter.sh'

$script:failures = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path -LiteralPath $WRAPPER)) { Write-Host "wrapper not found: $WRAPPER"; exit 1 }
if (-not (Test-Path -LiteralPath $ADAPTER)) { Write-Host "adapter not found: $ADAPTER"; exit 1 }

$wrapperBytes = [System.IO.File]::ReadAllBytes($WRAPPER)
$bareLf = 0
for ($i = 0; $i -lt $wrapperBytes.Length; $i++) {
    if ($wrapperBytes[$i] -eq 10 -and ($i -eq 0 -or $wrapperBytes[$i - 1] -ne 13)) { $bareLf++ }
}
Check 'run-hook.cmd contains no bare LF line endings' ($bareLf -eq 0)

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
# HIMMEL-1987: emits a Claude permissionDecision:"allow"/updatedInput envelope
# (auto-approve-safe-bash / rtk-hook-guard shape) on stdout, exits 0.
$allowdummy = "cat >/dev/null`nprintf '%s\n' '{`"hookSpecificOutput`":{`"hookEventName`":`"PreToolUse`",`"permissionDecision`":`"allow`",`"updatedInput`":{`"command`":`"rtk git status`"},`"permissionDecisionReason`":`"safe`"}}'`nexit 0`n"
[System.IO.File]::WriteAllText((Join-Path $T 'scripts\hooks\allowdummy.sh'), $allowdummy)
# CRITIC-1: stdout permissionDecision:"deny" with non-exact colon spacing must
# still be detected as a block, not swallowed as fail-OPEN.
$denyspace = "cat >/dev/null`nprintf '%s\n' '{`"hookSpecificOutput`":{`"hookEventName`":`"PreToolUse`",`"permissionDecision`": `"deny`"}}'`nexit 0`n"
[System.IO.File]::WriteAllText((Join-Path $T 'scripts\hooks\denyspace.sh'), $denyspace)
$denytab = "cat >/dev/null`nprintf '{`"hookSpecificOutput`":{`"hookEventName`":`"PreToolUse`",`"permissionDecision`":\t`"deny`"}}\n'`nexit 0`n"
[System.IO.File]::WriteAllText((Join-Path $T 'scripts\hooks\denytab.sh'), $denytab)
$fakeBash = Join-Path $T 'fake-bash.cmd'
[System.IO.File]::WriteAllText($fakeBash, "@echo off`r`nexit /b 99`r`n")

try {
    # 1) NON-BLOCK path: adapter exits 0 (proceeds cleanly, codex-2) regardless
    #    of the guardrail's own code; env + stdin still forwarded (advisory stderr).
    Push-Location $T
    $out = ('fromstdin' | & cmd.exe /c '.codex\run-hook.cmd' dummy.sh 2>&1 | Out-String)
    $rc = $LASTEXITCODE
    Pop-Location

    Check "non-block -> adapter exits 0 (proceeds cleanly, not the guardrail's own code)" ($rc -eq 0)
    $expected = (Resolve-Path -LiteralPath $T).Path
    Check "CLAUDE_PROJECT_DIR derived from wrapper location + exported" ($out -match [regex]::Escape("PROJDIR=[$expected]"))
    # Match the prefix only — PowerShell pipes CRLF, so `read -r` may keep a
    # trailing \r inside the brackets; stdin forwarding is what we're asserting.
    Check "stdin forwarded to the guardrail" ($out -match 'STDIN=\[fromstdin')

    # HIMMEL-1987: Codex rejects a Claude permissionDecision:"allow"/updatedInput
    # envelope, so the adapter no longer forwards guardrail stdout to Codex's
    # stdout at all — it re-emits it only as advisory on the adapter's OWN
    # stderr. Capture stdout ALONE (stderr suppressed) and assert it's empty.
    Push-Location $T
    $sout = ('fromstdin' | & cmd.exe /c '.codex\run-hook.cmd' dummy.sh 2>$null | Out-String)
    Pop-Location
    Check "non-block guardrail stdout NOT forwarded to Codex stdout (swallowed)" ([string]::IsNullOrWhiteSpace($sout))

    # 1b) Explicit sandbox mode is the tracked hook setup; it should behave like
    #     the default sandbox path: adapter exits 0 (proceeds cleanly) and stdin
    #     is still forwarded.
    Push-Location $T
    $fout = ('fromstdin' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox dummy.sh 2>&1 | Out-String)
    $frc = $LASTEXITCODE
    Pop-Location

    Check "explicit --sandbox flag -> adapter exits 0 (proceeds cleanly)" ($frc -eq 0)
    Check "explicit --sandbox flag still forwards stdin" ($fout -match 'STDIN=\[fromstdin')

    # 1c) ALLOW-SWALLOW (HIMMEL-1987): a guardrail that emits a Claude
    #     permissionDecision:"allow" (optionally with updatedInput) on stdout and
    #     exits 0 — auto-approve-safe-bash / rtk-hook-guard shape. Codex rejects
    #     that envelope ("unsupported permissionDecision:allow"), so the adapter
    #     must NOT forward it: stdout empty, rc 0 (proceed).
    Push-Location $T
    $aout = ('{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox allowdummy.sh 2>$null | Out-String)
    $arc = $LASTEXITCODE
    Pop-Location
    Check "allow/updatedInput envelope swallowed (empty stdout, rc 0)" (($arc -eq 0) -and [string]::IsNullOrWhiteSpace($aout))

    # 1d) STDOUT-DENY whitespace tolerance (CRITIC-1): a guardrail that exits 0
    #     but emits a permissionDecision:"deny" envelope on stdout with non-exact
    #     spacing around the colon (pretty-printed / tab-indented) must still be
    #     detected as a block, not swallowed as fail-OPEN.
    Push-Location $T
    $dsout = ('{"hook_event_name":"PreToolUse"}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox denyspace.sh 2>&1 | Out-String)
    $dsrc = $LASTEXITCODE
    Pop-Location
    Check "stdout deny (space after colon) -> wrapper exits 0" ($dsrc -eq 0)
    Check "stdout deny (space after colon) is detected, not swallowed" ($dsout -match '"permissionDecision":"deny"')

    Push-Location $T
    $dtout = ('{"hook_event_name":"PreToolUse"}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox denytab.sh 2>&1 | Out-String)
    $dtrc = $LASTEXITCODE
    Pop-Location
    Check "stdout deny (tab after colon) -> wrapper exits 0" ($dtrc -eq 0)
    Check "stdout deny (tab after colon) is detected, not swallowed" ($dtout -match '"permissionDecision":"deny"')

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
    #     Use a clearly-bogus event name: `Stop` is now a first-class adapter branch
    #     (HIMMEL-599), so it is no longer "unknown".
    Push-Location $T
    $unkout = ('{"hook_event_name":"BogusEvent"}' | & cmd.exe /c '.codex\run-hook.cmd' blocker.sh 2>&1 | Out-String)
    $unkrc = $LASTEXITCODE
    Pop-Location
    Check "unknown-event exit-2 -> wrapper exits 0" ($unkrc -eq 0)
    Check "unknown-event exit-2 -> normalised to PostToolUse" ($unkout -match '"hookEventName":"PostToolUse"')
    Check "unknown-event exit-2 -> must NOT echo the raw event string" ($unkout -notmatch '"BogusEvent"')
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

    # 3c) Git Bash exists but cannot run the adapter (unusable inside the hook
    #     sandbox, or a fork failure under memory pressure) -> fail-closed deny.
    #     HIMMEL-1981: the adapter exits 0 on every normal path, so a nonzero code
    #     in sandbox mode means it never ran; the wrapper must NOT propagate it
    #     (Codex renders "hook exited with code 1" AND fails open) but emit the
    #     deny Codex honours and exit 0. Checked AFTER the adapter call, which
    #     replaces the extra `bash -c "exit 0"` smoke spawn this used to cost.
    $oldHookBash = $env:HIMMEL_CODEX_HOOK_BASH
    $env:HIMMEL_CODEX_HOOK_BASH = $fakeBash
    Push-Location $T
    $sout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox dummy.sh 2>&1 | Out-String)
    $rc4 = $LASTEXITCODE
    Pop-Location
    if ($null -eq $oldHookBash) { Remove-Item Env:\HIMMEL_CODEX_HOOK_BASH -ErrorAction SilentlyContinue }
    else { $env:HIMMEL_CODEX_HOOK_BASH = $oldHookBash }
    Check "explicit --sandbox adapter failure -> fail-closed deny (rc 0, never the child's code)" (($rc4 -eq 0) -and ($sout -match '"permissionDecision":"deny"') -and ($sout -match 'hook adapter did not complete') -and ($sout -match 'blocking dummy.sh fail-closed'))

    # 3c-bis) A --lifecycle hook (SessionStart/Stop) has NO permission gate, and
    #     Codex's per-event output schema rejects a PreToolUse deny envelope. So
    #     an adapter failure there must report honestly (stderr + rc 1, Codex's
    #     "hook failed" banner) rather than emit a deny shaped for the wrong event.
    $oldHookBash = $env:HIMMEL_CODEX_HOOK_BASH
    $env:HIMMEL_CODEX_HOOK_BASH = $fakeBash
    Push-Location $T
    $lout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox --lifecycle dummy.sh 2>&1 | Out-String)
    $rc4b = $LASTEXITCODE
    Pop-Location
    if ($null -eq $oldHookBash) { Remove-Item Env:\HIMMEL_CODEX_HOOK_BASH -ErrorAction SilentlyContinue }
    else { $env:HIMMEL_CODEX_HOOK_BASH = $oldHookBash }
    Check "--lifecycle adapter failure -> honest rc 1, no wrong-event deny envelope" (($rc4b -eq 1) -and ($lout -notmatch '"permissionDecision"') -and ($lout -match 'advisory hook dummy.sh did not run'))

    # 3c-quater) CRITIC-1: the PRECONDITION failures (missing script name, no Git
    #     Bash, adapter not found) must honour the same lifecycle contract as the
    #     adapter-failure path — one shared fail-closed exit, not a per-branch
    #     copy that forgets it. Adapter absent + --lifecycle -> honest rc 1.
    $NOAD = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path (Join-Path $NOAD '.codex') -Force | Out-Null
    Copy-Item -LiteralPath $WRAPPER -Destination (Join-Path $NOAD '.codex\run-hook.cmd')
    Push-Location $NOAD
    $pout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox --lifecycle dummy.sh 2>&1 | Out-String)
    $rc4d = $LASTEXITCODE
    $gout2 = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox dummy.sh 2>&1 | Out-String)
    $rc4e = $LASTEXITCODE
    Pop-Location
    Remove-Item -Recurse -Force -LiteralPath $NOAD -ErrorAction SilentlyContinue
    Check "--lifecycle precondition failure (no adapter) -> honest rc 1, no deny envelope" (($rc4d -eq 1) -and ($pout -notmatch '"permissionDecision"') -and ($pout -match 'adapter not found'))
    Check "gate precondition failure (no adapter) still fails closed (rc 0 + deny)" (($rc4e -eq 0) -and ($gout2 -match '"permissionDecision":"deny"'))

    # 3c-quinquies) CRITIC-2: --lifecycle is documented as independently optional,
    #     so it must parse in the FIRST slot too (the Unix branch loops over flags).
    Push-Location $T
    $f1out = ('fromstdin' | & cmd.exe /c '.codex\run-hook.cmd' --lifecycle dummy.sh 2>&1 | Out-String)
    $rc4f = $LASTEXITCODE
    Pop-Location
    Check "--lifecycle in the first arg slot resolves the script name" (($rc4f -eq 0) -and ($f1out -match 'STDIN=\[fromstdin'))

    # 3c-sexies) The ADAPTER has preconditions the wrapper does not (missing
    #     guardrail file), and it is reached before stdin is read, so the inbound
    #     event is unknown there too. The wrapper exports the lifecycle intent so
    #     the adapter honours the same contract: honest failure, no deny envelope.
    Push-Location $T
    $aout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox --lifecycle nonexistent-guardrail.sh 2>&1 | Out-String)
    $rc4g = $LASTEXITCODE
    Pop-Location
    Check "--lifecycle adapter precondition (missing guardrail) -> honest rc 1, no deny envelope" (($rc4g -eq 1) -and ($aout -notmatch '"permissionDecision"'))

    # 3c-septies) The wrapper is the ONLY authority on the flag. An INHERITED
    #     HIMMEL_CODEX_HOOK_LIFECYCLE=1 must not promote a permission-gate hook,
    #     or its fail-closed deny silently becomes a bare rc 1 (= Codex fails open).
    $env:HIMMEL_CODEX_HOOK_LIFECYCLE = '1'
    Push-Location $T
    $iout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox nonexistent-guardrail.sh 2>&1 | Out-String)
    $rc4h = $LASTEXITCODE
    Pop-Location
    Remove-Item Env:\HIMMEL_CODEX_HOOK_LIFECYCLE -ErrorAction SilentlyContinue
    Check "inherited HIMMEL_CODEX_HOOK_LIFECYCLE does NOT promote a gate hook (still deny, rc 0)" (($rc4h -eq 0) -and ($iout -match '"permissionDecision":"deny"'))

    # 3c-ter) --lifecycle must not change the HEALTHY path: the guardrail still
    #     runs (stdin + derived project dir forwarded) and the wrapper exits 0.
    Push-Location $T
    $hout = ('fromstdin' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox --lifecycle dummy.sh 2>&1 | Out-String)
    $rc4c = $LASTEXITCODE
    Pop-Location
    Check "--lifecycle healthy path still runs the guardrail and exits 0" (($rc4c -eq 0) -and ($hout -match 'STDIN=\[fromstdin'))

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

    # 4) CHAIN (HIMMEL-1989) through the WINDOWS wrapper. The chain semantics
    #    (order, first-deny short-circuit, allow swallow, fail-closed) live in the
    #    adapter and are pinned by the .sh twin; what is Windows-specific — and
    #    what this covers — is whether the `+`-separated chain survives cmd.exe's
    #    argument tokenizer intact.
    $log = Join-Path $T 'chain.log'
    foreach ($m in @('m1','m2','m3')) {
        [System.IO.File]::WriteAllText((Join-Path $T "scripts\hooks\$m.sh"),
            "cat >/dev/null`nprintf '%s ' $m >> `"`$CHAIN_LOG`"`nexit 0`n")
    }
    $env:CHAIN_LOG = $log
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    Push-Location $T
    $chout = ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox m1.sh+m2.sh+m3.sh 2>$null | Out-String)
    $rc6 = $LASTEXITCODE
    Pop-Location
    $chlog = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Raw) } else { '' }
    Check "chain survives cmd.exe argument parsing: all 3 members run in order" (($rc6 -eq 0) -and ($chlog -eq 'm1 m2 m3 '))
    Check "clean chain emits nothing on Codex stdout" ([string]::IsNullOrWhiteSpace($chout))

    # 4b) CANARY (platform behaviour, not ours): cmd.exe treats `,` as an argument
    #     DELIMITER, so a comma-separated chain arrives as %2=<first> and would
    #     silently run only the first guardrail. This is the entire reason the
    #     separator is `+`; if this canary ever stops holding, revisit that choice
    #     — do NOT let a comma chain into .codex/hooks.json (the parity gate
    #     rejects one, because nothing downstream can detect the truncation).
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    Push-Location $T
    ('{}' | & cmd.exe /c '.codex\run-hook.cmd' --sandbox m1.sh,m2.sh,m3.sh 2>$null | Out-Null)
    Pop-Location
    $cslog = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Raw) } else { '' }
    Remove-Item Env:\CHAIN_LOG -ErrorAction SilentlyContinue
    Check "canary: cmd.exe splits a comma chain, so only the first member runs" ($cslog -eq 'm1 ')
}
finally {
    Remove-Item Env:\HIMMEL_CODEX_HOOK_BASH -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $T -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) { Write-Host 'OK: all cases passed'; exit 0 }
else { Write-Host "FAIL: $($script:failures) case(s) failed"; exit 1 }
