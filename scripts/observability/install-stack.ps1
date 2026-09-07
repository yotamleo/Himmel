param(
  [string]$RepoRoot,
  # -Hidden registers the long-running exporter tasks with an S4U principal so
  # they run in session 0 with no visible console window (the default Interactive
  # logon tasks pop a cmd window per exporter). REQUIRES an elevated shell — an
  # S4U principal change is Access Denied unelevated. Omit for the default
  # unelevated, windowed install. Re-registration is symmetric: re-running this
  # script WITHOUT -Hidden against tasks previously registered WITH -Hidden
  # flips them back to Interactive (and vice versa) and takes effect
  # immediately, because Register-LogonTask stops any running instance of
  # each task and waits for it to exit before swapping the definition --
  # Register-ScheduledTask -Force alone only replaces the definition, it does
  # not touch an already-running process. (Interim to the cross-platform
  # supervisor, HIMMEL-1425.)
  [switch]$Hidden
)

$ErrorActionPreference = 'Stop'
# Progress rendering makes Invoke-WebRequest downloads crawl in remote/task
# contexts (no console to render into); silence it for the whole install.
$ProgressPreference = 'SilentlyContinue'

# S4U principal registration needs elevation; fail early with a clear message
# rather than the opaque Access Denied Register-ScheduledTask throws mid-run.
# codex-adv-r18-2: computed unconditionally (not just under -Hidden) -- the
# reverse-flip pre-flight below (Confirm-NoUnelevatedS4UMutation, called once
# $exporterTaskNames is known) needs it too, regardless of whether THIS run
# itself requested -Hidden.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Hidden -and -not $isAdmin) {
  throw "-Hidden registers S4U (session-0, no-window) scheduled tasks, which requires an elevated shell. Re-run from an Administrator PowerShell, or omit -Hidden for the default windowed install."
}

# codex-adv-r18-1: Write-Output writes to the SUCCESS stream. Restore-
# TaskDefinition, Remove-FreshTaskRegistration, and Repair-AmbiguousStop (the
# three value-returning helpers the finally block's finalizer captures into a
# variable, e.g. `$restored = Restore-TaskDefinition ...`) all call this
# function to log their own progress *before* their final `return`. PowerShell
# bundles every uncaptured pipeline object emitted inside a function -- Write-
# Output text included -- together with its `return` value into ONE array. A
# non-empty array is always truthy in `if ($restored) {...}`, even when the
# array's last (real) element is the literal $false the helper actually
# returned -- silently recording a FAILED restore/removal/repair as if it had
# succeeded. Write-Host renders to the console the same as Write-Output does
# at a script's top level, but it never enters the success/pipeline stream,
# so it cannot pollute a caller's captured return value this way -- audited:
# these three are the only helpers the finally block (or the try block's own
# revalidation sweep) captures a return value from that also call Write-Step
# internally; Confirm-TaskStillRunning, also captured, uses Write-Warning only.
function Write-Step {
  param([string]$Message)
  Write-Host "[observability] $Message"
}

function Invoke-PackageInstall {
  param(
    [string]$Name,
    [string[]]$WingetIds,
    [string]$ScoopName
  )

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    foreach ($wingetId in $WingetIds) {
      Write-Step "Installing $Name with winget id $wingetId"
      winget install --id $wingetId -e --silent --accept-source-agreements --accept-package-agreements
      if ($LASTEXITCODE -eq 0) { return }
    }
    Write-Warning "winget install failed for $Name; trying scoop when available"
  }

  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    # prometheus / grafana / windows_exporter live in the extras bucket;
    # adding it is idempotent-ish (fails benignly when already registered).
    Write-Step "Ensuring scoop extras bucket"
    scoop bucket add extras 2>$null | Out-Null
    Write-Step "Installing $Name with scoop package $ScoopName"
    scoop install $ScoopName
    if ($LASTEXITCODE -eq 0) { return }
  }

  Write-Warning "Could not install $Name automatically. Install it manually, then re-run this script."
}

function Resolve-RequiredCommand {
  param(
    [string]$DisplayName,
    [string[]]$Names
  )

  foreach ($name in $Names) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  throw "Required command for $DisplayName was not found on PATH after install attempt: $($Names -join ', ')"
}

# Register-ScheduledTask -Force replaces only the task DEFINITION -- Windows
# does not touch an already-running instance of it. These exporters run
# indefinitely, so re-registering in place (e.g. flipping -Hidden on or off)
# would otherwise leave the OLD-mode process alive: an Interactive window
# survives a flip to -Hidden, a session-0 S4U process survives a flip back,
# and the replacement Start-ScheduledTask (below, at the end of the script)
# can be a no-op under the default IgnoreNew MultipleInstances policy while
# the old instance still holds the task's "running" state, or the new
# instance can fail to bind the same port. Stop-ScheduledTask returns as soon
# as the stop is requested, not once the process has actually exited, so poll
# task state until it leaves Running (or timeout) before the caller swaps the
# definition. Fail-closed: Register-LogonTask below does NOT swallow a stop
# failure or a stop timeout -- it aborts before touching the definition
# rather than proceeding into the exact ambiguous state (old instance maybe
# still alive, holding the window/session/port) this whole mechanism exists
# to prevent.
#
# By the time anything downstream of a successful Register-ScheduledTask
# -Force notices trouble, the PREVIOUS definition is already gone -- -Force
# overwrites unconditionally. "Restart what we stopped" is therefore not
# enough: it would restart the NEW, possibly-broken definition, not the
# working one it replaced. Register-LogonTask exports each existing task's
# definition (Export-ScheduledTask XML) into $script:SavedTaskXml BEFORE
# touching it. Restore-eligibility is the UNION of two sets, both populated
# by Register-LogonTask:
#   - $script:StoppedTaskNames -- was Running before, and the stop was
#     CONFIRMED (added only AFTER Wait-TaskStopped succeeds, never before --
#     a stop failure/timeout throws first, leaving the task's definition
#     untouched and out of every rollback set; there is nothing to restore
#     or (re)start for a task this run never actually touched).
#   - $script:ReplacedTaskNames -- this run's Register-ScheduledTask call for
#     the NEW definition actually succeeded (regardless of prior running
#     state). A pre-existing task that was NOT running still has its live
#     definition overwritten by that call, so it is still rollback-eligible
#     even though it was never in StoppedTaskNames -- keying eligibility on
#     "was running" alone (the round-6 bug) let such a task's saved XML sit
#     unused while its definition stayed overwritten.
# The try/catch/finally around the registration + start section near the
# bottom of this script uses Restore-TaskDefinition (below) to put the SAVED
# definition back for anything in that union not verifiably in its intended
# end state by the time the run finishes -- for a task that WAS running
# before (StoppedTaskNames), that also means starting it and confirming
# Running; for one that was not (ReplacedTaskNames only), the definition is
# restored but NOT started -- it wasn't running before, so starting it now
# would hand the operator state they didn't have. Either way it still counts
# toward a non-zero exit: the requested flip did not apply. The script also
# exits non-zero if the recovery itself fails. A task that did not exist
# before this run has no saved definition and needs none: a failed fresh
# registration just reports and exits non-zero, nothing to roll back.
#
# One more edge (round 12): "nothing to restore for a task this run never
# actually touched" (StoppedTaskNames' confirmation requirement, above)
# assumed an UNconfirmed stop timeout means the task is genuinely still
# running. It might not -- the stop can genuinely succeed while the
# CONFIRMING lookups themselves keep failing for the whole poll window (an
# RPC/Task Scheduler hiccup, not the task being stuck). That throws too
# (correctly refusing to swap the definition on an unconfirmed stop), but
# the task would otherwise sit stranded in NO rollback set: definition
# untouched, genuinely not running, nothing recovering it.
# $script:StopAttemptedTaskNames tracks every stop REQUEST (Stop-
# ScheduledTask didn't throw), a superset of StoppedTaskNames (CONFIRMED);
# Repair-AmbiguousStop (below) handles the gap for anything in the former
# but not the latter -- a narrower recovery than Restore-TaskDefinition,
# since the definition here is guaranteed never touched: just re-query
# (fail-closed) and restart if genuinely stopped, or report loudly as
# indeterminate if even the retry can't tell.
# Get-ScheduledTask -ErrorAction SilentlyContinue conflates two different
# things into the same $null: "this task genuinely does not exist" and "the
# query itself failed" (RPC/Task Scheduler service hiccup, transient
# permission issue). Code that reads that $null as "safe to treat as a
# fresh, non-existent task" (Register-LogonTask's initial discovery) or as
# "confirmed stopped" (Wait-TaskStopped's poll, below) would then skip
# backup+stop entirely, or report a still-running old instance as gone, on
# nothing more than a transient lookup failure. This wrapper makes the
# distinction explicit: returns the task object, or $null ONLY when Task
# Scheduler positively confirms no such task exists (CategoryInfo.Category
# -- a fixed .NET enum, unlike the free-text .Exception.Message, so this
# check does not depend on system locale -- is ObjectNotFound for that
# case); any other failure re-throws, so the caller's own
# $ErrorActionPreference = 'Stop' aborts that task's migration rather than
# silently proceeding on an unverified assumption.
function Resolve-ExistingTask {
  param([string]$TaskName)
  try {
    return Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  } catch {
    if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $null }
    throw "Failed to query scheduled task '$TaskName': $_. Refusing to proceed -- cannot tell whether it already exists and needs stop+backup before being touched."
  }
}

