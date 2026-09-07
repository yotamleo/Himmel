<#
.SYNOPSIS
  Hermetic tests for probe-codex-hooks.ps1 (HIMMEL-1982).

.DESCRIPTION
  A temp CODEX_HOME (never the real ~/.codex) holds a global hooks.json (one
  bare-bash hook, one quoted-path hook, one already-correct hook), a
  config.toml with one enabled + one disabled plugin (two cached versions for
  the enabled one, to exercise "lexically highest wins"), and matching
  plugins/cache/ hooks.json fixtures using ${CLAUDE_PLUGIN_ROOT} + a
  $CLAUDE_PROJECT_DIR reference. A separate temp project dir holds a
  .codex/hooks.json using the himmel platform-wrapper shape, which must lint
  clean (guards against ".sh" filenames false-triggering the bash-invoked
  check). Asserts finding kinds/counts, exit 1 vs 0 (-NoFail), and the -Json
  dump shape, then a separate hermetic replay smoke test (cmd /c exit 0/3,
  and a Start-Sleep killed by -TimeoutSec, confirming the process is actually
  gone afterwards).
#>
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Probe = Join-Path $ScriptDir 'probe-codex-hooks.ps1'

$fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Warning "  FAIL: $m"; $script:fails++ }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("probe-ps-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$CodexHome = Join-Path $TMP 'codex-home'
$ProjectDir = Join-Path $TMP 'project'

New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ProjectDir '.codex') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'plugins/cache/testmkt/myplug/1.0.0/hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'plugins/cache/testmkt/myplug/1.2.0/hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'plugins/cache/testmkt/offplug/1.0.0/hooks') | Out-Null

# --- global hooks.json: bare-bash, quoted-path, one already-correct ----------
@'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "bash \"C:/fixtures/foo.sh\"" }
      ]},
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "\"C:\\fixtures\\thing.cmd\" arg" }
      ]},
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "& \"C:\\Program Files\\Git\\bin\\bash.exe\" \"x\"", "timeout": 15 }
      ]}
    ]
  }
}
'@ | Set-Content -LiteralPath (Join-Path $CodexHome 'hooks.json') -Encoding utf8NoBOM

# --- project .codex/hooks.json: platform-specific himmel wrappers, clean ----
@'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": ".codex/run-hook.sh --sandbox foo.sh", "commandWindows": ".codex/run-hook.cmd --sandbox foo.sh" }
      ]}
    ]
  }
}
'@ | Set-Content -LiteralPath (Join-Path $ProjectDir '.codex/hooks.json') -Encoding utf8NoBOM

# --- config.toml: one enabled plugin, one disabled -----------------------------
@'
[plugins."myplug@testmkt"]
enabled = true

[plugins."offplug@testmkt"]
enabled = false
'@ | Set-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Encoding utf8NoBOM

# --- older cached version: must be ignored (lexically highest wins) -----------
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "OLD_VERSION_MARKER_SHOULD_NOT_APPEAR" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $CodexHome 'plugins/cache/testmkt/myplug/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM

# --- newest cached version: bare-bash via ${CLAUDE_PLUGIN_ROOT} + a $CLAUDE_PROJECT_DIR ref ---
@'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/thing.sh\"" }
      ]}
    ],
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/x.js\" \"$CLAUDE_PROJECT_DIR/foo\"" }
      ]}
    ]
  }
}
'@ | Set-Content -LiteralPath (Join-Path $CodexHome 'plugins/cache/testmkt/myplug/1.2.0/hooks/hooks.json') -Encoding utf8NoBOM

# --- disabled plugin's cache: must never be scanned ----------------------------
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "OFFPLUG_MARKER_SHOULD_NOT_APPEAR" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $CodexHome 'plugins/cache/testmkt/offplug/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM

# === 1. static lint: run without -NoFail, capture output + exit code ===========
$out = (& $Probe -CodexHome $CodexHome -Project $ProjectDir 6>&1 | Out-String)
$rc = $LASTEXITCODE
if ($rc -eq 1) { Pass 'exit 1 when FAIL findings exist (no -NoFail)' } else { Fail "exit code $rc (want 1)" }

