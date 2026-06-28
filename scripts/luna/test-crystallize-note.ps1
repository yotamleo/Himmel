# test-crystallize-note.ps1 — hermetic smoke tests for crystallize-note.ps1
# (HIMMEL-576). A `claude` stub (CRYSTALLIZE_CLAUDE_BIN -> claude-stub.ps1) keeps
# the suite offline. Run: pwsh -NoProfile -File scripts/luna/test-crystallize-note.ps1
$ErrorActionPreference = 'Stop'
$CRYS = Join-Path $PSScriptRoot 'crystallize-note.ps1'
$STUB = Join-Path $PSScriptRoot '..\hooks\testdata\bin\claude-stub.ps1'
$PWSH = (Get-Command pwsh).Source
$script:fails = 0
function Pass([string]$m) { "PASS: $m" }
function Fail([string]$m) { "FAIL: $m"; $script:fails++ }

function Write-Note([string]$p) {
    Set-Content -LiteralPath $p -Encoding utf8 -Value @'
---
date: 2026-06-20T08:00:00Z
type: session
repo: himmel
branch: feat/x
worktree: /tmp/x
duration_minutes: 5
files_touched: 0
tags:
  - session
  - autocapture
ai-first: true
session_id: sess-abc
source: live
crystallized: false
crystallized_at:
---

Auto-captured session.

## Summary

_Transcript unavailable; auto-summary not generated._ (speculation)

## Decisions

_None._

## Files Touched

_None._

## Commands

```bash
```

## Follow-ups

_None._

## Raw Conversation

> [!note]- Raw conversation
> _Transcript unavailable._
'@
}
function Identity([string]$p) { (Get-Content -LiteralPath $p | Where-Object { $_ -match '^(date|session_id|repo|branch|worktree|source):' }) -join "`n" }
function Run-Crys([string]$note, [string]$tr) { & $PWSH -NoProfile -File $CRYS $note $tr | Out-Null }