# codex-adv-r18-2: the top-of-script check above only guards the FORWARD
# direction -- it throws when THIS run requests -Hidden but the shell isn't
# elevated. A REVERSE flip (an existing task already registered S4U from an
# earlier -Hidden run; this run omits -Hidden, or any run that simply touches
# an existing S4U task again) also mutates that task -- Register-LogonTask
# stops + re-registers it -- and if the batch later aborts, Restore-
# TaskDefinition rolls it back by re-registering the SAME saved S4U XML,
# which needs elevation too, per this script's own -Hidden claim above. An
# unelevated reverse flip can stop the running S4U task, then fail Access
# Denied mid-registration or mid-rollback, stranding it neither on the old
# definition nor the new one. Checked for every exporter task this run is
# about to touch, not just whatever -Hidden itself names: if ANY of them
# currently carries an S4U principal, the whole transaction needs elevation,
# regardless of which direction $Hidden points this run. $IsAdmin is an
# explicit parameter (not read from script scope) so this is unit-testable
# without needing an actually-elevated test process.
function Confirm-NoUnelevatedS4UMutation {
  param([string[]]$TaskNames, [bool]$IsAdmin)

  if ($IsAdmin) { return }
  $s4uTasks = @()
  foreach ($taskName in $TaskNames) {
    $existing = Resolve-ExistingTask -TaskName $taskName
    if ($existing -and $existing.Principal.LogonType -eq 'S4U') {
      $s4uTasks += $taskName
    }
  }
  if ($s4uTasks.Count -gt 0) {
    $verb = if ($s4uTasks.Count -eq 1) { 'is' } else { 'are' }
    throw "$($s4uTasks -join ', ') $verb currently registered with an S4U (hidden) principal. Changing or rolling back an S4U-registered task requires an elevated shell, the same as registering one with -Hidden in the first place. Re-run from an Administrator PowerShell."
  }
}

function Wait-TaskStopped {
  param([string]$TaskName, [int]$TimeoutSeconds = 30)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $task = Resolve-ExistingTask -TaskName $TaskName
      if (-not $task -or $task.State -ne 'Running') { return $true }
    } catch {
      # A failed lookup is not evidence of anything -- it must NOT be read
      # as "confirmed stopped". Fall through and keep polling; if it never
      # resolves within the deadline, the loop times out below, the same
      # fail-closed path as a genuinely stuck process (the caller,
      # Register-LogonTask, already aborts on timeout, leaving the
      # definition untouched).
    }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

# Counterpart poll for the final start loop (below): registering a task
# successfully does not mean it actually launched -- S4U in particular adds
# its own failure modes (missing "Log on as a batch job" rights, EFS/network
# access under the S4U token) that Start-ScheduledTask doesn't surface
# synchronously. A short poll for State -eq 'Running' lets the script report
# per-task started/not-started honestly instead of assuming success from a
# non-throwing Start-ScheduledTask call. A single Running sample is not
# enough either -- a task that dies during its own init (port conflict, an
# S4U resource-access failure that only bites once the process actually
# tries to use something) can enter Running and exit again within a couple
# of seconds. After the first Running observation, re-sample once more
# after a short stability window before trusting it. Uses Resolve-
# ExistingTask (round 12), not a bare Get-ScheduledTask -ErrorAction
# SilentlyContinue: a transient lookup failure during startup must not be
# read as "not running" -- that would trigger a spurious (if fail-safe)
# rollback on nothing more than an RPC hiccup. A caught lookup failure here
# just means "not confirmed this iteration", same as Wait-TaskStopped's poll.
function Wait-TaskStarted {
  param([string]$TaskName, [int]$TimeoutSeconds = 10, [int]$StabilitySeconds = 3)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $task = $null
    try { $task = Resolve-ExistingTask -TaskName $TaskName } catch { }
    if ($task -and $task.State -eq 'Running') {
      Start-Sleep -Seconds $StabilitySeconds
      $recheck = $null
      try { $recheck = Resolve-ExistingTask -TaskName $TaskName } catch { }
      if ($recheck -and $recheck.State -eq 'Running') { return $true }
      # Died during the stability window (or the recheck lookup itself
      # failed) -- fall through and keep polling within whatever budget
      # remains rather than failing immediately; the task's own
      # RestartCount policy may bring it back up.
    } else {
      Start-Sleep -Milliseconds 500
    }
  }
  return $false
}

# Re-applies the definition Register-LogonTask saved for $TaskName BEFORE
# this run's Register-ScheduledTask -Force overwrote it, starts it, and
# confirms (via Wait-TaskStarted, not just a non-throwing Start-ScheduledTask
# call) that it actually reached Running. Returns $true only on a fully
# verified recovery. Never throws -- callers treat a $false return as a
# recovery failure to report and reflect in the exit code, not a script-
# terminating error compounding whatever already went wrong.
function Restore-TaskDefinition {
  param(
    [string]$TaskName,
    # Only for a task that was actually RUNNING before this run touched it.
    # A pre-existing task that was NOT running (Ready/Stopped) gets its
    # definition restored either way -- the requested flip still failed to
    # apply, so the caller still counts it toward a non-zero exit -- but it
    # is not started, since it wasn't running before and starting it now
    # would hand the operator state they didn't have.
    [switch]$StartAfterRestore
  )

  if (-not $script:SavedTaskXml.ContainsKey($TaskName)) {
    Write-Warning "No saved definition for $TaskName -- it did not exist before this run, so there is nothing to restore."
    return $false
  }
  Write-Warning "Restoring $TaskName to the definition it had before this run"
  try {
    # Same "-Force doesn't touch an already-running process" trap this
    # script documents everywhere else, and the exact reason Register-
    # LogonTask stops-and-confirms before ITS OWN registration: if a
    # replacement instance is currently live here (e.g. a transient lookup
    # failure earlier marked it failed while it was actually up and
    # running), swapping the definition underneath it via -Force would
    # leave that live process running while the task's registration now
    # says something else -- reported as "restored" while the NEW-mode
    # process is still active. Fail-closed query (Resolve-ExistingTask, not
    # a bare Get-ScheduledTask) + stop + confirm, exactly like the initial
    # registration path, before ever touching the definition here.
    $liveTask = Resolve-ExistingTask -TaskName $TaskName
    if ($liveTask -and $liveTask.State -eq 'Running') {
      Write-Step "Stopping live replacement instance of $TaskName before restoring its previous definition"
      Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
      if (-not (Wait-TaskStopped -TaskName $TaskName)) {
        Write-Warning "$TaskName's replacement did not stop within 30s -- refusing to restore underneath a possibly-still-running instance."
        return $false
      }
    }
    Register-ScheduledTask -TaskName $TaskName -Xml $script:SavedTaskXml[$TaskName] -Force -ErrorAction Stop | Out-Null
    if (-not $StartAfterRestore) {
      Write-Step "$TaskName's previous definition restored (it was not running before this run, so it is not being started)"
      return $true
    }
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if (Wait-TaskStarted -TaskName $TaskName) {
      Write-Step "$TaskName restored to its previous definition and confirmed running"
      return $true
    }
    Write-Warning "$TaskName was restored to its previous definition but did not reach Running within 10s"
    return $false
  } catch {
    Write-Warning "Failed to restore $TaskName -- $_"
    return $false
  }
}

