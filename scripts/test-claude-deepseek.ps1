#Requires -Version 7
# Hermetic PS smoke tests (HIMMEL-4084). No network: launch cases must stop at
# egress; seed cases execute the twin's actual JS against scratch JSON.
# Full bash contract and JS parity complement these platform-specific cases.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Launcher = Join-Path $PSScriptRoot 'claude-deepseek.ps1'
$Source = Get-Content -LiteralPath $Launcher -Raw
$SeedMatch = [regex]::Match($Source, "(?s)\`$SeedJs = @'\r?\n(.*?)\r?\n'@")
if (-not $SeedMatch.Success) { throw 'Cannot find actual twin seed predicate' }
$SeedJs = $SeedMatch.Groups[1].Value
$Scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('deepseek-ps-test-' + [Guid]::NewGuid().ToString('N'))
$HomeDir = Join-Path $Scratch 'home'
$Work = Join-Path $Scratch 'work'
[System.IO.Directory]::CreateDirectory($HomeDir) | Out-Null
[System.IO.Directory]::CreateDirectory($Work) | Out-Null
$Pwsh = (Get-Command pwsh).Source
$Node = (Get-Command node).Source
$Git = (Get-Command git).Source
$ToolPath = ((Split-Path $Node -Parent),(Split-Path $Git -Parent),[Environment]::GetEnvironmentVariable('SystemRoot')) -join [System.IO.Path]::PathSeparator
function Run-Clean([string]$Exe, [string[]]$Argv, [hashtable]$Extra) {
    $Info = [System.Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Exe
    $Info.UseShellExecute = $false
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.WorkingDirectory = $Work
    foreach ($Arg in $Argv) { $Info.ArgumentList.Add($Arg) }
    $Info.Environment.Clear()
    $Info.Environment['HOME'] = $HomeDir
    $Info.Environment['USERPROFILE'] = $HomeDir
    $Info.Environment['PATH'] = $ToolPath
    if ($IsWindows) { $Info.Environment['SystemRoot'] = [Environment]::GetEnvironmentVariable('SystemRoot') }
    foreach ($Name in $Extra.Keys) { $Info.Environment[$Name] = $Extra[$Name] }
    $Process = [System.Diagnostics.Process]::Start($Info)
    $Out = $Process.StandardOutput.ReadToEndAsync()
    $Err = $Process.StandardError.ReadToEndAsync()
    $Process.WaitForExit()
    return @{ Code=$Process.ExitCode; Output=$Out.Result + $Err.Result }
}
$Count = 0
foreach ($Flag in @('', '0', 'true', '1 ')) {
    $EnvVars = @{ DEEPSEEK_API_KEY='ds-ps-hermetic-secret'; CLAUDE_DEEPSEEK_CWD=(Split-Path $PSScriptRoot -Parent); CLAUDE_DEEPSEEK_DOTENV_ROOT=$Work }
    if ($Flag) { $EnvVars['HIMMEL_DEEPSEEK_INFERENCE_OK'] = $Flag }
    $Result = Run-Clean $Pwsh @('-NoProfile','-File',$Launcher) $EnvVars
    if ($Result.Code -ne 3 -or $Result.Output.Contains('ds-ps-hermetic-secret')) { throw "Station flag refusal failed: $($Result.Code) $($Result.Output)" }
    $Count++
}
[System.IO.File]::WriteAllText((Join-Path $Work '.env'), "DEEPSEEK_API_KEY=ds-ps-hermetic-secret`nHIMMEL_DEEPSEEK_INFERENCE_OK=1`n")
$Result = Run-Clean $Pwsh @('-NoProfile','-File',$Launcher) @{ CLAUDE_DEEPSEEK_CWD=(Split-Path $PSScriptRoot -Parent); CLAUDE_DEEPSEEK_DOTENV_ROOT=$Work }
if ($Result.Code -ne 3 -or $Result.Output.Contains('ds-ps-hermetic-secret')) { throw 'Dotenv-only opt-in did not refuse safely' }
$Count++
$Config = Join-Path $HomeDir '.claude.json'
$Primary = Split-Path $PSScriptRoot -Parent
[System.IO.File]::WriteAllText($Config,'{"keep":42,"projects":{}}')
$Result = Run-Clean $Node @('-e',$SeedJs,$Config,$Primary) @{}
if ($Result.Code -ne 0) { throw "Seed failed: $($Result.Output)" }
$First = [System.IO.File]::ReadAllText($Config)
$Json = $First | ConvertFrom-Json -AsHashtable
if ($Json.keep -ne 42 -or $Json.hasCompletedOnboarding -ne $true -or $Json.projects[$Primary].hasTrustDialogAccepted -ne $true) { throw 'Seed did not preserve unrelated fields and add trust' }
$Result = Run-Clean $Node @('-e',$SeedJs,$Config,$Primary) @{}
if ($Result.Code -ne 0 -or [System.IO.File]::ReadAllText($Config) -ne $First) { throw 'Seed is not idempotent' }
$Count++
[System.IO.File]::WriteAllText($Config,'{malformed')
$Result = Run-Clean $Node @('-e',$SeedJs,$Config,$Primary) @{}
if ($Result.Code -ne 4 -or [System.IO.File]::ReadAllText($Config) -ne '{malformed') { throw 'Malformed config was not refused unmodified' }
$Count++
Write-Host "$Count PowerShell smoke cases passed; scratch preserved at $Scratch"
