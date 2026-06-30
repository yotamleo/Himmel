<#
.SYNOPSIS
  Hermetic tests for sanitize-plugin-hooks.ps1 (HIMMEL-651) — PowerShell twin of
  test-sanitize-plugin-hooks.sh.

.DESCRIPTION
  A temp CODEX_HOME holds fixture plugin-cache hooks.json files (one WITH a
  top-level `description` + a DEEPLY-nested hooks block, one already clean, one
  malformed). Asserts the sanitizer strips only `description`, preserves the
  nested `hooks` block (guards the `ConvertTo-Json -Depth` choice), honours
  -DryRun, is idempotent, leaves clean/malformed files untouched, aggregates the
  count over multiple files, and exits 0 when there is no cache dir. Never
  touches the real ~/.codex.
#>
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Sanitizer = Join-Path $ScriptDir 'sanitize-plugin-hooks.ps1'

$fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Warning "  FAIL: $m"; $script:fails++ }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("san-ps-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$cache = Join-Path $TMP '.codex/plugins/cache'
New-Item -ItemType Directory -Force -Path (Join-Path $cache 'ext-desc/hooks')  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $cache 'ext-desc2/hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $cache 'ext-clean/hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $cache 'ext-bad/hooks')   | Out-Null

$descFile  = Join-Path $cache 'ext-desc/hooks/hooks.json'
$desc2File = Join-Path $cache 'ext-desc2/hooks/hooks.json'
$cleanFile = Join-Path $cache 'ext-clean/hooks/hooks.json'
$badFile   = Join-Path $cache 'ext-bad/hooks/hooks.json'

# WITH top-level description + a deeply-nested hooks block (exercises -Depth).
@'
{
  "description": "External plugin - rejected by Codex",
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "echo hi", "meta": { "a": { "b": { "c": "deep" } } } } ] }
    ]
  }
}
'@ | Set-Content -LiteralPath $descFile -Encoding utf8NoBOM

# A SECOND file with description (exercises multi-file aggregation).
@'
{ "description": "another external", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo two" } ] } ] } }
'@ | Set-Content -LiteralPath $desc2File -Encoding utf8NoBOM

# Already clean (no top-level description).
@'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo bye" } ] } ] } }
'@ | Set-Content -LiteralPath $cleanFile -Encoding utf8NoBOM

# Malformed JSON — must be left untouched, never crash the run.
'{ not valid json' | Set-Content -LiteralPath $badFile -Encoding utf8NoBOM
$badBefore = Get-Content -LiteralPath $badFile -Raw

function Has-Description($path) {
  $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  return ($j.PSObject.Properties.Name -contains 'description')
}

$env:CODEX_HOME = Join-Path $TMP '.codex'
try {
  # --- 1. dry-run reports but mutates nothing ---
  # 6>&1 merges the Information stream (Write-Host) into output so Out-String
  # captures the human-facing report lines.
  $out = (& $Sanitizer -DryRun 6>&1 | Out-String)
  if ($out -match 'WOULD STRIP') { Pass 'dry-run flags a strippable file' } else { Fail 'dry-run did not flag any file' }
  if ($out -match 'DRY-RUN: 2 of 4') { Pass 'dry-run count = 2 of 4' } else { Fail "dry-run count wrong (want 2 of 4): $out" }
  if (Has-Description $descFile) { Pass 'dry-run left description in place' } else { Fail 'dry-run MUTATED ext-desc' }

  # --- 2. real run strips description, preserves nested hooks ---
  $out = (& $Sanitizer 6>&1 | Out-String)
  if ($out -match 'STRIPPED') { Pass 'real run strips' } else { Fail 'real run stripped nothing' }
  if (Has-Description $descFile) { Fail 'description NOT removed from ext-desc' } else { Pass 'description removed from ext-desc' }
  if (Has-Description $desc2File) { Fail 'description NOT removed from ext-desc2' } else { Pass 'description removed from ext-desc2' }

  $j = Get-Content -LiteralPath $descFile -Raw | ConvertFrom-Json
  if ($j.hooks.SessionStart[0].hooks[0].command -eq 'echo hi') { Pass 'hooks block preserved' } else { Fail 'hooks block damaged' }
  # deep nesting survived the ConvertTo-Json -Depth round-trip.
  if ($j.hooks.SessionStart[0].hooks[0].meta.a.b.c -eq 'deep') { Pass 'deeply-nested value preserved (-Depth ok)' } else { Fail 'deep nesting truncated' }

  # multi-file aggregation summary.
  if ($out -match 'sanitized 2 of 4') { Pass 'real-run summary = sanitized 2 of 4' } else { Fail "real-run summary wrong: $out" }

  # clean file untouched.
  $jc = Get-Content -LiteralPath $cleanFile -Raw | ConvertFrom-Json
  if ($jc.hooks.Stop[0].hooks[0].command -eq 'echo bye') { Pass 'clean file left intact' } else { Fail 'clean file changed' }

  # malformed file untouched byte-for-byte.
  if ((Get-Content -LiteralPath $badFile -Raw) -eq $badBefore) { Pass 'malformed file left untouched' } else { Fail 'malformed file was mutated' }

  # --- 3. idempotent re-run ---
  $out = (& $Sanitizer 6>&1 | Out-String)
  if ($out -match 'nothing to sanitize') { Pass 'idempotent re-run' } else { Fail "re-run not idempotent: $out" }
}
finally {
  Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
}

# --- 4. no cache dir -> graceful exit 0 ---
$env:CODEX_HOME = Join-Path $TMP 'empty/.codex'
try {
  $out = (& $Sanitizer 6>&1 | Out-String)
  if ($LASTEXITCODE -eq 0) { Pass 'no-cache exits 0' } else { Fail "no-cache exit $LASTEXITCODE (want 0)" }
  if ($out -match 'no Codex plugin cache') { Pass 'no-cache message present' } else { Fail 'no-cache message missing' }
}
finally {
  Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
}

Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "PASS" } else { Write-Host "FAIL ($fails)"; exit 1 }