# Counterpart to Restore-TaskDefinition for a task that did NOT exist before
# this run (round 10): there is no saved XML to fall back to, so "roll it
# back" means removing it entirely, not restoring anything. Without this, a
# fresh task that registered (and maybe even started) successfully before a
# LATER sibling's failure aborted the batch would simply survive -- staying
# registered, possibly under -Hidden/S4U, while its pre-existing siblings
# roll back to their prior (e.g. Interactive) definitions. Same stop-first
# discipline as Restore-TaskDefinition: never unregister out from under a
# still-running process.
function Remove-FreshTaskRegistration {
  param([string]$TaskName)

  try {
    $liveTask = Resolve-ExistingTask -TaskName $TaskName
    if (-not $liveTask) {
      # Already gone somehow -- nothing left to remove.
      return $true
    }
    if ($liveTask.State -eq 'Running') {
      Write-Step "Stopping $TaskName before removing it (created by this run, rolled back on abort)"
      Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
      if (-not (Wait-TaskStopped -TaskName $TaskName)) {
        Write-Warning "$TaskName did not stop within 30s -- refusing to unregister a possibly-still-running task."
        return $false
      }
    }
    Write-Warning "Removing $TaskName -- it did not exist before this run and the run aborted before completing; there is no prior definition to restore, so it is unregistered instead."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    return $true
  } catch {
    Write-Warning "Failed to remove $TaskName -- $_"
    return $false
  }
}

# Repairs the ambiguous case round 12 identified: Register-LogonTask
# requested a stop (Stop-ScheduledTask did not throw) but could never
# CONFIRM it -- Wait-TaskStopped's confirming lookups themselves kept
# failing for the whole 30s window, not because the task was genuinely
# still running. That throws (fail-closed, correctly refusing to swap the
# definition on an unconfirmed stop), so the task's definition was NEVER
# touched -- but it may well be genuinely stopped, and with no rollback set
# willing to touch it (it's in neither StoppedTaskNames nor
# ReplacedTaskNames), it would otherwise sit stranded: registered under its
# own unchanged definition, but not running, with nothing to bring it back.
# Since the definition is guaranteed untouched, restarting it (once its
# state can actually be observed) IS the entire recovery -- there is
# nothing to restore.
function Repair-AmbiguousStop {
  param([string]$TaskName)

  try {
    $task = Resolve-ExistingTask -TaskName $TaskName
  } catch {
    Write-Warning "$TaskName is in an INDETERMINATE state: a stop was requested and never confirmed, and this retry lookup ALSO failed ($_). It needs manual attention -- check Task Scheduler / the process list directly."
    return 'indeterminate'
  }
  if ($task -and $task.State -eq 'Running') {
    # Never actually stopped (or it recovered on its own) -- still Running
    # under its original, untouched definition. The earlier confirmation
    # timeout was a lookup problem, not a task problem.
    Write-Step "$TaskName is Running under its original definition -- the earlier stop-confirmation timeout was a lookup failure, not evidence the task itself was stuck"
    return 'recovered'
  }
  Write-Step "Restarting $TaskName -- a fresh lookup now confirms it stopped, and its definition was never touched, so restarting it under its original definition is the entire recovery"
  try {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if (Wait-TaskStarted -TaskName $TaskName) {
      return 'recovered'
    }
    Write-Warning "$TaskName did not reach Running within 10s after the recovery restart"
    return $false
  } catch {
    Write-Warning "Failed to restart $TaskName -- $_"
    return $false
  }
}

# Single one-shot re-check used by the final revalidation sweep (near the
# bottom of this script) -- unlike Wait-TaskStarted/Wait-TaskStopped's polls,
# there is no retry loop to fall back into here, so a FAILED lookup (round
# 15) must not be read as "not Running": that would trigger rollback/
# removal of a genuinely healthy task on nothing more than a transient Task
# Scheduler hiccup. Returns $true (confirmed Running), $false (confirmed
# not Running), or 'indeterminate' (the lookup itself failed).
function Confirm-TaskStillRunning {
  param([string]$TaskName, [bool]$ExpectedHidden)

  try {
    $task = Resolve-ExistingTask -TaskName $TaskName
  } catch {
    Write-Warning "$TaskName was confirmed Running earlier, but the final revalidation sweep's lookup FAILED ($_) -- its actual state is INDETERMINATE, not assumed not-Running. Check Task Scheduler manually."
    return 'indeterminate'
  }
  if (-not $task -or $task.State -ne 'Running') {
    Write-Warning "$TaskName was confirmed Running earlier but is no longer Running at the final revalidation sweep -- treating it as NOT started."
    return $false
  }
  # codex-adv-r18-3 (narrowed): Running alone is not enough to trust as "this
  # run's own start succeeded" -- a concurrent, opposite-mode run touching the
  # same tasks (this run without -Hidden while another -Hidden run mutates
  # them, or vice versa) can leave a task genuinely Running, just re-flipped
  # to the OTHER run's principal, not the one THIS run requested and is about
  # to report success for. Verify the registered principal matches what THIS
  # run asked for before trusting Running at all -- the cheap, correct half
  # of closing that cross-confirm read. True cross-process serialization (a
  # run-level named mutex so two installs can't interleave at all) is
  # deferred to the supervisor, HIMMEL-1425 -- this only stops a mismatched
  # run from mis-reporting success, it doesn't stop the interleaving itself.
  $isS4U = $task.Principal.LogonType -eq 'S4U'
  if ($isS4U -ne $ExpectedHidden) {
    $actual = if ($isS4U) { 'S4U/hidden' } else { 'Interactive/windowed' }
    $expected = if ($ExpectedHidden) { 'S4U/hidden' } else { 'Interactive/windowed' }
    Write-Warning "$TaskName is Running, but its registered principal ($actual) does not match what this run requested ($expected) -- likely a concurrent, opposite-mode install run touched it. Treating it as NOT verifiably started under this run's definition."
    return $false
  }
  return $true
}

