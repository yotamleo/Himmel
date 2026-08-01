# Hermetic fixture tests for install-stack.ps1's task stop/register/start/
# restore logic (HIMMEL-1217 CR round 3). Mirrors the mocking approach
# test-host-detectors.ps1 uses for host-detectors.ps1: instead of testing a
# script full of real network downloads and elevated Task Scheduler calls
# directly, this mocks the ScheduledTasks cmdlets with an in-memory fake
# task store, then dot-sources the REAL function definitions extracted live
# from install-stack.ps1 (everything up to the `$scriptDir = ...` line that
# starts its imperative install body) so the functions under test can never
# silently drift out of sync with a hand-copied duplicate.
#
# Not wired into any CI runner (same as test-host-detectors.ps1 -- neither
# is discovered by scripts/ci/run-shell-tests.sh, which only walks bash
# suites). Run manually: pwsh -File scripts/observability/test-install-stack.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target = Join-Path $ScriptDir 'install-stack.ps1'

# ---- fake Task Scheduler state ---------------------------------------------
$Global:FakeTasks = @{}          # TaskName -> @{ State; Def }
$Global:RegisterBehavior = @{}   # TaskName -> @{ New = 'throw'|'succeed'; Restore = 'throw'|'succeed' }
$Global:BrokenNewDefs = @()      # TaskNames whose NEW (non-restore) definition fails to start (async, no throw)
$Global:StopBehavior = @{}       # TaskName -> 'succeed' | 'timeout' | 'throw'
# TaskName -> 'fail' (every read throws a generic, non-"not found" error) OR
# @{ SucceedCount = <int>; FailCount = <int> } (the first SucceedCount reads
# behave normally, the next FailCount reads throw, then normal forever) --
# lets a test target a lookup failure at a SPECIFIC phase (e.g. the post-stop
# poll) without also breaking the initial-discovery read that necessarily
# comes first.
$Global:LookupBehavior = @{}
# TaskName -> int: once Start-ScheduledTask (re)starts a task configured
# here, it is observed Running for exactly that many subsequent reads, then
# flips to Ready on every read after -- deterministically simulating a task
# that dies shortly after entering Running (port conflict, an S4U resource
# failure that only bites once the process tries to use something) without
# depending on real wall-clock timing. Reads BEFORE the task is (re)started
# (discovery, the stop-poll) are unaffected -- see Start-ScheduledTask below,
# which is what (re)initializes DiesAfterReadsRemaining.
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining = @{}  # internal; do not set directly from a test
$Global:StartBehavior = @{}      # TaskName -> 'throw' (Start-ScheduledTask itself throws synchronously, distinct
                                  # from BrokenNewDefs' "registers/starts without throwing, never reaches Running")
$Global:UnregisterBehavior = @{} # TaskName -> 'throw' (Unregister-ScheduledTask fails); default 'succeed'
# codex-adv-r18-3: TaskName -> LogonType at the moment Export-ScheduledTask
# (mock) last captured it, so a Register-ScheduledTask RESTORE call (which
# never passes -Principal -- it's registering from saved XML, not building a
# fresh definition) can put back the principal the SAVED definition actually
# had, not silently default it. Populated by the Export-ScheduledTask mock;
# read by the Register-ScheduledTask mock's restore branch.
$Global:SavedTaskLogonType = @{}
# Ordered log of "Stop:<name>" / "Register-New:<name>" / "Register-Restore:<name>"
# / "Start:<name>" entries -- lets a test assert CALL ORDER (e.g. "Stop
# happened before Register-Restore"), not just final state, since final
# state alone can look identical whether or not a fix actually ran (see
# Test 15's comment).
$Global:CallLog = New-Object System.Collections.Generic.List[string]

function Get-ScheduledTask {
  param([string]$TaskName, [string]$ErrorAction)
  if ($Global:LookupBehavior.ContainsKey($TaskName)) {
    $lb = $Global:LookupBehavior[$TaskName]
    if ($lb -eq 'fail') {
      # A generic `throw` (not a Get-ScheduledTask "no such task" error) --
      # its CategoryInfo.Category is NotSpecified, not ObjectNotFound, so
      # Resolve-ExistingTask (install-stack.ps1) correctly treats this as a
      # FAILED lookup, not a confirmed-absent task.
      throw "FAKE: RPC server is unavailable"
    }
    if ($lb -is [hashtable]) {
      if ($lb.SucceedCount -gt 0) {
        $lb.SucceedCount--
      } elseif ($lb.FailCount -gt 0) {
        $lb.FailCount--
        throw "FAKE: RPC server is unavailable (transient)"
      }
      # both counters exhausted -> fall through to normal behavior below, permanently
    }
  }
  if (-not $Global:FakeTasks.ContainsKey($TaskName)) {
    if ($ErrorAction -eq 'SilentlyContinue') { return $null }
    # Round 17 [glm-r16-5]: the REAL Get-ScheduledTask cmdlet raises a
    # non-terminating error (which -ErrorAction Stop, what Resolve-
    # ExistingTask always passes, turns into a catchable terminating one)
    # categorized ObjectNotFound for a missing named task -- it does NOT
    # just cleanly return $null the way this mock previously did
    # unconditionally. That meant Resolve-ExistingTask's own
    # `$_.CategoryInfo.Category -eq 'ObjectNotFound'` catch branch was
    # never actually exercised by this suite; every "fresh/missing task"
    # scenario was silently taking the try block's success path instead.
    # Net externally-observable behavior for callers is unchanged (Resolve-
    # ExistingTask still returns $null for a missing task either way) --
    # this only routes it through the code path meant to handle it.
    Write-Error -Message "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'." -Category ObjectNotFound -ErrorAction Stop
  }
  $entry = $Global:FakeTasks[$TaskName]
  if ($Global:DiesAfterReadsRemaining.ContainsKey($TaskName)) {
    if ($Global:DiesAfterReadsRemaining[$TaskName] -le 0) {
      $entry.State = 'Ready'
    } else {
      $Global:DiesAfterReadsRemaining[$TaskName]--
    }
  }
  # codex-adv-r18-3: default 'InteractiveToken' (non-S4U) for the many
  # pre-existing test fixtures that construct a $Global:FakeTasks entry
  # directly (@{ State = ...; Def = ... }) without a LogonType key -- matches
  # their current implicit non-hidden behavior exactly, so none of them need
  # to change. Only fixtures that explicitly opt in with a LogonType key (or
  # tasks Register-ScheduledTask itself creates, below) carry 'S4U'.
  $logonType = if ($entry.ContainsKey('LogonType')) { $entry.LogonType } else { 'InteractiveToken' }
  [pscustomobject]@{ TaskName = $TaskName; State = $entry.State; Principal = [pscustomobject]@{ LogonType = $logonType } }
}

function Get-ScheduledTaskInfo {
  param([string]$TaskName, [string]$ErrorAction)
  [pscustomobject]@{ LastTaskResult = 0 }
}

function Stop-ScheduledTask {
  param([string]$TaskName, [string]$ErrorAction)
  $Global:CallLog.Add("Stop:$TaskName") | Out-Null
  $behavior = if ($Global:StopBehavior.ContainsKey($TaskName)) { $Global:StopBehavior[$TaskName] } else { 'succeed' }
  if ($behavior -eq 'throw') { throw "FAKE: stop denied for $TaskName" }
  # 'succeed' flips state to Ready immediately; 'timeout' leaves it Running
  # forever, so a Wait-TaskStopped poll exhausts its deadline.
  if ($behavior -eq 'succeed') { $Global:FakeTasks[$TaskName].State = 'Ready' }
}

function Start-ScheduledTask {
  param([string]$TaskName, [string]$ErrorAction)
  $Global:CallLog.Add("Start:$TaskName") | Out-Null
  if (-not $Global:FakeTasks.ContainsKey($TaskName)) { throw "FAKE: no such task $TaskName" }
  if ($Global:StartBehavior.ContainsKey($TaskName) -and $Global:StartBehavior[$TaskName] -eq 'throw') {
    throw "FAKE: Start-ScheduledTask itself failed synchronously for $TaskName"
  }
  if ($Global:DiesAfterReadsConfig.ContainsKey($TaskName)) {
    # (Re)arm the "alive for N reads" budget starting from THIS start
    # attempt, not from whatever earlier discovery/stop-poll reads happened
    # before the task was even (re)started, and independent of
    # Register-ScheduledTask replacing the FakeTasks entry in between.
    $Global:DiesAfterReadsRemaining[$TaskName] = $Global:DiesAfterReadsConfig[$TaskName]
  }
  $def = $Global:FakeTasks[$TaskName].Def
  if ($def -like 'BROKEN:*') {
    # Async failure (the S4U logon-rights style case): Start-ScheduledTask
    # itself does not throw, the task just never reaches Running.
    return
  }
  $Global:FakeTasks[$TaskName].State = 'Running'
}

