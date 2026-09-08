# plugin-profile.ps1 — PowerShell twin of plugin-profile.sh: move a plugin
# between the ALWAYS and ON-DEMAND tiers of the himmel lean profile
# (HIMMEL-2733).
#
# WHY this exists: docs/setup/settings-template.json declares two tiers. The
# ALWAYS tier (`enabledPlugins` entries flagged `true`) is installed AND
# enabled on every himmel machine. The ON-DEMAND tier (keys of
# `onDemandPlugins`, each also present in `enabledPlugins` as `false`) is
# INSTALLED but left DISABLED, so a session starts lean and the capability is
# still one command away. Reaching an on-demand plugin used to mean a manual
# `/plugin` toggle or — worse — a hand edit of a live settings.json, which is
# hook-blocked (block-edit-live-settings) precisely because a hand edit
# drifts from the template silently.
#
# This script is the ONLY sanctioned writer for that flip, and it writes
# solely through `claude plugin enable|disable <spec> --scope user`. It never
# opens a settings.json.
#
# Cadences do NOT use this script: an unattended leg that needs an on-demand
# plugin force-enables it per run via a settings fragment
# (scripts/luna/pipeline-cadence.sh, HIMMEL-1036) so the machine's own
# profile stays lean between runs.
#
# Usage:
#   pwsh plugin-profile.ps1 list [--json]
#   pwsh plugin-profile.ps1 lean
#   pwsh plugin-profile.ps1 full
#   pwsh plugin-profile.ps1 enable  <spec>
#   pwsh plugin-profile.ps1 disable <spec>
#
# Verbs:
#   list              Print both tiers with each plugin's LIVE enabled/disabled
#                     state, and the `neededBy` line for every on-demand entry.
#   lean              Disable every on-demand plugin that is currently enabled.
#   full              Enable every installed on-demand plugin at user scope.
#   enable  <spec>    Enable one plugin at user scope.
#   disable <spec>    Disable one plugin at user scope.
#
# <spec> takes the full `plugin@marketplace` form, or a bare plugin name when
# that name is unambiguous across the template's two tiers.
#
# Flags:
#   --dry-run         Print the `claude plugin ...` commands instead of running.
#   --json            `list` only: emit the tier table as JSON.
#   --template PATH   Override the template (default: repo settings-template.json).
#
# Exit codes:
#   0  the requested state was reached (including a no-op — already there)
#   1  a `claude plugin` call failed, or the live state could not be read
#   2  usage error (unknown verb/flag, unknown or ambiguous <spec>, refused spec)
#
# plugin-profile.sh is the bash twin — keep the resolution + refusal rules in
# lockstep. Verbs/flags are positional + intermixed (like the bash getopts
# loop), which is why this file parses $Rest by hand instead of a typed
# [CmdletBinding()] param block.
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)
$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits (the ❯ bullets in `claude plugin
# list`) is silently mis-decoded on capture (HIMMEL-2256; reference fix:
# gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $Rest) { $Rest = @() }

# Die: write to stderr and exit with the intended code. NOT Write-Error --
# under $ErrorActionPreference='Stop' that is terminating, so a trailing
# `exit N` is unreachable and the real exit code becomes 1 (plus a noisy
# stack trace).
function Die([string]$msg, [int]$code) { [Console]::Error.WriteLine($msg); exit $code }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path

$UsageText = @'
Usage:
  pwsh plugin-profile.ps1 list [--json]
  pwsh plugin-profile.ps1 lean
  pwsh plugin-profile.ps1 full
  pwsh plugin-profile.ps1 enable  <spec>
  pwsh plugin-profile.ps1 disable <spec>

Verbs:
  list              Print both tiers with each plugin's LIVE enabled/disabled
                    state, and the `neededBy` line for every on-demand entry.
  lean              Disable every on-demand plugin that is currently enabled.
  full              Enable every installed on-demand plugin at user scope.
  enable  <spec>    Enable one plugin at user scope.
  disable <spec>    Disable one plugin at user scope.

<spec> takes the full `plugin@marketplace` form, or a bare plugin name when
that name is unambiguous across the template's two tiers.

Flags:
  --dry-run         Print the `claude plugin ...` commands instead of running.
  --json            `list` only: emit the tier table as JSON.
  --template PATH   Override the template (default: repo settings-template.json).

Exit codes:
  0  the requested state was reached (including a no-op - already there)
  1  a `claude plugin` call failed, or the live state could not be read
  2  usage error (unknown verb/flag, unknown or ambiguous <spec>, refused spec)
'@
function Show-Usage { Write-Host $UsageText }

# The harness-operational floor. Disabling any of these breaks the session
# that is running the command (dispatch, retrieval, handover state), so
# `disable` refuses them outright. Mirrors the `floor` list in
# scripts/lanes/plugin-profiles.json AND the bash twin's $FLOOR -- keep all
# three in lockstep.
$Floor = @('handover@himmel', 'himmel-ops@himmel', 'qmd@himmel')

# ── Parse args (mirrors the bash while/case loop) ────────────────────────────
$Template = Join-Path $RepoRoot 'docs\setup\settings-template.json'
$DryRun = $false
$Json = $false
$Verb = ''
$Spec = ''

$i = 0
while ($i -lt $Rest.Count) {
  $a = $Rest[$i]
  if ($a -ceq 'list' -or $a -ceq 'lean' -or $a -ceq 'full' -or $a -ceq 'enable' -or $a -ceq 'disable') {
    if ($Verb -ne '') { Die "plugin-profile: one verb at a time -- saw '$Verb' and '$a'" 2 }
    $Verb = $a; $i++
  } elseif ($a -eq '--dry-run') {
    $DryRun = $true; $i++
  } elseif ($a -eq '--json') {
    $Json = $true; $i++
  } elseif ($a -eq '--template') {
    if (($i + 1) -ge $Rest.Count -or [string]::IsNullOrEmpty($Rest[$i + 1])) { Die 'plugin-profile: --template needs a path' 2 }
    $Template = $Rest[$i + 1]; $i += 2
  } elseif ($a -eq '-h' -or $a -eq '--help') {
    Show-Usage; exit 0
  } elseif ($a.StartsWith('-')) {
    Die "plugin-profile: unknown flag: $a" 2
  } else {
    if ($Verb -eq '') { Die "plugin-profile: unknown verb: $a" 2 }
    if ($Spec -ne '') { Die "plugin-profile: one <spec> at a time -- saw '$Spec' and '$a'" 2 }
    $Spec = $a; $i++
  }
}

if ([string]::IsNullOrEmpty($Verb)) { Show-Usage; exit 2 }

if ($Verb -eq 'enable' -or $Verb -eq 'disable') {
  if ([string]::IsNullOrEmpty($Spec)) { Die "plugin-profile: $Verb needs a <spec>" 2 }
} elseif (-not [string]::IsNullOrEmpty($Spec)) {
  Die "plugin-profile: $Verb takes no <spec> (got '$Spec')" 2
}
if ($Json -and $Verb -ne 'list') { Die "plugin-profile: --json is only valid for 'list'" 2 }

# ── Pre-flight ────────────────────────────────────────────────────────────
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Die 'plugin-profile: claude CLI required on PATH' 1 }
if (-not (Test-Path $Template)) { Die "plugin-profile: template missing: $Template" 1 }
try { $tmpl = Get-Content -Raw $Template | ConvertFrom-Json } catch { Die "plugin-profile: template is not valid JSON: $Template" 1 }

