# Smoke test for scripts/hooks/check-commit-msg.ps1 (HIMMEL-1483).
# PowerShell twin of test-check-commit-msg.sh.
$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$SCRIPT = Join-Path $PSScriptRoot 'check-commit-msg.ps1'
$R = Join-Path ([System.IO.Path]::GetTempPath()) ('cm-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $R -Force | Out-Null
& git -C $R init -q
& git -C $R config user.email 't@t'
& git -C $R config user.name 't'
$MSG = Join-Path $R 'COMMIT_MSG'
$script:failures = 0

function Invoke-Gate {
    param([string]$Message, [hashtable]$Env = @{})
    Set-Content -LiteralPath $MSG -Value $Message -NoNewline
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($SCRIPT)
    $psi.ArgumentList.Add($MSG)
    $psi.WorkingDirectory = $R
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($key in @('TICKET_ID_REQUIRED','TICKET_ID_PATTERN','TICKET_ID_EXEMPT_AUTHORS','TICKET_ID_AUTHOR','TICKET_ID_TRUSTED_AUTHOR','JIRA_PROJECT_KEY')) {
        $psi.Environment.Remove($key)
    }
    foreach ($key in $Env.Keys) { $psi.Environment[$key] = $Env[$key] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    [void]$proc.StandardOutput.ReadToEnd()
    [void]$proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Expect-Rc {
    param([string]$Name, [int]$Want, [string]$Message, [hashtable]$Env = @{})
    $rc = Invoke-Gate -Message $Message -Env $Env
    if ($rc -eq $Want) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name (rc=$rc, want $Want)"; $script:failures++ }
}

# HIMMEL-2183: WARN-only negative-existence claim linter. Never blocks — rc
# must match what the case would get without the linter.
function Invoke-GateCaptured {
    param([string]$Message, [hashtable]$Env = @{})
    Set-Content -LiteralPath $MSG -Value $Message -NoNewline
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($SCRIPT)
    $psi.ArgumentList.Add($MSG)
    $psi.WorkingDirectory = $R
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($key in @('TICKET_ID_REQUIRED','TICKET_ID_PATTERN','TICKET_ID_EXEMPT_AUTHORS','TICKET_ID_AUTHOR','TICKET_ID_TRUSTED_AUTHOR','JIRA_PROJECT_KEY')) {
        $psi.Environment.Remove($key)
    }
    foreach ($key in $Env.Keys) { $psi.Environment[$key] = $Env[$key] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ ExitCode = $proc.ExitCode; Output = "$stdout$stderr" }
}

function Expect-Warn {
    param([string]$Name, [int]$WantRc, [bool]$WantWarn, [string]$Message, [hashtable]$Env = @{})
    $result = Invoke-GateCaptured -Message $Message -Env $Env
    $hasWarn = $result.Output -match 'WARN'
    if ($result.ExitCode -eq $WantRc -and $hasWarn -eq $WantWarn) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name (rc=$($result.ExitCode) want $WantRc; warn=$hasWarn want $WantWarn)"; $script:failures++ }
}

try {
    # HIMMEL-2442: the gate is ON by default, and with no ticket system
    # configured the pattern is himmel's own `#N` enumeration.
    Expect-Rc 'default ON rejects a ticketless message (adopter defaults)' 1 'chore: no ticket id here'
    Expect-Rc 'default ON accepts #N' 0 'chore: [#12] wire the thing'
    # CR2: the default #N pattern must not match inside a longer token, and must
    # still accept every shape the rejection message tells adopters to use.
    Expect-Rc 'default ON rejects #N inside a longer token (CSS colour)' 1 'chore: use #123abc for the border'
    Expect-Rc 'default ON accepts a bracketed #N' 0 'chore: [#12] wire the thing'
    Expect-Rc 'default ON accepts a trailing-colon #N' 0 'chore: #12: wire the thing'
    Expect-Rc 'default ON accepts a bare #N at end of subject' 0 'chore: wire the thing #12'
    Expect-Rc 'Jira posture does not accept bare #N' 1 'chore: [#12] wire the thing' @{
        JIRA_PROJECT_KEY = 'HIMMEL'
    }
    Expect-Rc 'Jira posture accepts PROJECT-N without TICKET_ID_REQUIRED' 0 'chore: HIMMEL-2442 wire the thing' @{
        JIRA_PROJECT_KEY = 'HIMMEL'
    }
    Expect-Rc 'explicit opt-out keeps ticket optional' 0 'feat: add feature' @{
        TICKET_ID_REQUIRED = '0'
    }
    # CR3 twin parity: `switch -Regex` here is case-insensitive by default, and
    # the .sh twin now normalizes case to match. The same three cases exist in
    # test-check-commit-msg.sh; they must agree.
    Expect-Rc 'mixed-case False opts out (twin parity)' 0 'feat: add feature' @{
        TICKET_ID_REQUIRED = 'False'
    }
    Expect-Rc 'mixed-case True still requires a ticket (twin parity)' 1 'feat: add feature' @{
        TICKET_ID_REQUIRED = 'True'
    }
    Expect-Rc 'mixed-case True accepts a ticketed message (twin parity)' 0 'feat: [#12] add feature' @{
        TICKET_ID_REQUIRED = 'True'
    }
    Expect-Rc 'an unrecognised TICKET_ID_REQUIRED fails closed' 1 'feat: [#12] add feature' @{
        TICKET_ID_REQUIRED = 'maybe'
    }
    Expect-Rc 'malformed conventional commit still rejects' 1 'not conventional'
    # Positive control: garbage is rejected in EVERY posture, so a rejection
    # above is a ticket verdict rather than the shape check firing for both arms.
    Expect-Rc 'garbage rejected under explicit opt-out' 1 'not conventional' @{
        TICKET_ID_REQUIRED = '0'
    }
    Expect-Rc 'garbage rejected under Jira posture' 1 'not conventional' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    Expect-Rc 'strict Jira mode rejects missing ticket' 1 'feat: add feature' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    Expect-Rc 'strict Jira mode accepts PROJECT-N' 0 'feat: ACME-42 add feature' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    Expect-Rc 'custom regex supports no-Jira #N tickets' 0 'fix: close #73' @{
        TICKET_ID_REQUIRED = '1'; TICKET_ID_PATTERN = '#[0-9]+'
    }
    # HIMMEL-2442: no configured pattern is no longer a configuration error — it
    # is the `#N` posture, so a ticketless message still fails and an #N one passes.
    Expect-Rc 'no configured pattern falls back to #N and rejects' 1 'feat: add feature' @{
        TICKET_ID_REQUIRED = '1'
    }
    Expect-Rc 'no configured pattern falls back to #N and accepts' 0 'feat: [#7] add feature' @{
        TICKET_ID_REQUIRED = '1'
    }
    Expect-Rc 'invalid custom regex fails closed' 1 'feat: [ add feature' @{
        TICKET_ID_REQUIRED = '1'; TICKET_ID_PATTERN = '['
    }
    Expect-Rc 'fake merge subject is not exempt' 1 "Merge branch 'main'" @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    Expect-Rc 'bare revert subject is not exempt' 1 'Revert "feat: add feature"' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    # HIMMEL-1483 CR1: revert exemption now requires the reverted hash to resolve
    # to a real commit. Seed one and use its SHA for the positive case; a
    # fabricated hash must fall through and be rejected in strict mode.
    & git -C $R commit -q --allow-empty -m 'feat: add feature'
    $revertedSha = (& git -C $R rev-parse HEAD).Trim()
    Expect-Rc 'Git-generated revert of a real commit is exempt' 0 "Revert `"feat: add feature`"`n`nThis reverts commit $revertedSha." @{
        TICKET_ID_REQUIRED = '1'
    }
    Expect-Rc 'fabricated-hash revert shape falls through and is rejected' 1 "Revert `"feat: add feature`"`n`nThis reverts commit 0123456789abcdef0123456789abcdef01234567." @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }

    $baseBranch = (& git -C $R symbolic-ref --short HEAD).Trim()
    Set-Content -LiteralPath (Join-Path $R 'file') -Value 'base' -NoNewline
    & git -C $R add file
    & git -C $R commit -q -m base
    & git -C $R checkout -q -b side
    Set-Content -LiteralPath (Join-Path $R 'file') -Value 'side' -NoNewline
    & git -C $R commit -q -am side
    & git -C $R checkout -q $baseBranch
    Set-Content -LiteralPath (Join-Path $R 'file') -Value 'main' -NoNewline
    & git -C $R commit -q -am main
    & git -C $R merge side *> $null
    Expect-Rc 'real merge is exempt' 0 "Merge branch 'side'" @{
        TICKET_ID_REQUIRED = '1'
    }
    & git -C $R merge --abort

    Expect-Rc 'dependabot author is exempt locally' 0 'chore: bump dependency' @{
        TICKET_ID_REQUIRED = '1'; TICKET_ID_AUTHOR = 'dependabot[bot]'
    }
    Expect-Rc 'trusted human blocks spoofed bot author' 1 'chore: bump dependency' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'; TICKET_ID_AUTHOR = 'dependabot[bot]'; TICKET_ID_TRUSTED_AUTHOR = 'human'
    }
    Expect-Rc 'trusted bot and bot author are exempt' 0 'chore: bump dependency' @{
        TICKET_ID_REQUIRED = '1'; TICKET_ID_AUTHOR = 'dependabot[bot]'; TICKET_ID_TRUSTED_AUTHOR = 'dependabot[bot]'
    }
    Expect-Rc 'custom author exemption list is data-driven' 0 'chore: generated update' @{
        TICKET_ID_REQUIRED = '1'; TICKET_ID_AUTHOR = 'release-bot'; TICKET_ID_EXEMPT_AUTHORS = 'release-bot'
    }
    Expect-Rc 'fixup without ticket rejects in strict mode' 1 'fixup! feat: add feature' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    Expect-Rc 'fixup carrying ticket passes strict mode' 0 'fixup! feat: ACME-42 add feature' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }

    "TICKET_ID_REQUIRED=1`nJIRA_PROJECT_KEY=ENVKEY`n" | Set-Content -LiteralPath (Join-Path $R '.env') -NoNewline
    Expect-Rc 'primary .env supplies strict mode and Jira key' 0 'docs: ENVKEY-9 update docs'
    Expect-Rc 'live env overrides the primary .env' 0 'docs: no ticket needed' @{
        TICKET_ID_REQUIRED = '0'
    }
    Remove-Item -LiteralPath (Join-Path $R '.env') -ErrorAction SilentlyContinue

    # HIMMEL-2462: a trailing comment on JIRA_PROJECT_KEY must be stripped, not
    # folded into the ticket pattern (the impossible `HIMMEL # default-\d+`).
    "TICKET_ID_REQUIRED=1`nJIRA_PROJECT_KEY=HIMMEL # default project`n" | Set-Content -LiteralPath (Join-Path $R '.env') -NoNewline
    Expect-Rc '.env value with trailing comment still accepts HIMMEL-N' 0 'docs: HIMMEL-123 update docs'
    Expect-Rc '.env value with trailing comment still rejects a ticketless message' 1 'docs: no ticket here'
    Remove-Item -LiteralPath (Join-Path $R '.env') -ErrorAction SilentlyContinue

    # TICKET_ID_REQUIRED=0 keeps these focused on the linter: the ticket gate is
    # ON by default (HIMMEL-2442) and would otherwise decide rc for these messages.
    Expect-Warn 'bare negative claim warns, rc unchanged' 0 $true "feat: add feature`n`nWe don't have this handled yet." @{ TICKET_ID_REQUIRED = '0' }
    Expect-Warn 'claim with adjacent path evidence is silent' 0 $false "feat: add feature`n`nWe don't have this handled yet.`nSee scripts/hooks/check-commit-msg.ps1 for details." @{ TICKET_ID_REQUIRED = '0' }
    Expect-Warn 'no claim is silent' 0 $false "feat: add feature`n`nEverything here works as expected." @{ TICKET_ID_REQUIRED = '0' }

    $missingPath = Join-Path $R 'no-such-commit-msg-file'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command pwsh).Source
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-NonInteractive')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($SCRIPT)
    $psi.ArgumentList.Add($missingPath)
    $psi.WorkingDirectory = $R
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($key in @('TICKET_ID_REQUIRED','TICKET_ID_PATTERN','TICKET_ID_EXEMPT_AUTHORS','TICKET_ID_AUTHOR','TICKET_ID_TRUSTED_AUTHOR','JIRA_PROJECT_KEY')) {
        [void]$psi.Environment.Remove($key)
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    # HIMMEL-2461: a missing commit-msg file must fail CLOSED with a named
    # rejection (the .sh twin's assertion flipped the same way) — the old
    # fail-open assertion here matched the vacuous guard that let a stray
    # commit slip through on every real invocation. The HIMMEL-2183 linter
    # stays silent (no WARN) since it never got a message to scan.
    $malformedOutput = "$stdout$stderr"
    if ($proc.ExitCode -ne 0 -and ($malformedOutput -match 'COMMIT REJECTED') -and -not ($malformedOutput -match 'WARN')) {
        Write-Host '  PASS  malformed input (missing commit-msg file) fails CLOSED'
    } else {
        Write-Host "  FAIL  malformed input (missing commit-msg file) fails CLOSED (rc=$($proc.ExitCode), rejected-present=$($malformedOutput -match 'COMMIT REJECTED'), warn-present=$($malformedOutput -match 'WARN'))"
        $script:failures++
    }

    # codex-1 (CR round 2): Test-Path with no -PathType Leaf is true for a
    # DIRECTORY, so a $1 that resolves to one used to sail past the guard into
    # Get-Content, which errored non-terminating and left $msg empty — the
    # empty-message path then exits 0, recreating the vacuous gate. $R itself
    # is a directory, so it doubles as the fixture here.
    $psiDir = [System.Diagnostics.ProcessStartInfo]::new()
    $psiDir.FileName = (Get-Command pwsh).Source
    $psiDir.ArgumentList.Add('-NoProfile')
    $psiDir.ArgumentList.Add('-NonInteractive')
    $psiDir.ArgumentList.Add('-File')
    $psiDir.ArgumentList.Add($SCRIPT)
    $psiDir.ArgumentList.Add($R)
    $psiDir.WorkingDirectory = $R
    $psiDir.RedirectStandardOutput = $true
    $psiDir.RedirectStandardError = $true
    $psiDir.UseShellExecute = $false
    foreach ($key in @('TICKET_ID_REQUIRED','TICKET_ID_PATTERN','TICKET_ID_EXEMPT_AUTHORS','TICKET_ID_AUTHOR','TICKET_ID_TRUSTED_AUTHOR','JIRA_PROJECT_KEY')) {
        [void]$psiDir.Environment.Remove($key)
    }
    $procDir = [System.Diagnostics.Process]::Start($psiDir)
    $stdoutDir = $procDir.StandardOutput.ReadToEnd()
    $stderrDir = $procDir.StandardError.ReadToEnd()
    $procDir.WaitForExit()
    $dirOutput = "$stdoutDir$stderrDir"
    if ($procDir.ExitCode -ne 0 -and ($dirOutput -match 'COMMIT REJECTED')) {
        Write-Host '  PASS  a $1 naming a directory fails CLOSED'
    } else {
        Write-Host "  FAIL  a `$1 naming a directory fails CLOSED (rc=$($procDir.ExitCode), rejected-present=$($dirOutput -match 'COMMIT REJECTED'))"
        $script:failures++
    }

    # CR3: the .sh twin asserts against the REAL primary .env, and this suite had
    # only synthetic fixtures — so a regression in Import-TicketConfig (a separate
    # reimplementation of the .env resolution, not a call into load-dotenv.sh)
    # could ship on Windows unseen. Same posture gate as the .sh twin: run only
    # when JIRA_PROJECT_KEY is genuinely the pattern in force, because
    # TICKET_ID_PATTERN outranks it and TICKET_ID_REQUIRED=0 disables the ticket
    # half — asserting under either would fail on a SUPPORTED configuration.
    function Get-PrimaryPosture {
        $wanted = @{ 'JIRA_PROJECT_KEY' = 'Key'; 'TICKET_ID_PATTERN' = 'Pattern'; 'TICKET_ID_REQUIRED' = 'Required' }
        # CR4: seed from the PROCESS environment first, then let .env fill only
        # what is still empty. The earlier version read process overrides only
        # for keys it happened to encounter IN the file, so a process-only
        # TICKET_ID_PATTERN or TICKET_ID_REQUIRED=0 — both supported by the hook
        # — was invisible to the detector, which then classified the posture as
        # Jira-driven and asserted against a hook that was behaving correctly.
        # This ordering is also what Import-TicketConfig does (it writes a key
        # only when the process value is empty), so detector and hook agree.
        $posture = @{ Key = ''; Pattern = ''; Required = '' }
        foreach ($name in $wanted.Keys) {
            $live = [System.Environment]::GetEnvironmentVariable($name, 'Process')
            if (-not [string]::IsNullOrEmpty($live)) { $posture[$wanted[$name]] = $live }
        }
        Push-Location $PSScriptRoot
        try {
            $commonDir = & git rev-parse --git-common-dir 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $commonDir) { return $posture }
            if (-not [System.IO.Path]::IsPathRooted($commonDir)) {
                $commonDir = Join-Path (Get-Location) $commonDir
            }
            $envFile = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $commonDir '..'))) '.env'
            if (-not (Test-Path -LiteralPath $envFile)) { return $posture }
            foreach ($line in Get-Content -LiteralPath $envFile) {
                $trimmed = $line.Trim().TrimEnd("`r")
                if (-not $trimmed -or $trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) { continue }
                $sep = $trimmed.IndexOf('=')
                $key = $trimmed.Substring(0, $sep).Trim()
                if (-not $wanted.ContainsKey($key)) { continue }
                if ($posture[$wanted[$key]]) { continue }   # process env already won
                $posture[$wanted[$key]] = $trimmed.Substring($sep + 1).Trim()
            }
        } finally { Pop-Location }
        return $posture
    }

    $posture = Get-PrimaryPosture
    $jiraDriven = $posture.Key -and -not $posture.Pattern -and ($posture.Required -notmatch '^(0|false|off|no)$')
    if ($jiraDriven) {
        # cwd inside the repo, and NO env stripping — the point is the real posture.
        function Invoke-GateRepoPosture {
            param([string]$Message)
            Set-Content -LiteralPath $MSG -Value $Message -NoNewline
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = (Get-Command pwsh).Source
            $psi.ArgumentList.Add('-NoProfile')
            $psi.ArgumentList.Add('-NonInteractive')
            $psi.ArgumentList.Add('-File')
            $psi.ArgumentList.Add($SCRIPT)
            $psi.ArgumentList.Add($MSG)
            $psi.WorkingDirectory = $PSScriptRoot
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            [void]$proc.StandardOutput.ReadToEnd()
            [void]$proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            return $proc.ExitCode
        }
        $rc = Invoke-GateRepoPosture "chore: $($posture.Key)-2442 real posture"
        if ($rc -eq 0) { Write-Host "  PASS  this repo's real .env posture still accepts $($posture.Key)-N" }
        else { Write-Host "  FAIL  this repo's real .env posture still accepts $($posture.Key)-N (rc=$rc, want 0)"; $script:failures++ }
        $rc = Invoke-GateRepoPosture 'chore: no ticket id here'
        if ($rc -eq 1) { Write-Host "  PASS  this repo's real .env posture still rejects a ticketless message" }
        else { Write-Host "  FAIL  this repo's real .env posture still rejects a ticketless message (rc=$rc, want 1)"; $script:failures++ }
    } else {
        Write-Host '  SKIP  primary .env is not JIRA_PROJECT_KEY-driven (no key, or TICKET_ID_PATTERN / TICKET_ID_REQUIRED=0 overrides it)'
    }
} finally {
    Remove-Item -LiteralPath $R -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) { Write-Host 'OK: all cases passed'; exit 0 }
Write-Host "FAIL: $($script:failures) case(s) failed"
exit 1
