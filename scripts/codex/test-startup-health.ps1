<#
.SYNOPSIS
  Hermetic tests for startup-health.ps1 (HIMMEL-747) — twin of test-startup-health.sh.
.DESCRIPTION
  Builds a temp CODEX_HOME per case (synthetic rollout .jsonl naming the session
  thread_id + a synthetic logs_2.sqlite text file carrying the real WARN message
  shapes) and asserts: healthy -> 0; hook-failure -> 1; skill-truncation -> 1;
  a marker under an OLD thread_id does NOT fire (session scoping); oversized
  _where-are-we -> 1; missing CODEX_HOME -> 2.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$DET  = Join-Path $PSScriptRoot 'startup-health.ps1'
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("sh-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$NEW  = '019f3c01-afbf-7ef3-a689-c5be6d9afde0'
$OLD  = '019f0000-0000-7000-8000-000000000000'
$fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { [Console]::Error.WriteLine("  FAIL: $m"); $script:fails++ }

function New-Home([string]$name, [string]$tid, [string]$waw) {
  $h = Join-Path $TMP $name
  $d = Join-Path $h 'sessions/2026/07/07'
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  $f = Join-Path $d "rollout-2026-07-07T11-56-16-$tid.jsonl"
  '{"type":"event_msg","payload":{"type":"token_count"}}' | Set-Content -LiteralPath $f -Encoding utf8
  $rec = [pscustomobject]@{ type = 'response_item'; payload = [pscustomobject]@{ type = 'message'; content = @([pscustomobject]@{ type = 'text'; text = $waw }) } }
  ($rec | ConvertTo-Json -Depth 20 -Compress) | Add-Content -LiteralPath $f -Encoding utf8
  return $h
}
function Set-Db([string]$homeDir, [string]$line) { $line | Set-Content -LiteralPath (Join-Path $homeDir 'logs_2.sqlite') -Encoding utf8 }
function Run([string]$homeDir, [hashtable]$envx = @{}) {
  $env:CODEX_HOME = $homeDir
  $env:WHERE_ARE_WE_BUDGET_BYTES = $(if ($envx.ContainsKey('budget')) { $envx.budget } else { $null })
  $out = & pwsh -NoProfile -File $DET 2>&1
  $rc = $LASTEXITCODE
  $env:CODEX_HOME = $null; $env:WHERE_ARE_WE_BUDGET_BYTES = $null
  return @{ rc = $rc; out = ($out -join "`n") }
}

$small = "<system-reminder>`n# Where are we`nsmall"
$hookLine  = "WARN codex_core_plugins::manifest session_loop{thread_id=__TID__}:x: load_plugins_from_layer_stack: ignoring hooks: found object"
$skillLine = "WARN codex_core_plugins::manifest session_loop{thread_id=__TID__}:built_tools: ignoring interface.defaultPrompt[0]: prompt must be at most 128 characters path=X"

try {
  # 1. healthy
  $h = New-Home 'healthy' $NEW $small
  Set-Db $h "INFO codex_core_skills::service session_loop{thread_id=$NEW}: skills cache cleared padding"
  $r = Run $h
  if ($r.rc -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) { Pass 'healthy -> exit 0, no findings' } else { Fail "healthy rc=$($r.rc) out=$($r.out)" }

  # 2. hook-failure
  $h = New-Home 'hook' $NEW $small
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match '^WARN hook-failure:') { Pass 'hook-failure -> exit 1' } else { Fail "hook rc=$($r.rc) out=$($r.out)" }

  # 3. skill-truncation
  $h = New-Home 'skill' $NEW $small
  Set-Db $h (($skillLine -replace '__TID__', $NEW))
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match 'WARN skill-truncation:') { Pass 'skill-truncation -> exit 1' } else { Fail "skill rc=$($r.rc) out=$($r.out)" }

  # 4. session scoping: marker only under OLD tid
  $h = New-Home 'scope' $NEW $small
  $od = Join-Path $h 'sessions/2026/07/01'; New-Item -ItemType Directory -Force -Path $od | Out-Null
  '{}' | Set-Content -LiteralPath (Join-Path $od "rollout-2026-07-01T00-00-00-$OLD.jsonl") -Encoding utf8
  Set-Db $h ($hookLine -replace '__TID__', $OLD)
  $r = Run $h
  if ($r.rc -eq 0) { Pass 'stale-only markers (old tid) -> exit 0 (scoped out)' } else { Fail "scope rc=$($r.rc) out=$($r.out)" }

  # 5. oversized where-are-we
  $big = "<system-reminder>`n# Where are we`n" + ('x' * 400)
  $h = New-Home 'big' $NEW $big
  Set-Db $h "INFO x session_loop{thread_id=$NEW}: noise padding line here"
  $r = Run $h @{ budget = '200' }
  if ($r.rc -eq 1 -and $r.out -match 'WARN where-are-we-oversized:') { Pass 'oversized where-are-we -> exit 1' } else { Fail "oversized rc=$($r.rc) out=$($r.out)" }
  $r = Run $h @{ budget = '100000' }
  if ($r.rc -eq 0) { Pass 'big block under generous budget -> exit 0' } else { Fail "budget-gate rc=$($r.rc)" }

  # 6. missing CODEX_HOME -> 2
  $r = Run (Join-Path $TMP 'nope/.codex')
  if ($r.rc -eq 2) { Pass 'missing CODEX_HOME -> exit 2' } else { Fail "missing rc=$($r.rc)" }
}
finally {
  Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -eq 0) { Write-Host 'PASS' } else { Write-Host "FAIL ($fails)"; exit 1 }