if ($out -match 'FAIL:bare-bash') { Pass 'bare-bash FAIL detected' } else { Fail 'bare-bash FAIL not detected' }
if ($out -match 'FAIL:quoted-path-start') { Pass 'quoted-path-start FAIL detected' } else { Fail 'quoted-path-start FAIL not detected' }
if ($out -match 'INFO:claude-project-dir') { Pass 'claude-project-dir INFO detected' } else { Fail 'claude-project-dir INFO not detected' }
if ($out -match 'SUMMARY: 6 hooks, 3 FAIL, 2 WARN, 1 INFO') { Pass 'summary counts correct (6/3/2/1)' } else { Fail "summary counts wrong: $out" }

if ($out -notmatch 'OLD_VERSION_MARKER_SHOULD_NOT_APPEAR') { Pass 'older cached plugin version excluded' } else { Fail 'older cached plugin version leaked into output' }
if ($out -notmatch 'OFFPLUG_MARKER_SHOULD_NOT_APPEAR') { Pass 'disabled plugin excluded' } else { Fail 'disabled plugin leaked into output' }
if ($out -match 'plugin:myplug') { Pass 'enabled plugin source tag present' } else { Fail 'plugin:myplug source tag missing' }
if ($out -match '\.codex/run-hook\.cmd --sandbox foo\.sh') { Pass 'project hook listed' } else { Fail 'project hook missing from output' }
# the project's run-hook.cmd row itself must carry no finding (".sh" must not false-trigger bash-invoked check)
if ($out -match '\.codex/run-hook\.cmd --sandbox foo\.sh\s+-\s*$' -or ($out -split "`r?`n" | Where-Object { $_ -match 'foo\.sh' -and $_ -match '\s-\s*$' })) {
  Pass 'project run-hook.cmd hook is clean (no false bash/sh trigger)'
} else {
  Fail "project run-hook.cmd hook was not clean: $out"
}
if ($out -match 'Recommended rewrites') { Pass 'recommended-rewrites section printed' } else { Fail 'recommended-rewrites section missing' }
if ($out -match '& "C:\\Program Files\\Git\\bin\\bash\.exe" "C:/fixtures/foo\.sh"') { Pass 'bare-bash rewrite suggestion correct' } else { Fail "bare-bash rewrite suggestion wrong: $out" }
if ($out -match '& "C:\\fixtures\\thing\.cmd" arg') { Pass 'quoted-path rewrite suggestion correct' } else { Fail "quoted-path rewrite suggestion wrong: $out" }

# === 2. -NoFail always exits 0 =================================================
& $Probe -CodexHome $CodexHome -Project $ProjectDir -NoFail | Out-Null
if ($LASTEXITCODE -eq 0) { Pass '-NoFail exits 0 despite FAIL findings' } else { Fail "-NoFail exit code $LASTEXITCODE (want 0)" }

# === 3. -Json dump shape ========================================================
$jsonPath = Join-Path $TMP 'results.json'
& $Probe -CodexHome $CodexHome -Project $ProjectDir -NoFail -Json $jsonPath | Out-Null
if (Test-Path -LiteralPath $jsonPath) { Pass '-Json wrote a file' } else { Fail '-Json produced no file' }
$j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
if ($j.summary.total -eq 6) { Pass 'json summary.total = 6' } else { Fail "json summary.total = $($j.summary.total) (want 6)" }
if ($j.summary.fail -eq 3) { Pass 'json summary.fail = 3' } else { Fail "json summary.fail = $($j.summary.fail) (want 3)" }
if ($j.summary.warn -eq 2) { Pass 'json summary.warn = 2' } else { Fail "json summary.warn = $($j.summary.warn) (want 2)" }
if ($j.summary.info -eq 1) { Pass 'json summary.info = 1' } else { Fail "json summary.info = $($j.summary.info) (want 1)" }
if (@($j.rows).Count -eq 6) { Pass 'json rows.Count = 6' } else { Fail "json rows.Count = $(@($j.rows).Count) (want 6)" }
$quotedRow = @($j.rows) | Where-Object { $_.command -like '*thing.cmd*' } | Select-Object -First 1
if ($quotedRow -and (@($quotedRow.findings) -contains 'FAIL:quoted-path-start')) {
  Pass 'json row findings array carries FAIL:quoted-path-start'
} else {
  Fail 'json row findings array missing FAIL:quoted-path-start'
}
$myplugRow = @($j.rows) | Where-Object { $_.source -eq 'plugin:myplug' -and $_.event -eq 'PreToolUse' } | Select-Object -First 1
if ($myplugRow -and $myplugRow.command -match [regex]::Escape((Join-Path $CodexHome 'plugins\cache\testmkt\myplug\1.2.0'))) {
  Pass 'CLAUDE_PLUGIN_ROOT substituted with the resolved (highest-version) root'
} else {
  Fail "CLAUDE_PLUGIN_ROOT substitution missing/wrong: $($myplugRow.command)"
}

