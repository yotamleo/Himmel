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
        $skipPattern = '^(date:|worktree:|duration_minutes:|session_id:|source:)'
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
