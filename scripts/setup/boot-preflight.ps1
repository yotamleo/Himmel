# boot-preflight.ps1 (HIMMEL-1163) - boot/logon readiness-check WATCHDOG.
#
# WHY: a stale codex-gateway credential, a missing lane API key, or a
# disarmed orphan-sweep cadence is otherwise only discovered MID-RUN, hours
# after the machine came up - by which point a session has already stalled or
# burned a retry loop on a 401. This script runs once per logon (registered
# by the OPERATOR, see below) and auto-verifies the same handful of
# preflight facts a human would eyeball, then ALERTS via Telegram ONLY when a
# MANUAL step is still needed. It is a VERIFIER + ALERT, never an
# auto-login: the codex gateway credential is an interactive device-OAuth
# flow (see cli-proxy-lane.ps1 -Login) that structurally cannot be scripted.
#
# CHECKS (each independently fail-soft - one section's error never blocks
# the others or the exit):
#   1. Orphan-sweep arm: HIMMEL-CodexOrphanSweep must carry an hourly
#      Repetition (Interval=PT1H) on its trigger(s) AND be ENABLED - a
#      disabled task with an otherwise-durable hourly trigger will never
#      actually run, so the enabled/disabled state is flagged as its own
#      PROBLEM even when the trigger checks pass. If a trigger is
#      missing it, re-assert it in place via Set-ScheduledTask - this
#      script runs in the TASK'S OWN context (SYSTEM/InteractiveToken at
#      logon), not the interactive session's guarded shell, so the
#      rogue-schedule / edit-on-main guards that block a live Claude
#      session from arming schedules do not apply here. Idempotent
#      belt-and-suspenders: a no-op on every run once conformant.
#   2. Gateway: ensure the cli-proxy-api scheduled task is Running (start it
#      if not), then shell out to the existing cli-proxy-lane.ps1 -Verify
#      and parse the "HTTP <code>" it prints. Anything other than 200 is
#      flagged (401/000 => stale/absent credential => re-run -Login).
#   3. Keys: DEEPSEEK_API_KEY and ZAI_API_KEY must be present (non-empty)
#      in the repo .env - grepped for the KEY= line only, value NEVER read
#      into a log or a Telegram message.
#   4. Report: write a readiness report to
#      ~/.claude/boot-preflight/boot-preflight.log (rotating the previous
#      run to .log.prev, mirroring codex-sweep.bat's rotation), and send a
#      Telegram summary ONLY when something needs attention (a fully-ready
#      boot sends nothing, to avoid noise).
#
# TELEGRAM SENDER (judgment call): scripts/telegram/*.ts exports a
# `sendMessage` (telegram-api.ts) but it is an internal helper of the
# bun poller/server request-response loop (scripts/telegram/poller.ts,
# marketplace/plugins/telegram-himmel/server.ts) - there is no standalone
# CLI/function meant for a one-shot, out-of-band alert with no inbound
# message context, and no bun runtime dependency belongs in an unattended
# PS 5.1 logon task. scripts/hooks/jira-nudge-on-end.sh already solves the
# IDENTICAL problem (a hook that must alert the operator proactively, no
# inbound message to reply to): TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID read
# from .env, best-effort curl-shaped POST to the bot API's sendMessage
# endpoint, failure swallowed. This script mirrors that EXACT established
# convention (same two env var names) via Invoke-RestMethod instead of
# inventing a new integration. If either var is absent from .env, the
# send degrades to "logged, not sent" - it never blocks or throws.
#
# STRUCTURE (mirrors scripts/cleanup/sweep-codex-orphans.ps1): pure
# predicate functions first (fed synthetic inputs, no OS calls), a
# `-AsLibrary` dot-source seam that returns before touching the live OS,
# then the production path. Hermetic test: test-boot-preflight.ps1.
#
# REGISTRATION (operator-run - this script never arms itself; the
# interactive session's rogue-schedule guard blocks a live Claude session
# from doing it, and by design the operator arms boot-time persistence):
#
#   Register-ScheduledTask -TaskName 'HIMMEL-BootPreflight' `
#     -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
#     -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "<repo>\scripts\setup\boot-preflight.ps1"') `
#     -Description 'HIMMEL boot readiness check (HIMMEL-1163)'
#
# Usage:
#   powershell -NoProfile -File scripts/setup/boot-preflight.ps1
#
# PowerShell 5.1-safe by construction (this is what runs the logon task):
# no assignment to $pid/$home/$input/$args, every conditional-array
# assignment is wrapped in @(...), and the only dot-source seam is this
# script's own -AsLibrary (no nested AsLibrary dot-source, so there is no
# caller-scope param clobber to guard against here).

