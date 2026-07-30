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

# Log/marker relocated per-machine, OUTSIDE any repo (HIMMEL-1215): mirrors the
# hook's own $projectSlug derivation exactly (path separators/colon -> "-") so
# tests can compute the expected log/marker path for a given (USERPROFILE, proj).
function Get-EswSlug([string]$ProjDir) { return ($ProjDir -replace '[\\/:]', '-') }
function Get-EswLogPath([string]$HomeDir, [string]$ProjDir) {
    return (Join-Path $HomeDir ".claude\logs\end-session-wiki\$(Get-EswSlug $ProjDir).log")
}
function Get-EswMarkerPath([string]$HomeDir, [string]$ProjDir) {
    return (Join-Path $HomeDir ".claude\logs\end-session-wiki\$(Get-EswSlug $ProjDir).degraded")
}

$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $SB 'proj\.claude') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SB 'home\Documents\medic\.obsidian') -Force | Out-Null
$transcript = Join-Path $SB 'transcript.jsonl'
Set-Content -LiteralPath $transcript -Value '{"timestamp":"2026-06-17T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"l1\nl2"}]}}'
$cfgPath = Join-Path $SB 'proj\.claude\end-session-wiki.json'
$logPath = Get-EswLogPath -HomeDir (Join-Path $SB 'home') -ProjDir (Join-Path $SB 'proj')
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

    # Case 2b (HIMMEL-1215 CR): the relocated per-machine log dir + log file are
    # hardened owner-only — the Windows equivalent of the .sh twin's 0700/0600
    # (icacls /inheritance:r /grant:r <current-user>). dry_run logs + the degraded
    # note can carry raw transcript text (secrets), so no other local user may
    # read them. Assert inheritance is disabled AND the only principal is the
    # running user. (Cases 1–2 already ran the hook, so $logDir + $logPath exist.)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $logDirForAcl = Split-Path -Parent $logPath
    function Test-OwnerOnly([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $acl = Get-Acl -LiteralPath $Path
        if (-not $acl.AreAccessRulesProtected) { return $false }   # inheritance still on
        if ($acl.Access.Count -lt 1) { return $false }
        foreach ($r in $acl.Access) { if ($r.IdentityReference.Value -ne $me) { return $false } }
        return $true
    }
    if (Test-OwnerOnly $logDirForAcl) { Pass 'ACL: log dir owner-only (inheritance off, current user only)' } else { Fail 'ACL: log dir not hardened owner-only' }
    if (Test-OwnerOnly $logPath)      { Pass 'ACL: log file owner-only' } else { Fail 'ACL: log file not hardened owner-only' }

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
    $huskLog = Get-Content -LiteralPath (Get-EswLogPath -HomeDir (Join-Path $SB 'home') -ProjDir $huskProj) -Raw -ErrorAction SilentlyContinue
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
    $rulesLog = Get-Content -LiteralPath (Get-EswLogPath -HomeDir (Join-Path $SB 'home') -ProjDir $huskProj) -Raw -ErrorAction SilentlyContinue
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

    # Case 13 (HIMMEL-1345): a high-entropy operand is elided; surrounding
    # command/flag/path text and an unrelated ordinary command both survive.
    # Exact real-world shape that wedged the vault autosync: a GitHub GraphQL
    # global node ID copied verbatim tripped gitleaks' generic-api-key rule.
    # Own vault (not the shared $huskVault) so the note-selection in this case
    # and Case 14 can't collide on a LastWriteTime tie (twin parity with the
    # .sh suite's fresh sandbox per case).
    $elideVault = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-elide-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $elideVault -Force | Out-Null
    $elideTs = Join-Path $huskProj 'transcript-elide.jsonl'
    # The three secret-shaped fixture values below are assembled from concatenated
    # chunks at runtime, rather than written as single contiguous literals, so no
    # realistic-looking secret sits in tracked source (this repo's own gitleaks
    # pre-commit gate already passes on these fixtures as plain literals — this is
    # hygiene/futureproofing against EXTERNAL scanners, e.g. GitHub push
    # protection or a downstream/adopter gitleaks config, not a fix for a live
    # leak). The same variables are reused in the negative assertions below so the
    # fixture and the assertion can never drift apart. Twin of the .sh suite's
    # Case 15 TOK_GQL/TOK_KEY/TOK_B64.
    $TokGql = 'PRRT_k' + 'wDOS8W' + 'KNM6UP' + 'mnU'
    $TokKey = 'api-Live_8' + 'JxQ2mN7pR4' + 'vT9yW6cK1h' + 'F5dG0zB3uE'
    $TokB64 = 'AbCdEfGhIj' + 'KlMnOpQrSt' + 'UvWxYz0123' + '456789+/=='
    Set-Content -LiteralPath $elideTs -Value @(
        '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}',
        ('{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"resolved the thread"},{"type":"tool_use","name":"PowerShell","input":{"command":"gh api graphql -F threadId=\"' + $TokGql + '\" -F body=@\"C:/Users/op/note.md\""}},{"type":"tool_use","name":"PowerShell","input":{"command":"client --api-key ' + $TokKey + '"}},{"type":"tool_use","name":"PowerShell","input":{"command":"client --blob=' + $TokB64 + '"}},{"type":"tool_use","name":"PowerShell","input":{"command":"git status"}}]}}')
    )
    Invoke-HookCustom -Transcript $elideTs -VaultPath $elideVault -ProjPath $huskProj
    $elideNote = Notes (Join-Path $elideVault 'sessions') | Sort-Object LastWriteTime | Select-Object -Last 1
    $elideContent = if ($elideNote) { Get-Content -LiteralPath $elideNote.FullName -Raw } else { '' }
    if ($elideContent -match '<elided>') { Pass 'HIMMEL-1345: high-entropy operand elided' } else { Fail 'HIMMEL-1345: high-entropy operand was NOT elided' }
    if ($elideContent -notmatch [regex]::Escape($TokGql)) { Pass 'HIMMEL-1345: the raw high-entropy token does not appear in the note' } else { Fail 'HIMMEL-1345: the raw high-entropy token leaked into the note' }
    if ($elideContent -match [regex]::Escape('gh api graphql -F threadId="<elided>"')) { Pass 'HIMMEL-1345: program/subcommand/flag text survives around the elision' } else { Fail 'HIMMEL-1345: surrounding command text did not survive the scrub' }
    if (($elideContent -match [regex]::Escape('client --api-key <elided>')) -and ($elideContent -notmatch [regex]::Escape($TokKey))) { Pass 'HIMMEL-1345: API key containing a hyphen is elided' } else { Fail 'HIMMEL-1345: API key containing a hyphen leaked or lost surrounding text' }
    if (($elideContent -match [regex]::Escape('client --blob=<elided>')) -and ($elideContent -notmatch [regex]::Escape($TokB64))) { Pass 'HIMMEL-1345: base64 blob containing +, /, and = padding is elided' } else { Fail 'HIMMEL-1345: base64 blob containing +, /, and = padding leaked or lost surrounding text' }
    if ($elideContent -match 'git status') { Pass 'HIMMEL-1345: an unrelated ordinary command in the same session is untouched' } else { Fail 'HIMMEL-1345: an ordinary command in the same session was altered' }
    Remove-Item -LiteralPath $elideVault -Recurse -Force -ErrorAction SilentlyContinue

    # Case 14 (HIMMEL-1345): ordinary commands with no high-entropy operand are
    # unchanged. Negative case — a scrubber that elides everything would still
    # pass Case 13 alone. Uses a command with REPEATED internal spaces and a
    # spacing-sensitive quoted argument — a scrubber that unconditionally
    # splits-on-whitespace-and-rejoins-with-a-single-space (rather than only
    # rewriting a line that actually had a token elided) would silently
    # collapse both, passing this case vacuously. Own vault, see Case 13.
    $noElideVault = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-noelide-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $noElideVault -Force | Out-Null
    $noElideTs = Join-Path $huskProj 'transcript-noelide.jsonl'
    Set-Content -LiteralPath $noElideTs -Value @(
        '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}',
        '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"checked history"},{"type":"tool_use","name":"PowerShell","input":{"command":"git   log --oneline"}},{"type":"tool_use","name":"PowerShell","input":{"command":"git commit -m \"a  b\""}},{"type":"tool_use","name":"PowerShell","input":{"command":"deploy --dry-run --date 2026-07-29 /tmp/releases/2026-07-29/artifact https://example.com/releases/2026-07-29"}}]}}'
    )
    Invoke-HookCustom -Transcript $noElideTs -VaultPath $noElideVault -ProjPath $huskProj
    $noElideNote = Notes (Join-Path $noElideVault 'sessions') | Sort-Object LastWriteTime | Select-Object -Last 1
    $noElideContent = if ($noElideNote) { Get-Content -LiteralPath $noElideNote.FullName -Raw } else { '' }
    if ($noElideContent -notmatch '<elided>') { Pass 'HIMMEL-1345: ordinary commands pass through with no elision' } else { Fail 'HIMMEL-1345: an ordinary command was unexpectedly elided' }
    if (($noElideContent -match [regex]::Escape('git   log --oneline')) -and ($noElideContent -match [regex]::Escape('git commit -m "a  b"')) -and ($noElideContent -match [regex]::Escape('deploy --dry-run --date 2026-07-29 /tmp/releases/2026-07-29/artifact https://example.com/releases/2026-07-29'))) {
        Pass 'HIMMEL-1345: ordinary commands are byte-for-byte unchanged (spacing, dates, paths, URLs, and flags survive)'
    } else { Fail "HIMMEL-1345: an ordinary command's text was altered" }
    Remove-Item -LiteralPath $noElideVault -Recurse -Force -ErrorAction SilentlyContinue

    # Case 15 (HIMMEL-1345): single-case high-entropy tokens are NOT elided
    # (mixed-case gate negative coverage). Regression guard for THIS twin's
    # `-notmatch` -> `-cnotmatch` fix: case-insensitive `-notmatch` never
    # enforced mixed case at all, and no suite had a negative case here to
    # catch it shipping, or to catch it regressing back. Twin of the .sh
    # suite's Case 17 — see its comment for the full rationale.
    #
    # Each fixture below was verified offline against the awk is_opaque()
    # gate (identical logic to Test-OpaqueToken) to fail ONLY the mixed-case
    # check (length >=20, charset, and entropy >=3.8 all pass on their own)
    # — so the ONLY reason either survives is the mixed-case rule. Built
    # from concatenated chunks (twin of Case 13's TokGql/TokKey/TokB64) so
    # no secret-shaped literal sits in tracked source; the SAME variables
    # are reused in the fixture and the assertion so they cannot drift.
    $singleCaseVault = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-singlecase-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $singleCaseVault -Force | Out-Null
    $singleCaseTs = Join-Path $huskProj 'transcript-singlecase.jsonl'
    $TokHexLower = 'f3a9c81b4e' + '72d0f6a1c8' + '9b3e5d7a02' + 'c4f81b6e93'
    $TokScreamUpper = 'API_TOKEN_' + '9XQ2M7B4RT' + '6PLW3ZN8H5' + 'JC1FYD'
    Set-Content -LiteralPath $singleCaseTs -Value @(
        '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}',
        ('{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"checked hashes"},{"type":"tool_use","name":"PowerShell","input":{"command":"client --sha ' + $TokHexLower + '"}},{"type":"tool_use","name":"PowerShell","input":{"command":"client --env ' + $TokScreamUpper + '"}}]}}')
    )
    Invoke-HookCustom -Transcript $singleCaseTs -VaultPath $singleCaseVault -ProjPath $huskProj
    $singleCaseNote = Notes (Join-Path $singleCaseVault 'sessions') | Sort-Object LastWriteTime | Select-Object -Last 1
    $singleCaseContent = if ($singleCaseNote) { Get-Content -LiteralPath $singleCaseNote.FullName -Raw } else { '' }
    if ($singleCaseContent -match [regex]::Escape("client --sha $TokHexLower")) { Pass 'HIMMEL-1345: all-lowercase high-entropy token (hex-SHA shape) is NOT elided' } else { Fail 'HIMMEL-1345: all-lowercase high-entropy token was elided or altered' }
    if ($singleCaseContent -match [regex]::Escape("client --env $TokScreamUpper")) { Pass 'HIMMEL-1345: ALL-UPPERCASE/SCREAMING_SNAKE high-entropy token is NOT elided' } else { Fail 'HIMMEL-1345: ALL-UPPERCASE/SCREAMING_SNAKE high-entropy token was elided or altered' }
    Remove-Item -LiteralPath $singleCaseVault -Recurse -Force -ErrorAction SilentlyContinue

    # Case 16 (HIMMEL-1345): a STANDALONE padded base64 operand (no key=
    # prefix) is elided. Regression guard for the Get-ScrubbedWord key=value
    # mis-split bug: it used to find the FIRST "=" in a token and treat
    # everything before it as a "key=" prefix, testing ONLY the suffix for
    # opacity. A standalone padded base64 token's first "=" is its own
    # PADDING, so the tested suffix collapsed to "="/"==" -- too short to
    # ever clear the length gate -- and the secret leaked verbatim. Every
    # pre-existing fixture (TokB64 above) carries a genuine "--blob=" prefix,
    # which hid this. This case has NO key= prefix at all: the token appears
    # bare as a positional argument. Twin of the .sh suite's Case 18. Built
    # from concatenated chunks (twin of Case 13's TokGql/TokKey/TokB64) so no
    # secret-shaped literal sits in tracked source.
    $standaloneVault = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-standalone-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $standaloneVault -Force | Out-Null
    $standaloneTs = Join-Path $huskProj 'transcript-standalone.jsonl'
    $TokB64Standalone = 'QwErTyUiOp' + 'AsDfGhJkLz' + 'XcVbNm2468' + '013579+/=='
    Set-Content -LiteralPath $standaloneTs -Value @(
        '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}',
        ('{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pushed the blob"},{"type":"tool_use","name":"PowerShell","input":{"command":"client push ' + $TokB64Standalone + '"}},{"type":"tool_use","name":"PowerShell","input":{"command":"git config env=prod"}}]}}')
    )
    Invoke-HookCustom -Transcript $standaloneTs -VaultPath $standaloneVault -ProjPath $huskProj
    $standaloneNote = Notes (Join-Path $standaloneVault 'sessions') | Sort-Object LastWriteTime | Select-Object -Last 1
    $standaloneContent = if ($standaloneNote) { Get-Content -LiteralPath $standaloneNote.FullName -Raw } else { '' }
    if (($standaloneContent -match [regex]::Escape('client push <elided>')) -and ($standaloneContent -notmatch [regex]::Escape($TokB64Standalone))) {
        Pass 'HIMMEL-1345: standalone padded base64 operand (no key= prefix) is elided'
    } else { Fail 'HIMMEL-1345: standalone padded base64 operand leaked verbatim' }
    if ($standaloneContent -match [regex]::Escape('git config env=prod')) { Pass 'HIMMEL-1345: an ordinary short key=value word is untouched' } else { Fail 'HIMMEL-1345: an ordinary short key=value word was altered' }
    Remove-Item -LiteralPath $standaloneVault -Recurse -Force -ErrorAction SilentlyContinue

    # Case 17 (HIMMEL-1345, second round): a MIXED-CASE opaque prefix before a
    # non-padding "=" is elided whole (CodeRabbit finding). Case 16's
    # charset-only keypart gate is not enough on its own: it accepts ANY
    # alphanumeric prefix, so a standalone opaque token whose "=" sits
    # partway through on a non-padding boundary -- e.g.
    # "AbCdEfGhIjKlMnOpQrStUvWxYz=tail" -- is misread as
    # key="AbCdEfGhIjKlMnOpQrStUvWxYz" value="tail"; the short suffix again
    # never clears the length gate and the whole secret leaks. The fix reuses
    # Test-OpaqueToken on the keypart itself: a real key/flag/field name is
    # always too short to independently clear its own length gate (even a
    # camelCase one like the GraphQL "threadId" field, preserved by the
    # existing Case 13 fixture), so only a keypart that is itself opaque --
    # like this mixed-case, high-entropy one -- is rejected as a key, and the
    # WHOLE token is tested for opacity instead. Twin of the .sh suite's
    # Case 19. Built from concatenated chunks so no secret-shaped literal
    # sits in tracked source.
    $pocVault = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-poc-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $pocVault -Force | Out-Null
    $pocTs = Join-Path $huskProj 'transcript-poc.jsonl'
    $TokMixedPrefix = 'AbCdEfGhIj' + 'KlMnOpQrSt' + 'UvWxYz'
    $TokPoc = "$TokMixedPrefix=tail"
    Set-Content -LiteralPath $pocTs -Value @(
        '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}',
        ('{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"synced"},{"type":"tool_use","name":"PowerShell","input":{"command":"client sync ' + $TokPoc + '"}}]}}')
    )
    Invoke-HookCustom -Transcript $pocTs -VaultPath $pocVault -ProjPath $huskProj
    $pocNote = Notes (Join-Path $pocVault 'sessions') | Sort-Object LastWriteTime | Select-Object -Last 1
    $pocContent = if ($pocNote) { Get-Content -LiteralPath $pocNote.FullName -Raw } else { '' }
    if (($pocContent -match [regex]::Escape('client sync <elided>')) -and ($pocContent -notmatch [regex]::Escape('<elided>=tail')) -and ($pocContent -notmatch [regex]::Escape($TokPoc)) -and ($pocContent -notmatch [regex]::Escape($TokMixedPrefix))) {
        Pass 'HIMMEL-1345: mixed-case opaque prefix before a non-padding = is elided whole'
    } else { Fail 'HIMMEL-1345: mixed-case opaque prefix before a non-padding = leaked verbatim' }
    Remove-Item -LiteralPath $pocVault -Recurse -Force -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $huskVault -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $huskProj  -Recurse -Force -ErrorAction SilentlyContinue

    # ---- 401 multi-vault retry cases (HIMMEL-711) ----------------------------
    # A 401 from the target vault's key must trigger discovery of the operator's
    # OTHER vault keys and a retry. The network is stubbed via ESW_PUT_CMD (no
    # real Invoke-RestMethod / no real Obsidian); USERPROFILE is sandboxed so
    # only the two fake vaults are discovered.
    $mvHome = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-mv-" + [guid]::NewGuid().ToString('N'))
    $mvProj = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-mvp-" + [guid]::NewGuid().ToString('N'))
    $vaultA = Join-Path $mvHome 'Documents\vaultA'
    $vaultB = Join-Path $mvHome 'Documents\vaultB'
    New-Item -ItemType Directory -Path (Join-Path $vaultA '.obsidian\plugins\obsidian-local-rest-api') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $vaultB '.obsidian\plugins\obsidian-local-rest-api') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mvProj '.claude') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $vaultA '.obsidian\plugins\obsidian-local-rest-api\data.json') -Value '{"apiKey":"primary-key-A"}'
    Set-Content -LiteralPath (Join-Path $vaultB '.obsidian\plugins\obsidian-local-rest-api\data.json') -Value '{"apiKey":"sibling-key-B"}'
    # PUT stub: args = <key> <uri>; echoes 200 only for the OK key, else 401.
    $putStub = Join-Path $mvProj 'put-stub.ps1'
    Set-Content -LiteralPath $putStub -Value 'param([string]$Key,[string]$Uri); if ($Key -eq $env:ESW_STUB_OK_KEY) { "200" } else { "401" }'
    $mvTs = Join-Path $mvProj 'transcript.jsonl'
    Set-Content -LiteralPath $mvTs -Value '{"timestamp":"2026-06-17T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"l1\nl2"}]}}'
    $mvLog = Get-EswLogPath -HomeDir $mvHome -ProjDir $mvProj

    function Invoke-HookMV {
        param([string]$OkKey)
        $pl = @{ transcript_path = $mvTs; cwd = $mvProj; session_id = 't'; reason = 'other' } | ConvertTo-Json -Compress
        $env:USERPROFILE = $mvHome
        $env:CLAUDE_PROJECT_DIR = $mvProj
        $env:OBSIDIAN_API_KEY = ''
        $env:LUNA_VAULT_PATH = $vaultA
        $env:ESW_PUT_CMD = $putStub
        $env:ESW_STUB_OK_KEY = $OkKey
        $pl | pwsh -NoProfile -File $HOOK | Out-Null
        Remove-Item Env:\ESW_PUT_CMD -ErrorAction SilentlyContinue
        Remove-Item Env:\ESW_STUB_OK_KEY -ErrorAction SilentlyContinue
    }

    # Case 13: a sibling vault's key recovers the 401.
    Remove-Item -LiteralPath $mvLog -ErrorAction SilentlyContinue
    # Seed a STALE degradation marker: a healthy recovery PUT must clear it (the
    # self-healing half of the loud flag — prevents a permanent false banner).
    $marker13 = Get-EswMarkerPath -HomeDir $mvHome -ProjDir $mvProj
    New-Item -ItemType Directory -Path (Split-Path -Parent $marker13) -Force | Out-Null
    Set-Content -LiteralPath $marker13 -Value 'stale DEGRADED marker from a prior session'
    Invoke-HookMV -OkKey 'sibling-key-B'
    $log13 = Get-Content -LiteralPath $mvLog -Raw -ErrorAction SilentlyContinue
    if ($log13 -match 'recovered with a sibling vault key') { Pass '401-retry(ps): recovered via a sibling vault key' } else { Fail '401-retry(ps): did not recover via a sibling key' }
    if (($log13 -match '(?m) wrote sessions/') -and ($log13 -notmatch 'local fs fallback')) { Pass '401-retry(ps): took the REST success path (no disk fallback)' } else { Fail '401-retry(ps): fell back to disk instead of recovering' }
    if (-not (Test-Path -LiteralPath $marker13)) { Pass '401-retry(ps): healthy recovery PUT cleared the stale degradation marker' } else { Fail '401-retry(ps): stale degradation marker survived a healthy recovery PUT' }
    if ($log13 -match 'sibling-key-B|primary-key-A') { Fail '401-retry(ps): an apiKey value leaked into the log' } else { Pass '401-retry(ps): no apiKey value in the log (redaction holds)' }

    # Case 14: no vault key accepted (all 401) -> on-disk fallback preserved.
    Remove-Item -LiteralPath $mvLog -ErrorAction SilentlyContinue
    Get-ChildItem -Path (Join-Path $vaultA 'sessions') -Recurse -Filter *.md -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Invoke-HookMV -OkKey 'no-such-key'
    $log14 = Get-Content -LiteralPath $mvLog -Raw -ErrorAction SilentlyContinue
    $mvNote = Get-ChildItem -Path (Join-Path $vaultA 'sessions') -Recurse -Filter *.md -ErrorAction SilentlyContinue | Select-Object -First 1
    if (($log14 -match 'local fs fallback') -and $mvNote) { Pass '401-retry(ps): all keys 401 -> on-disk fallback preserved' } else { Fail '401-retry(ps): all-keys-401 did not fall back to disk' }
    # The loud degradation flag (HIMMEL-711): a persisted marker must be written so
    # a SessionStart / where-are-we surface can pick up the silent-disk fallback.
    $marker14 = Get-EswMarkerPath -HomeDir $mvHome -ProjDir $mvProj
    if ((Test-Path -LiteralPath $marker14) -and ((Get-Content -LiteralPath $marker14 -Raw) -match 'DEGRADED')) { Pass '401-retry(ps): degradation marker persisted on disk-only fallback' } else { Fail '401-retry(ps): no degradation marker written on disk-only fallback' }
    # HIMMEL-1215 CR: the degraded marker is ALSO owner-only hardened + written
    # UTF-8 no-BOM — the text-only check above would pass even if protection
    # failed or a BOM were reintroduced, so assert both explicitly.
    if (Test-OwnerOnly $marker14) { Pass 'ACL: degraded marker owner-only' } else { Fail 'ACL: degraded marker not hardened owner-only' }
    $marker14Bytes = [System.IO.File]::ReadAllBytes($marker14)
    if ($marker14Bytes.Length -ge 3 -and $marker14Bytes[0] -eq 0xEF -and $marker14Bytes[1] -eq 0xBB -and $marker14Bytes[2] -eq 0xBF) {
        Fail 'encoding: degraded marker has a UTF-8 BOM (EF BB BF)'
    } else { Pass 'encoding: degraded marker is UTF-8 no-BOM' }
    # Redaction (hard requirement): no apiKey value in the log OR the marker.
    $blob14 = "$log14`n$(Get-Content -LiteralPath $marker14 -Raw -ErrorAction SilentlyContinue)"
    if ($blob14 -match 'primary-key-A') { Fail '401-retry(ps): an apiKey value leaked into the log/marker on fallback' } else { Pass '401-retry(ps): no apiKey value in the log or marker (redaction holds)' }

    Remove-Item -LiteralPath $mvHome -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mvProj -Recurse -Force -ErrorAction SilentlyContinue

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
