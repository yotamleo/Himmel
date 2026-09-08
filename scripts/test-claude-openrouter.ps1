#Requires -Version 7
<#
  Hermetic PowerShell smoke suite for scripts/claude-openrouter.ps1
  (HIMMEL-1792). The bash suite (test-claude-openrouter.sh) never executes the
  .ps1, which is how a PowerShell-ONLY regression shipped green in HIMMEL-1774
  CR round 3: round 2 moved config-dir creation below the settings sanitizer,
  so a FIRST launch against an existing ~/.claude/settings.json failed seeding
  and MISREPORTED the cause as "node missing/broken?" — while the bash twin
  (which creates the dir first) passed the whole time.

  Focused smoke set — the regression case plus the lane's defining gate, not a
  full port of the 29-case bash suite:
    T1  missing key -> exit 2, claude never launched
    T2  REAL egress matrix, unclassified cwd -> REFUSED exit 3, fail-closed
    T2b the egress refusal survives -Force (no proceed-anyway override)
    T3  FIRST launch with an EXISTING ~/.claude/settings.json under a declared
        allow cell -> exit 0 (THE regressed case), seeded sanitized settings,
        sentinel written, credentials never copied, no key material in the
        config dir, and NO "node missing/broken?" misreport
    T4  the full env contract reaches the child (empty ANTHROPIC_API_KEY is
        load-bearing: it is what forces the OpenRouter route)
    T5  credit probe failure is ADVISORY: loud UNKNOWN, launch still exit 0
    T6  claude flags pass through verbatim; leading -Reseed consumed
    T7  key resolvable from the repo .env with surrounding quotes stripped

  Sandbox (twin of test-claude-glm.ps1's harness): fake $env:USERPROFILE ->
  temp dir, mock claude.cmd on a prepended PATH that dumps its env to
  $env:MOCK_ENV_OUT and its argv to $env:MOCK_ARGV_OUT. The launcher runs in a
  CHILD pwsh so its `exit 2/3/4` cannot terminate this harness. The credit
  probe points at a fast-failing loopback, so nothing touches the network.
  Never reads the real user profile, ~/.claude, or the repo .env.
#>
$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ScriptDir = $PSScriptRoot
$Launcher  = Join-Path $ScriptDir 'claude-openrouter.ps1'
$RealMatrix = Join-Path $ScriptDir (Join-Path 'guardrails' 'egress-matrix.json')

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }
function FileHas($path, $needle) { (Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -SimpleMatch -Quiet -Pattern $needle) }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-openrouter-ps-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null

# snapshot env mutated per-invocation; restored in the outer finally
$OrigEnv = @{}
foreach ($n in 'USERPROFILE', 'OPENROUTER_API_KEY', 'CLAUDE_OPENROUTER_DOTENV_ROOT', 'CLAUDE_OPENROUTER_EGRESS_MATRIX',
               'CLAUDE_OPENROUTER_CWD', 'OPENROUTER_API_BASE', 'MOCK_ENV_OUT', 'MOCK_ARGV_OUT', 'PATH') {
  $OrigEnv[$n] = [Environment]::GetEnvironmentVariable($n)
}

function New-Sandbox {
  # fresh sandbox: fake HOME whose ~/.claude ALREADY carries settings.json (the
  # exact fixture the round-3 regression needed), mock claude.cmd in BIN.
  $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
  $script:FAKEHOME = Join-Path $TMP "$id-home"
  $script:WORK     = Join-Path $TMP "$id-work"
  $script:BIN      = Join-Path $TMP "$id-bin"
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude') | Out-Null
  New-Item -ItemType Directory -Force -Path $WORK | Out-Null
  New-Item -ItemType Directory -Force -Path $BIN | Out-Null
  '{"model":"claude-opus-5[1m]","env":{"ANTHROPIC_MODEL":"x","HIMMEL_INITIATIVE":"1"}}' |
    Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\settings.json') -NoNewline
  'secret' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\.credentials.json') -NoNewline
  New-Item -ItemType Directory -Force -Path (Join-Path $FAKEHOME '.claude\plugins\claude-hud') | Out-Null
  '{"hud":true}' | Set-Content -LiteralPath (Join-Path $FAKEHOME '.claude\plugins\claude-hud\config.json') -NoNewline
  # Mock claude: dumps env, records passthrough argv, propagates a magic
  # --mock-exit-N arg as its own exit code.
  $mock = @'
@echo off
echo %*>>"%MOCK_ARGV_OUT%"
pwsh -NoProfile -Command "Get-ChildItem env: | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value } | Set-Content -LiteralPath $env:MOCK_ENV_OUT"
exit /b 0
'@
  Set-Content -LiteralPath (Join-Path $BIN 'claude.cmd') -Value $mock -Encoding Ascii
  $script:ChildEnv = Join-Path $WORK 'child-env.txt'
  $script:ArgvOut  = Join-Path $WORK 'claude-argv.txt'
  $script:OutTxt   = Join-Path $WORK 'out.txt'
  $script:KEY = ''
  $script:MATRIX = ''   # empty -> Invoke-Launcher defaults to the REAL matrix
}

