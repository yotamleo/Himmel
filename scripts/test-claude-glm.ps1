#Requires -Version 7
<#
  Hermetic tests for scripts/claude-glm.ps1 (HIMMEL-665) - Windows twin of
  test-claude-glm.sh. Sandbox: fake $env:USERPROFILE -> temp dir, a mock
  claude.cmd on a prepended PATH that dumps its env (KEY=VALUE) to
  $env:MOCK_ENV_OUT and records its full passthrough argv to $env:MOCK_ARGV_OUT.
  The launcher runs in a CHILD pwsh so a scenario's `exit 2`/`exit 3`/`exit 4`
  cannot terminate this harness. Never touches the real user profile or ~/.claude.
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$Launcher  = Join-Path $ScriptDir 'claude-glm.ps1'
# Directory holding pwsh itself — a PATH that keeps pwsh (needed to spawn the
# launcher) but drops node lets T17 simulate "node absent entirely".
$PwshDir   = Split-Path -Parent (Get-Command pwsh -ErrorAction Stop).Source
# Directory holding node — a PATH of node + pwsh (but neither the sandbox bin's
# mock claude nor the host PATH) lets the no-claude test resolve node for seeding
# while leaving `claude` unresolvable.
$NodeDir   = Split-Path -Parent (Get-Command node -ErrorAction Stop).Source

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }
function FileHas($path, $needle) { (Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -SimpleMatch -Quiet -Pattern $needle) }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-glm-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null

# snapshot env we mutate per-invocation; restored in the outer finally
$OrigEnv = @{}
foreach ($n in 'USERPROFILE', 'ZAI_API_KEY', 'CLAUDE_GLM_DOTENV_ROOT', 'MOCK_ENV_OUT', 'MOCK_ARGV_OUT', 'PATH') {
  $OrigEnv[$n] = [Environment]::GetEnvironmentVariable($n)
}

