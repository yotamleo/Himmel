# reconcile-enabled-plugins.ps1 - enforce the lean plugin floor (HIMMEL-1032).
#
# PowerShell twin of reconcile-enabled-plugins.sh - keep the WHITELIST logic in
# lockstep. See the .sh header for the full WHY. In short: the lean plugin
# profile (HIMMEL-816) was additive-only, so disabled plugins drift back after
# every update; this reconciles the target settings.json enabledPlugins DOWN to
# the template floor. Only template-`true` plugins survive; every other spec
# (template `false` AND any live-enabled spec absent from the template) is forced
# `false`. The sibling settings.local.json is honored as a per-machine override
# and baked into the result in BOTH directions (a `true` keeps an off-floor
# plugin enabled; a `false` disables a floor plugin), so the override holds
# across reconcile runs without relying on harness load-order.
#
# Usage:
#   pwsh reconcile-enabled-plugins.ps1 [-DryRun] [-Scope user|project]
#                                      [-Settings PATH] [-Template PATH]
# NOTE: no `local` scope - settings.local.json is the protected override input
# (it wins over the floor), never a reconcile target.
[CmdletBinding()]
param(
  [switch]$DryRun,
  [ValidateSet('user', 'project')]
  [string]$Scope = 'user',
  [string]$Settings,
  [string]$Template
)
$ErrorActionPreference = 'Stop'

# Die: write to stderr and exit with the intended code. NOT Write-Error - under
# $ErrorActionPreference='Stop' that is terminating, so a trailing `exit N` is
# unreachable and the real exit code becomes 1 (plus a noisy stack trace).
function Die([string]$msg, [int]$code) { [Console]::Error.WriteLine($msg); exit $code }

# Return an object's enabledPlugins, or Die if it is present but a non-null
# non-object (unusable shape that would break the hashtable conversion / merge).
# null/absent -> $null (treated as "no map"), matching the bash object|null accept.
function Get-EpOrDie($obj, [string]$label, [string]$file) {
  if (-not $obj.PSObject.Properties['enabledPlugins']) { return $null }
  $ep = $obj.enabledPlugins
  if ($null -ne $ep -and $ep -isnot [System.Management.Automation.PSCustomObject]) {
    Die "reconcile-enabled-plugins: $label ($file) has a non-object enabledPlugins - refusing" 1
  }
  return $ep
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $Template) { $Template = Join-Path $RepoRoot 'docs\setup\settings-template.json' }

# Resolve the target settings file (-Settings wins over -Scope).
if (-not $Settings) {
  $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
  switch ($Scope) {
    'user'    { $Settings = Join-Path $cfgDir 'settings.json' }
    'project' { $Settings = Join-Path (Get-Location) '.claude\settings.json' }
  }
}

# Refuse to target settings.local.json even via an explicit -Settings path: it
# is the protected override input; reconciling it would wipe the operator's
# overrides down to the floor. (-eq is case-insensitive - matches Windows FS.)
if ((Split-Path -Leaf $Settings) -eq 'settings.local.json') {
  Die 'reconcile-enabled-plugins: refusing to target settings.local.json - it is the protected override input, not a reconcile target' 2
}

if (-not (Test-Path $Template)) { Die "reconcile-enabled-plugins: template not found: $Template" 1 }
try { $tmpl = Get-Content -Raw $Template | ConvertFrom-Json } catch { Die "reconcile-enabled-plugins: template is not valid JSON: $Template" 1 }

# Template enabledPlugins is the authoritative floor.
$tmplEp = Get-EpOrDie $tmpl 'template' $Template
if (-not $tmplEp -or $tmplEp.PSObject.Properties.Count -eq 0) {
  Die 'reconcile-enabled-plugins: template has no enabledPlugins - refusing to blank the live set' 1
}

if (-not (Test-Path $Settings)) {
  Write-Host "reconcile-enabled-plugins: settings file not found ($Settings) - nothing to reconcile."
  exit 0
}
try { $settingsObj = Get-Content -Raw $Settings | ConvertFrom-Json } catch { Die "reconcile-enabled-plugins: $Settings is not valid JSON - refusing to patch" 1 }

# Validate the live enabledPlugins shape BEFORE the hashtable conversion - a
# non-object here would make ConvertTo-EpHashtable iterate bogus properties.
$liveEp = Get-EpOrDie $settingsObj 'settings' $Settings