# A hermetic matrix that DECLARES openrouter + an explicit allow cell (the only
# shape under which the lane may proceed; twin of the bash suite's fixture).
function Write-AllowMatrix([string]$Path) {
  @'
{ "providers": { "openrouter": { "region": "US", "note": "test fixture" } },
  "rules": [ { "corpus": "*", "provider": "openrouter", "purpose": "*", "verdict": "allow", "why": "test" } ],
  "default": "deny" }
'@ | Set-Content -LiteralPath $Path -NoNewline
}

# Run the launcher in a child pwsh under the prepared sandbox; returns its exit
# code. Output (stdout+stderr) is captured to $OutTxt.
function Invoke-Launcher {
  param([string[]]$LArgs = @())
  if ($script:KEY) { $env:OPENROUTER_API_KEY = $script:KEY } else { Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue }
  $env:USERPROFILE                   = $FAKEHOME
  $env:CLAUDE_OPENROUTER_DOTENV_ROOT = $WORK
  if ($script:MATRIX) { $env:CLAUDE_OPENROUTER_EGRESS_MATRIX = $script:MATRIX }
  else { Remove-Item Env:CLAUDE_OPENROUTER_EGRESS_MATRIX -ErrorAction SilentlyContinue }
  Remove-Item Env:CLAUDE_OPENROUTER_CWD -ErrorAction SilentlyContinue
  $env:OPENROUTER_API_BASE = 'http://127.0.0.1:1/api/v1'   # fast-failing loopback -> credit UNKNOWN, no network
  $env:MOCK_ENV_OUT        = $ChildEnv
  $env:MOCK_ARGV_OUT       = $ArgvOut
  $env:PATH                = $BIN + [IO.Path]::PathSeparator + $OrigEnv['PATH']
  Push-Location $WORK
  try {
    & pwsh -NoProfile -NonInteractive -File $Launcher @LArgs 2>&1 | Out-File -LiteralPath $OutTxt -Encoding utf8
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

  # --- T2 (REQUIRED): the REAL matrix refuses an unclassified cwd fail-closed.
  # The temp WORK dir classifies as corpus "unknown"; the real matrix declares
  # openrouter cells ONLY for himmel-code + handover-state (HIMMEL-1774 ruling),
  # so the lane must REFUSE with exit 3, claude never launched. ---
  New-Sandbox; $script:KEY = 'or-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher) 3 'real matrix refuses unclassified cwd fail-closed'
  if (FileHas $OutTxt 'REFUSED') { Pass 'refusal is a REFUSED line' } else { Fail 'no REFUSED line' }
  if (FileHas $OutTxt 'no egress-matrix cell permits') { Pass 'refusal names the unpermitted corpus' } else { Fail 'refusal does not name the corpus' }
  if (Test-Path -LiteralPath $ChildEnv) { Fail 'claude launched past the egress refusal' } else { Pass 'claude never launched past the egress refusal' }

  # --- T2b: -Force does NOT bypass the egress gate (no proceed-anyway override;
  # only the path denylist keeps --force, the matrix does not). ---
  New-Sandbox; $script:KEY = 'or-test-123'  # gitleaks:allow
  Assert-Exit (Invoke-Launcher -LArgs @('-Force')) 3 'egress refusal survives -Force'
  if (Test-Path -LiteralPath $ChildEnv) { Fail '-Force bypassed the egress refusal' } else { Pass '-Force did not bypass the egress refusal' }

  # --- T3 (REQUIRED — the regressed case): FIRST launch (no config dir at all)
  # with an EXISTING ~/.claude/settings.json, under a declared allow cell. The
  # round-3 bug had config-dir creation BELOW the sanitizer, so the node write
  # into the not-yet-created dir failed and the launcher exited 4 blaming
  # "node missing/broken?". Must exit 0 with a fully seeded config dir. ---
  New-Sandbox; $script:KEY = 'or-test-123'  # gitleaks:allow
  Write-AllowMatrix (Join-Path $WORK 'matrix.json'); $script:MATRIX = Join-Path $WORK 'matrix.json'
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-openrouter')) { Fail 'fixture hygiene: config dir pre-exists' } else { Pass 'fixture hygiene: no pre-existing config dir' }
  Assert-Exit (Invoke-Launcher) 0 'first launch with existing settings.json seeds and launches'
  if (FileHas $OutTxt 'node missing/broken') { Fail 'seeding failure misreported as node missing/broken (the round-3 regression)' } else { Pass 'no node-missing misreport' }
  $seeded = Join-Path $FAKEHOME '.claude-openrouter\settings.json'
  if (Test-Path -LiteralPath $seeded) { Pass 'settings.json seeded' } else { Fail 'settings.json not seeded' }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-openrouter\.seeded')) { Pass 'seed sentinel written' } else { Fail 'seed sentinel not written' }
  if (Test-Path -LiteralPath $seeded) {
    $s = Get-Content -LiteralPath $seeded -Raw | ConvertFrom-Json
    if ($s.PSObject.Properties.Name -contains 'model') { Fail 'model key survived sanitization' } else { Pass 'model key stripped' }
    $envKeys = if ($s.env) { $s.env.PSObject.Properties.Name } else { @() }
    $forbidden = $envKeys | Where-Object { $_.ToUpperInvariant().StartsWith('ANTHROPIC_') }
    if ($forbidden) { Fail "forbidden env key survived: $($forbidden -join ',')" } else { Pass 'env.ANTHROPIC_* stripped' }
    if ($s.env.HIMMEL_INITIATIVE -eq '1') { Pass 'non-forbidden env entry preserved' } else { Fail 'non-forbidden env entry lost' }
  }
  if (Test-Path -LiteralPath (Join-Path $FAKEHOME '.claude-openrouter\.credentials.json')) { Fail 'credentials copied' } else { Pass 'credentials never copied' }
  $leaked = Get-ChildItem -LiteralPath (Join-Path $FAKEHOME '.claude-openrouter') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { Select-String -LiteralPath $_.FullName -SimpleMatch -Quiet -Pattern 'or-test-123' }  # gitleaks:allow
  if ($leaked) { Fail 'key leaked into config dir' } else { Pass 'no key material in config dir' }

  # --- T4: the full env contract reaches the child. ANTHROPIC_API_KEY must
  # arrive EXPLICITLY EMPTY (whole-line match) — the empty key is load-bearing:
  # it is what forces the SDK onto the OpenRouter route. ---
  if (Test-Path -LiteralPath $ChildEnv) {
    foreach ($pair in @(
        'ANTHROPIC_BASE_URL=https://openrouter.ai/api',
        'ANTHROPIC_AUTH_TOKEN=or-test-123',
        'ANTHROPIC_MODEL=anthropic/claude-opus-5',
        'ANTHROPIC_DEFAULT_HAIKU_MODEL=anthropic/claude-opus-5',
        'ANTHROPIC_DEFAULT_SONNET_MODEL=anthropic/claude-opus-5',
        'ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic/claude-opus-5',
        'CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000',
        ('CLAUDE_CONFIG_DIR=' + (Join-Path $FAKEHOME '.claude-openrouter')))) {
      if (FileHas $ChildEnv $pair) { Pass "child env has $pair" } else { Fail "child env missing $pair" }
    }
    $emptyKey = (Get-Content -LiteralPath $ChildEnv) -match '^(?i)ANTHROPIC_API_KEY=$'
    if ($emptyKey) { Pass 'ANTHROPIC_API_KEY exported empty' } else { Fail 'ANTHROPIC_API_KEY not exported empty' }
  } else { Fail 'T3 launch produced no child env dump' }

  # --- T5: credit probe failure is ADVISORY — loud UNKNOWN on a fast-failing
  # loopback, launch STILL exit 0 (HIMMEL-1771: never fail open silently). ---
  New-Sandbox; $script:KEY = 'or-test-123'  # gitleaks:allow
  Write-AllowMatrix (Join-Path $WORK 'matrix.json'); $script:MATRIX = Join-Path $WORK 'matrix.json'
  Assert-Exit (Invoke-Launcher) 0 'credit UNKNOWN surfaced + launch proceeds'
  if (FileHas $OutTxt 'remaining metered credit: UNKNOWN') { Pass 'loud UNKNOWN credit line' } else { Fail 'no loud UNKNOWN credit line' }

  # --- T6: claude flags pass through verbatim; a LEADING -Reseed is consumed.
  # Pins the manual flag loop (a param() block would swallow -p/-d as common
  # parameters before it ever runs). ---
  New-Sandbox; $script:KEY = 'or-test-123'  # gitleaks:allow
  Write-AllowMatrix (Join-Path $WORK 'matrix.json'); $script:MATRIX = Join-Path $WORK 'matrix.json'
  Assert-Exit (Invoke-Launcher -LArgs @('-Reseed', '-p', 'hello', '-d')) 0 'passthrough launch'
  if (FileHas $ArgvOut '-p hello -d') { Pass 'claude short flags passed verbatim' } else { Fail 'claude short flags NOT passed verbatim' }
  if (FileHas $ArgvOut '-Reseed') { Fail 'leading -Reseed leaked to claude argv' } else { Pass 'leading -Reseed consumed, not forwarded' }

  # --- T7: key resolvable from the repo .env ONLY, with one surrounding quote
  # pair stripped (Get-DotenvKey — PS-only logic the bash suite cannot cover). ---
  New-Sandbox; $script:KEY = ''
  'OPENROUTER_API_KEY="quoted-val-789"' | Set-Content -LiteralPath (Join-Path $WORK '.env')  # gitleaks:allow
  Write-AllowMatrix (Join-Path $WORK 'matrix.json'); $script:MATRIX = Join-Path $WORK 'matrix.json'
  Assert-Exit (Invoke-Launcher) 0 'quoted .env key launches'
  if (FileHas $ChildEnv 'ANTHROPIC_AUTH_TOKEN=quoted-val-789') { Pass 'surrounding quotes stripped from key' } else { Fail 'surrounding quotes not stripped from key' }  # gitleaks:allow

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