# --- Case 1: success — sections filled, crystallized true, identity preserved --
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
$idBefore = Identity $note
$envd = Join-Path $SB 'env.txt'
$env:CRYSTALLIZE_CLAUDE_BIN = $STUB; $env:STUB_MODE = 'success'
$env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids'); $env:CRYSTALLIZE_ENV_DUMP = $envd
# CRYSTALLIZE_NOW pins the stamp time (the script — not the stub — now owns the
# flag + timestamp from the body diff, HIMMEL-590 T1d).
$env:CRYSTALLIZE_NOW = '2026-06-28T12:00:00Z'
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_NOW -ErrorAction SilentlyContinue
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized: true$') { Pass 'success: crystallized: true set (by script, from body diff)' } else { Fail 'success: crystallized not flipped' }
if ($nc -match 'Crystallized by stub') { Pass 'success: Summary rewritten' } else { Fail 'success: Summary not rewritten' }
if ($nc -match '(?m)^crystallized_at: 2026-06-28T12:00:00Z$') { Pass 'success: crystallized_at set' } else { Fail 'success: crystallized_at not set' }
if ((Identity $note) -eq $idBefore) { Pass 'success: identity frontmatter byte-stable' } else { Fail 'success: identity changed' }
$ed = Get-Content -LiteralPath $envd -Raw
if ($ed -match 'CLAUDE_END_SESSION_WIKI=0') { Pass 'recursion-guard: CLAUDE_END_SESSION_WIKI=0' } else { Fail 'recursion-guard: end-session-wiki env not set' }
if ($ed -match 'HIMMEL_WHERE_ARE_WE=0') { Pass 'recursion-guard: HIMMEL_WHERE_ARE_WE=0 (HIMMEL-572 fold-in)' } else { Fail 'recursion-guard: where-are-we env not set' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 2: fail — note unchanged, crystallized stays false -----------------
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
$h0 = (Get-FileHash -LiteralPath $note).Hash
$env:STUB_MODE = 'fail'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
Run-Crys $note $tr
if ((Get-FileHash -LiteralPath $note).Hash -eq $h0) { Pass 'fail: note byte-unchanged' } else { Fail 'fail: note modified on failure' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 3: noop — note unchanged -------------------------------------------
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
$h0 = (Get-FileHash -LiteralPath $note).Hash
$env:STUB_MODE = 'noop'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
Run-Crys $note $tr
if ((Get-FileHash -LiteralPath $note).Hash -eq $h0) { Pass 'noop: note byte-unchanged' } else { Fail 'noop: note modified on no-op' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 4: claude absent — note unchanged ----------------------------------
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
$h0 = (Get-FileHash -LiteralPath $note).Hash
$oldPath = $env:PATH; $oldBin = $env:CRYSTALLIZE_CLAUDE_BIN
$env:CRYSTALLIZE_CLAUDE_BIN = ''; $env:PATH = "$env:SystemRoot\System32"; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
Run-Crys $note $tr
$env:PATH = $oldPath; $env:CRYSTALLIZE_CLAUDE_BIN = $oldBin
if ((Get-FileHash -LiteralPath $note).Hash -eq $h0) { Pass 'claude-absent: note unchanged' } else { Fail 'claude-absent: note modified' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 5: concurrency cap — over cap, no spawn ----------------------------
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'; $pids = Join-Path $SB 'pids'; $mark = Join-Path $SB 'marker.txt'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'; New-Item -ItemType Directory -Path $pids -Force | Out-Null
# Seed >= cap (2) live pidfiles using THIS test's own PID (Get-Process succeeds).
Set-Content -LiteralPath (Join-Path $pids 'a.pid') -Value $PID
Set-Content -LiteralPath (Join-Path $pids 'b.pid') -Value $PID
$env:CRYSTALLIZE_CLAUDE_BIN = $STUB; $env:STUB_MODE = 'success'
$env:CRYSTALLIZE_PID_DIR = $pids; $env:CRYSTALLIZE_MARKER = $mark; $env:CRYSTALLIZE_MAX_CONCURRENCY = '2'
Run-Crys $note $tr
if (-not (Test-Path $mark)) { Pass 'cap: no claude spawned when at/over cap' } else { Fail 'cap: claude spawned despite cap' }
if ((Get-Content -LiteralPath $note -Raw) -match '(?m)^crystallized: false$') { Pass 'cap: note stays crystallized: false' } else { Fail 'cap: note wrongly crystallized' }
Remove-Item Env:\CRYSTALLIZE_MARKER -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_MAX_CONCURRENCY -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 6: workspace guard — the spawn puts the note-dir in the workspace -----
# HIMMEL-590 T1c: assert the fix shape from the spawned argv/cwd dump — cwd is the
# note's directory, the transcript dir is added via --add-dir, and a --settings
# fragment (auto-approve-safe-bash) is injected.
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $SB 'vault\sessions') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SB 'proj') -Force | Out-Null
$note = Join-Path $SB 'vault\sessions\note.md'; $tr = Join-Path $SB 'proj\t.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
$argvd = Join-Path $SB 'argv.txt'
$env:CRYSTALLIZE_CLAUDE_BIN = $STUB; $env:STUB_MODE = 'success'
$env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids'); $env:CRYSTALLIZE_ARGV_DUMP = $argvd
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
$av = Get-Content -LiteralPath $argvd
$noteDirReal = (Resolve-Path -LiteralPath (Split-Path -Parent $note)).Path
$trDirReal = (Resolve-Path -LiteralPath (Split-Path -Parent $tr)).Path
if ($av -contains "cwd=$noteDirReal") { Pass 'workspace: spawn cwd is the note directory' } else { Fail 'workspace: spawn cwd is NOT the note-dir (out-of-workspace edit risk)' }
if (($av -contains 'arg=--add-dir') -and ($av -contains "arg=$trDirReal")) { Pass 'workspace: transcript dir added via --add-dir' } else { Fail 'workspace: transcript dir not in --add-dir' }
if ($av -contains 'arg=--settings') { Pass 'workspace: --settings fragment injected' } else { Fail 'workspace: no --settings fragment' }
# Content, not just presence: the fragment must actually wire auto-approve-safe-bash.
$avRaw = (Get-Content -LiteralPath $argvd -Raw)
if ($avRaw -match '(?m)^settings:.*auto-approve-safe-bash') { Pass 'workspace: --settings fragment wires auto-approve-safe-bash by path' } else { Fail 'workspace: --settings fragment does not wire the hook' }
if (($avRaw -match '(?m)^settings:.*"PreToolUse"') -and ($avRaw -match '(?m)^settings:.*"Bash"')) { Pass 'workspace: --settings fragment is a PreToolUse/Bash hook block' } else { Fail 'workspace: --settings fragment malformed' }
# acceptEdits must survive — it auto-approves the in-workspace note edit.
if ($av -contains 'arg=acceptEdits') { Pass 'workspace: --permission-mode acceptEdits passed' } else { Fail 'workspace: acceptEdits not passed' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 7: edit-confirmed flag — no body change => crystallized stays false ---
# T1d: a noop run (claude wrote nothing) must leave crystallized:false.
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
$env:CRYSTALLIZE_CLAUDE_BIN = $STUB; $env:STUB_MODE = 'noop'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
Run-Crys $note $tr
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized: false$') { Pass 'edit-confirmed: noop leaves crystallized: false' } else { Fail 'edit-confirmed: noop wrongly flagged crystallized' }
Remove-Item -LiteralPath $SB -Recurse -Force

if ($script:fails -eq 0) { 'ALL PASS'; exit 0 } else { "$($script:fails) FAILED"; exit 1 }
