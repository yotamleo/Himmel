# Integration smoke for scripts/hooks/end-session-wiki.ps1 (HIMMEL-403) — the
# .ps1 is the hook that actually runs on Windows, so the vault-NAME wiring and
# the fail-closed skip are exercised end-to-end here, not just via the lib.
# Run: pwsh scripts/hooks/test-end-session-wiki.ps1
$ErrorActionPreference = 'Stop'
$HOOK = Join-Path $PSScriptRoot 'end-session-wiki.ps1'
$script:fails = 0
function Pass([string]$m) { "PASS: $m" }
function Fail([string]$m) { "FAIL: $m"; $script:fails++ }

$SB = Join-Path ([System.IO.Path]::GetTempPath()) ("eswt-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $SB 'proj\.claude') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SB 'home\Documents\medic\.obsidian') -Force | Out-Null
$transcript = Join-Path $SB 'transcript.jsonl'
Set-Content -LiteralPath $transcript -Value '{"timestamp":"2026-06-17T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"l1\nl2"}]}}'
$cfgPath = Join-Path $SB 'proj\.claude\end-session-wiki.json'
$logPath = Join-Path $SB 'proj\.claude\end-session-wiki.log'
$payload = @{ transcript_path = $transcript; cwd = (Join-Path $SB 'proj'); session_id = 't'; reason = 'other' } | ConvertTo-Json -Compress

function Invoke-Hook {
    $env:USERPROFILE = (Join-Path $SB 'home')
    $env:CLAUDE_PROJECT_DIR = (Join-Path $SB 'proj')
    $env:OBSIDIAN_API_KEY = ''
    Remove-Item Env:\LUNA_VAULT_PATH -ErrorAction SilentlyContinue
    $payload | pwsh -NoProfile -File $HOOK | Out-Null
}
function Notes([string]$root) { Get-ChildItem -Path $root -Recurse -Filter *.md -ErrorAction SilentlyContinue }

try {
    # Case 1: per-repo vault NAME routes via the ~/Documents/<name> convention.
    Set-Content -LiteralPath $cfgPath -Value '{"vault":"medic"}'
    Invoke-Hook
    if (Notes (Join-Path $SB 'home\Documents\medic\sessions')) { Pass 'vault NAME routes to medic via convention' }
    else { Fail 'no note under medic vault' }

    # Case 2: an invalid NAME is fail-closed — skip, no write anywhere, skip logged.
    Notes (Join-Path $SB 'home') | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $cfgPath -Value '{"vault":"../evil"}'
    Invoke-Hook
    if (Notes (Join-Path $SB 'home')) { Fail 'invalid name wrote a note' } else { Pass 'invalid name wrote no note' }
    $log = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
    if ($log -match 'skipped: vault') { Pass 'skip logged' } else { Fail 'skip not logged' }

    $script:reached = $true
}
finally {
    Remove-Item -LiteralPath $SB -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $script:reached) { 'FAILED: test did not run to completion'; exit 1 }
if ($script:fails -eq 0) { 'ALL PASS'; exit 0 } else { "$($script:fails) FAILED"; exit 1 }
