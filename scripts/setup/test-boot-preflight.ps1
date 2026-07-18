# Hermetic tests for boot-preflight.ps1 (HIMMEL-1163).
# Dot-sources the script with -AsLibrary (defines the pure predicate
# functions, returns before touching the live OS) and drives them with
# synthetic inputs - no live scheduled tasks, no network, no real .env.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'boot-preflight.ps1'

$script:Pass = 0
$script:Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name" }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { Pass $Name; $script:Pass++ } else { Fail $Name $Detail; $script:Fail++ }
}

# Load the pure functions without running the production scan/OS calls.
. $Helper -AsLibrary

# Terse trigger-descriptor builder for the armed-check tests. Defaults match an
# indefinite hourly repetition (no Duration, StopAtDurationEnd off) so a bare
# `Trig 'PT1H'` is the armed baseline; override to model a finite/stopping one.
function Trig([string]$Interval, [string]$Duration = '', [bool]$StopAtDurationEnd = $false) {
  New-SweepTriggerDescriptor -Interval $Interval -Duration $Duration -StopAtDurationEnd $StopAtDurationEnd
}

# --- Test-GatewayHealthy: 200 vs 401/000 -------------------------------------
Check 'gateway 200 is healthy' (Test-GatewayHealthy -HttpCode '200')
Check 'gateway 401 is NOT healthy' (-not (Test-GatewayHealthy -HttpCode '401'))
Check 'gateway 000 (not running) is NOT healthy' (-not (Test-GatewayHealthy -HttpCode '000'))

# --- Test-SweepArmed: durable hourly (interval PT1H + indefinite lifetime) ----
Check 'sweep PT1H indefinite is armed' (Test-SweepArmed -RepetitionInterval 'PT1H' -RepetitionDuration '' -StopAtDurationEnd $false)
Check 'sweep empty interval is NOT armed' (-not (Test-SweepArmed -RepetitionInterval '' -RepetitionDuration '' -StopAtDurationEnd $false))
Check 'sweep PT24H is NOT armed (not hourly)' (-not (Test-SweepArmed -RepetitionInterval 'PT24H' -RepetitionDuration '' -StopAtDurationEnd $false))
Check 'sweep $null interval is NOT armed' (-not (Test-SweepArmed -RepetitionInterval $null -RepetitionDuration '' -StopAtDurationEnd $false))
# Lifetime findings (HIMMEL-1163 CR): a PT1H interval alone is NOT enough - a
# finite Duration or a set StopAtDurationEnd means the hourly repeats STOP.
Check 'sweep PT1H with finite Duration is NOT armed' (-not (Test-SweepArmed -RepetitionInterval 'PT1H' -RepetitionDuration 'PT4H' -StopAtDurationEnd $false))
Check 'sweep PT1H with StopAtDurationEnd is NOT armed' (-not (Test-SweepArmed -RepetitionInterval 'PT1H' -RepetitionDuration '' -StopAtDurationEnd $true))

# --- Test-AllSweepTriggersArmed: EVERY trigger, not ANY (CR round 2) ---------
Check 'all triggers PT1H -> armed' (Test-AllSweepTriggersArmed -Triggers @(Trig 'PT1H'))
Check 'multiple triggers all PT1H -> armed' (Test-AllSweepTriggersArmed -Triggers @((Trig 'PT1H'), (Trig 'PT1H')))
Check 'mixed intervals (one PT1H, one un-repeated) -> NOT armed' (-not (Test-AllSweepTriggersArmed -Triggers @((Trig 'PT1H'), (Trig ''))))
Check 'empty trigger list -> NOT armed (not vacuously armed)' (-not (Test-AllSweepTriggersArmed -Triggers @()))
Check 'single un-repeated trigger -> NOT armed' (-not (Test-AllSweepTriggersArmed -Triggers @(Trig '')))
# Lifetime findings at the whole-task level: one PT1H-but-finite trigger among
# otherwise-armed ones still leaves the sweep able to go dark.
Check 'all PT1H but one has finite Duration -> NOT armed' (-not (Test-AllSweepTriggersArmed -Triggers @((Trig 'PT1H'), (Trig 'PT1H' 'P1D'))))
Check 'single PT1H with StopAtDurationEnd -> NOT armed' (-not (Test-AllSweepTriggersArmed -Triggers @(Trig 'PT1H' '' $true)))