# === 4. replay smoke (separate hermetic fixture set) ============================
$ReplayHome = Join-Path $TMP 'replay-home'
New-Item -ItemType Directory -Force -Path $ReplayHome | Out-Null
$marker = 'REPLAY_SLEEP_MARKER_' + [guid]::NewGuid().ToString('N').Substring(0,8)
@"
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "exit 0" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "exit 3" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "Start-Sleep -Seconds 5; Write-Output '$marker'" } ] }
    ]
  }
}
"@ | Set-Content -LiteralPath (Join-Path $ReplayHome 'hooks.json') -Encoding utf8NoBOM

$replayJson = Join-Path $TMP 'replay-results.json'
& $Probe -CodexHome $ReplayHome -Project $ReplayHome -Replay -TimeoutSec 1 -NoFail -Json $replayJson | Out-Null
$rj = Get-Content -LiteralPath $replayJson -Raw | ConvertFrom-Json
$rows = @($rj.replayResults)
if ($rows.Count -eq 3) { Pass 'replay produced 3 results' } else { Fail "replay produced $($rows.Count) results (want 3)" }

$exit0 = $rows | Where-Object { $_.command -eq 'exit 0' } | Select-Object -First 1
$exit3 = $rows | Where-Object { $_.command -eq 'exit 3' } | Select-Object -First 1
$sleep = $rows | Where-Object { $_.command -like '*Start-Sleep*' } | Select-Object -First 1

if ($exit0 -and $exit0.result -eq 'ok') { Pass 'exit 0 -> ok' } else { Fail "exit-0 hook result: $($exit0.result)" }
if ($exit3 -and $exit3.result -eq 'rc=3') { Pass 'exit 3 -> rc=3' } else { Fail "exit-3 hook result: $($exit3.result)" }
if ($sleep -and $sleep.result -eq 'TIMEOUT') { Pass 'Start-Sleep 5 with -TimeoutSec 1 -> TIMEOUT' } else { Fail "sleep hook result: $($sleep.result)" }

# confirm the killed process is actually gone (poll briefly; CI/slow-kill tolerant)
$stillAlive = $true
for ($i = 0; $i -lt 15; $i++) {
  $procs = Get-CimInstance Win32_Process -Filter "CommandLine like '%$marker%'" -ErrorAction SilentlyContinue
  if (-not $procs) { $stillAlive = $false; break }
  Start-Sleep -Milliseconds 200
}
if (-not $stillAlive) { Pass 'timed-out replay process is actually gone' } else { Fail 'timed-out replay process is still running' }