# Read a possibly-absent JSON property without throwing / without the '@'
# character in a spec name confusing dot-indexing.
function Get-JsonProp($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

# ── Tier tables from the template ────────────────────────────────────────────
$AlwaysSpecs = @()
$enabledPlugins = Get-JsonProp $tmpl 'enabledPlugins'
if ($enabledPlugins) {
  foreach ($p in $enabledPlugins.PSObject.Properties) {
    if ($p.Value -eq $true) { $AlwaysSpecs += $p.Name }
  }
}
$OnDemandPlugins = Get-JsonProp $tmpl 'onDemandPlugins'
$OnDemandSpecs = @()
if ($OnDemandPlugins) { $OnDemandSpecs = @($OnDemandPlugins.PSObject.Properties.Name) }

# ── Live state: claude plugin list, USER scope only ──────────────────────────
# `claude plugin list` prints one stanza per (spec, scope) pair; we key on the
# USER scope because that is the only scope this script writes. Fail closed:
# a `plugin list` we could not run has told us NOTHING about the live state,
# so every read below would be a guess.
$listOutput = @(& claude plugin list 2>&1)
$listRc = $LASTEXITCODE
if ($listRc -ne 0) {
  [Console]::Error.WriteLine("plugin-profile: 'claude plugin list' failed -- cannot read live plugin state:")
  $listOutput | ForEach-Object { [Console]::Error.WriteLine("    $_") }
  exit 1
}

# Validate the observed CLI protocol before trusting an empty parse. Exit 0
# with garbage, a partial stanza, or an unknown status has proved no live state
# and must not make lean/full report a false no-op. The supported empty response
# is the real CLI's exact sentence; non-empty output is the observed header plus
# complete Version/Scope/Status stanzas. TrimEnd handles native CRLF capture.
function Stop-UnrecognizedList {
  Die "plugin-profile: 'claude plugin list' returned an unrecognized response -- cannot read live plugin state" 1
}
function Get-LiveMap([object[]]$Lines) {
  $clean = @($Lines | ForEach-Object { ([string]$_).TrimEnd("`r") })
  if ($clean.Count -eq 1 -and $clean[0] -ceq 'No plugins installed. Use `claude plugin install` to install a plugin.') {
    return @{}
  }
  if ($clean.Count -eq 0 -or $clean[0] -cne 'Installed plugins:') { Stop-UnrecognizedList }

  $map = @{}
  $spec = $null
  $scope = $null
  $stage = 0
  $count = 0
  for ($j = 1; $j -lt $clean.Count; $j++) {
    $line = $clean[$j]
    if ([string]::IsNullOrWhiteSpace($line)) {
      if ($stage -ne 0) { Stop-UnrecognizedList }
      continue
    }
    if ($line -match '^\s*❯\s+([A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+)\s*$') {
      if ($stage -ne 0) { Stop-UnrecognizedList }
      $spec = $Matches[1]
      $scope = $null
      $stage = 1
      $count++
      continue
    }
    if ($line -match '^\s*Version:\s+\S+\s*$') {
      if ($stage -ne 1) { Stop-UnrecognizedList }
      $stage = 2
      continue
    }
    if ($line -match '^\s*Scope:\s+(user|project|local)\s*$') {
      if ($stage -ne 2) { Stop-UnrecognizedList }
      $scope = $Matches[1]
      $stage = 3
      continue
    }
    if ($line -match '^\s*Status:\s+\S+\s+(enabled|disabled)\s*$') {
      if ($stage -ne 3) { Stop-UnrecognizedList }
      $state = $Matches[1]
      if ($scope -ceq 'user') { $map[$spec] = $state }
      $stage = 0
      continue
    }
    Stop-UnrecognizedList
  }
  if ($stage -ne 0 -or $count -eq 0) { Stop-UnrecognizedList }
  return $map
}
$LiveMap = Get-LiveMap $listOutput

function Get-LiveState([string]$spec) {
  if ($LiveMap.ContainsKey($spec)) { return $LiveMap[$spec] }
  return 'absent'
}

# ── Resolve a bare plugin name to a full spec ────────────────────────────────
# Only the template's own two tiers are searchable: resolving against the
# LIVE machine would let a stray third-party plugin answer to a himmel name.
function Resolve-Spec([string]$want) {
  if ($want -match '@') { return $want }
  $hits = @()
  foreach ($s in ($AlwaysSpecs + $OnDemandSpecs)) {
    $name = $s.Split('@')[0]
    if ($name -ceq $want) { $hits += $s }
  }
  $hits = @($hits | Sort-Object -Unique)
  if ($hits.Count -eq 0) {
    [Console]::Error.WriteLine("plugin-profile: '$want' is in neither tier of $Template.")
    [Console]::Error.WriteLine('  Run ''plugin-profile.ps1 list'' to see both tiers, or pass the full plugin@marketplace spec.')
    exit 2
  }
  if ($hits.Count -gt 1) {
    [Console]::Error.WriteLine("plugin-profile: '$want' is ambiguous -- pass the full plugin@marketplace spec. Candidates:")
    foreach ($h in $hits) { [Console]::Error.WriteLine("    $h") }
    exit 2
  }
  return $hits[0]
}

# ── The one writer ───────────────────────────────────────────────────────────
function Invoke-Apply([string]$Action, [string]$SpecArg) {
  # Enforce the floor HERE, not only at the single `disable <spec>` call site
  # below: the `lean`/`full` bulk loop calls Invoke-Apply directly, so a floor
  # refusal that lived solely at the single-spec site would never fire for it
  # -- a `--template` override that placed a floor plugin (e.g. qmd@himmel)
  # in onDemandPlugins would let a plain `lean` run disable it. Checking here
  # covers every caller in one place (HIMMEL-2733).
  if ($Action -eq 'disable' -and ($Floor -ccontains $SpecArg)) {
    [Console]::Error.WriteLine("plugin-profile: refusing to disable $SpecArg -- it is harness-operational (floor).")
    [Console]::Error.WriteLine("  The floor is $($Floor -join ' '); disabling one breaks the session running this command.")
    return $false
  }
  if ($DryRun) {
    Write-Host "DRY: claude plugin $Action $SpecArg --scope user"
    return $true
  }
  $out = & claude plugin $Action $SpecArg --scope user 2>&1
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    [Console]::Error.WriteLine("plugin-profile: 'claude plugin $Action $SpecArg --scope user' failed:")
    $out | ForEach-Object { [Console]::Error.WriteLine("    $_") }
    return $false
  }
  Write-Host "  user scope changed: $Action $SpecArg; project/local settings may override effective state"
  return $true
}