# Per-machine escape hatch: sibling settings.local.json wins in BOTH directions
# (a `true` keeps an operator-personal plugin enabled; a `false` disables a
# template-floor plugin). Baked in here so the override holds across runs.
# Only when the target IS settings.json (avoid a local target reading itself).
# Fail LOUD on an invalid local file - silently treating it as no-override would
# reconcile the base settings and disable the very plugins the operator kept in
# settings.local.json (the exact harm this file prevents). A parseable file whose
# enabledPlugins is not an OBJECT (string/array/number) is equally unusable.
$localOverrides = $null
if ((Split-Path -Leaf $Settings) -eq 'settings.json') {
  $localFile = Join-Path (Split-Path -Parent $Settings) 'settings.local.json'
  if (Test-Path $localFile) {
    try { $lj = Get-Content -Raw $localFile | ConvertFrom-Json }
    catch { Die "reconcile-enabled-plugins: $localFile exists but is not valid JSON - refusing to reconcile (its overrides would be lost, disabling wanted plugins)" 1 }
    # null == "no overrides" (parity with the bash/doctor object|null accept);
    # a present non-null non-object is refused by Get-EpOrDie.
    $localOverrides = Get-EpOrDie $lj 'settings.local.json' $localFile
  }
}

# Convert enabledPlugins objects to hashtables so key lookup is robust for specs
# containing '@' (PSObject.Properties[$k] indexing is fragile for those).
function ConvertTo-EpHashtable($o) {
  $h = @{}
  if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [bool]$p.Value } }
  return $h
}
$liveHt = ConvertTo-EpHashtable $liveEp
$localHt = ConvertTo-EpHashtable $localOverrides

# newMap = template floor, then unknown live-enabled specs appended as false
# (the whitelist catch-all), then settings.local.json overrides win. Ordered so
# output is stable/diffable.
$newEp = [ordered]@{}
foreach ($p in $tmplEp.PSObject.Properties) { $newEp[$p.Name] = [bool]$p.Value }
foreach ($k in $liveHt.Keys) { if (-not $newEp.Contains($k)) { $newEp[$k] = $false } }
foreach ($k in $localHt.Keys) { $newEp[$k] = $localHt[$k] }

# Drift = ends false but was live-`true` (a genuine true->false demotion).
$disabled = New-Object System.Collections.Generic.List[string]
foreach ($k in $newEp.Keys) {
  if ($newEp[$k] -eq $false -and $liveHt.ContainsKey($k) -and $liveHt[$k] -eq $true) { $disabled.Add($k) }
}

$kept = @($newEp.Keys | Where-Object { $newEp[$_] -eq $true }).Count
Write-Host "==> plugin-set reconcile ($Settings)"
Write-Host "    lean floor: $kept plugin(s) enabled."
if ($disabled.Count -gt 0) {
  Write-Host '    forcing OFF (drift cleared):'
  foreach ($k in $disabled) { Write-Host "      - $k" }
} else {
  Write-Host '    no drift - already at the lean floor.'
}

# Unchanged? (compare live vs new by key/value)
$changed = $false
if ($liveHt.Keys.Count -ne $newEp.Keys.Count) { $changed = $true }
else { foreach ($k in $newEp.Keys) { if (-not $liveHt.ContainsKey($k) -or ($liveHt[$k] -ne $newEp[$k])) { $changed = $true; break } } }
if (-not $changed) { Write-Host '    settings unchanged.'; exit 0 }

if ($DryRun) { Write-Host "    DRY: would write reconciled enabledPlugins to $Settings"; exit 0 }

# Write BOM-free UTF-8 via temp+move (mirrors install-plugins.ps1's writer).
# Order matters for security: create the EMPTY temp, copy the target's ACL onto
# it, THEN write the JSON - so the settings content is never briefly readable
# through a temp that still carries the parent dir's (possibly broader) inherited
# ACL. Fail CLOSED if the ACL can't be preserved: delete the temp and abort
# rather than replace the settings file with one that may widen access.
$settingsObj | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue ([PSCustomObject]$newEp) -Force
$tmp = "$Settings.reconcile.tmp"
New-Item -ItemType File -Force -Path $tmp | Out-Null
try { Set-Acl -LiteralPath $tmp -AclObject (Get-Acl -LiteralPath $Settings) }
catch {
  try { Remove-Item -Force -LiteralPath $tmp -ErrorAction Stop } catch { [Console]::Error.WriteLine("reconcile-enabled-plugins: warning - could not remove temp file $tmp") }
  Die "reconcile-enabled-plugins: could not preserve the ACL on $Settings - refusing to replace it with a temp file that may carry broader inherited access" 1
}
[System.IO.File]::WriteAllText($tmp, ($settingsObj | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding $false))
Move-Item -Force $tmp $Settings
Write-Host "    reconciled: enabledPlugins written to $Settings"
