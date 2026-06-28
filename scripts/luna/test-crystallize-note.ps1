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
Run-Crys $note $tr
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized: true$') { Pass 'success: crystallized: true set' } else { Fail 'success: crystallized not flipped' }
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

if ($script:fails -eq 0) { 'ALL PASS'; exit 0 } else { "$($script:fails) FAILED"; exit 1 }
