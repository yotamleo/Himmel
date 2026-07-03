#Requires -Version 7
<#
  claude-routed.ps1 - thin launcher: Claude Code on the LOCAL loopback OmniRoute
  router. HIMMEL-654 WS2 (child HIMMEL-666). PowerShell twin of scripts/claude-routed
  (bash), itself a copy-and-edit of claude-glm where ONLY the backend block differs
  (loopback router base URL + an OmniRoute-issued client key). Behaviour-parallel:
  same 7-var env contract; same exit codes on the enumerated paths (2 = missing key,
  3 = egress refusal, 4 = failed seed). A guard config (phi-roots / egress-denylist)
  that exists but is not a readable regular file also fails CLOSED with the bash-parity
  message ("guard config <path> exists but is not a readable file — failing closed.")
  and exit 3. Specs: WS1 wrapper himmel/specs/design/ws1-claude-glm-wrapper.md (the
  wrapper this edits); WS2 routed design himmel/specs/design/ws2-router-omniroute-pilot.md
  + plan himmel/specs/plan/ws2-router-omniroute-pilot.md (routed-specific rationale).

  Flags LEAD, then everything else passes to `claude` verbatim - mirrors the
  bash flags-lead rule. This is deliberately a PLAIN script with NO declared
  params. Declared params bind by PREFIX MATCH anywhere in argv (not just the
  leading position), so a real `claude` flag could be swallowed by a same-prefix
  launcher param wherever it appears; and attaching a [Parameter()] attribute (or
  [CmdletBinding()]) additionally enables common-parameter binding
  (-Debug/-Verbose/-ProgressAction/…), which would then hijack claude's
  `-d`/`-v`/`-p`. With no declared params, every arg lands in the automatic $args
  array as a literal string. Leading -Reseed/-Force are consumed manually by the
  loop below; the first non-flag stops flag parsing.
#>

$ErrorActionPreference = 'Stop'

# --- backend block (DIFFERS from claude-glm; this is the whole variant) --------
# Host is FIXED to loopback (127.0.0.1) — the spec mandates loopback-only, so it is
# NOT configurable. Only the PORT is an env seam (OMNIROUTE_PORT); the operator-gated
# router deploy (Task 2) records the real chosen port. 20128 is the source-read
# documented default. The Z.ai key must NEVER appear here — the router terminates the
# provider keys itself, so this launcher carries only the OmniRoute CLIENT key.
$Port          = if ($env:OMNIROUTE_PORT) { $env:OMNIROUTE_PORT } else { '20128' }
$RoutedBaseUrl = "http://127.0.0.1:$Port"
# Tier aliases are the SAME GLM values as claude-glm: the pilot lane is GLM-only
# intra-provider tiering and the router config defines these aliases.
$RoutedModel   = 'glm-5.2'
$RoutedHaiku   = 'glm-4.7'

# HOME equivalent: bash uses $HOME; here $env:USERPROFILE so hermetic tests can
# override the home root per-invocation (PowerShell's $HOME is fixed at startup).
$HomeDir   = $env:USERPROFILE
$ConfigDir = Join-Path $HomeDir '.claude-routed'   # per-lane isolation

# --- key resolution: process env first, else the launcher-repo .env ----------
# CLAUDE_ROUTED_DOTENV_ROOT (test hook) pins the .env root; production falls back to
# the launcher's parent dir (the himmel checkout), NOT the CWD repo - the
# motivating workload runs with cwd in the luna vault, whose .env has no OmniRoute key.
function Get-DotenvKey {
  param([string]$Root, [string]$Name)
  $envfile = Join-Path $Root '.env'
  if (-not (Test-Path -LiteralPath $envfile)) { return $null }
  foreach ($line in Get-Content -LiteralPath $envfile) {
    $l = $line.TrimEnd("`r")
    if ($l -eq '' -or $l.StartsWith('#')) { continue }
    $eq = $l.IndexOf('=')
    if ($eq -lt 0) { continue }
    if ($l.Substring(0, $eq).Trim() -ne $Name) { continue }
    $val = $l.Substring($eq + 1).Trim()
    if ($val.Length -ge 2 -and
        (($val[0] -eq '"' -and $val[-1] -eq '"') -or ($val[0] -eq "'" -and $val[-1] -eq "'"))) {
      $val = $val.Substring(1, $val.Length - 2)   # strip one optional quote pair
    }
    return $val   # first match wins
  }
  return $null
}

$key = $env:OMNIROUTE_API_KEY
if ([string]::IsNullOrEmpty($key)) {
  $root = if ($env:CLAUDE_ROUTED_DOTENV_ROOT) { $env:CLAUDE_ROUTED_DOTENV_ROOT } else { Split-Path -Parent $PSScriptRoot }
  $key = Get-DotenvKey -Root $root -Name 'OMNIROUTE_API_KEY'
}