function Register-ScheduledTask {
  param($TaskName, $Xml, $Action, $Trigger, $Settings, $Description, [switch]$Force, $Principal, [string]$ErrorAction)
  $isRestore = [bool]$Xml
  $Global:CallLog.Add($(if ($isRestore) { "Register-Restore:$TaskName" } else { "Register-New:$TaskName" })) | Out-Null
  # RegisterBehavior[$TaskName] is @{ New = 'throw'|'succeed'; Restore = 'throw'|'succeed' }
  # (either key absent defaults to 'succeed') -- a real "bad new principal"
  # failure does not necessarily also break restoring a DIFFERENT,
  # previously-valid XML, so the mock must be able to fail one without the
  # other.
  $behavior = 'succeed'
  if ($Global:RegisterBehavior.ContainsKey($TaskName)) {
    $entry = $Global:RegisterBehavior[$TaskName]
    if ($isRestore -and $entry.ContainsKey('Restore')) { $behavior = $entry['Restore'] }
    elseif ((-not $isRestore) -and $entry.ContainsKey('New')) { $behavior = $entry['New'] }
  }
  if ($behavior -eq 'throw') { throw "FAKE: Access is denied registering $TaskName" }
  # Realistically, -Force replaces only the DEFINITION -- it does NOT touch
  # an already-running process (this is the exact production bug class
  # these tests exist to catch: codex-adv-r8-1 was found because an earlier
  # version of THIS mock reset State on every Register-ScheduledTask call,
  # which could never have caught it). Preserve whatever State the task
  # currently has; only a task with no prior entry (never registered before)
  # starts at 'Ready' (not yet started).
  $priorState = if ($Global:FakeTasks.ContainsKey($TaskName)) { $Global:FakeTasks[$TaskName].State } else { 'Ready' }
  if ($isRestore) {
    # codex-adv-r18-3: a restore call never passes -Principal (it registers
    # from saved XML, not a freshly-built definition) -- put back whatever
    # LogonType Export-ScheduledTask last captured for this task, not a
    # fresh evaluation of $Principal (which would always be $null here and
    # silently reset a restored S4U task to non-S4U). Falls back to
    # 'InteractiveToken' for the couple of pre-existing tests that assign
    # $script:SavedTaskXml directly instead of going through Export-
    # ScheduledTask -- unaffected, matches their current behavior.
    $logonType = if ($Global:SavedTaskLogonType.ContainsKey($TaskName)) { $Global:SavedTaskLogonType[$TaskName] } else { 'InteractiveToken' }
    $Global:FakeTasks[$TaskName] = @{ State = $priorState; Def = $Xml; LogonType = $logonType }
  } else {
    $newDef = if ($Global:BrokenNewDefs -contains $TaskName) { "BROKEN:$TaskName" } else { "NEW-DEF:$TaskName" }
    $logonType = if ($Principal) { 'S4U' } else { 'InteractiveToken' }
    $Global:FakeTasks[$TaskName] = @{ State = $priorState; Def = $newDef; LogonType = $logonType }
  }
}

function Export-ScheduledTask {
  param([string]$TaskName)
  if (-not $Global:FakeTasks.ContainsKey($TaskName)) { throw "FAKE: cannot export missing task $TaskName" }
  # codex-adv-r18-3: capture the LIVE LogonType now, before anything touches
  # it, exactly the same "save what's actually running before this call
  # overwrites it" semantic the real Export-ScheduledTask XML already covers
  # for Def -- Register-ScheduledTask's restore branch reads this back.
  $entry = $Global:FakeTasks[$TaskName]
  $Global:SavedTaskLogonType[$TaskName] = if ($entry.ContainsKey('LogonType')) { $entry.LogonType } else { 'InteractiveToken' }
  return "SAVED-XML:${TaskName}:$($entry.Def)"
}

function Unregister-ScheduledTask {
  param([string]$TaskName, [switch]$Confirm, [string]$ErrorAction)
  $Global:CallLog.Add("Unregister:$TaskName") | Out-Null
  $behavior = if ($Global:UnregisterBehavior.ContainsKey($TaskName)) { $Global:UnregisterBehavior[$TaskName] } else { 'succeed' }
  if ($behavior -eq 'throw') { throw "FAKE: Access is denied unregistering $TaskName" }
  $Global:FakeTasks.Remove($TaskName)
}

function New-ScheduledTaskAction { param([string]$Execute, [string]$Argument, [string]$WorkingDirectory) [pscustomobject]@{} }
function New-ScheduledTaskTrigger {
  param([switch]$AtLogOn, [string]$User, [switch]$Once, [datetime]$At, [timespan]$RepetitionInterval)
  [pscustomobject]@{ Delay = $null; Repetition = [pscustomobject]@{ StopAtDurationEnd = $null } }
}
function New-ScheduledTaskSettingsSet {
  param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit, $RestartCount, $RestartInterval)
  [pscustomobject]@{}
}
function New-ScheduledTaskPrincipal { param([string]$UserId, [string]$LogonType, [string]$RunLevel) [pscustomobject]@{} }

# ---- extract + dot-source the REAL function definitions from install-stack.ps1,
#      stopping before its imperative install body (the `$scriptDir = ...`
#      line) so this test can never quietly diverge from production code --
#      there is no separately maintained copy of the functions to go stale.
$targetLines = Get-Content -LiteralPath $Target
$bodyStart = ($targetLines | Select-String -Pattern '^\$scriptDir = Split-Path' -List).LineNumber
if (-not $bodyStart) { throw "Could not find the install body marker in $Target -- extraction pattern is stale, update this test." }
$functionLines = $targetLines[0..($bodyStart - 2)]
$tempFunctionsFile = [System.IO.Path]::GetTempFileName() + '.ps1'
Set-Content -LiteralPath $tempFunctionsFile -Value $functionLines -Encoding utf8
try {
  . $tempFunctionsFile -RepoRoot 'C:\fixture-repo-root-unused'
} finally {
  Remove-Item -LiteralPath $tempFunctionsFile -Force -ErrorAction SilentlyContinue
}

# codex-adv-r18-1: production Write-Step itself now uses Write-Host (not
# Write-Output -- a real bug this override was originally added to shield
# THIS TEST from, without noticing the identical leak also corrupted
# PRODUCTION's own Restore-TaskDefinition/Remove-FreshTaskRegistration/
# Repair-AmbiguousStop return values whenever their caller captured them into
# a variable -- see install-stack.ps1's Write-Step comment). This override is
# now redundant with production's own definition, but kept for isolation and
# defense in depth: every dot-sourced call Write-Step makes during a mocked
# run (e.g. from inside Register-LogonTask or Restore-TaskDefinition) stays
# off this test's own capture (`$r = Invoke-InstallSequence ...`) even if
# production's choice of stream ever changes again independently. Test 29
# below deliberately re-dot-sources the RAW production Write-Step (bypassing
# this override) to pin the production fix itself, not just this shield.
function Write-Step {
  param([string]$Message)
  Write-Host "[observability] $Message"
}

