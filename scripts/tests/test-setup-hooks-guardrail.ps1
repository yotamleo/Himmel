#requires -Version 5
# HIMMEL-709 — smoke test for setup-hooks.ps1 -GuardrailMode (parity with the .sh).
# Hermetic: CLAUDE_USER_SETTINGS points at a temp file; never touches ~/.claude.
$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Setup = Join-Path $Here '../setup-hooks.ps1'
$Tmp = Join-Path $env:TEMP ('gblkps_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $Tmp 'himmel/scripts/hooks') | Out-Null
$Settings = Join-Path $Tmp 'settings.json'
'{}' | Set-Content $Settings
$env:CLAUDE_USER_SETTINGS = $Settings
$env:HIMMEL_REPO = (Join-Path $Tmp 'himmel')

function Wrapped-Count {
  $d = Get-Content $Settings -Raw | ConvertFrom-Json
  $c = 0
  foreach ($g in $d.hooks.PreToolUse) { foreach ($h in $g.hooks) { if ($h.command -like '*guardrail-skip-in-himmel.js*') { $c++ } } }
  return $c
}
function Fail($m) { Write-Host "FAIL: $m"; Remove-Item -Recurse -Force $Tmp; exit 1 }

try {
  # 1. global -Yes installs exactly three.
  pwsh -NoProfile -File $Setup -GuardrailMode global -Yes | Out-Null
  if ((Wrapped-Count) -ne 3) { Fail ("expected 3 wrapped, got " + (Wrapped-Count)) }

  # 2. global -> project on a non-tty without -Yes ABORTS (exit 3), no mutation.
  $before = Get-Content $Settings -Raw
  'x' | pwsh -NoProfile -File $Setup -GuardrailMode project *> $null
  if ($LASTEXITCODE -ne 3) { Fail "expected non-tty destructive abort (exit 3), got $LASTEXITCODE" }
  if ((Get-Content $Settings -Raw) -ne $before) { Fail 'settings mutated on aborted project transition' }

  # 3. idempotent re-run reports no changes.
  $out = pwsh -NoProfile -File $Setup -GuardrailMode global -Yes
  if ($out -notmatch 'no changes') { Fail "expected 'no changes' on idempotent, got: $out" }

  # 4. project -Yes removes the block.
  pwsh -NoProfile -File $Setup -GuardrailMode project -Yes | Out-Null
  if ((Wrapped-Count) -ne 0) { Fail ("expected 0 wrapped after remove, got " + (Wrapped-Count)) }

  Write-Host 'PASS: setup-hooks.ps1 -GuardrailMode smoke (install/abort/idempotent/remove)'
}
finally {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
  Remove-Item Env:\CLAUDE_USER_SETTINGS, Env:\HIMMEL_REPO -ErrorAction SilentlyContinue
}
