#Requires -Version 7
<#
  omniroute-config-lint.ps1 — structural WS6-dedup enforcement for the self-hosted
  OmniRoute router config (HIMMEL-654 WS2, child HIMMEL-666). PowerShell twin of
  scripts/omniroute-config-lint.sh — behaviour-identical: same output lines, same
  exit codes. himmel already runs its own rtk hook + caveman compression, so
  OmniRoute's bundled compression stack must be provably OFF ("one optimizer per
  boundary"). This lint is a POSITIVE assertion over the authoritative engine-key
  set from the WS2 Task-1 source-read (OmniRoute pin b729a8f / v3.8.43): every
  expected key must be PRESENT and explicitly disabled — an OMITTED default-on
  engine fails just like an enabled one.

  Input document shape (Task 2 — operator-gated — exports the deployed OmniRoute
  settings to this shape): a JSON object with the compression settings object under
  a top-level "compression" key and the free-lane flag "autoRoutingEnabled" at top
  level. An `optimization` subtree inside compression is SQLite VACUUM tuning (not
  prompt optimization) and is ignored.

  Usage: omniroute-config-lint.ps1 <config.json>
  Exit:  0 = PASS, 1 = one or more FAILs, 2 = usage / unreadable / unparseable input.
  (The bash twin additionally exits 4 if its node runtime is absent — it delegates
  JSON parsing to node; PS parses natively via ConvertFrom-Json and has no node
  dependency, so it cannot hit that path.)

  JSON parsing uses ConvertFrom-Json natively (twin uses node); presence is probed
  via PSObject.Properties so an OMITTED key is distinguished from a disabled one.
#>
$ErrorActionPreference = 'Stop'

if ($args.Count -ne 1) {
  [Console]::Error.WriteLine('usage: omniroute-config-lint.ps1 <config.json>')
  exit 2
}
$cfgPath = $args[0]

if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
  [Console]::Error.WriteLine("omniroute-config-lint: cannot read $cfgPath")
  exit 2
}
try { $raw = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop }
catch { [Console]::Error.WriteLine("omniroute-config-lint: cannot read $cfgPath"); exit 2 }
try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop }
catch { [Console]::Error.WriteLine("omniroute-config-lint: invalid JSON in $cfgPath"); exit 2 }
if ($null -eq $doc -or -not ($doc -is [System.Management.Automation.PSCustomObject])) {
  [Console]::Error.WriteLine('omniroute-config-lint: config root is not a JSON object')
  exit 2
}

$script:fails = [System.Collections.Generic.List[string]]::new()
$script:asserted = 0
function Add-Fail([string]$m) { $script:fails.Add('FAIL: ' + $m) }
function Test-IsObj($x) { return ($x -is [System.Management.Automation.PSCustomObject]) }
function Get-Leaf($parent, [string]$key) {
  if (Test-IsObj $parent) {
    $p = $parent.PSObject.Properties[$key]
    if ($null -ne $p) { return @{ present = $true; value = $p.Value } }
  }
  return @{ present = $false; value = $null }
}
function Get-Show($v) {
  if ($null -eq $v) { return 'null' }
  if ($v -is [string]) { return [string]$v }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [array]) { return ($v | ConvertTo-Json -Compress -Depth 20) }
  if (Test-IsObj $v) { return ($v | ConvertTo-Json -Compress -Depth 20) }
  return [string]$v
}
function Assert-False([string]$path, $leaf) {
  $script:asserted++
  if (-not $leaf.present) { Add-Fail "$path expected false, got <absent>"; return }
  $v = $leaf.value
  if (-not (($v -is [bool]) -and ($v -eq $false))) { Add-Fail "$path expected false, got $(Get-Show $v)" }
}
function Assert-Off([string]$path, $leaf) {
  $script:asserted++
  if (-not $leaf.present) { Add-Fail "$path expected off, got <absent>"; return }
  $v = $leaf.value
  if (-not (($v -is [string]) -and ($v -eq 'off'))) { Add-Fail "$path expected off, got $(Get-Show $v)" }
}