# === 5. commandWindows / command_windows precedence (separate fixture set) =====
$WinHome = Join-Path $TMP 'win-home'
New-Item -ItemType Directory -Force -Path $WinHome | Out-Null
@'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "bash \"C:/trap.sh\"", "commandWindows": "& \"C:\\Program Files\\Git\\bin\\bash.exe\" \"C:/clean.sh\"" }
      ]},
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "& \"C:\\Program Files\\Git\\bin\\bash.exe\" \"C:/clean.sh\"", "command_windows": "bash \"C:/trap.sh\"" }
      ]}
    ]
  }
}
'@ | Set-Content -LiteralPath (Join-Path $WinHome 'hooks.json') -Encoding utf8NoBOM
$winOut = (& $Probe -CodexHome $WinHome -Project $WinHome -NoFail 6>&1 | Out-String)
$winLines = $winOut -split "`r?`n"
$camelLine = $winLines | Where-Object { $_ -match 'via=commandWindows' } | Select-Object -First 1
$snakeLine = $winLines | Where-Object { $_ -match 'via=command_windows' } | Select-Object -First 1
if ($camelLine) { Pass 'via=commandWindows noted for camelCase key' } else { Fail "via=commandWindows marker missing: $winOut" }
if ($snakeLine) { Pass 'via=command_windows noted for snake_case alias' } else { Fail "via=command_windows marker missing: $winOut" }
# row 1: trap in `command`, clean commandWindows -> effective command is the clean one (no FAIL, trap.sh not used)
if ($camelLine -and $camelLine -match 'clean\.sh' -and $camelLine -notmatch 'trap\.sh') {
  Pass 'commandWindows (clean) used, trap in command ignored'
} else {
  Fail "commandWindows row picked the wrong command: $camelLine"
}
# row 2: clean `command`, trap in command_windows -> effective command is the trap (bare-bash FAIL, clean.sh not used)
if ($snakeLine -and $snakeLine -match 'trap\.sh' -and $snakeLine -notmatch 'clean\.sh' -and $snakeLine -match 'FAIL:bare-bash') {
  Pass 'command_windows (trap) used, clean command field ignored -> FAIL:bare-bash'
} else {
  Fail "command_windows row picked the wrong command: $snakeLine"
}

# === 6. plugin version resolution: numeric-highest beats lexical, mixed falls back ===
$VerHome = Join-Path $TMP 'ver-home'
New-Item -ItemType Directory -Force -Path (Join-Path $VerHome 'plugins/cache/vermkt/verplug/1.2.0/hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $VerHome 'plugins/cache/vermkt/verplug/1.10.0/hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $VerHome 'plugins/cache/vermkt/mixedplug/local/hooks') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $VerHome 'plugins/cache/vermkt/mixedplug/unknown/hooks') | Out-Null
@'
[plugins."verplug@vermkt"]
enabled = true

[plugins."mixedplug@vermkt"]
enabled = true
'@ | Set-Content -LiteralPath (Join-Path $VerHome 'config.toml') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "OLD_1_2_0_SHOULD_NOT_APPEAR" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $VerHome 'plugins/cache/vermkt/verplug/1.2.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "NEW_1_10_0_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $VerHome 'plugins/cache/vermkt/verplug/1.10.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "MIXED_PLUGIN_RESOLVED_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $VerHome 'plugins/cache/vermkt/mixedplug/unknown/hooks/hooks.json') -Encoding utf8NoBOM
$verOut = (& $Probe -CodexHome $VerHome -Project $VerHome -NoFail 6>&1 | Out-String)
if ($verOut -match 'NEW_1_10_0_MARKER') { Pass '1.10.0 wins over 1.2.0 (numeric compare, not lexical)' } else { Fail "1.10.0 not selected: $verOut" }
if ($verOut -notmatch 'OLD_1_2_0_SHOULD_NOT_APPEAR') { Pass '1.2.0 excluded once 1.10.0 is selected' } else { Fail '1.2.0 leaked into output' }
if ($LASTEXITCODE -eq 0) { Pass 'non-numeric version dirs (local/unknown) resolve without error' } else { Fail "non-numeric version dirs errored, exit $LASTEXITCODE" }

# === 7. TOML enabled-detection: enabled= need not be the FIRST line in the table ===
$EnableHome = Join-Path $TMP 'enable-home'
foreach ($p in 'commentfirst','otherkeyfirst','falsetrailing','simpletrue','simplefalse','inlinecommenttrue','inlinecommentfalse') {
  New-Item -ItemType Directory -Force -Path (Join-Path $EnableHome "plugins/cache/enmkt/$p/1.0.0/hooks") | Out-Null
}
@'
[plugins."commentfirst@enmkt"]
# a comment before enabled
enabled = true

[plugins."otherkeyfirst@enmkt"]
source = "somewhere"
enabled = true

[plugins."falsetrailing@enmkt"]
enabled = false
extra_key = "value"

[plugins."simpletrue@enmkt"]
enabled = true

