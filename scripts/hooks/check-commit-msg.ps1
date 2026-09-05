# Windows PowerShell equivalent of check-commit-msg.sh
# Called by Git on Windows when bash is unavailable.
# Usage: git config core.hooksPath scripts/hooks (then Git calls .ps1 on Windows)
# Note: pre-commit framework uses the .sh version via Git Bash — this is a fallback.

param([string]$CommitMsgFile = $env:GIT_COMMIT_MSG_FILE)

# A positional argument bound to a DECLARED parameter is removed from $args —
# $args[0] is empty on a normal invocation, so it cannot be used to report what
# was actually supplied. Capture it here, before either fallback below
# overwrites $CommitMsgFile, so the rejection diagnostic names the real input.
$SuppliedCommitMsgFile = $CommitMsgFile

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# HIMMEL-2461: mirror the .sh twin's fail-closed resolution. $args[0] is this
# hook's equivalent of the bash script's $1; when that is empty, fall back to
# .git/COMMIT_EDITMSG before giving up.
if (-not $CommitMsgFile) { $CommitMsgFile = $args[0] }
if (-not $CommitMsgFile) {
    $gitEditMsg = & git rev-parse --git-path COMMIT_EDITMSG 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitEditMsg) { $CommitMsgFile = $gitEditMsg }
}
if (-not $CommitMsgFile -or -not (Test-Path -LiteralPath $CommitMsgFile -PathType Leaf)) {
    $resolved = if ($CommitMsgFile) { $CommitMsgFile } else { '<none>' }
    $suppliedDisplay = if ($SuppliedCommitMsgFile) { $SuppliedCommitMsgFile } else { '' }
    Write-Error @"
COMMIT REJECTED: the commit-msg hook received no readable message file.
  `$1 was '$suppliedDisplay'; the .git/COMMIT_EDITMSG fallback resolved to '$resolved'.
  This is a HOOK WIRING fault, not a bad message. Check that the
  conventional-commit-msg entry in .pre-commit-config.yaml does NOT set
  'pass_filenames: false' -- that starves this hook of the message and
  made it certify every commit.
"@
    exit 1
}

try {
    $msg = Get-Content -LiteralPath $CommitMsgFile -Raw -ErrorAction Stop
} catch {
    Write-Error @"
COMMIT REJECTED: could not read the commit-message file '$CommitMsgFile'.
  This is a HOOK WIRING fault, not a bad message (see above).
"@
    exit 1
}

# HIMMEL-2462: a value line may carry a trailing comment
# (`JIRA_PROJECT_KEY=HIMMEL # default project`); without stripping it the
# ticket pattern built below becomes the impossible
# `HIMMEL # default project-\d+`. Mirrors strip_comment() in
# scripts/lib/load-dotenv.sh: a value is quoted only if it BEGINS with `"`
# or `'`; a quote appearing later is data. Inside a double-quoted value a
# backslash escapes the next character; inside a single-quoted value a
# backslash is literal. Once a quote closes, scanning continues, so a `#`
# after it can still start a comment. Unquoted, a `#` truncates the value
# only when it is preceded by whitespace (so `URL=http://x/#frag` keeps its
# fragment). An unterminated quote returns the whole remainder rather than
# guessing. Surrounding quotes are still NOT stripped (HIMMEL-1493).
function Remove-TrailingComment {
    param([string]$Value)
    $quote = ''
    $started = $false
    $esc = $false
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if (-not $started) {
            if ($c -eq [char]' ' -or $c -eq [char]"`t") { continue }
            $started = $true
            if ($c -eq [char]'"' -or $c -eq [char]"'") { $quote = $c; continue }
        }
        if ($quote -ne '') {
            if ($quote -eq [char]'"' -and $esc) { $esc = $false; continue }
            if ($quote -eq [char]'"' -and $c -eq [char]'\') { $esc = $true; continue }
            if ($c -eq $quote) { $quote = '' }
            continue
        }
        if ($c -eq [char]'#' -and $i -gt 0) {
            $prev = $Value[$i - 1]
            if ($prev -eq [char]' ' -or $prev -eq [char]"`t") {
                return $Value.Substring(0, $i)
            }
        }
    }
    return $Value
}

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
            $value = (Remove-TrailingComment $trimmed.Substring($separator + 1)).Trim()
            [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }
}

