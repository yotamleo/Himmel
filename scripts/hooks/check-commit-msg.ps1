# Windows PowerShell equivalent of check-commit-msg.sh
# Called by Git on Windows when bash is unavailable.
# Usage: git config core.hooksPath scripts/hooks (then Git calls .ps1 on Windows)
# Note: pre-commit framework uses the .sh version via Git Bash — this is a fallback.

param([string]$CommitMsgFile = $env:GIT_COMMIT_MSG_FILE)

if (-not $CommitMsgFile) { $CommitMsgFile = $args[0] }
if (-not $CommitMsgFile -or -not (Test-Path $CommitMsgFile)) {
    Write-Error "No commit message file provided."
    exit 1
}

$msg = Get-Content $CommitMsgFile -Raw

function Import-TicketConfig {
    $commonDir = & git rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $commonDir) { return }
    if (-not [System.IO.Path]::IsPathRooted($commonDir)) {
        $commonDir = Join-Path (Get-Location) $commonDir
    }
    $root = [System.IO.Path]::GetFullPath((Join-Path $commonDir '..'))
    $envFile = Join-Path $root '.env'
    if (-not (Test-Path -LiteralPath $envFile)) { return }

    $wanted = @('TICKET_ID_REQUIRED','TICKET_ID_PATTERN','TICKET_ID_EXEMPT_AUTHORS','JIRA_PROJECT_KEY')
    foreach ($line in Get-Content -LiteralPath $envFile) {
        $trimmed = $line.Trim().TrimEnd("`r")
        if (-not $trimmed -or $trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) { continue }
        $separator = $trimmed.IndexOf('=')
        $key = $trimmed.Substring(0, $separator).Trim()
        if ($wanted -notcontains $key) { continue }
        if ([string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable($key, 'Process'))) {
            $value = $trimmed.Substring($separator + 1).Trim()
            [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }
}

Import-TicketConfig

# Skip real merge commits. MERGE_HEAD exists while Git is composing the commit.
$mergeHead = & git rev-parse -q --verify MERGE_HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $mergeHead) { exit 0 }

$firstLine = (($msg -split "`n")[0]).TrimEnd("`r")

# Git-generated revert commits are exempt from both checks. fixup/squash retain
# their generated shape, but strict mode still requires the referenced ticket.
# HIMMEL-1483 CR1: the reverted hash must resolve to a real commit object
# (git cat-file -e <hash>^{commit}); a revert-shaped MESSAGE alone is not
# enough, or a hand-typed revert with a fabricated hash bypasses both checks.
# On resolution failure fall through to normal validation.
$generatedRevert = $false
if ($firstLine -match '^Revert ".+"$') {
    if ($msg -match '(?m)^This reverts commit (?<hash>[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\.$') {
        $revertedHash = $Matches['hash']
        & git cat-file -e "$revertedHash^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) { $generatedRevert = $true }
    }
}
if ($generatedRevert) { exit 0 }
$skipConventional = $firstLine -match '^(fixup!|squash!)'

# Skip empty or comment-only messages.
$meaningful = ($msg -split "`r?`n") | Where-Object { $_ -notmatch '^#' -and $_ -match '\S' }
if (-not $meaningful) { exit 0 }

# Validate conventional commit
$pattern = '^(feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert)(\([^)]+\))?!?:\s+\S.+'
if (-not $skipConventional -and $firstLine -notmatch $pattern) {
    Write-Host ""
    Write-Host "COMMIT REJECTED: message does not match conventional commit format."
    Write-Host ""
    Write-Host "  Required:  type(scope): message"
    Write-Host "  Ticket:    required only when TICKET_ID_REQUIRED=1"
    Write-Host ""
    Write-Host "  Types: feat fix chore docs refactor test style perf ci build revert"
    Write-Host ""
    Write-Host "  Examples:"
    Write-Host "    feat(auth): add JWT validation"
    Write-Host "    fix(api): PROJECT-23 correct status code on 404"
    Write-Host "    chore: update dependencies"
    Write-Host ""
    Write-Host "  Got: $firstLine"
    Write-Host ""
    exit 1
}

$requiredValue = if ($env:TICKET_ID_REQUIRED) { $env:TICKET_ID_REQUIRED } else { '0' }
switch -Regex ($requiredValue) {
    '^(|0|false|off|no)$' { exit 0 }
    '^(1|true|on|yes)$'   { break }
    default {
        Write-Error "COMMIT REJECTED: invalid TICKET_ID_REQUIRED='$requiredValue'. Use 1/true/on/yes or 0/false/off/no."
        exit 1
    }
}

$authorName = $env:TICKET_ID_AUTHOR
if (-not $authorName) { $authorName = $env:GIT_AUTHOR_NAME }
if (-not $authorName) {
    $authorIdent = & git var GIT_AUTHOR_IDENT 2>$null
    if ($authorIdent -match '^(.*?)\s+<') { $authorName = $Matches[1] }
}
$exemptAuthors = if ($env:TICKET_ID_EXEMPT_AUTHORS) { $env:TICKET_ID_EXEMPT_AUTHORS } else { 'dependabot[bot],dependabot' }
$trustedAuthor = [System.Environment]::GetEnvironmentVariable('TICKET_ID_TRUSTED_AUTHOR', 'Process')
$trustedAuthorSet = $null -ne $trustedAuthor
$authorExempt = $false
$trustedAuthorExempt = $false
foreach ($exemptAuthor in ($exemptAuthors -split ',')) {
    $candidate = $exemptAuthor.Trim()
    if ($candidate -and $candidate.Equals($authorName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $authorExempt = $true
    }
    if ($candidate -and $trustedAuthor -and $candidate.Equals($trustedAuthor, [System.StringComparison]::OrdinalIgnoreCase)) {
        $trustedAuthorExempt = $true
    }
}
if ($authorExempt -and (-not $trustedAuthorSet -or $trustedAuthorExempt)) { exit 0 }

$ticketPattern = $env:TICKET_ID_PATTERN
if (-not $ticketPattern -and $env:JIRA_PROJECT_KEY) {
    $ticketPattern = [regex]::Escape($env:JIRA_PROJECT_KEY) + '-\d+'
}
if (-not $ticketPattern) {
    Write-Error "COMMIT REJECTED: TICKET_ID_REQUIRED=1 but no ticket pattern is configured.`n  Set JIRA_PROJECT_KEY (for PROJECT-N) or TICKET_ID_PATTERN (for another ticket system)."
    exit 1
}

try {
    if ($msg -notmatch $ticketPattern) {
        Write-Error "COMMIT REJECTED: TICKET_ID_REQUIRED=1 but no ticket reference matched: $ticketPattern`n  Merge commits, revert commits, and TICKET_ID_EXEMPT_AUTHORS are exempt."
        exit 1
    }
} catch {
    Write-Error "COMMIT REJECTED: invalid TICKET_ID_PATTERN regex: $ticketPattern"
    exit 1
}

exit 0
