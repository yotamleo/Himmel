# scripts/himmelctl/lib/job-run.ps1 -- HIMMEL-755 CR round: win32 process-
# tree-kill via a Windows Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
#
# WHY (not `taskkill /PID <pid> /T /F`, install-engine.js's own shipped
# win32 cleanup before this round): taskkill's tree-kill walks the CURRENT
# process snapshot's ParentProcessID chain starting from the root pid, AT
# KILL TIME. A descendant that has already re-parented -- exactly what
# installers and package postinst/daemon scripts do (spawn a background
# daemon inside a subshell that itself exits immediately, "orphaning" the
# daemon) -- can be MISSED: verified empirically against a genuine
# re-parenting reproduction (a wedged bash primitive backgrounds a
# grandchild inside a `(...)` subshell that exits without waiting) --
# taskkill left the grandchild running; a Job Object did not. See
# test-wizard-install-engine.sh's case v/w for the harness that proves
# this both ways.
#
# A Job Object makes the guarantee STRUCTURAL instead of a best-effort
# tree-walk: every descendant a job-member process spawns automatically
# joins the SAME job (nested-job support, standard since Windows 8), so
# there is no re-parenting escape and no snapshot-timing race --
# terminating the job kills every member, unconditionally, in one call.
#
# CR fix (codex critic round 3, IMPORTANT): that same kill-on-close
# guarantee is wrong on the SUCCESS path. The job is created with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE set so that if job-run.ps1 itself is
# forcibly killed from OUTSIDE (install-engine.js's own Node-level backstop
# timeout, a last-resort safety net -- see its own comment), the OS's
# handle-cleanup-on-process-exit still tears the whole tree down even
# though this script never got to run any of its own cleanup code. But
# this script holds the ONLY handle to the job, so a plain CloseHandle() on
# ANY exit path -- including a perfectly normal, successful completion --
# was ALSO enough to trigger it, killing a legitimately-started background
# service/daemon/helper the very moment the installer that launched it
# returned successfully. Fixed: the limit flag is explicitly CLEARED
# (Clear-JobKillOnClose) before the handle is released on every path except
# the genuine timeout one, so a surviving descendant is released, not
# killed; the timeout path keeps the flag set AND explicitly calls
# TerminateJobObject (belt and suspenders on that path only).
#
# Zero new npm deps (the operator's explicit doctrine -- koffi/ffi-napi
# would violate it): this is a plain PowerShell script using Add-Type
# P/Invoke against kernel32.dll, shelled out to exactly like setup.ps1/
# uninstall.ps1 already are (bin.js's own cmdInstall/cmdUninstall).
#
# Interface (install-engine.js's win32 runHardenedSpawn branch is the ONLY
# caller):
#   -Command <string>            the program to run (always 'bash' today,
#                                 but never hardcoded here)
#   -CommandArgsB64 <string>     base64(UTF8(JSON.stringify(argv))) -- see
#                                 "why base64+JSON" below
#   -TimeoutSeconds <int>
#   -HasInput (switch)           when set, this script's OWN stdin is
#                                 relayed VERBATIM to the wrapped command's
#                                 stdin (see "why stdin relay, not an argv
#                                 payload" below). Node pipes the credential
#                                 into POWERSHELL's stdin exactly like it
#                                 already does for the POSIX `entry.input`
#                                 path; this script never sees or handles
#                                 the secret as a discrete value at all,
#                                 only as an opaque byte stream it forwards.
#                                 Unused by any win32 buildEntry() case
#                                 today (every credential-bearing entry is
#                                 Linux-only) -- kept for parity/
#                                 future-proofing, tested the same as
#                                 everything else here.
#
# Why base64+JSON for CommandArgs specifically, not a `[string[]]` param or
# a raw `[string]` param, both tried and REJECTED during development:
#   - `[string[]]$CommandArgs` bound from an EXTERNAL process launch (not
#     PowerShell's own in-session comma-array syntax) silently drops every
#     token after the first -- verified empirically (`-CommandArgs foo bar
#     baz` bound ONLY "foo"; "bar"/"baz" vanished with no error). PowerShell
#     script parameter binding for -File invocations does not accumulate
#     repeated bare tokens into an array the way an in-session `@('a','b')`
#     literal does.
#   - A raw JSON string as a plain argv value collides with Windows argv
#     quoting: both JSON and CreateProcess's own argument-quoting convention
#     use `"` as their delimiter, and the two layers of quoting corrupt each
#     other once the JSON contains its own embedded quotes.
#   - Base64 has no argv-special characters at all, sidestepping both.
#
# Why stdin RELAY, not a `-InputTextB64` argv payload (the FIRST design,
# caught and reverted before shipping): base64 is encoding, NOT encryption
# -- a base64'd secret sitting in job-run.ps1's own command line would
# still be fully `ps`/Task-Manager/process-command-line-visible to any
# other user on the box (trivially reversible by anyone who can already see
# it), reintroducing EXACTLY the argv-exposure vulnerability the stdin-only
# transport exists to prevent. entry.args (the wrapped command's own argv,
# never itself secret -- buildEntry's sudo entry puts the password ONLY in
# `.input`, never `.args`) is fine over base64+argv; the credential itself
# never may be. CommandArgs are argv-safe by construction; InputText is not
# argv-safe under ANY encoding, so it goes over the ONE channel that never
# materializes in a command line at all: stdin, piped hop-by-hop
# (Node->powershell.exe->the wrapped command), exactly mirroring the
# existing POSIX `entry.input` -> spawnSync `input` -> child stdin path.
#
# `ConvertFrom-Json` PITFALL (also discovered empirically, worth flagging
# for the next person editing this file): `@(ConvertFrom-Json -InputObject
# $json)` for a JSON ARRAY double-wraps -- ConvertFrom-Json emits its
# result (itself an array) as ONE pipeline object, so `@()` around the
# WHOLE call collects that single emitted object into an outer 1-element
# array (Count=1, holding the entire real array as element 0). The fix
# (below) is to assign first, THEN normalize to an array only if the
# result isn't already one.
param(
  [Parameter(Mandatory=$true)][string]$Command,
  [Parameter(Mandatory=$true)][string]$CommandArgsB64,
  [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
  [Parameter(Mandatory=$false)][switch]$HasInput
)

# CR: deliberately NOT `$ErrorActionPreference = 'Stop'` globally -- a
# Job-Object setup failure (CreateJobObjectW/SetInformationJobObject/
# AssignProcessToJobObject all return a bool + SetLastError rather than
# throwing) is handled explicitly at each call site instead of via an
# uncaught-exception crash. Diagnostics go to stderr via [Console]::Error,
# never Write-Error (which would throw once real errors DO need to
# propagate elsewhere in this file).
#
# CR fix (CodeRabbit round 15, item 2 -- FAIL CLOSED, not silent degrade):
# setup failure used to degrade to $jobObjectAvailable=$false and proceed
# with only .NET's best-effort direct-child Kill() on timeout -- "no worse
# than before Job Objects existed," but silently reintroducing the exact
# re-parenting gap this whole file exists to close (see the file header's
# "WHY"), with no visible signal it had happened. That silently made
# docs/setup/new-machine.md's own "a timeout can't leave a survivor"
# guarantee false on exactly the machines where it matters most. Fixed: any
# setup failure below now exits immediately -- before the wrapped command
# ever starts, or by killing it right away if it had already started --
# with a distinct exit code install-engine.js classifies as a hard failure
# landing in failed[], matching this verb's fail-closed posture elsewhere
# (a misconfigured/restricted environment blocks the operation rather than
# silently running it unprotected).
$TIMEOUT_EXIT_CODE = 4217
$JOB_SETUP_FAILED_EXIT_CODE = 4218
# CR fix (CodeRabbit round 16, item 3 — confirmed independently by a
# senior/Fable review, worse than first framed): a WaitForExit() exception
# used to be treated as "not a timeout," which routed into the SUCCESS
# branch below — clearing kill-on-close and releasing the job while the
# wrapped command (and its entire tree) kept running UNBOUNDED, with
# neither a timeout nor job protection left in place. That's a fail-OPEN
# on the one path in this file that's supposed to fail closed like every
# other setup/wait failure here. See the WaitForExit try/catch below for
# the fix; this sentinel lets install-engine.js tell a genuine timeout
# apart from "we couldn't confirm completion and killed defensively."
$WAIT_FAILED_EXIT_CODE = 4219
# CR fix (codex round 17): the wrapped command SUCCEEDED but clearing
# KILL_ON_JOB_CLOSE failed, so releasing the handle may have killed a
# legitimate background descendant the install deliberately launched. Same
# fail-OPEN class as $WAIT_FAILED_EXIT_CODE above: the old code exited with
# the child's own success status, so `ensure` reported green right after
# potentially breaking the service it installed. Distinct sentinel so
# install-engine.js can name the actual failure (it classifies this spawn by
# exit code alone and never reads job-run's stderr warning).
$CLEANUP_FAILED_EXIT_CODE = 4220

function ConvertFrom-Base64Json {
  param([string]$B64)
  if ([string]::IsNullOrEmpty($B64)) { return @() }
  $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($B64))
  $decoded = ConvertFrom-Json -InputObject $json
  if ($decoded -isnot [array]) { $decoded = @($decoded) }
  return $decoded
}

