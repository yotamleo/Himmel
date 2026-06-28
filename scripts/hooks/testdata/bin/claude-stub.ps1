# claude-stub.ps1 — Windows twin of claude-stub.sh: a deterministic `claude`
# stand-in for crystallize-note.ps1 tests (HIMMEL-576). Pointed at via
# CRYSTALLIZE_CLAUDE_BIN so the suite stays hermetic (no model call / network).
#
# STUB_MODE (default success): success edits the note ($CRYSTALLIZE_NOTE) — fills
# the 4 sections, sets crystallized: true / crystallized_at, preserves all other
# frontmatter; fail exits 7 without writing; noop exits 0 without writing; slow
# sleeps 1s THEN behaves as success (detach timing). Touches $CRYSTALLIZE_MARKER
# on invocation (after the slow sleep) and dumps the recursion-guard env vars to
# $CRYSTALLIZE_ENV_DUMP. Extra args (the prompt + flags) are ignored.
param([Parameter(ValueFromRemainingArguments = $true)] $Rest)
$ErrorActionPreference = 'SilentlyContinue'

$mode = if ($env:STUB_MODE) { $env:STUB_MODE } else { 'success' }

# slow sleeps BEFORE signalling so the detach-survival test can kill the launching
# process during the sleep; the marker then proves the child outlived it.
if ($mode -eq 'slow') { Start-Sleep -Seconds 1 }

if ($env:CRYSTALLIZE_MARKER) { Add-Content -LiteralPath $env:CRYSTALLIZE_MARKER -Value 'invoked' }
if ($env:CRYSTALLIZE_ENV_DUMP) {
    $w = if ($null -ne $env:CLAUDE_END_SESSION_WIKI) { $env:CLAUDE_END_SESSION_WIKI } else { '<unset>' }
    $a = if ($null -ne $env:HIMMEL_WHERE_ARE_WE) { $env:HIMMEL_WHERE_ARE_WE } else { '<unset>' }
    Set-Content -LiteralPath $env:CRYSTALLIZE_ENV_DUMP -Value @("CLAUDE_END_SESSION_WIKI=$w", "HIMMEL_WHERE_ARE_WE=$a")
}

if ($mode -eq 'fail') { exit 7 }
if ($mode -eq 'noop') { exit 0 }

$note = $env:CRYSTALLIZE_NOTE
if (-not $note -or -not (Test-Path -LiteralPath $note)) { exit 0 }

$now = '2026-06-28T12:00:00Z'
$out = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($line in (Get-Content -LiteralPath $note)) {
    if ($line -eq 'crystallized: false') { $out.Add('crystallized: true'); continue }
    if ($line -eq 'crystallized_at:')    { $out.Add("crystallized_at: $now"); continue }
    if ($skip) { if ($line -match '^## ') { $skip = $false } else { continue } }
    if ($line -eq '## Summary') {
        $out.Add($line); $out.Add(''); $out.Add('_Crystallized by stub: session synthesized._'); $out.Add('')
        $skip = $true; continue
    }
    $out.Add($line)
}
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($note, (($out -join "`n") + "`n"), $enc)
exit 0