# ---- replica of install-stack.ps1's orchestration (try/catch/finally +
#      reporting) driving the REAL dot-sourced functions the same way the
#      actual script's imperative body does -----------------------------------
function Invoke-InstallSequence {
  param([string[]]$TaskOrder, [switch]$Hidden)

  # codex-adv-r18-3: $script: (not a local var) -- Register-LogonTask and
  # Confirm-TaskStillRunning are dot-sourced production functions whose
  # lexical parent is this TEST FILE's own top-level scope (dot-sourcing
  # grafts them there), not this function's local scope, so an unqualified
  # `$Hidden` read inside them resolves against $script:Hidden, exactly
  # mirroring how install-stack.ps1's own top-level `param([switch]$Hidden)`
  # is itself a script-scope variable its functions read the same way.
  # Every existing call site omits -Hidden, defaulting to $false here
  # identically to today's implicit-$null-is-falsy behavior -- no other test
  # is affected.
  $script:Hidden = [bool]$Hidden
  $script:SavedTaskXml = @{}
  $script:StoppedTaskNames = New-Object System.Collections.Generic.List[string]
  $script:ReplacedTaskNames = New-Object System.Collections.Generic.List[string]
  $script:FreshTaskNames = New-Object System.Collections.Generic.List[string]
  $script:StopAttemptedTaskNames = New-Object System.Collections.Generic.List[string]
  $taskStartStatus = [ordered]@{}
  $scriptFailed = $false

  try {
    foreach ($t in $TaskOrder) {
      Register-LogonTask -TaskName $t -Execute 'x.exe' -Arguments 'a' -WorkingDirectory 'C:\wd'
    }
    foreach ($taskName in $TaskOrder) {
      Start-ScheduledTask -TaskName $taskName
      # TimeoutSeconds 0 would make the real function's `while ((Get-Date) -lt
      # $deadline)` false before the loop body ever runs once -- always
      # $false regardless of actual state. Production never calls it with 0;
      # use the smallest positive value so the check genuinely executes.
      # StabilitySeconds 0 skips the REAL sleep production waits between the
      # first Running observation and its recheck -- the mock's
      # DiesAfterReads mechanism is read-count-based, not wall-clock-based,
      # so the stability logic is still exercised correctly and
      # deterministically without slowing this whole suite down. (This
      # override is test-only, in code this file owns; the dot-sourced
      # PRODUCTION Restore-TaskDefinition calls Wait-TaskStarted with no
      # override at all, so restore-and-start scenarios below still pay
      # the real ~3s default at least once, exercising the untouched path.)
      $started = Wait-TaskStarted -TaskName $taskName -TimeoutSeconds 1 -StabilitySeconds 0
      $taskStartStatus[$taskName] = $started
    }
    # Final revalidation sweep -- mirrors install-stack.ps1's own sweep
    # exactly (round-6 fix): a task confirmed started above can still have
    # gone down by the time every other exporter has finished starting.
    # Round 15: calls the REAL dot-sourced Confirm-TaskStillRunning (not a
    # reimplementation) -- a FAILED lookup (no retry loop to fall back into,
    # unlike the polls) is 'indeterminate', never silently "not Running".
    foreach ($taskName in $TaskOrder) {
      if ($taskStartStatus[$taskName] -eq $true) {
        $reconfirmed = Confirm-TaskStillRunning -TaskName $taskName -ExpectedHidden:$Hidden
        if ($reconfirmed -ne $true) {
          $taskStartStatus[$taskName] = $reconfirmed
        }
      }
    }
    # Round-12 fix: a single exporter's Wait-TaskStarted returning $false is
    # an honest per-task report, not an exception -- $scriptFailed alone
    # would stay $false and the finally block's narrower per-task check
    # would leave successful siblings on the requested definition and any
    # fresh registration standing. A CONFIRMED not-Running exporter means
    # the batch did not fully succeed; treat it the same as an aborted run.
    # Round-17 fix: scoped to $false only, NOT "-ne $true" -- an
    # 'indeterminate' sweep result (round 15: the lookup itself failed, not
    # evidence the task is unhealthy) must not fold into this flag and drag
    # every healthy sibling into a full rollback on an RPC blip.
    if (@($TaskOrder | Where-Object { $taskStartStatus[$_] -eq $false }).Count -gt 0) {
      $scriptFailed = $true
    }
  }
  catch {
    $scriptFailed = $true
  }
  finally {
    # Round-6 fix: restore-eligibility is the UNION of StoppedTaskNames (was
    # Running, confirmed stopped) and ReplacedTaskNames (this run's new-def
    # Register-ScheduledTask actually succeeded, regardless of prior running
    # state) -- matches install-stack.ps1's real finally block exactly.
    # Round-8 fix: on an ABORTED run ($scriptFailed), roll back EVERY
    # rollback candidate uniformly, even one already $true -- otherwise a
    # task that individually succeeded before a LATER task's failure
    # aborted the batch would keep the requested (e.g. S4U) definition
    # while its siblings get restored, a mixed stack after a partial
    # failure. On a clean run, only a task that itself failed needs
    # recovery (the narrower -ne $true check).
    $rollbackCandidates = @($script:StoppedTaskNames) + @($script:ReplacedTaskNames | Where-Object { $script:StoppedTaskNames -notcontains $_ })
    foreach ($taskName in $rollbackCandidates) {
      # Round-17 fix: an 'indeterminate' task (the sweep's own lookup
      # failed) is left alone entirely -- attempting a restore on it would
      # be a corrective action based on nothing more than a transient
      # lookup blip. String-on-the-left (not $taskStartStatus[...] -eq
      # 'indeterminate'): $taskStartStatus values can be the literal
      # boolean $true, and $true -eq 'indeterminate' coerces truthy,
      # silently matching every healthy task too -- this exact ordering
      # bug shipped once in this file and in the mirrored production line
      # before Test 23 caught the regression.
      if ('indeterminate' -eq $taskStartStatus[$taskName]) {
        continue
      }
      if ($scriptFailed -or $taskStartStatus[$taskName] -ne $true) {
        $wasRunningBefore = $script:StoppedTaskNames -contains $taskName
        $restored = Restore-TaskDefinition -TaskName $taskName -StartAfterRestore:$wasRunningBefore
        $taskStartStatus[$taskName] = if ($restored) { 'restored' } else { $false }
      }
    }
    # Round-10 fix: a task with no prior existence has nothing to restore to
    # -- on an aborted batch it is unregistered instead, mirroring install-
    # stack.ps1's own finally block exactly.
    if ($scriptFailed) {
      foreach ($taskName in $script:FreshTaskNames) {
        $removed = Remove-FreshTaskRegistration -TaskName $taskName
        $taskStartStatus[$taskName] = if ($removed) { 'removed' } else { $false }
      }
    }
    # Round-12 fix: a task whose stop was ATTEMPTED but never CONFIRMED fell
    # through $rollbackCandidates above entirely (in neither StoppedTaskNames
    # nor ReplacedTaskNames). Its definition is guaranteed untouched, so
    # Repair-AmbiguousStop's job is narrower: just re-establish whether it's
    # actually running.
    foreach ($taskName in $script:StopAttemptedTaskNames) {
      if ($script:StoppedTaskNames -notcontains $taskName) {
        $taskStartStatus[$taskName] = Repair-AmbiguousStop -TaskName $taskName
      }
    }
  }

  # Mirrors install-stack.ps1's actual exit-code formula exactly (round-4/5
  # fix): scoped to $TaskOrder (every REQUESTED exporter), not to
  # StoppedTaskNames (which stays rollback-decision-only) -- a fresh install
  # whose exporters all fail their async start must still fail here, and a
  # successfully-restored task must still fail here even though the stack is
  # up, because the requested flip did not apply.
  $notFlippedTasks = @($TaskOrder | Where-Object { $taskStartStatus[$_] -ne $true })
  # String-on-the-left (round 17): see install-stack.ps1's matching comment
  # -- $taskStartStatus[$_] -eq 'restored' would silently also match every
  # $true task via boolean/string coercion.
  $restoredTasks = @($TaskOrder | Where-Object { 'restored' -eq $taskStartStatus[$_] })

  [pscustomobject]@{
    ScriptFailed = $scriptFailed
    NotFlipped   = $notFlippedTasks
    Restored     = $restoredTasks
    Status       = $taskStartStatus
    ExitCode     = if ($scriptFailed -or $notFlippedTasks.Count -gt 0) { 1 } else { 0 }
  }
}

# ---- test harness -----------------------------------------------------------
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

