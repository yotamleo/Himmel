#requires -Version 5.1
<#
.SYNOPSIS
  Offload a task prompt to a fresh local Warp terminal tab running `warp agent run`.

.DESCRIPTION
  Writes an ephemeral Warp Launch Configuration YAML and a PowerShell launcher script,
  then opens `warp://launch/<name>` so Warp spawns a new tab and executes the launcher.
  The launcher invokes `warp agent run --prompt <text>` with the prompt loaded from
  a tempfile (sidesteps YAML/PowerShell quoting issues for prompts with quotes,
  newlines, or backticks). Launcher exits when the agent returns so Warp can close
  the tab automatically (when "Close tab on shell exit" is enabled in Warp settings).

  Fire-and-forget: returns immediately after dispatching the URL handler. No PID,
  no exit code, no output captured back from the offloaded tab.

  Self-prunes any `oz-offload-*.yaml` configs and matching launcher/prompt
  tempfiles older than 72h on each invocation.

.PARAMETER Prompt
  The task description handed to the Warp agent. Mutually exclusive with -PromptFile.

.PARAMETER PromptFile
  Path to a file containing the task description. Read with -Raw, then deleted.
  Use this from the slash command to bypass shell quoting issues with prompts
  that contain quotes, newlines, or backticks. Mutually exclusive with -Prompt.

.PARAMETER Cwd
  Absolute working directory for the new tab. Defaults to the current location.

.EXAMPLE
  scripts\oz\offload.ps1 -Prompt "Summarize the architecture of this repo"

.EXAMPLE
  scripts\oz\offload.ps1 -PromptFile C:\Users\me\AppData\Local\Temp\my-task.txt
#>
[CmdletBinding(DefaultParameterSetName = 'Inline')]
param(
  [Parameter(ParameterSetName = 'Inline', Mandatory = $true, Position = 0)]
  [string]$Prompt,

  [Parameter(ParameterSetName = 'File', Mandatory = $true)]
  [string]$PromptFile,

  [string]$Cwd = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($env:APPDATA)) {
  throw "APPDATA env var is empty — cannot locate Warp launch_configurations dir."
}
if ([string]::IsNullOrEmpty($env:TEMP)) {
  throw "TEMP env var is empty — cannot create tempfile dir."
}

function Resolve-WarpExe {
  $roots = @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { -not [string]::IsNullOrEmpty($_) }
  $subpaths = @('Programs\Warp\warp.exe', 'Warp\warp.exe')
  foreach ($root in $roots) {
    foreach ($sub in $subpaths) {
      $p = Join-Path $root $sub
      if (Test-Path -LiteralPath $p) { return $p }
    }
  }
  $cmd = Get-Command warp.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "warp.exe not found in standard install locations or PATH. Install Warp or fix the path."
}

$warpExe   = Resolve-WarpExe
$configDir = Join-Path $env:APPDATA 'warp\Warp\data\launch_configurations'
$tempDir   = Join-Path $env:TEMP   'oz-offload'

foreach ($d in @($configDir, $tempDir)) {
  if (-not (Test-Path -LiteralPath $d)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
}

# Read prompt from file when -PromptFile given (bypasses shell quoting).
if ($PSCmdlet.ParameterSetName -eq 'File') {
  if (-not (Test-Path -LiteralPath $PromptFile)) {
    throw "PromptFile not found: $PromptFile"
  }
  $Prompt = Get-Content -LiteralPath $PromptFile -Raw
  Remove-Item -LiteralPath $PromptFile -Force -ErrorAction SilentlyContinue
}

# Prune stale configs + tempfiles (>72h). 72h headroom in case a queued tab
# only consumes its prompt long after dispatch (e.g. operator left laptop closed).
$cutoff = (Get-Date).AddHours(-72)
Get-ChildItem -LiteralPath $configDir -Filter 'oz-offload-*.yaml' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt $cutoff } |
  Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt $cutoff } |
  Remove-Item -Force -ErrorAction SilentlyContinue

$timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$uuid       = [guid]::NewGuid().ToString('N').Substring(0, 8)
$slug       = "oz-offload-$timestamp-$uuid"
$configPath = Join-Path $configDir "$slug.yaml"
$promptPath = Join-Path $tempDir   "$slug.prompt.txt"
$launchPath = Join-Path $tempDir   "$slug.launcher.ps1"

$absCwd = (Resolve-Path -LiteralPath $Cwd).Path

[System.IO.File]::WriteAllText($promptPath, $Prompt, [System.Text.UTF8Encoding]::new($false))

# Escape single quotes for PowerShell single-quoted string literals in the
# launcher template (handles paths with `'`, which is legal on Windows).
function Escape-PSSingleQuoted([string]$s) { $s.Replace("'", "''") }

$promptPathPS = Escape-PSSingleQuoted $promptPath
$warpExePS    = Escape-PSSingleQuoted $warpExe

$launcher = @"
`$prompt = Get-Content -LiteralPath '$promptPathPS' -Raw
& '$warpExePS' agent run --prompt `$prompt
exit
"@
Set-Content -LiteralPath $launchPath -Value $launcher -Encoding UTF8

# Quote YAML scalars to defend against `#` (comment), `:` (mapping), and other
# YAML-special characters in paths. Escape embedded `"` and `\` per YAML
# double-quoted scalar rules.
function Quote-YamlDouble([string]$s) {
  '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"'
}

$cwdYaml      = Quote-YamlDouble $absCwd
$titleYaml    = Quote-YamlDouble "oz-offload $timestamp"
# Chain `; exit` so the OUTER tab shell exits after the launcher returns —
# Warp closes the tab automatically when "Close tab on shell exit" is on.
# The launcher's own `exit` only ends the inner PowerShell subprocess.
$execCommand  = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$launchPath`"; exit"
$execYaml     = Quote-YamlDouble $execCommand

$yaml = @"
---
name: $slug
windows:
  - tabs:
      - title: $titleYaml
        layout:
          cwd: $cwdYaml
          commands:
            - exec: $execYaml
"@
Set-Content -LiteralPath $configPath -Value $yaml -Encoding UTF8

try {
  Start-Process -FilePath $warpExe -ArgumentList "warp://launch/$slug" -ErrorAction Stop | Out-Null
}
catch {
  throw "warp.exe failed to launch warp://launch/$slug — $_"
}

[pscustomobject]@{
  Status      = 'dispatched'
  Config      = $slug
  ConfigPath  = $configPath
  Cwd         = $absCwd
  PromptFile  = $promptPath
} | Format-List