# ── list ─────────────────────────────────────────────────────────────────────
if ($Verb -eq 'list') {
  $onDemandConnectors = Get-JsonProp $tmpl 'onDemandConnectors'

  if ($Json) {
    $always = @()
    foreach ($s in $AlwaysSpecs) { $always += [PSCustomObject]@{ spec = $s; state = (Get-LiveState $s) } }

    $onDemand = @()
    foreach ($s in $OnDemandSpecs) {
      $entry = Get-JsonProp $OnDemandPlugins $s
      $onDemand += [PSCustomObject]@{ spec = $s; state = (Get-LiveState $s); neededBy = (Get-JsonProp $entry 'neededBy') }
    }

    $connectors = @()
    if ($onDemandConnectors) {
      foreach ($cname in $onDemandConnectors.PSObject.Properties.Name) {
        $c = Get-JsonProp $onDemandConnectors $cname
        $connectors += [PSCustomObject]@{
          name      = $cname
          neededBy  = (Get-JsonProp $c 'neededBy')
          enableVia = (Get-JsonProp $c 'enableVia')
        }
      }
    }

    [PSCustomObject]@{ always = $always; onDemand = $onDemand; connectors = $connectors } | ConvertTo-Json -Depth 10
    exit 0
  }

  Write-Host '──── ALWAYS tier (installed + enabled on every himmel machine) ────'
  foreach ($s in $AlwaysSpecs) { Write-Host "  [$(Get-LiveState $s)] $s" }
  Write-Host ''
  Write-Host '──── ON-DEMAND tier (installed, disabled -- enable when you need it) ────'
  foreach ($s in $OnDemandSpecs) {
    Write-Host "  [$(Get-LiveState $s)] $s"
    $entry = Get-JsonProp $OnDemandPlugins $s
    $nb = Get-JsonProp $entry 'neededBy'
    if (-not $nb) { $nb = '(unrecorded)' }
    Write-Host "        needed by: $nb"
  }
  Write-Host ''
  Write-Host '  enable one:  pwsh scripts/machine-setup/plugin-profile.ps1 enable <spec>'
  Write-Host '  back to lean: pwsh scripts/machine-setup/plugin-profile.ps1 lean'
  if ($onDemandConnectors) {
    $connNames = @($onDemandConnectors.PSObject.Properties.Name)
    if ($connNames.Count -gt 0) {
      Write-Host ''
      Write-Host '──── On-demand CONNECTORS (himmel does not install these) ────'
      foreach ($c in $connNames) {
        $obj = Get-JsonProp $onDemandConnectors $c
        $nb = Get-JsonProp $obj 'neededBy'; if (-not $nb) { $nb = '(unrecorded)' }
        $ev = Get-JsonProp $obj 'enableVia'; if (-not $ev) { $ev = '(unrecorded)' }
        Write-Host "  $c"
        Write-Host "        needed by: $nb"
        Write-Host "        enable via: $ev"
      }
    }
  }
  exit 0
}