[plugins."simplefalse@enmkt"]
enabled = false

[plugins."inlinecommenttrue@enmkt"]
enabled = true  # note

[plugins."inlinecommentfalse@enmkt"]
enabled = false # x
'@ | Set-Content -LiteralPath (Join-Path $EnableHome 'config.toml') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "COMMENTFIRST_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $EnableHome 'plugins/cache/enmkt/commentfirst/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "OTHERKEYFIRST_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $EnableHome 'plugins/cache/enmkt/otherkeyfirst/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "FALSETRAILING_MARKER_SHOULD_NOT_APPEAR" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $EnableHome 'plugins/cache/enmkt/falsetrailing/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "SIMPLETRUE_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $EnableHome 'plugins/cache/enmkt/simpletrue/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "SIMPLEFALSE_MARKER_SHOULD_NOT_APPEAR" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $EnableHome 'plugins/cache/enmkt/simplefalse/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "INLINECOMMENTTRUE_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $EnableHome 'plugins/cache/enmkt/inlinecommenttrue/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM
'{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "INLINECOMMENTFALSE_MARKER_SHOULD_NOT_APPEAR" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $EnableHome 'plugins/cache/enmkt/inlinecommentfalse/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM

$enableOut = (& $Probe -CodexHome $EnableHome -Project $EnableHome -NoFail 6>&1 | Out-String)
if ($enableOut -match 'COMMENTFIRST_MARKER') { Pass 'comment before enabled=true still counts as enabled' } else { Fail 'comment-first table wrongly excluded' }
if ($enableOut -match 'OTHERKEYFIRST_MARKER') { Pass 'another key before enabled=true still counts as enabled' } else { Fail 'other-key-first table wrongly excluded' }
if ($enableOut -match 'SIMPLETRUE_MARKER') { Pass 'simple enabled=true (first line) still included' } else { Fail 'simple enabled=true table wrongly excluded' }
if ($enableOut -notmatch 'FALSETRAILING_MARKER_SHOULD_NOT_APPEAR') { Pass 'enabled=false with trailing keys stays excluded' } else { Fail 'enabled=false-with-trailing-keys table wrongly included' }
if ($enableOut -notmatch 'SIMPLEFALSE_MARKER_SHOULD_NOT_APPEAR') { Pass 'simple enabled=false table stays excluded' } else { Fail 'simple enabled=false table wrongly included' }
if ($enableOut -match 'INLINECOMMENTTRUE_MARKER') { Pass 'enabled = true  # comment still counts as enabled' } else { Fail 'enabled = true with trailing comment wrongly excluded' }
if ($enableOut -notmatch 'INLINECOMMENTFALSE_MARKER_SHOULD_NOT_APPEAR') { Pass 'enabled = false # x stays excluded' } else { Fail 'enabled = false with trailing comment wrongly included' }

# === 8. bare-bash extended detection: call operator + bare-quoted forms =========
$BareBashHome = Join-Path $TMP 'barebash-home'
New-Item -ItemType Directory -Force -Path $BareBashHome | Out-Null
@'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "& bash x.sh" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "& \"bash\" x.sh" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash.exe x.sh" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "& \"C:\\Program Files\\Git\\bin\\bash.exe\" x.sh" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "& \"$env:X\\bash.exe\" x" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'C:\\Program Files\\Git\\bin\\bash.exe' x" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "& 'C:\\Program Files\\Git\\bin\\bash.exe' x" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bashful --help" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "& bashful x" } ] }
    ]
  }
}
'@ | Set-Content -LiteralPath (Join-Path $BareBashHome 'hooks.json') -Encoding utf8NoBOM