[CmdletBinding()]
param(
  [switch]$AsLibrary
)

# --- pure helpers (fed records/strings; unit-tested directly) ---------------

# True iff the gateway's reported HTTP status is exactly 200. 401 (local
# bearer key rejected / upstream auth failure) and 000 (not running) are
# both "needs attention" - only a clean 200 is healthy.
function Test-GatewayHealthy {
  param([string]$HttpCode)
  return ($HttpCode -eq '200')
}

# Pure parser: pull the "HTTP <code>" cli-proxy-lane.ps1 -Verify prints out
# of its captured output. '000' (not running/unparseable) when no match -
# same fallback the production path already defaulted to, just factored out
# so the polling loop below (OS calls: Start-Sleep, process invoke) stays a
# thin shell around something a test can still drive hermetically with a
# plain string, no live proxy required.
function Get-GatewayHttpCodeFromVerifyOutput {
  param([string]$VerifyOutput)
  if ($VerifyOutput -match 'HTTP\s+(\d{3})') { return $Matches[1] }
  return '000'
}

# The trigger descriptor consumed by the sweep-armed predicates below and by
# the gather site in the production path. Single-sources the shape (Interval +
# the two repetition-lifetime fields) so production and tests can never drift
# on which fields "armed" is judged against, and so property access stays
# StrictMode-2.0-safe (every descriptor carries all three members). Fed plain
# values pulled off the live CIM Repetition object; never the CIM object itself.
function New-SweepTriggerDescriptor {
  param(
    [AllowEmptyString()][string]$Interval,
    [AllowEmptyString()][string]$Duration,
    [bool]$StopAtDurationEnd
  )
  return [pscustomobject]@{
    Interval          = $Interval
    Duration          = $Duration
    StopAtDurationEnd = $StopAtDurationEnd
  }
}

# True iff a single trigger carries a DURABLE hourly repetition: Interval is the
# ISO-8601 PT1H AND the repetition runs indefinitely. A PT1H trigger with a
# finite Duration (or StopAtDurationEnd enabled) stops repeating once its window
# elapses - the sweep then goes dark while still LOOKING armed to an
# interval-only check (HIMMEL-1163 CR: validate the whole repetition LIFETIME,
# not just the interval). An indefinite pattern has no Duration (Interval alone -
# see the Task Scheduler docs: no Duration => repeat forever), so a non-empty
# Duration OR a set StopAtDurationEnd both disqualify. Fed the raw
# interval/duration strings + the flag (never the live CIM object), so this
# stays testable with plain values.
function Test-SweepArmed {
  param(
    [AllowEmptyString()][string]$RepetitionInterval,
    [AllowEmptyString()][string]$RepetitionDuration,
    [bool]$StopAtDurationEnd
  )
  if ($RepetitionInterval -ne 'PT1H') { return $false }
  if (-not [string]::IsNullOrEmpty($RepetitionDuration)) { return $false }
  if ($StopAtDurationEnd) { return $false }
  return $true
}

# "Armed" for the WHOLE task requires EVERY trigger to satisfy Test-SweepArmed,
# not just any one (CR round 2, HIMMEL-1163) - a task with more than one trigger
# and only SOME of them durably-hourly still leaves a gap. Fed trigger
# descriptors (Interval + Duration + StopAtDurationEnd), not bare interval
# strings, so the lifetime check reaches every trigger. An EMPTY collection is
# explicitly NOT armed (not vacuously true - a task with no triggers at all is
# not "armed" by having nothing to fail the check).
function Test-AllSweepTriggersArmed {
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Triggers)
  $all = @($Triggers)
  if ($all.Count -eq 0) { return $false }
  # Where-Object's result is wrapped in its OWN @(...) (not just the input):
  # a single-match pipeline can yield a bare scalar, and under StrictMode
  # 2.0 a bare scalar's .Count is not reliably an adapted member - only an
  # array guarantees it.
  $unarmedCount = (@(@($all) | Where-Object {
    -not (Test-SweepArmed -RepetitionInterval ([string]$_.Interval) `
      -RepetitionDuration ([string]$_.Duration) `
      -StopAtDurationEnd ([bool]$_.StopAtDurationEnd))
  })).Count
  return ($unarmedCount -eq 0)
}

