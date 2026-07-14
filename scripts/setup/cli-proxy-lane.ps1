#Requires -Version 5.1
<#
.SYNOPSIS
  Bring up the CLIProxyAPI codex lane (cc-codex) on a Windows HOST.

.DESCRIPTION
  The proxy is a HOST process on 127.0.0.1:8317. ONE instance per host serves
  that host's launchers (bash + .ps1) AND that host's WSL (via mirrored
  networking). Do NOT run this inside WSL. cc-glm needs no proxy (direct to z.ai).

  Per-host order:  -Install  ->  -Login (once)  ->  -Start  ->  -Register
  Run with no switch for a status report + the next command to run.

.PARAMETER Install   Download the CLIProxyAPI binary + write config.yaml if missing.
.PARAMETER Login     One-time codex OAuth via device-code flow (no local browser needed).
.PARAMETER Start     Start the proxy in the foreground (Ctrl-C to stop).
.PARAMETER Register  Register a logon scheduled task so the proxy restarts at each sign-in.
.PARAMETER Verify    Curl the running proxy.

.EXAMPLE
  # win1 (OAuth already present): start, then persist across boot
  .\cli-proxy-lane.ps1 -Start
  .\cli-proxy-lane.ps1 -Register

.EXAMPLE
  # win2 (fresh host): one-time login, start, persist
  .\cli-proxy-lane.ps1 -Login
  .\cli-proxy-lane.ps1 -Start
  .\cli-proxy-lane.ps1 -Register
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Login,
    [switch]$Start,
    [switch]$Register,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'

$Dir     = Join-Path $HOME '.cli-proxy-api'
$Exe     = Join-Path $Dir 'cli-proxy-api.exe'
$Cfg     = Join-Path $Dir 'config.yaml'
$ApiKey  = 'himmel-local-claudex'   # local proxy token; must match config.yaml api-keys
$Port    = 8317
$Version = '7.2.77'
$Release = "https://github.com/router-for-me/CLIProxyAPI/releases/download/v$Version/CLIProxyAPI_${Version}_windows_amd64.zip"

function Test-OAuth {
    (Test-Path $Dir) -and @(Get-ChildItem $Dir -Filter 'codex-*.json' -ErrorAction SilentlyContinue).Count -gt 0
}
function Get-ProxyCode {
    # Authenticated HTTP probe (not just a port check): an unrelated listener on
    # $Port would pass a bare TCP test but not answer /v1/models.
    curl.exe -sk -H "Authorization: Bearer $ApiKey" "http://127.0.0.1:$Port/v1/models" -o NUL -w '%{http_code}' 2>$null
}
function Test-Running {
    # 200 = up + our key accepted; 401 = up but key rejected (still the proxy speaking HTTP).
    $c = Get-ProxyCode
    ($c -eq '200') -or ($c -eq '401')
}
function Assert-Exe {
    if (-not (Test-Path $Exe)) { throw "binary missing at $Exe - run with -Install first" }
}
function Assert-Config {
    if (-not (Test-Path $Cfg)) { throw "config missing at $Cfg - run with -Install first" }
}

