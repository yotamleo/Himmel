# ensure-qmd-daemon.ps1 - operator-facing MANUAL Windows twin of the qmd
# plugin's ensure script (HIMMEL-592).
#
# The SessionStart hook path is the bash script INSIDE the vendored plugin
# (marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh, wired via the
# plugin's hooks/hooks.json with ${CLAUDE_PLUGIN_ROOT}) - plugin hooks run
# bash on Windows too (Git Bash). This .ps1 is NOT wired as a hook; it is
# the manual tool for operators driving from PowerShell.
#
# Brings up the shared qmd HTTP MCP daemon on localhost:8181 if it is not
# already serving. Probes the endpoint with an MCP initialize POST, exits 0
# silently when a qmd daemon already answers, validates the reply is qmd-shaped
# (a foreign listener on 8181 fails loudly, never counts as alive), and
# otherwise starts one (idempotent) and waits for it to come alive.
#
# -WhatIf skips the daemon start (dry-run / syntax check).
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Url = $(if ($env:QMD_MCP_URL) { $env:QMD_MCP_URL } else { 'http://localhost:8181/mcp' }),
    # Daemon-start bound in seconds - mirrors the bash twin's QMD_START_TIMEOUT
    # env seam (param wins, env is the fallback).
    [int]$QmdStartTimeout = $(if ($env:QMD_START_TIMEOUT) { [int]$env:QMD_START_TIMEOUT } else { 20 })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InitPayload = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ensure-qmd-daemon","version":"1"}}}'

function Resolve-QmdBin {
    # Bun global bin FIRST, PATH second — parity with the plugin bash hook:
    # a broken Windows qmd stub can shadow PATH (HIMMEL-163), so the
    # known-good bun install wins when present.
    $bunExe = Join-Path $HOME '.bun\bin\qmd.exe'
    if (Test-Path $bunExe) { return $bunExe }
    $bunShim = Join-Path $HOME '.bun\bin\qmd'
    if (Test-Path $bunShim) { return $bunShim }
    $cmd = Get-Command qmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Returns 'alive' | 'foreign' | 'dead'.
function Test-QmdAlive {
    param([string]$ProbeUrl)
    try {
        $resp = Invoke-WebRequest -Uri $ProbeUrl -Method Post -Body $InitPayload `
            -ContentType 'application/json' `
            -Headers @{ 'Accept' = 'application/json, text/event-stream' } `
            -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        $body = [string]$resp.Content
    } catch {
        return 'dead'
    }
    # Scope the match to the serverInfo object (serverInfo.name == "qmd"), so
    # a foreign server whose reply merely contains a name:qmd pair elsewhere
    # (tool list, echoed fragment) does not falsely validate - parity with the
    # bash twin's is_qmd_shaped().
    if ($body -match '"serverInfo"\s*:\s*\{[^}]*"name"\s*:\s*"qmd"') { return 'alive' }
    return 'foreign'
}

$state = Test-QmdAlive -ProbeUrl $Url
if ($state -eq 'alive') { exit 0 }
if ($state -eq 'foreign') {
    Write-Error "ensure-qmd-daemon: a process is listening on $Url but it is NOT qmd (no qmd serverInfo in the MCP initialize reply). Port 8181 is taken by another service. Free it or stop that service, then start a fresh session."
    exit 1
}

# dead - start the daemon
$qmd = Resolve-QmdBin
if (-not $qmd) {
    Write-Error "ensure-qmd-daemon: qmd is not on PATH and no fallback at $HOME\.bun\bin\qmd.exe. Install it: bun add -g @tobilu/qmd"
    exit 1
}

if ($PSCmdlet.ShouldProcess($Url, 'start qmd mcp --http --daemon')) {
    # Bounded start (parity with the bash twin's timeout(1) wrap): a hung
    # qmd/bun start must not stall the caller indefinitely.
    $job = Start-Job -ScriptBlock { & $using:qmd mcp --http --daemon 2>&1 }
    if (Wait-Job $job -Timeout $QmdStartTimeout) {
        $startOut = Receive-Job $job -ErrorAction SilentlyContinue
        if ($startOut) { Write-Verbose ($startOut -join [Environment]::NewLine) }
        Remove-Job $job -Force
    } else {
        Stop-Job $job
        Remove-Job $job -Force
        Write-Error "ensure-qmd-daemon: 'qmd mcp --http --daemon' timed out after ${QmdStartTimeout}s (killed). Check the daemon log: $HOME\.cache\qmd\mcp.log"
        exit 1
    }
    for ($i = 0; $i -lt 5; $i++) {
        if ((Test-QmdAlive -ProbeUrl $Url) -eq 'alive') { exit 0 }
        Start-Sleep -Seconds 1
    }
    Write-Error "ensure-qmd-daemon: started 'qmd mcp --http --daemon' but nothing came alive on $Url. Check the daemon log: $HOME\.cache\qmd\mcp.log"
    exit 1
}