function Register-LogonTask {
  param(
    [string]$TaskName,
    [string]$Execute,
    [string]$Arguments,
    [string]$WorkingDirectory,
    # Optional ISO-8601 delay (e.g. 'PT3M') applied to the logon trigger. Used
    # only by Grafana: at logon w32time (trigger-started on Win11) has not yet
    # corrected the boot clock, so Grafana signs its internal ID token against a
    # fast clock; once the clock settles backward it caches that now-future-dated
    # token for the process lifetime and every grafana.app API call 500s with
    # "token issued in the future (iat)" until restart (RestartCount can't help —
    # Grafana never exits). Delaying its start past the boot clock-settle window
    # avoids it. Prometheus/exporters sign nothing clock-sensitive, so they omit
    # this. Manual Start-ScheduledTask (below, at install time) ignores the
    # trigger delay, so the interactive install stays immediate.
    [string]$StartupDelay
  )

  # See Wait-TaskStopped above: stop any live instance and wait for it to
  # actually exit BEFORE swapping the definition, so a re-register (in
  # particular a -Hidden flip) takes effect immediately and cleanly instead
  # of leaving a stale process holding the old window/session/port.
  # Resolve-ExistingTask (see above), not a bare Get-ScheduledTask -ErrorAction
  # SilentlyContinue: a FAILED lookup here must not be silently treated as
  # "task doesn't exist" -- that would skip backup+stop entirely and let
  # registration proceed while an actual running instance is still up.
  # Resolve-ExistingTask throws on a genuine failure, which aborts this
  # task's migration here with its definition (whatever it is) untouched.
  $existingTask = Resolve-ExistingTask -TaskName $TaskName
  if ($existingTask) {
    # Register-ScheduledTask -Force below overwrites the definition
    # unconditionally -- save it now, before anything touches it, so
    # Restore-TaskDefinition can put back what was actually working rather
    # than whatever ends up currently registered.
    $script:SavedTaskXml[$TaskName] = Export-ScheduledTask -TaskName $TaskName
  }
  if ($existingTask -and $existingTask.State -eq 'Running') {
    Write-Step "Stopping running instance of $TaskName before re-registering"
    # No -ErrorAction SilentlyContinue here: a stop failure must abort (the
    # script-level $ErrorActionPreference = 'Stop' makes this throw), not
    # silently fall through into swapping the definition underneath a
    # possibly-still-running old instance.
    Stop-ScheduledTask -TaskName $TaskName
    # The stop REQUEST itself succeeded (no throw) -- track the attempt
    # separately from CONFIRMED (StoppedTaskNames, below), before we know
    # whether Wait-TaskStopped can actually confirm it. If the CONFIRMING
    # lookups themselves keep failing for the whole poll window (not
    # because the task is genuinely still running), Wait-TaskStopped times
    # out and this throws below -- with the task in NO rollback set at all
    # under the round-7 ordering fix, even though the stop may well have
    # genuinely succeeded. $script:StopAttemptedTaskNames (round 12) is
    # what lets the finally block's ambiguous-stop repair pass (see
    # Repair-AmbiguousStop below) find and recover it.
    $script:StopAttemptedTaskNames.Add($TaskName) | Out-Null
    if (-not (Wait-TaskStopped -TaskName $TaskName)) {
      # Reporting-only (feeds the throw message text below, gates no
      # decision) -- still uses Resolve-ExistingTask (round 17), not a bare
      # lookup, so a failed re-query renders as an honest "lookup failed"
      # instead of silently showing as an empty/blank state.
      try {
        $currentState = (Resolve-ExistingTask -TaskName $TaskName).State
      } catch {
        $currentState = "lookup failed: $_"
      }
      throw "$TaskName did not stop within 30s (current state: $currentState). Refusing to re-register while the old instance may still hold its window/session/port -- leaving the existing task definition in place. Stop it manually (Stop-ScheduledTask -TaskName '$TaskName') and re-run."
    }
    # Only add to the rollback bookkeeping AFTER the stop is CONFIRMED. A
    # stop failure or timeout throws above and this line is never reached --
    # the task's definition is about to be left untouched either way (we
    # haven't replaced it yet), so it must stay OUT of the set the finally
    # block below drives Restore-TaskDefinition/Start-ScheduledTask from.
    # Adding it before confirmation (the round-6 bug) would let finally
    # touch a task whose old instance might still be running.
    $script:StoppedTaskNames.Add($TaskName) | Out-Null
  }

  $action = New-ScheduledTaskAction -Execute $Execute -Argument $Arguments -WorkingDirectory $WorkingDirectory
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  if ($StartupDelay) { $trigger.Delay = $StartupDelay }
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

  $registerArgs = @{
    TaskName    = $TaskName
    Action      = $action
    Trigger     = $trigger
    Settings    = $settings
    Description  = 'himmel local observability stack task'
    Force       = $true
  }
  # $Hidden is the script-level switch (parent scope). When set, run the task
  # under an S4U principal so it lives in session 0 with no visible window.
  # UserId uses the current Windows identity name (DOMAIN\User or
  # COMPUTERNAME\User), not $env:USERNAME, since S4U principal resolution
  # needs an unambiguous account reference and $env:USERNAME is a bare name
  # with no domain/machine qualifier. (All four exporter Execute/Arguments/
  # WorkingDirectory values passed into this function are already-resolved
  # literal paths built from $env:LOCALAPPDATA etc. in this elevated
  # installer's own session -- not %VAR%/$env: tokens for the task to expand
  # itself -- so S4U's lack of profile-loading at task runtime doesn't affect
  # them.)
  if ($Hidden) {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $registerArgs.Principal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType S4U -RunLevel Limited
  }
  Register-ScheduledTask @registerArgs | Out-Null
  if ($existingTask) {
    # This task's LIVE definition was actually replaced this run (the call
    # above succeeded) -- it is now rollback-eligible regardless of whether
    # it was previously Running. This is the correct restore-eligibility
    # signal (round 6): keying eligibility on $script:StoppedTaskNames alone
    # missed a pre-existing task that was NOT running before -- its saved
    # XML sat unused while its live definition was overwritten out from
    # under it.
    $script:ReplacedTaskNames.Add($TaskName) | Out-Null
  } else {
    # This task did not exist before this run -- there is no saved
    # definition to fall back to, so it is NOT rollback-eligible the same
    # way (see Remove-FreshTaskRegistration below). Tracked separately so a
    # batch abort can still remove it: without this, a fresh task that
    # registered (and maybe even started) successfully before a LATER
    # sibling's failure aborted the batch would simply survive, sitting
    # registered -- possibly under -Hidden/S4U -- while its pre-existing
    # siblings roll back to their prior (e.g. Interactive) definitions
    # (round 10).
    $script:FreshTaskNames.Add($TaskName) | Out-Null
  }
}

# Register-IntervalTask (HIMMEL-1199): unlike the long-running exporters above
# (one AtLogOn trigger, process stays up), luna-sync-alert.ts is a short-lived
# one-shot check meant to run on a cadence — an -Once trigger with a
# RepetitionInterval, starting at the next logon and repeating indefinitely
# (RepetitionDuration left unset = forever).
function Register-IntervalTask {
  param(
    [string]$TaskName,
    [string]$Execute,
    [string]$Arguments,
    [string]$WorkingDirectory,
    [int]$IntervalMinutes
  )
  # HIMMEL-2081: unlike Register-LogonTask above, this function never
  # consulted $Hidden at all -- every interval task (today: luna-sync-alert,
  # a bare bun.exe run with no cmd/pwsh wrapper) always registered
  # InteractiveToken, popping a visible console on EVERY fire regardless of
  # whether the installer's own -Hidden switch was passed. $Hidden is the
  # same script-level switch (parent scope) Register-LogonTask already reads
  # above; same S4U principal fix, applied here too.

  $action = New-ScheduledTaskAction -Execute $Execute -Argument $Arguments -WorkingDirectory $WorkingDirectory
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
  $trigger.Repetition.StopAtDurationEnd = $false
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

  $registerArgs = @{
    TaskName    = $TaskName
    Action      = $action
    Trigger     = $trigger
    Settings    = $settings
    Description = "himmel local observability stack task"
    Force       = $true
  }
  if ($Hidden) {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $registerArgs.Principal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType S4U -RunLevel Limited
  }
  Register-ScheduledTask @registerArgs | Out-Null
}

# ---------------------------------------------------------------------------
# HIMMEL-2209: seed GRAFANA_TELEGRAM_BOT_TOKEN / GRAFANA_TELEGRAM_CHAT_ID at
# User scope from himmel's OWN repo-root .env only -- see the call site below
# for why (this supersedes a cross-source fallback to the Telegram bridge's
# .env/access.json, HIMMEL-924 F3, which silently mis-routed ops alerts to
# the shared luna bot / the operator's personal DM). Split into small pieces
# so test-install-stack.ps1 can dot-source and unit-test them without a real
# [Environment] User-scope round trip:
#   Get-HimmelEnvValue             -- pure .env text parser (mirrors
#                                      boot-preflight.ps1's Get-EnvValue;
#                                      not shared, that copy isn't either)
#   Get-UserEnvVar / Set-UserEnvVar -- thin, mockable wrappers around the two
#                                      [Environment]:: static calls
#   Set-GrafanaTelegramEnvVar      -- the "already set? / seed from .env /
#                                      warn + leave unset, no fallback"
#                                      policy, called once per var so the
#                                      logic isn't duplicated twice
function Get-HimmelEnvValue {
  param([string]$EnvText, [string]$KeyName)
  if (-not $EnvText) { return $null }
  # [ \t] (not \s) around the tokens: .NET's \s matches \n too, so \s* right
  # before the capture group could consume a KEY's own line break and let the
  # (lazy, non-newline-matching) capture group land on the FOLLOWING line's
  # content instead of reporting an empty value -- e.g. a bare "KEY=" line
  # directly above another "OTHER=secret" line would silently parse KEY's
  # value as "OTHER=secret". Horizontal-whitespace-only keeps the match on
  # KEY's own line, same intent as boot-preflight.ps1's Get-EnvValue without
  # inheriting this cross-line bug.
  $pattern = "(?m)^[ \t]*$([regex]::Escape($KeyName))[ \t]*=[ \t]*(.+?)[ \t]*$"
  $m = [regex]::Match($EnvText, $pattern)
  if (-not $m.Success) { return $null }
  $val = $m.Groups[1].Value.Trim()
  if ($val.Length -ge 2) {
    $firstChar = $val.Substring(0, 1)
    $lastChar = $val.Substring($val.Length - 1, 1)
    if (($firstChar -eq '"' -or $firstChar -eq "'") -and ($firstChar -eq $lastChar)) {
      $val = $val.Substring(1, $val.Length - 2)
      # Re-trim AFTER stripping the quote pair: a quoted whitespace-only
      # value (KEY="   ") loses its quotes above and leaves bare spaces,
      # which IsNullOrEmpty does NOT catch on its own.
      $val = $val.Trim()
    }
  }
  if ([string]::IsNullOrEmpty($val)) { return $null }
  return $val
}

