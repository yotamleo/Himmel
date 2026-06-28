# crystallize-note.ps1 — Windows twin of crystallize-note.sh (HIMMEL-576).
# Upgrades a mechanical session note into an LLM synthesis: asks a bounded
# `claude "<prompt>"` run (interactive, NOT headless -p -> HIMMEL-128-safe; Max
# plan, no API key) to rewrite the four body sections and flip crystallized: true.
#
# Usage: pwsh -File crystallize-note.ps1 <note_path> <transcript_path>
#
# Best-effort + fail-open: no claude / over the concurrency cap / note-not-yet-on-
# disk -> exit 0, leaving the mechanical note (crystallized: false); the reheal
# sweep recovers it. Test seam: CRYSTALLIZE_CLAUDE_BIN overrides claude with a stub.
param(
    [string]$NotePath,
    [string]$TranscriptPath
)
$ErrorActionPreference = 'SilentlyContinue'

if (-not $NotePath) { exit 0 }

# Recursion guards: the throwaway claude subsession must not re-fire the session-
# end hooks (end-session-wiki + HIMMEL-572 where-are-we refresh).
$env:CLAUDE_END_SESSION_WIKI = '0'
$env:HIMMEL_WHERE_ARE_WE = '0'

# Resolve claude (test override wins). No claude -> leave the mechanical note.
$bin = $env:CRYSTALLIZE_CLAUDE_BIN
if (-not $bin) { $bin = (Get-Command claude -ErrorAction SilentlyContinue).Source }
if (-not $bin) { exit 0 }

# Concurrency cap — never pile up N claude processes for N session-ends.
$maxC = if ($env:CRYSTALLIZE_MAX_CONCURRENCY) { [int]$env:CRYSTALLIZE_MAX_CONCURRENCY } else { 2 }
$pidDir = if ($env:CRYSTALLIZE_PID_DIR) { $env:CRYSTALLIZE_PID_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'himmel-crystallize' }
New-Item -ItemType Directory -Path $pidDir -Force | Out-Null
$live = 0
Get-ChildItem -Path $pidDir -Filter '*.pid' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($p -and (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue)) { $live++ }
    else { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}
if ($live -ge $maxC) { exit 0 }
$myPid = Join-Path $pidDir "$PID.pid"
Set-Content -LiteralPath $myPid -Value $PID -ErrorAction SilentlyContinue
try {
    # Retry-read: the live hook may have just written the note via the Obsidian
    # REST API, which flushes to disk asynchronously.
    $i = 0
    while (-not (Test-Path -LiteralPath $NotePath) -and $i -lt 3) { Start-Sleep -Seconds 1; $i++ }
    if (-not (Test-Path -LiteralPath $NotePath)) { exit 0 }

    # Already crystallized -> nothing to do.
    if (Select-String -LiteralPath $NotePath -Pattern '^crystallized: true$' -Quiet) { exit 0 }

    $prompt = @"
You are crystallizing a Claude Code session note for an Obsidian vault.
Read the session transcript at: $TranscriptPath
Read the note at: $NotePath
Rewrite ONLY these sections of that note, in place, distilling the session:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Set frontmatter 'crystallized: true' and 'crystallized_at:' to the current UTC
ISO-8601 time. Preserve every other frontmatter field (date, session_id, repo,
branch, worktree, source) verbatim, and do NOT touch the Raw Conversation
callout. Make the edit with your file tools, then stop.
"@

    # Run in the himmel repo root so the spawned claude inherits himmel's project
    # settings (auto-approve-safe-bash -> no compound-bash stall, the HIMMEL-575
    # posture). --permission-mode acceptEdits lets the single note edit land
    # without a prompt. Pipe $null -> bounded stdin (a stray prompt EOFs out).
    $himmelRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $claudeArgs = @()
    if ($env:CRYSTALLIZE_MODEL) { $claudeArgs += @('--model', $env:CRYSTALLIZE_MODEL) }
    $claudeArgs += @('--permission-mode', 'acceptEdits', $prompt)
    $env:CRYSTALLIZE_NOTE = $NotePath
    $env:CRYSTALLIZE_TRANSCRIPT = $TranscriptPath
    Push-Location $himmelRoot
    [Environment]::CurrentDirectory = $himmelRoot
    try {
        $null | & $bin @claudeArgs *> $null
    } finally {
        Pop-Location
    }
} finally {
    Remove-Item -LiteralPath $myPid -Force -ErrorAction SilentlyContinue
}
exit 0
