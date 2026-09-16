# Hermetic test for wire-statusline.ps1 (HIMMEL-359 / HIMMEL-718). Temp dir only,
# no network. Mirrors test-wire-statusline.sh so the bash/PowerShell twins stay in
# parity -- HIMMEL-718 Task 4.1 switched the command to the hud renderer (node),
# added the .env extra-cmd gate, and drops the hud config. Case 5 pins the
# invalid-JSON exit code (the bug the CR caught: Write-Error+return exited 0,
# masking the refusal from -File callers).
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$helper = Join-Path $here 'wire-statusline.ps1'
$repoRoot = (Resolve-Path (Join-Path $here '..\..')).Path.Replace('\', '/')
$tmp    = Join-Path ([IO.Path]::GetTempPath()) ("twsl-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $tmp | Out-Null
$script:fail = 0
function Check([bool]$cond, [string]$msg) {
    if ($cond) { Write-Host "ok $msg" } else { Write-Host "FAIL $msg"; $script:fail = 1 }
}
# HIMMEL-2892: the hud config now lands under ${CLAUDE_CONFIG_DIR:-~/.claude},
# never beside the settings file -- so this suite pins CLAUDE_CONFIG_DIR at a
# throwaway dir for the WHOLE run. Without the pin it would write into the
# RUNNER'S real config dir. Restored on exit.
$prevClaudeConfigDir = $env:CLAUDE_CONFIG_DIR
$cfgDir = Join-Path $tmp 'config-dir'
$env:CLAUDE_CONFIG_DIR = $cfgDir

# Invoke the helper the way production callers do (-File) so $LASTEXITCODE is real.
function Wire([string]$path, [string]$himmel) {
    & pwsh -NoProfile -File $helper -SettingsPath $path -HimmelPath $himmel *> $null
    return $LASTEXITCODE
}

# 1 fresh file + backslash path normalized + extra-cmd gate
Wire "$tmp\s1.json" 'C:\fake\himmel' | Out-Null
$s1 = Get-Content "$tmp\s1.json" -Raw | ConvertFrom-Json
Check ($s1.statusLine.command -eq 'node "C:/fake/himmel/marketplace/plugins/claude-hud/dist/index.js"') "1 fresh+backslash-normalized"
Check ($s1.env.CLAUDE_HUD_ALLOW_EXTRA_CMD -eq '1') "1b extra-cmd gate set"

# 2 existing keys preserved incl. pre-existing .env keys (non-destructive merge)
'{"theme":"dark","env":{"CR_PROFILE":"paid"}}' | Set-Content "$tmp\s2.json"
Wire "$tmp\s2.json" 'C:\fake\himmel' | Out-Null
$s2 = Get-Content "$tmp\s2.json" -Raw | ConvertFrom-Json
Check ($s2.theme -eq 'dark' -and $s2.statusLine.type -eq 'command') "2 existing keys preserved"
Check ($s2.env.CR_PROFILE -eq 'paid' -and $s2.env.CLAUDE_HUD_ALLOW_EXTRA_CMD -eq '1') "2b env merged non-destructively"

# 3 idempotent
Wire "$tmp\s3.json" 'C:\fake\himmel' | Out-Null
$a = Get-Content "$tmp\s3.json" -Raw
Wire "$tmp\s3.json" 'C:\fake\himmel' | Out-Null
Check ((Get-Content "$tmp\s3.json" -Raw) -eq $a) "3 idempotent"

# 4 empty file -> {}
New-Item -ItemType File "$tmp\s4.json" | Out-Null
Wire "$tmp\s4.json" 'C:\fake\himmel' | Out-Null
$s4 = Get-Content "$tmp\s4.json" -Raw | ConvertFrom-Json
Check ($s4.statusLine.type -eq 'command') "4 empty file handled"

# 5 non-empty INVALID json -> exit non-zero + not clobbered (parity with bash case 7)
'{not valid' | Set-Content "$tmp\s5.json"
$rc = Wire "$tmp\s5.json" 'C:\fake\himmel'
Check ($rc -ne 0) "5a invalid json exits non-zero"
Check ((Get-Content "$tmp\s5.json" -Raw).Trim() -eq '{not valid') "5b invalid json not clobbered"

# 6 hud config dropped under CLAUDE_CONFIG_DIR with <himmel-path> SUBSTITUTED.
# Uses the REAL himmel clone so the source himmel-config.json exists.
$sdir = Join-Path $tmp 'cfgdrop'
Wire (Join-Path $sdir 'settings.json') $repoRoot | Out-Null
$dropped = Join-Path $cfgDir 'plugins/claude-hud/config.json'
Check (Test-Path $dropped) "6a hud config dropped under CLAUDE_CONFIG_DIR"
if (Test-Path $dropped) {
    $body = Get-Content $dropped -Raw
    Check (-not ($body -match '<himmel-path>')) "6b placeholder substituted"
    Check ($body.Contains($repoRoot)) "6c real himmel path substituted"
    $sj = Get-Content (Join-Path $sdir 'settings.json') -Raw | ConvertFrom-Json
    Check ($sj.statusLine.command -eq "node `"$repoRoot/marketplace/plugins/claude-hud/dist/index.js`"") "6d command node w/ real path"
    $dj = $body | ConvertFrom-Json
    Check ($dj.display.showPromptCache -eq $true) "6e dropped config has showPromptCache: true"
}

# 7 HIMMEL-2892: a PROJECT settings path leaves NOTHING under the project dir.
# The 2026-09-09 dogfood incident: a project-scope install dropped an untracked
# .claude/plugins/claude-hud/config.json inside the repo.
$proj7 = Join-Path $tmp 'proj7'
New-Item -ItemType Directory -Force (Join-Path $proj7 '.claude') | Out-Null
$cfg7 = Join-Path $tmp 'cfg7'
$env:CLAUDE_CONFIG_DIR = $cfg7
Wire (Join-Path $proj7 '.claude/settings.json') $repoRoot | Out-Null
Check (-not (Test-Path (Join-Path $proj7 '.claude/plugins'))) "7a nothing dropped inside the project dir"
Check (Test-Path (Join-Path $cfg7 'plugins/claude-hud/config.json')) "7b hud config landed under CLAUDE_CONFIG_DIR"
$env:CLAUDE_CONFIG_DIR = $cfgDir

# 8 HIMMEL-3065: the hud's RUNTIME cache state is dropped when the wiring
# CHANGES, and only then -- parity with bash cases 16-20. config.json is
# settings this script owns; everything beside it is per-session snapshot state
# that must not survive a migration onto a different install.
function Seed-HudCache([string]$dir) {
    foreach ($sub in @('transcript-cache', 'context-cache', 'config-cache')) {
        New-Item -ItemType Directory -Force (Join-Path $dir $sub) | Out-Null
        '{"stale":true}' | Set-Content (Join-Path $dir "$sub/deadbeef.json")
    }
    '{"reads":1,"writes":2,"inputs":3,"computedAt":1}' | Set-Content (Join-Path $dir 'cache-economics-all.json')
    '{"date":"20260101","sessions":{}}' | Set-Content (Join-Path $dir 'daily-cost.json')
}

$cfg8 = Join-Path $tmp 'cfg8'
$hud8 = Join-Path $cfg8 'plugins/claude-hud'
$proj8 = Join-Path $tmp 'proj8'
New-Item -ItemType Directory -Force (Join-Path $proj8 '.claude') | Out-Null
$s8 = Join-Path $proj8 '.claude/settings.json'
$env:CLAUDE_CONFIG_DIR = $cfg8
# An EARLIER install's command is already wired, and its snapshots are on disk.
'{"statusLine":{"type":"command","command":"node \"/old/himmel/marketplace/plugins/claude-hud/dist/index.js\""}}' | Set-Content $s8
New-Item -ItemType Directory -Force $hud8 | Out-Null
Seed-HudCache $hud8
Wire $s8 $repoRoot | Out-Null
Check (-not (Test-Path (Join-Path $hud8 'transcript-cache'))) "8a changed wiring drops transcript-cache"
Check (-not (Test-Path (Join-Path $hud8 'context-cache'))) "8b changed wiring drops context-cache"
Check (-not (Test-Path (Join-Path $hud8 'daily-cost.json'))) "8c changed wiring drops the daily-cost ledger"
Check (Test-Path (Join-Path $hud8 'config.json')) "8d config.json survives the purge"

# 9 steady state: the SAME clone re-wired over its own wiring changes nothing,
# so the caches stay -- otherwise every update would throw away the context
# fallback snapshot of every live session.
Seed-HudCache $hud8
Wire $s8 $repoRoot | Out-Null
Check (Test-Path (Join-Path $hud8 'transcript-cache/deadbeef.json')) "9a unchanged re-wire keeps transcript-cache"
Check (Test-Path (Join-Path $hud8 'daily-cost.json')) "9b unchanged re-wire keeps the daily-cost ledger"

# 10 the CONFIG half on its own: same command, but an earlier install's hud
# config on disk (the migration case where the clone path is unchanged).
'{"display":{"showPromptCache":false}}' | Set-Content (Join-Path $hud8 'config.json')
Seed-HudCache $hud8
Wire $s8 $repoRoot | Out-Null
Check (-not (Test-Path (Join-Path $hud8 'transcript-cache'))) "10a a changed hud config drops the cache state"
$c10 = Get-Content (Join-Path $hud8 'config.json') -Raw | ConvertFrom-Json
Check ($c10.display.showPromptCache -eq $true) "10b hud config refreshed"

# 11 a MOVED/renamed clone (the command half on its own): a synthetic himmel
# path drops no config, so the command comparison decides by itself.
$cfg11 = Join-Path $tmp 'cfg11'
$hud11 = Join-Path $cfg11 'plugins/claude-hud'
$proj11 = Join-Path $tmp 'proj11'
New-Item -ItemType Directory -Force (Join-Path $proj11 '.claude') | Out-Null
$s11 = Join-Path $proj11 '.claude/settings.json'
$env:CLAUDE_CONFIG_DIR = $cfg11
Wire $s11 'C:\old\path\himmel' | Out-Null
New-Item -ItemType Directory -Force $hud11 | Out-Null
Seed-HudCache $hud11
Wire $s11 'C:\new\path\himmel' | Out-Null
Check (-not (Test-Path (Join-Path $hud11 'transcript-cache'))) "11 a moved clone drops the hud cache state"
$env:CLAUDE_CONFIG_DIR = $cfgDir

# 12 CR round 1 [codex-1]: `"statusLine": null` is valid JSON — the property
# EXISTS while its value is $null, so reading the previous command must not
# dereference it. The wire must still succeed and replace the null.
$proj12 = Join-Path $tmp 'proj12'
New-Item -ItemType Directory -Force (Join-Path $proj12 '.claude') | Out-Null
$s12 = Join-Path $proj12 '.claude/settings.json'
'{"statusLine":null,"theme":"dark"}' | Set-Content $s12
$rc12 = Wire $s12 'C:\fake\himmel'
Check ($rc12 -eq 0) "12a a null statusLine does not break the wire"
$c12 = Get-Content $s12 -Raw | ConvertFrom-Json
Check ($c12.statusLine.type -eq 'command') "12b null statusLine replaced"
Check ($c12.theme -eq 'dark') "12c other keys preserved"

# 13 CR round 1 [codex-2]: the hud config is per-USER but the settings file may
# be a PROJECT one, so wiring a machine's SECOND project on the same install is
# not a migration and must not purge the other projects' live snapshots.
$cfg13 = Join-Path $tmp 'cfg13'
$hud13 = Join-Path $cfg13 'plugins/claude-hud'
$proj13a = Join-Path $tmp 'proj13a'
$proj13b = Join-Path $tmp 'proj13b'
New-Item -ItemType Directory -Force (Join-Path $proj13a '.claude') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $proj13b '.claude') | Out-Null
$env:CLAUDE_CONFIG_DIR = $cfg13
Wire (Join-Path $proj13a '.claude/settings.json') $repoRoot | Out-Null
Seed-HudCache $hud13
Wire (Join-Path $proj13b '.claude/settings.json') $repoRoot | Out-Null
Check (Test-Path (Join-Path $hud13 'transcript-cache/deadbeef.json')) "13 a second project on the same install keeps the cache state"
$env:CLAUDE_CONFIG_DIR = $cfgDir

$env:CLAUDE_CONFIG_DIR = $prevClaudeConfigDir
Get-ChildItem $tmp -Recurse | Remove-Item -Force -Recurse
Remove-Item $tmp -Force
if ($script:fail) { Write-Host "FAILURES"; exit 1 } else { Write-Host "ALL PASS"; exit 0 }
