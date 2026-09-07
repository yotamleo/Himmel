# Hermetic fixture tests for foreground-window-log.ps1 (LUNA-131 Task 9,
# acceptance 2 / D16). Same shape as test-install-stack.ps1 / test-host-
# detectors.ps1: single pass line, `exit 1` on any failure, SKIP loud never
# silent.
#
# Extraction technique (mirrors test-install-stack.ps1 exactly): dot-source
# everything in foreground-window-log.ps1 ABOVE its "entry point" marker so
# the functions under test can never silently drift out of sync with a
# hand-copied duplicate.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# The logger is Win32-only (user32.dll via P/Invoke) -- SKIP loud on any
# non-Windows host rather than fail on a missing API.
$onWindows = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $onWindows = [bool]$IsWindows }
if (-not $onWindows) {
  Write-Host "SKIP all — foreground-window-log.ps1 requires Windows (user32.dll)"
  exit 0
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target = Join-Path $ScriptDir 'foreground-window-log.ps1'

$targetLines = Get-Content -LiteralPath $Target
$bodyStart = ($targetLines | Select-String -Pattern '^# ---- entry point' -List).LineNumber
if (-not $bodyStart) { throw "Could not find the entry-point marker in $Target -- extraction pattern is stale, update this test." }
$functionLines = $targetLines[0..($bodyStart - 2)]
$tempFunctionsFile = [System.IO.Path]::GetTempFileName() + '.ps1'
Set-Content -LiteralPath $tempFunctionsFile -Value $functionLines -Encoding utf8
try {
  . $tempFunctionsFile
} finally {
  Remove-Item -LiteralPath $tempFunctionsFile -Force -ErrorAction SilentlyContinue
}

$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

Write-Host "F1: consecutive identical window identities dedup to exactly one emitted change"
$changes = @()
$prev = $null
foreach ($key in @('A', 'A', 'A')) {
  if (Test-FocusChanged -PreviousKey $prev -CurrentKey $key) { $changes += $key }
  $prev = $key
}
Check 'exactly one change recorded across 3 identical polls' ($changes.Count -eq 1) "changes=$($changes -join ',')"

Write-Host "F1b: a genuinely different identity after identical repeats IS a change"
$changed2 = Test-FocusChanged -PreviousKey 'A' -CurrentKey 'B'
Check 'A -> B is reported as a change' ($changed2 -eq $true)

Write-Host "F2: emitted ts matches millisecond-precision ISO8601 (\.ddd Z)"
# Checked against the RAW JSON text, not a round-trip through
# ConvertFrom-Json: PowerShell 7's ConvertFrom-Json auto-detects
# ISO8601-looking strings and deserializes them into [datetime] objects,
# which would silently launder away the exact string format this test
# exists to pin (it's what actually lands in focus.jsonl on disk).
$line2 = Format-FocusRecord -ProcessId 1234 -Exe 'obsidian' -Title 'Vault' -Timestamp (Get-Date)
Check 'ts matches \.\d{3}Z$' ($line2 -match '"ts":"[^"]*\.\d{3}Z"') "line=$line2"

Write-Host "F3: a 200-char title truncates to exactly 80 chars"
$longTitle = 'x' * 200
$line3 = Format-FocusRecord -ProcessId 1 -Exe 'e' -Title $longTitle -Timestamp (Get-Date)
$obj3 = $line3 | ConvertFrom-Json
Check 'title truncated to 80 chars' ($obj3.title.Length -eq 80) "len=$($obj3.title.Length)"
Check 'a short title is left untouched' ((Format-FocusRecord -ProcessId 1 -Exe 'e' -Title 'short' -Timestamp (Get-Date) | ConvertFrom-Json).title -eq 'short')

Write-Host "F4: every emitted line is valid JSON with exactly the keys ts,pid,exe,title"
$line4 = Format-FocusRecord -ProcessId 42 -Exe 'notepad' -Title 'untitled' -Timestamp (Get-Date)
$parsed = $true
$obj4 = $null
try { $obj4 = $line4 | ConvertFrom-Json } catch { $parsed = $false }
Check 'line parses as JSON' $parsed
if ($parsed) {
  $keys = ($obj4.PSObject.Properties.Name | Sort-Object) -join ','
  Check 'keys are exactly ts,pid,exe,title' ($keys -eq 'exe,pid,title,ts') "keys=$keys"
}

Write-Host "F5: -DurationSeconds bounded run against a stub window source exits on its own and leaves a well-formed file"
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "focus-log-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$outFile = Join-Path $tmpDir 'focus.jsonl'
try {
  # Deterministic stub: alternates between two window identities on every
  # poll, so the loop sees a real sequence of changes without touching the
  # actual desktop. .GetNewClosure() so the captured $state survives being
  # invoked (via &) from inside Invoke-FocusPollLoop's own scope.
  $state = @{ Count = 0 }
  $stubSource = {
    $state.Count++
    $key = if ($state.Count % 2 -eq 1) { 'hwnd-A' } else { 'hwnd-B' }
    [pscustomobject]@{ Key = $key; Pid = 100; Exe = 'stub.exe'; Title = "window-$key" }
  }.GetNewClosure()

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Invoke-FocusPollLoop -OutFile $outFile -DurationSeconds 2 -PollIntervalSeconds 0.2 -WindowSource $stubSource
  $sw.Stop()

  Check 'the poll loop returned on its own within a bounded time' ($sw.Elapsed.TotalSeconds -lt 15) "elapsed=$($sw.Elapsed.TotalSeconds)"
  Check 'the output file exists' (Test-Path -LiteralPath $outFile)
  $fileLines = @(Get-Content -LiteralPath $outFile)
  Check 'at least one record was written' ($fileLines.Count -ge 1) "count=$($fileLines.Count)"
  $allValid = $true
  foreach ($l in $fileLines) {
    try { [void]($l | ConvertFrom-Json) } catch { $allValid = $false }
  }
  Check 'every line in the file is valid JSON' $allValid
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