$bbJson = Join-Path $TMP 'barebash-results.json'
$bbOut = (& $Probe -CodexHome $BareBashHome -Project $BareBashHome -NoFail -Json $bbJson 6>&1 | Out-String)
$bbRows = @((Get-Content -LiteralPath $bbJson -Raw | ConvertFrom-Json).rows)
function Has-BareBashFail($rowsArr, $cmdText) {
  $row = $rowsArr | Where-Object { $_.command -eq $cmdText } | Select-Object -First 1
  return ($row -and (@($row.findings) -contains 'FAIL:bare-bash'))
}
function Has-QuotedPathFail($rowsArr, $cmdText) {
  $row = $rowsArr | Where-Object { $_.command -eq $cmdText } | Select-Object -First 1
  return ($row -and (@($row.findings) -contains 'FAIL:quoted-path-start'))
}
if (Has-BareBashFail $bbRows '& bash x.sh') { Pass '& bash x.sh -> FAIL:bare-bash' } else { Fail '& bash x.sh not flagged' }
if (Has-BareBashFail $bbRows '& "bash" x.sh') { Pass '& "bash" x.sh -> FAIL:bare-bash' } else { Fail '& "bash" x.sh not flagged' }
if (Has-BareBashFail $bbRows 'bash.exe x.sh') { Pass 'bash.exe x.sh -> FAIL:bare-bash' } else { Fail 'bash.exe x.sh not flagged' }
if (-not (Has-BareBashFail $bbRows '& "C:\Program Files\Git\bin\bash.exe" x.sh')) { Pass '& "C:\...\bash.exe" x.sh (path-qualified) stays clean' } else { Fail 'path-qualified bash.exe wrongly flagged' }
if (-not (Has-BareBashFail $bbRows '& "$env:X\bash.exe" x')) { Pass '& "$env:X\bash.exe" x (env-qualified) stays clean' } else { Fail 'env-qualified bash.exe wrongly flagged' }
if (Has-QuotedPathFail $bbRows "'C:\Program Files\Git\bin\bash.exe' x") { Pass "single-quoted leading path -> FAIL:quoted-path-start" } else { Fail "single-quoted leading path not flagged" }
if (-not (Has-QuotedPathFail $bbRows "& 'C:\Program Files\Git\bin\bash.exe' x")) { Pass "& 'C:\...' x (already prefixed, single-quoted) stays clean" } else { Fail "prefixed single-quoted path wrongly flagged" }
if ($bbOut -match [regex]::Escape("& 'C:\Program Files\Git\bin\bash.exe' x")) { Pass "single-quoted rewrite suggestion is & '...'" } else { Fail "single-quoted rewrite suggestion wrong: $bbOut" }
if (-not (Has-BareBashFail $bbRows 'bashful --help')) { Pass "bashful --help stays clean (token boundary, not bare-bash)" } else { Fail "bashful --help wrongly flagged FAIL:bare-bash" }
if (-not (Has-BareBashFail $bbRows '& bashful x')) { Pass "& bashful x stays clean (token boundary, not bare-bash)" } else { Fail "& bashful x wrongly flagged FAIL:bare-bash" }

# === 9. replay payload enrichment + matcher-aware tool_name (self-checking hooks) ===
$PayloadHome = Join-Path $TMP 'payload-home'
New-Item -ItemType Directory -Force -Path $PayloadHome | Out-Null
@'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$j = [Console]::In.ReadToEnd() | ConvertFrom-Json; $n = $j.PSObject.Properties.Name; if ($n -contains 'source' -and $n -contains 'model' -and $n -contains 'permission_mode') { exit 0 } else { exit 9 }" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "$j = [Console]::In.ReadToEnd() | ConvertFrom-Json; if ($j.tool_name -eq 'Edit' -and $j.tool_input.file_path -and $j.tool_use_id) { exit 0 } else { exit 9 }" } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "$j = [Console]::In.ReadToEnd() | ConvertFrom-Json; $n = $j.PSObject.Properties.Name; if ($n -contains 'tool_response' -and $n -contains 'tool_use_id') { exit 0 } else { exit 9 }" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$j = [Console]::In.ReadToEnd() | ConvertFrom-Json; if ($j.prompt) { exit 0 } else { exit 9 }" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$j = [Console]::In.ReadToEnd() | ConvertFrom-Json; $n = $j.PSObject.Properties.Name; if ($n -contains 'last_assistant_message' -and $n -contains 'stop_hook_active') { exit 0 } else { exit 9 }" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$j = [Console]::In.ReadToEnd() | ConvertFrom-Json; if ($j.reason) { exit 0 } else { exit 9 }" } ] }
    ]
  }
}
'@ | Set-Content -LiteralPath (Join-Path $PayloadHome 'hooks.json') -Encoding utf8NoBOM

