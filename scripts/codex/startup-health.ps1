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
# Every finding here is about the codex CLI alone (the HIMMEL-1104 convention).
$scopeNote = "Scope: the codex CLI only — claudex / cc-glm / hermes are separate surfaces and are NOT implicated by this finding."

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

# Name the codex plugin-cache hooks.json files carrying a root-level
# `description`. Deterministic JSON key test — no log parsing, no sqlite.
#
# These are CANDIDATES, never proof: codex's "ignoring hooks" row carries NO
# path, so the failing manifest CANNOT be correlated to a cache file. A scan hit
# never licenses declaring a lane safe — every branch fails CLOSED; only a
# himmel-owned hit escalates. Mirrors the .sh twin.
# ONE scan yields BOTH results, so status can never drift from contents:
#   .Offenders — paths carrying a root-level `description`
#   .Scan      — 'ok' | 'incomplete'  (anything that could not be enumerated,
#                read, or parsed makes it incomplete — never a clean "none
#                found", which would assert a fact never checked).
function Get-DescScan {
  $cache = Join-Path $codexHome 'plugins/cache'
  $res = [pscustomobject]@{ Offenders = @(); Scan = 'ok' }
  if (-not (Test-Path -LiteralPath $cache)) { $res.Scan = 'incomplete'; return $res }
  $files = @()
  try { $files = @(Get-ChildItem -LiteralPath $cache -Recurse -Filter 'hooks.json' -File -ErrorAction Stop) }
  catch { $res.Scan = 'incomplete'; return $res }
  foreach ($f in $files) {
    $b = Read-SharedBytes $f.FullName
    if (-not $b) { $res.Scan = 'incomplete'; continue }   # unreadable -> cannot judge
    try { $o = [System.Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json }
    catch { $res.Scan = 'incomplete'; continue }          # unparseable -> cannot judge
    # -ccontains, NOT -contains: PowerShell comparisons are case-INSENSITIVE by
    # default, so -contains would flag a `Description` key that jq's
    # has("description") in the .sh twin ignores. codex's serde field matching is
    # case-sensitive too, so only the exact lowercase key is the real field.
    if ($o.PSObject.Properties.Name -ccontains 'description') { $res.Offenders += $f.FullName }
  }
  return $res
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
    # HIMMEL-1104: LOAD path only. The identical "ignoring hooks" text is also
    # emitted by list_tool_suggest_discoverable_plugins — a marketplace
    # SUGGESTION scan over NON-INSTALLED plugins that discards the parsed hooks.
    # Matching the bare string reported a healthy session as DEGRADED.
    if ($r -match 'load_plugins_from_layer_stack: ignoring hooks') { $hookHits++ }
    if ($r -match 'ignoring interface\.defaultPrompt|prompt must be at most|maximum of [0-9]+ prompts') { $skillHits++ }
  }
  if ($hookHits -gt 0) {
    # Split by BLAST RADIUS. A dropped hooks block is per-plugin isolated, so an
    # upstream offender never implies himmel's guardrails are off.
    $scan = Get-DescScan
    $himmelHit = @(); $upstreamHit = @()
    foreach ($f in $scan.Offenders) {
      $rel = ($f -replace '^.*[\\/]plugins[\\/]cache[\\/]', '') -replace '\\', '/'
      if ($rel -match '^(himmel|qmd)/') { $himmelHit += $rel } else { $upstreamHit += $rel }
    }
    $upgradeNote = "Most likely fix: upgrade codex to >= rust-v0.143.0, which accepts a root-level 'description' (upstream PR #30229)."
    $scanNote = if ($scan.Scan -ne 'ok') { " NOTE: the cache scan was INCOMPLETE (a hooks.json could not be enumerated, read, or parsed), so candidates may be missing." } else { '' }
    if ($himmelHit.Count -gt 0) {
      Emit 'hook-failure' "codex CLI ($codexHome) dropped a lifecycle hooks block, and a HIMMEL-OWNED plugin carries the root-level 'description' that triggers it — $($himmelHit -join ' ') — GUARDRAILS MAY BE OFF, do not route work to the codex CLI lane until fixed. $upgradeNote $scopeNote$scanNote"
    } elseif ($upstreamHit.Count -gt 0) {
      Emit 'hook-failure' "codex CLI ($codexHome) dropped a lifecycle hooks block. Upstream cache candidate(s) carrying a root-level 'description': $($upstreamHit -join ' '). The log row names NO path, so this is NOT correlated to the failing manifest — himmel's guardrails are NOT proven unaffected. Do not route to the codex CLI lane until ownership is confirmed. $upgradeNote $scopeNote$scanNote"
    } elseif ($scan.Scan -ne 'ok') {
      Emit 'hook-failure' "codex CLI ($codexHome) dropped a lifecycle hooks block (codex_core_plugins::manifest 'load_plugins_from_layer_stack: ignoring hooks'), and the plugin cache could NOT be scanned (no cache dir, or an unreadable/unparseable hooks.json) — offender unidentified. Do not route to the codex CLI lane until confirmed. $scopeNote"
    } else {
      Emit 'hook-failure' "codex CLI ($codexHome) dropped a lifecycle hooks block (codex_core_plugins::manifest 'load_plugins_from_layer_stack: ignoring hooks'), but no plugin-cache hooks.json carries a root-level 'description' — cause unidentified, inspect $codexHome/plugins/cache/**/hooks.json by hand. Do not route to the codex CLI lane until confirmed. $scopeNote"
    }
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

# --- (d) himmel plugin registration (HIMMEL-1145) -----------------------------
# (a)-(c) all read what codex LOGGED. A codex that lost the himmel marketplace +
# plugin registration loads nothing, parses no manifest, and so logs nothing: every
# check above reads healthy while every himmel guardrail is absent. Assert
# PRESENCE instead — a deterministic read of $codexHome/config.toml, no log parsing.
# Mirrors the .sh twin (see its comments for the full reasoning).
#
# The expected set is DATA, shared with install-himmel-codex
# (himmel-plugin-set.conf) — never restated here. Only the `default` set is
# required; `-All` extras are opt-in. Per-plugin, not all-or-nothing.
# ponytail: only the table-header form codex itself writes ([marketplaces.X],
# [plugins."name@X"] + `enabled = true`) is parsed; a hand-written dotted-key or
# inline-table config reads as unregistered (fail closed). A registered
# marketplace whose `source` path has gone stale is not checked either. Multiline
# strings are skipped by delimiter parity only: a quote escaped next to a
# triple-quote can desync it.
$pluginSetFile = Join-Path $PSScriptRoot 'himmel-plugin-set.conf'
function Get-PluginSetField([string]$key) {
  $b = Read-SharedBytes $pluginSetFile
  if (-not $b) { return '' }
  foreach ($line in ([System.Text.Encoding]::UTF8.GetString($b) -split "`r?`n")) {
    if ($line -match "^$([regex]::Escape($key)):\s*(.*?)\s*$") { return $Matches[1] }
  }
  return ''
}
# Registered marketplaces + enabled plugin ids from config.toml. Comparisons are
# -c (case-SENSITIVE) like the .sh twin's awk/grep: TOML keys are case-sensitive.
function Get-ConfigState([string]$cfgPath) {
  $b = Read-SharedBytes $cfgPath
  if (-not $b) { return $null }
  $res = [pscustomobject]@{ Markets = @(); Enabled = @() }
  $cur = ''
  $text = [System.Text.Encoding]::UTF8.GetString($b).TrimStart([char]0xFEFF)
  # $ml = the open TOML multiline-string delimiter (triple double or single quote), or
  # '' outside one: lines inside it are text, never headers or `enabled`. Tracked by
  # delimiter parity per line, like the .sh twin.
  $ml = ''
  foreach ($line in ($text -split "`r?`n")) {
    if ($ml -ne '') {
      if (([regex]::Matches($line, [regex]::Escape($ml))).Count % 2 -eq 1) { $ml = '' }
      continue
    }
    if ($line -match '^\s*\[') {
      $s = $line -replace '^\s*\[', ''
      $s = $s -replace '\][ \t]*(#.*)?$', ''
      $s = $s -replace '["\s]', ''
      $cur = $s
      if ($s -clike 'marketplaces.*') { $res.Markets += $s.Substring(13) }
    } elseif (($cur -clike 'plugins.*') -and ($line -cmatch '^\s*enabled\s*=\s*true\s*(#.*)?$')) { $res.Enabled += $cur.Substring(8) }
    if (([regex]::Matches($line, '"""')).Count % 2 -eq 1) { $ml = '"""' }
    elseif (([regex]::Matches($line, "'''")).Count % 2 -eq 1) { $ml = "'''" }
  }
  return $res
}

$wantMarket  = Get-PluginSetField 'marketplace'
$wantPlugins = @((Get-PluginSetField 'default') -split '\s+' | Where-Object { $_ })
if (-not $wantMarket -or $wantPlugins.Count -eq 0) {
  # Cannot say what to look for -> cannot say it is present. Never a silent pass.
  Emit 'plugin-presence-unchecked' "codex CLI ($codexHome): cannot read the expected himmel plugin set from $pluginSetFile (missing, unreadable, or empty) — plugin registration NOT verified, so himmel's guardrails may not be loaded. $scopeNote"
} else {
  $cfg = Join-Path $codexHome 'config.toml'
  $state = Get-ConfigState $cfg
  $cfgNote = ''
  if ($null -eq $state) { $state = [pscustomobject]@{ Markets = @(); Enabled = @() }; $cfgNote = " $cfg is missing or unreadable." }
  $marketMissing = -not ($state.Markets -ccontains $wantMarket)
  $pluginsMissing = @($wantPlugins | Where-Object { -not ($state.Enabled -ccontains "$_@$wantMarket") } | ForEach-Object { "$_@$wantMarket" })
  if ($marketMissing -or $pluginsMissing.Count -gt 0) {
    $what = @()
    if ($marketMissing) { $what += "marketplace '$wantMarket' is not registered" }
    if ($pluginsMissing.Count -gt 0) { $what += "plugin(s) not registered+enabled: $($pluginsMissing -join ' ')" }
    # himmel-ops carries the guardrail hooks, and no marketplace = nothing loads.
    $alarm = ''
    if ($marketMissing -or ($pluginsMissing -ccontains "himmel-ops@$wantMarket")) {
      $alarm = " GUARDRAILS MAY BE OFF — himmel's hooks are not loaded; do not route work to the codex CLI lane until fixed."
    }
    Emit 'plugin-unregistered' "codex CLI ($codexHome) has lost part of its himmel plugin registration: $($what -join '; ').$cfgNote$alarm No log row is written for a plugin that never loads, so the checks above cannot see this. Fix: re-run scripts/codex/install-himmel-codex.ps1 (idempotent; only ever adds), then restart codex. $scopeNote"
  }
}

if ($findings -gt 0) { exit 1 }
exit 0
