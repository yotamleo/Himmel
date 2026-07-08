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
function Run-Crys3([string]$note, [string]$tr, [string]$rules) { & $PWSH -NoProfile -File $CRYS $note $tr $rules | Out-Null }
# Flip a crystallized:false note to crystallized:true with an OLD timestamp, in
# place, so --refresh cases have an already-synthesized note to re-consolidate.
function Mark-Crystallized([string]$p) {
    $out = foreach ($l in (Get-Content -LiteralPath $p)) {
        if ($l -eq 'crystallized: false') { 'crystallized: true' }
        elseif ($l -eq 'crystallized_at:') { 'crystallized_at: 2026-01-01T00:00:00Z' }
        else { $l }
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($p, (($out -join "`n") + "`n"), $enc)
}

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

# --- Case 8: rules injection — rules file content reaches the claude prompt -----
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
$rules = Join-Path $SB 'rules.txt'; $argvd = Join-Path $SB 'argv.txt'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
Set-Content -LiteralPath $rules -Value 'PREFER_ACTIVE_VOICE_MARKER'
$env:CRYSTALLIZE_CLAUDE_BIN = $STUB; $env:STUB_MODE = 'success'
$env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids'); $env:CRYSTALLIZE_ARGV_DUMP = $argvd
$env:CRYSTALLIZE_RULES_FILE = $rules
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_RULES_FILE -ErrorAction SilentlyContinue
$avRaw = Get-Content -LiteralPath $argvd -Raw
if ($avRaw -match 'PREFER_ACTIVE_VOICE_MARKER') { Pass 'rules: rules content reaches the claude prompt' } else { Fail 'rules: rules content not in prompt' }
if ($avRaw -match 'begin operator rules') { Pass 'rules: delimited operator-rules block present' } else { Fail 'rules: no operator-rules delimiter' }
# Lesson-provenance prompt pin (HIMMEL-767): a here-string-escaping break must
# not silently drop the ## Lessons instruction block from the spawned prompt.
if ($avRaw.Contains('## Lessons')) { Pass 'lessons: ## Lessons instruction present in prompt' } else { Fail 'lessons: ## Lessons instruction missing from prompt' }
if ($avRaw.Contains('validate-lesson.mjs --capture')) { Pass 'lessons: validate-lesson.mjs --capture pointer present in prompt' } else { Fail 'lessons: validator pointer missing from prompt' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 9: missing/unreadable rules file — run proceeds, no rules block -------
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'; $argvd = Join-Path $SB 'argv.txt'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
$env:STUB_MODE = 'success'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_ARGV_DUMP = $argvd; $env:CRYSTALLIZE_RULES_FILE = (Join-Path $SB 'does-not-exist.txt')
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_RULES_FILE -ErrorAction SilentlyContinue
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized: true$') { Pass 'rules(missing): run still proceeds (fail-open)' } else { Fail 'rules(missing): run did not proceed' }
$avRaw = Get-Content -LiteralPath $argvd -Raw
if ($avRaw -notmatch 'begin operator rules') { Pass 'rules(missing): no rules block in prompt' } else { Fail 'rules(missing): rules block wrongly present' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 10: env CRYSTALLIZE_RULES_FILE beats the 3rd positional arg -----------
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'; $argvd = Join-Path $SB 'argv.txt'
$rulesEnv = Join-Path $SB 'env-rules.txt'; $rulesPos = Join-Path $SB 'pos-rules.txt'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
Set-Content -LiteralPath $rulesEnv -Value 'ENV_RULES_MARKER'
Set-Content -LiteralPath $rulesPos -Value 'POSITIONAL_RULES_MARKER'
$env:STUB_MODE = 'success'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_ARGV_DUMP = $argvd; $env:CRYSTALLIZE_RULES_FILE = $rulesEnv
Run-Crys3 $note $tr $rulesPos
Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_RULES_FILE -ErrorAction SilentlyContinue
$avRaw = Get-Content -LiteralPath $argvd -Raw
if ($avRaw -match 'ENV_RULES_MARKER') { Pass 'rules(precedence): env CRYSTALLIZE_RULES_FILE used' } else { Fail 'rules(precedence): env rules not used' }
if ($avRaw -notmatch 'POSITIONAL_RULES_MARKER') { Pass 'rules(precedence): positional arg ignored when env set' } else { Fail 'rules(precedence): positional wrongly used over env' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 11: refresh bypasses crystallized:true and re-stamps on a real change -
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'; Mark-Crystallized $note
$env:STUB_MODE = 'success'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_REFRESH = '1'; $env:CRYSTALLIZE_NOW = '2026-06-30T09:00:00Z'
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_REFRESH -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_NOW -ErrorAction SilentlyContinue
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized: true$') { Pass 'refresh: crystallized stays true' } else { Fail 'refresh: crystallized flag lost' }
if ($nc -match 'Crystallized by stub') { Pass 'refresh: Summary re-consolidated (bypassed early-exit)' } else { Fail 'refresh: Summary not updated' }
if ($nc -match '(?m)^crystallized_at: 2026-06-30T09:00:00Z$') { Pass 'refresh: crystallized_at re-stamped on a real change' } else { Fail 'refresh: crystallized_at not re-stamped' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 12: no-op refresh leaves the note byte-identical, no re-stamp ---------
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'; Mark-Crystallized $note
$h0 = (Get-FileHash -LiteralPath $note).Hash
$env:STUB_MODE = 'noop'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_REFRESH = '1'; $env:CRYSTALLIZE_NOW = '2026-06-30T09:00:00Z'
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_REFRESH -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_NOW -ErrorAction SilentlyContinue
if ((Get-FileHash -LiteralPath $note).Hash -eq $h0) { Pass 'refresh(noop): note byte-identical' } else { Fail 'refresh(noop): note modified on no-op refresh' }
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized_at: 2026-01-01T00:00:00Z$') { Pass 'refresh(noop): crystallized_at NOT re-stamped' } else { Fail 'refresh(noop): crystallized_at wrongly changed' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 13: corrupting refresh — result rolled back, nothing re-stamped -------
# A half-applied edit (the `corrupt` stub truncates the note, losing frontmatter
# + sections) changes the hash, but the refresh validator must REJECT it:
# restore the snapshot (byte-identical note), keep the OLD crystallized_at, and
# leave no snapshot temp behind.
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'; Mark-Crystallized $note
$h0 = (Get-FileHash -LiteralPath $note).Hash
$env:STUB_MODE = 'corrupt'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_REFRESH = '1'; $env:CRYSTALLIZE_NOW = '2026-06-30T09:00:00Z'
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_REFRESH -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_NOW -ErrorAction SilentlyContinue
if ((Get-FileHash -LiteralPath $note).Hash -eq $h0) { Pass 'refresh(corrupt): note restored byte-identical' } else { Fail 'refresh(corrupt): corrupted result was ACCEPTED (prior synthesis lost)' }
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized_at: 2026-01-01T00:00:00Z$') { Pass 'refresh(corrupt): crystallized_at NOT re-stamped' } else { Fail 'refresh(corrupt): crystallized_at wrongly re-stamped' }
if ($nc -match '(?m)^crystallized: true$') { Pass 'refresh(corrupt): crystallized still true after rollback' } else { Fail 'refresh(corrupt): crystallized flag lost in rollback' }
if (-not (Get-ChildItem -Path $SB -Filter '*.snap.*' -ErrorAction SilentlyContinue)) { Pass 'refresh(corrupt): no snapshot temp left behind' } else { Fail 'refresh(corrupt): snapshot temp leaked' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 14: 3rd positional rules arg ALONE (env unset) reaches the prompt ------
# Case 10 proves env beats positional; this proves the positional fallback works on
# its own when CRYSTALLIZE_RULES_FILE is unset.
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
$rules = Join-Path $SB 'pos-only-rules.txt'; $argvd = Join-Path $SB 'argv.txt'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
Set-Content -LiteralPath $rules -Value 'POSITIONAL_ONLY_RULES_MARKER'
Remove-Item Env:\CRYSTALLIZE_RULES_FILE -ErrorAction SilentlyContinue
$env:STUB_MODE = 'success'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_ARGV_DUMP = $argvd
Run-Crys3 $note $tr $rules
Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
$avRaw = Get-Content -LiteralPath $argvd -Raw
if ($avRaw -match 'POSITIONAL_ONLY_RULES_MARKER') { Pass 'rules(positional): 3rd positional rules arg reaches the prompt' } else { Fail 'rules(positional): positional rules not in prompt' }
if ($avRaw -match 'begin operator rules') { Pass 'rules(positional): delimited operator-rules block present' } else { Fail 'rules(positional): no operator-rules delimiter' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 15: existing but EMPTY rules file — no rules block, run still proceeds -
# The empty-content guard (if ($rulesContent)) must skip the block for a zero-byte
# rules file while the crystallize run itself proceeds normally.
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
$rules = Join-Path $SB 'empty-rules.txt'; $argvd = Join-Path $SB 'argv.txt'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
[System.IO.File]::WriteAllText($rules, '')
$env:CRYSTALLIZE_CLAUDE_BIN = $STUB; $env:STUB_MODE = 'success'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_ARGV_DUMP = $argvd; $env:CRYSTALLIZE_RULES_FILE = $rules
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_RULES_FILE -ErrorAction SilentlyContinue
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized: true$') { Pass 'rules(empty): run still proceeds normally with zero-byte rules file' } else { Fail 'rules(empty): run did not proceed' }
$avRaw = Get-Content -LiteralPath $argvd -Raw
if ($avRaw -notmatch 'begin operator rules') { Pass 'rules(empty): no operator-rules block for a zero-byte rules file' } else { Fail 'rules(empty): rules block wrongly present for zero-byte file' }
Remove-Item -LiteralPath $SB -Recurse -Force

# --- Case 16: whitespace-only rules file — parity test (bash vs ps1 divergence) --
# HIMMEL-841: bash `$(cat file)` strips trailing newline; PS `Get-Content -Raw`
# keeps it. A file with ONLY a newline must NOT append a rules block in BOTH.
$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("cnt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $SB -Force | Out-Null
$note = Join-Path $SB 'note.md'; $tr = Join-Path $SB 't.jsonl'
$rules = Join-Path $SB 'ws-only-rules.txt'; $argvd = Join-Path $SB 'argv.txt'
Write-Note $note; Set-Content -LiteralPath $tr -Value '{}'
[System.IO.File]::WriteAllText($rules, "`n")
$env:CRYSTALLIZE_CLAUDE_BIN = $STUB; $env:STUB_MODE = 'success'; $env:CRYSTALLIZE_PID_DIR = (Join-Path $SB 'pids')
$env:CRYSTALLIZE_ARGV_DUMP = $argvd; $env:CRYSTALLIZE_RULES_FILE = $rules
Run-Crys $note $tr
Remove-Item Env:\CRYSTALLIZE_ARGV_DUMP -ErrorAction SilentlyContinue
Remove-Item Env:\CRYSTALLIZE_RULES_FILE -ErrorAction SilentlyContinue
$nc = Get-Content -LiteralPath $note -Raw
if ($nc -match '(?m)^crystallized: true$') { Pass 'rules(ws-only): run still proceeds normally with whitespace-only rules file' } else { Fail 'rules(ws-only): run did not proceed' }
# The load-bearing parity assertion (HIMMEL-841): the block must be ABSENT —
# without it this case stays green even if the trim guard is reverted.
$avRaw = Get-Content -LiteralPath $argvd -Raw
if ($avRaw -notmatch 'begin operator rules') { Pass 'rules(ws-only): no operator-rules block for whitespace-only file (parity with bash)' } else { Fail 'rules(ws-only): rules block wrongly present for whitespace-only file' }
Remove-Item -LiteralPath $SB -Recurse -Force

if ($script:fails -eq 0) { 'ALL PASS'; exit 0 } else { "$($script:fails) FAILED"; exit 1 }
