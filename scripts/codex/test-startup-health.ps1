<#
.SYNOPSIS
  Hermetic tests for startup-health.ps1 (HIMMEL-747) — twin of test-startup-health.sh.
.DESCRIPTION
  Builds a temp CODEX_HOME per case (synthetic rollout .jsonl naming the session
  thread_id + a synthetic logs_2.sqlite text file carrying the real WARN message
  shapes) and asserts: healthy -> 0; hook-failure -> 1; skill-truncation -> 1;
  a marker under an OLD thread_id does NOT fire (session scoping); oversized
  _where-are-we -> 1; missing CODEX_HOME -> 2.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$DET  = Join-Path $PSScriptRoot 'startup-health.ps1'
$TMP  = Join-Path ([System.IO.Path]::GetTempPath()) ("sh-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$NEW  = '019f3c01-afbf-7ef3-a689-c5be6d9afde0'
$OLD  = '019f0000-0000-7000-8000-000000000000'
$fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { [Console]::Error.WriteLine("  FAIL: $m"); $script:fails++ }

function New-Home([string]$name, [string]$tid, [string]$waw) {
  $h = Join-Path $TMP $name
  $d = Join-Path $h 'sessions/2026/07/07'
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  $f = Join-Path $d "rollout-2026-07-07T11-56-16-$tid.jsonl"
  '{"type":"event_msg","payload":{"type":"token_count"}}' | Set-Content -LiteralPath $f -Encoding utf8
  $rec = [pscustomobject]@{ type = 'response_item'; payload = [pscustomobject]@{ type = 'message'; content = @([pscustomobject]@{ type = 'text'; text = $waw }) } }
  ($rec | ConvertTo-Json -Depth 20 -Compress) | Add-Content -LiteralPath $f -Encoding utf8
  # HIMMEL-1145: a fully-registered config.toml, so every case that is NOT about
  # registration stays healthy. Registration cases overwrite it via Write-Config.
  Write-Config $h 'all'
  return $h
}

# The expected set comes from the SAME data file the detector reads — this suite
# must not become the second hardcoded copy the ticket forbids.
$PLUGIN_SET = Join-Path $PSScriptRoot 'himmel-plugin-set.conf'
function Get-SetField([string]$file, [string]$key) {
  foreach ($l in (Get-Content -LiteralPath $file)) { if ($l -match "^$([regex]::Escape($key)):\s*(.*?)\s*$") { return $Matches[1] } }
  return ''
}
$MARKET = Get-SetField $PLUGIN_SET 'marketplace'
$DEFAULT_PLUGINS = @((Get-SetField $PLUGIN_SET 'default') -split '\s+' | Where-Object { $_ })

# Synthesize $CODEX_HOME/config.toml in the shape codex itself writes
# (`[marketplaces.himmel]` + `[plugins."name@himmel"]` / `enabled = true`).
#   all      marketplace + every default plugin enabled
#   nomarket every default plugin enabled, marketplace table absent
#   skip     everything except $skip (absent entirely)
#   disable  everything, but $skip carries `enabled = false`
#   empty    an unrelated config only (no himmel registration at all)
function Write-Config([string]$homeDir, [string]$mode, [string]$skip = '') {
  $t = @('model = "gpt-5"', '', '[marketplaces.openai-bundled]', 'source_type = "local"', '', '[plugins."browser@openai-bundled"]', 'enabled = true', '')
  if ($mode -ne 'empty') {
    if ($mode -ne 'nomarket') { $t += @("[marketplaces.$MARKET]", 'source_type = "local"', 'source = "/x/marketplace"', '') }
    foreach ($p in $DEFAULT_PLUGINS) {
      if ($mode -eq 'skip' -and $p -eq $skip) { continue }
      $t += "[plugins.`"$p@$MARKET`"]"
      $t += $(if ($mode -eq 'disable' -and $p -eq $skip) { 'enabled = false' } else { 'enabled = true' })
      $t += ''
    }
  }
  $t | Set-Content -LiteralPath (Join-Path $homeDir 'config.toml') -Encoding utf8
}
function Set-Db([string]$homeDir, [string]$line) { $line | Set-Content -LiteralPath (Join-Path $homeDir 'logs_2.sqlite') -Encoding utf8 }
function Run([string]$homeDir, [hashtable]$envx = @{}) {
  $env:CODEX_HOME = $homeDir
  $env:WHERE_ARE_WE_BUDGET_BYTES = $(if ($envx.ContainsKey('budget')) { $envx.budget } else { $null })
  $out = & pwsh -NoProfile -File $DET 2>&1
  $rc = $LASTEXITCODE
  $env:CODEX_HOME = $null; $env:WHERE_ARE_WE_BUDGET_BYTES = $null
  return @{ rc = $rc; out = ($out -join "`n") }
}

function New-Hooks([string]$homeDir, [string]$rel, [bool]$withDesc) {
  $d = Join-Path $homeDir "plugins/cache/$rel"
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  $json = if ($withDesc) { '{"description":"x","hooks":{"SessionStart":[]}}' } else { '{"hooks":{"SessionStart":[]}}' }
  $json | Set-Content -LiteralPath (Join-Path $d 'hooks.json') -Encoding utf8
}

$small = "<system-reminder>`n# Where are we`nsmall"
$hookLine  = "WARN codex_core_plugins::manifest session_loop{thread_id=__TID__}:submission_dispatch{}:turn: load_plugins_from_layer_stack: ignoring hooks: expected a string, string array, object, or object array; found object"
# HIMMEL-1104: same "ignoring hooks" text from the marketplace SUGGESTION scan
# (non-installed plugins; parsed hooks discarded) — must NOT be a hook failure.
$suggestLine = "WARN codex_core_plugins::manifest session_loop{thread_id=__TID__}:submission_dispatch{}:turn:built_tools.load_discoverable_tools:list_tool_suggest_discoverable_tools_with_auth:list_tool_suggest_discoverable_plugins: ignoring hooks: expected a string, string array, object, or object array; found object"
$skillLine = "WARN codex_core_plugins::manifest session_loop{thread_id=__TID__}:built_tools: ignoring interface.defaultPrompt[0]: prompt must be at most 128 characters path=X"

try {
  # 1. healthy
  $h = New-Home 'healthy' $NEW $small
  Set-Db $h "INFO codex_core_skills::service session_loop{thread_id=$NEW}: skills cache cleared padding"
  $r = Run $h
  if ($r.rc -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) { Pass 'healthy -> exit 0, no findings' } else { Fail "healthy rc=$($r.rc) out=$($r.out)" }

  # 2. hook-failure
  $h = New-Home 'hook' $NEW $small
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match '^WARN hook-failure:') { Pass 'hook-failure -> exit 1' } else { Fail "hook rc=$($r.rc) out=$($r.out)" }

  # 2b. suggestion-scan noise must NOT fire (offenders present in cache too, to
  # prove it is the SPAN that gates the finding, not the cache contents).
  # Twin parity: same span shape as the .sh fixture, emitted twice.
  $h = New-Home 'suggest' $NEW $small
  New-Hooks $h 'claude-plugins-official/hookify/local/hooks' $true
  Set-Db $h (($suggestLine -replace '__TID__', $NEW) + "`n" + ($suggestLine -replace '__TID__', $NEW))
  $r = Run $h
  if ($r.rc -eq 0 -and [string]::IsNullOrWhiteSpace($r.out)) { Pass "suggestion-scan noise -> exit 0 (not a hook failure)" } else { Fail "suggest rc=$($r.rc) out=$($r.out)" }

  # 2c. upstream candidate named, but NOT declared safe (log carries no path).
  $h = New-Home 'upstream' $NEW $small
  New-Hooks $h 'claude-plugins-official/ralph-loop/1.0.0/hooks' $true
  New-Hooks $h 'himmel/himmel-ops/0.4.0/hooks' $false
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match 'ralph-loop' -and $r.out -match 'NOT correlated' -and $r.out -notmatch 'safe to route') { Pass 'upstream candidate named, not declared safe (fail-closed)' } else { Fail "upstream rc=$($r.rc) out=$($r.out)" }

  # 2d. himmel-owned offender escalates
  $h = New-Home 'himmeloff' $NEW $small
  New-Hooks $h 'himmel/himmel-ops/0.4.0/hooks' $true
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match 'GUARDRAILS MAY BE OFF' -and $r.out -match 'himmel-ops') { Pass 'himmel-owned offender escalates' } else { Fail "himmeloff rc=$($r.rc) out=$($r.out)" }

  # 2e. missing plugins/cache -> fail closed, report "could NOT be scanned"
  # (twin parity with the .sh suite).
  $h = New-Home 'noscan' $NEW $small
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match 'could NOT be scanned') { Pass 'unscannable cache says so rather than asserting none found' } else { Fail "noscan rc=$($r.rc) out=$($r.out)" }

  # 2f. unparseable hooks.json -> INCOMPLETE, never a clean "none found"
  $h = New-Home 'badjson' $NEW $small
  $bd = Join-Path $h 'plugins/cache/himmel/himmel-ops/0.4.0/hooks'
  New-Item -ItemType Directory -Force -Path $bd | Out-Null
  '{"hooks":{ THIS IS NOT JSON' | Set-Content -LiteralPath (Join-Path $bd 'hooks.json') -Encoding utf8
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match 'could NOT be scanned') { Pass 'unparseable hooks.json marks the scan incomplete' } else { Fail "badjson rc=$($r.rc) out=$($r.out)" }

  # 2g. incompleteness surfaced ALONGSIDE a found candidate
  $h = New-Home 'partial' $NEW $small
  New-Hooks $h 'claude-plugins-official/ralph-loop/1.0.0/hooks' $true
  $pd = Join-Path $h 'plugins/cache/claude-plugins-official/broken/1.0.0/hooks'
  New-Item -ItemType Directory -Force -Path $pd | Out-Null
  '{ nope' | Set-Content -LiteralPath (Join-Path $pd 'hooks.json') -Encoding utf8
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match 'ralph-loop' -and $r.out -match 'INCOMPLETE') { Pass 'names candidate + admits incomplete scan' } else { Fail "partial rc=$($r.rc) out=$($r.out)" }

  # 2h. case parity with the .sh twin: a `Description` key is NOT the lowercase
  # `description` field. jq (and codex's serde) are case-sensitive, so PowerShell
  # must use -ccontains — plain -contains would flag this and diverge.
  $h = New-Home 'casevariant' $NEW $small
  $cd = Join-Path $h 'plugins/cache/claude-plugins-official/casey/1.0.0/hooks'
  New-Item -ItemType Directory -Force -Path $cd | Out-Null
  '{"Description":"x","hooks":{"SessionStart":[]}}' | Set-Content -LiteralPath (Join-Path $cd 'hooks.json') -Encoding utf8
  Set-Db $h ($hookLine -replace '__TID__', $NEW)
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -notmatch 'casey') { Pass 'case-variant Description is not flagged (matches jq/serde case-sensitivity)' } else { Fail "casevariant rc=$($r.rc) out=$($r.out)" }

  # 3. skill-truncation
  $h = New-Home 'skill' $NEW $small
  Set-Db $h (($skillLine -replace '__TID__', $NEW))
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match 'WARN skill-truncation:') { Pass 'skill-truncation -> exit 1' } else { Fail "skill rc=$($r.rc) out=$($r.out)" }

  # 4. session scoping: marker only under OLD tid
  $h = New-Home 'scope' $NEW $small
  $od = Join-Path $h 'sessions/2026/07/01'; New-Item -ItemType Directory -Force -Path $od | Out-Null
  '{}' | Set-Content -LiteralPath (Join-Path $od "rollout-2026-07-01T00-00-00-$OLD.jsonl") -Encoding utf8
  Set-Db $h ($hookLine -replace '__TID__', $OLD)
  $r = Run $h
  if ($r.rc -eq 0) { Pass 'stale-only markers (old tid) -> exit 0 (scoped out)' } else { Fail "scope rc=$($r.rc) out=$($r.out)" }

  # 5. oversized where-are-we
  $big = "<system-reminder>`n# Where are we`n" + ('x' * 400)
  $h = New-Home 'big' $NEW $big
  Set-Db $h "INFO x session_loop{thread_id=$NEW}: noise padding line here"
  $r = Run $h @{ budget = '200' }
  if ($r.rc -eq 1 -and $r.out -match 'WARN where-are-we-oversized:') { Pass 'oversized where-are-we -> exit 1' } else { Fail "oversized rc=$($r.rc) out=$($r.out)" }
  $r = Run $h @{ budget = '100000' }
  if ($r.rc -eq 0) { Pass 'big block under generous budget -> exit 0' } else { Fail "budget-gate rc=$($r.rc)" }

  # 8. HIMMEL-1145: himmel plugin registration is asserted PRESENT (twin of the
  # .sh suite's section 8). The session in each case is otherwise clean — only
  # config.toml differs.
  function New-RegHome([string]$name, [string]$mode, [string]$skip = '') {
    $h = New-Home $name $NEW $small
    Set-Db $h "INFO codex_core_skills::service session_loop{thread_id=$NEW}: skills cache cleared padding"
    Write-Config $h $mode $skip
    return $h
  }
  $r = Run (New-RegHome 'regall' 'all')
  if ($r.rc -eq 0) { Pass 'fully registered set -> exit 0' } else { Fail "regall rc=$($r.rc) out=$($r.out)" }

  # 8a. no config.toml at all -> fail closed
  $h = New-RegHome 'regnocfg' 'all'; Remove-Item -LiteralPath (Join-Path $h 'config.toml')
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match '^WARN plugin-unregistered:' -and $r.out -match 'config\.toml') { Pass 'no config.toml -> plugin-unregistered naming the file' } else { Fail "nocfg rc=$($r.rc) out=$($r.out)" }

  # 8b. total loss
  $r = Run (New-RegHome 'regempty' 'empty')
  $allNamed = $true; foreach ($p in $DEFAULT_PLUGINS) { if ($r.out -notmatch [regex]::Escape("$p@$MARKET")) { $allNamed = $false } }
  if ($r.rc -eq 1 -and $r.out -match '^WARN plugin-unregistered:' -and $allNamed -and $r.out -match "marketplace '$MARKET'" -and $r.out -match 'GUARDRAILS MAY BE OFF') { Pass 'total loss -> names marketplace + every plugin, GUARDRAILS MAY BE OFF' } else { Fail "empty rc=$($r.rc) out=$($r.out)" }
  if ($r.out -match 'codex CLI' -and $r.out -match 'claudex / cc-glm / hermes are separate surfaces') { Pass 'finding names the surface (codex CLI)' } else { Fail "surface out=$($r.out)" }
  if ($r.out -notmatch 'luna-correlate') { Pass 'opt-in extras are not required' } else { Fail "extras required: $($r.out)" }

  # 8c. marketplace gone, plugin tables still there
  $r = Run (New-RegHome 'regnomarket' 'nomarket')
  if ($r.rc -eq 1 -and $r.out -match "marketplace '$MARKET'" -and $r.out -match 'GUARDRAILS MAY BE OFF') { Pass 'marketplace missing -> named + escalates' } else { Fail "nomarket rc=$($r.rc) out=$($r.out)" }

  # 8d. PARTIAL: himmel-ops disabled -> named alone, escalates
  $r = Run (New-RegHome 'regdisabled' 'disable' 'himmel-ops')
  if ($r.rc -eq 1 -and $r.out -match "himmel-ops@$MARKET" -and $r.out -match 'GUARDRAILS MAY BE OFF' -and $r.out -notmatch "handover@$MARKET") { Pass 'himmel-ops disabled -> named alone (per-plugin), escalates' } else { Fail "disabled rc=$($r.rc) out=$($r.out)" }

  # 8e. PARTIAL: a non-guardrail plugin absent -> named, no guardrails alarm
  $r = Run (New-RegHome 'regpartial' 'skip' 'telegram-himmel')
  if ($r.rc -eq 1 -and $r.out -match "telegram-himmel@$MARKET" -and $r.out -notmatch 'GUARDRAILS MAY BE OFF') { Pass 'non-guardrail loss named, no GUARDRAILS MAY BE OFF' } else { Fail "partial rc=$($r.rc) out=$($r.out)" }

  # 8f. same plugin name under ANOTHER marketplace does not count
  $h = New-RegHome 'regforeign' 'all'
  $cfgPath = Join-Path $h 'config.toml'
  (Get-Content -LiteralPath $cfgPath) -replace "`"himmel-ops@$MARKET`"", '"himmel-ops@other"' | Set-Content -LiteralPath $cfgPath -Encoding utf8
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match "himmel-ops@$MARKET") { Pass 'foreign-marketplace himmel-ops does not satisfy the requirement' } else { Fail "foreign rc=$($r.rc) out=$($r.out)" }

  # 8f2. a registration that only appears INSIDE a multiline string is not one
  $mlno = 0
  foreach ($q in @('"""', "'''")) {
    $mlno++
    $h = New-RegHome "regml$mlno" 'skip' 'himmel-ops'
    Add-Content -LiteralPath (Join-Path $h 'config.toml') -Value "note = $q`n[plugins.`"himmel-ops@$MARKET`"]`nenabled = true`n$q"
    $r = Run $h
    if ($r.rc -eq 1 -and $r.out -match "himmel-ops@$MARKET") { Pass "himmel-ops registered only inside a $q string is still reported missing" } else { Fail "multiline $q rc=$($r.rc) out=$($r.out)" }
  }

  # 8g. no session at all (no sessions dir -> no thread_id): config-only check
  $h = Join-Path $TMP 'regnosession'; New-Item -ItemType Directory -Force -Path $h | Out-Null
  Set-Db $h "INFO x session_loop{thread_id=$NEW}: noise padding line here"; Write-Config $h 'empty'
  $r = Run $h
  if ($r.rc -eq 1 -and $r.out -match '^WARN plugin-unregistered:') { Pass 'registration check does not depend on a session' } else { Fail "nosession rc=$($r.rc) out=$($r.out)" }

  # 8h. the expected set is DERIVED from the data file, not restated in the detector
  $dd = Join-Path $TMP 'derive'; New-Item -ItemType Directory -Force -Path $dd | Out-Null
  Copy-Item -LiteralPath $DET -Destination (Join-Path $dd 'startup-health.ps1')
  "marketplace: himmel`ndefault: zzz-only-plugin`nall-extra: x" | Set-Content -LiteralPath (Join-Path $dd 'himmel-plugin-set.conf') -Encoding utf8
  $h = New-RegHome 'regderived' 'all'
  $env:CODEX_HOME = $h; $out = & pwsh -NoProfile -File (Join-Path $dd 'startup-health.ps1') 2>&1; $rc = $LASTEXITCODE; $env:CODEX_HOME = $null
  $out = $out -join "`n"
  if ($rc -eq 1 -and $out -match 'zzz-only-plugin@himmel' -and $out -notmatch 'himmel-ops') { Pass 'custom data file drives the requirement (no second hardcoded copy)' } else { Fail "derived rc=$rc out=$out" }
  @('[marketplaces.himmel]', 'source_type = "local"', '', '[plugins."zzz-only-plugin@himmel"]', 'enabled = true') | Set-Content -LiteralPath (Join-Path $h 'config.toml') -Encoding utf8
  $env:CODEX_HOME = $h; $null = & pwsh -NoProfile -File (Join-Path $dd 'startup-health.ps1') 2>&1; $rc = $LASTEXITCODE; $env:CODEX_HOME = $null
  if ($rc -eq 0) { Pass 'custom data file: its plugin present -> exit 0' } else { Fail "derived-ok rc=$rc" }

  # 8i. data file missing -> cannot judge -> say so, never a silent pass
  $nd = Join-Path $TMP 'nodata'; New-Item -ItemType Directory -Force -Path $nd | Out-Null
  Copy-Item -LiteralPath $DET -Destination (Join-Path $nd 'startup-health.ps1')
  $h = New-RegHome 'regnodata' 'all'
  $env:CODEX_HOME = $h; $out = & pwsh -NoProfile -File (Join-Path $nd 'startup-health.ps1') 2>&1; $rc = $LASTEXITCODE; $env:CODEX_HOME = $null
  $out = $out -join "`n"
  if ($rc -eq 1 -and $out -match '^WARN plugin-presence-unchecked:') { Pass 'data file missing -> plugin-presence-unchecked (fail closed)' } else { Fail "nodata rc=$rc out=$out" }

  # 6. missing CODEX_HOME -> 2
  $r = Run (Join-Path $TMP 'nope/.codex')
  if ($r.rc -eq 2) { Pass 'missing CODEX_HOME -> exit 2' } else { Fail "missing rc=$($r.rc)" }
}
finally {
  Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -eq 0) { Write-Host 'PASS' } else { Write-Host "FAIL ($fails)"; exit 1 }
