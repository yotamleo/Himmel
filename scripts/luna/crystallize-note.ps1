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
# Declared before the try so the outer finally always cleans it up (parity with
# the bash EXIT trap) even if a throw lands between its creation and the run.
$settingsTmp = $null
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
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop.
"@

    # The note lives in the luna vault, OUTSIDE the himmel repo. Running claude in
    # HIMMEL_ROOT left the out-of-workspace note edit waiting on a permission
    # prompt that bounded stdin EOFed -> byte-unchanged note (HIMMEL-590 F1). Fix
    # (HIMMEL-575 class): cwd = the note's directory, --add-dir the transcript
    # dir, and inject auto-approve-safe-bash by absolute path via --settings. The
    # LLM rewrites only the body; this script owns the crystallized flag from the
    # body diff (T1d).
    $himmelRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $hookPath = ((Join-Path $himmelRoot 'scripts\hooks\auto-approve-safe-bash.sh') -replace '\\', '/')
    $settingsTmp = Join-Path ([System.IO.Path]::GetTempPath()) "crys-settings-$PID.json"
    $settingsJson = @"
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash $hookPath" }
        ]
      }
    ]
  }
}
"@
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($settingsTmp, $settingsJson, $enc)

    $noteDir = Split-Path -Parent (Resolve-Path -LiteralPath $NotePath).Path
    $claudeArgs = @()
    if ($env:CRYSTALLIZE_MODEL) { $claudeArgs += @('--model', $env:CRYSTALLIZE_MODEL) }
    if ($TranscriptPath) {
        $trParent = Split-Path -Parent $TranscriptPath
        if ($trParent -and (Test-Path -LiteralPath $trParent)) { $claudeArgs += @('--add-dir', $trParent) }
    }
    $claudeArgs += @('--settings', $settingsTmp, '--permission-mode', 'acceptEdits', $prompt)
    $env:CRYSTALLIZE_NOTE = $NotePath
    $env:CRYSTALLIZE_TRANSCRIPT = $TranscriptPath

    # Pre-hash: the edit-confirmed flag-set keys off whether the body moved.
    $hashBefore = (Get-FileHash -LiteralPath $NotePath -Algorithm SHA256).Hash

    Push-Location $noteDir
    [Environment]::CurrentDirectory = $noteDir
    try {
        $null | & $bin @claudeArgs *> $null
    } finally {
        Pop-Location
    }

    # Edit-confirmed flag-set (T1d): stamp crystallized:true only when the note
    # body actually changed. A no-op leaves it byte-unchanged + crystallized:false;
    # a real synthesis flips it with a deterministic UTC timestamp this script owns
    # (CRYSTALLIZE_NOW overridable for hermetic tests). LF-preserving write.
    $hashAfter = (Get-FileHash -LiteralPath $NotePath -Algorithm SHA256).Hash
    if ($hashBefore -and $hashAfter -and ($hashBefore -ne $hashAfter)) {
        $now = if ($env:CRYSTALLIZE_NOW) { $env:CRYSTALLIZE_NOW } else { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $fmc = 0
        $stamped = New-Object System.Collections.Generic.List[string]
        foreach ($line in (Get-Content -LiteralPath $NotePath)) {
            if ($line -eq '---') { $fmc++; $stamped.Add($line); continue }
            if ($fmc -eq 1 -and $line -match '^crystallized: ') { $stamped.Add('crystallized: true'); continue }
            if ($fmc -eq 1 -and $line -match '^crystallized_at:') { $stamped.Add("crystallized_at: $now"); continue }
            $stamped.Add($line)
        }
        [System.IO.File]::WriteAllText($NotePath, (($stamped -join "`n") + "`n"), $enc)
    }
} finally {
    Remove-Item -LiteralPath $myPid -Force -ErrorAction SilentlyContinue
    if ($settingsTmp) { Remove-Item -LiteralPath $settingsTmp -Force -ErrorAction SilentlyContinue }
}
exit 0
