<#
.SYNOPSIS
  Enumerate the EFFECTIVE Codex hook set on Windows and lint (or replay) it
  for the pwsh-runner traps (HIMMEL-1982).

.DESCRIPTION
  codex-cli on Windows runs every hook command as
  `pwsh.exe -NoProfile -Command "<command>"` (live-proven, codex-cli 0.149.0).
  Two traps follow from that: (1) a command starting with bare `bash` resolves
  via the MACHINE PATH to the WSL launcher stub at
  C:\Windows\System32\bash.exe (Git\usr\bin is only on the USER PATH, which
  comes later) — when WSL is wedged the hook hangs to Codex's default 600s
  hook timeout; (2) a command that STARTS with a quoted path (a quoted .cmd,
  or a `${CLAUDE_PLUGIN_ROOT}`-substituted path) is parsed by pwsh as a
  string EXPRESSION, not a command invocation -> ParserError -> exit 1. The
  fix differs per trap: bare-bash needs a PATH-QUALIFIED Git Bash exe
  (`& "C:\Program Files\Git\bin\bash.exe" <rest>` — a bare leading `& ` alone
  still resolves `bash` via PATH to the same WSL stub); quoted-path-start
  just needs a leading `& ` (the executable is already a full path; `&`
  makes pwsh invoke it instead of parsing it as a string expression).

  This script collects the hook set Codex would ACTUALLY run for -Project:
    (a) <CodexHome>/hooks.json                          (source: global)
    (b) <Project>/.codex/hooks.json                      (source: project)
    (c) the Codex hook file of every plugin enabled in
        <CodexHome>/config.toml ([plugins."name@market"] with the next
        `enabled = true` line)                           (source: plugin:<name>)
        resolved the way Codex resolves it: <root>/.codex-plugin/plugin.json's
        `hooks` field when that manifest exists (an absent/empty value means
        the plugin registers no Codex hooks and is skipped), else the
        hooks/hooks.json convention. See Resolve-PluginHooksFile.
  `${CLAUDE_PLUGIN_ROOT}` / `$CLAUDE_PLUGIN_ROOT` in plugin hook commands is
  substituted with the resolved plugin root (Codex does this before running
  pwsh). `$CLAUDE_PROJECT_DIR` is left verbatim — Codex does NOT substitute
  it, so under pwsh it expands to an empty PS variable (a known himmel-ops
  inertness; reported as INFO, not FAIL).

  Static lint (default) never runs a hook. -Replay ACTUALLY EXECUTES every
  hook exactly like Codex would (pwsh -Command <cmd>, real stdin, real PATH)
  — side effects included. Use it only against hooks you trust; never against
  the real ~/.codex security-guidance / rtk-hook-guard hooks (they hang on a
  wedged WSL, per the trap above) unless you know they're clean. Replay is
  matcher-aware: each hook gets a synthetic tool_name derived from its own
  matcher (first literal alternative, e.g. `Edit|Write` -> Edit; absent/.*/*
  -> Bash) with a tool_input shape appropriate to that tool, and per-event
  fields matching the empirical Codex matrix (docs/internals/harness-compat.md)
  — Codex itself only ever fires Bash/apply_patch, but the probe lints the
  WRITTEN matcher, so replaying the matched tool is the honest fidelity check.

.PARAMETER CodexHome
  Codex home dir. Default $env:CODEX_HOME or ~/.codex.
.PARAMETER Project
  Project dir whose .codex/hooks.json is the project layer. Default cwd.
.PARAMETER Replay
  Switch. Actually execute each hook (see WARNING above). Default is static
  lint only.
.PARAMETER Arm
  PATH arm used during -Replay: 'native' (registry Machine PATH + ';' + User
  PATH, the default) or 'gitbash' (C:\Program Files\Git\bin prepended).
.PARAMETER TimeoutSec
  Per-hook replay timeout in seconds. Default 20.
.PARAMETER NoFail
  Always exit 0, even if FAIL findings exist. For installer advisory use.
.PARAMETER Json
  Optional path to dump the full result set as JSON.

.EXAMPLE
  pwsh -NoProfile -File scripts\codex\probe-codex-hooks.ps1
  # static lint of the effective hook set for the current project

.EXAMPLE
  pwsh -NoProfile -File scripts\codex\probe-codex-hooks.ps1 -Project C:\repo -NoFail
  # advisory lint (installer phase 4), never fails the run

.EXAMPLE
  pwsh -NoProfile -File scripts\codex\probe-codex-hooks.ps1 -Replay -Arm gitbash -TimeoutSec 10
  # WARNING: executes every effective hook for real
#>
[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = '',
  [string]$Project = '',
  [switch]$Replay,
  [ValidateSet('native','gitbash')]
  [string]$Arm = 'native',
  [int]$TimeoutSec = 20,
  [switch]$NoFail,
  [string]$Json = ''
)
$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $CodexHome) { $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' } }
if (-not $Project)   { $Project = (Get-Location).Path }

# --- collect hook rows from one hooks.json -----------------------------------
function Get-HookRows([string]$HooksJsonPath, [string]$Source, [string]$PluginRoot) {
  $rows = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $HooksJsonPath)) { return ,$rows }
  try {
    $json = Get-Content -LiteralPath $HooksJsonPath -Raw | ConvertFrom-Json
  } catch {
    Write-Warning "SKIP (parse): $HooksJsonPath - $($_.Exception.Message)"
    return ,$rows
  }
  if (-not $json.hooks) { return ,$rows }
  foreach ($evProp in $json.hooks.PSObject.Properties) {
    $event = $evProp.Name
    foreach ($block in $evProp.Value) {
      $matcher = if ($block.PSObject.Properties.Name -contains 'matcher') { [string]$block.matcher } else { '' }
      foreach ($h in $block.hooks) {
        # Codex's HookHandlerConfig has commandWindows (alias command_windows);
        # on Windows that command runs INSTEAD of command when present.
        $via = 'command'
        if ($h.PSObject.Properties.Name -contains 'commandWindows' -and $h.commandWindows) {
          $via = 'commandWindows'
        } elseif ($h.PSObject.Properties.Name -contains 'command_windows' -and $h.command_windows) {
          $via = 'command_windows'
        }
        $cmd = [string]$h.$via
        if ($PluginRoot) {
          $cmd = $cmd.Replace('${CLAUDE_PLUGIN_ROOT}', $PluginRoot).Replace('$CLAUDE_PLUGIN_ROOT', $PluginRoot)
        }
        $timeout = if ($h.PSObject.Properties.Name -contains 'timeout') { $h.timeout } else { $null }
        $rows.Add([pscustomobject]@{
          source  = $Source
          event   = $event
          matcher = $matcher
          command = $cmd
          via     = $via
          timeout = $timeout
          root    = $PluginRoot
        })
      }
    }
  }
  return ,$rows
}

# --- minimal TOML scan: [plugins."name@market"] tables enabled = true --------
function Get-EnabledPlugins([string]$ConfigTomlPath) {
  $result = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $ConfigTomlPath)) { return ,$result }
  $lines = Get-Content -LiteralPath $ConfigTomlPath
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\[plugins\."([^@"]+)@([^"]+)"\]\s*$') {
      $name = $Matches[1]; $marketplace = $Matches[2]
      # scan to the next top-level table header (or EOF); the FIRST `enabled =`
      # line found in that span wins (comments/other keys before it don't count).
      $isEnabled = $false
      for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -notmatch '^\['; $j++) {
        if ($lines[$j] -match '^\s*enabled\s*=\s*(true|false)\s*(#.*)?$') {
          $isEnabled = ($Matches[1] -eq 'true')
          break
        }
      }
      if ($isEnabled) {
        $result.Add([pscustomobject]@{ name = $name; marketplace = $marketplace })
      }
    }
  }
  return ,$result
}

function Resolve-PluginRoot([string]$CodexHome, [string]$Marketplace, [string]$Name) {
  $dir = Join-Path $CodexHome "plugins/cache/$Marketplace/$Name"
  if (-not (Test-Path -LiteralPath $dir)) { return $null }
  $versions = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)
  if ($versions.Count -eq 0) { return $null }
  # Prefer real version-number ordering (1.10.0 > 1.2.0) when every dir name
  # parses as a [version]; fall back to lexical sort for non-numeric names.
  $parsed = New-Object System.Collections.Generic.List[object]
  foreach ($v in $versions) {
    $ver = $null
    if ([System.Version]::TryParse($v.Name.TrimStart('v'), [ref]$ver)) {
      $parsed.Add([pscustomobject]@{ item = $v; ver = $ver })
    }
  }
  if ($parsed.Count -eq $versions.Count) {
    return @($parsed | Sort-Object ver)[-1].item.FullName
  }
  return @($versions | Sort-Object Name)[-1].FullName
}

# Which file holds a plugin's CODEX hook set (HIMMEL-2001). Codex consults the
# plugin's Codex-specific manifest <root>/.codex-plugin/plugin.json first: its
# "hooks" field names the file, and an absent/empty value means the plugin
# registers NO Codex hooks. Only a plugin that ships no .codex-plugin manifest
# falls back to the hooks/hooks.json convention (himmel-ops, security-guidance,
# hookify, warp all resolve that way). Confirmed against Codex's own trust
# ledger in config.toml: manifest-less plugins get
# `<name>@<mkt>:hooks/hooks.json:<event>:i:j` keys, while superpowers — whose
# 6.1.1 manifest declares "hooks": {} — has no hooks/hooks.json key at all.
# Hardcoding hooks/hooks.json made the probe lint (and FAIL on) a Claude-side
# file Codex never loads. Returns $null when the plugin contributes no hooks.
# A non-string "hooks" value carrying inline config is not a file and is not
# linted here.
function Resolve-PluginHooksFile([string]$Root) {
  $manifest = Join-Path $Root '.codex-plugin/plugin.json'
  if (-not (Test-Path -LiteralPath $manifest)) {
    return (Join-Path $Root 'hooks/hooks.json')
  }
  try {
    $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
  } catch {
    Write-Warning "SKIP (parse): $manifest - $($_.Exception.Message)"
    return $null
  }
  $declared = $m.hooks
  if (($declared -is [string]) -and $declared.Trim()) {
    return (Join-Path $Root ($declared -replace '^\./', ''))
  }
  return $null
}

# --- static lint --------------------------------------------------------------
# "bash"/"sh" invoked as a program (not as a filename substring, e.g. NOT
# "run-hook-with-bash.js" or "sg-python.sh"): preceded by start/whitespace/
# quote/&/path-separator, followed by (optional .exe then) quote/whitespace/end.
$script:BashInvokeRegex = '(?i)(^|[\s"&\\/])(bash|sh)(\.exe)?(?=["\s]|$)'

# Bare-bash still resolves via PATH to the WSL launcher even behind a call
# operator (`& bash ...`) or wrapped in quotes that hold ONLY the bare word
# (`& "bash" ...`) — those are PATH-resolved, not path-qualified. A real path
# (`& "C:\...\bash.exe" ...`, `./bash ...`) is the fix shape and must stay clean.
# Returns the command's remainder past the bash invocation, or $null if the
# command isn't a bare-bash invocation.
function Get-BareBashRest([string]$cmd) {
  $t = $cmd -replace '^\s*&\s+', ''
  if ($t -match '^\s*"bash(\.exe)?"(\s*)(.*)$') { return $Matches[3] }
  if ($t -match "^\s*'bash(\.exe)?'(\s*)(.*)$") { return $Matches[3] }
  if ($t -match '^\s*bash(\.exe)?(?=\s|$)(\s*)(.*)$') { return $Matches[3] }
  return $null
}

function Get-Findings($cmd, $timeout) {
  $findings = New-Object System.Collections.Generic.List[string]
  if ($null -ne (Get-BareBashRest $cmd)) { $findings.Add('FAIL:bare-bash') }
  if ($cmd -match "^\s*['`"]") { $findings.Add('FAIL:quoted-path-start') }
  if (($cmd -match $script:BashInvokeRegex) -and (-not $timeout)) { $findings.Add('WARN:no-timeout-bash') }
  if ($cmd.Contains('$CLAUDE_PROJECT_DIR')) { $findings.Add('INFO:claude-project-dir') }
  return $findings
}

function Get-Rewrite($cmd, $kind) {
  switch ($kind) {
    'FAIL:bare-bash' {
      $rest = Get-BareBashRest $cmd
      if ($null -ne $rest) { return '& "C:\Program Files\Git\bin\bash.exe" ' + $rest }
      return $null
    }
    'FAIL:quoted-path-start' { return '& ' + $cmd }
    default { return $null }
  }
}

# --- build the effective row set ----------------------------------------------
$rows = New-Object System.Collections.Generic.List[object]
$rows.AddRange((Get-HookRows (Join-Path $CodexHome 'hooks.json') 'global' $null))
$rows.AddRange((Get-HookRows (Join-Path $Project '.codex/hooks.json') 'project' $null))
foreach ($p in (Get-EnabledPlugins (Join-Path $CodexHome 'config.toml'))) {
  $root = Resolve-PluginRoot $CodexHome $p.marketplace $p.name
  if (-not $root) { continue }
  $hooksFile = Resolve-PluginHooksFile $root
  if (-not $hooksFile) { continue }
  $rows.AddRange((Get-HookRows $hooksFile "plugin:$($p.name)" $root))
}

# --- lint + print table --------------------------------------------------------
$failCount = 0; $warnCount = 0; $infoCount = 0
$lintResults = New-Object System.Collections.Generic.List[object]
Write-Host ("{0,-12} {1,-18} {2,-55} {3}" -f 'SOURCE','EVENT','COMMAND (head)','FINDINGS')
Write-Host ("-" * 12 + " " + "-" * 18 + " " + "-" * 55 + " " + "-" * 20)
foreach ($r in $rows) {
  $findings = Get-Findings $r.command $r.timeout
  foreach ($f in $findings) {
    if ($f -like 'FAIL:*') { $failCount++ }
    elseif ($f -like 'WARN:*') { $warnCount++ }
    elseif ($f -like 'INFO:*') { $infoCount++ }
  }
  $head = ($r.command -replace '\s+',' ')
  if ($head.Length -gt 55) { $head = $head.Substring(0,52) + '...' }
  if ($r.via -ne 'command') { $head = $head + " [via=$($r.via)]" }
  $findingText = if ($findings.Count -gt 0) { $findings -join ',' } else { '-' }
  Write-Host ("{0,-12} {1,-18} {2,-55} {3}" -f $r.source, $r.event, $head, $findingText)
  $lintResults.Add([pscustomobject]@{
    source   = $r.source
    event    = $r.event
    matcher  = $r.matcher
    command  = $r.command
    via      = $r.via
    timeout  = $r.timeout
    root     = $r.root
    findings = $findings
  })
}

Write-Host ""
Write-Host ("SUMMARY: {0} hooks, {1} FAIL, {2} WARN, {3} INFO" -f $rows.Count, $failCount, $warnCount, $infoCount)

$hasFailRewrite = $false
foreach ($lr in $lintResults) {
  foreach ($f in $lr.findings) {
    if ($f -eq 'FAIL:bare-bash' -or $f -eq 'FAIL:quoted-path-start') {
      if (-not $hasFailRewrite) { Write-Host ""; Write-Host "Recommended rewrites:"; $hasFailRewrite = $true }
      $rewrite = Get-Rewrite $lr.command $f
      Write-Host ("  [{0}/{1}] {2}" -f $lr.source, $lr.event, $f)
      Write-Host ("    was : {0}" -f $lr.command)
      Write-Host ("    use : {0}" -f $rewrite)
    }
  }
}

# --- optional replay ------------------------------------------------------------
$replayResults = $null
if ($Replay) {
  if ($TimeoutSec -le 0) {
    # WaitForExit(<=0*1000) misbehaves (0/negative ms -> a wedged hook can run
    # indefinitely instead of being killed); clamp to the documented default.
    Write-Warning "TimeoutSec $TimeoutSec is <= 0; clamping to 20s"
    $TimeoutSec = 20
  }
  Write-Host ""
  Write-Host "REPLAY: executing every hook above for real (arm=$Arm, timeout=${TimeoutSec}s)"
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  $pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { 'C:\Program Files\PowerShell\7\pwsh.exe' }

  $nativePath = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
  $armPath = if ($Arm -eq 'gitbash') { 'C:\Program Files\Git\bin;' + $nativePath } else { $nativePath }

  # matcher -> synthetic tool_name: first literal alternative (Edit|Write -> Edit);
  # absent/.*/* -> Bash (himmel's own hooks never see anything else under Codex,
  # but replaying the WRITTEN matcher is the honest fidelity check).
  function Get-MatchedToolName([string]$matcher) {
    if (-not $matcher -or $matcher -eq '.*' -or $matcher -eq '*') { return 'Bash' }
    $first = ($matcher -split '\|')[0].Trim()
    if (-not $first -or $first -eq '.*' -or $first -eq '*') { return 'Bash' }
    return $first
  }

  function Get-ToolInput([string]$ToolName) {
    switch ($ToolName) {
      { $_ -in @('Edit','Write','MultiEdit','NotebookEdit','Read') } { return '{"file_path":"probe.txt"}' }
      'Grep'  { return '{"pattern":"ok"}' }
      'Skill' { return '{"skill_name":"probe"}' }
      'Agent' { return '{"description":"probe"}' }
      default { return '{"command":"echo ok"}' }
    }
  }

  # field set per event matches the empirical matrix recorded in
  # docs/internals/harness-compat.md (event/tool-name table, HIMMEL-1982 probe).
  function Get-HookPayload([string]$Event, [string]$Project, [string]$ToolName) {
    $cwdj = $Project.Replace('\','/')
    $base = '"session_id":"probe","transcript_path":"","cwd":"' + $cwdj + '"'
    switch ($Event) {
      'SessionStart'     { return '{' + $base + ',"hook_event_name":"SessionStart","source":"startup","model":"probe-model","permission_mode":"default"}' }
      'PreToolUse'       { return '{' + $base + ',"hook_event_name":"PreToolUse","tool_use_id":"probe-1","tool_name":"' + $ToolName + '","tool_input":' + (Get-ToolInput $ToolName) + '}' }
      'PostToolUse'      { return '{' + $base + ',"hook_event_name":"PostToolUse","tool_use_id":"probe-1","tool_name":"' + $ToolName + '","tool_input":' + (Get-ToolInput $ToolName) + ',"tool_response":{"ok":true}}' }
      'UserPromptSubmit' { return '{' + $base + ',"hook_event_name":"UserPromptSubmit","prompt":"reply with the single word ok"}' }
      'Stop'             { return '{' + $base + ',"hook_event_name":"Stop","last_assistant_message":"ok","stop_hook_active":false}' }
      'SessionEnd'       { return '{' + $base + ',"hook_event_name":"SessionEnd","reason":"exit"}' }
      default            { return '{' + $base + ',"hook_event_name":"' + $Event + '"}' }
    }
  }

  $replayResults = New-Object System.Collections.Generic.List[object]
  Write-Host ("{0,-12} {1,-18} {2,-8} {3,6} {4}" -f 'SOURCE','EVENT','RESULT','SECS','STDERR (head)')
  foreach ($r in $rows) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    $psi.ArgumentList.Add('-NoProfile'); $psi.ArgumentList.Add('-Command'); $psi.ArgumentList.Add($r.command)
    $psi.WorkingDirectory = $Project
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    foreach ($k in @($psi.Environment.Keys)) { if ($k -like 'CLAUDE*') { [void]$psi.Environment.Remove($k) } }
    $psi.Environment['PATH'] = $armPath
    if ($r.root) { $psi.Environment['CLAUDE_PLUGIN_ROOT'] = $r.root }

    $toolName = Get-MatchedToolName $r.matcher
    $payload = Get-HookPayload $r.event $Project $toolName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if ($p.WaitForExit($TimeoutSec * 1000)) { $rc = $p.ExitCode } else { try { $p.Kill($true) } catch {}; $rc = 'TIMEOUT' }
    $sw.Stop()
    [void][System.Threading.Tasks.Task]::WaitAll(@($so,$se), 5000)
    $stderr = if ($se.IsCompleted) { $se.Result } else { '' }
    $stderr1 = ($stderr -replace '\s+',' ')
    if ($stderr1.Length -gt 200) { $stderr1 = $stderr1.Substring(0,200) }
    $tag = if ($rc -eq 'TIMEOUT') { 'TIMEOUT' } elseif ($rc -eq 0) { 'ok' } else { "rc=$rc" }
    $secs = [math]::Round($sw.Elapsed.TotalSeconds,2)
    Write-Host ("{0,-12} {1,-18} {2,-8} {3,6} {4}" -f $r.source, $r.event, $tag, $secs, $stderr1)
    $replayResults.Add([pscustomobject]@{ source=$r.source; event=$r.event; command=$r.command; result=$tag; seconds=$secs; stderrHead=$stderr1 })
  }
}

# --- optional JSON dump ---------------------------------------------------------
if ($Json) {
  $dump = [pscustomobject]@{
    codexHome = $CodexHome
    project   = $Project
    arm       = $Arm
    replay    = [bool]$Replay
    rows      = $lintResults
    replayResults = $replayResults
    summary   = [pscustomobject]@{ total = $rows.Count; fail = $failCount; warn = $warnCount; info = $infoCount }
  }
  $dump | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Json -Encoding utf8
}

if ($NoFail) { exit 0 }
if ($failCount -gt 0) { exit 1 } else { exit 0 }