# --- Get-GatewayHttpCodeFromVerifyOutput: parse or fall back to 000 --------
Check 'verify-output parse: HTTP 200 line' ((Get-GatewayHttpCodeFromVerifyOutput -VerifyOutput 'proxy http://127.0.0.1:8317 -> HTTP 200  (200/401 = reachable; 000 = not running)') -eq '200')
Check 'verify-output parse: HTTP 401 line' ((Get-GatewayHttpCodeFromVerifyOutput -VerifyOutput 'proxy http://127.0.0.1:8317 -> HTTP 401  (200/401 = reachable; 000 = not running)') -eq '401')
Check 'verify-output parse: unparseable text falls back to 000' ((Get-GatewayHttpCodeFromVerifyOutput -VerifyOutput 'binary missing at ...') -eq '000')
Check 'verify-output parse: empty text falls back to 000' ((Get-GatewayHttpCodeFromVerifyOutput -VerifyOutput '') -eq '000')

# --- Get-EnvValue: presence/parsing -------------------------------------------
$envBoth = "DEEPSEEK_API_KEY=sk-abc123`nZAI_API_KEY=zai-xyz789`nOTHER=1`n"
$envOneMissing = "DEEPSEEK_API_KEY=sk-abc123`nOTHER=1`n"
$envNeither = "OTHER=1`n"

Check 'Get-EnvValue finds a present key' ((Get-EnvValue -EnvText $envBoth -KeyName 'DEEPSEEK_API_KEY') -eq 'sk-abc123')
Check 'Get-EnvValue returns $null for an absent key' ($null -eq (Get-EnvValue -EnvText $envNeither -KeyName 'DEEPSEEK_API_KEY'))
Check 'Get-EnvValue returns $null on empty EnvText' ($null -eq (Get-EnvValue -EnvText '' -KeyName 'DEEPSEEK_API_KEY'))

# --- Get-EnvValue: quote stripping (CR round 1, HIMMEL-1163) -----------------
Check 'double-quoted value unquotes' ((Get-EnvValue -EnvText 'KEY="v"' -KeyName 'KEY') -eq 'v')
Check 'single-quoted value unquotes' ((Get-EnvValue -EnvText "KEY='v'" -KeyName 'KEY') -eq 'v')
Check 'quoted-empty value is absent ($null), not a non-empty string of quotes' ($null -eq (Get-EnvValue -EnvText 'KEY=""' -KeyName 'KEY'))
Check 'unquoted value is unchanged' ((Get-EnvValue -EnvText 'KEY=v' -KeyName 'KEY') -eq 'v')
Check 'inner quote NOT part of a surrounding pair is preserved' ((Get-EnvValue -EnvText 'KEY="a''b"' -KeyName 'KEY') -eq "a'b")

# --- Get-EnvValue: quoted whitespace-only value (CR round 3, HIMMEL-1163) ----
# KEY="   " loses its quotes leaving bare spaces - IsNullOrEmpty alone does
# NOT catch that (only a zero-length string, not whitespace), so the value
# must be re-trimmed AFTER unquoting before the empty check.
Check 'quoted whitespace-only value is absent ($null), not "present"' ($null -eq (Get-EnvValue -EnvText 'KEY="   "' -KeyName 'KEY'))
Check 'Test-KeysPresent reads a quoted whitespace-only key as absent' ((Test-KeysPresent -EnvText 'DEEPSEEK_API_KEY="   "').DEEPSEEK_API_KEY -eq $false)

# --- Test-KeysPresent: both present vs one missing vs neither ----------------
$keysBoth = Test-KeysPresent -EnvText $envBoth
Check 'both keys present -> DEEPSEEK true' ($keysBoth.DEEPSEEK_API_KEY -eq $true)
Check 'both keys present -> ZAI true' ($keysBoth.ZAI_API_KEY -eq $true)

$keysOneMissing = Test-KeysPresent -EnvText $envOneMissing
Check 'one missing -> DEEPSEEK true' ($keysOneMissing.DEEPSEEK_API_KEY -eq $true)
Check 'one missing -> ZAI false' ($keysOneMissing.ZAI_API_KEY -eq $false)

$keysNeither = Test-KeysPresent -EnvText $envNeither
Check 'neither present -> DEEPSEEK false' ($keysNeither.DEEPSEEK_API_KEY -eq $false)
Check 'neither present -> ZAI false' ($keysNeither.ZAI_API_KEY -eq $false)

# --- Get-ReadinessReport: all-ready -> no alert -------------------------------
$readyReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig 'PT1H') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '200' -EnvText $envBoth
Check 'all-ready report: Ready is true' ($readyReport.Ready -eq $true)
Check 'all-ready report: AlertText is null (no-alert contract)' ($null -eq $readyReport.AlertText)
Check 'all-ready report: no problems recorded' (@($readyReport.Problems).Count -eq 0)

# --- Get-ReadinessReport: gateway problem -> alert with remediation text ----
$gatewayProblemReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig 'PT1H') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '401' -EnvText $envBoth
Check 'gateway problem: Ready is false' ($gatewayProblemReport.Ready -eq $false)
Check 'gateway problem: AlertText present' (-not [string]::IsNullOrEmpty($gatewayProblemReport.AlertText))
Check 'gateway 401: alert names the -Login remediation' ($gatewayProblemReport.AlertText -match 'cli-proxy-lane\.ps1 -Login')