$compLeaf = Get-Leaf $doc 'compression'
if (-not $compLeaf.present) {
  Add-Fail 'compression object is missing (expected present with every engine disabled)'
}
elseif (-not (Test-IsObj $compLeaf.value)) {
  Add-Fail "compression expected an object, got $(Get-Show $compLeaf.value)"
}
else {
  $comp = $compLeaf.value
  Assert-False 'compression.enabled' (Get-Leaf $comp 'enabled')
  Assert-Off   'compression.defaultMode' (Get-Leaf $comp 'defaultMode')
  Assert-Off   'compression.autoTriggerMode' (Get-Leaf $comp 'autoTriggerMode')
  Assert-False 'compression.rtkConfig.enabled' (Get-Leaf (Get-Leaf $comp 'rtkConfig').value 'enabled')
  Assert-False 'compression.cavemanConfig.enabled' (Get-Leaf (Get-Leaf $comp 'cavemanConfig').value 'enabled')
  Assert-False 'compression.cavemanOutputMode.enabled' (Get-Leaf (Get-Leaf $comp 'cavemanOutputMode').value 'enabled')
  Assert-False 'compression.ultra.enabled' (Get-Leaf (Get-Leaf $comp 'ultra').value 'enabled')
  Assert-False 'compression.contextEditing.enabled' (Get-Leaf (Get-Leaf $comp 'contextEditing').value 'enabled')
  Assert-False 'compression.languageConfig.enabled' (Get-Leaf (Get-Leaf $comp 'languageConfig').value 'enabled')
  Assert-False 'compression.mcpDescriptionCompressionEnabled' (Get-Leaf $comp 'mcpDescriptionCompressionEnabled')
  Assert-False 'compression.mcpAccessibilityConfig.enabled' (Get-Leaf (Get-Leaf $comp 'mcpAccessibilityConfig').value 'enabled')

  $eng = Get-Leaf $comp 'engines'
  $script:asserted++
  if (-not $eng.present) {
    Add-Fail 'compression.engines missing (expected an object with every entry disabled)'
  }
  elseif (-not (Test-IsObj $eng.value)) {
    Add-Fail "compression.engines expected an object, got $(Get-Show $eng.value)"
  }
  else {
    foreach ($pr in $eng.value.PSObject.Properties) {
      $en = Get-Leaf $pr.Value 'enabled'
      if (-not ($en.present -and ($en.value -is [bool]) -and ($en.value -eq $false))) {
        $got = if ($en.present) { Get-Show $en.value } else { '<absent>' }
        Add-Fail "compression.engines[""$($pr.Name)""].enabled expected false, got $got"
      }
    }
  }

  $aggLeaf = Get-Leaf $comp 'aggressive'
  $agg = $aggLeaf.value
  Assert-False 'compression.aggressive.summarizerEnabled' (Get-Leaf $agg 'summarizerEnabled')
  $ts = if ($aggLeaf.present) { Get-Leaf $agg 'toolStrategies' } else { @{ present = $false; value = $null } }
  $script:asserted++
  if (-not $ts.present) {
    Add-Fail 'compression.aggressive.toolStrategies missing (expected an object with every entry disabled)'
  }
  elseif (-not (Test-IsObj $ts.value)) {
    Add-Fail "compression.aggressive.toolStrategies expected an object, got $(Get-Show $ts.value)"
  }
  else {
    foreach ($pr in $ts.value.PSObject.Properties) {
      $tv = $pr.Value
      if ($tv -is [bool]) {
        if ($tv -ne $false) { Add-Fail "compression.aggressive.toolStrategies.$($pr.Name) expected false, got true" }
      }
      elseif (Test-IsObj $tv) {
        $te = Get-Leaf $tv 'enabled'
        if (-not ($te.present -and ($te.value -is [bool]) -and ($te.value -eq $false))) {
          $got = if ($te.present) { Get-Show $te.value } else { '<absent>' }
          Add-Fail "compression.aggressive.toolStrategies.$($pr.Name).enabled expected false, got $got"
        }
      }
      else {
        Add-Fail "compression.aggressive.toolStrategies.$($pr.Name) expected disabled, got $(Get-Show $tv)"
      }
    }
  }

  $sp = Get-Leaf $comp 'stackedPipeline'
  $script:asserted++
  if (-not $sp.present) {
    Add-Fail 'compression.stackedPipeline missing (expected an empty array)'
  }
  elseif (-not ($sp.value -is [array])) {
    Add-Fail "compression.stackedPipeline expected an empty array, got $(Get-Show $sp.value)"
  }
  elseif ($sp.value.Count -ne 0) {
    $n = $sp.value.Count
    $u = if ($n -eq 1) { 'entry' } else { 'entries' }
    Add-Fail "compression.stackedPipeline expected an empty array, got $n $u"
  }

  $cache = (Get-Leaf $comp 'cache').value
  Assert-False 'compression.cache.semanticCacheEnabled' (Get-Leaf $cache 'semanticCacheEnabled')
  Assert-False 'compression.cache.promptCacheEnabled' (Get-Leaf $cache 'promptCacheEnabled')

  # KEEP IN SYNC with the twin allowlist in scripts/omniroute-config-lint.sh
  # (var known) — the recognized-key set must match, or one twin flags a key the
  # other silently accepts (a renamed/new engine sneaking past only one twin).
  $known = @('enabled', 'defaultMode', 'autoTriggerMode', 'rtkConfig', 'cavemanConfig', 'cavemanOutputMode', 'ultra', 'contextEditing', 'languageConfig', 'mcpDescriptionCompressionEnabled', 'mcpAccessibilityConfig', 'engines', 'aggressive', 'stackedPipeline', 'cache', 'optimization')
  foreach ($pr in $comp.PSObject.Properties) {
    if ($known -notcontains $pr.Name) {
      Add-Fail "compression.$($pr.Name) is not a recognized key (discovered set != expected set; possible new/renamed engine)"
    }
  }
}

$ar = Get-Leaf $doc 'autoRoutingEnabled'
$script:asserted++
if (-not $ar.present) {
  Add-Fail 'autoRoutingEnabled expected false, got <absent>'
}
elseif (-not (($ar.value -is [bool]) -and ($ar.value -eq $false))) {
  Add-Fail "autoRoutingEnabled expected false, got $(Get-Show $ar.value)"
}

if ($script:fails.Count -gt 0) {
  # FAIL diagnostics go to stderr; the PASS confirmation stays on stdout so a
  # passing lint emits exactly one stdout line (testable / pipeable), while a
  # failing one writes nothing to stdout. Exit code is unchanged (1).
  foreach ($f in $script:fails) { [Console]::Error.WriteLine($f) }
  exit 1
}
Write-Output "PASS: omniroute compression stack disabled ($($script:asserted) keys asserted)"
exit 0
