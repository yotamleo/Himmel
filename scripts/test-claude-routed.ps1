#Requires -Version 7
<#
  Hermetic tests for scripts/claude-routed.ps1 (HIMMEL-666) - Windows twin of
  test-claude-routed.sh, itself a copy-and-edit of the WS1 claude-glm suite where
  ONLY the backend block differs (loopback OmniRoute router + OmniRoute client key).
  Sandbox: fake $env:USERPROFILE -> temp dir, a mock claude.cmd on a prepended PATH
  that dumps its env (KEY=VALUE) to $env:MOCK_ENV_OUT and records its full
  passthrough argv to $env:MOCK_ARGV_OUT. The launcher runs in a CHILD pwsh so a
  scenario's `exit 2`/`exit 3`/`exit 4` cannot terminate this harness. Never touches
  the real user profile or ~/.claude.
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$Launcher  = Join-Path $ScriptDir 'claude-routed.ps1'
# Directory holding pwsh itself — a PATH that keeps pwsh (needed to spawn the
# launcher) but drops node lets T17 simulate "node absent entirely".
$PwshDir   = Split-Path -Parent (Get-Command pwsh -ErrorAction Stop).Source

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }
function FileHas($path, $needle) { (Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -SimpleMatch -Quiet -Pattern $needle) }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-routed-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null

# snapshot env we mutate per-invocation; restored in the outer finally
$OrigEnv = @{}
foreach ($n in 'USERPROFILE', 'OMNIROUTE_API_KEY', 'CLAUDE_ROUTED_DOTENV_ROOT', 'OMNIROUTE_PORT', 'MOCK_ENV_OUT', 'MOCK_ARGV_OUT', 'PATH') {
  $OrigEnv[$n] = [Environment]::GetEnvironmentVariable($n)
}

function New-Sandbox {
  # fresh sandbox: fake HOME with a minimal ~/.claude, mock claude.cmd in BIN
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $script:FAKEHOME = Join-Path $TMP "$id-home"
  $script:WORK     = Join-Path $TMP "$id-work"
  $script:BIN      = Join-Path $TMP "$id-bin"
  $script:PORT     = ''   # default: launcher falls back to documented default port 20128
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude') | Out-Null
  New-Item -ItemType Directory -Force -Path $WORK | Out-Null
  New-Item -ItemType Directory -Force -Path $BIN | Out-Null
  '{"model":"claude-fable-5[1m]","env":{"ANTHROPIC_MODEL":"x","HIMMEL_INITIATIVE":"1"}}' |
    Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\settings.json') -NoNewline
  'secret' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\.credentials.json') -NoNewline
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\plugins\claude-hud') | Out-Null
  '{"hud":true}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\claude-hud\config.json') -NoNewline
  # Mock claude: a launch invocation dumps env AND records its full passthrough
  # argv to a SEPARATE sink (T13 asserts the claude short flags arrived verbatim).
  # A magic --mock-exit-7 arg makes the mock exit 7 so T14 can prove the launcher
  # propagates claude's exit code (via the trailing `exit $LASTEXITCODE`).
  $mock = @'
@echo off
echo %*>>"%MOCK_ARGV_OUT%"
pwsh -NoProfile -Command "Get-ChildItem env: | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value } | Set-Content -LiteralPath $env:MOCK_ENV_OUT"
echo %*| findstr /C:"--mock-exit-7" >nul && exit /b 7
exit /b 0
'@
  Set-Content -LiteralPath (Join-Path $BIN 'claude.cmd') -Value $mock -Encoding Ascii
  $script:ChildEnv  = Join-Path $WORK 'child-env.txt'
  $script:ArgvOut   = Join-Path $WORK 'claude-argv.txt'
  $script:OutTxt    = Join-Path $WORK 'out.txt'
  $script:KEY = ''
}

# Run the launcher in a child pwsh under the prepared sandbox; returns exit code.
# Output (stdout+stderr) is captured to $OutTxt.
function Invoke-Launcher {
  param([string[]]$LArgs = @(), [switch]$NoNode)
  if ($script:KEY) { $env:OMNIROUTE_API_KEY = $script:KEY } else { Remove-Item Env:OMNIROUTE_API_KEY -ErrorAction SilentlyContinue }
  if ($script:PORT) { $env:OMNIROUTE_PORT = $script:PORT } else { Remove-Item Env:OMNIROUTE_PORT -ErrorAction SilentlyContinue }
  $env:USERPROFILE               = $FAKEHOME
  $env:CLAUDE_ROUTED_DOTENV_ROOT = $WORK
  $env:MOCK_ENV_OUT              = $ChildEnv
  $env:MOCK_ARGV_OUT            = $ArgvOut
  if ($NoNode) {
    # PATH with pwsh (to spawn the launcher) but WITHOUT the real node dir, so the
    # launcher's `& node` throws CommandNotFoundException — simulates node absent.
    $env:PATH = $BIN + [IO.Path]::PathSeparator + $PwshDir
  } else {
    $env:PATH = $BIN + [IO.Path]::PathSeparator + $OrigEnv['PATH']
  }
  Push-Location $WORK
  try {
    & pwsh -NoProfile -File $Launcher @LArgs 2>&1 | Out-File -LiteralPath $OutTxt -Encoding utf8
    return $LASTEXITCODE
  } finally {
    Pop-Location
  }
}

