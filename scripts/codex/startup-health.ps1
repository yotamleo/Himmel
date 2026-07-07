<#
.SYNOPSIS
  Surface a DEGRADED Codex CLI startup (HIMMEL-747) — twin of startup-health.sh.

.DESCRIPTION
  When himmel routes work to the Codex lane, a codex session can start degraded
  in ways that leave the lane LOOKING healthy: skills/plugin prompts silently
  truncated, lifecycle hooks silently ignored, or an oversized _where-are-we
  context injection. This read-only detector inspects the MOST-RECENT codex
  session's own logs and reports each signal it finds. See the .sh twin's header
  for the full grounding in the real ~/.codex log formats.

  Output: one `WARN <signal>: <detail>` line per finding.
  Exit:   0 = healthy   1 = finding(s)   2 = cannot read codex logs.
  Env:    CODEX_HOME (default ~/.codex)
          WHERE_ARE_WE_BUDGET_BYTES (default 8192)

  NON-FATAL by contract: callers treat any failure as "no signal".
#>
[CmdletBinding(PositionalBinding=$false)]
param()
$ErrorActionPreference = 'Stop'

# Read a file that may be held open by a live codex process (Windows locks it):
# open with FileShare ReadWrite, and return $null on any failure (non-fatal).
function Read-SharedBytes([string]$path) {
  try {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $ms = New-Object System.IO.MemoryStream
      $fs.CopyTo($ms)
      return $ms.ToArray()
    } finally { $fs.Dispose() }
  } catch { return $null }
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$budget    = if ($env:WHERE_ARE_WE_BUDGET_BYTES) { [int]$env:WHERE_ARE_WE_BUDGET_BYTES } else { 8192 }
$logdb     = Join-Path $codexHome 'logs_2.sqlite'
$sessions  = Join-Path $codexHome 'sessions'

if (-not (Test-Path -LiteralPath $logdb) -and -not (Test-Path -LiteralPath $sessions)) {
  [Console]::Error.WriteLine("startup-health: no codex logs under $codexHome (logs_2.sqlite / sessions absent)")
  exit 2
}

$findings = 0
function Emit([string]$signal, [string]$detail) {
  Write-Output "WARN ${signal}: ${detail}"
  $script:findings++
}

# Newest rollout session (lexical sort of ISO-timestamp-prefixed filenames).
$newest = $null
if (Test-Path -LiteralPath $sessions) {
  $newest = Get-ChildItem -LiteralPath $sessions -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -Last 1
}
$tid = $null
if ($newest) {
  $m = [regex]::Match($newest.Name, '-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$')
  if ($m.Success) { $tid = $m.Groups[1].Value }
}

# --- (a) skill/plugin prompt truncation + (b) lifecycle hook failure -----------
# logs_2.sqlite stores TEXT inline as UTF-8; extract printable runs (>=20 chars),
# keep those carrying the current session thread_id, count the WARN markers.
if ((Test-Path -LiteralPath $logdb) -and $tid) {
  $bytes = Read-SharedBytes $logdb
  # Latin1 = 1:1 byte->char, so [\x20-\x7E]{20,} isolates printable runs verbatim.
  $text  = if ($bytes) { [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes) } else { '' }
  $hookHits = 0; $skillHits = 0
  foreach ($run in [regex]::Matches($text, '[\x20-\x7E]{20,}')) {
    $r = $run.Value
    if ($r -notmatch [regex]::Escape($tid)) { continue }
    if ($r -match 'ignoring hooks') { $hookHits++ }
    if ($r -match 'ignoring interface\.defaultPrompt|prompt must be at most|maximum of [0-9]+ prompts') { $skillHits++ }
  }
  if ($hookHits -gt 0) {
    Emit 'hook-failure' "codex ignored a lifecycle hooks block in the current session (codex_core_plugins::manifest 'ignoring hooks') — SessionStart/UserPromptSubmit/Stop hooks may not be running"
  }
  if ($skillHits -gt 0) {
    Emit 'skill-truncation' "codex truncated $skillHits skill/plugin prompt field(s) in the current session (codex_core_plugins::manifest 'defaultPrompt ... at most N chars / maximum of N prompts') — skill content silently dropped"
  }
}

# --- (c) oversized _where-are-we context injection -----------------------------
if ($newest) {
  $maxBytes = 0
  # Recurse every JSON string leaf; track the largest that carries the header.
  function Walk($node) {
    if ($null -eq $node) { return }
    if ($node -is [string]) {
      if ($node -like '*# Where are we*') {
        $b = [System.Text.Encoding]::UTF8.GetByteCount($node)
        if ($b -gt $script:maxBytes) { $script:maxBytes = $b }
      }
      return
    }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
      foreach ($item in $node) { Walk $item }
      return
    }
    if ($node -is [psobject] -and $node.PSObject.Properties) {
      foreach ($p in $node.PSObject.Properties) { Walk $p.Value }
    }
  }
  $script:maxBytes = 0
  $jb = Read-SharedBytes $newest.FullName
  $jtext = if ($jb) { [System.Text.Encoding]::UTF8.GetString($jb) } else { '' }
  foreach ($line in ($jtext -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $obj = $line | ConvertFrom-Json } catch { continue }
    Walk $obj
  }
  if ($script:maxBytes -gt $budget) {
    Emit 'where-are-we-oversized' "the _where-are-we context injected into the most recent codex session is $($script:maxBytes) bytes (budget $budget)"
  }
}

if ($findings -gt 0) { exit 1 }
exit 0