function New-Sandbox {
  # fresh sandbox: fake HOME with a minimal ~/.claude, mock claude.cmd in BIN
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $script:FAKEHOME = Join-Path $TMP "$id-home"
  $script:WORK     = Join-Path $TMP "$id-work"
  $script:BIN      = Join-Path $TMP "$id-bin"
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
  param([string[]]$LArgs = @(), [switch]$NoNode, [switch]$NoClaude)
  if ($script:KEY) { $env:ZAI_API_KEY = $script:KEY } else { Remove-Item Env:ZAI_API_KEY -ErrorAction SilentlyContinue }
  $env:USERPROFILE            = $FAKEHOME
  $env:CLAUDE_GLM_DOTENV_ROOT = $WORK
  $env:MOCK_ENV_OUT           = $ChildEnv
  $env:MOCK_ARGV_OUT          = $ArgvOut
  if ($NoNode) {
    # PATH with pwsh (to spawn the launcher) but WITHOUT the real node dir, so the
    # launcher's `& node` throws CommandNotFoundException — simulates node absent.
    $env:PATH = $BIN + [IO.Path]::PathSeparator + $PwshDir
  } elseif ($NoClaude) {
    # node present (seeding needs it) + pwsh, but neither the sandbox bin's mock
    # claude nor the host PATH — so `claude` is unresolvable and the pre-launch
    # guard fires (exit 5). $BIN is omitted so its claude.cmd cannot resolve.
    $env:PATH = $NodeDir + [IO.Path]::PathSeparator + $PwshDir
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

  # --- T2: key set -> exit 0 and all eight env vars reach the child ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'launch with key'
  foreach ($pair in @(
      'ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic',
      'ANTHROPIC_AUTH_TOKEN=zai-test-123',
      'ANTHROPIC_MODEL=glm-5.2[1m]',
      'ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7',
      'ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2[1m]',
      'ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2[1m]',
      'CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000',
      ('CLAUDE_CONFIG_DIR=' + (Join-Path $FAKEHOME '.claude-glm')))) {
    if (FileHas $ChildEnv $pair) { Pass "child env has $pair" } else { Fail "child env missing $pair" }
  }

  # --- T3: key never echoed to the launcher's stdout/stderr ---
  if (FileHas $OutTxt 'zai-test-123') { Fail 'key echoed to output' } else { Pass 'key not echoed to output' }

  # --- T3b: key resolvable from a repo .env ONLY (the dotenv path) ---
  New-Sandbox; $script:KEY = ''
  'ZAI_API_KEY=from-dotenv-456' | Set-Content -LiteralPath (Join-Path $WORK '.env')  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'key from .env launches'
  if (FileHas $ChildEnv 'ANTHROPIC_AUTH_TOKEN=from-dotenv-456') { Pass '.env key reached child' } else { Fail '.env key did not reach child' }  # gitleaks:allow

  # --- T4: first launch seeds config dir; credentials NEVER copied ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\commands') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\plugins\marketplaces') | Out-Null
  'x'  | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\CLAUDE.md') -NoNewline
  '{}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\installed_plugins.json') -NoNewline
  Assert-Exit (Invoke-Launcher) 0 'seed on first launch'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\claude-hud\config.json')) { Pass 'claude-hud config seeded' } else { Fail 'claude-hud config not seeded' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\CLAUDE.md')) { Pass 'CLAUDE.md seeded' } else { Fail 'CLAUDE.md not seeded' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\installed_plugins.json')) { Pass 'plugin registry seeded' } else { Fail 'plugin registry not seeded' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.credentials.json')) { Fail 'credentials copied' } else { Pass 'credentials not copied' }

  # --- T5: seeded settings.json sanitized (no model key, no env.ANTHROPIC_*) ---
  $seeded = Join-Path $FAKEHOME '.claude-glm\settings.json'
  if (Test-Path -LiteralPath $seeded) {
    $s = Get-Content -LiteralPath $seeded -Raw | ConvertFrom-Json
    if ($s.PSObject.Properties.Name -contains 'model') { Fail 'model key survived sanitization' } else { Pass 'model key stripped' }
    $envKeys = if ($s.env) { $s.env.PSObject.Properties.Name } else { @() }
    if ($envKeys | Where-Object { $_.StartsWith('ANTHROPIC_') }) { Fail 'env.ANTHROPIC_* survived' } else { Pass 'env.ANTHROPIC_* stripped' }
    if ($s.env.HIMMEL_INITIATIVE -eq '1') { Pass 'non-ANTHROPIC env entry preserved' } else { Fail 'non-ANTHROPIC env entry lost' }
  } else { Fail 'settings.json not seeded' }

  # --- T6: no key material anywhere under the seeded dir ---
  $leaked = Get-ChildItem -LiteralPath (Join-Path $FAKEHOME '.claude-glm') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { Select-String -LiteralPath $_.FullName -SimpleMatch -Quiet -Pattern 'zai-test-123' }  # gitleaks:allow
  if ($leaked) { Fail 'key leaked into config dir' } else { Pass 'no key material in config dir' }

  # --- T7: --reseed refreshes seeded files, never resurrects denied files ---
  'updated' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\CLAUDE.md') -NoNewline
  'secret'  | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\history.jsonl') -NoNewline
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 0 'reseed'
  if (FileHas (Join-Path $FAKEHOME '.claude-glm\CLAUDE.md') 'updated') { Pass 'reseed refreshed CLAUDE.md' } else { Fail 'reseed did not refresh' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\history.jsonl')) { Fail 'denied file seeded' } else { Pass 'denied file not seeded' }

  # --- T7b: stale seed auto-refreshes on plain launch (HIMMEL-819) — source
  # settings.json newer than the sentinel triggers a reseed without -Reseed. ---
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')).LastWriteTimeUtc = [datetime]'2020-01-01'
  '{"env":{"HIMMEL_INITIATIVE":"1"},"marker":"lean-profile-v2"}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\settings.json') -NoNewline
  Assert-Exit (Invoke-Launcher) 0 'stale seed auto-refreshes'
  if (FileHas (Join-Path $FAKEHOME '.claude-glm\settings.json') 'lean-profile-v2') { Pass 'stale seed refreshed on plain launch' } else { Fail 'stale seed not refreshed on plain launch' }

  # --- T7c: fresh sentinel -> plain launch does NOT reseed (no churn) ---
  # (HIMMEL-828 Part B: the subtree sources are set old here too, so the widened
  # staleness check keeps its no-churn guarantee when nothing has drifted.)
  '{"local":"tamper-survives"}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude-glm\settings.json') -NoNewline
  foreach ($srcRel in @('.claude\settings.json', '.claude\plugins\installed_plugins.json', '.claude\plugins\known_marketplaces.json',
                        '.claude\commands', '.claude\skills', '.claude\hooks', '.claude\agents', '.claude\plugins\marketplaces')) {
    $p = Join-Path $FAKEHOME $srcRel
    if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc = [datetime]'2020-01-01' }
  }
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')).LastWriteTimeUtc = [datetime]::UtcNow
  Assert-Exit (Invoke-Launcher) 0 'fresh sentinel skips reseed'
  if (FileHas (Join-Path $FAKEHOME '.claude-glm\settings.json') 'tamper-survives') { Pass 'fresh sentinel skipped reseed' } else { Fail 'fresh sentinel still reseeded' }

  # --- T7d: deleted source triggers reseed and the lane copy is removed (true mirror) ---
  Remove-Item -LiteralPath (Join-Path $FAKEHOME '.claude\settings.json') -Force
  Assert-Exit (Invoke-Launcher) 0 'deleted source triggers reseed'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\settings.json')) { Fail 'stale settings copy survived source deletion' } else { Pass 'stale settings copy removed on source deletion' }

  # --- T7e: CLAUDE_LANE_AUTO_RESEED=0 opt-out — stale state left alone on plain launch ---
  '{"env":{"HIMMEL_INITIATIVE":"1"},"marker":"optout-should-not-land"}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\settings.json') -NoNewline
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')).LastWriteTimeUtc = [datetime]'2020-01-01'
  $env:CLAUDE_LANE_AUTO_RESEED = '0'
  Assert-Exit (Invoke-Launcher) 0 'opt-out skips auto-reseed'
  Remove-Item Env:CLAUDE_LANE_AUTO_RESEED
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\settings.json')) { Fail 'opt-out still auto-reseeded' } else { Pass 'opt-out skipped auto-reseed' }
  # restore a sane seeded state for the tests below
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 0 'restore reseed'

  # --- T7f: plugin-manifest sources participate in staleness AND deletion mirroring ---
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\plugins') | Out-Null
  '{"m":1}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\installed_plugins.json') -NoNewline
  '{"k":1}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\known_marketplaces.json') -NoNewline
  Assert-Exit (Invoke-Launcher) 0 'manifest newer triggers reseed'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\installed_plugins.json')) { Pass 'installed_plugins reseeded on manifest change' } else { Fail 'installed_plugins not reseeded on manifest change' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\known_marketplaces.json')) { Pass 'known_marketplaces reseeded on manifest change' } else { Fail 'known_marketplaces not reseeded on manifest change' }
  Remove-Item -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\known_marketplaces.json') -Force
  Assert-Exit (Invoke-Launcher) 0 'deleted manifest mirrors removal'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\known_marketplaces.json')) { Fail 'stale known_marketplaces copy survived source deletion' } else { Pass 'known_marketplaces copy removed on source deletion' }

  # --- T7g: explicit -Reseed still seeds while the opt-out is set ---
  '{"local":"tamper2"}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude-glm\settings.json') -NoNewline
  $env:CLAUDE_LANE_AUTO_RESEED = '0'
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 0 'explicit reseed wins over opt-out'
  Remove-Item Env:CLAUDE_LANE_AUTO_RESEED
  if (FileHas (Join-Path $FAKEHOME '.claude-glm\settings.json') 'tamper2') { Fail '-Reseed under opt-out did not reseed' } else { Pass '-Reseed wins over opt-out' }

  # --- T8: .salus marker -> refuse exit 3, --force does NOT override ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType File -Force -Path (Join-Path $WORK '.salus') | Out-Null
  Assert-Exit (Invoke-Launcher) 3 'salus refuses'
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 3 'salus refuses despite -Force'

  # --- T9: denylisted cwd -> refuse without -Force, proceed with it ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  $WORK | Set-Content -LiteralPath (Join-Path $FAKEHOME '.config\claude-glm\egress-denylist')
  Assert-Exit (Invoke-Launcher) 3 'denylist refuses'
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 0 'denylist + -Force proceeds'

  # --- T10: PHI root file -> absolute refuse even with -Force ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  $WORK | Set-Content -LiteralPath (Join-Path $FAKEHOME '.config\claude-glm\phi-roots')
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 3 'phi-root refuses despite -Force'

  # --- T10b: config roots normalized (trailing slash + CRLF) before matching ---
  # Trailing-separator root: point phi-roots at WORK's PARENT WITH a trailing
  # backslash -> WORK is a strict descendant -> absolute refuse.
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  ((Split-Path -Parent $WORK) + '\') | Set-Content -LiteralPath (Join-Path $FAKEHOME '.config\claude-glm\phi-roots')
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 3 'phi-root trailing-slash still refuses descendant despite -Force'

  # CRLF denylist line (himmel targets Windows): "$WORK" + CRLF must still match.
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $FAKEHOME '.config\claude-glm\egress-denylist'), "$WORK`r`n")
  Assert-Exit (Invoke-Launcher) 3 'denylist CRLF line still refuses'

  # --- T11: clean cwd proceeds silently ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'clean proceeds'

  # --- T12: launch output contains an off-peak annotation line ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'annotation present'
  if (FileHas $OutTxt 'GLM peak window') { Pass 'off-peak annotation emitted' } else { Fail 'no off-peak annotation' }

  # --- T13: claude short flags pass through verbatim (NOT hijacked by PS common params) ---
  # -p/-d/-v are real `claude` flags. A param(... ValueFromRemainingArguments ...) block
  # makes the launcher an advanced function, so PowerShell binds -p (ambiguous
  # -ProgressAction/-PipelineVariable => hard crash), -d (-Debug) and -v (-Verbose)
  # BEFORE the manual loop ever runs. A plain script does no such binding: every arg
  # arrives as a literal string. Prove -p hello -d reach claude intact, and a LEADING
  # -Reseed is still consumed (never forwarded).
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed', '-p', 'hello', '-d')) 0 'passthrough launch'
  if (FileHas $ArgvOut '-p hello -d') { Pass 'claude short flags passed verbatim' } else { Fail 'claude short flags NOT passed verbatim'; if (Test-Path -LiteralPath $ArgvOut) { Get-Content -LiteralPath $ArgvOut | ForEach-Object { Write-Host "    argv| $_" } } }
  if (FileHas $ArgvOut '-Reseed') { Fail 'leading -Reseed leaked to claude argv' } else { Pass 'leading -Reseed consumed, not forwarded' }

  # --- T14: the launcher propagates claude's exit code (trailing exit $LASTEXITCODE) ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher -LArgs @('--mock-exit-7')) 7 'exit code propagates from claude'

  # --- T15: seeding is transactional — a failed sanitize exits 4, launches nothing,
  # writes no .seeded sentinel; the NEXT launch (node restored) self-heals. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  # Shadow node with a failing shim (BIN leads PATH) so the sanitizer exits nonzero.
  $nodeShim = Join-Path $BIN 'node.cmd'
  Set-Content -LiteralPath $nodeShim -Value "@echo off`r`nexit /b 1" -Encoding Ascii
  Assert-Exit (Invoke-Launcher) 4 'sanitize failure exits 4'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite failed seed' } else { Pass 'claude not launched on failed seed' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')) { Fail 'sentinel written despite failed seed' } else { Pass 'no sentinel on failed seed' }
  Remove-Item -LiteralPath $nodeShim -Force
  Assert-Exit (Invoke-Launcher) 0 'second launch self-heals after node restored'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\settings.json')) { Pass 'settings.json seeded on self-heal' } else { Fail 'settings.json not seeded on self-heal' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')) { Pass 'sentinel written on self-heal' } else { Fail 'sentinel not written on self-heal' }

  # --- T16: a FAILED -Reseed clears the stale sentinel, so a later plain launch
  # re-seeds (and fails again while node is broken) instead of proceeding with the
  # stale tree; node restored -> plain launch self-heals. Regression for the
  # "sentinel written LAST but never removed at seeder START" gap. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'initial seed ok'              # sentinel written
  $nodeShim = Join-Path $BIN 'node.cmd'
  Set-Content -LiteralPath $nodeShim -Value "@echo off`r`nexit /b 1" -Encoding Ascii
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 4 'reseed with broken node exits 4'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')) { Fail 'stale sentinel survived failed reseed' } else { Pass 'stale sentinel cleared by failed reseed' }
  Remove-Item -LiteralPath $ChildEnv -Force -ErrorAction SilentlyContinue
  Assert-Exit (Invoke-Launcher) 4 'plain launch after failed reseed still exits 4'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched with a stale-sentinel tree' } else { Pass 'claude not launched with a stale-sentinel tree' }
  Remove-Item -LiteralPath $nodeShim -Force
  Assert-Exit (Invoke-Launcher) 0 'plain launch self-heals after node restored'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')) { Pass 'sentinel written on self-heal' } else { Fail 'sentinel not written on self-heal' }

  # --- T17: node ENTIRELY ABSENT from PATH -> exit 4 (the `& node` CommandNotFound
  # exception must map to the "4 = failed seed" contract, not a raw exit 1). ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher -NoNode) 4 'node missing entirely exits 4'
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite missing node' } else { Pass 'claude not launched when node missing' }
  if (FileHas $OutTxt 'FAILED to sanitize settings.json') { Pass 'node-missing emits the failed-seed message' } else { Fail 'node-missing did not emit the failed-seed message' }

  # --- T17b (HIMMEL-820): a Copy-Item failure inside the allowlisted seed copy
  # block maps to exit 4 (the "failed seed" contract), never a raw exit 1, and
  # never launches claude. Twin of routed's T17b — the CLAUDE.md copy runs in the
  # remaining seed body that #1044 left OUTSIDE any try/catch; this pins the
  # function-level wrap. Fixture: the child launcher cannot read an exclusively
  # locked source. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  $lockedSeed = Join-Path $FAKEHOME '.claude\CLAUDE.md'
  'locked' | Set-Content -LiteralPath $lockedSeed -NoNewline
  $lock = [System.IO.File]::Open($lockedSeed, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    Assert-Exit (Invoke-Launcher) 4 'seed Copy-Item failure exits 4'
  } finally {
    $lock.Dispose()
  }
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite seed Copy-Item failure' } else { Pass 'claude not launched on seed Copy-Item failure' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')) { Fail 'sentinel written despite seed Copy-Item failure' } else { Pass 'no sentinel on seed Copy-Item failure' }
  if (FileHas $OutTxt 'FAILED to seed config dir') { Pass 'copy failure emits the failed-seed message' } else { Fail 'copy failure did not emit the failed-seed message' }

  # --- T17c (HIMMEL-820 CR: codex-adv [high] + silent-failure-hunter): a stale
  # .seeded that cannot be removed on reseed exits 4 with the clear-sentinel
  # message BEFORE any copy work, and the sentinel is left intact (never silently
  # swallowed) — so the seeder never proceeds leaving the old sentinel next to a
  # half-seeded tree. Fixture: seed once, then exclusively lock the sentinel. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'seed before sentinel-lock'   # writes .seeded
  Remove-Item -LiteralPath $ChildEnv -Force -ErrorAction SilentlyContinue  # so the non-launch assert below is meaningful
  $sentinel = Join-Path $FAKEHOME '.claude-glm\.seeded'
  $slock = [System.IO.File]::Open($sentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 4 'unremovable stale sentinel exits 4 on reseed'
  } finally {
    $slock.Dispose()
  }
  if (FileHas $OutTxt 'FAILED to clear stale .seeded sentinel') { Pass 'stale-sentinel failure emits the clear-sentinel message' } else { Fail 'no clear-sentinel message on unremovable stale sentinel' }
  if (Test-Path -LiteralPath $sentinel) { Pass 'stale sentinel left intact (not silently removed)' } else { Fail 'stale sentinel vanished despite lock' }
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite unremovable stale sentinel' } else { Pass 'claude not launched on unremovable stale sentinel' }

  # --- T18 (guard I7): a guard config that is a DIRECTORY (not a readable file)
  # fails CLOSED with exit 3 + the bash-parity message, never silently allows
  # egress, never launches claude — instead of letting Get-Content throw a
  # terminating error (raw exit 1 + stack trace). Twin of bash T17. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.config\claude-glm\phi-roots') | Out-Null
  Assert-Exit (Invoke-Launcher) 3 'phi-roots as directory fails closed'
  if (FileHas $OutTxt 'exists but is not a readable file') { Pass 'directory guard emits fail-closed message' } else { Fail 'no fail-closed message for directory guard' }
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched despite unreadable phi-roots' } else { Pass 'claude not launched on unreadable phi-roots' }

  # --- T19: a quoted .env value has its surrounding quotes stripped before it
  # reaches the child (Get-DotenvKey quote-strip). Twin of bash T18. ---
  New-Sandbox; $script:KEY = ''
  'ZAI_API_KEY="quoted-val-789"' | Set-Content -LiteralPath (Join-Path $WORK '.env')  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'quoted .env key launches'
  if (FileHas $ChildEnv 'ANTHROPIC_AUTH_TOKEN=quoted-val-789') { Pass 'surrounding quotes stripped from key' } else { Fail 'surrounding quotes not stripped from key' }  # gitleaks:allow

  # --- T20: 'claude' absent from PATH -> exit 5 with a clear message, before the
  # launch. PATH carries node (seeding needs it) + pwsh but no claude anywhere.
  # If a host claude resolves inside that restricted PATH (e.g. an npm-global
  # claude.cmd living in the node dir), the guard cannot fire there: SKIP. ---
  $restricted = $NodeDir + [IO.Path]::PathSeparator + $PwshDir
  $prevPath = $env:PATH
  $env:PATH = $restricted
  $claudeInRestricted = Get-Command claude -ErrorAction SilentlyContinue
  $env:PATH = $prevPath
  if ($claudeInRestricted) {
    Write-Host '  skip: T20 - host claude resolvable inside the restricted PATH'
  } else {
    New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
    Assert-Exit (Invoke-Launcher -NoClaude) 5 'missing claude exits 5'
    if (FileHas $OutTxt "claude-glm: 'claude' not found on PATH") { Pass 'missing-claude message emitted' } else { Fail 'no missing-claude message' }
  }

  # --- T21: -Reseed re-mirrors seeded subtrees (twin of bash T22/T23) — a stale
  # file planted in the dest is dropped, no nested copy appears, kept files
  # survive; covers BOTH the commands loop and the separate plugins/marketplaces
  # statement in Copy-SeedConfig. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\commands') | Out-Null
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\commands\keep.md') -Value 'a'
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\plugins\marketplaces') | Out-Null
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\marketplaces\keep.json') -Value 'a'
  Assert-Exit (Invoke-Launcher) 0 'seed before re-mirror'
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands\stale.md') -Value 'stale'
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\marketplaces\stale.json') -Value 'stale'
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 0 'reseed re-mirrors subtrees'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands\stale.md')) { Fail 'stale commands file survived reseed' } else { Pass 'stale commands file dropped on reseed' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands\commands')) { Fail 'nested commands\commands after reseed' } else { Pass 'no nested commands dir after reseed' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands\keep.md')) { Pass 'kept commands file survived reseed' } else { Fail 'kept commands file lost after reseed' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\marketplaces\stale.json')) { Fail 'stale marketplaces file survived reseed' } else { Pass 'stale marketplaces file dropped on reseed' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\marketplaces\marketplaces')) { Fail 'nested marketplaces dir after reseed' } else { Pass 'no nested marketplaces dir after reseed' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\plugins\marketplaces\keep.json')) { Pass 'kept marketplaces file survived reseed' } else { Fail 'kept marketplaces file lost after reseed' }

  # --- T22 (HIMMEL-828 Part A): the up-front sentinel removal is race-free like bash
  # `rm -f` — a reseed whose sentinel is ABSENT at removal time (a concurrent reseed
  # sharing the config dir removed it in the window the old Test-Path-then-Remove left
  # open) must NOT spuriously exit 4. Deterministic stand-in for that race: seed once,
  # delete the sentinel out from under the seeder, then -Reseed; Remove-Item hits
  # ItemNotFound, which the typed catch treats as goal-reached, so the reseed completes
  # (exit 0) and rewrites the sentinel. Guards a regression that drops/narrows the typed
  # catch so ItemNotFound falls through to the general catch -> exit 4. Twin: T17c pins
  # the opposite (a REAL lock failure still exits 4). ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 0 'seed before absent-sentinel reseed'   # writes .seeded
  Remove-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded') -Force  # vanish, as a concurrent reseed would
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed')) 0 'reseed with an absent sentinel does not spuriously exit 4'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')) { Pass 'sentinel rewritten after absent-sentinel reseed' } else { Fail 'sentinel not rewritten after absent-sentinel reseed' }

  # --- T23 (HIMMEL-828 Part B): a half-seeded tree self-heals on a plain launch — the
  # sentinel is present but a copied subtree is missing (an interrupted reseed or an
  # external removal), which the pre-828 settings+manifest staleness check missed.
  # Fixture: seed a sandbox with a commands subtree, delete the DEST subtree while
  # leaving a FRESH sentinel + old sources; a plain launch must detect the source-
  # present/dest-missing mismatch and reseed, restoring the subtree. FAILS on pre-828
  # code (fresh sentinel + old tracked files => not stale => no reseed). ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\commands') | Out-Null
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\commands\keep.md') -Value 'a'
  Assert-Exit (Invoke-Launcher) 0 'seed before half-seed simulation'
  Remove-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands') -Recurse -Force  # dest subtree vanishes
  foreach ($srcRel in @('.claude\settings.json', '.claude\plugins\installed_plugins.json', '.claude\plugins\known_marketplaces.json', '.claude\commands')) {
    $p = Join-Path $FAKEHOME $srcRel
    if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc = [datetime]'2020-01-01' }
  }
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')).LastWriteTimeUtc = [datetime]::UtcNow
  Assert-Exit (Invoke-Launcher) 0 'half-seeded tree triggers reseed on plain launch'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands\keep.md')) { Pass 'missing subtree restored by self-heal reseed' } else { Fail 'missing subtree NOT restored (half-seed not detected)' }

  # --- T24 (HIMMEL-828 Part B): a top-level add inside a source subtree (source dir
  # mtime newer than the sentinel) auto-reseeds without -Reseed — pre-828 this drift
  # needed an explicit -Reseed. Fixture: seed, set a fresh-ish sentinel + OLD settings/
  # manifests (so only the subtree can be the trigger), add a new command to the source
  # (bumping its dir mtime past the sentinel), confirm a plain launch mirrors it. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\commands') | Out-Null
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\commands\one.md') -Value 'a'
  Assert-Exit (Invoke-Launcher) 0 'seed before subtree drift'
  foreach ($srcRel in @('.claude\settings.json', '.claude\plugins\installed_plugins.json', '.claude\plugins\known_marketplaces.json')) {
    $p = Join-Path $FAKEHOME $srcRel
    if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc = [datetime]'2020-01-01' }
  }
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')).LastWriteTimeUtc = [datetime]'2020-06-01'
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\commands\two.md') -Value 'b'  # new source command
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude\commands')).LastWriteTimeUtc = [datetime]::UtcNow
  Assert-Exit (Invoke-Launcher) 0 'source subtree drift auto-reseeds on plain launch'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands\two.md')) { Pass 'new source command mirrored by subtree-drift reseed' } else { Fail 'new source command NOT mirrored (subtree drift not detected)' }

  # --- T25 (HIMMEL-828/819, codex-adv [high]): DELETION MIRRORING — a deleted SOURCE
  # subtree is removed from the lane on a plain launch (a removed command/hook must not
  # linger steering the cloud lane), fully symmetric with settings/manifest deletion
  # mirroring, AND it does NOT churn forever (the seeder clears the dest, so the predicate
  # stops firing). Fixture: seed with a commands subtree, delete the SOURCE; launch 2
  # mirrors the removal; launch 3 is stable (a lane tamper survives = no reseed). ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\commands') | Out-Null
  Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\commands\keep.md') -Value 'a'
  Assert-Exit (Invoke-Launcher) 0 'seed before source-subtree deletion'
  Remove-Item -LiteralPath (Join-Path $FAKEHOME '.claude\commands') -Recurse -Force  # SOURCE subtree deleted
  Assert-Exit (Invoke-Launcher) 0 'source-deleted subtree triggers a mirror reseed'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\commands')) { Fail 'stale lane subtree survived source deletion' } else { Pass 'stale lane subtree removed (deletion mirrored)' }
  '{"local":"tamper-stable"}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude-glm\settings.json') -NoNewline
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude\settings.json')).LastWriteTimeUtc = [datetime]'2020-01-01'
  (Get-Item -LiteralPath (Join-Path $FAKEHOME '.claude-glm\.seeded')).LastWriteTimeUtc = [datetime]::UtcNow
  Assert-Exit (Invoke-Launcher) 0 'no further churn after deletion mirrored'
  if (FileHas (Join-Path $FAKEHOME '.claude-glm\settings.json') 'tamper-stable') { Pass 'stable after mirror (no churn)' } else { Fail 'churns after deletion mirrored' }

  # --- T26 (HIMMEL-828/819, codex-adv [high]): LEAF-FILE deletion mirroring — a deleted
  # source CLAUDE.md (which literally steers the lane) is removed from the lane on a plain
  # launch, not just subtrees/manifests. Every allowlisted leaf now mirrors deletion. ---
  New-Sandbox; $script:KEY = 'zai-test-123'  # gitleaks:allow
  'steer' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\CLAUDE.md') -NoNewline
  Assert-Exit (Invoke-Launcher) 0 'seed before CLAUDE.md deletion'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\CLAUDE.md')) { Pass 'CLAUDE.md seeded' } else { Fail 'CLAUDE.md not seeded' }
  Remove-Item -LiteralPath (Join-Path $FAKEHOME '.claude\CLAUDE.md') -Force  # SOURCE deleted
  Assert-Exit (Invoke-Launcher) 0 'deleted source CLAUDE.md triggers a mirror reseed'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-glm\CLAUDE.md')) { Fail 'stale CLAUDE.md survived source deletion' } else { Pass 'stale CLAUDE.md removed (leaf deletion mirrored)' }

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