# --- Get-ReadinessReport: gateway 000 -> connectivity remediation, NOT -Login
# (CR round 2, HIMMEL-1163: 000 means the proxy is unreachable, not that a
# credential was rejected - telling the operator to re-login is misleading).
$gatewayDownReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig 'PT1H') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '000' -EnvText $envBoth
Check 'gateway 000: Ready is false' ($gatewayDownReport.Ready -eq $false)
Check 'gateway 000: alert names connectivity, not -Login' (($gatewayDownReport.AlertText -match 'gateway unavailable') -and ($gatewayDownReport.AlertText -notmatch 'cli-proxy-lane\.ps1 -Login'))

# --- Get-ReadinessReport: gateway other code -> generic "inspect" remediation
$gatewayOtherReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig 'PT1H') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '503' -EnvText $envBoth
Check 'gateway 503: Ready is false' ($gatewayOtherReport.Ready -eq $false)
Check 'gateway 503: alert names the code, not -Login' (($gatewayOtherReport.AlertText -match 'HTTP 503') -and ($gatewayOtherReport.AlertText -notmatch 'cli-proxy-lane\.ps1 -Login'))

# --- Get-ReadinessReport: missing key -> alert with remediation text --------
$keyProblemReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig 'PT1H') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '200' -EnvText $envOneMissing
Check 'missing key: Ready is false' ($keyProblemReport.Ready -eq $false)
Check 'missing key: alert names ZAI_API_KEY' ($keyProblemReport.AlertText -match 'ZAI_API_KEY')

# --- Get-ReadinessReport: sweep not armed, no reassert attempted -------------
$sweepProblemReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig '') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '200' -EnvText $envBoth
Check 'sweep not armed: Ready is false' ($sweepProblemReport.Ready -eq $false)
Check 'sweep not armed: alert names HIMMEL-CodexOrphanSweep' ($sweepProblemReport.AlertText -match 'HIMMEL-CodexOrphanSweep')

# --- Get-ReadinessReport: PT1H interval but FINITE duration -> NOT ready ------
# End-to-end proof of the lifetime finding (HIMMEL-1163 CR): an interval-only
# check would call this "armed", but the hourly repeats stop when the window
# elapses, so the report must flag it and the reassert path must not be skipped.
$sweepFiniteReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig 'PT1H' 'PT4H') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '200' -EnvText $envBoth
Check 'sweep PT1H+finite duration: Ready is false' ($sweepFiniteReport.Ready -eq $false)
Check 'sweep PT1H+finite duration: alert names HIMMEL-CodexOrphanSweep' ($sweepFiniteReport.AlertText -match 'HIMMEL-CodexOrphanSweep')

# --- Get-ReadinessReport: durably-hourly trigger but task DISABLED -> NOT ready
# A disabled task never fires regardless of how healthy its trigger is - an
# interval/lifetime-only check would call this "armed", so the enabled/disabled
# state must be its own PROBLEM even with a durable PT1H trigger present.
$sweepDisabledReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $false -SweepTriggers @(Trig 'PT1H') `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '200' -EnvText $envBoth
Check 'sweep disabled task: Ready is false' ($sweepDisabledReport.Ready -eq $false)
Check 'sweep disabled task: alert recommends enabling' ($sweepDisabledReport.AlertText -match 'enable')

# --- Get-ReadinessReport: sweep not armed but successfully re-asserted THIS run
$sweepReassertedReport = Get-ReadinessReport -SweepTaskFound $true -SweepTaskEnabled $true -SweepTriggers @(Trig 'PT1H') `
  -SweepReassertAttempted $true -SweepReassertOk $true -GatewayHttpCode '200' -EnvText $envBoth
Check 're-asserted this run: Ready is true (self-healed)' ($sweepReassertedReport.Ready -eq $true)
Check 're-asserted this run: no alert' ($null -eq $sweepReassertedReport.AlertText)

# --- Get-ReadinessReport: sweep task not found at all ------------------------
$sweepMissingReport = Get-ReadinessReport -SweepTaskFound $false -SweepTaskEnabled $true -SweepTriggers @() `
  -SweepReassertAttempted $false -SweepReassertOk $false -GatewayHttpCode '200' -EnvText $envBoth
Check 'sweep task not found: Ready is false' ($sweepMissingReport.Ready -eq $false)
Check 'sweep task not found: alert names codex-sweep-cadence.sh arm' ($sweepMissingReport.AlertText -match 'codex-sweep-cadence\.sh arm')

Write-Host ""
Write-Host "test-boot-preflight: $script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
