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
    [string]$TranscriptPath,
    [string]$RulesFile
)
$ErrorActionPreference = 'SilentlyContinue'

if (-not $NotePath) { exit 0 }

# Optional operator rules/context file: 3rd positional arg, overridden by env
# CRYSTALLIZE_RULES_FILE (env wins — same precedence as CRYSTALLIZE_MODEL).
$rulesFile = if ($env:CRYSTALLIZE_RULES_FILE) { $env:CRYSTALLIZE_RULES_FILE } else { $RulesFile }
# Refresh (re-consolidation) mode: re-run an already-synthesized note.
$refresh = ($env:CRYSTALLIZE_REFRESH -eq '1')

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
# Declared before the try so the outer finally always cleans them up (parity with
# the bash EXIT trap) even if a throw lands between their creation and the run.
$settingsTmp = $null
$snapTmp = $null
try {
    # Retry-read: the live hook may have just written the note via the Obsidian
    # REST API, which flushes to disk asynchronously.
    $i = 0
    while (-not (Test-Path -LiteralPath $NotePath) -and $i -lt 3) { Start-Sleep -Seconds 1; $i++ }
    if (-not (Test-Path -LiteralPath $NotePath)) { exit 0 }

    # Already crystallized -> nothing to do, UNLESS refresh mode re-runs it.
    if (-not $refresh -and (Select-String -LiteralPath $NotePath -Pattern '^crystallized: true$' -Quiet)) { exit 0 }

    if ($refresh) {
        # Loss-proofing (refresh only): a refresh rewrites PREVIOUSLY-GOOD
        # synthesis, so a partial/failed claude edit must never be accepted.
        # Snapshot pre-run; the result is validated structurally below and
        # restored from this snapshot if it fails. Can't snapshot -> can't
        # roll back -> don't run (fail-open, note untouched).
        $snapTmp = "$NotePath.snap.$PID"
        try { Copy-Item -LiteralPath $NotePath -Destination $snapTmp -Force -ErrorAction Stop }
        catch { $snapTmp = $null; exit 0 }
    }

    if ($refresh) {
        # Refresh (re-consolidation): CONSOLIDATE — update/extend the four
        # sections, preserving prior synthesis content still correct.
        $prompt = @"
You are re-consolidating an already-synthesized Claude Code session note for an Obsidian vault.
Read the session transcript at: $TranscriptPath
Read the note at: $NotePath
This note was already synthesized. Re-read the transcript and the existing sections;
UPDATE/EXTEND the four sections below, preserving prior synthesis content that is
still correct — do not discard it:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop.

Optionally, ALSO append one more section after ## Follow-ups if the session
surfaced a genuine reusable lesson (a gotcha, decision, or fact worth
remembering beyond this session — skip the section entirely if there is no
genuine lesson):
- ## Lessons — a fenced code block labeled jsonl, one JSON object per line:
  {"id": "YYYY-MM-DD-<kebab-slug>", "claim": "<the lesson, 1-3 lines, self-contained>", "source": {"type": "session", "ref": "<this note's vault-relative path>#Lessons"}, "captured_at": "<UTC ISO-8601 now>", "captured_by": "end-session-wiki", "confidence": "<see below>", "scope": ["<see below>"], "status": "<see below>"}
  confidence is exactly one of: high (observed directly), medium (inferred from one occurrence), low (speculative).
  status is: active when confidence is high, unverified otherwise.
  scope is a list of one or more of ONLY these tags: guardrails, cr, lanes, jira, handover, telegram, vault, env-windows, env-macos, billing, harness.
This section is best-effort: a malformed line must never stop you from
finishing the required sections above. It is checked later by a lean-invoke
validation pass (scripts/lessons/validate-lesson.mjs --capture), not at capture time.
"@
    } else {
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

Optionally, ALSO append one more section after ## Follow-ups if the session
surfaced a genuine reusable lesson (a gotcha, decision, or fact worth
remembering beyond this session — skip the section entirely if there is no
genuine lesson):
- ## Lessons — a fenced code block labeled jsonl, one JSON object per line:
  {"id": "YYYY-MM-DD-<kebab-slug>", "claim": "<the lesson, 1-3 lines, self-contained>", "source": {"type": "session", "ref": "<this note's vault-relative path>#Lessons"}, "captured_at": "<UTC ISO-8601 now>", "captured_by": "end-session-wiki", "confidence": "<see below>", "scope": ["<see below>"], "status": "<see below>"}
  confidence is exactly one of: high (observed directly), medium (inferred from one occurrence), low (speculative).
  status is: active when confidence is high, unverified otherwise.
  scope is a list of one or more of ONLY these tags: guardrails, cr, lanes, jira, handover, telegram, vault, env-windows, env-macos, billing, harness.
This section is best-effort: a malformed line must never stop you from
finishing the required sections above. It is checked later by a lean-invoke
validation pass (scripts/lessons/validate-lesson.mjs --capture), not at capture time.
"@
    }

    # Operator rules/context injection: append a readable rules file's content as
    # a clearly delimited block. Unreadable / missing / empty -> append nothing.
    # Trim whitespace before the emptiness check to ensure parity with bash
    # (bash `$(cat)` strips trailing newline, but PS Get-Content -Raw keeps it;
    # both must skip on whitespace-only files).
    if ($rulesFile -and (Test-Path -LiteralPath $rulesFile)) {
        $rulesContent = (Get-Content -LiteralPath $rulesFile -Raw)
        # Null-safe whitespace check: Get-Content -Raw returns $null on a
        # zero-byte file, so .Trim() would throw and abort the run.
        if (-not [string]::IsNullOrWhiteSpace($rulesContent)) {
            $prompt = $prompt + @"

Additionally apply these operator rules when synthesizing:
--- begin operator rules ---
$rulesContent
--- end operator rules ---
"@
        }
    }

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
        # Refresh loss-proofing: a changed-but-structurally-broken result
        # (truncated note, lost frontmatter/sections — the shape of a
        # half-applied edit) is ROLLED BACK to the pre-run snapshot and NOT
        # re-stamped, so a hash-based caller naturally counts a skip.
        # Non-refresh runs never enter the rollback branch (no snapshot).
        $valid = $true
        if ($refresh) {
            # Frontmatter intact (first line `---`, a second `---` exists),
            # all four section headers, and the Raw Conversation callout the
            # renderer emits (scripts/lib/session-note.sh) still present.
            $rl = @(Get-Content -LiteralPath $NotePath)
            if (-not $rl -or $rl[0] -ne '---') { $valid = $false }
            elseif (@($rl | Where-Object { $_ -eq '---' }).Count -lt 2) { $valid = $false }
            elseif (($rl -notcontains '## Summary') -or ($rl -notcontains '## Decisions') -or
                    ($rl -notcontains '## Files Touched') -or ($rl -notcontains '## Follow-ups')) { $valid = $false }
            elseif ($rl -notcontains '> [!note]- Raw conversation') { $valid = $false }
        }
        if (-not $valid) {
            if ($snapTmp -and (Test-Path -LiteralPath $snapTmp)) {
                Move-Item -LiteralPath $snapTmp -Destination $NotePath -Force
                $snapTmp = $null
            }
        } else {
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
    }
} finally {
    Remove-Item -LiteralPath $myPid -Force -ErrorAction SilentlyContinue
    if ($settingsTmp) { Remove-Item -LiteralPath $settingsTmp -Force -ErrorAction SilentlyContinue }
    if ($snapTmp) { Remove-Item -LiteralPath $snapTmp -Force -ErrorAction SilentlyContinue }
}
exit 0
