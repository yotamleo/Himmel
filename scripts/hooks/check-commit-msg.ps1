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

# Skip merge commits
$gitDir = git rev-parse --git-dir 2>$null
if (Test-Path (Join-Path $gitDir "MERGE_HEAD")) { exit 0 }

# Skip fixup/squash/revert
$firstLine = ($msg -split "`n")[0]
if ($firstLine -match '^(fixup!|squash!|revert!|Revert|Merge)') { exit 0 }

# Validate conventional commit
$pattern = '^(feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert)(\([^)]+\))?!?:\s+(HIMMEL-\d+\s+)?\S.+'
if ($firstLine -notmatch $pattern) {
    Write-Host ""
    Write-Host "COMMIT REJECTED: message does not match conventional commit format."
    Write-Host ""
    Write-Host "  Required:  type(scope): message"
    Write-Host "  Optional:  type(scope): HIMMEL-N message"
    Write-Host ""
    Write-Host "  Types: feat fix chore docs refactor test style perf ci build revert"
    Write-Host ""
    Write-Host "  Examples:"
    Write-Host "    feat(auth): add JWT validation"
    Write-Host "    fix(api): HIMMEL-23 correct status code on 404"
    Write-Host "    chore: update dependencies"
    Write-Host ""
    Write-Host "  Got: $firstLine"
    Write-Host ""
    exit 1
}

exit 0