if ($Install) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    if (-not (Test-Path $Exe)) {
        # Unique per-run temp paths; cleanup in finally so a failed download/extract
        # leaves no orphaned artifacts. Trust boundary = pinned HTTPS release URL
        # (operator-accepted, HIMMEL-979); upstream publishes no per-asset checksum.
        $stamp = [guid]::NewGuid().ToString('N')
        $zip = Join-Path $env:TEMP "cliproxy-$stamp.zip"
        $tmp = Join-Path $env:TEMP "cliproxy-$stamp"
        try {
            Write-Host "downloading CLIProxyAPI v$Version ..."
            Invoke-WebRequest -Uri $Release -OutFile $zip
            Expand-Archive -Force $zip $tmp
            $src = Get-ChildItem -Recurse $tmp -Filter 'cli-proxy-api.exe' | Select-Object -First 1 -ExpandProperty FullName
            if (-not $src) { throw "cli-proxy-api.exe not found in release archive" }
            Copy-Item $src $Exe -Force
            Write-Host "installed binary: $Exe"
        } finally {
            Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "binary already present: $Exe"
    }
    if (-not (Test-Path $Cfg)) {
        # host 127.0.0.1 ONLY: the default empty host binds ALL interfaces, which
        # would LAN-expose the OAuth-wrapped subscription endpoint.
        $yaml = @"
host: "127.0.0.1"
port: $Port
auth-dir: "~/.cli-proxy-api"
api-keys:
  - "$ApiKey"
"@
        [System.IO.File]::WriteAllText($Cfg, $yaml, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "wrote config: $Cfg"
    } else {
        Write-Host "config already present: $Cfg"
    }
}

if ($Login) {
    Assert-Exe; Assert-Config
    Write-Host "codex device-login: open the printed URL on any browser, enter the code,"
    Write-Host "and sign in with your codex / ChatGPT account. Writes ~/.cli-proxy-api/codex-<email>.json."
    # -config is required even for login: the binary reads it to locate auth-dir,
    # and defaults to .\config.yaml (cwd) when omitted -> fails outside ~/.cli-proxy-api.
    & $Exe -config $Cfg -codex-device-login
    # PowerShell 5.1 does not stop on a native non-zero exit; surface it.
    if ($LASTEXITCODE -ne 0) { throw "codex device-login failed (exit $LASTEXITCODE)" }
}

if ($Register) {
    Assert-Exe; Assert-Config
    # Windowless logon task so no console pops on every sign-in.
    $tr = "powershell -NoProfile -WindowStyle Hidden -Command `"& '$Exe' -config '$Cfg'`""
    schtasks /create /tn 'cli-proxy-api' /sc onlogon /rl limited /f /tr $tr | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /create failed (exit $LASTEXITCODE) - run elevated if it is a permissions error" }
    Write-Host "registered logon task 'cli-proxy-api' (runs the proxy at sign-in)"
    # Start it now too (windowless) so -Register brings the proxy up immediately,
    # not only at the next sign-in. -Start is foreground and dies with the terminal.
    schtasks /run /tn 'cli-proxy-api' | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "started 'cli-proxy-api' now (windowless background)" }
    else { Write-Warning "task registered but immediate /run failed (exit $LASTEXITCODE) - it will still start at next sign-in" }
}

if ($Start) {
    Assert-Exe; Assert-Config
    if (-not (Test-OAuth)) { Write-Warning "no codex OAuth found - cc-codex will 401 until you run -Login" }
    Write-Host "starting proxy on 127.0.0.1:$Port (Ctrl-C to stop) ..."
    & $Exe -config $Cfg
    if ($LASTEXITCODE -ne 0) { throw "proxy exited with error (exit $LASTEXITCODE)" }
}

if ($Verify) {
    $code = Get-ProxyCode
    Write-Host "proxy http://127.0.0.1:$Port -> HTTP $code  (200/401 = reachable; 000 = not running)"
}

if (-not ($Install -or $Login -or $Start -or $Register -or $Verify)) {
    Write-Host "== CLIProxyAPI codex lane (HOST-only; serves this host + its WSL via 127.0.0.1:$Port) =="
    $hasExe = Test-Path $Exe
    $hasCfg = Test-Path $Cfg
    $hasOA  = Test-OAuth
    $run    = Test-Running
    "{0,-12} {1}" -f 'binary:',    $(if ($hasExe) { "OK   $Exe" }              else { 'MISSING  -> -Install' })
    "{0,-12} {1}" -f 'config:',    $(if ($hasCfg) { "OK   $Cfg" }              else { 'MISSING  -> -Install' })
    "{0,-12} {1}" -f 'codex auth:',$(if ($hasOA)  { 'OK' }                     else { 'MISSING  -> -Login' })
    "{0,-12} {1}" -f 'running:',   $(if ($run)    { "OK   127.0.0.1:$Port" }   else { 'no       -> -Start (then -Register to restart at sign-in)' })
    Write-Host ''
    if (-not $hasExe -or -not $hasCfg) { Write-Host 'NEXT: .\cli-proxy-lane.ps1 -Install' }
    elseif (-not $hasOA)               { Write-Host 'NEXT: .\cli-proxy-lane.ps1 -Login   (then -Start, then -Register)' }
    elseif (-not $run)                 { Write-Host 'NEXT: .\cli-proxy-lane.ps1 -Start   (and -Register to restart at sign-in)' }
    else                               { Write-Host 'lane is up. Test: bash $HOME/Documents/github/himmel/scripts/claude-codex -p "reply OK"' }
}
