# Integration smoke for scripts/hooks/end-session-wiki.ps1 (HIMMEL-403) — the
# .ps1 is the hook that actually runs on Windows, so the vault-NAME wiring and
# the fail-closed skip are exercised end-to-end here, not just via the lib.
#
# Cases 1–2: vault-NAME routing + fail-closed skip (original coverage).
# Cases 3–5: pinned-fixture render test + safety gate (added for Task 1.2
#   spec compliance — mirrors capture-baseline.sh for PowerShell).
#   The hook uses [DateTime]::UtcNow which cannot be stubbed via PATH shims,
#   so runtime-variable lines (date:, worktree:, duration_minutes:) are also
#   stripped from the comparison in addition to the two new fields (session_id:,
#   source:). All other content must match session-note.baseline.md exactly.
#
# Run: pwsh scripts/hooks/test-end-session-wiki.ps1
$ErrorActionPreference = 'Stop'
$HOOK = Join-Path $PSScriptRoot 'end-session-wiki.ps1'
$TestdataDir = Join-Path $PSScriptRoot 'testdata'
$FixturePath = Join-Path $TestdataDir 'fixture.jsonl'
$BaselinePath = Join-Path $TestdataDir 'session-note.baseline.md'

# Crystallizer test seam (HIMMEL-576): point the detached crystallizer at the
# claude STUB (no-op) so these tests NEVER spawn a real claude / bill the Max plan.
# Inherited by the hook child pwsh and onward to crystallize-note.ps1.
$env:CRYSTALLIZE_CLAUDE_BIN = (Join-Path $TestdataDir 'bin\claude-stub.ps1')
$env:STUB_MODE = 'noop'
$env:CRYSTALLIZE_PID_DIR = (Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-pids-" + [guid]::NewGuid().ToString('N')))

$script:fails = 0
function Pass([string]$m) { "PASS: $m" }
function Fail([string]$m) { "FAIL: $m"; $script:fails++ }

$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $SB 'proj\.claude') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SB 'home\Documents\medic\.obsidian') -Force | Out-Null
$transcript = Join-Path $SB 'transcript.jsonl'
Set-Content -LiteralPath $transcript -Value '{"timestamp":"2026-06-17T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"l1\nl2"}]}}'
$cfgPath = Join-Path $SB 'proj\.claude\end-session-wiki.json'
$logPath = Join-Path $SB 'proj\.claude\end-session-wiki.log'
$payload = @{ transcript_path = $transcript; cwd = (Join-Path $SB 'proj'); session_id = 't'; reason = 'other' } | ConvertTo-Json -Compress

function Invoke-Hook {
    $env:USERPROFILE = (Join-Path $SB 'home')
    $env:CLAUDE_PROJECT_DIR = (Join-Path $SB 'proj')
    $env:OBSIDIAN_API_KEY = ''
    Remove-Item Env:\LUNA_VAULT_PATH -ErrorAction SilentlyContinue
    $payload | pwsh -NoProfile -File $HOOK | Out-Null
}
function Notes([string]$root) { Get-ChildItem -Path $root -Recurse -Filter *.md -ErrorAction SilentlyContinue }

# ---------- Build git.bat shim for pinned-fixture cases ----------------------
# Placed in a temp dir prepended to PATH so the hook's `& git ...` calls return
# fixed values matching the bash stub (same repo/branch/files as fixture.jsonl).
# Uses pwsh internally to emit LF-only output (cmd `echo` always emits CRLF,
# which would leave trailing \r on every file path the hook stores).
$StubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-stubs-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $StubDir -Force | Out-Null
$gitBat = Join-Path $StubDir 'git.bat'
@'
@echo off
set ARGS=%*
echo %ARGS% | findstr /C:"rev-parse --show-toplevel" >nul && (pwsh -NoProfile -Command "Write-Host 'C:\tmp\himmel-test'") && exit /b 0
echo %ARGS% | findstr /C:"remote get-url origin" >nul && (pwsh -NoProfile -Command "Write-Host 'https://github.com/yotamleo/himmel.git'") && exit /b 0
echo %ARGS% | findstr /C:"branch --show-current" >nul && (pwsh -NoProfile -Command "Write-Host 'feat/luna-backfill'") && exit /b 0
echo %ARGS% | findstr /C:"diff --name-only HEAD" >nul && (pwsh -NoProfile -Command "Write-Host 'scripts/lib/session-transcript.sh'; Write-Host 'scripts/lib/session-note.sh'") && exit /b 0
exit /b 1
'@ | Set-Content -LiteralPath $gitBat -Encoding ASCII