# ── lean / full ──────────────────────────────────────────────────────────────
if ($Verb -eq 'lean' -or $Verb -eq 'full') {
  $Want = if ($Verb -eq 'lean') { 'disabled' } else { 'enabled' }
  $Act  = if ($Verb -eq 'lean') { 'disable' }  else { 'enable' }
  Write-Host "──── ${Verb}: bringing installed on-demand plugins to '$Want' (user scope) ────"
  $installed = 0
  $touched = 0
  $rc = 0
  foreach ($s in $OnDemandSpecs) {
    if ([string]::IsNullOrEmpty($s)) { continue }
    $st = Get-LiveState $s
    if ($st -eq 'absent') {
      Write-Host "  skip: $s (not installed at user scope -- run install-plugins.ps1)"
      continue
    }
    $installed++
    if ($st -eq $Want) { continue }
    if (-not (Invoke-Apply $Act $s)) { $rc = 1 }
    $touched++
  }
  if ($installed -eq 0) {
    Write-Host '  (no on-demand plugins installed at user scope -- nothing to change; project/local installs are outside this user-scope toggle)'
  } elseif ($touched -eq 0) {
    Write-Host "  (installed on-demand plugins at user scope already $Verb -- nothing to change; project/local settings may override effective state)"
  }
  exit $rc
}