if ([string]::IsNullOrEmpty($key)) {
  [Console]::Error.WriteLine('claude-routed: OMNIROUTE_API_KEY is not set. Export it or add it to the repo .env (never settings.json).')
  exit 2
}

# --- flags lead, rest passes to claude verbatim ------------------------------
$Reseed = $false
$Force  = $false
$ClaudeArgs = [System.Collections.Generic.List[string]]::new()
$leading = $true
foreach ($a in $args) {
  if ($leading -and ($a -ieq '-Reseed' -or $a -ieq '--reseed')) { $Reseed = $true; continue }
  if ($leading -and ($a -ieq '-Force'  -or $a -ieq '--force'))  { $Force  = $true; continue }
  $leading = $false
  $ClaudeArgs.Add($a)
}

# --- tiered egress guard -----------------------------------------------------
# Guard config dir is DELIBERATELY SHARED with claude-glm (~/.config/claude-glm),
# NOT a per-lane ~/.config/claude-routed: one guard source of truth means a PHI/
# egress rule written once governs every launcher variant. The routed lane is still
# GLM behind the router, so the exact same denylist/phi-roots policy applies.
$Cfg = Join-Path $HomeDir (Join-Path '.config' 'claude-glm')

function Test-PathUnderAny {
  # $Target is under some line of $ListFile. Windows paths: normalize separators
  # (config lines may use / or \), strip a trailing CR (CRLF config lines) then a
  # trailing separator, skip lines blank before AND after normalization, and
  # compare case-insensitively (NTFS/Windows paths are case-insensitive). Mirrors
  # the bash path_under_any incl. its CRLF + trailing-slash + empty-line fixes.
  param([string]$Target, [string]$ListFile)
  if (-not (Test-Path -LiteralPath $ListFile)) { return $false }
  $t = ($Target -replace '/', '\').TrimEnd('\')
  foreach ($root in Get-Content -LiteralPath $ListFile) {
    if ($null -eq $root) { continue }
    $r = $root.TrimEnd("`r")
    if ($r -eq '') { continue }
    $r = ($r -replace '/', '\').TrimEnd('\')
    if ($r -eq '') { continue }
    if (($t + '\').StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Assert-GuardReadable {
  # Fail CLOSED (exit 3) if a guard config EXISTS but is not a readable regular
  # file — an unreadable guard config must never silently allow egress. Bash parity
  # with path_under_any's rc=2 caller: same message, same exit 3. Mapping BOTH the
  # not-a-leaf case (e.g. phi-roots is a directory) and a leaf that Get-Content
  # cannot read (throws under ErrorActionPreference=Stop) here PREVENTS the raw
  # terminating exception (exit 1) that Test-PathUnderAny would otherwise surface.
  param([string]$ListFile)
  if (-not (Test-Path -LiteralPath $ListFile)) { return }   # absent = no restriction
  if (Test-Path -LiteralPath $ListFile -PathType Leaf) {
    try { [void](Get-Content -LiteralPath $ListFile -TotalCount 1 -ErrorAction Stop); return }
    catch { }
  }
  [Console]::Error.WriteLine("claude-routed: guard config $ListFile exists but is not a readable file — failing closed.")
  exit 3
}

$cwd = (Get-Location).ProviderPath
Assert-GuardReadable (Join-Path $Cfg 'phi-roots')
if ((Test-Path -LiteralPath (Join-Path $cwd '.salus')) -or (Test-PathUnderAny -Target $cwd -ListFile (Join-Path $Cfg 'phi-roots'))) {
  [Console]::Error.WriteLine('claude-routed: REFUSED - this workspace is PHI-marked (.salus / phi-roots). No override exists; PHI never goes to the routed GLM backend.')
  exit 3
}
Assert-GuardReadable (Join-Path $Cfg 'egress-denylist')
if (Test-PathUnderAny -Target $cwd -ListFile (Join-Path $Cfg 'egress-denylist')) {
  if ($Force) {
    [Console]::Error.WriteLine('claude-routed: WARNING - denylisted workspace, proceeding under --force. Content WILL be sent through the local OmniRoute router.')
  } else {
    [Console]::Error.WriteLine("claude-routed: REFUSED - workspace is on the egress denylist ($Cfg\egress-denylist). Re-run with --force to override.")
    exit 3
  }
}

# --- config-dir seeder -------------------------------------------------------
# Same allowlist as the bash twin; credentials/history never copied. settings
# sanitization delegates to the IDENTICAL node -e one-liner (no PS re-impl).
$SanitizerJs = @'
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
delete j.model;
if (j.env) for (const k of Object.keys(j.env)) if (k.indexOf("ANTHROPIC_")===0) delete j.env[k];
fs.writeFileSync(process.argv[2], JSON.stringify(j,null,2));
'@

function Copy-SeedConfig {
  # Transactional: the .seeded sentinel is removed FIRST and (re)written LAST, and
  # every Copy-Item/sanitize runs under ErrorActionPreference=Stop, so ANY failure
  # — first seed OR -Reseed — aborts with no sentinel and the next launch re-seeds.
  # Without the up-front delete a failed -Reseed would exit 4 yet leave a stale
  # sentinel, and the next plain launch would proceed with the half-populated tree.
  $src = Join-Path $HomeDir '.claude'
  Remove-Item -LiteralPath (Join-Path $ConfigDir '.seeded') -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path (Join-Path $ConfigDir 'plugins') | Out-Null
  $settings = Join-Path $src 'settings.json'
  if (Test-Path -LiteralPath $settings) {
    $sanitized = $false
    try {
      & node -e $SanitizerJs $settings (Join-Path $ConfigDir 'settings.json')
      $sanitized = ($LASTEXITCODE -eq 0)
    } catch {
      # node absent from PATH throws CommandNotFoundException (ErrorActionPreference
      # = Stop) BEFORE $LASTEXITCODE is ever set; without this catch it would
      # surface as a raw exit 1, violating the "4 = failed seed" contract. Map it
      # to the same failed-seed path as a nonzero sanitizer exit.
      $sanitized = $false
    }
    if (-not $sanitized) {
      [Console]::Error.WriteLine('claude-routed: FAILED to sanitize settings.json (node missing/broken?). Refusing to launch with an unseeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-routed).')
      exit 4
    }
  }
  # Parity with the bash twin's seed_fail=4 — any seed failure must exit 4, not raw 1 (CR F9, #830).
  try {
    foreach ($f in 'CLAUDE.md', 'RTK.md') {
      $p = Join-Path $src $f
      if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $ConfigDir $f) -Force }
    }
    foreach ($d in 'commands', 'skills', 'hooks', 'agents') {
      $p = Join-Path $src $d
      if (Test-Path -LiteralPath $p -PathType Container) { Copy-Item -LiteralPath $p -Destination $ConfigDir -Recurse -Force }
    }
    foreach ($p in 'installed_plugins.json', 'known_marketplaces.json') {
      $sp = Join-Path $src (Join-Path 'plugins' $p)
      if (Test-Path -LiteralPath $sp) { Copy-Item -LiteralPath $sp -Destination (Join-Path $ConfigDir (Join-Path 'plugins' $p)) -Force }
    }
    $mp = Join-Path $src (Join-Path 'plugins' 'marketplaces')
    if (Test-Path -LiteralPath $mp -PathType Container) { Copy-Item -LiteralPath $mp -Destination (Join-Path $ConfigDir 'plugins') -Recurse -Force }
    # sentinel LAST: only a fully-populated seed reads as "seeded"
    New-Item -ItemType File -Force -Path (Join-Path $ConfigDir '.seeded') | Out-Null
  } catch {
    [Console]::Error.WriteLine("claude-routed: FAILED to seed config dir ($($_.Exception.Message)). Refusing to launch with a half-seeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-routed).")
    exit 4
  }
}

if ((-not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) -or $Reseed) {
  Copy-SeedConfig
}

# --- off-peak annotation -----------------------------------------------------
# Peak window 14:00-18:00 UTC+8 == 06:00-10:00 UTC (unverified for the
# Anthropic-compatible endpoint - advisory only, spec Launch step 4). The routed
# lane is GLM behind the router, so the GLM peak-window advisory still applies.
$hourUtc = [DateTime]::UtcNow.Hour
if ($hourUtc -ge 6 -and $hourUtc -le 9) {
  [Console]::Error.WriteLine('claude-routed: inside GLM peak window (14:00-18:00 UTC+8); off-peak resumes 10:00 UTC. Advisory only.')
} else {
  [Console]::Error.WriteLine('claude-routed: outside GLM peak window (14:00-18:00 UTC+8). Advisory only.')
}

# --- launch: env contract mirrors the bash `exec env … claude "$@"` -----------
$env:ANTHROPIC_BASE_URL           = $RoutedBaseUrl
$env:ANTHROPIC_AUTH_TOKEN         = $key
$env:ANTHROPIC_MODEL              = $RoutedModel
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $RoutedHaiku
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $RoutedModel
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $RoutedModel
$env:CLAUDE_CONFIG_DIR            = $ConfigDir

& claude @ClaudeArgs
exit $LASTEXITCODE
