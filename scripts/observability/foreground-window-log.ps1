# LUNA-131 Task 9 (soak instrumentation, acceptance 2 / D16). A 1 Hz poller
# that appends one JSON line per FOREGROUND-WINDOW CHANGE (not per poll) to
# <StateDir>\focus.jsonl, so a later correlator (focus-tick-correlate.mjs)
# can test whether the vault sweeper's 10-minute tick coincides with focus
# loss more than chance predicts. `ts` carries millisecond precision because
# the correlation window is +/-3s.
#
# The polling logic is factored into pure, dot-sourceable functions
# (Format-FocusRecord, Test-FocusChanged, Get-ForegroundWindowInfo,
# Invoke-FocusPollLoop) so test-foreground-window-log.ps1 can exercise them
# directly, without a human alt-tabbing. See that file for the extraction
# technique (mirrors test-install-stack.ps1: dot-source everything above the
# "entry point" marker below).
#
# Run manually: pwsh -File scripts/observability/foreground-window-log.ps1
[CmdletBinding()]
param(
  [string]$StateDir = (Join-Path $env:USERPROFILE '.himmel\luna-sync'),
  [string]$OutFile,
  [int]$DurationSeconds = 0   # 0 = run until Ctrl-C
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---- Win32 P/Invoke for the foreground window + its owning process ---------
if (-not ('LunaFocusNative' -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class LunaFocusNative {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
}
"@
}

function Format-FocusRecord {
  # Builds the JSON line for one focus-change record from raw identity
  # fields + a timestamp. Pure: no I/O, no global state. Truncates the
  # title to 80 chars (F3).
  param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Exe,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
    [Parameter(Mandatory)][datetime]$Timestamp
  )
  $truncatedTitle = if ($Title.Length -gt 80) { $Title.Substring(0, 80) } else { $Title }
  $record = [ordered]@{
    ts    = $Timestamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    pid   = $ProcessId
    exe   = $Exe
    title = $truncatedTitle
  }
  return ($record | ConvertTo-Json -Compress)
}

function Test-FocusChanged {
  # Given the previous and current foreground-window identity (any
  # comparable key -- the poll loop uses a window-handle string), returns
  # whether this counts as a CHANGE worth emitting. $null previous key
  # means "nothing observed yet" -> always a change.
  param(
    $PreviousKey,
    $CurrentKey
  )
  return ($null -eq $PreviousKey) -or ($PreviousKey -ne $CurrentKey)
}

function Get-ForegroundWindowInfo {
  # Reads the CURRENT real foreground window via Win32 and returns its
  # identity as a pscustomobject (Key/Pid/Exe/Title), or $null if there is
  # no foreground window right now (e.g. secure desktop). This is the one
  # function with real OS I/O; Invoke-FocusPollLoop takes it as a swappable
  # -WindowSource so tests can stub it out (F5).
  $hwnd = [LunaFocusNative]::GetForegroundWindow()
  if ($hwnd -eq [IntPtr]::Zero) { return $null }
  [uint32]$procId = 0
  [void][LunaFocusNative]::GetWindowThreadProcessId($hwnd, [ref]$procId)
  $sb = New-Object System.Text.StringBuilder(512)
  [void][LunaFocusNative]::GetWindowText($hwnd, $sb, $sb.Capacity)
  $title = $sb.ToString()
  $exe = 'unknown'
  try {
    $proc = Get-Process -Id $procId -ErrorAction Stop
    $exe = $proc.ProcessName
  } catch {
    # Process gone between the two calls, or access denied -- 'unknown' is
    # an honest report, not a silent skip.
  }
  [pscustomobject]@{
    Key   = $hwnd.ToString()
    Pid   = [int]$procId
    Exe   = $exe
    Title = $title
  }
}

function Invoke-FocusPollLoop {
  # The imperative loop: poll -WindowSource at -PollIntervalSeconds, emit a
  # record via Format-FocusRecord only when Test-FocusChanged says the
  # foreground window changed, stop after -DurationSeconds (0 = forever).
  # -WindowSource defaults to the real Get-ForegroundWindowInfo but accepts
  # a stub scriptblock so tests can drive it deterministically (F5) without
  # touching the real desktop.
  param(
    [Parameter(Mandatory)][string]$OutFile,
    [double]$DurationSeconds = 0,
    [double]$PollIntervalSeconds = 1,
    [scriptblock]$WindowSource = (Get-Item Function:\Get-ForegroundWindowInfo).ScriptBlock
  )
  $outDir = Split-Path -Parent $OutFile
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $previousKey = $null
  $startTime = Get-Date
  while ($true) {
    $info = & $WindowSource
    if ($null -ne $info) {
      if (Test-FocusChanged -PreviousKey $previousKey -CurrentKey $info.Key) {
        $line = Format-FocusRecord -ProcessId $info.Pid -Exe $info.Exe -Title $info.Title -Timestamp (Get-Date)
        # utf8NoBOM, not utf8 (HIMMEL-1432): under Windows PowerShell 5.1 the
        # `utf8` encoding writes a BOM. focus.jsonl is consumed by Node
        # (focus-tick-correlate.mjs), whose readFileSync(...,'utf8') does NOT
        # strip a BOM -- JSON.parse would then throw on the first record and the
        # correlator's per-line skip would silently drop it.
        Add-Content -LiteralPath $OutFile -Value $line -Encoding utf8NoBOM
        $previousKey = $info.Key
      }
    }
    if ($DurationSeconds -gt 0 -and ((Get-Date) - $startTime).TotalSeconds -ge $DurationSeconds) {
      break
    }
    Start-Sleep -Seconds $PollIntervalSeconds
  }
}

# ---- entry point (body) ------------------------------------------------------
$resolvedOutFile = if ($OutFile) { $OutFile } else { Join-Path $StateDir 'focus.jsonl' }
Invoke-FocusPollLoop -OutFile $resolvedOutFile -DurationSeconds $DurationSeconds