function Invoke-HookPinned {
    # Run the hook with the pinned fixture.jsonl and git shim; captures exit code.
    param([string]$VaultPath, [string]$ProjPath)
    $pin = '{"transcript_path":"' + ($FixturePath -replace '\\','\\\\') + '","cwd":"C:\\\\tmp\\\\himmel-test","session_id":"test-session-id-001","reason":"other"}'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName  = (Get-Command pwsh).Source
    $psi.Arguments = "-NoProfile -NonInteractive -File `"$HOOK`""
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    foreach ($e in [System.Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process).GetEnumerator()) {
        $psi.EnvironmentVariables[$e.Key] = $e.Value
    }
    $psi.EnvironmentVariables['PATH']              = "$StubDir;" + $psi.EnvironmentVariables['PATH']
    $psi.EnvironmentVariables['LUNA_VAULT_PATH']   = $VaultPath
    $psi.EnvironmentVariables['OBSIDIAN_API_KEY']  = ''
    $psi.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = $ProjPath
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($pin)
    $proc.StandardInput.Close()
    [void]$proc.StandardOutput.ReadToEnd()
    [void]$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return $proc.ExitCode
}

try {
    # Case 1: per-repo vault NAME routes via the ~/Documents/<name> convention.
    Set-Content -LiteralPath $cfgPath -Value '{"vault":"medic"}'
    Invoke-Hook
    if (Notes (Join-Path $SB 'home\Documents\medic\sessions')) { Pass 'vault NAME routes to medic via convention' }
    else { Fail 'no note under medic vault' }

    # Case 2: an invalid NAME is fail-closed — skip, no write anywhere, skip logged.
    Notes (Join-Path $SB 'home') | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $cfgPath -Value '{"vault":"../evil"}'
    Invoke-Hook
    if (Notes (Join-Path $SB 'home')) { Fail 'invalid name wrote a note' } else { Pass 'invalid name wrote no note' }
    $log = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
    if ($log -match 'skipped: vault') { Pass 'skip logged' } else { Fail 'skip not logged' }

    # ---- Pinned-fixture cases (Cases 3–5) ------------------------------------
    if (-not (Test-Path $FixturePath))  { Fail 'fixture.jsonl not found — skipping pinned cases'; $script:reached = $true; throw 'skip' }
    if (-not (Test-Path $BaselinePath)) { Fail 'session-note.baseline.md not found — skipping pinned cases'; $script:reached = $true; throw 'skip' }

    $sb3Vault = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt3v-" + [guid]::NewGuid().ToString('N'))
    $sb3Proj  = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt3p-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sb3Vault -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sb3Proj '.claude') -Force | Out-Null

    # Case 3: pinned fixture produces a note (FS fallback, no API key).
    $rc3 = Invoke-HookPinned -VaultPath $sb3Vault -ProjPath $sb3Proj
    if ($rc3 -eq 0) { Pass 'pinned-fixture run exits 0' }
    else             { Fail "pinned-fixture run exit was $rc3, expected 0" }

    $note3 = Get-ChildItem -Path $sb3Vault -Recurse -Filter '*.md' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($note3) { Pass "pinned-fixture run wrote note ($($note3.Name))" }
    else         { Fail "pinned-fixture run wrote no note under $sb3Vault" }

    # Case 4: rendered note carries session_id and source: live fields.
    if ($note3) {
        $noteContent3 = Get-Content -LiteralPath $note3.FullName -Raw
        if ($noteContent3 -match '(?m)^session_id: test-session-id-001$') { Pass 'rendered note carries session_id field' }
        else { Fail 'rendered note missing session_id field' }
        if ($noteContent3 -match '(?m)^source: live$') { Pass 'rendered note carries source: live' }
        else { Fail "rendered note missing 'source: live'" }
    }

    # Case 5: safety gate — structural skeleton minus runtime-variable lines
    # and known PS/bash divergent sections matches baseline.
    #
    # Lines stripped before comparing:
    #   date:, worktree:, duration_minutes: — cannot be pinned ([DateTime]::UtcNow)
    #   session_id:, source:               — the two new fields (same gate as bash)
    #
    # Sections excluded from comparison (known PS/bash behavioral divergence):
    #   ## Summary … ## Decisions  — PS captures last assistant turn only;
    #                                 bash captures ALL turns concatenated.
    #   ## Raw Conversation …       — same divergence (raw callout mirrors summary).
    # All other content (frontmatter skeleton, Files Touched, Commands,
    # Decisions, Follow-ups) must match the baseline exactly.
    if ($note3) {
        $skipPattern = '^(date:|worktree:|duration_minutes:|session_id:|source:|crystallized:|crystallized_at:)'
        function Remove-Section {
            param([string[]]$Lines, [string]$StartHeader, [string]$EndHeader)
            $inside = $false
            $out = foreach ($l in $Lines) {
                if ($l -match $StartHeader) { $inside = $true }
                if ($inside -and $l -match $EndHeader -and $l -notmatch $StartHeader) { $inside = $false }
                if (-not $inside) { $l }
            }
            return $out
        }
        function Strip-Note([string[]]$Lines) {
            $l = $Lines | Where-Object { $_ -notmatch $skipPattern }
            # Remove ## Summary through ## Decisions (exclusive)
            $l = Remove-Section -Lines $l -StartHeader '^## Summary' -EndHeader '^## '
            # Remove ## Raw Conversation to end
            $l = $l | ForEach-Object { $_ } | Where-Object {
                $script:inRaw = if ($_ -match '^## Raw Conversation') { $true } else { $script:inRaw }
                -not $script:inRaw
            }
            return ($l -join "`n").TrimEnd()
        }
        $script:inRaw = $false
        $stripped3   = Strip-Note -Lines (Get-Content -LiteralPath $note3.FullName)
        $script:inRaw = $false
        $strippedBase = Strip-Note -Lines (Get-Content -LiteralPath $BaselinePath)
        if ($stripped3 -eq $strippedBase) {
            Pass 'safety gate: structural skeleton (minus runtime-variable lines + divergent sections) matches baseline'
        } else {
            Fail 'safety gate: structural skeleton differs from baseline'
            '--- baseline (stripped) ---'
            $strippedBase
            '--- note (stripped) ---'
            $stripped3
        }
    }

    Remove-Item -LiteralPath $sb3Vault -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sb3Proj  -Recurse -Force -ErrorAction SilentlyContinue

    # ---- Husk-skip cases (Cases 6–7, HIMMEL-576) -----------------------------
    $huskVault = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-husk-" + [guid]::NewGuid().ToString('N'))
    $huskProj  = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-huskp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $huskVault -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $huskProj '.claude') -Force | Out-Null

    function Invoke-HookCustom {
        param([string]$Transcript, [string]$VaultPath, [string]$ProjPath)
        $pl = @{ transcript_path = $Transcript; cwd = $ProjPath; session_id = 't'; reason = 'other' } | ConvertTo-Json -Compress
        $env:USERPROFILE = (Join-Path $SB 'home')
        $env:CLAUDE_PROJECT_DIR = $ProjPath
        $env:OBSIDIAN_API_KEY = ''
        $env:LUNA_VAULT_PATH = $VaultPath
        $pl | pwsh -NoProfile -File $HOOK | Out-Null
    }

    # Case 6: a contentless transcript → husk → no note + skip logged.
    $huskTs = Join-Path $huskProj 'transcript.jsonl'
    Set-Content -LiteralPath $huskTs -Value '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"hi"}}'
    Invoke-HookCustom -Transcript $huskTs -VaultPath $huskVault -ProjPath $huskProj
    if (Notes (Join-Path $huskVault 'sessions')) { Fail 'husk: a note was written for a contentless transcript' }
    else { Pass 'husk: no note written for a contentless transcript' }
    $huskLog = Get-Content -LiteralPath (Join-Path $huskProj '.claude\end-session-wiki.log') -Raw -ErrorAction SilentlyContinue
    if ($huskLog -match 'skipped: husk \(no content\)') { Pass 'husk: skip logged' } else { Fail 'husk: skip not logged' }

    # Case 7: a thinking/tool-only session IS captured with a command-activity summary.
    $toolTs = Join-Path $huskProj 'transcript2.jsonl'
    Set-Content -LiteralPath $toolTs -Value @(
        '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}',
        '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"x"},{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}'
    )
    Invoke-HookCustom -Transcript $toolTs -VaultPath $huskVault -ProjPath $huskProj
    $toolNote = Notes (Join-Path $huskVault 'sessions') | Select-Object -First 1
    if ($toolNote) { Pass 'tool-only: note written (not a husk)' } else { Fail 'tool-only: no note written' }
    if ($toolNote -and ((Get-Content -LiteralPath $toolNote.FullName -Raw) -match 'Tool-only session')) {
        Pass 'tool-only: Summary surfaces command activity'
    } else { Fail 'tool-only: Summary did not surface command activity' }

    # Case 8: the hook spawns the detached crystallizer for a non-husk note.
    $spawnMark = Join-Path $huskProj 'spawn-marker.txt'
    $env:STUB_MODE = 'success'; $env:CRYSTALLIZE_MARKER = $spawnMark
    Invoke-HookCustom -Transcript $toolTs -VaultPath $huskVault -ProjPath $huskProj
    $w = 0; while (-not (Test-Path $spawnMark) -and $w -lt 60) { Start-Sleep -Milliseconds 100; $w++ }
    if (Test-Path $spawnMark) { Pass 'crystallizer spawned for a non-husk note' } else { Fail 'crystallizer was not spawned' }
    $env:STUB_MODE = 'noop'; Remove-Item Env:\CRYSTALLIZE_MARKER -ErrorAction SilentlyContinue

    # Case 9 (HIMMEL-590 F2): the mechanical Summary drops a leading system-reminder
    # reaction and surfaces the substantive line. Exercises the PowerShell-side
    # heuristic (independent from the bash twin) through the real hook. Only the
    # Summary SECTION is asserted (the Raw Conversation echoes the full turn).
    $f2Ts = Join-Path $huskProj 'transcript-f2.jsonl'
    Set-Content -LiteralPath $f2Ts -Value @(
        '{"timestamp":"2026-06-17T01:11:00Z","type":"user","message":{"role":"user","content":"go"}}',
        '{"timestamp":"2026-06-17T01:11:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I''ll ignore the TaskCreate reminder.\nFixed the parser off-by-one and added a test."}]}}'
    )
    Invoke-HookCustom -Transcript $f2Ts -VaultPath $huskVault -ProjPath $huskProj
    $f2Note = Notes (Join-Path $huskVault 'sessions') | Sort-Object LastWriteTime | Select-Object -Last 1
    $f2Summary = ''
    if ($f2Note) {
        $inS = $false; $acc = @()
        foreach ($l in (Get-Content -LiteralPath $f2Note.FullName)) {
            if ($l -eq '## Summary') { $inS = $true; continue }
            if ($inS -and ($l -match '^## ')) { break }
            if ($inS) { $acc += $l }
        }
        $f2Summary = ($acc -join "`n")
    }
    if ($f2Summary -match 'Fixed the parser off-by-one') { Pass 'F2(ps): substantive Summary line surfaced' } else { Fail 'F2(ps): substantive line missing from Summary' }
    if ($f2Summary -notmatch 'TaskCreate reminder') { Pass 'F2(ps): leading TaskCreate-reminder preamble dropped' } else { Fail 'F2(ps): preamble leaked into Summary' }

    # Case 9b (F2 ack branch, twin parity with bash Case 1c/2): an uppercase +
    # trailing-whitespace bare acknowledgment leading line is dropped; the
    # substantive line surfaces. Exercises the PS bare-ack regex specifically.
    $f2Ts2 = Join-Path $huskProj 'transcript-f2b.jsonl'
    Set-Content -LiteralPath $f2Ts2 -Value @(
        '{"timestamp":"2026-06-17T02:22:00Z","type":"user","message":{"role":"user","content":"go"}}',
        '{"timestamp":"2026-06-17T02:22:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"OKAY.   \nWired the webhook retry path."}]}}'
    )
    Invoke-HookCustom -Transcript $f2Ts2 -VaultPath $huskVault -ProjPath $huskProj
    $f2Note2 = Notes (Join-Path $huskVault 'sessions') | Sort-Object LastWriteTime | Select-Object -Last 1
    $f2Sum2 = ''
    if ($f2Note2) {
        $inS = $false; $acc = @()
        foreach ($l in (Get-Content -LiteralPath $f2Note2.FullName)) {
            if ($l -eq '## Summary') { $inS = $true; continue }
            if ($inS -and ($l -match '^## ')) { break }
            if ($inS) { $acc += $l }
        }
        $f2Sum2 = ($acc -join "`n").Trim()
    }
    if ($f2Sum2 -match '^Wired the webhook retry path') { Pass 'F2(ps): leading uppercase/trailing-ws ack dropped (twin parity)' } else { Fail 'F2(ps): bare-ack branch did not drop the ack line' }

    # Case 10 (HIMMEL-663): unreadable crystallize_rules logs a warning with the
    # tilde-EXPANDED path (fail-open but not invisible).
    $rulesCfg = Join-Path $huskProj '.claude\end-session-wiki.json'
    Set-Content -LiteralPath $rulesCfg -Value '{"enabled":true,"crystallize_rules":"~/missing-rules.md"}'
    Invoke-HookCustom -Transcript $toolTs -VaultPath $huskVault -ProjPath $huskProj
    $rulesLog = Get-Content -LiteralPath (Join-Path $huskProj '.claude\end-session-wiki.log') -Raw -ErrorAction SilentlyContinue
    if ($rulesLog -match 'crystallize_rules not readable') { Pass 'rules(hook): unreadable crystallize_rules logged' } else { Fail 'rules(hook): unreadable crystallize_rules NOT logged' }
    $expandedMissing = Join-Path (Join-Path $SB 'home') 'missing-rules.md'
    if ($rulesLog -and $rulesLog.Contains($expandedMissing)) { Pass 'rules(hook): log carries the tilde-EXPANDED path' } else { Fail 'rules(hook): log missing the expanded path' }

    # Case 11 (HIMMEL-663): crystallize_rules plumbs through to the spawned
    # crystallizer — config parse -> ~/ expansion -> export -> across the
    # Start-Process boundary -> rules content lands in the claude prompt (argv).
    $rulesFile = Join-Path (Join-Path $SB 'home') 'rules-marker.md'
    Set-Content -LiteralPath $rulesFile -Value 'HOOK_RULES_MARKER'
    Set-Content -LiteralPath $rulesCfg -Value '{"enabled":true,"crystallize_rules":"~/rules-marker.md"}'
    $envd = Join-Path $huskProj 'envdump.txt'; $argvd = Join-Path $huskProj 'argv.txt'
    $env:STUB_MODE = 'success'; $env:CRYSTALLIZE_ENV_DUMP = $envd; $env:CRYSTALLIZE_ARGV_DUMP = $argvd
    Invoke-HookCustom -Transcript $toolTs -VaultPath $huskVault -ProjPath $huskProj
    $w = 0; while (-not (Test-Path $envd) -and $w -lt 60) { Start-Sleep -Milliseconds 100; $w++ }
    $env:STUB_MODE = 'noop'
    Remove-Item Env:\CRYSTALLIZE_ENV_DUMP -ErrorAction SilentlyContinue
    Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
    $envDump = Get-Content -LiteralPath $envd -Raw -ErrorAction SilentlyContinue
    if ($envDump -and $envDump.Contains("CRYSTALLIZE_RULES_FILE=$rulesFile")) { Pass 'rules(hook): stub saw CRYSTALLIZE_RULES_FILE at the expanded absolute path' } else { Fail 'rules(hook): CRYSTALLIZE_RULES_FILE did not reach the spawned crystallizer expanded' }
    $argvDump = Get-Content -LiteralPath $argvd -Raw -ErrorAction SilentlyContinue
    if ($argvDump -match 'HOOK_RULES_MARKER') { Pass 'rules(hook): rules content reached the claude prompt across the spawn boundary' } else { Fail 'rules(hook): rules content missing from the spawned prompt' }
    Remove-Item -LiteralPath $rulesCfg -Force -ErrorAction SilentlyContinue

    # Case 12 (HIMMEL-672): crystallize_model precedence — config supplies the
    # DEFAULT model; a CRYSTALLIZE_MODEL already set in the launching shell wins
    # (per-session operator switch). Twin of the .sh suite's Case 13.
    $modelCfg = Join-Path $huskProj '.claude\end-session-wiki.json'
    Set-Content -LiteralPath $modelCfg -Value '{"enabled":true,"crystallize_model":"cfg-pin-model"}'
    # 12a — env unset -> the config model reaches claude's argv.
    $argvdM = Join-Path $huskProj 'argv-model.txt'
    $env:STUB_MODE = 'success'; $env:CRYSTALLIZE_ARGV_DUMP = $argvdM
    Remove-Item Env:\CRYSTALLIZE_MODEL -ErrorAction SilentlyContinue
    Invoke-HookCustom -Transcript $toolTs -VaultPath $huskVault -ProjPath $huskProj
    $w = 0; while (-not (Test-Path $argvdM) -and $w -lt 60) { Start-Sleep -Milliseconds 100; $w++ }
    $argvLinesM = @(Get-Content -LiteralPath $argvdM -ErrorAction SilentlyContinue)
    if ($argvLinesM -contains 'arg=cfg-pin-model') { Pass 'model(hook): config crystallize_model reaches claude argv when env is unset' } else { Fail 'model(hook): config crystallize_model did NOT reach claude argv' }
    Remove-Item -LiteralPath $argvdM -Force -ErrorAction SilentlyContinue
    # 12b — env set in the launching shell -> env wins over the config model.
    $env:CRYSTALLIZE_MODEL = 'env-switch-model'
    Invoke-HookCustom -Transcript $toolTs -VaultPath $huskVault -ProjPath $huskProj
    $w = 0; while (-not (Test-Path $argvdM) -and $w -lt 60) { Start-Sleep -Milliseconds 100; $w++ }
    $env:STUB_MODE = 'noop'
    Remove-Item Env:\CRYSTALLIZE_MODEL -ErrorAction SilentlyContinue
    Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
    $argvLinesM = @(Get-Content -LiteralPath $argvdM -ErrorAction SilentlyContinue)
    if ($argvLinesM -contains 'arg=env-switch-model') { Pass 'model(hook): launching-shell CRYSTALLIZE_MODEL wins over config' } else { Fail 'model(hook): env CRYSTALLIZE_MODEL did not override the config model' }
    if ($argvLinesM -contains 'arg=cfg-pin-model') { Fail 'model(hook): config model leaked into argv despite env override' } else { Pass 'model(hook): config model correctly absent when env override is set' }
    Remove-Item -LiteralPath $modelCfg -Force -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $huskVault -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $huskProj  -Recurse -Force -ErrorAction SilentlyContinue

    $script:reached = $true
}
catch {
    if ($_.Exception.Message -ne 'skip') { throw }
}
finally {
    Remove-Item -LiteralPath $SB      -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StubDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $script:reached) { 'FAILED: test did not run to completion'; exit 1 }
if ($script:fails -eq 0) { 'ALL PASS'; exit 0 } else { "$($script:fails) FAILED"; exit 1 }