# ── enable / disable one ─────────────────────────────────────────────────────
$Resolved = Resolve-Spec $Spec

if ($Verb -eq 'disable' -and ($Floor -ccontains $Resolved)) {
  [Console]::Error.WriteLine("plugin-profile: refusing to disable $Resolved -- it is harness-operational (floor).")
  [Console]::Error.WriteLine("  The floor is $($Floor -join ' '); disabling one breaks the session running this command.")
  exit 2
}

$State = Get-LiveState $Resolved
if ($State -eq 'absent') {
  [Console]::Error.WriteLine("plugin-profile: $Resolved is not installed at user scope.")
  [Console]::Error.WriteLine('  Install it first: pwsh scripts/machine-setup/install-plugins.ps1 -Scope user')
  exit 1
}

$WantState = if ($Verb -eq 'enable') { 'enabled' } else { 'disabled' }
if ($State -eq $WantState) {
  Write-Host "  user scope already ${WantState}: $Resolved; project/local settings may override effective state"
  exit 0
}

if (-not (Invoke-Apply $Verb $Resolved)) { exit 1 }

if ($Verb -eq 'enable' -and ($OnDemandSpecs -ccontains $Resolved)) {
  Write-Host '  note: this is an ON-DEMAND plugin. An opt-in reconcile'
  Write-Host '        (HIMMEL_RECONCILE_PLUGINS=1, e.g. via /himmel-update) writes the template'
  Write-Host '        map verbatim and will turn it back off. To keep it on permanently on THIS'
  Write-Host "        machine, record ""$Resolved"": true in ~/.claude/settings.local.json as"
  Write-Host '        reconciliation input. The next opt-in reconcile copies it into settings.json;'
  Write-Host '        the user sibling is not a Claude Code runtime settings layer.'
}
exit 0
