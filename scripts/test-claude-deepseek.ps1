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
    $Info.WorkingDirectory = Split-Path $PSScriptRoot -Parent
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
# Actual same-process invocation: fake executables are the network/model
# boundaries, while the real launcher must restore native routing afterwards.
$Bin = Join-Path $Scratch 'bin'
[System.IO.Directory]::CreateDirectory($Bin) | Out-Null
$CurlJs = Join-Path $Bin 'curl-mock.js'
$ClaudeJs = Join-Path $Bin 'claude-mock.js'
[System.IO.File]::WriteAllText($CurlJs, 'require("fs").readFileSync(0,"utf8");console.log(JSON.stringify({is_available:true,balance_infos:[{currency:"USD",total_balance:"50.00"}]}));')
[System.IO.File]::WriteAllText($ClaudeJs, 'if(process.env.ANTHROPIC_BASE_URL!=="https://api.deepseek.com/anthropic"||process.env.ANTHROPIC_MODEL!=="deepseek-flash[1m]")process.exit(9);')
if ($IsWindows) {
    [System.IO.File]::WriteAllText((Join-Path $Bin 'curl.cmd'), "@echo off`r`n`"$Node`" `"$CurlJs`" %*`r`n")
    [System.IO.File]::WriteAllText((Join-Path $Bin 'claude.cmd'), "@echo off`r`n`"$Node`" `"$ClaudeJs`" %*`r`n")
} else {
    [System.IO.File]::WriteAllText((Join-Path $Bin 'curl'), "#!/bin/sh`nexec `"$Node`" `"$CurlJs`" `"`$@`"`n")
    [System.IO.File]::WriteAllText((Join-Path $Bin 'claude'), "#!/bin/sh`nexec `"$Node`" `"$ClaudeJs`" `"`$@`"`n")
    & chmod +x (Join-Path $Bin 'curl') (Join-Path $Bin 'claude')
}
$Runner = Join-Path $Scratch 'same-process.ps1'
$RunnerText = @'
$Before = [Environment]::GetEnvironmentVariables('Process')
# Fail before invoking the launcher unless ordinary native PATH resolution
# selects the fixture. A host's real curl must never service this smoke test.
$SelectedCurl = Get-Command curl -CommandType Application -ErrorAction Stop
if ($SelectedCurl.Source -cne $args[1]) { throw 'Hermetic setup refused: curl did not resolve to the fixture' }
& $args[0]
if ($LASTEXITCODE -ne 0) { throw 'Real launcher failed before environment assertion' }
foreach ($Name in @('HOME','DEEPSEEK_API_KEY','ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL_NAME','ANTHROPIC_DEFAULT_SONNET_MODEL_NAME','ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME','CLAUDE_CODE_SUBAGENT_MODEL','CLAUDE_CODE_AUTO_COMPACT_WINDOW','CLAUDE_CODE_EFFORT_LEVEL','CLAUDE_CODE_AUTO_MODE_SERVER','CLAUDE_CONFIG_DIR')) {
    $After = [Environment]::GetEnvironmentVariable($Name,'Process')
    if ($After -cne $Before[$Name]) { throw ('Leaked launcher environment: ' + $Name) }
}
'@
[System.IO.File]::WriteAllText($Runner,$RunnerText)
$OriginalToolPath = $ToolPath
$ToolPath = $Bin + [System.IO.Path]::PathSeparator + $ToolPath
$Extra = @{ DEEPSEEK_API_KEY='ds-ps-hermetic-secret'; HIMMEL_DEEPSEEK_INFERENCE_OK='1'; CLAUDE_DEEPSEEK_DOTENV_ROOT=$Work; ANTHROPIC_BASE_URL='https://native.invalid'; ANTHROPIC_MODEL='native-model'; ANTHROPIC_AUTH_TOKEN='native-token'; CLAUDE_CONFIG_DIR='native-config' }
if ($IsWindows) { $Extra['PATHEXT'] = '.COM;.EXE;.BAT;.CMD' }
$ExpectedCurl = Join-Path $Bin $(if ($IsWindows) { 'curl.cmd' } else { 'curl' })
$Result = Run-Clean $Pwsh @('-NoProfile','-File',$Runner,$Launcher,$ExpectedCurl) $Extra
$ToolPath = $OriginalToolPath
if ($Result.Code -ne 0 -or $Result.Output.Contains('ds-ps-hermetic-secret')) { throw "Same-process environment restoration failed: $($Result.Output)" }
$Count++
Write-Host "$Count PowerShell smoke cases passed; scratch preserved at $Scratch"