$payloadJson = Join-Path $TMP 'payload-results.json'
& $Probe -CodexHome $PayloadHome -Project $PayloadHome -Replay -TimeoutSec 10 -NoFail -Json $payloadJson | Out-Null
$prRows = @((Get-Content -LiteralPath $payloadJson -Raw | ConvertFrom-Json).replayResults)
function Get-ReplayResult($rowsArr, $ev) {
  return ($rowsArr | Where-Object { $_.event -eq $ev } | Select-Object -First 1).result
}
if ((Get-ReplayResult $prRows 'SessionStart') -eq 'ok') { Pass 'SessionStart payload carries source+model+permission_mode' } else { Fail "SessionStart self-check: $(Get-ReplayResult $prRows 'SessionStart')" }
if ((Get-ReplayResult $prRows 'PreToolUse') -eq 'ok') { Pass 'PreToolUse matcher Edit|Write replays as tool_name=Edit with file_path + tool_use_id' } else { Fail "PreToolUse self-check: $(Get-ReplayResult $prRows 'PreToolUse')" }
if ((Get-ReplayResult $prRows 'PostToolUse') -eq 'ok') { Pass 'PostToolUse payload carries tool_response+tool_use_id' } else { Fail "PostToolUse self-check: $(Get-ReplayResult $prRows 'PostToolUse')" }
if ((Get-ReplayResult $prRows 'UserPromptSubmit') -eq 'ok') { Pass 'UserPromptSubmit payload carries prompt' } else { Fail "UserPromptSubmit self-check: $(Get-ReplayResult $prRows 'UserPromptSubmit')" }
if ((Get-ReplayResult $prRows 'Stop') -eq 'ok') { Pass 'Stop payload carries last_assistant_message+stop_hook_active' } else { Fail "Stop self-check: $(Get-ReplayResult $prRows 'Stop')" }
if ((Get-ReplayResult $prRows 'SessionEnd') -eq 'ok') { Pass 'SessionEnd payload carries reason' } else { Fail "SessionEnd self-check: $(Get-ReplayResult $prRows 'SessionEnd')" }

# === 10. -TimeoutSec <= 0 does not hang (clamped to the 20s default) ============
$ClampHome = Join-Path $TMP 'clamp-home'
New-Item -ItemType Directory -Force -Path $ClampHome | Out-Null
'{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "exit 0" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $ClampHome 'hooks.json') -Encoding utf8NoBOM
$clampJson = Join-Path $TMP 'clamp-results.json'
$clampSw = [System.Diagnostics.Stopwatch]::StartNew()
& $Probe -CodexHome $ClampHome -Project $ClampHome -Replay -TimeoutSec -1 -NoFail -Json $clampJson | Out-Null
$clampSw.Stop()
if ($clampSw.Elapsed.TotalSeconds -lt 30) { Pass '-TimeoutSec -1 does not hang (clamped)' } else { Fail "-TimeoutSec -1 took $($clampSw.Elapsed.TotalSeconds)s (looks hung)" }
$cr = @((Get-Content -LiteralPath $clampJson -Raw | ConvertFrom-Json).replayResults)
if ($cr.Count -eq 1 -and $cr[0].result -eq 'ok') { Pass '-TimeoutSec -1 clamp still completes the hook (exit 0 -> ok)' } else { Fail "clamp replay result: $($cr | ConvertTo-Json -Compress)" }

# === 11. plugin hook file resolves via .codex-plugin/plugin.json (HIMMEL-2001) ==
# Separate hermetic CODEX_HOME so the counts asserted above stay untouched.
# Three plugin shapes, all enabled:
#   nohookplug  - manifest declares "hooks": {}      -> contributes nothing
#   declplug    - manifest declares a hooks path     -> that file is linted
#   bareplug    - no .codex-plugin manifest at all   -> hooks/hooks.json fallback
$MfHome = Join-Path $TMP 'manifest-home'
foreach ($leaf in 'nohookplug', 'declplug', 'bareplug') {
  New-Item -ItemType Directory -Force -Path (Join-Path $MfHome "plugins/cache/testmkt/$leaf/1.0.0/hooks") | Out-Null
}
foreach ($leaf in 'nohookplug', 'declplug') {
  New-Item -ItemType Directory -Force -Path (Join-Path $MfHome "plugins/cache/testmkt/$leaf/1.0.0/.codex-plugin") | Out-Null
}
@'
[plugins."nohookplug@testmkt"]
enabled = true