Write-Host "Test 1: a later exception rolls back an earlier task's own-succeeded-but-never-started registration too"
# prometheus: was Running, stop+re-register (new def) both succeed -- but the
# shared start loop only runs AFTER every Register-LogonTask call in the
# batch completes. grafana (registered second) has its OWN Register-
# ScheduledTask throw, aborting the try block before the start loop ever
# runs -- so even though prometheus's own re-registration succeeded, it
# never gets started either. Per the CR's ask ("on any later exception...
# RESTORE the saved definition"), finally rolls BOTH back to their SAVED
# pre-run definitions: a run that didn't complete guarantees no regression,
# not partial credit for a task whose own step happened to succeed before a
# sibling failed. Round-5 contract: both being 'restored' means the
# REQUESTED flip did not apply to either, so both belong in NotFlipped too
# (on top of ScriptFailed already forcing non-zero here).
$Global:FakeTasks = @{
  'prometheus' = @{ State = 'Running'; Def = 'OLD:prometheus' }
  'grafana'    = @{ State = 'Running'; Def = 'OLD:grafana' }
}
$Global:RegisterBehavior = @{ 'grafana' = @{ New = 'throw' } }  # Restore absent -> defaults to 'succeed'
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('prometheus', 'grafana')
Check 'prometheus ends Running (restored -- never reached the start loop)' ($Global:FakeTasks['prometheus'].State -eq 'Running')
Check 'prometheus restored from its SAVED pre-run definition' ($Global:FakeTasks['prometheus'].Def -eq 'SAVED-XML:prometheus:OLD:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check 'grafana ends Running (restored)' ($Global:FakeTasks['grafana'].State -eq 'Running')
Check 'grafana restored from the SAVED pre-run definition, not a NEW one' ($Global:FakeTasks['grafana'].Def -eq 'SAVED-XML:grafana:OLD:grafana') "got=$($Global:FakeTasks['grafana'].Def)"
Check 'both tasks land in Restored (requested flip did not apply to either)' ($r.Restored.Count -eq 2) "restored=$($r.Restored -join ',')"
Check 'both tasks land in NotFlipped' ($r.NotFlipped.Count -eq 2) "notFlipped=$($r.NotFlipped -join ',')"
Check 'ScriptFailed is true (registration aborted)' ($r.ScriptFailed -eq $true)
Check 'exit code is 1' ($r.ExitCode -eq 1)

Write-Host "Test 2 [pins codex-r4-1]: restored-instead-of-flipped is non-zero even when the run otherwise completed cleanly"
# winexp: the requested (new) definition registers fine and Start-
# ScheduledTask doesn't throw, but it never actually reaches Running (async
# S4U-style failure) -- finally restores the OLD, working definition and
# confirms it running. Round 4 found this exiting 0: the stack stayed alive,
# but the requested -Hidden flip silently did not apply. It must be non-zero.
# Round 12 broadened ScriptFailed's meaning: nothing here literally throws,
# but any exporter not reaching Running now marks the batch failed too (see
# Test 23), so ScriptFailed is $true here even though Register/Start both
# "succeeded" in the sense of not throwing.
$Global:FakeTasks = @{ 'winexp' = @{ State = 'Running'; Def = 'OLD:winexp' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @('winexp')
$Global:StopBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('winexp')
Check 'ScriptFailed is true (round 12: an async failure marks the batch failed even though nothing literally threw)' ($r.ScriptFailed -eq $true)
Check 'winexp restore was attempted and succeeded' ('restored' -eq $r.Status['winexp']) "got=$($r.Status['winexp'])"
Check 'winexp ends Running via the restored (old, working) definition' ($Global:FakeTasks['winexp'].State -eq 'Running')
Check 'winexp is in Restored' ($r.Restored -contains 'winexp')
Check 'exit code is 1 -- stack alive, but the requested flip did not apply' ($r.ExitCode -eq 1)

Write-Host "Test 3: the restore path itself failing must surface as not-flipped, never silent success"
$script:SavedTaskXml = @{ 'flowexp' = 'SAVED-XML:flowexp:OLD:flowexp' }
$Global:RegisterBehavior = @{ 'flowexp' = @{ Restore = 'throw' } }
$restoreResult = Restore-TaskDefinition -TaskName 'flowexp'
Check 'Restore-TaskDefinition returns $false when the restore Register call throws' ($restoreResult -eq $false)
$taskStartStatus = [ordered]@{ 'flowexp' = if ($restoreResult) { 'restored' } else { $false } }
$notFlipped = @('flowexp' | Where-Object { $taskStartStatus[$_] -ne $true })
Check 'not-flipped list is non-empty when restore fails' ($notFlipped.Count -eq 1) "notFlipped=$($notFlipped -join ',')"

Write-Host "Test 4: a fresh-install task (nothing existed before) has nothing to roll back but still fails the run"
$Global:FakeTasks = @{}
$Global:RegisterBehavior = @{ 'brandnew' = @{ New = 'throw' } }
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('brandnew')
Check 'fresh-install failure sets ScriptFailed' ($r.ScriptFailed -eq $true)
Check 'nothing was stopped (nothing existed to stop, so nothing to restore)' ($r.Status.Count -eq 0) "status keys=$($r.Status.Keys -join ',')"
Check 'brandnew is in NotFlipped' ($r.NotFlipped -contains 'brandnew')
Check 'exit code is 1 (report + non-zero, nothing to roll back)' ($r.ExitCode -eq 1)

Write-Host "Test 5: happy path -- first-ever install, everything registers and starts clean"
$Global:FakeTasks = @{}
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('prometheus', 'grafana', 'winexp', 'flowexp')
Check 'ScriptFailed is false' ($r.ScriptFailed -eq $false)
Check 'nothing is NotFlipped' ($r.NotFlipped.Count -eq 0)
Check 'exit code 0' ($r.ExitCode -eq 0)
Check 'all 4 tasks confirmed started' ((@($r.Status.Values) | Where-Object { $_ -eq $true }).Count -eq 4)

Write-Host "Test 6 [pins codex-adv-r4-1 regression]: fresh install, ALL exporters fail their async start -- must exit non-zero"
# The exact regression named in the CR: empty fake-task store (nothing
# pre-existing, so StoppedTaskNames stays empty all run) + every requested
# task's NEW definition is broken (registers fine, never reaches Running).
# Before this fix, the exit-code predicate was scoped to StoppedTaskNames
# only, so this scenario reported every task NOT STARTED yet still exited 0.
# Round 12: since ScriptFailed now becomes true whenever any exporter isn't
# verifiably Running (even without an exception), and these 4 tasks are all
# FRESH, the uniform-abort FreshTaskNames removal loop now also fires for
# all of them -- they end up 'removed', not a bare $false.
$Global:FakeTasks = @{}
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @('prometheus', 'grafana', 'winexp', 'flowexp')
$Global:StopBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('prometheus', 'grafana', 'winexp', 'flowexp')
Check 'ScriptFailed is true (round 12: no exporter reached Running, even though nothing literally threw)' ($r.ScriptFailed -eq $true)
Check 'nothing was stopped (fresh install, nothing pre-existing)' ($r.Status.Values -notcontains 'restored')
Check 'all 4 fresh tasks end up removed (uniform abort now covers fresh registrations too)' (@($r.Status.Values | Where-Object { 'removed' -eq $_ }).Count -eq 4) "status=$($r.Status.Values -join ',')"
Check 'all 4 requested exporters land in NotFlipped' ($r.NotFlipped.Count -eq 4) "notFlipped=$($r.NotFlipped -join ',')"
Check 'exit code is 1 (regression: this used to be 0)' ($r.ExitCode -eq 1)

Write-Host "Test 7: Wait-TaskStopped genuinely detects a stop timeout vs a prompt stop"
$Global:FakeTasks = @{ 'stuck' = @{ State = 'Running'; Def = 'OLD:stuck' } }
$stoppedOk = Wait-TaskStopped -TaskName 'stuck' -TimeoutSeconds 1
Check 'Wait-TaskStopped returns false on genuine timeout' ($stoppedOk -eq $false)
$Global:FakeTasks['stuck'].State = 'Ready'
$stoppedOk2 = Wait-TaskStopped -TaskName 'stuck' -TimeoutSeconds 5
Check 'Wait-TaskStopped returns true promptly once state leaves Running' ($stoppedOk2 -eq $true)

Write-Host "Test 8 [pins codex-r6-1 + codex-adv-r12-2]: a stop TIMEOUT never touches the DEFINITION, but round 12's ambiguous-stop repair now confirms + reports its real state"
# grafana: Running, StopBehavior 'timeout' (Stop-ScheduledTask 'succeeds' --
# no throw -- but state never actually leaves Running, so Wait-TaskStopped's
# real 30s-default poll will time out). Register-LogonTask must throw BEFORE
# adding grafana to StoppedTaskNames (round-6 bug: it used to add it first,
# then throw) and BEFORE ever reaching Register-ScheduledTask for the new
# def, so grafana lands in neither StoppedTaskNames nor ReplacedTaskNames --
# finally's rollback loop must never call Restore-TaskDefinition on it: the
# DEFINITION stays exactly what it was before this run touched anything.
# Round 12: Stop-ScheduledTask itself didn't throw here (only the
# CONFIRMATION timed out), so grafana IS in StopAttemptedTaskNames --
# Repair-AmbiguousStop now runs for it, re-queries, finds it genuinely still
# Running (this mock's 'timeout' behavior never actually flips state), and
# reports 'recovered' -- confirmed + honestly reported rather than left in
# total silence (accepts the real ~30s wait -- Register-LogonTask hardcodes
# Wait-TaskStopped's default timeout).
$Global:FakeTasks = @{ 'grafana' = @{ State = 'Running'; Def = 'OLD:grafana' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{ 'grafana' = 'timeout' }
$Global:LookupBehavior = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-InstallSequence -TaskOrder @('grafana')
$sw.Stop()
Write-Host "  (took $([Math]::Round($sw.Elapsed.TotalSeconds,1))s -- Register-LogonTask's hardcoded 30s Wait-TaskStopped deadline)"
Check 'ScriptFailed true (stop-timeout throws inside Register-LogonTask)' ($r.ScriptFailed -eq $true)
Check 'grafana definition was never replaced (still the OLD one, untouched)' ($Global:FakeTasks['grafana'].Def -eq 'OLD:grafana') "got=$($Global:FakeTasks['grafana'].Def)"
Check "grafana is reported 'recovered' -- round 12's ambiguous-stop repair confirms it, rather than leaving it in silence" ('recovered' -eq $r.Status['grafana']) "got=$($r.Status['grafana'])"
Check 'grafana state is whatever the mock left it at (still Running -- Stop never actually flips state on timeout)' ($Global:FakeTasks['grafana'].State -eq 'Running')

Write-Host "Test 9 [pins codex-r6-1, glm-r6-4]: a stop FAILURE (throw) also leaves the task untouched by finally"
$Global:FakeTasks = @{ 'prometheus' = @{ State = 'Running'; Def = 'OLD:prometheus' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{ 'prometheus' = 'throw' }
$r = Invoke-InstallSequence -TaskOrder @('prometheus')
Check 'ScriptFailed true (Stop-ScheduledTask itself throws)' ($r.ScriptFailed -eq $true)
Check 'prometheus definition was never replaced' ($Global:FakeTasks['prometheus'].Def -eq 'OLD:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check 'prometheus was never touched by the rollback loop at all' ($r.Status.Contains('prometheus') -eq $false) "status=$($r.Status.Keys -join ',')"
Check 'prometheus is still Running (the mock never actually stopped it on a throw)' ($Global:FakeTasks['prometheus'].State -eq 'Running')

Write-Host "Test 10 [pins codex-r6-2 / glm-r6-3]: a pre-existing NON-running task's definition is restored but NOT started"
# winexp: pre-existing, Ready (not Running) -- e.g. a prior install's task
# that never got started, or the operator stopped it deliberately. This run
# re-registers it (succeeds -- ReplacedTaskNames, but never StoppedTaskNames,
# since there was nothing to stop) and its NEW definition is broken (never
# reaches Running). Before this fix, restore-eligibility was keyed on
# StoppedTaskNames only, so this task's saved XML sat unused and its OLD,
# valid definition stayed overwritten. It must now be restored -- but NOT
# started, since it wasn't running before and starting it would hand the
# operator state they didn't have -- and it must still count toward a
# non-zero exit, because the requested flip did not apply.
$Global:FakeTasks = @{ 'winexp' = @{ State = 'Ready'; Def = 'OLD:winexp' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @('winexp')
$Global:StopBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('winexp')
Check 'ScriptFailed is true (round 12: winexp never reached Running, even though nothing literally threw)' ($r.ScriptFailed -eq $true)
Check 'winexp status is restored' ('restored' -eq $r.Status['winexp']) "got=$($r.Status['winexp'])"
Check 'winexp definition was restored to the SAVED (old) one' ($Global:FakeTasks['winexp'].Def -eq 'SAVED-XML:winexp:OLD:winexp') "got=$($Global:FakeTasks['winexp'].Def)"
Check 'winexp was NOT started -- still Ready, not Running (it was not running before)' ($Global:FakeTasks['winexp'].State -eq 'Ready') "got state=$($Global:FakeTasks['winexp'].State)"
Check 'winexp still trips a non-zero exit -- the requested flip did not apply' ($r.ExitCode -eq 1)

Write-Host "Test 11 [pins codex-adv-r6-1]: a FAILED lookup during initial discovery aborts that task's migration, untouched"
$Global:FakeTasks = @{ 'prometheus' = @{ State = 'Running'; Def = 'OLD:prometheus' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{ 'prometheus' = 'fail' }
$r = Invoke-InstallSequence -TaskOrder @('prometheus')
Check 'ScriptFailed true (the failed lookup propagates, not swallowed as "does not exist")' ($r.ScriptFailed -eq $true)
Check 'prometheus definition is untouched' ($Global:FakeTasks['prometheus'].Def -eq 'OLD:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check 'prometheus was never backed up (the failure aborted before Export-ScheduledTask)' (-not $script:SavedTaskXml.ContainsKey('prometheus'))
Check 'prometheus was never touched at all (absent from status)' ($r.Status.Contains('prometheus') -eq $false) "status=$($r.Status.Keys -join ',')"
$Global:LookupBehavior = @{}

Write-Host "Test 12 [pins codex-adv-r6-1]: TRANSIENT lookup failures during the post-stop poll are not read as 'confirmed stopped'"
# 1 clean read (the initial discovery), then 2 transient failures (simulating
# the first two post-stop poll attempts hitting an RPC hiccup), then normal.
# Wait-TaskStopped must survive the transient failures -- NOT treat them as
# "confirmed stopped" -- and correctly confirm once the lookup starts
# succeeding again and shows the real (already-stopped) state.
$Global:FakeTasks = @{ 'grafana' = @{ State = 'Running'; Def = 'OLD:grafana' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{ 'grafana' = @{ SucceedCount = 1; FailCount = 2 } }
$r = Invoke-InstallSequence -TaskOrder @('grafana')
Check 'no exception -- the poll survives the transient failures and eventually confirms stopped' ($r.ScriptFailed -eq $false)
Check 'grafana ends up fully registered and started (the transient failure did not skip or misreport anything)' ($r.Status['grafana'] -eq $true) "got=$($r.Status['grafana'])"
Check 'exit code 0' ($r.ExitCode -eq 0)
$Global:LookupBehavior = @{}

Write-Host "Test 13 [pins codex-adv-r6-2]: Wait-TaskStarted's own stability recheck catches a task dying immediately after entering Running"
# Fresh install; the new definition registers fine and Start-ScheduledTask
# reports Running on the very first read, but DiesAfterReadsConfig makes it
# flip to Ready by the stability recheck's read -- must NOT be confirmed
# started. Round 12: since flowexp is FRESH and ScriptFailed now becomes
# true whenever any exporter isn't verifiably Running, the uniform-abort
# FreshTaskNames removal loop now also fires for it -- it ends up 'removed',
# not a bare $false.
$Global:FakeTasks = @{}
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$Global:DiesAfterReadsConfig = @{ 'flowexp' = 1 }
$r = Invoke-InstallSequence -TaskOrder @('flowexp')
Check 'ScriptFailed is true (round 12: flowexp never confirmed started)' ($r.ScriptFailed -eq $true)
Check "flowexp ends up removed (fresh, uniform abort rolls it back too)" ('removed' -eq $r.Status['flowexp']) "got=$($r.Status['flowexp'])"
Check 'exit code is 1' ($r.ExitCode -eq 1)
# Reset BOTH -- Remaining is internal state (re)armed per-task by Start-
# ScheduledTask, independent of Config; leaving a stale Remaining entry for
# 'flowexp' here silently mutated its State on a later, unrelated test's
# very first Get-ScheduledTask read (found while adding Test 18 below).
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining = @{}

Write-Host "Test 14 [pins codex-adv-r6-2 regression]: a task that transitions Running->Ready before the FINAL sweep triggers restore + non-zero"
# winexp: pre-existing, Running. Survives Wait-TaskStarted's own stability
# recheck (2 reads Running), so the main loop marks it $true -- exactly the
# scenario that used to slip through before the final revalidation sweep
# existed. It then dies (flips to Ready) by the time the sweep re-checks it.
# The sweep must catch this, downgrade it, and the finally block must
# attempt a real restore -- which (since Start-ScheduledTask re-arms the
# same alive-for-2-reads budget for the restored definition too) succeeds,
# demonstrating the CR's named regression end to end: restore is triggered,
# and the exit is still non-zero because the REQUESTED (new) definition
# never verifiably landed.
$Global:FakeTasks = @{ 'winexp' = @{ State = 'Running'; Def = 'OLD:winexp' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$Global:DiesAfterReadsConfig = @{ 'winexp' = 2 }
$r = Invoke-InstallSequence -TaskOrder @('winexp')
Check 'ScriptFailed is true (round 12: winexp never confirmed started)' ($r.ScriptFailed -eq $true)
Check 'winexp ends up restored -- the final sweep caught the death and triggered rollback' ('restored' -eq $r.Status['winexp']) "got=$($r.Status['winexp'])"
Check 'winexp is actually Running again (the restore succeeded)' ($Global:FakeTasks['winexp'].State -eq 'Running')
Check 'exit code is 1 -- the requested (new) definition never verifiably landed' ($r.ExitCode -eq 1)
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining = @{}

Write-Host "Test 15 [pins codex-adv-r8-1]: Restore-TaskDefinition stops a LIVE replacement before swapping the definition underneath it"
# Simulates the exact scenario the finding describes: SavedTaskXml holds the
# task's OLD definition, but the CURRENT live task is actually Running (a
# replacement instance genuinely up -- e.g. a transient lookup failure
# elsewhere wrongly marked it failed while the new-mode process is genuinely
# alive). Restore-TaskDefinition must detect this, stop it, confirm the
# stop, and ONLY THEN swap the definition -- the same "-Force doesn't touch
# a running process" trap this whole script exists to avoid, now applied to
# the restore path itself. Checked via CallLog ORDER, not just final state:
# the mock's Register-ScheduledTask now realistically PRESERVES State across
# -Force (matching production), so final state alone would look identical
# whether or not the stop actually ran first -- only the call order proves it.
$Global:FakeTasks = @{ 'prometheus' = @{ State = 'Running'; Def = 'NEW-DEF:prometheus' } }
$script:SavedTaskXml = @{ 'prometheus' = 'SAVED-XML:prometheus:OLD:prometheus' }
$Global:RegisterBehavior = @{}
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:CallLog.Clear()
$restoreResult = Restore-TaskDefinition -TaskName 'prometheus' -StartAfterRestore
Check 'Restore-TaskDefinition returns true' ($restoreResult -eq $true)
Check 'the definition IS the saved (old) one afterward' ($Global:FakeTasks['prometheus'].Def -eq 'SAVED-XML:prometheus:OLD:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check 'prometheus ends up Running again (restarted under the restored definition)' ($Global:FakeTasks['prometheus'].State -eq 'Running')
$stopIndex = $Global:CallLog.IndexOf('Stop:prometheus')
$registerRestoreIndex = $Global:CallLog.IndexOf('Register-Restore:prometheus')
Check 'the live instance was stopped (Stop:prometheus is in the call log)' ($stopIndex -ge 0) "log=$($Global:CallLog -join ',')"
Check 'the stop happened BEFORE the definition was swapped' ($stopIndex -ge 0 -and $stopIndex -lt $registerRestoreIndex) "stopIdx=$stopIndex registerIdx=$registerRestoreIndex log=$($Global:CallLog -join ',')"

Write-Host "Test 16 [pins codex-adv-r8-2 regression]: task 1 starts fine, task 2 throws synchronously during start -- task 1 must ALSO end restored"
# prometheus and grafana both pre-existing and Running. prometheus's full
# stop+register+start sequence succeeds cleanly (taskStartStatus = $true)
# BEFORE grafana's Start-ScheduledTask throws synchronously, aborting the
# batch. Before this fix, finally skipped prometheus (already $true),
# leaving it on the NEW/requested definition while grafana rolled back to
# its old one -- a mixed Interactive/S4U stack after one partial failure.
# The regression this test pins is specifically about PROMETHEUS (task 1):
# grafana's own StartBehavior='throw' is unconditional in this mock (it
# blocks every Start-ScheduledTask call for that name, not just the one
# that triggered the abort), so its OWN restore attempt genuinely cannot
# succeed either and correctly ends up $false, not 'restored' -- that's a
# realistic outcome (a persistent, not definition-specific, start failure),
# not a gap in the fix.
$Global:FakeTasks = @{
  'prometheus' = @{ State = 'Running'; Def = 'OLD:prometheus' }
  'grafana'    = @{ State = 'Running'; Def = 'OLD:grafana' }
}
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{}
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining = @{}
$Global:StartBehavior = @{ 'grafana' = 'throw' }
$r = Invoke-InstallSequence -TaskOrder @('prometheus', 'grafana')
Check 'ScriptFailed true (grafana Start-ScheduledTask threw synchronously)' ($r.ScriptFailed -eq $true)
Check 'prometheus ends up restored too -- even though its OWN start already succeeded' ('restored' -eq $r.Status['prometheus']) "got=$($r.Status['prometheus'])"
Check 'prometheus definition is back to the SAVED (old) one, not the requested new one' ($Global:FakeTasks['prometheus'].Def -eq 'SAVED-XML:prometheus:OLD:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check 'prometheus is Running again under the restored definition (uniform batch rollback, not left mixed)' ($Global:FakeTasks['prometheus'].State -eq 'Running')
Check 'grafana was also attempted (its own restore genuinely cannot start either, given its unconditional mock failure)' ($r.Status['grafana'] -eq $false) "got=$($r.Status['grafana'])"
Check 'exit code is 1' ($r.ExitCode -eq 1)
$Global:StartBehavior = @{}

Write-Host "Test 17 [pins codex-adv-r10-1 regression]: fresh task registers successfully, a later task's registration throws -- the fresh task must be unregistered, not left behind"
# The exact regression named in the CR: prometheus (task 1) does not exist
# before this run -- registers fine (FreshTaskNames, not ReplacedTaskNames --
# no saved XML exists for it). grafana (task 2)'s own registration then
# throws, aborting the batch during the REGISTRATION phase, before the
# start loop is ever reached for either task. Before this fix, prometheus
# had no rollback path at all (only pre-existing tasks were tracked) and
# would simply survive registered.
$Global:FakeTasks = @{}
$Global:RegisterBehavior = @{ 'grafana' = @{ New = 'throw' } }
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{}
$Global:StartBehavior = @{}
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining = @{}
$Global:UnregisterBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('prometheus', 'grafana')
Check 'ScriptFailed true (grafana registration threw)' ($r.ScriptFailed -eq $true)
Check 'prometheus (fresh, registered fine) ends up removed -- not left registered' ('removed' -eq $r.Status['prometheus']) "got=$($r.Status['prometheus'])"
Check 'prometheus no longer exists in the fake task store at all' (-not $Global:FakeTasks.ContainsKey('prometheus'))
Check 'grafana never existed either (its own registration failed before creating anything)' (-not $Global:FakeTasks.ContainsKey('grafana'))
Check 'exit code is 1' ($r.ExitCode -eq 1)

Write-Host "Test 18 [pins codex-adv-r10-1]: Remove-FreshTaskRegistration stops a LIVE task before unregistering it"
# Same stop-first discipline as Restore-TaskDefinition (Test 15) -- must
# never unregister a task that is still genuinely running.
$Global:FakeTasks = @{ 'flowexp' = @{ State = 'Running'; Def = 'NEW-DEF:flowexp' } }
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{}
$Global:UnregisterBehavior = @{}
# 'flowexp' was used with DiesAfterReadsConfig back in Test 13 -- explicitly
# clear its leftover Remaining counter (belt-and-suspenders on top of the
# fix at Test 13's own cleanup) so this direct call isn't silently affected.
$Global:DiesAfterReadsRemaining.Remove('flowexp')
$Global:CallLog.Clear()
$removeResult = Remove-FreshTaskRegistration -TaskName 'flowexp'
Check 'Remove-FreshTaskRegistration returns true' ($removeResult -eq $true)
Check 'flowexp is gone from the fake task store' (-not $Global:FakeTasks.ContainsKey('flowexp'))
$stopIdx = $Global:CallLog.IndexOf('Stop:flowexp')
$unregisterIdx = $Global:CallLog.IndexOf('Unregister:flowexp')
Check 'the task was stopped first (Stop:flowexp is in the call log)' ($stopIdx -ge 0) "log=$($Global:CallLog -join ',')"
Check 'the stop happened BEFORE the unregister' ($stopIdx -ge 0 -and $stopIdx -lt $unregisterIdx) "stopIdx=$stopIdx unregisterIdx=$unregisterIdx log=$($Global:CallLog -join ',')"

Write-Host "Test 19 [pins codex-adv-r10-1]: a failed unregister must surface honestly, never silent success"
$Global:FakeTasks = @{ 'winexp' = @{ State = 'Ready'; Def = 'NEW-DEF:winexp' } }
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{}
$Global:UnregisterBehavior = @{ 'winexp' = 'throw' }
$Global:DiesAfterReadsRemaining.Remove('winexp')  # same belt-and-suspenders as Test 18 -- 'winexp' was used in Test 14
$removeResult2 = Remove-FreshTaskRegistration -TaskName 'winexp'
Check 'Remove-FreshTaskRegistration returns false when Unregister-ScheduledTask throws' ($removeResult2 -eq $false)
Check 'winexp is still present -- removal genuinely failed, not silently dropped from tracking' ($Global:FakeTasks.ContainsKey('winexp'))
$Global:UnregisterBehavior = @{}

Write-Host "Test 20 [pins codex-adv-r12-2]: Repair-AmbiguousStop restarts a task whose stop genuinely succeeded, once a fresh lookup can confirm it"
# grafana is already Ready (genuinely stopped) with its definition
# untouched (matches Register-LogonTask's guarantee: it threw BEFORE ever
# reaching Register-ScheduledTask for this task) -- lookups now succeed
# fine ("the scheduler recovers"). Repair-AmbiguousStop's whole job is to
# restart it under that same, never-replaced definition.
$Global:FakeTasks = @{ 'grafana' = @{ State = 'Ready'; Def = 'OLD:grafana' } }
$Global:LookupBehavior = @{}
$Global:StartBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining.Remove('grafana')
$repairResult = Repair-AmbiguousStop -TaskName 'grafana'
Check "Repair-AmbiguousStop returns 'recovered'" ('recovered' -eq $repairResult) "got=$repairResult"
Check 'grafana is Running again' ($Global:FakeTasks['grafana'].State -eq 'Running')
Check 'grafana definition is STILL the original -- untouched, nothing was ever replaced' ($Global:FakeTasks['grafana'].Def -eq 'OLD:grafana') "got=$($Global:FakeTasks['grafana'].Def)"

Write-Host "Test 21 [pins codex-adv-r12-2]: Repair-AmbiguousStop reports INDETERMINATE, never silent success, when the retry lookup ALSO fails"
$Global:FakeTasks = @{ 'winexp' = @{ State = 'Ready'; Def = 'OLD:winexp' } }
$Global:LookupBehavior = @{ 'winexp' = 'fail' }
$repairResult2 = Repair-AmbiguousStop -TaskName 'winexp'
Check "Repair-AmbiguousStop returns 'indeterminate'" ('indeterminate' -eq $repairResult2) "got=$repairResult2"
$Global:LookupBehavior = @{}

Write-Host "Test 22 [pins codex-adv-r12-2 regression]: an unconfirmed stop (Wait-TaskStopped times out on lookup failures, not a stuck task) is tracked and repaired end to end, not silently stranded"
# Honest note on scope: reaching this scenario end-to-end through
# Register-LogonTask means Wait-TaskStopped's real, hardcoded 30s poll must
# actually time out -- reliably forcing LookupBehavior to resolve to
# "succeeds" at the EXACT moment Repair-AmbiguousStop's own retry runs
# (rather than a moment earlier or later) is a real-time race this suite
# cannot pin deterministically without excessive fragility across machines.
# What IS deterministic and IS pinned here: the tracking and wiring --
# StopAttemptedTaskNames populates, Repair-AmbiguousStop actually gets
# invoked from finally, and the task ends up HONESTLY reported instead of
# silently absent from every set (the original round-12 bug). The
# 'recovered' outcome itself (the "scheduler recovers" half of the CR's
# regression) is deterministically pinned separately by Test 20, using the
# same Repair-AmbiguousStop function this end-to-end path also calls into.
$Global:FakeTasks = @{ 'prometheus' = @{ State = 'Running'; Def = 'OLD:prometheus' } }
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
# SucceedCount 1 lets the INITIAL discovery read through cleanly (otherwise
# Register-LogonTask throws right there, at the top, before ever reaching
# Stop-ScheduledTask -- that's Test 11's scenario, not this one). FailCount
# is comfortably larger than the ~60 poll attempts a 30s/500ms-interval
# window can make, so Wait-TaskStopped is guaranteed to time out rather
# than accidentally succeed mid-poll.
$Global:LookupBehavior = @{ 'prometheus' = @{ SucceedCount = 1; FailCount = 1000 } }
$Global:StartBehavior = @{}
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-InstallSequence -TaskOrder @('prometheus')
$sw2.Stop()
Write-Host "  (took $([Math]::Round($sw2.Elapsed.TotalSeconds,1))s -- Register-LogonTask's hardcoded 30s Wait-TaskStopped deadline)"
Check 'ScriptFailed true (the stop-confirmation timeout throws)' ($r.ScriptFailed -eq $true)
Check 'prometheus definition was never replaced (Register-LogonTask threw before reaching it)' ($Global:FakeTasks['prometheus'].Def -eq 'OLD:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check "prometheus is honestly reported 'indeterminate' -- not silently absent from every rollback set (the round-12 bug)" ('indeterminate' -eq $r.Status['prometheus']) "got=$($r.Status['prometheus'])"
Check 'exit code is 1' ($r.ExitCode -eq 1)
$Global:LookupBehavior = @{}

Write-Host "Test 23 [pins codex-adv-r12-1 regression]: multi-task async failure -- one fails to start (no exception), successful siblings + a fresh registration must ALSO roll back"
# prometheus (pre-existing) and winexp (fresh) both fully succeed --
# registered, started, confirmed Running -- individually. grafana
# (pre-existing) registers fine but its new definition is BROKEN (async
# failure, no throw -- Start-ScheduledTask just never reaches Running).
# Before this fix, ScriptFailed stayed $false (nothing threw), so finally's
# narrower per-task check would restore ONLY grafana, leaving prometheus on
# its new/requested definition and winexp registered and running -- a mixed
# stack after a single non-throwing async failure. Round 12 forces the
# batch-uniformity rule to apply here too.
$Global:FakeTasks = @{
  'prometheus' = @{ State = 'Running'; Def = 'OLD:prometheus' }
  'grafana'    = @{ State = 'Running'; Def = 'OLD:grafana' }
}
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @('grafana')
$Global:StopBehavior = @{}
$Global:LookupBehavior = @{}
$Global:StartBehavior = @{}
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining = @{}
$Global:UnregisterBehavior = @{}
$r = Invoke-InstallSequence -TaskOrder @('prometheus', 'grafana', 'winexp')
Check 'ScriptFailed becomes true (batch-uniformity trigger: not every exporter reached Running)' ($r.ScriptFailed -eq $true)
Check 'prometheus (its own start succeeded) still rolls back uniformly -- not left on the new definition' ('restored' -eq $r.Status['prometheus']) "got=$($r.Status['prometheus'])"
Check 'prometheus definition is back to its SAVED (old) one' ($Global:FakeTasks['prometheus'].Def -eq 'SAVED-XML:prometheus:OLD:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check 'grafana (the one that actually failed to start) also ends up restored' ('restored' -eq $r.Status['grafana']) "got=$($r.Status['grafana'])"
Check 'winexp (fresh, its own start succeeded) is ALSO removed -- uniform rollback covers fresh registrations too' ('removed' -eq $r.Status['winexp']) "got=$($r.Status['winexp'])"
Check 'winexp no longer exists in the fake task store' (-not $Global:FakeTasks.ContainsKey('winexp'))
Check 'exit code is 1' ($r.ExitCode -eq 1)

Write-Host "Test 24 [pins round-15 sweep lookup-failure fix]: Confirm-TaskStillRunning reports INDETERMINATE on a failed lookup, never silently 'not Running'"
# This is the last of the three verification sites (Wait-TaskStarted,
# Wait-TaskStopped, and now the final revalidation sweep) to get the
# fail-closed Resolve-ExistingTask treatment -- unlike the other two, the
# sweep is a single one-shot check with no retry loop to fall back into, so
# a failed lookup can't just "keep polling": it must be reported honestly
# as indeterminate rather than misread as the task having gone down.
$Global:FakeTasks = @{ 'grafana' = @{ State = 'Running'; Def = 'NEW-DEF:grafana' } }
$Global:LookupBehavior = @{ 'grafana' = 'fail' }
$confirmResult = Confirm-TaskStillRunning -TaskName 'grafana'
Check "Confirm-TaskStillRunning returns 'indeterminate' when the lookup fails" ('indeterminate' -eq $confirmResult) "got=$confirmResult"
$Global:LookupBehavior = @{}

Write-Host "Test 25: Confirm-TaskStillRunning's other two outcomes -- still Running (no change needed), and genuinely gone (not Running)"
$Global:FakeTasks = @{ 'prometheus' = @{ State = 'Running'; Def = 'NEW-DEF:prometheus' } }
$Global:LookupBehavior = @{}
Check "still Running -> `$true" ((Confirm-TaskStillRunning -TaskName 'prometheus') -eq $true)
$Global:FakeTasks = @{ 'winexp' = @{ State = 'Ready'; Def = 'NEW-DEF:winexp' } }
Check "no longer Running -> `$false" ((Confirm-TaskStillRunning -TaskName 'winexp') -eq $false)
Check "genuinely gone -> `$false" ((Confirm-TaskStillRunning -TaskName 'does-not-exist') -eq $false)

Write-Host "Test 26 [pins codex-r16-1]: an 'indeterminate' sweep result must NOT drag a healthy sibling into rollback"
# prometheus fully succeeds -- registered, started, confirmed Running, and
# reconfirmed Running at the sweep. grafana ALSO fully succeeds through the
# main loop (registered, started, confirmed Running) but its OWN sweep
# lookup fails -- LookupBehavior's SucceedCount is set to cover exactly the
# reads grafana's own successful path consumes (discovery, the stop-poll's
# single confirming read, the start-check, the stability recheck -- 4
# total, deterministic call-count, not a real-time race) before FailCount
# takes over for the 5th read, which is the sweep's own Confirm-
# TaskStillRunning call. Before this fix, grafana ending 'indeterminate'
# folded into $scriptFailed via the round-12 "-ne $true" check, which then
# forced a FULL uniform rollback -- restoring prometheus too, even though
# prometheus never had anything wrong with it. The fix scopes that fold to
# confirmed $false only.
$Global:FakeTasks = @{
  'prometheus' = @{ State = 'Running'; Def = 'OLD:prometheus' }
  'grafana'    = @{ State = 'Running'; Def = 'OLD:grafana' }
}
$Global:RegisterBehavior = @{}
$Global:BrokenNewDefs = @()
$Global:StopBehavior = @{}
$Global:StartBehavior = @{}
$Global:DiesAfterReadsConfig = @{}
$Global:DiesAfterReadsRemaining = @{}
$Global:LookupBehavior = @{ 'grafana' = @{ SucceedCount = 4; FailCount = 1 } }
$r = Invoke-InstallSequence -TaskOrder @('prometheus', 'grafana')
Check 'ScriptFailed stays FALSE -- indeterminate alone must not fold into the batch-failed flag' ($r.ScriptFailed -eq $false) "got=$($r.ScriptFailed)"
Check "grafana is honestly reported 'indeterminate'" ('indeterminate' -eq $r.Status['grafana']) "got=$($r.Status['grafana'])"
Check 'prometheus was NOT touched -- still $true, never rolled back, because the grafana lookup blip did not drag it in' ($r.Status['prometheus'] -eq $true) "got=$($r.Status['prometheus'])"
Check 'prometheus definition is STILL the requested (new) one -- no unnecessary restore happened' ($Global:FakeTasks['prometheus'].Def -eq 'NEW-DEF:prometheus') "got=$($Global:FakeTasks['prometheus'].Def)"
Check 'exit code is still 1 -- indeterminate alone still counts toward non-zero, on its own' ($r.ExitCode -eq 1)
$Global:LookupBehavior = @{}

Write-Host "Test 27 [pins glm-r16-5]: Resolve-ExistingTask's ObjectNotFound catch branch is genuinely exercised, not bypassed"
# Directly exercises the exact gap named in the finding: the mock used to
# return $null cleanly for a missing task, so Resolve-ExistingTask's try
# block always succeeded and its `$_.CategoryInfo.Category -eq
# 'ObjectNotFound'` catch branch was dead code as far as this suite could
# tell. The mock now throws a real ObjectNotFound-categorized error (Test
# 27's whole point is to prove the CATCH branch, not the try branch, is
# what returns $null here).
$Global:FakeTasks = @{}
$Global:LookupBehavior = @{}
$resolved = $null
$threw = $false
try {
  $resolved = Resolve-ExistingTask -TaskName 'genuinely-missing-task'
} catch {
  $threw = $true
}
Check 'Resolve-ExistingTask does NOT propagate an exception for a genuinely missing task' ($threw -eq $false)
Check 'Resolve-ExistingTask returns $null (via its ObjectNotFound catch branch, not a bare try-block success)' ($null -eq $resolved)

Write-Host "Test 28 [pins codex-r16-2/glm-r16-4 verification + glm-r16-3 sug]: a started task's status renders as exactly 'started', with no case-fallthrough concatenation"
# glm-r16-3 raised a real question worth VERIFYING (per CLAUDE.md: verify a
# CR finding's premise before complying) -- PowerShell's `switch` on a
# value that can be $true, tested against non-empty STRING case labels
# without `break`, COULD in principle suffer `$true -eq '<string>'`
# coercion causing every case to match. Verified directly in a live
# PowerShell session (not just reasoning): switch compares as `$CaseLabel
# -eq $InputValue` (label on the left), and 'someString' -eq $true
# evaluates to $false -- the coercion direction the finding worried about
# does not apply here. Confirmed empirically: switching $true, 'restored',
# 'removed', 'recovered', 'indeterminate', and $false each against the
# EXACT production case list all produced a single-string result (Count=1,
# correct value, no concatenation) with $ErrorActionPreference = 'Stop' and
# Set-StrictMode -Version 2.0 active (this test file's own settings) in
# effect throughout. Not restructuring genuinely-correct code per CLAUDE.md
# surgical-changes -- this test mirrors the exact production switch (it is
# inline script body, not an extracted function, so it cannot be called
# directly) purely as a permanent regression guard against the coercion
# class the finding named, in case the case order or a `break` is ever
# touched later without re-verifying.
function Get-MirroredStatusLine {
  param($StatusValue)
  switch ($StatusValue) {
    $true            { 'started' }
    'restored'       { 'RESTORED to its previous definition after the new one failed to start' }
    'removed'        { 'REMOVED -- created by this run, rolled back on abort' }
    'recovered'      { 'RECOVERED on its ORIGINAL (never-replaced) definition -- an earlier stop could not be confirmed at the time' }
    'indeterminate'  { 'INDETERMINATE -- a stop was requested and its outcome could not be confirmed; check manually' }
    default          { 'NOT STARTED -- see warning above' }
  }
}
$startedLine = @(Get-MirroredStatusLine -StatusValue $true)
Check "a `$true status renders as EXACTLY ONE line: 'started'" ($startedLine.Count -eq 1 -and 'started' -eq $startedLine[0]) "count=$($startedLine.Count) value=[$($startedLine -join '|')]"
$restoredLine = @(Get-MirroredStatusLine -StatusValue 'restored')
Check "a 'restored' status renders as exactly one line, not concatenated with 'started'" ($restoredLine.Count -eq 1 -and $restoredLine[0] -notlike '*started*') "count=$($restoredLine.Count) value=[$($restoredLine -join '|')]"

Write-Host "Test 29 [pins codex-adv-r18-1]: a helper that Write-Step-logs before returning `$false` must not have its return value swallowed into a truthy array by the SUCCESS stream"
# Uses the RAW dot-sourced production Write-Step, NOT this test file's own
# Write-Host override (defined right after the top-level dot-source, above)
# -- a fresh, isolated re-extraction+dot-source, mirroring the top's own
# extraction technique, so this test genuinely exercises whatever install-
# stack.ps1 CURRENTLY defines Write-Step as. Every OTHER test in this file is
# shielded by the override and would never catch a regression here; if
# Write-Step ever reverts to Write-Output, THIS test starts failing -- the
# regression pin the finding explicitly asked for.
$targetLines29 = Get-Content -LiteralPath $Target
$bodyStart29 = ($targetLines29 | Select-String -Pattern '^\$scriptDir = Split-Path' -List).LineNumber
$functionLines29 = $targetLines29[0..($bodyStart29 - 2)]
$tempFunctionsFile29 = [System.IO.Path]::GetTempFileName() + '.ps1'
Set-Content -LiteralPath $tempFunctionsFile29 -Value $functionLines29 -Encoding utf8
try {
  . $tempFunctionsFile29 -RepoRoot 'C:\fixture-repo-root-unused'
} finally {
  Remove-Item -LiteralPath $tempFunctionsFile29 -Force -ErrorAction SilentlyContinue
}
try {
  # Scenario: 'r18task' has a saved (old) definition AND a currently-live
  # replacement instance that's Running -- Restore-TaskDefinition's own
  # "stop the live replacement first" branch fires, which calls Write-Step
  # (the exact "helper that logs" the finding names), and the restore's own
  # Register-ScheduledTask call then throws -- so the function returns
  # $false AFTER having already emitted pipeline output via Write-Step.
  $script:SavedTaskXml = @{ 'r18task' = 'SAVED-XML:r18task:OLD:r18task' }
  $Global:FakeTasks = @{ 'r18task' = @{ State = 'Running'; Def = 'NEW-DEF:r18task' } }
  $Global:StopBehavior = @{ 'r18task' = 'succeed' }
  $Global:RegisterBehavior = @{ 'r18task' = @{ Restore = 'throw' } }
  $Global:LookupBehavior = @{}
  $Global:CallLog.Clear()
  $restoreResult29 = Restore-TaskDefinition -TaskName 'r18task' -StartAfterRestore:$true
  Check 'Write-Step genuinely fired along this path (Stop:r18task in the call log -- the live-replacement branch ran)' ($Global:CallLog.Contains('Stop:r18task'))
  # -is [bool] first, short-circuited with -and, so a regression (an
  # Object[] instead of a scalar bool) fails this Check CLEANLY instead of
  # crashing the whole suite on a parameter-binding error when the array
  # gets compared with -eq further down (verified live: it does crash without
  # this guard).
  Check 'Restore-TaskDefinition still returns the scalar boolean $false, not an array (the bug: a non-empty array is always truthy)' ($restoreResult29 -is [bool]) "type=$($restoreResult29.GetType().Name) value=[$($restoreResult29 -join '|')]"
  Check 'Restore-TaskDefinition returns exactly $false' ($restoreResult29 -is [bool] -and $restoreResult29 -eq $false) "got=$restoreResult29"
  # Regression: the exact finalizer pattern the finally block uses.
  $taskStartStatus29 = if ($restoreResult29) { 'restored' } else { $false }
  Check "the finalizer classifies this as FAILED (`$false), never 'restored' on a failed operation" ($taskStartStatus29 -eq $false) "got=$taskStartStatus29"
} finally {
  # Restore this test file's own Write-Host override for every subsequent
  # test -- this test is the one deliberate exception.
  function Write-Step {
    param([string]$Message)
    Write-Host "[observability] $Message"
  }
}
$Global:StopBehavior = @{}
$Global:RegisterBehavior = @{}

Write-Host "Test 30 [pins codex-adv-r18-2]: an unelevated run must refuse to touch an EXISTING S4U task, regardless of which direction -Hidden points THIS run"
# codex-adv-r18-2's own scenario: a reverse flip (or any run) touching a task
# already registered S4U needs elevation just like registering one with
# -Hidden does. Confirm-NoUnelevatedS4UMutation takes -IsAdmin as an explicit
# parameter precisely so this is testable without an actually-elevated test
# process.
$Global:FakeTasks = @{ 'hiddentask' = @{ State = 'Running'; Def = 'OLD:hiddentask'; LogonType = 'S4U' } }
$threw30a = $false
try { Confirm-NoUnelevatedS4UMutation -TaskNames @('hiddentask') -IsAdmin $false } catch { $threw30a = $true }
Check 'unelevated + existing S4U task -> throws' ($threw30a -eq $true)

$threw30b = $false
try { Confirm-NoUnelevatedS4UMutation -TaskNames @('hiddentask') -IsAdmin $true } catch { $threw30b = $true }
Check 'elevated + existing S4U task -> does NOT throw' ($threw30b -eq $false)

$Global:FakeTasks = @{ 'windowedtask' = @{ State = 'Running'; Def = 'OLD:windowedtask'; LogonType = 'InteractiveToken' } }
$threw30c = $false
try { Confirm-NoUnelevatedS4UMutation -TaskNames @('windowedtask') -IsAdmin $false } catch { $threw30c = $true }
Check 'unelevated + existing non-S4U (Interactive) task -> does NOT throw (the top -Hidden-only check already covers the forward-only case)' ($threw30c -eq $false)

$Global:FakeTasks = @{}
$threw30d = $false
try { Confirm-NoUnelevatedS4UMutation -TaskNames @('brandnewtask') -IsAdmin $false } catch { $threw30d = $true }
Check 'unelevated + task does not exist yet (fresh install) -> does NOT throw (nothing to protect)' ($threw30d -eq $false)

Write-Host "Test 31 [pins codex-adv-r18-3]: the final sweep's Running check also verifies the registered PRINCIPAL matches what THIS run requested"
# Happy path: task genuinely Running under the SAME principal this run
# requested (S4U, since ExpectedHidden is $true) -- must still confirm $true.
$Global:FakeTasks = @{ 'hiddentask2' = @{ State = 'Running'; Def = 'NEW-DEF:hiddentask2'; LogonType = 'S4U' } }
Check "Running + principal MATCHES what this run requested (S4U) -> `$true" ((Confirm-TaskStillRunning -TaskName 'hiddentask2' -ExpectedHidden:$true) -eq $true)

Write-Host "Test 32 [pins codex-adv-r18-3]: a task Running under the OTHER run's principal must NOT be trusted as this run's own success (closes the cross-confirm read)"
# codex-adv-r18-3's own scenario: a concurrent opposite-mode run flipped this
# task to Interactive while THIS run believed it had it Running under S4U
# (requested -Hidden). Running alone used to be enough to confirm success --
# now the principal must match too, or it's reported as NOT started, not
# silently cross-confirmed as this run's own healthy task.
$Global:FakeTasks = @{ 'crosstask' = @{ State = 'Running'; Def = 'NEW-DEF:crosstask'; LogonType = 'InteractiveToken' } }
Check "Running but principal does NOT match (this run requested S4U, task shows Interactive) -> `$false, not cross-confirmed" ((Confirm-TaskStillRunning -TaskName 'crosstask' -ExpectedHidden:$true) -eq $false)
$Global:FakeTasks = @{ 'crosstask2' = @{ State = 'Running'; Def = 'NEW-DEF:crosstask2'; LogonType = 'S4U' } }
Check "reverse direction: this run requested Interactive (ExpectedHidden `$false) but task shows S4U -> `$false too" ((Confirm-TaskStillRunning -TaskName 'crosstask2' -ExpectedHidden:$false) -eq $false)

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
