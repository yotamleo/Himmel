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

# 6 hud config dropped next to settings.json with <himmel-path> SUBSTITUTED.
# Uses the REAL himmel clone so the source himmel-config.json exists.
$sdir = Join-Path $tmp 'cfgdrop'
Wire (Join-Path $sdir 'settings.json') $repoRoot | Out-Null
$dropped = Join-Path $sdir 'plugins/claude-hud/config.json'
Check (Test-Path $dropped) "6a hud config dropped"
if (Test-Path $dropped) {
    $body = Get-Content $dropped -Raw
    Check (-not ($body -match '<himmel-path>')) "6b placeholder substituted"
    Check ($body.Contains($repoRoot)) "6c real himmel path substituted"
    $sj = Get-Content (Join-Path $sdir 'settings.json') -Raw | ConvertFrom-Json
    Check ($sj.statusLine.command -eq "node `"$repoRoot/marketplace/plugins/claude-hud/dist/index.js`"") "6d command node w/ real path"
}

Get-ChildItem $tmp -Recurse | Remove-Item -Force -Recurse
Remove-Item $tmp -Force
if ($script:fail) { Write-Host "FAILURES"; exit 1 } else { Write-Host "ALL PASS"; exit 0 }