function Get-UserEnvVar {
  param([string]$Name)
  [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-UserEnvVar {
  param([string]$Name, [string]$Value)
  [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
}

function Set-GrafanaTelegramEnvVar {
  param([string]$VarName, [string]$EnvText)
  # [pr-check panel round 2, codex-1]: the replaced implementation wrapped its
  # equivalent [Environment] read+write in try/catch so a registry failure
  # warned instead of aborting the installer (this step is documented
  # NON-FATAL). Restore that guarantee here around both the "already set?"
  # read and the write.
  try {
    if (Get-UserEnvVar -Name $VarName) { return }
    $val = Get-HimmelEnvValue -EnvText $EnvText -KeyName $VarName
    if ($val) {
      Set-UserEnvVar -Name $VarName -Value $val
      Write-Step "Seeded $VarName from himmel's .env."
    } else {
      Write-Warning "$VarName not set in himmel's .env -- Grafana's Telegram contact point will not send until $VarName is set manually (see README.md)."
    }
  } catch {
    Write-Warning "Could not seed $VarName from himmel's .env ($($_.Exception.Message)) -- set it manually (see README.md)."
  }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoRoot) {
  $RepoRoot = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
} else {
  $RepoRoot = (Resolve-Path $RepoRoot).Path
}

# Hoisted ahead of the package installs/downloads below (literal data, no
# dependency on anything resolved further down) so the S4U elevation
# pre-flight can run -- and fail fast, before wasting time downloading
# Prometheus/Grafana/windows_exporter -- the same "fail early, not an opaque
# mid-run Access Denied" reasoning the -Hidden-only check above already uses.
$exporterTaskNames = @(
  'himmel-observability-prometheus',
  'himmel-observability-grafana',
  'himmel-observability-windows-exporter',
  'himmel-observability-flow-exporter')
Confirm-NoUnelevatedS4UMutation -TaskNames $exporterTaskNames -IsAdmin $isAdmin

$stateRoot = Join-Path $env:LOCALAPPDATA 'himmel\observability'
$promData = Join-Path $stateRoot 'prometheus-data'
$grafanaData = Join-Path $stateRoot 'grafana-data'
$grafanaLogs = Join-Path $stateRoot 'grafana-logs'
$grafanaPlugins = Join-Path $stateRoot 'grafana-plugins'
New-Item -ItemType Directory -Path $stateRoot, $promData, $grafanaData, $grafanaLogs, $grafanaPlugins -Force | Out-Null

# Pinned official release artifacts into the state root — NO winget/msiexec
# on the default path (live s53 install: Prometheus has no winget package at
# all, and the Grafana / windows_exporter MSIs are perMachine -> an invisible
# UAC wait under automation, msiexec mutex deadlocks). Everything below is
# elevation-free and user-scoped, matching the user-level scheduled tasks.
$promVersion = '3.13.1'
$grafanaVersion = '13.1.0'
$weVersion = '0.31.7'
# Pinned SHA-256 of each artifact, from the projects' published checksum
# files (prometheus sha256sums.txt, dl.grafana.com .sha256, windows_exporter
# sha256sums.txt). Bump these together with the versions.
$promSha256 = '5409abdcac847984ab7869d7814e6e8cff65b4411d62e7477b960b92eadfa08a'
$grafanaSha256 = '2c5c0733fc87129334333987799e26807a5eef1572c40941909d948392cf29f4'
$weSha256 = '288252baf470da41494420250e68b5358992701298f77a36d821992b589eccdd'
$promBinDir = Join-Path $stateRoot "prometheus-$promVersion"
$grafanaHomeDir = Join-Path $stateRoot "grafana-$grafanaVersion"
$weBinDir = Join-Path $stateRoot "windows_exporter-$weVersion"

function Assert-FileHash {
  param([string]$Path, [string]$Expected, [string]$Name)
  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Expected.ToLowerInvariant()) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    throw "SHA-256 mismatch for $Name (expected $Expected, got $actual) - download deleted, refusing to install it."
  }
}

if (-not (Test-Path (Join-Path $promBinDir 'prometheus.exe'))) {
  Write-Step "Downloading Prometheus v$promVersion release zip"
  $promZip = Join-Path $stateRoot "prometheus-$promVersion.zip"
  Invoke-WebRequest -Uri "https://github.com/prometheus/prometheus/releases/download/v$promVersion/prometheus-$promVersion.windows-amd64.zip" -OutFile $promZip
  Assert-FileHash -Path $promZip -Expected $promSha256 -Name 'Prometheus zip'
  Expand-Archive -LiteralPath $promZip -DestinationPath $stateRoot -Force
  # A partial dir from an aborted run would make Move-Item nest instead of rename.
  if (Test-Path $promBinDir) { Remove-Item -LiteralPath $promBinDir -Recurse -Force }
  Move-Item -LiteralPath (Join-Path $stateRoot "prometheus-$promVersion.windows-amd64") -Destination $promBinDir -Force
  Remove-Item -LiteralPath $promZip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $grafanaHomeDir 'bin\grafana.exe'))) {
  Write-Step "Downloading Grafana OSS v$grafanaVersion release zip"
  $grafanaZip = Join-Path $stateRoot "grafana-$grafanaVersion.zip"
  Invoke-WebRequest -Uri "https://dl.grafana.com/oss/release/grafana-$grafanaVersion.windows-amd64.zip" -OutFile $grafanaZip
  Assert-FileHash -Path $grafanaZip -Expected $grafanaSha256 -Name 'Grafana zip'
  Expand-Archive -LiteralPath $grafanaZip -DestinationPath $stateRoot -Force
  Remove-Item -LiteralPath $grafanaZip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path (Join-Path $weBinDir 'windows_exporter.exe'))) {
  Write-Step "Downloading windows_exporter v$weVersion release binary"
  New-Item -ItemType Directory -Path $weBinDir -Force | Out-Null
  $weExe = Join-Path $weBinDir 'windows_exporter.exe'
  Invoke-WebRequest -Uri "https://github.com/prometheus-community/windows_exporter/releases/download/v$weVersion/windows_exporter-$weVersion-amd64.exe" -OutFile $weExe
  Assert-FileHash -Path $weExe -Expected $weSha256 -Name 'windows_exporter binary'
}
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Invoke-PackageInstall -Name 'Bun' -WingetIds @('Oven-sh.Bun') -ScoopName 'bun'
}

