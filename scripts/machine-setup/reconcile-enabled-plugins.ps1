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
#   pwsh reconcile-enabled-plugins.ps1 [-DryRun] [-Scope user|project|local]
#                                      [-Settings PATH] [-Template PATH]
[CmdletBinding()]
param(
  [switch]$DryRun,
  [ValidateSet('user', 'project', 'local')]
  [string]$Scope = 'user',
  [string]$Settings,
  [string]$Template
)
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $Template) { $Template = Join-Path $RepoRoot 'docs\setup\settings-template.json' }

# Resolve the target settings file (-Settings wins over -Scope).
if (-not $Settings) {
  $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
  switch ($Scope) {
    'user'    { $Settings = Join-Path $cfgDir 'settings.json' }
    'project' { $Settings = Join-Path (Get-Location) '.claude\settings.json' }
    'local'   { $Settings = Join-Path (Get-Location) '.claude\settings.local.json' }
  }
}

if (-not (Test-Path $Template)) { Write-Error "reconcile-enabled-plugins: template not found: $Template"; exit 1 }
try { $tmpl = Get-Content -Raw $Template | ConvertFrom-Json } catch { Write-Error "reconcile-enabled-plugins: template is not valid JSON: $Template"; exit 1 }

# Template enabledPlugins is the authoritative floor.
$tmplEp = $tmpl.enabledPlugins
if (-not $tmplEp -or $tmplEp.PSObject.Properties.Count -eq 0) {
  Write-Error 'reconcile-enabled-plugins: template has no enabledPlugins - refusing to blank the live set'; exit 1
}

if (-not (Test-Path $Settings)) {
  Write-Host "reconcile-enabled-plugins: settings file not found ($Settings) - nothing to reconcile."
  exit 0
}
try { $settingsObj = Get-Content -Raw $Settings | ConvertFrom-Json } catch { Write-Error "reconcile-enabled-plugins: $Settings is not valid JSON - refusing to patch"; exit 1 }

$liveEp = if ($settingsObj.PSObject.Properties['enabledPlugins']) { $settingsObj.enabledPlugins } else { $null }

# Per-machine escape hatch: sibling settings.local.json wins in BOTH directions
# (a `true` keeps an operator-personal plugin enabled; a `false` disables a
# template-floor plugin). Baked in here so the override holds across runs.
# Only when the target IS settings.json (avoid a local target reading itself).
# Fail LOUD on an invalid local file - silently treating it as no-override would
# reconcile the base settings and disable the very plugins the operator kept in
# settings.local.json (the exact harm this file prevents).
$localOverrides = $null
if ((Split-Path -Leaf $Settings) -eq 'settings.json') {
  $localFile = Join-Path (Split-Path -Parent $Settings) 'settings.local.json'
  if (Test-Path $localFile) {
    try { $lj = Get-Content -Raw $localFile | ConvertFrom-Json; $localOverrides = $lj.enabledPlugins }
    catch { Write-Error "reconcile-enabled-plugins: $localFile exists but is not valid JSON - refusing to reconcile (its overrides would be lost, disabling wanted plugins)"; exit 1 }
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

# Assign the ordered map back and write BOM-free UTF-8 via temp+move (mirrors
# install-plugins.ps1's writer). Copy the target's ACL to the temp file BEFORE
# the move so a freshly-created temp (which inherits the parent dir's possibly
# broader ACL) cannot widen access to the settings file. Best-effort - an ACL
# copy failure must not abort the reconcile.
$settingsObj | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue ([PSCustomObject]$newEp) -Force
$tmp = "$Settings.reconcile.tmp"
[System.IO.File]::WriteAllText($tmp, ($settingsObj | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding $false))
try { Set-Acl -LiteralPath $tmp -AclObject (Get-Acl -LiteralPath $Settings) } catch { }
Move-Item -Force $tmp $Settings
Write-Host "    reconciled: enabledPlugins written to $Settings"