Import-TicketConfig

# HIMMEL-2183: WARN-only negative-existence claim linter. Never blocks (exit
# code is untouched) and fails open on any error inside it — a broken regex
# or a garbled line must degrade to silence, not to a crash or a false deny.
function Test-NegativeExistenceClaims {
    param([string]$Msg)
    try {
        $negRe = "(?i)we don't have|doesn't exist|isn't implemented|no [A-Za-z0-9_./-]+( [A-Za-z0-9_./-]+){0,3} found"
        $evidenceRe = '`[^`]+`|(^|[^A-Za-z0-9_.-])[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*\.[A-Za-z0-9]+|(^|[^A-Za-z0-9_])(scripts|docs|src|lib|test|tests|marketplace|templates)/|rg |grep |JQL|gh '
        $lines = $Msg -split "`r?`n"
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $m = [regex]::Match($lines[$i], $negRe)
            if ($m.Success) {
                $ctxLines = @()
                if ($i -gt 0) { $ctxLines += $lines[$i - 1] }
                $ctxLines += $lines[$i]
                if ($i -lt $lines.Length - 1) { $ctxLines += $lines[$i + 1] }
                $ctx = $ctxLines -join "`n"
                if ($ctx -notmatch $evidenceRe) {
                    [Console]::Error.WriteLine("WARN check-commit-msg: negative-existence claim (`"$($m.Value)`") — add a file path, command output, or Jira JQL next to this claim.")
                }
            }
        }
    } catch {}
}
Test-NegativeExistenceClaims $msg

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
    Write-Host "  Ticket:    required by default; TICKET_ID_REQUIRED=0 opts out"
    Write-Host ""
    Write-Host "  Types: feat fix chore docs refactor test style perf ci build revert"
    Write-Host ""
    Write-Host "  Examples:"
    Write-Host "    feat(auth): [#12] add JWT validation"
    Write-Host "    fix(api): PROJECT-23 correct status code on 404"
    Write-Host "    chore: [#13] update dependencies"
    Write-Host ""
    Write-Host "  Got: $firstLine"
    Write-Host ""
    exit 1
}

# HIMMEL-2442: default ON. An adopter with no .env at all is gated; the
# explicit opt-out is TICKET_ID_REQUIRED=0.
$requiredValue = if ($env:TICKET_ID_REQUIRED) { $env:TICKET_ID_REQUIRED } else { '1' }
switch -Regex ($requiredValue) {
    '^(0|false|off|no)$' { exit 0 }
    '^(1|true|on|yes)$'  { break }
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
# CR2: a bare '#[0-9]+' matches INSIDE a longer token, so a CSS colour like
# '#123abc' satisfies the gate as ticket "#123". Boundaries are character
# classes, not \b, so this is the SAME regex the .sh twin feeds to grep -E.
if (-not $ticketPattern) { $ticketPattern = '(^|[^0-9A-Za-z_])#[0-9]+([^0-9A-Za-z_]|$)' }

try {
    if ($msg -notmatch $ticketPattern) {
        Write-Error @"
COMMIT REJECTED: no ticket reference matched: $ticketPattern
  That is the only pattern in force. It is chosen in this order:
    1. TICKET_ID_PATTERN  — your own regex, if set
    2. JIRA_PROJECT_KEY   — gives PROJECT-123, if set
    3. #123               — himmel's own enumeration, the default when neither is set
  Get an #N from '/handover new-epic' or '/handover new-task' (it allocates the next free number).
  Opt out entirely with TICKET_ID_REQUIRED=0 in the repo's .env or the environment.
  Merge commits, revert commits, and TICKET_ID_EXEMPT_AUTHORS are exempt.
"@
        exit 1
    }
} catch {
    Write-Error "COMMIT REJECTED: invalid TICKET_ID_PATTERN regex: $ticketPattern"
    exit 1
}

exit 0
