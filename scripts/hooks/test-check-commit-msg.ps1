# Smoke test for scripts/hooks/check-commit-msg.ps1 (HIMMEL-1483).
# PowerShell twin of test-check-commit-msg.sh.
$ErrorActionPreference = 'Stop'
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

try {
    Expect-Rc 'default OFF keeps ticket optional' 0 'feat: add feature'
    Expect-Rc 'malformed conventional commit still rejects' 1 'not conventional'
    Expect-Rc 'strict Jira mode rejects missing ticket' 1 'feat: add feature' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    Expect-Rc 'strict Jira mode accepts PROJECT-N' 0 'feat: ACME-42 add feature' @{
        TICKET_ID_REQUIRED = '1'; JIRA_PROJECT_KEY = 'ACME'
    }
    Expect-Rc 'custom regex supports no-Jira #N tickets' 0 'fix: close #73' @{
        TICKET_ID_REQUIRED = '1'; TICKET_ID_PATTERN = '#[0-9]+'
    }
    Expect-Rc 'strict mode fails closed without any pattern' 1 'feat: add feature' @{
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
} finally {
    Remove-Item -LiteralPath $R -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) { Write-Host 'OK: all cases passed'; exit 0 }
Write-Host "FAIL: $($script:failures) case(s) failed"
exit 1
