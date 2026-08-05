<#
.SYNOPSIS
  Push-to-talk: speak, get the transcript on the clipboard.

.DESCRIPTION
  Thin wrapper over push-to-talk.py so it is one word to invoke. Records from
  the MOTU physical jack (never the loopback default), transcribes locally with
  whisper.cpp, and sets the clipboard.

.EXAMPLE
  .\ptt.ps1
  .\ptt.ps1 -Device "Microphone (Logitech BRIO)"
#>
[CmdletBinding()]
param(
    [string]$Device,
    [string]$Language,
    [int]$MaxSeconds
)

$ErrorActionPreference = 'Stop'
$py = Join-Path $HOME '.himmel\voice\venv\Scripts\python.exe'
$script = Join-Path $PSScriptRoot 'push-to-talk.py'

if (-not (Test-Path $py))     { throw "voice venv missing at $py" }
if (-not (Test-Path $script)) { throw "push-to-talk.py missing at $script" }

if ($Device)     { $env:MIC_DEVICE   = $Device }
if ($Language)   { $env:MIC_LANG     = $Language }
if ($MaxSeconds) { $env:MIC_MAX_SECS = "$MaxSeconds" }

# stdout is the transcript; progress goes to stderr, so this stays pipeable.
& $py $script
exit $LASTEXITCODE