# Windows argv quoting (the standard CreateProcess/CommandLineToArgvW
# convention -- .NET's own ProcessStartInfo.ArgumentList isn't present on
# this codebase's baseline PowerShell 5.1 / .NET Framework, verified
# empirically, so it must be built by hand). Round-trip verified against
# spaces, apostrophes, embedded double-quotes, and a lone trailing
# backslash.
function ConvertTo-WindowsArgString {
  param([string[]]$ArgList)
  $parts = foreach ($a in $ArgList) {
    if ($null -eq $a) { $a = '' }
    if ($a.Length -gt 0 -and $a -notmatch '[\s"]') {
      $a
    } else {
      $sb = New-Object System.Text.StringBuilder
      [void]$sb.Append('"')
      $backslashes = 0
      foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') {
          $backslashes++
        } elseif ($ch -eq '"') {
          [void]$sb.Append('\' * ($backslashes * 2 + 1))
          [void]$sb.Append('"')
          $backslashes = 0
        } else {
          if ($backslashes -gt 0) { [void]$sb.Append('\' * $backslashes); $backslashes = 0 }
          [void]$sb.Append($ch)
        }
      }
      if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
      [void]$sb.Append('"')
      $sb.ToString()
    }
  }
  return ($parts -join ' ')
}

Add-Type -Name JobNative -Namespace HimmelCtl -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

[DllImport("kernel32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool CloseHandle(IntPtr hObject);
'@

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace HimmelCtl {
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS {
    public UInt64 ReadOperationCount;
    public UInt64 WriteOperationCount;
    public UInt64 OtherOperationCount;
    public UInt64 ReadTransferCount;
    public UInt64 WriteTransferCount;
    public UInt64 OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public Int64 PerProcessUserTimeLimit;
    public Int64 PerJobUserTimeLimit;
    public UInt32 LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public UInt32 ActiveProcessLimit;
    public UIntPtr Affinity;
    public UInt32 PriorityClass;
    public UInt32 SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }
}
'@

$JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
$JobObjectExtendedLimitInformation = 9

# BUG FOUND (empirically, during development -- see the codex-critic-round-3
# writeup this fix responds to): `$info.BasicLimitInformation.LimitFlags =
# <value>` silently DOES NOT PERSIST. BasicLimitInformation is a nested
# VALUE-TYPE (struct) field -- PowerShell's property access returns a
# boxed COPY of it, so assigning `.LimitFlags` on that expression mutates
# the temporary copy, never the real field inside $info. Verified in
# isolation: `$o.Basic.Flags = 999; $o.Basic.Flags` reads back 0. This means
# LimitFlags was NEVER actually reaching SetInformationJobObject as
# anything but 0 in the FIRST shipped version of this file -- the entire
# KILL_ON_JOB_CLOSE mechanism was silently inert; every test that passed
# did so because the TIMEOUT path's explicit TerminateJobObject() call
# (below) kills the tree directly and does not depend on this flag at all.
# Fixed by building the INNER struct as its own local variable first, then
# assigning the WHOLE struct value into the outer field in one shot (a
# plain value-type copy, not a nested-property mutation) -- reused by
# Clear-JobKillOnClose (below) for the exact same reason.
function New-ExtendedLimitInfo {
  param([UInt32]$LimitFlags)
  $basic = New-Object HimmelCtl.JOBOBJECT_BASIC_LIMIT_INFORMATION
  $basic.LimitFlags = $LimitFlags
  $info = New-Object HimmelCtl.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
  $info.BasicLimitInformation = $basic
  return $info
}

function Set-JobLimitFlags {
  param([IntPtr]$HJob, [UInt32]$LimitFlags)
  $info = New-ExtendedLimitInfo -LimitFlags $LimitFlags
  $len = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
  $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($len)
  try {
    [System.Runtime.InteropServices.Marshal]::StructureToPtr($info, $ptr, $false)
    return [HimmelCtl.JobNative]::SetInformationJobObject($HJob, $script:JobObjectExtendedLimitInformation, $ptr, $len)
  } finally {
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
  }
}

# CR fix: fail closed (see above) -- job setup failure exits NOW, before
# the wrapped command ever starts, rather than degrading to a weaker
# best-effort mode.
$hJob = [HimmelCtl.JobNative]::CreateJobObjectW([IntPtr]::Zero, $null)
if ($hJob -eq [IntPtr]::Zero) {
  [Console]::Error.WriteLine("job-run: CreateJobObjectW failed (GetLastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())) -- refusing to run without job-based tree-kill (fail-closed)")
  exit $JOB_SETUP_FAILED_EXIT_CODE
}
if (-not (Set-JobLimitFlags -HJob $hJob -LimitFlags $JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)) {
  [Console]::Error.WriteLine("job-run: SetInformationJobObject failed (GetLastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())) -- refusing to run without job-based tree-kill (fail-closed)")
  [HimmelCtl.JobNative]::CloseHandle($hJob) | Out-Null
  exit $JOB_SETUP_FAILED_EXIT_CODE
}

# BUG FOUND (empirically, during development): a bare command name (no
# path) given to .NET's ProcessStartInfo resolves via raw Win32
# CreateProcess search order, which checks %SystemRoot%\System32 BEFORE
# the PATH env var's own directories. On a machine with WSL installed,
# C:\Windows\System32\bash.exe (the WSL launcher stub) therefore wins over
# Git's bash.exe even though PATH itself lists Git's bash first --
# PowerShell's own Get-Command and Node's spawnSync both resolve correctly
# (Get-Command searches PATH directly; Node does its own PATH-order lookup
# rather than a raw CreateProcess search), so this is a
# ProcessStartInfo-specific trap. Resolved explicitly so "bash" always
# means the SAME bash.exe every other invocation in this codebase gets.
$resolvedCmd = (Get-Command $Command -All -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if (-not $resolvedCmd) {
  [Console]::Error.WriteLine("job-run: could not resolve command '$Command' on PATH")
  exit 1
}

$commandArgs = ConvertFrom-Base64Json -B64 $CommandArgsB64

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $resolvedCmd
$psi.Arguments = ConvertTo-WindowsArgString -ArgList $commandArgs
# CR: .NET's ProcessStartInfo does NOT default WorkingDirectory to the
# CALLING process's actual current directory when left unset (verified
# empirically -- a relative script-path CommandArg silently failed to
# resolve without this). Set explicitly to this script's own process cwd
# (which install-engine.js's spawnSync call inherits/sets normally).
$psi.WorkingDirectory = (Get-Location).Path
$psi.UseShellExecute = $false
if ($HasInput) {
  $psi.RedirectStandardInput = $true
}

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$proc.Start() | Out-Null
# CR: assigned to the job IMMEDIATELY, as the very next statement after
# Start() returns, to minimize (not eliminate) the window in which the
# child could spawn its own descendants before job membership is
# established. Every descendant this process (or anything IT spawns)
# creates from this point on automatically joins the SAME job (nested-job
# support).
#
# CR correction (CodeRabbit round 16, item 4 — a THIRD, independent senior
# review): CREATE_SUSPENDED was proposed (create the child suspended,
# AssignProcessToJobObject before it can execute or spawn anything, THEN
# ResumeThread) to close this window entirely — REJECTED after a genuine
# attempt/assessment, not skipped. The window is Start()->Assign(), the
# TWO adjacent statements right here — sub-millisecond. Exploiting it
# requires bash to fork a grandchild before its OWN image even finishes
# loading, AND this run to separately time out later, AND that grandchild
# to have re-parented by then: a compound, near-impossible race on an
# already-narrow path. The assignment-failure path below now tree-kills
# (taskkill /T /F, see below) — a real improvement over the Kill()-only
# shape, terminating every descendant still parented to the child — but
# NOT an airtight "never ran unprotected" invariant: /T walks parent-child
# LINKS, so a descendant that already re-parented away from the child
# before the kill still escapes. Honest residual ("narrowed, not closed"),
# not a closed guarantee.
# Against that theoretical, sub-ms-window improvement: implementing it
# means abandoning System.Diagnostics.Process entirely for raw
# CreateProcessW + hand-rolled STARTUPINFO/PROCESS_INFORMATION P/Invoke —
# which means hand-rolling the SAME handle-inheritance plumbing the
# stdin-only sudo-credential relay (-HasInput, below) currently gets for
# free from ProcessStartInfo.RedirectStandardInput. Getting anonymous-pipe
# handle inheritance flags wrong there is exactly the class of bug that
# leaks a credential or a stray handle to the child — trading a REAL
# security-invariant risk for a THEORETICAL sub-ms hardening improvement on
# a path that's already exceptional is a bad trade, full stop. The residual
# window is knowingly accepted; docs/setup/new-machine.md's own ensure
# section documents it honestly rather than overclaiming a guarantee this
# file doesn't fully provide. Do not re-litigate this without a concrete,
# demonstrated exploit — not a theoretical one — against the CURRENT
# fail-closed behavior.
#
# CR fix: fail closed (see above) -- unlike the pre-Start() setup failures,
# the process is ALREADY RUNNING here, so failing closed means killing it
# immediately rather than letting it continue unprotected.
$assigned = [HimmelCtl.JobNative]::AssignProcessToJobObject($hJob, $proc.Handle)
if (-not $assigned) {
  [Console]::Error.WriteLine("job-run: AssignProcessToJobObject failed (GetLastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())) -- killing the already-started process; refusing to continue without job-based tree-kill (fail-closed)")
  # CR fix (CodeRabbit round 19): $proc.Kill() alone (the previous sole
  # measure) terminates ONLY the direct child -- .NET's Process.Kill() is
  # NOT a tree operation -- so a descendant the child spawned in the
  # Start()->Assign() window would SURVIVE it (the overclaim corrected
  # above). taskkill /T /F walks the parent-child tree and force-terminates
  # every descendant it finds; $proc.Kill() stays as a FALLBACK if taskkill
  # is absent or itself errors. Best-effort throughout: a wrapped failure
  # cannot throw, and we exit fail-closed regardless. RESIDUAL (honest, not
  # airtight): /T follows parent-child LINKS, so a descendant that already
  # RE-PARENTED before this point is NOT reached and still escapes -- this
  # narrows the window substantially but does not fully close it (the Job
  # Object's structural kill, unavailable here because no process ever
  # joined the job, is the only thing that would). NOTE: Process.Kill($true)
  # (entireProcessTree) would be the obvious one-liner but is .NET Core 3.0+
  # only; this runs under Windows PowerShell 5.1 (.NET Framework), so
  # taskkill is the portable tree-kill.
  $treeKilled = $false
  try {
    & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $treeKilled = $true }
  } catch {}
  if (-not $treeKilled) {
    try { $proc.Kill() } catch {}
  }
  [HimmelCtl.JobNative]::CloseHandle($hJob) | Out-Null
  exit $JOB_SETUP_FAILED_EXIT_CODE
}

if ($HasInput) {
  # SECURITY: relayed VERBATIM from this script's OWN stdin -- Node piped
  # the credential directly into powershell.exe's stdin (the SAME `input:`
  # mechanism already used for the POSIX path), so it is read here as an
  # opaque byte stream and forwarded, never passed as -- or reconstructed
  # from -- a command-line argument anywhere in this file. See the file
  # header's "why stdin relay, not an argv payload" for what this replaced
  # and why.
  $inputText = [Console]::In.ReadToEnd()
  $proc.StandardInput.Write($inputText)
  $proc.StandardInput.Close()
}

# CR fix (codex critic, IMPORTANT): KILL_ON_JOB_CLOSE terminates every job
# member the instant the LAST handle to the job closes -- and this script
# only ever holds one handle, so CloseHandle() alone was enough to trigger
# it. That guarantee is exactly right on the TIMEOUT path (below) and
# exactly WRONG here: a Windows installer that legitimately starts a
# service/daemon/background helper (a perfectly normal thing for a package
# installer to do) would have that helper killed the instant a
# SUCCESSFUL install returned, just because our wrapper happened to be the
# one that launched it. Clear-JobKillOnClose strips the limit flag before
# the handle is released on ANY non-timeout path, so a surviving descendant
# is RELEASED, not killed -- while the timeout branch keeps the limit set
# and additionally calls TerminateJobObject explicitly (belt and suspenders:
# either mechanism alone would kill the tree on that path; combined, there's
# no gap even if one P/Invoke call unexpectedly no-ops).
function Clear-JobKillOnClose {
  param([IntPtr]$HJob)
  $cleared = Set-JobLimitFlags -HJob $HJob -LimitFlags 0
  if (-not $cleared) {
    [Console]::Error.WriteLine("job-run: failed to clear KILL_ON_JOB_CLOSE before releasing the job (GetLastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())) -- closing the handle anyway; a surviving descendant may be killed as a result")
  }
  # CR fix (codex round 17): the caller MUST know this failed -- see the
  # success branch's own comment for why a warning alone was not enough.
  return $cleared
}

# CR fix (CodeRabbit round 16, item 3 — Fable-confirmed FAIL-OPEN, the
# highest-value item this round): the PREVIOUS version of this catch block
# forced `$exited = $true` on ANY WaitForExit exception, reasoning
# (wrongly) that this was "fail-safe toward releasing the tree." It is the
# OPPOSITE: `$exited = $true` with `$timedOut` never touched (still its
# initial $false) sends control straight into the ELSE ("success") branch
# below, which CLEARS kill-on-close and releases the job -- while the
# wrapped command and its ENTIRE tree are, for all this script actually
# knows, still running. A WaitForExit exception is NOT evidence of
# completion; treating it as one left the process (and everything it
# spawned) running UNBOUNDED with neither a timeout nor job protection —
# fail-OPEN on the one path in this file that's supposed to fail closed
# like every other setup/wait failure here (see JOB_SETUP_FAILED_EXIT_CODE
# above). Fixed: on an exception, check $proc.HasExited. In the (narrow)
# case the process genuinely already exited by the time the exception
# unwound, fall through to the normal success path below unchanged. In
# every other case -- including HasExited itself throwing, treated the
# same fail-closed way -- this is now indistinguishable from a genuine
# timeout for cleanup purposes: terminate the job the SAME way the timeout
# branch does, but exit with the distinct $WAIT_FAILED_EXIT_CODE sentinel
# so install-engine.js can tell "genuinely timed out" apart from "couldn't
# confirm completion and killed defensively" if it ever needs to.
$timedOut = $false
$waitFailed = $false
try {
  $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
  $timedOut = -not $exited
} catch {
  [Console]::Error.WriteLine("job-run: WaitForExit threw: $_")
  $stillRunning = $true
  try {
    if ($proc.HasExited) { $stillRunning = $false }
  } catch {
    # HasExited itself threw -- can't confirm either way; fail closed
    # (treat as still running, same as the default above).
  }
  if ($stillRunning) {
    $waitFailed = $true
  } else {
    $exited = $true
  }
}

if ($timedOut -or $waitFailed) {
  # CR: the whole point -- terminate the JOB, not just the direct child.
  # Every process that joined it (the direct child AND every descendant it
  # spawned, regardless of whether an intermediate parent already exited
  # and "re-parented" it) dies here, unconditionally, in one call -- no
  # tree-walk, no re-parenting escape, no snapshot-timing race. The limit
  # flag set at job-creation time is left AS-IS here (still carrying
  # KILL_ON_JOB_CLOSE) -- TerminateJobObject already kills everyone
  # directly, and CloseHandle() right after is a no-op cleanup either way.
  # CR fix: the job is unconditionally available past this point -- setup
  # failure now exits earlier (fail-closed, see above) instead of leaving a
  # $jobObjectAvailable=$false path to guard against here.
  [HimmelCtl.JobNative]::TerminateJobObject($hJob, 1) | Out-Null
  [HimmelCtl.JobNative]::CloseHandle($hJob) | Out-Null
  # Belt-and-suspenders direct-child kill too (a no-op if TerminateJobObject
  # already took it down).
  try { $proc.Kill() } catch {}
  # CR fix (CodeRabbit round 16, item 3): a WaitForExit failure and a
  # genuine timeout get the SAME tree-kill treatment above, but a DISTINCT
  # exit code -- $waitFailed means "couldn't confirm completion, killed
  # defensively," not "genuinely ran past -TimeoutSeconds."
  if ($waitFailed) { exit $WAIT_FAILED_EXIT_CODE }
  exit $TIMEOUT_EXIT_CODE
} else {
  $code = 1
  try { $code = $proc.ExitCode } catch { $code = 1 }
  if ($code -ne 0) {
    # CR fix (MAJOR): a nonzero $code used to hit the SAME clear-and-release
    # path as success below -- KILL_ON_JOB_CLOSE got stripped even though the
    # wrapped command FAILED, so any descendant it left running (a partial
    # install's background helper, a daemon spawned before the failure) was
    # released to keep running unsupervised instead of being torn down along
    # with the failed install. A failed primitive gets no benefit of the
    # doubt: leave KILL_ON_JOB_CLOSE set (never call Clear-JobKillOnClose
    # here) so CloseHandle terminates every surviving descendant, exactly
    # like the timeout branch above -- then propagate the wrapped command's
    # ORIGINAL failure exit code unchanged (never a cleanup sentinel; there
    # is nothing to report here that CloseHandle itself could fail at, since
    # the limit flag is left untouched).
    [HimmelCtl.JobNative]::CloseHandle($hJob) | Out-Null
    exit $code
  }
  # CR fix (codex round 17 -- FAIL-OPEN, same class as round 16's
  # WaitForExit find): clearing KILL_ON_JOB_CLOSE is what lets a legitimate
  # background descendant (a service/daemon an install deliberately
  # launched) SURVIVE the CloseHandle below. When the clear FAILS the flag
  # is still set, so CloseHandle kills that whole surviving tree -- and the
  # previous version still exited with the wrapped command's own SUCCESS
  # code, so `ensure` reported green immediately after breaking the very
  # service it just installed. The stderr warning inside
  # Clear-JobKillOnClose was not enough: install-engine.js classifies this
  # spawn by EXIT CODE alone and never reads stderr.
  #
  # There is no way to avoid the kill once the clear has failed (letting
  # the handle leak does not help -- process exit closes it and triggers
  # kill-on-close all the same), so the honest move is to REPORT it: a
  # distinct sentinel, fail-closed, exactly like every other exceptional
  # path in this file. A successful wrapped command whose tree we may have
  # just killed is NOT a success. This clear-and-release path is reached
  # ONLY for a genuinely SUCCESSFUL wrapped command ($code -eq 0) -- see the
  # CR fix above for why a FAILED command takes the opposite branch instead.
  $cleared = Clear-JobKillOnClose -HJob $hJob
  [HimmelCtl.JobNative]::CloseHandle($hJob) | Out-Null
  if (-not $cleared) { exit $CLEANUP_FAILED_EXIT_CODE }
  exit $code
}