# Pure .env-text parser: KeyName's value on a `KEY=value` line (first match,
# trimmed, one surrounding matching pair of quotes stripped). $null when
# absent, EnvText is empty, or the value is empty (bare or after unquoting -
# CR round 1, HIMMEL-1163): a `.env` convention like KEY="v" / KEY='v' is
# common, and returning the value WITH its quotes was two real bugs - a
# quoted-empty KEY="" looked non-empty (false "present") to Test-KeysPresent,
# and the Telegram token/chat_id would have been sent to the API URL/body
# WITH literal quote characters. Only a quote pair that spans the WHOLE
# value (same char at both ends) is stripped - an inner quote that isn't
# part of a surrounding pair (KEY="a'b") is left untouched. Never used to
# surface a value to a log/alert - callers only ever test presence
# (Test-KeysPresent) except the two operator-facing relay credentials
# (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID), which must be READ to be used but
# are never printed.
function Get-EnvValue {
  param([string]$EnvText, [string]$KeyName)
  if (-not $EnvText) { return $null }
  $pattern = "(?m)^\s*$([regex]::Escape($KeyName))\s*=\s*(.+?)\s*$"
  $m = [regex]::Match($EnvText, $pattern)
  if (-not $m.Success) { return $null }
  $val = $m.Groups[1].Value.Trim()
  if ($val.Length -ge 2) {
    $firstChar = $val.Substring(0, 1)
    $lastChar = $val.Substring($val.Length - 1, 1)
    if (($firstChar -eq '"' -or $firstChar -eq "'") -and ($firstChar -eq $lastChar)) {
      $val = $val.Substring(1, $val.Length - 2)
      # Re-trim AFTER stripping the quote pair (CR round 3, HIMMEL-1163): a
      # quoted whitespace-only value (KEY="   ") loses its quotes above and
      # leaves bare spaces, which IsNullOrEmpty does NOT catch (it is only
      # empty, not whitespace-only) - the key would misreport "present".
      # The first .Trim() (pre-strip) intentionally stays: it trims
      # trailing junk OUTSIDE a quoted value, e.g. `KEY="v"  ` -> `"v"`.
      $val = $val.Trim()
    }
  }
  if ([string]::IsNullOrEmpty($val)) { return $null }
  return $val
}

# Presence check ONLY (never the value) for the two lane keys. Returns a
# hashtable { DEEPSEEK_API_KEY = bool; ZAI_API_KEY = bool }.
function Test-KeysPresent {
  param([string]$EnvText)
  $deepseek = [bool](Get-EnvValue -EnvText $EnvText -KeyName 'DEEPSEEK_API_KEY')
  $zai      = [bool](Get-EnvValue -EnvText $EnvText -KeyName 'ZAI_API_KEY')
  return @{
    DEEPSEEK_API_KEY = $deepseek
    ZAI_API_KEY      = $zai
  }
}

