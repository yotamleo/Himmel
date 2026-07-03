# claude-stub.ps1 — Windows twin of claude-stub.sh: a deterministic `claude`
# stand-in for crystallize-note.ps1 tests (HIMMEL-576). Pointed at via
# CRYSTALLIZE_CLAUDE_BIN so the suite stays hermetic (no model call / network).
#
# STUB_MODE (default success): success edits the note ($CRYSTALLIZE_NOTE) —
# rewrites the Summary body, preserving all frontmatter; the crystallized flag is
# owned by crystallize-note.ps1 (set from the body diff, HIMMEL-590 T1d), NOT
# here. fail exits 7 without writing; noop exits 0 without writing; slow sleeps 1s
# THEN behaves as success (detach timing); corrupt overwrites the note with a
# truncated fragment (half-applied edit, refresh loss-proofing, HIMMEL-663).
# Touches $CRYSTALLIZE_MARKER on
# invocation (after the slow sleep) and dumps the recursion-guard env vars to
# $CRYSTALLIZE_ENV_DUMP. When $CRYSTALLIZE_ARGV_DUMP is set, records cwd + every
# argv entry there so a test can assert the workspace shape (T1c).
param([Parameter(ValueFromRemainingArguments = $true)] $Rest)
$ErrorActionPreference = 'SilentlyContinue'

$mode = if ($env:STUB_MODE) { $env:STUB_MODE } else { 'success' }

if ($env:CRYSTALLIZE_ARGV_DUMP) {
    $lines = @("cwd=$((Get-Location).Path)")
    $wantSettings = $false
    foreach ($a in $Rest) {
        $lines += "arg=$a"
        # Capture the --settings fragment's CONTENT while it still exists
        # (crystallize-note.ps1 cleans it up on exit) so a test can assert it
        # actually wires the hook, not just that the flag is present.
        if ($wantSettings) {
            $wantSettings = $false
            if (Test-Path -LiteralPath $a) {
                foreach ($l in (Get-Content -LiteralPath $a)) { $lines += "settings:$l" }
            }
        }
        if ($a -eq '--settings') { $wantSettings = $true }
    }
    Set-Content -LiteralPath $env:CRYSTALLIZE_ARGV_DUMP -Value $lines
}

# slow sleeps BEFORE signalling so the detach-survival test can kill the launching
# process during the sleep; the marker then proves the child outlived it.
if ($mode -eq 'slow') { Start-Sleep -Seconds 1 }

if ($env:CRYSTALLIZE_MARKER) { Add-Content -LiteralPath $env:CRYSTALLIZE_MARKER -Value 'invoked' }
if ($env:CRYSTALLIZE_ENV_DUMP) {
    $w = if ($null -ne $env:CLAUDE_END_SESSION_WIKI) { $env:CLAUDE_END_SESSION_WIKI } else { '<unset>' }
    $a = if ($null -ne $env:HIMMEL_WHERE_ARE_WE) { $env:HIMMEL_WHERE_ARE_WE } else { '<unset>' }
    $r = if ($null -ne $env:CRYSTALLIZE_RULES_FILE) { $env:CRYSTALLIZE_RULES_FILE } else { '<unset>' }
    Set-Content -LiteralPath $env:CRYSTALLIZE_ENV_DUMP -Value @("CLAUDE_END_SESSION_WIKI=$w", "HIMMEL_WHERE_ARE_WE=$a", "CRYSTALLIZE_RULES_FILE=$r")
}

if ($mode -eq 'fail') { exit 7 }
if ($mode -eq 'noop') { exit 0 }

$note = $env:CRYSTALLIZE_NOTE
if (-not $note -or -not (Test-Path -LiteralPath $note)) { exit 0 }

# corrupt simulates a half-applied edit (quota kill mid-write): the note is left
# as a truncated fragment — no frontmatter, only one section header.
if ($mode -eq 'corrupt') {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($note, "## Summary`n`nhalf-written fragment`n", $enc)
    exit 0
}

# Rewrite ONLY the Summary body; leave the frontmatter untouched (the script owns
# the crystallized flag from the body diff).
$out = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($line in (Get-Content -LiteralPath $note)) {
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
