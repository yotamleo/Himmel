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
$Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$Node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$Git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
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
[System.IO.File]::WriteAllText($CurlJs, 'require("fs").readFileSync(0,"utf8");console.log(process.env.BALANCE_RESPONSE||JSON.stringify({is_available:true,balance_infos:[{currency:"USD",total_balance:"50.00"}]}));process.exit(Number(process.env.CURL_EXIT||0));')
[System.IO.File]::WriteAllText($ClaudeJs, 'if(process.env.ANTHROPIC_BASE_URL!=="https://api.deepseek.com/anthropic"||process.env.ANTHROPIC_MODEL!=="sonnet"||process.env.ANTHROPIC_DEFAULT_SONNET_MODEL!=="deepseek-flash[1m]"||process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW!=="786432"||process.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS!=="786432")process.exit(9);')
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
# Temporary CI diagnosis of PowerShell null-to-string argument binding.
$ProbeName = 'HIMMEL_DEEPSEEK_NULL_BINDING_PROBE'
[Environment]::SetEnvironmentVariable($ProbeName, 'present', 'Process')
[Environment]::SetEnvironmentVariable($ProbeName, $null, 'Process')
Write-Host "Null argument leaves present=$([Environment]::GetEnvironmentVariables('Process').Contains($ProbeName)); pwsh=$($PSVersionTable.PSVersion); runtime=$([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
[Environment]::SetEnvironmentVariable($ProbeName, [NullString]::Value, 'Process')
Write-Host "NullString argument leaves present=$([Environment]::GetEnvironmentVariables('Process').Contains($ProbeName))"
# Fail before invoking the launcher unless ordinary native PATH resolution
# selects the fixture. A host's real curl must never service this smoke test.
$CurlMatches = @(Get-Command curl -CommandType Application -ErrorAction Stop)
if ($CurlMatches[0].Source -cne $args[1]) { throw 'Hermetic setup refused: curl did not resolve to the fixture' }
if ($args.Count -gt 2 -and $args[2] -cnotin $CurlMatches.Source) { throw 'Two-curl setup refused: decoy did not resolve as an application' }
& $args[0]
if ($LASTEXITCODE -ne 0) { throw 'Real launcher failed before environment assertion' }
foreach ($Name in @('HOME','DEEPSEEK_API_KEY','ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL_NAME','ANTHROPIC_DEFAULT_SONNET_MODEL_NAME','ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME','CLAUDE_CODE_SUBAGENT_MODEL','CLAUDE_CODE_AUTO_COMPACT_WINDOW','CLAUDE_CODE_MAX_CONTEXT_TOKENS','CLAUDE_CODE_EFFORT_LEVEL','CLAUDE_CODE_AUTO_MODE_SERVER','CLAUDE_CONFIG_DIR')) {
    $AfterEnv = [Environment]::GetEnvironmentVariables('Process')
    if ($AfterEnv.Contains($Name) -ne $Before.Contains($Name)) { throw ('Leaked launcher environment presence: ' + $Name) }
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
Write-Host "Fixture executables: node=$Node; git=$Git; pwsh=$Pwsh; curl=$ExpectedCurl"
$CurlProbe = Join-Path $Scratch 'curl-probe.ps1'
[System.IO.File]::WriteAllText($CurlProbe, @'
$ErrorActionPreference = 'Stop'
'fixture probe input' | & $args[0]
exit $LASTEXITCODE
'@)
$ProbeResult = Run-Clean $Pwsh @('-NoProfile','-File',$CurlProbe,$ExpectedCurl) $Extra
if ($ProbeResult.Code -ne 0 -or -not $ProbeResult.Output.Contains('"total_balance":"50.00"')) { throw "Curl fixture probe failed: $($ProbeResult.Code) $($ProbeResult.Output)" }
Write-Host 'Curl fixture probe returned a passing balance'
# HIMMEL-4099: passing curl JSON must reach the real launcher's balance log.
# This fails before seed-setting cases if the native pipeline corrupts JSON.
$Result = Run-Clean $Pwsh @('-NoProfile','-File',$Runner,$Launcher,$ExpectedCurl) $Extra
if ($Result.Code -ne 0 -or -not $Result.Output.Contains('balance=50.00 USD')) { throw "Passing balance refused by real launcher: $($Result.Code) $($Result.Output)" }
$Count++
# Restore pre-existing credentials and an explicitly empty routing value too.
$PreservedEnv = $Extra.Clone()
$PreservedEnv['ANTHROPIC_API_KEY'] = 'native-api-key'
$PreservedEnv['CLAUDE_CODE_AUTO_MODE_SERVER'] = ''
$Preserved = Run-Clean $Pwsh @('-NoProfile','-File',$Runner,$Launcher,$ExpectedCurl) $PreservedEnv
if ($Preserved.Code -ne 0 -or $Preserved.Output.Contains('ds-ps-hermetic-secret')) { throw "Pre-existing environment restoration failed: $($Preserved.Code) $($Preserved.Output)" }
$Count++
# A BOM-free pipeline must not weaken UNKNOWN, unavailable, or floor refusals.
foreach ($Response in @('not json','{}','null','{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"50.00"}]}','{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.99"}]}','{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"NaN"}]}')) {
    $RefusalEnv = $Extra.Clone()
    $RefusalEnv['BALANCE_RESPONSE'] = $Response
    $Refusal = Run-Clean $Pwsh @('-NoProfile','-File',$Launcher) $RefusalEnv
    if ($Refusal.Code -ne 5 -or -not $Refusal.Output.Contains('balance below floor, unavailable or UNKNOWN') -or $Refusal.Output.Contains('ds-ps-hermetic-secret')) { throw "Invalid balance was not refused safely: $Response $($Refusal.Code) $($Refusal.Output)" }
    $Count++
}
foreach ($Setting in @(@{ CURL_EXIT='99' }, @{ DEEPSEEK_MIN_BALANCE_USD='51' })) {
    $RefusalEnv = $Extra.Clone()
    foreach ($Name in $Setting.Keys) { $RefusalEnv[$Name] = $Setting[$Name] }
    $Refusal = Run-Clean $Pwsh @('-NoProfile','-File',$Launcher) $RefusalEnv
    if ($Refusal.Code -ne 5 -or -not $Refusal.Output.Contains('balance below floor, unavailable or UNKNOWN') -or $Refusal.Output.Contains('ds-ps-hermetic-secret')) { throw "Curl failure or custom floor was not refused safely: $($Refusal.Code) $($Refusal.Output)" }
    $Count++
}
$FloorEnv = $Extra.Clone()
$FloorEnv['BALANCE_RESPONSE'] = '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"3.00"}]}'
$FloorResult = Run-Clean $Pwsh @('-NoProfile','-File',$Runner,$Launcher,$ExpectedCurl) $FloorEnv
if ($FloorResult.Code -ne 0 -or -not $FloorResult.Output.Contains('balance=3.00 USD') -or $FloorResult.Output.Contains('ds-ps-hermetic-secret')) { throw "Exact balance floor refused: $($FloorResult.Code) $($FloorResult.Output)" }
$Count++
foreach ($Name in @('CLAUDE_LANE_SEED_LOCK_TIMEOUT','CLAUDE_LANE_SEED_LOCK_STALE')) {
    foreach ($Value in @('invalid','-1','1.5',' 1','2147483648')) {
        $InvalidEnv = $Extra.Clone()
        $InvalidEnv[$Name] = $Value
        $InvalidResult = Run-Clean $Pwsh @('-NoProfile','-File',$Launcher) $InvalidEnv
        if ($InvalidResult.Code -ne 4 -or $InvalidResult.Output.Contains('ds-ps-hermetic-secret')) { throw "Invalid seed setting did not exit 4: $Name $Value $($InvalidResult.Output)" }
        $Count++
    }
}
if ($Result.Code -ne 0 -or $Result.Output.Contains('ds-ps-hermetic-secret')) { throw "Same-process environment restoration failed: $($Result.Output)" }
$Count++
# HIMMEL-4096: a second native curl must not turn .Source into an array or
# displace the first PATH match. The decoy fails if the launcher selects it.
$DecoyBin = Join-Path $Scratch 'decoy-bin'
[System.IO.Directory]::CreateDirectory($DecoyBin) | Out-Null
$DecoyCurl = Join-Path $DecoyBin $(if ($IsWindows) { 'curl.cmd' } else { 'curl' })
if ($IsWindows) {
    [System.IO.File]::WriteAllText($DecoyCurl, "@echo off`r`necho DECOY_CURL_INVOKED 1>&2`r`nexit /b 99`r`n")
} else {
    [System.IO.File]::WriteAllText($DecoyCurl, "#!/bin/sh`nprintf 'DECOY_CURL_INVOKED\\n' >&2`nexit 99`n")
    & chmod +x $DecoyCurl
}
$ToolPath = $Bin + [System.IO.Path]::PathSeparator + $DecoyBin + [System.IO.Path]::PathSeparator + $OriginalToolPath
$Result = Run-Clean $Pwsh @('-NoProfile','-File',$Runner,$Launcher,$ExpectedCurl,$DecoyCurl) $Extra
$ToolPath = $OriginalToolPath
if ($Result.Code -ne 0 -or $Result.Output.Contains('DECOY_CURL_INVOKED') -or $Result.Output.Contains('ds-ps-hermetic-secret')) { throw "First curl on PATH was not used safely: $($Result.Output)" }
$Count++
# HIMMEL-4091: exercise the real shared PS mirror/lock without a network or
# model process. These cases run on pwsh hosts; Linux without pwsh skips them.
$MirrorRunner = Join-Path $Scratch 'mirror-seed.ps1'
$MirrorText = @'
param([string]$Scripts, [string]$Root, [string]$Case)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Scripts 'lane-mirror-seed.psm1') -Force
$homeDir = Join-Path $Root $Case
$src = Join-Path $homeDir '.claude'
$dir = Join-Path $homeDir '.claude-deepseek'
$nested = Join-Path $src 'hooks/sub/x.sh'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nested) | Out-Null
[System.IO.File]::WriteAllText($nested, 'old')
$source = Get-Content -LiteralPath (Join-Path $Scripts 'claude-deepseek.ps1') -Raw
$match = [regex]::Match($source, "(?s)\`$SanitizerJs = @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'Cannot find launcher sanitizer' }
$seed = @{HomeDir=$homeDir; ConfigDir=$dir; Lane='claude-deepseek'; SanitizerJs=$match.Groups[1].Value; Stamp=''; StampRequired=$false; LeafOnly=$false; LockTimeout=0; LockStale=1}
Copy-LaneSeedConfig $seed
if ($Case -eq 'nested') {
  $time = (Get-Item -LiteralPath $nested).LastWriteTimeUtc
  [System.IO.File]::WriteAllText($nested, 'new')
  (Get-Item -LiteralPath $nested).LastWriteTimeUtc = $time
  Invoke-LaneSeedWithLock $seed $false $null
  if ([System.IO.File]::ReadAllText((Join-Path $dir 'hooks/sub/x.sh')) -ne 'new') { throw 'Nested content remained stale' }
} else {
  $lock = "$dir.seed-lock"
  New-Item -ItemType Directory -Path $lock | Out-Null
  $ownerPid = if ($Case -eq 'dead') { 2147483647 } else { $PID }
  $birth = if ($Case -eq 'live') { (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks } else { 0 }
  [System.IO.File]::WriteAllText((Join-Path $lock 'owner'), "$ownerPid`nticks:$birth`n")
  (Get-Item -LiteralPath $lock).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
  Invoke-LaneSeedWithLock $seed $true $null
  if ($Case -eq 'live') { throw 'A live owner was stolen' }
  if (Test-Path -LiteralPath $lock) { throw 'Dead/recycled owner lock was not released' }
}
'@
[System.IO.File]::WriteAllText($MirrorRunner, $MirrorText)
foreach ($Case in 'nested', 'live', 'dead', 'recycled') {
    $Result = Run-Clean $Pwsh @('-NoProfile','-File',$MirrorRunner,$PSScriptRoot,$Scratch,$Case) @{}
    $Want = if ($Case -eq 'live') { 4 } else { 0 }
    if ($Result.Code -ne $Want) { throw "Shared PS seed $Case failed: $($Result.Code) $($Result.Output)" }
    if ($Case -eq 'live' -and -not (Test-Path -LiteralPath (Join-Path $Scratch 'live/.claude-deepseek.seed-lock/owner'))) { throw 'Live owner metadata was removed' }
    $Count++
}
Write-Host "$Count PowerShell smoke cases passed; scratch preserved at $Scratch"