function Assert-Exit($got, $want, $name) {
  if ($got -eq $want) { Pass $name } else { Fail "$name (exit $got, want $want)"; if (Test-Path -LiteralPath $OutTxt) { Get-Content -LiteralPath $OutTxt | ForEach-Object { Write-Host "    | $_" } } }
}

try {
  # --- T1: missing key -> exit 2, claude never launched ---
  New-Sandbox; $script:KEY = ''
  Assert-Exit (Invoke-Launcher) 2 'missing key exits 2'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched without key' } else { Pass 'claude not launched without key' }

  # --- T2: key set -> exit 0 and all eight env vars reach the child.
  # Backend block differs from claude-glm: loopback router base URL (default port
  # 20128) + auth from OMNIROUTE_API_KEY + config dir ~/.claude-routed. Tier aliases
  # stay the GLM values (the router config defines these aliases). ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'launch with key'
  foreach ($pair in @(
      'ANTHROPIC_BASE_URL=http://127.0.0.1:20128',
      'ANTHROPIC_AUTH_TOKEN=omni-test-123',
      'ANTHROPIC_MODEL=glm-5.2[1m]',
      'ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7',
      'ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2[1m]',
      'ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2[1m]',
      'CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000',
      ('CLAUDE_CONFIG_DIR=' + (Join-Path $FAKEHOME '.claude-routed')))) {
    if (FileHas $ChildEnv $pair) { Pass "child env has $pair" } else { Fail "child env missing $pair" }
  }

  # --- T2b: OMNIROUTE_PORT override -> child sees the overridden loopback port.
  # Loopback host is FIXED (127.0.0.1) — only the port is the env seam. ---
  New-Sandbox; $script:KEY = 'omni-test-123'; $script:PORT = '9999'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'port override launches'
  if (FileHas $ChildEnv 'ANTHROPIC_BASE_URL=http://127.0.0.1:9999') { Pass 'OMNIROUTE_PORT override reached child' } else { Fail 'OMNIROUTE_PORT override did not reach child' }

  # --- T3: key never echoed to the launcher's stdout/stderr ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'launch for key-echo check'
  if (FileHas $OutTxt 'omni-test-123') { Fail 'key echoed to output' } else { Pass 'key not echoed to output' }

  # --- T3b: key resolvable from a repo .env ONLY (the dotenv path) ---
  New-Sandbox; $script:KEY = ''
  'OMNIROUTE_API_KEY=from-dotenv-456' | Set-Content -LiteralPath (Join-Path $WORK '.env')  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'key from .env launches'
  if (FileHas $ChildEnv 'ANTHROPIC_AUTH_TOKEN=from-dotenv-456') { Pass '.env key reached child' } else { Fail '.env key did not reach child' }  # gitleaks:allow

  # --- T4: first launch seeds config dir; credentials NEVER copied ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\commands') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\plugins\marketplaces') | Out-Null
  'x'  | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\CLAUDE.md') -NoNewline
  '{}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\installed_plugins.json') -NoNewline
  Assert-Exit (Invoke-Launcher) 0 'seed on first launch'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\plugins\claude-hud\config.json')) { Pass 'claude-hud config seeded' } else { Fail 'claude-hud config not seeded' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\CLAUDE.md')) { Pass 'CLAUDE.md seeded' } else { Fail 'CLAUDE.md not seeded' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\plugins\installed_plugins.json')) { Pass 'plugin registry seeded' } else { Fail 'plugin registry not seeded' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\.credentials.json')) { Fail 'credentials copied' } else { Pass 'credentials not copied' }

  # --- T5: seeded settings.json sanitized (no model key, no env.ANTHROPIC_*) ---
  $seeded = Join-Path $FAKEHOME '.claude-routed\settings.json'
  if (Test-Path -LiteralPath $seeded) {
    $s = Get-Content -LiteralPath $seeded -Raw | ConvertFrom-Json
    if ($s.PSObject.Properties.Name -contains 'model') { Fail 'model key survived sanitization' } else { Pass 'model key stripped' }
    $envKeys = if ($s.env) { $s.env.PSObject.Properties.Name } else { @() }
    if ($envKeys | Where-Object { $_.StartsWith('ANTHROPIC_') }) { Fail 'env.ANTHROPIC_* survived' } else { Pass 'env.ANTHROPIC_* stripped' }
    if ($s.env.HIMMEL_INITIATIVE -eq '1') { Pass 'non-ANTHROPIC env entry preserved' } else { Fail 'non-ANTHROPIC env entry lost' }
  } else { Fail 'settings.json not seeded' }

  # --- T6: no key material anywhere under the seeded dir ---
  $leaked = Get-ChildItem -LiteralPath (Join-Path $FAKEHOME '.claude-routed') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { Select-String -LiteralPath $_.FullName -SimpleMatch -Quiet -Pattern 'omni-test-123' }  # gitleaks:allow
  if ($leaked) { Fail 'key leaked into config dir' } else { Pass 'no key material in config dir' }

  # --- T7: --reseed refreshes seeded files, never resurrects denied files ---
  'updated' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\CLAUDE.md') -NoNewline
  'secret'  | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\history.jsonl') -NoNewline
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 0 'reseed'
  if (FileHas (Join-Path $FAKEHOME '.claude-routed\CLAUDE.md') 'updated') { Pass 'reseed refreshed CLAUDE.md' } else { Fail 'reseed did not refresh' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\history.jsonl')) { Fail 'denied file seeded' } else { Pass 'denied file not seeded' }

  # --- T8: .salus marker -> refuse exit 3, -Force does NOT override (guard survives
  # the variant — the mandated red path) ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  New-Item -ItemType File -Force -Path (Join-Path $WORK '.salus') | Out-Null
  Assert-Exit (Invoke-Launcher) 3 'salus refuses'
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 3 'salus refuses despite -Force'

  # --- T9: denylisted cwd -> refuse without -Force, proceed with it. Guard config
  # is DELIBERATELY read from ~/.config/claude-glm (shared source of truth), NOT a
  # per-lane ~/.config/claude-routed — a claude-glm denylist hit must refuse routed too. ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  $WORK | Set-Content -LiteralPath (Join-Path $FAKEHOME '.config\claude-glm\egress-denylist')
  Assert-Exit (Invoke-Launcher) 3 'shared claude-glm denylist refuses routed'
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 0 'denylist + -Force proceeds'

  # --- T10: PHI root file (shared claude-glm config) -> absolute refuse even with -Force ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  $WORK | Set-Content -LiteralPath (Join-Path $FAKEHOME '.config\claude-glm\phi-roots')
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 3 'phi-root refuses despite -Force'

  # --- T10b: config roots normalized (trailing slash + CRLF) before matching ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  ((Split-Path -Parent $WORK) + '\') | Set-Content -LiteralPath (Join-Path $FAKEHOME '.config\claude-glm\phi-roots')
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 3 'phi-root trailing-slash still refuses descendant despite -Force'

  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $FAKEHOME '.config\claude-glm\egress-denylist'), "$WORK`r`n")
  Assert-Exit (Invoke-Launcher) 3 'denylist CRLF line still refuses'

  # --- T11: clean cwd proceeds silently ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'clean proceeds'

  # --- T12: launch output contains an off-peak annotation line (routed lane is
  # GLM-behind-the-router — the advisory still applies) ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'annotation present'
  if (FileHas $OutTxt 'GLM peak window') { Pass 'off-peak annotation emitted' } else { Fail 'no off-peak annotation' }

  # --- T13: claude short flags pass through verbatim (NOT hijacked by PS common params) ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed', '-p', 'hello', '-d')) 0 'passthrough launch'
  if (FileHas $ArgvOut '-p hello -d') { Pass 'claude short flags passed verbatim' } else { Fail 'claude short flags NOT passed verbatim'; if (Test-Path -LiteralPath $ArgvOut) { Get-Content -LiteralPath $ArgvOut | ForEach-Object { Write-Host "    argv| $_" } } }
  if (FileHas $ArgvOut '-Reseed') { Fail 'leading -Reseed leaked to claude argv' } else { Pass 'leading -Reseed consumed, not forwarded' }

  # --- T14: the launcher propagates claude's exit code (trailing exit $LASTEXITCODE) ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher -LArgs @('--mock-exit-7')) 7 'exit code propagates from claude'

  # --- T15: seeding is transactional — a failed sanitize exits 4, launches nothing,
  # writes no .seeded sentinel; the NEXT launch (node restored) self-heals. ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  $nodeShim = Join-Path $BIN 'node.cmd'
  Set-Content -LiteralPath $nodeShim -Value "@echo off`r`nexit /b 1" -Encoding Ascii
  Assert-Exit (Invoke-Launcher) 4 'sanitize failure exits 4'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite failed seed' } else { Pass 'claude not launched on failed seed' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\.seeded')) { Fail 'sentinel written despite failed seed' } else { Pass 'no sentinel on failed seed' }
  Remove-Item -LiteralPath $nodeShim -Force
  Assert-Exit (Invoke-Launcher) 0 'second launch self-heals after node restored'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\settings.json')) { Pass 'settings.json seeded on self-heal' } else { Fail 'settings.json not seeded on self-heal' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\.seeded')) { Pass 'sentinel written on self-heal' } else { Fail 'sentinel not written on self-heal' }

  # --- T16: a FAILED -Reseed clears the stale sentinel, so a later plain launch
  # re-seeds (and fails again while node is broken) instead of proceeding with the
  # stale tree; node restored -> plain launch self-heals. ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'initial seed ok'              # sentinel written
  $nodeShim = Join-Path $BIN 'node.cmd'
  Set-Content -LiteralPath $nodeShim -Value "@echo off`r`nexit /b 1" -Encoding Ascii
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 4 'reseed with broken node exits 4'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\.seeded')) { Fail 'stale sentinel survived failed reseed' } else { Pass 'stale sentinel cleared by failed reseed' }
  Remove-Item -LiteralPath $ChildEnv -Force -ErrorAction SilentlyContinue
  Assert-Exit (Invoke-Launcher) 4 'plain launch after failed reseed still exits 4'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched with a stale-sentinel tree' } else { Pass 'claude not launched with a stale-sentinel tree' }
  Remove-Item -LiteralPath $nodeShim -Force
  Assert-Exit (Invoke-Launcher) 0 'plain launch self-heals after node restored'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\.seeded')) { Pass 'sentinel written on self-heal' } else { Fail 'sentinel not written on self-heal' }

  # --- T17: node ENTIRELY ABSENT from PATH -> exit 4 (the `& node` CommandNotFound
  # exception must map to the "4 = failed seed" contract, not a raw exit 1). ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher -NoNode) 4 'node missing entirely exits 4'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite missing node' } else { Pass 'claude not launched when node missing' }
  if (FileHas $OutTxt 'FAILED to sanitize settings.json') { Pass 'node-missing emits the failed-seed message' } else { Fail 'node-missing did not emit the failed-seed message' }

  # --- T17b: a Copy-Item failure inside the allowlisted seed copy block maps to
  # exit 4 (the "failed seed" contract), never a raw exit 1, and never launches
  # claude. Fixture: the child launcher cannot read an exclusively locked source. ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  $lockedSeed = Join-Path $FAKEHOME '.claude\CLAUDE.md'
  'locked' | Set-Content -LiteralPath $lockedSeed -NoNewline
  $lock = [System.IO.File]::Open($lockedSeed, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    Assert-Exit (Invoke-Launcher) 4 'seed Copy-Item failure exits 4'
  } finally {
    $lock.Dispose()
  }
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite seed Copy-Item failure' } else { Pass 'claude not launched on seed Copy-Item failure' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-routed\.seeded')) { Fail 'sentinel written despite seed Copy-Item failure' } else { Pass 'no sentinel on seed Copy-Item failure' }
  if (FileHas $OutTxt 'FAILED to seed config dir') { Pass 'copy failure emits the failed-seed message' } else { Fail 'copy failure did not emit the failed-seed message' }

  # --- T18 (guard I7): phi-roots that is a DIRECTORY (not a readable regular file)
  # fails CLOSED with exit 3, never silently allows egress, never launches claude.
  # PS twin of bash T17 — proves the PS guard maps the not-a-leaf case to the
  # bash-parity "failing closed." message + exit 3 (not a raw exit-1 exception). ---
  New-Sandbox; $script:KEY = 'omni-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm\phi-roots') | Out-Null
  Assert-Exit (Invoke-Launcher) 3 'phi-roots as directory fails closed'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite unreadable phi-roots' } else { Pass 'claude not launched on unreadable phi-roots' }
  if (FileHas $OutTxt 'failing closed') { Pass 'phi-roots dir emits the failing-closed message' } else { Fail 'no failing-closed message on phi-roots dir' }

  Write-Host ''
  if ($script:fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fails) failure(s)" -ForegroundColor Red; exit 1 }
}
finally {
  foreach ($n in $OrigEnv.Keys) {
    if ($null -eq $OrigEnv[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:$n" $OrigEnv[$n] }
  }
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