[plugins."declplug@testmkt"]
enabled = true

[plugins."bareplug@testmkt"]
enabled = true
'@ | Set-Content -LiteralPath (Join-Path $MfHome 'config.toml') -Encoding utf8NoBOM
'{ "hooks": {} }' | Set-Content -LiteralPath (Join-Path $MfHome 'plugins/cache/testmkt/nohookplug/1.0.0/.codex-plugin/plugin.json') -Encoding utf8NoBOM
'{ "hooks": "./hooks/hooks-codex.json" }' | Set-Content -LiteralPath (Join-Path $MfHome 'plugins/cache/testmkt/declplug/1.0.0/.codex-plugin/plugin.json') -Encoding utf8NoBOM
# Both manifest-bearing plugins ALSO ship a Claude-side hooks/hooks.json whose
# command would FAIL the quoted-path lint. Neither may be read (this is the
# exact superpowers 6.1.1 shape that produced the false FAIL).
foreach ($leaf in 'nohookplug', 'declplug') {
  '{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "\"C:\\claude\\side.cmd\" CLAUDE_SIDE_MARKER" } ] } ] } }' |
    Set-Content -LiteralPath (Join-Path $MfHome "plugins/cache/testmkt/$leaf/1.0.0/hooks/hooks.json") -Encoding utf8NoBOM
}
'{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "& \"${CLAUDE_PLUGIN_ROOT}/hooks/run.cmd\" DECLARED_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $MfHome 'plugins/cache/testmkt/declplug/1.0.0/hooks/hooks-codex.json') -Encoding utf8NoBOM
'{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "& \"${CLAUDE_PLUGIN_ROOT}/hooks/run.cmd\" FALLBACK_MARKER" } ] } ] } }' |
  Set-Content -LiteralPath (Join-Path $MfHome 'plugins/cache/testmkt/bareplug/1.0.0/hooks/hooks.json') -Encoding utf8NoBOM

$mfJson = Join-Path $TMP 'manifest-results.json'
& $Probe -CodexHome $MfHome -Project $MfHome -NoFail -Json $mfJson | Out-Null
$mf = Get-Content -LiteralPath $mfJson -Raw | ConvertFrom-Json
$mfRows = @($mf.rows)

if ($mfRows.Count -eq 2) { Pass 'manifest resolution: 2 rows (declared + fallback), empty-hooks plugin skipped' } else { Fail "manifest resolution: $($mfRows.Count) rows (want 2): $($mfRows.command -join ' | ')" }
if (-not (@($mfRows | Where-Object { $_.source -eq 'plugin:nohookplug' }))) { Pass 'manifest "hooks": {} contributes no rows' } else { Fail 'plugin with "hooks": {} leaked rows' }
if (@($mfRows | Where-Object { $_.command -like '*DECLARED_MARKER*' -and $_.source -eq 'plugin:declplug' })) { Pass 'declared hooks path is the file that gets linted' } else { Fail 'declared hooks path not read' }
if (@($mfRows | Where-Object { $_.command -like '*FALLBACK_MARKER*' -and $_.source -eq 'plugin:bareplug' })) { Pass 'no .codex-plugin manifest falls back to hooks/hooks.json' } else { Fail 'fallback to hooks/hooks.json broken' }
if (-not (@($mfRows | Where-Object { $_.command -like '*CLAUDE_SIDE_MARKER*' }))) { Pass 'Claude-side hooks/hooks.json never read when a manifest exists' } else { Fail 'Claude-side hooks/hooks.json leaked into the Codex hook set' }
if ($mf.summary.fail -eq 0) { Pass 'no false FAIL from a Claude-side hooks.json Codex never loads' } else { Fail "summary.fail = $($mf.summary.fail) (want 0)" }

Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "PASS" } else { Write-Host "FAIL ($fails)"; exit 1 }