# winget/scoop add PATH entries this session cannot see yet; refresh from the
# registry scopes so Resolve-RequiredCommand works on a clean machine.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$prometheusExe = if (Test-Path (Join-Path $promBinDir 'prometheus.exe')) {
  Join-Path $promBinDir 'prometheus.exe'
} else {
  Resolve-RequiredCommand -DisplayName 'Prometheus' -Names @('prometheus.exe', 'prometheus')
}
# Modern Grafana ships bin\grafana.exe (the `server` subcommand replaced the
# old grafana-server.exe binary).
$grafanaExe = if (Test-Path (Join-Path $grafanaHomeDir 'bin\grafana.exe')) {
  Join-Path $grafanaHomeDir 'bin\grafana.exe'
} else {
  Resolve-RequiredCommand -DisplayName 'Grafana' -Names @('grafana.exe', 'grafana-server.exe', 'grafana-server')
}
$grafanaServerArgPrefix = ''
if ((Split-Path -Leaf $grafanaExe) -eq 'grafana.exe') { $grafanaServerArgPrefix = 'server ' }
$windowsExporterExe = if (Test-Path (Join-Path $weBinDir 'windows_exporter.exe')) {
  Join-Path $weBinDir 'windows_exporter.exe'
} else {
  Resolve-RequiredCommand -DisplayName 'windows_exporter' -Names @('windows_exporter.exe', 'windows_exporter')
}
$bunExe = Resolve-RequiredCommand -DisplayName 'Bun' -Names @('bun.exe', 'bun')

$prometheusConfig = Join-Path $stateRoot 'prometheus.yml'
Copy-Item -LiteralPath (Join-Path $scriptDir 'prometheus.yml') -Destination $prometheusConfig -Force
# HIMMEL-1633: prometheus.yml's rule_files entry is RELATIVE to the config's
# location, so the rule file must travel with it — without this copy the
# installed Prometheus references a missing alerts.rules.yml and refuses its
# config (the HIMMEL-924 rules were inert after install).
Copy-Item -LiteralPath (Join-Path $scriptDir 'alerts.rules.yml') -Destination (Join-Path $stateRoot 'alerts.rules.yml') -Force

$grafanaIni = Join-Path $stateRoot 'grafana.ini'
# HIMMEL-924: grafana-provisioning holds a machine-local COPY of
# scripts/observability/provisioning/ (copied below, same pattern as
# prometheus.yml) -- Grafana reads its provisioning tree from [paths]
# provisioning, so alert rules/contact points/the Prometheus datasource all
# load without a manual step.
$grafanaProvisioning = Join-Path $stateRoot 'grafana-provisioning'
@"
[server]
http_addr = 127.0.0.1
http_port = 3000
root_url = http://127.0.0.1:3000/