# The headline pure assembler: given the raw findings from each check (never
# the live OS objects), produce a { Ready; Lines; Problems; AlertText }
# report. AlertText is $null when Ready (no-alert contract) and a single
# remediation-bearing string otherwise.
function Get-ReadinessReport {
  param(
    [Parameter(Mandatory)][bool]$SweepTaskFound,
    [Parameter(Mandatory)][bool]$SweepTaskEnabled,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SweepTriggers,
    [Parameter(Mandatory)][bool]$SweepReassertAttempted,
    [Parameter(Mandatory)][bool]$SweepReassertOk,
    [Parameter(Mandatory)][AllowEmptyString()][string]$GatewayHttpCode,
    [Parameter(Mandatory)][AllowEmptyString()][string]$EnvText
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $problems = New-Object System.Collections.Generic.List[string]

  # --- 1. orphan-sweep arm ---
  $sweepArmedNow = Test-AllSweepTriggersArmed -Triggers $SweepTriggers
  if (-not $SweepTaskFound) {
    $lines.Add('[sweep]    PROBLEM - HIMMEL-CodexOrphanSweep task not found')
    $problems.Add('HIMMEL-CodexOrphanSweep scheduled task is missing - arm it: bash scripts/cleanup/codex-sweep-cadence.sh arm')
  } elseif (-not $SweepTaskEnabled) {
    # A disabled task never runs regardless of its trigger/repetition state -
    # checked ahead of $sweepArmedNow so a durably-hourly-but-disabled task is
    # still flagged (a disabled-but-hourly task will never actually sweep).
    $lines.Add('[sweep]    PROBLEM - HIMMEL-CodexOrphanSweep task is DISABLED')
    $problems.Add('HIMMEL-CodexOrphanSweep scheduled task is disabled - enable it: schtasks /change /tn HIMMEL-CodexOrphanSweep /enable')
  } elseif ($sweepArmedNow) {
    if ($SweepReassertAttempted -and $SweepReassertOk) {
      $lines.Add('[sweep]    OK - hourly repetition (PT1H) was missing; re-asserted this run')
    } else {
      $lines.Add('[sweep]    OK - hourly repetition (PT1H) present')
    }
  } else {
    $why = if ($SweepReassertAttempted) { 're-assert FAILED' } else { 'not armed' }
    $lines.Add("[sweep]    PROBLEM - hourly repetition missing ($why)")
    $problems.Add("HIMMEL-CodexOrphanSweep is missing its hourly (PT1H) repetition ($why) - inspect: schtasks /query /tn HIMMEL-CodexOrphanSweep /fo LIST /v")
  }

  # --- 2. gateway ---
  # Remediation differs by failure MODE (CR round 2, HIMMEL-1163): 000 means
  # the proxy is simply unreachable (task not running / verifier failed) -
  # telling the operator to re-login when the gateway is DOWN, not
  # rejecting a credential, is actively misleading. Only 401 (up, credential
  # rejected) points at -Login; 000 points at connectivity; anything else
  # names the code and asks for a look before retrying auth.
  if (Test-GatewayHealthy -HttpCode $GatewayHttpCode) {
    $lines.Add('[gateway]  OK - HTTP 200')
  } else {
    $lines.Add("[gateway]  PROBLEM - HTTP $GatewayHttpCode")
    if ($GatewayHttpCode -eq '401') {
      $problems.Add('gateway credential stale - run: powershell -NoProfile -File scripts/setup/cli-proxy-lane.ps1 -Login')
    } elseif ($GatewayHttpCode -eq '000') {
      $problems.Add('gateway unavailable - verify the cli-proxy-api task is running, then cli-proxy-lane.ps1 -Verify')
    } else {
      $problems.Add("gateway returned HTTP $GatewayHttpCode - inspect the proxy before retrying auth")
    }
  }

  # --- 3. keys ---
  $keys = Test-KeysPresent -EnvText $EnvText
  foreach ($k in ($keys.Keys | Sort-Object)) {
    if ($keys[$k]) {
      $lines.Add("[keys]     OK - $k present")
    } else {
      $lines.Add("[keys]     PROBLEM - $k missing")
      $problems.Add("$k is missing from .env - add it before the lane that needs it runs")
    }
  }

  $ready = ($problems.Count -eq 0)
  $alertText = $null
  if (-not $ready) {
    $alertText = "[boot-preflight] manual attention needed:`n" + (($problems.ToArray()) -join "`n")
  }

  return [pscustomobject]@{
    Ready     = $ready
    Lines     = $lines.ToArray()
    Problems  = $problems.ToArray()
    AlertText = $alertText
  }
}

if ($AsLibrary) { return }

# --- production path ---------------------------------------------------------

# Watchdog contract: NOTHING below may escape uncaught. Each section is its
# own try/catch so one problem never masks the others' findings, and this
# outer catch is the last-resort net so even an unanticipated failure still
# exits clean rather than surfacing as a blocked/failed logon task.
try {

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$CliProxyLane = Join-Path $PSScriptRoot 'cli-proxy-lane.ps1'
$EnvPath = Join-Path $RepoRoot '.env'
# $userHome (not $HOME): $HOME is a read-only PowerShell automatic variable
# (assigning to it throws); USERPROFILE is the reliable Windows home on a
# scheduled-task context (mirrors scripts/observability/host-detectors.ps1).
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$LogDir = Join-Path $userHome '.claude\boot-preflight'
$LogPath = Join-Path $LogDir 'boot-preflight.log'

$RegisterHint = "Register-ScheduledTask -TaskName 'HIMMEL-BootPreflight' -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File `"$RepoRoot\scripts\setup\boot-preflight.ps1`"') -Description 'HIMMEL boot readiness check (HIMMEL-1163)'"

# --- 1. orphan-sweep arm: check + belt-and-suspenders re-assert ---
$SweepTaskName = 'HIMMEL-CodexOrphanSweep'
$sweepTaskFound = $false
$sweepTaskEnabled = $true
$sweepTriggers = @()
$sweepReassertAttempted = $false
$sweepReassertOk = $false
try {
  $sweepTask = Get-ScheduledTask -TaskName $SweepTaskName -ErrorAction Stop
  $sweepTaskFound = $true
  $sweepTaskEnabled = [bool]$sweepTask.Enabled
  $sweepTriggers = @($sweepTask.Triggers | ForEach-Object {
    New-SweepTriggerDescriptor -Interval ([string]$_.Repetition.Interval) `
      -Duration ([string]$_.Repetition.Duration) `
      -StopAtDurationEnd ([bool]$_.Repetition.StopAtDurationEnd)
  })
  $armedNow = Test-AllSweepTriggersArmed -Triggers $sweepTriggers
  if (-not $armedNow) {
    $sweepReassertAttempted = $true
    try {
      $updatedTriggers = @()
      foreach ($t in $sweepTask.Triggers) {
        $t.Repetition.Interval = 'PT1H'
        $t.Repetition.Duration = ''
        $t.Repetition.StopAtDurationEnd = $false
        $updatedTriggers += $t
      }
      Set-ScheduledTask -TaskName $SweepTaskName -Trigger $updatedTriggers -ErrorAction Stop | Out-Null
      $sweepReassertOk = $true
      $sweepTriggers = @((Get-ScheduledTask -TaskName $SweepTaskName -ErrorAction Stop).Triggers | ForEach-Object {
        New-SweepTriggerDescriptor -Interval ([string]$_.Repetition.Interval) `
          -Duration ([string]$_.Repetition.Duration) `
          -StopAtDurationEnd ([bool]$_.Repetition.StopAtDurationEnd)
      })
    } catch {
      $sweepReassertOk = $false
    }
  }
} catch {
  $sweepTaskFound = $false
}

# --- 2. gateway: start the task if not Running, then POLL -Verify until
# healthy or a bounded timeout (CR round 1, HIMMEL-1163). A single -Verify
# right after Start-ScheduledTask races the proxy's own bind time - on a
# slow boot a fixed short sleep would misreport a still-starting gateway as
# stale-credential and fire a false alert. Bounded poll instead (repo
# convention, docs/internals/environment-gotchas.md: poll until healthy or a
# deadline, never a fixed sleep): stop the instant a 200 is seen, otherwise
# keep trying on a short interval until the deadline, and report whatever
# the LAST attempt saw.
$gatewayHttpCode = '000'
try {
  $gwTask = Get-ScheduledTask -TaskName 'cli-proxy-api' -ErrorAction Stop
  if ($gwTask.State -ne 'Running') {
    Start-ScheduledTask -TaskName 'cli-proxy-api' -ErrorAction Stop
  }
} catch {
  # task missing / start failed - still poll -Verify below (the proxy may
  # already be up detached, or this simply surfaces as a 000 finding).
}
$GatewayPollTimeoutSeconds = 20
$GatewayPollIntervalSeconds = 2
$gatewayPollDeadline = (Get-Date).AddSeconds($GatewayPollTimeoutSeconds)
while ($true) {
  try {
    if (Test-Path -LiteralPath $CliProxyLane) {
      # *>&1 (ALL streams), not 2>&1 (stderr only): cli-proxy-lane.ps1's -Verify
      # prints via Write-Host, which in PS5+ writes to the Information stream
      # (6) - a plain 2>&1 never sees it (confirmed live: $verifyOut came back
      # empty while the line still appeared directly on the console), so the
      # HTTP-code parse below would silently never match and every boot would
      # misreport 000 regardless of the real gateway state.
      $verifyOut = & $CliProxyLane -Verify *>&1 | Out-String
      $gatewayHttpCode = Get-GatewayHttpCodeFromVerifyOutput -VerifyOutput $verifyOut
    }
  } catch {
    $gatewayHttpCode = '000'
  }
  if (Test-GatewayHealthy -HttpCode $gatewayHttpCode) { break }
  if ((Get-Date) -ge $gatewayPollDeadline) { break }
  Start-Sleep -Seconds $GatewayPollIntervalSeconds
}

# --- 3. keys: read .env text (never printed) ---
$envText = ''
try {
  if (Test-Path -LiteralPath $EnvPath) {
    $envText = Get-Content -LiteralPath $EnvPath -Raw -ErrorAction Stop
  }
} catch {
  $envText = ''
}

# --- assemble the report ---
$report = $null
try {
  $report = Get-ReadinessReport -SweepTaskFound $sweepTaskFound -SweepTaskEnabled $sweepTaskEnabled `
    -SweepTriggers $sweepTriggers `
    -SweepReassertAttempted $sweepReassertAttempted -SweepReassertOk $sweepReassertOk `
    -GatewayHttpCode $gatewayHttpCode -EnvText $envText
} catch {
  $report = [pscustomobject]@{ Ready = $false; Lines = @("[report]   PROBLEM - could not assemble readiness report: $_"); Problems = @('report assembly failed'); AlertText = "[boot-preflight] report assembly failed: $_" }
}

# --- 4. Telegram alert (only when NOT ready) ---
$telegramNote = 'no alert needed (all ready)'
if (-not $report.Ready) {
  $telegramToken = Get-EnvValue -EnvText $envText -KeyName 'TELEGRAM_BOT_TOKEN'
  $telegramChatId = Get-EnvValue -EnvText $envText -KeyName 'TELEGRAM_CHAT_ID'
  if ($telegramToken -and $telegramChatId) {
    try {
      $uri = "https://api.telegram.org/bot$telegramToken/sendMessage"
      Invoke-RestMethod -Uri $uri -Method Post -Body @{ chat_id = $telegramChatId; text = $report.AlertText } -TimeoutSec 10 -ErrorAction Stop | Out-Null
      $telegramNote = 'alert sent via Telegram'
    } catch {
      # HIMMEL-1163 (CR): fixed message, NOT $_ — the exception can echo the
      # request URI (which carries the bot token) into the log. Degraded
      # log-only behavior is preserved; the token is never surfaced.
      $telegramNote = 'telegram send FAILED (degraded to log-only)'
    }
  } else {
    $telegramNote = 'telegram send unavailable - TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID not present in .env (degraded to log-only)'
  }
}

# --- write the log (rotate previous run to .log.prev, codex-sweep.bat style) ---
try {
  if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
  if (Test-Path -LiteralPath $LogPath) {
    Move-Item -LiteralPath $LogPath -Destination "$LogPath.prev" -Force
  }
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $body = New-Object System.Collections.Generic.List[string]
  $body.Add("[boot-preflight $stamp] HIMMEL-1163 - overall: $(if ($report.Ready) { 'READY' } else { 'NEEDS ATTENTION' })")
  foreach ($l in $report.Lines) { $body.Add($l) }
  $body.Add("[telegram] $telegramNote")
  if (-not $report.Ready) {
    $body.Add('')
    $body.Add('If HIMMEL-BootPreflight itself is not yet registered, arm it with:')
    $body.Add("  $RegisterHint")
  }
  ($body.ToArray() -join "`r`n") | Set-Content -LiteralPath $LogPath -Encoding UTF8
} catch {
  [Console]::Error.WriteLine("[boot-preflight] could not write log at $LogPath`: $_")
}

Write-Host "[boot-preflight] $(if ($report.Ready) { 'READY' } else { "NEEDS ATTENTION ($($report.Problems.Count) problem(s))" }) - log: $LogPath"

} catch {
  # Last-resort net: the watchdog must never throw in a way that blocks logon.
  [Console]::Error.WriteLine("[boot-preflight] unexpected failure (watchdog fail-soft, not blocking logon): $_")
}

exit 0