[paths]
data = $($grafanaData.Replace('\', '/'))
logs = $($grafanaLogs.Replace('\', '/'))
plugins = $($grafanaPlugins.Replace('\', '/'))
provisioning = $($grafanaProvisioning.Replace('\', '/'))
"@ | Set-Content -LiteralPath $grafanaIni -Encoding utf8

# Copy scripts/observability/provisioning/'s CONTENTS into the state root,
# mirroring the prometheus.yml copy above -- none of these files hold
# machine paths, so a plain recursive copy (no templating) is enough. Source
# uses a trailing \* so a re-run merges into an existing $grafanaProvisioning
# instead of nesting a second "provisioning" folder inside it (Copy-Item
# -Recurse copies a directory ARGUMENT into an already-existing destination
# rather than overwriting its contents; globbing the source's contents is
# the idempotent form).
New-Item -ItemType Directory -Path $grafanaProvisioning -Force | Out-Null
Copy-Item -Path (Join-Path $scriptDir 'provisioning\*') -Destination $grafanaProvisioning -Recurse -Force

# HIMMEL-2209 (supersedes HIMMEL-924 F3's bridge-reuse design): seed the two
# env vars contact-points.yaml interpolates ($GRAFANA_TELEGRAM_BOT_TOKEN /
# $GRAFANA_TELEGRAM_CHAT_ID), persisted at User scope so the logon-triggered
# Grafana task inherits them. Seeded ONLY from himmel's OWN repo-root .env --
# never from the Telegram bridge's .env / access.json (that cross-source
# fallback silently routed ops alerts to the shared luna bot / the
# operator's personal DM). See README.md's "Alerting" section for the full
# writeup. This step is NON-FATAL and never overwrites an operator-set
# value; an absent/empty key in .env WARNS loudly and leaves the var unset
# -- no fallback, ever.
$himmelEnvPath = Join-Path $RepoRoot '.env'
$himmelEnvText = ''
try {
  if (Test-Path -LiteralPath $himmelEnvPath) {
    $himmelEnvText = Get-Content -LiteralPath $himmelEnvPath -Raw
  }
} catch {
  Write-Warning "Could not read himmel's .env at $himmelEnvPath ($($_.Exception.Message)) -- Grafana Telegram alerting env vars will not be seeded automatically (see README.md)."
}
Set-GrafanaTelegramEnvVar -VarName 'GRAFANA_TELEGRAM_BOT_TOKEN' -EnvText $himmelEnvText
Set-GrafanaTelegramEnvVar -VarName 'GRAFANA_TELEGRAM_CHAT_ID' -EnvText $himmelEnvText

# A logon-triggered task inherits the User-scope environment block computed
# at the TASK's own logon, not this installer's already-running session --
# refresh this process's view too so a same-session Grafana restart (rare,
# but harmless to cover) also picks up a freshly-seeded value.
$env:GRAFANA_TELEGRAM_BOT_TOKEN = [Environment]::GetEnvironmentVariable('GRAFANA_TELEGRAM_BOT_TOKEN', 'User')
$env:GRAFANA_TELEGRAM_CHAT_ID = [Environment]::GetEnvironmentVariable('GRAFANA_TELEGRAM_CHAT_ID', 'User')

$grafanaBin = Split-Path -Parent $grafanaExe
if ($grafanaBin -like '*\scoop\shims*') {
  # A scoop shim's parent is the shims dir, not Grafana's install root.
  $grafanaHome = (scoop prefix grafana).Trim()
} else {
  $grafanaHome = Split-Path -Parent $grafanaBin
}
$flowExporter = Join-Path $RepoRoot 'scripts\observability\flow-exporter.ts'

# $script:SavedTaskXml (task name -> exported XML) is populated by
# Register-LogonTask, before it touches an existing task, for every task
# that already exists -- see Restore-TaskDefinition above for why "restart
# what was stopped" isn't a real rollback on its own. $script:StoppedTaskNames
# is the subset that were actually Running AND confirmed stopped;
# $script:ReplacedTaskNames is the (possibly larger, possibly disjoint-ish)
# set whose LIVE definition this run actually overwrote -- see the comment
# above Wait-TaskStopped for why restore-eligibility is their union, and why
# neither one alone is correct. $script:FreshTaskNames (round 10) is the
# complementary set: tasks that did NOT exist before this run, so they have
# no saved XML and are not restore-eligible the same way -- Remove-
# FreshTaskRegistration above unregisters them instead, on an aborted batch,
# so rollback symmetry holds: pre-existing -> restored to saved XML; fresh ->
# unregistered, not left behind under whatever this run's own definition was.
# $script:StopAttemptedTaskNames (round 12) is a superset of StoppedTaskNames:
# every task whose stop was REQUESTED, whether or not it was ever CONFIRMED --
# see Repair-AmbiguousStop above for the gap this closes (a stop that
# genuinely succeeded while the confirming lookups themselves kept failing
# would otherwise strand the task in no rollback set at all). $taskStartStatus
# (task name -> $true / 'restored' / 'removed' / 'recovered' / 'indeterminate'
# / $false) is the single source of truth the finally block below and the
# final exit-code section both read -- no separate "confirmed running" list
# is needed.
$script:SavedTaskXml = @{}
$script:StoppedTaskNames = New-Object System.Collections.Generic.List[string]
$script:ReplacedTaskNames = New-Object System.Collections.Generic.List[string]
$script:FreshTaskNames = New-Object System.Collections.Generic.List[string]
$script:StopAttemptedTaskNames = New-Object System.Collections.Generic.List[string]
$taskStartStatus = [ordered]@{}
$scriptFailed = $false

try {
  Register-LogonTask `
    -TaskName 'himmel-observability-prometheus' `
    -Execute $prometheusExe `
    -Arguments "--config.file=`"$prometheusConfig`" --storage.tsdb.path=`"$promData`" --web.listen-address=127.0.0.1:9090" `
    -WorkingDirectory $stateRoot

  Register-LogonTask `
    -TaskName 'himmel-observability-grafana' `
    -Execute $grafanaExe `
    -Arguments "$grafanaServerArgPrefix--homepath `"$grafanaHome`" --config `"$grafanaIni`"" `
    -WorkingDirectory $grafanaHome `
    -StartupDelay 'PT3M'

  # HIMMEL-1161: disable the 'service' collector — it leaks kernel handles (paged pool) every scrape.
  Register-LogonTask `
    -TaskName 'himmel-observability-windows-exporter' `
    -Execute $windowsExporterExe `
    -Arguments "--web.listen-address=127.0.0.1:9182 --collectors.disabled=service" `
    -WorkingDirectory $stateRoot

  Register-LogonTask `
    -TaskName 'himmel-observability-flow-exporter' `
    -Execute $bunExe `
    -Arguments "run `"$flowExporter`"" `
    -WorkingDirectory $RepoRoot

  $lunaSyncAlert = Join-Path $RepoRoot 'scripts\observability\luna-sync-alert.ts'
  Register-IntervalTask `
    -TaskName 'himmel-observability-luna-sync-alert' `
    -Execute $bunExe `
    -Arguments "run `"$lunaSyncAlert`"" `
    -WorkingDirectory $RepoRoot `
    -IntervalMinutes 10

  # Logon triggers only fire at the NEXT logon; start each task now so the
  # verification below reflects reality immediately after install. A failed
  # Wait-TaskStarted here does NOT throw -- it's recorded and handled by the
  # finally block's restore pass below, alongside anything an earlier
  # exception in this try block left mid-flight.
  foreach ($taskName in $exporterTaskNames) {
    Write-Step "Starting $taskName"
    Start-ScheduledTask -TaskName $taskName
    $started = Wait-TaskStarted -TaskName $taskName
    $taskStartStatus[$taskName] = $started
    if (-not $started) {
      $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
      Write-Warning "$taskName did not reach Running within 10s (LastTaskResult=$($info.LastTaskResult)) -- treating it as NOT started. Check Task Scheduler (in -Hidden/S4U mode this commonly means the account is missing 'Log on as a batch job' rights, or the S4U token can't reach EFS/network resources the process needs)."
    }
  }

  # Final revalidation sweep: Wait-TaskStarted's own per-task stability
  # recheck already guards against a task dying immediately during its own
  # init, but a task confirmed stable early in the loop above could still go
  # down later -- e.g. a port conflict from a LATER exporter starting, or a
  # slower-manifesting S4U resource failure. Re-check every exporter this
  # run believes it started, once more, before deciding the run's outcome.
  # Endpoint-level verification (curling each /metrics URL) stays deferred
  # to HIMMEL-1425 (supervisor territory) -- this is still just a Task
  # Scheduler state check, not a health probe of what the process is doing.
  # Confirm-TaskStillRunning (above) is Resolve-ExistingTask-based, not a
  # bare Get-ScheduledTask -ErrorAction SilentlyContinue -- round 15: a
  # FAILED lookup counts as 'indeterminate', never silently "not Running".
  foreach ($taskName in $exporterTaskNames) {
    if ($taskStartStatus[$taskName] -eq $true) {
      $reconfirmed = Confirm-TaskStillRunning -TaskName $taskName -ExpectedHidden:$Hidden
      if ($reconfirmed -ne $true) {
        $taskStartStatus[$taskName] = $reconfirmed
      }
    }
  }

  # Round 12: Wait-TaskStarted returning $false for one exporter is an
  # honest, individually-reported failure -- it does NOT throw, so
  # $scriptFailed alone would stay $false and the finally block's rollback
  # would (per its narrower per-task check) touch only THAT one task,
  # leaving successful siblings on the requested definition and any fresh
  # registrations standing -- the exact mixed-stack problem rounds 9/11
  # fixed for the exception path, just reached without an exception. A
  # CONFIRMED not-Running task means the batch did not fully succeed, full
  # stop; treat it the same as an aborted run so the existing uniform
  # rollback machinery (restore every touched pre-existing task, remove
  # every fresh one) applies uniformly below.
  #
  # Round 17: deliberately scoped to $false only, NOT "-ne $true" -- an
  # 'indeterminate' sweep result (round 15: the final lookup itself failed,
  # not evidence the task is unhealthy) must NOT fold into this flag. Doing
  # so would drag every OTHER, perfectly healthy sibling and fresh
  # registration into a full rollback/removal on nothing more than a
  # transient RPC hiccup at the very last check of the run -- exactly what
  # round 15 introduced 'indeterminate' to avoid. It still counts toward the
  # non-zero exit on its own, via $notFlippedTasks below; it just doesn't
  # drag the rest of the stack down with it.
  if (@($exporterTaskNames | Where-Object { $taskStartStatus[$_] -eq $false }).Count -gt 0) {
    $scriptFailed = $true
  }

  # luna-sync-alert is a short-lived one-shot check (5-minute execution
  # limit, repeats on its own schedule) -- it can legitimately finish and
  # leave 'Running' before we'd poll it, so it is deliberately NOT run
  # through Wait-TaskStarted (that would produce false "not started"
  # reports for a task that ran and exited normally). It is also unaffected
  # by -Hidden, so it carries none of the S4U-specific start risk above, and
  # it is never stopped/replaced by this script, so it has no restore path
  # either.
  Write-Step 'Starting himmel-observability-luna-sync-alert'
  Start-ScheduledTask -TaskName 'himmel-observability-luna-sync-alert'
}
catch {
  $scriptFailed = $true
  Write-Warning "Registration/start aborted partway through: $_"
}
finally {
  # Restore-eligible = the union of StoppedTaskNames (was Running, confirmed
  # stopped) and ReplacedTaskNames (this run's new-definition Register-
  # ScheduledTask call actually succeeded) -- see the comment above
  # Wait-TaskStopped for why neither alone is correct. $taskStartStatus is
  # already the single source of truth for "did this task reach its
  # intended end state": $true means the main loop above confirmed it
  # Running; anything else (an explicit $false, or simply absent because an
  # earlier task's registration threw before the main loop ever reached
  # this one) means it needs a restore attempt.
  $rollbackCandidates = @($script:StoppedTaskNames) + @($script:ReplacedTaskNames | Where-Object { $script:StoppedTaskNames -notcontains $_ })
  foreach ($taskName in $rollbackCandidates) {
    # On a CLEAN run (no exception), only a task that individually failed to
    # reach its intended end state needs recovery -- $taskStartStatus -ne
    # $true is the right, narrow check. On an ABORTED run ($scriptFailed),
    # every pre-existing task this run touched rolls back UNIFORMLY, even
    # one that itself already reached Running under the new/requested
    # definition before a LATER task's failure aborted the batch. Skipping
    # an already-$true task here (the round-8 bug) could leave a mixed
    # stack -- one exporter on the requested definition, another restored
    # to its old one -- after a single partial failure. "An aborted run
    # guarantees no regression" is a BATCH-level guarantee (every
    # pre-existing task back to what it had before this run), not a
    # per-task one.
    #
    # Round 17: an 'indeterminate' task (the final sweep's own lookup
    # failed -- round 15) is left alone entirely here, never restored. The
    # whole point of 'indeterminate' is "we genuinely don't know its
    # state" -- attempting a restore on it would mean taking a corrective
    # action (stopping a possibly-live replacement, swapping in the saved
    # XML) based on nothing more than a transient RPC hiccup, which could
    # itself be actively harmful if the task is actually fine. It still
    # reports honestly and still counts toward the non-zero exit
    # (unchanged, via $notFlippedTasks below) -- it just isn't touched.
    # 'indeterminate' -eq $value, NOT $value -eq 'indeterminate' -- when
    # $taskStartStatus[$taskName] is the literal boolean $true (a healthy,
    # confirmed-started task), PowerShell's -eq coerces a non-empty STRING
    # right-hand operand to boolean when the LEFT operand is boolean, so
    # $true -eq 'indeterminate' evaluates to $true (a real bug this exact
    # line shipped with initially -- caught by Test 23 regressing after this
    # fix landed, then traced to this coercion direction, not a logic bug).
    # String-on-the-left avoids it entirely: 'indeterminate' -eq $true is
    # correctly $false, since a String is now the left operand.
    if ('indeterminate' -eq $taskStartStatus[$taskName]) {
      continue
    }
    if ($scriptFailed -or $taskStartStatus[$taskName] -ne $true) {
      $wasRunningBefore = $script:StoppedTaskNames -contains $taskName
      $restored = Restore-TaskDefinition -TaskName $taskName -StartAfterRestore:$wasRunningBefore
      $taskStartStatus[$taskName] = if ($restored) { 'restored' } else { $false }
    }
  }
  # A task with no prior existence has no saved definition to fall back to
  # (round 10). On a clean run that just means an individual failure reports
  # $false, same as always -- no special handling needed. On an ABORTED run,
  # the same batch-uniformity argument above applies: a fresh task that
  # registered (and maybe even started) successfully before a LATER
  # sibling's failure aborted the batch must not simply survive registered
  # (possibly running under -Hidden/S4U) while its pre-existing siblings
  # roll back -- true rollback for a task this run created is removing it.
  if ($scriptFailed) {
    foreach ($taskName in $script:FreshTaskNames) {
      $removed = Remove-FreshTaskRegistration -TaskName $taskName
      $taskStartStatus[$taskName] = if ($removed) { 'removed' } else { $false }
    }
  }
  # Round 12: a task whose stop was ATTEMPTED (Stop-ScheduledTask didn't
  # throw) but never CONFIRMED (Wait-TaskStopped's own poll timed out) is
  # in neither StoppedTaskNames nor ReplacedTaskNames -- it fell through
  # $rollbackCandidates above entirely. Its definition is guaranteed
  # untouched (Register-LogonTask threw before ever reaching Register-
  # ScheduledTask for it), so Repair-AmbiguousStop's job is narrower than a
  # full restore: just re-establish whether it's actually running.
  foreach ($taskName in $script:StopAttemptedTaskNames) {
    if ($script:StoppedTaskNames -notcontains $taskName) {
      $taskStartStatus[$taskName] = Repair-AmbiguousStop -TaskName $taskName
    }
  }
}

# Net contract: exit 0 iff EVERY requested exporter is verifiably Running
# under the definition THIS RUN requested. $script:StoppedTaskNames stays
# scoped to rollback decisions only (which tasks get a Restore-TaskDefinition
# attempt in finally, above) -- it must NOT drive the exit code, or a fresh
# install (nothing pre-existing, so nothing ever added to StoppedTaskNames)
# whose exporters all fail their async start would report NOT STARTED per
# task and still exit 0. Anything other than the literal boolean $true --
# $false (never got running), 'restored' (running, but on the OLD definition
# because the requested flip failed and was rolled back), 'removed'
# (unregistered because it was created by this run and the batch aborted --
# round 10), 'recovered' (an unconfirmed stop turned out fine on retry, or
# was restarted under its own untouched definition -- round 12),
# 'indeterminate' (a stop was requested and its outcome could not be
# confirmed even on retry -- round 12), or simply absent (this run never
# reached the task, always paired with $scriptFailed) -- means the requested
# change did not verifiably land.
$notFlippedTasks = @($exporterTaskNames | Where-Object { $taskStartStatus[$_] -ne $true })
# String-literal-on-the-left throughout below (round 17): $taskStartStatus
# values can be the literal boolean $true, and PowerShell's -eq coerces a
# non-empty STRING right-hand operand to boolean when the left operand is
# boolean -- so "$taskStartStatus[$_] -eq 'restored'" would silently also
# match every $true (healthy, started) task, polluting these buckets with
# tasks that need no mention at all. Putting the string on the left (as
# PowerShell's own `switch` does internally) avoids the coercion entirely.
$restoredTasks = @($exporterTaskNames | Where-Object { 'restored' -eq $taskStartStatus[$_] })
$removedTasks = @($exporterTaskNames | Where-Object { 'removed' -eq $taskStartStatus[$_] })
$recoveredTasks = @($exporterTaskNames | Where-Object { 'recovered' -eq $taskStartStatus[$_] })
$indeterminateTasks = @($exporterTaskNames | Where-Object { 'indeterminate' -eq $taskStartStatus[$_] })
$notRunningTasks = @($exporterTaskNames | Where-Object { $taskStartStatus.Contains($_) -and $taskStartStatus[$_] -eq $false })

# Endpoint-level verification (actually probing each /metrics URL) and
# persisted per-task stdout/stderr logs are supervisor territory, not this
# installer's -- deferred to HIMMEL-1425.
Write-Output ''
Write-Output 'Verification:'
Write-Output '  Prometheus:       http://127.0.0.1:9090'
Write-Output '  Grafana:          http://127.0.0.1:3000'
Write-Output '  flow exporter:    http://127.0.0.1:9877/metrics'
Write-Output '  windows_exporter: http://127.0.0.1:9182/metrics'
Write-Output '  Scheduled tasks:'
foreach ($taskName in $exporterTaskNames) {
  if ($taskStartStatus.Contains($taskName)) {
    $status = switch ($taskStartStatus[$taskName]) {
      $true            { 'started' }
      'restored'       { 'RESTORED to its previous definition after the new one failed to start' }
      'removed'        { 'REMOVED -- created by this run, rolled back on abort' }
      'recovered'      { 'RECOVERED on its ORIGINAL (never-replaced) definition -- an earlier stop could not be confirmed at the time' }
      'indeterminate'  { 'INDETERMINATE -- a stop was requested and its outcome could not be confirmed; check manually' }
      default          { 'NOT STARTED -- see warning above' }
    }
  } else {
    # This run never reached this task (an earlier task's registration threw
    # first) -- report its actual live state rather than assuming failure;
    # an untouched, already-running task from before this run is healthy.
    # Reporting-only (renders a listing line, gates no decision) -- still
    # uses Resolve-ExistingTask (round 17), not a bare lookup, so a failed
    # query renders as an honest "lookup failed" instead of silently
    # reading as "not registered".
    try {
      $liveState = (Resolve-ExistingTask -TaskName $taskName).State
      $status = if ($liveState -eq 'Running') { 'unchanged, already running (this run never reached it)' }
                elseif ($liveState) { "unchanged, not running (state: $liveState; this run never reached it)" }
                else { 'not registered (this run never reached it)' }
    } catch {
      $status = "unchanged, but a live-state lookup failed while reporting ($_) -- this run never reached it either way"
    }
  }
  Write-Output "    $taskName ($status)"
}
Write-Output '    himmel-observability-luna-sync-alert (every 10 minutes)'

if ($scriptFailed -or $notFlippedTasks.Count -gt 0) {
  Write-Output ''
  if ($restoredTasks.Count -gt 0) {
    Write-Output "FLIP DID NOT APPLY for: $($restoredTasks -join ', ') -- the requested definition failed to start, so the previous definition was restored and confirmed running instead. The stack is up, but the requested change was not made."
  }
  if ($removedTasks.Count -gt 0) {
    Write-Output "REMOVED: $($removedTasks -join ', ') -- created by this run, rolled back on abort (no prior definition existed to restore)."
  }
  if ($recoveredTasks.Count -gt 0) {
    Write-Output "RECOVERED (on their ORIGINAL, never-replaced definition): $($recoveredTasks -join ', ') -- an earlier stop could not be confirmed at the time (a lookup failure, not the task itself); the requested change did not apply."
  }
  if ($indeterminateTasks.Count -gt 0) {
    Write-Output "INDETERMINATE: $($indeterminateTasks -join ', ') -- a stop was requested and its outcome could not be confirmed, even on retry. Check Task Scheduler / the process list manually before assuming anything about these."
  }
  if ($notRunningTasks.Count -gt 0) {
    Write-Output "NOT RUNNING: $($notRunningTasks -join ', ') -- see warnings above."
  }
  if ($scriptFailed) {
    Write-Output 'This install attempt was aborted partway through -- see warnings above.'
  }
  exit 1
}
exit 0
