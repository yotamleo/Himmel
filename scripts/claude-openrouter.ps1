#Requires -Version 7
<#
  claude-openrouter.ps1 - thin launcher: Claude Code on the OpenRouter metered
  lane (HIMMEL-1774). PowerShell twin of scripts/claude-openrouter (bash), itself
  a copy-and-edit of claude-routed where the backend block differs (OpenRouter
  Anthropic-Messages-compatible endpoint + OPENROUTER_API_KEY + Claude 1M model
  pin). Behaviour-parallel: same env contract; same exit codes on the enumerated
  paths (2 = missing key / claude not on PATH, 3 = egress or PHI refusal / node
  missing, 4 = failed seed). A guard config (phi-roots / egress-denylist) that
  exists but is not a readable regular file fails CLOSED with the bash-parity
  message and exit 3.

  TWO OpenRouter-specific gates the siblings do not carry (HIMMEL-1774):
   1. Egress-matrix consultation (HARD gate, no override) — REFUSES fail-closed
      until the operator declares an explicit `openrouter` provider + cell in
      scripts/guardrails/egress-matrix.json. Reaching a Claude model THROUGH
      OpenRouter is NOT covered by the existing `anthropic` cell.
   2. Advisory remaining-credit surfacing (stderr) — a query failure is reported
      LOUDLY as UNKNOWN, never silent (the HIMMEL-1771 fail-open-silently class).

  Flags LEAD, then everything else passes to `claude` verbatim - mirrors the
  bash flags-lead rule. Plain script, NO declared params (prefix-match binding
  would swallow a real claude flag). Leading -Reseed/-Force are consumed
  manually; the first non-flag stops flag parsing.
#>

$ErrorActionPreference = 'Stop'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- backend block (DIFFERS from claude-routed; this is the whole variant) ------
# Claude Code speaks the Anthropic Messages API. OpenRouter exposes a NATIVE
# Anthropic-compatible endpoint at https://openrouter.ai/api (verified against
# OpenRouter's live API + docs, 2026-08-15) — NO loopback translation proxy is
# needed. OPENROUTER_ANTHROPIC_BASE_URL stays an env-overridable seam for a
# different Anthropic-Messages-compatible endpoint.
$OpenRouterAnthropicBaseUrl = if ($env:OPENROUTER_ANTHROPIC_BASE_URL) { $env:OPENROUTER_ANTHROPIC_BASE_URL } else { 'https://openrouter.ai/api' }
# Model pin (HIMMEL-1774 §5, verified 2026-08-15 against
# https://openrouter.ai/api/v1/models — 20 Anthropic models report
# context_length: 1000000): the 1M Claude tiers are NATIVELY 1M on OpenRouter;
# do NOT append ':extended' (no such variant exists). Default is the judge tier.
# Selectable without editing the launcher (OPENROUTER_MODEL env):
#   anthropic/claude-opus-5   (default — judge/orchestrator tier, 1M)
#   anthropic/claude-fable-5  (the judgment/taste escalation tier)
#   anthropic/claude-opus-5-fast
#   anthropic/claude-sonnet-5
# ':batch' variants exist for async pricing — opt in deliberately, never default.
$OpenRouterModel         = if ($env:OPENROUTER_MODEL) { $env:OPENROUTER_MODEL } else { 'anthropic/claude-opus-5' }
$OpenRouterHaiku         = if ($env:OPENROUTER_HAIKU) { $env:OPENROUTER_HAIKU } else { $OpenRouterModel }
$OpenRouterContextWindow = if ($env:OPENROUTER_CONTEXT_WINDOW) { $env:OPENROUTER_CONTEXT_WINDOW } else { '1000000' }
$OpenRouterApiBase       = if ($env:OPENROUTER_API_BASE) { $env:OPENROUTER_API_BASE } else { 'https://openrouter.ai/api/v1' }

# HOME equivalent: bash uses $HOME; here $env:USERPROFILE so hermetic tests can
# override the home root per-invocation.
$HomeDir   = $env:USERPROFILE
$ConfigDir = Join-Path $HomeDir '.claude-openrouter'
$RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path   # script lives in <repo>/scripts -> repo root (himmel-code corpus)

# --- key resolution: process env first, else the launcher-repo .env ----------
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

# HIMMEL-1482 (twin of bash _load_dotenv_primary_for): resolve the .env-bearing
# root for a candidate dir. <dir>/.env present -> <dir>. Else if <dir> is a
# linked git worktree -> the PRIMARY checkout when its .env exists, with ONE
# advisory to stderr. Otherwise -> <dir> unchanged.
function Resolve-DotenvPrimary {
  param([string]$Dir)
  if (Test-Path -LiteralPath (Join-Path $Dir '.env')) { return $Dir }
  try {
    $common = & git -C $Dir rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $common) { return $Dir }
    $dirAbs = (Resolve-Path -LiteralPath $Dir -ErrorAction Stop).Path
    $toplevel = & git -C $Dir rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $toplevel) { return $Dir }
    $toplevelAbs = (Resolve-Path -LiteralPath $toplevel -ErrorAction Stop).Path
    if (-not ($toplevelAbs -ieq $dirAbs)) { return $Dir }
    $gitdir = & git -C $Dir rev-parse --git-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $gitdir -or $gitdir -eq $common) { return $Dir }
    $commonFull = if ([System.IO.Path]::IsPathRooted($common)) { $common } else { Join-Path $Dir $common }
    $primary = (Resolve-Path -LiteralPath (Join-Path $commonFull '..') -ErrorAction Stop).Path
    if ($primary -ne $dirAbs -and (Test-Path -LiteralPath (Join-Path $primary '.env'))) {
      [Console]::Error.WriteLine("claude-openrouter: .env absent under worktree '$dirAbs' — reading the primary checkout's .env at '$primary'.")
      return $primary
    }
  } catch { }
  return $Dir
}

$key = $env:OPENROUTER_API_KEY
if ([string]::IsNullOrEmpty($key)) {
  $root = if ($env:CLAUDE_OPENROUTER_DOTENV_ROOT) { $env:CLAUDE_OPENROUTER_DOTENV_ROOT } else { Split-Path -Parent $PSScriptRoot }
  $root = Resolve-DotenvPrimary -Dir $root
  $key = Get-DotenvKey -Root $root -Name 'OPENROUTER_API_KEY'
}

if ([string]::IsNullOrEmpty($key)) {
  [Console]::Error.WriteLine('claude-openrouter: OPENROUTER_API_KEY is not set. Export it or add it to the repo .env (never settings.json).')
  exit 2
}

# node is REQUIRED to consult the egress matrix and to sanitize settings during
# seeding. Fail CLOSED if it is absent (HIMMEL-1771: cannot verify egress policy).
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine('claude-openrouter: node is required to consult the egress matrix and seed the config dir — refusing to launch without it.')
  exit 3
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

# --- tiered egress guard (PHI) -------------------------------------------------
# Guard config dir is SHARED with claude-glm (~/.config/claude-glm), matching
# claude-routed: one guard source of truth governs every variant.
# HIMMEL-1773 caveat: matches sibling STRUCTURE, NOT proven-correct on the real
# corpus — keys on a `.salus` marker the live vault lacks (it has .salus-profile)
# and the phi-roots fallback list is absent. Inherited defect; the egress
# matrix's salus hard-deny (consulted below) is the authoritative PHI backstop.
$Cfg = Join-Path $HomeDir (Join-Path '.config' 'claude-glm')

function Test-PathUnderAny {
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
  param([string]$ListFile)
  if (-not (Test-Path -LiteralPath $ListFile)) { return }   # absent = no restriction
  if (Test-Path -LiteralPath $ListFile -PathType Leaf) {
    try { [void](Get-Content -LiteralPath $ListFile -TotalCount 1 -ErrorAction Stop); return }
    catch { }
  }
  [Console]::Error.WriteLine("claude-openrouter: guard config $ListFile exists but is not a readable file — failing closed.")
  exit 3
}

$cwd = (Get-Location).ProviderPath
Assert-GuardReadable (Join-Path $Cfg 'phi-roots')
if ((Test-Path -LiteralPath (Join-Path $cwd '.salus')) -or (Test-PathUnderAny -Target $cwd -ListFile (Join-Path $Cfg 'phi-roots'))) {
  [Console]::Error.WriteLine('claude-openrouter: REFUSED - this workspace is PHI-marked (.salus / phi-roots). No override exists; PHI never goes to a cloud OpenRouter backend.')
  exit 3
}
Assert-GuardReadable (Join-Path $Cfg 'egress-denylist')
if (Test-PathUnderAny -Target $cwd -ListFile (Join-Path $Cfg 'egress-denylist')) {
  if ($Force) {
    [Console]::Error.WriteLine('claude-openrouter: WARNING - denylisted workspace, proceeding under --force. Content WILL be sent through OpenRouter.')
  } else {
    [Console]::Error.WriteLine("claude-openrouter: REFUSED - workspace is on the egress denylist ($Cfg\egress-denylist). Re-run with --force to override.")
    exit 3
  }
}

# --- egress-matrix consultation (HARD GATE, no override) ----------------------
# The authorizing gate: REFUSES fail-closed unless an explicit `openrouter`
# provider is declared AND a non-wildcard openrouter rule permits the launch
# corpus. No --force bypass (HIMMEL-1774). CLAUDE_OPENROUTER_EGRESS_MATRIX (test
# hook) points at a hermetic matrix. Delegates to the SAME node JS as the bash
# twin (no PS re-impl of the matrix semantics).
$EgressJs = @'
const fs=require("fs"), path=require("path");
const matrixPath=process.argv[1], repoRoot=process.argv[2];
let M;
try { M=JSON.parse(fs.readFileSync(matrixPath,"utf8")); }
catch (e) { console.error("claude-openrouter: egress matrix unreadable ("+matrixPath+"): "+(e.message||e)+" — failing closed."); process.exit(3); }
const PROVIDER="openrouter";
// This launcher performs INFERENCE (it runs Claude Code). A matrix rule
// authorizes the lane only when its purpose is "*" (any) or exactly the
// launcher purpose — a cell the operator scoped to a different purpose
// (embedding, extraction, ...) must NOT silently authorize an inference lane
// (CR round 2, HIMMEL-1774).
const PURPOSE="inference";
// 1. The provider itself must be DECLARED. A wildcard provider:"*" allow does
//    not authorize a new third-party routing layer in front of model vendors.
if (!M.providers || !Object.prototype.hasOwnProperty.call(M.providers, PROVIDER)) {
  console.error("claude-openrouter: REFUSED - provider \""+PROVIDER+"\" is not declared in the egress matrix ("+matrixPath+" -> providers). Reaching a Claude model through OpenRouter is a NEW third-party egress path (content transits OpenRouter) and is NOT covered by the existing \"anthropic\" cell. Declare it as an operator policy decision: add a providers."+PROVIDER+" entry plus a per-corpus rule.");
  process.exit(3);
}
// 2. Classify the launch corpus (most-restrictive). salus is already refused by
//    the path guard; treat it as deny here too. Vault corpora collapse to the
//    restrictive luna-personal label (fail-safe — they should stay DENY).
const cwd=process.env.CLAUDE_OPENROUTER_CWD || process.cwd();
// under(): equality counts (launching FROM the himmel checkout root itself is
// himmel-code, not "unknown" — a root-equal cwd must classify, not fall through).
const under=(root)=>{ try { const c=path.resolve(cwd).toLowerCase(), r=path.resolve(root).toLowerCase(); return !!root && (c===r || c.startsWith(r+path.sep)); } catch(_) { return false; } };
let corpus;
if (under(process.env.LUNA_VAULT_PATH) || under(process.env.LUNA_VAULT)) corpus="luna-personal";
else if (under(process.env.HANDOVER_DIR)) corpus="handover-state";
else if (under(repoRoot)) corpus="himmel-code";
else corpus="unknown";
// 3. Require an EXPLICIT openrouter rule (provider === PROVIDER, not "*")
//    permitting this corpus for this lane purpose (PURPOSE above), applying the
//    FIRST-MATCH-WINS semantics the matrix documents: among the explicit-provider
//    rows, the FIRST row matching (corpus, purpose) decides - including a deny.
//    Scanning past a deny to find a later permissive row would let a future
//    wildcard-corpus allow silently override an explicit vault deny, and the
//    matrix relies on row ORDER (the salus openrouter row is deliberately placed
//    above the wildcard hard deny so the ruling stays legible).
//    CR round 4, HIMMEL-1774.
let match=null;
for (const r of (M.rules||[])) {
  if (r.provider!==PROVIDER) continue;
  if (!(r.corpus==="*" || r.corpus===corpus)) continue;
  if (!(r.purpose==="*" || r.purpose===PURPOSE)) continue;
  match=r; break;
}
// A "conditional" cell is permitted ONLY while its condition holds. This
// launcher cannot evaluate matrix conditions, so it fails closed rather than
// launching as if the cell were unconditional (CR round 4, codex-3).
const allowed = !!match && (match.verdict==="allow" || match.verdict==="allow+log");
if (!allowed) {
  console.error("claude-openrouter: REFUSED - no egress-matrix cell permits \""+PROVIDER+"\" for corpus \""+corpus+"\" with purpose \""+PURPOSE+"\" ("+matrixPath+")"+(match?" - the first matching cell has verdict \""+match.verdict+"\"":"")+". Add a rule { corpus: \""+corpus+"\" (or \"*\"), provider: \""+PROVIDER+"\", purpose: \""+PURPOSE+"\" (or \"*\"), verdict: \"allow\" } ABOVE any row that denies it. Vault corpora (luna/salus) should stay DENY; himmel-code is the recommended first cell.");
  process.exit(3);
}
process.exit(0);
'@
$EgressMatrix = if ($env:CLAUDE_OPENROUTER_EGRESS_MATRIX) { $env:CLAUDE_OPENROUTER_EGRESS_MATRIX } else { Join-Path $PSScriptRoot (Join-Path 'guardrails' 'egress-matrix.json') }
& node -e $EgressJs $EgressMatrix $RepoRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

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
  $src = Join-Path $HomeDir '.claude'
  $sentinel = Join-Path $ConfigDir '.seeded'
  try {
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction Stop
  } catch [System.Management.Automation.ItemNotFoundException] {
    # already absent — goal reached.
  } catch {
    [Console]::Error.WriteLine("claude-openrouter: FAILED to clear stale .seeded sentinel ($($_.Exception.Message)). Refusing to reseed while a stale sentinel remains. Fix the cause and re-run (or rm -rf ~/.claude-openrouter).")
    exit 4
  }
  # The config dir must exist BEFORE the sanitizer below, which writes its
  # output to $ConfigDir/settings.json — on a first launch $ConfigDir does not
  # exist yet, so creating it later made seeding fail and misreport the cause as
  # "node missing/broken" (CR round 3, codex-1). Kept in its own handler so a
  # creation failure still surfaces as the documented exit-4 seed failure rather
  # than an unhandled error under $ErrorActionPreference='Stop' (codex-3).
  try {
    New-Item -ItemType Directory -Force -Path (Join-Path $ConfigDir 'plugins') | Out-Null
  } catch {
    [Console]::Error.WriteLine("claude-openrouter: FAILED to create the config dir $ConfigDir ($($_.Exception.Message)). Refusing to launch with an unseeded config dir. Fix the cause and re-run.")
    exit 4
  }
  $settings = Join-Path $src 'settings.json'
  if (Test-Path -LiteralPath $settings) {
    $sanitized = $false
    try {
      & node -e $SanitizerJs $settings (Join-Path $ConfigDir 'settings.json')
      $sanitized = ($LASTEXITCODE -eq 0)
    } catch { $sanitized = $false }
    if (-not $sanitized) {
      [Console]::Error.WriteLine('claude-openrouter: FAILED to sanitize settings.json (node missing/broken?). Refusing to launch with an unseeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-openrouter).')
      exit 4
    }
  }
  try {
    if (-not (Test-Path -LiteralPath $settings)) {
      $dst = Join-Path $ConfigDir 'settings.json'
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
    }
    foreach ($f in 'CLAUDE.md', 'RTK.md') {
      $p = Join-Path $src $f
      $dp = Join-Path $ConfigDir $f
      if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dp -Force }
      elseif (Test-Path -LiteralPath $dp) { Remove-Item -LiteralPath $dp -Force }
    }
    foreach ($d in 'commands', 'skills', 'hooks', 'agents') {
      $dst = Join-Path $ConfigDir $d
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
      $p = Join-Path $src $d
      if (Test-Path -LiteralPath $p -PathType Container) { Copy-Item -LiteralPath $p -Destination $ConfigDir -Recurse -Force }
    }
    foreach ($p in 'installed_plugins.json', 'known_marketplaces.json') {
      $sp = Join-Path $src (Join-Path 'plugins' $p)
      $dp = Join-Path $ConfigDir (Join-Path 'plugins' $p)
      if (Test-Path -LiteralPath $sp) { Copy-Item -LiteralPath $sp -Destination $dp -Force }
      elseif (Test-Path -LiteralPath $dp) { Remove-Item -LiteralPath $dp -Force }
    }
    $mdst = Join-Path $ConfigDir (Join-Path 'plugins' 'marketplaces')
    if (Test-Path -LiteralPath $mdst) { Remove-Item -LiteralPath $mdst -Recurse -Force }
    $mp = Join-Path $src (Join-Path 'plugins' 'marketplaces')
    if (Test-Path -LiteralPath $mp -PathType Container) { Copy-Item -LiteralPath $mp -Destination (Join-Path $ConfigDir 'plugins') -Recurse -Force }
    $hudCfg = Join-Path $src (Join-Path 'plugins' (Join-Path 'claude-hud' 'config.json'))
    $hudDst = Join-Path $ConfigDir (Join-Path 'plugins' (Join-Path 'claude-hud' 'config.json'))
    if (Test-Path -LiteralPath $hudCfg) {
      New-Item -ItemType Directory -Force -Path (Join-Path $ConfigDir (Join-Path 'plugins' 'claude-hud')) | Out-Null
      Copy-Item -LiteralPath $hudCfg -Destination $hudDst -Force
    } elseif (Test-Path -LiteralPath $hudDst) {
      Remove-Item -LiteralPath $hudDst -Force
    }
    New-Item -ItemType File -Force -Path (Join-Path $ConfigDir '.seeded') | Out-Null
  } catch {
    [Console]::Error.WriteLine("claude-openrouter: FAILED to seed config dir ($($_.Exception.Message)). Refusing to launch with a half-seeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-openrouter).")
    exit 4
  }
}

function Test-ConfigSeedStale {
  if ($env:CLAUDE_LANE_AUTO_RESEED -eq '0') { return $false }
  try {
    $sentinel = Join-Path $ConfigDir '.seeded'
    if (-not (Test-Path -LiteralPath $sentinel)) { return $false }
    $sentinelTime = (Get-Item -LiteralPath $sentinel).LastWriteTimeUtc
    $src = Join-Path $HomeDir '.claude'
    foreach ($rel in @('settings.json', 'CLAUDE.md', 'RTK.md', (Join-Path 'plugins' 'installed_plugins.json'), (Join-Path 'plugins' 'known_marketplaces.json'), (Join-Path 'plugins' (Join-Path 'claude-hud' 'config.json')))) {
      $s = Join-Path $src $rel
      $d = Join-Path $ConfigDir $rel
      if (Test-Path -LiteralPath $s) {
        if ((Get-Item -LiteralPath $s).LastWriteTimeUtc -gt $sentinelTime) { return $true }
      } elseif (Test-Path -LiteralPath $d) { return $true }
    }
    foreach ($rel in @('commands', 'skills', 'hooks', 'agents', (Join-Path 'plugins' 'marketplaces'))) {
      $s = Join-Path $src $rel
      $d = Join-Path $ConfigDir $rel
      if (Test-Path -LiteralPath $s -PathType Container) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { return $true }
        if ((Get-Item -LiteralPath $s).LastWriteTimeUtc -gt $sentinelTime) { return $true }
      } elseif (Test-Path -LiteralPath $d -PathType Container) { return $true }
    }
    return $false
  } catch { return $false }
}

# --- config-dir seed concurrency lock (HIMMEL-830) ---------------------------
$Lock            = "$ConfigDir.seed-lock"
$SeedLockTimeout = if ($env:CLAUDE_LANE_SEED_LOCK_TIMEOUT) { [int]$env:CLAUDE_LANE_SEED_LOCK_TIMEOUT } else { 60 }
$SeedLockStale   = if ($env:CLAUDE_LANE_SEED_LOCK_STALE) { [int]$env:CLAUDE_LANE_SEED_LOCK_STALE } else { 120 }

function Test-SeedLockStale {
  if (-not (Test-Path -LiteralPath $Lock -PathType Container)) { return $false }
  try {
    $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $Lock).LastWriteTimeUtc).TotalSeconds
    return ($age -ge $SeedLockStale)
  } catch { return $false }
}

function Invoke-SeedWithLock {
  $ticks = 0
  $maxTicks = $SeedLockTimeout * 2
  $lastAcquireErr = ''
  while ($true) {
    try {
      New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null
      break
    } catch {
      $lastAcquireErr = $_.Exception.Message
      if (Test-SeedLockStale) {
        try {
          Rename-Item -LiteralPath $Lock -NewName ((Split-Path -Leaf $Lock) + ".stale.$PID") -ErrorAction Stop
          try { [System.IO.Directory]::Delete("$Lock.stale.$PID") } catch { }
          continue
        } catch { }
      }
      if ($ticks -ge $maxTicks) {
        [Console]::Error.WriteLine("claude-openrouter: timed out after ${SeedLockTimeout}s waiting for the config-dir seed lock ($Lock). If no other claude-openrouter launch of this lane is seeding, remove that dir, or tune CLAUDE_LANE_SEED_LOCK_TIMEOUT / CLAUDE_LANE_SEED_LOCK_STALE; last acquire error: $lastAcquireErr")
        exit 4
      }
      Start-Sleep -Milliseconds 500
      $ticks++
    }
  }
  try {
    if ($Reseed -or (-not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) -or (Test-ConfigSeedStale)) {
      Copy-SeedConfig
    }
  } finally {
    try { [System.IO.Directory]::Delete($Lock) }
    catch { [Console]::Error.WriteLine("claude-openrouter: WARNING - failed to release seed lock $Lock (not empty or busy); it self-heals via stale steal after ${SeedLockStale}s but concurrent launches wait/time out until then.") }
  }
}

if ((-not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) -or $Reseed -or (Test-ConfigSeedStale)) {
  Invoke-SeedWithLock
}

# --- advisory remaining-credit surfacing (HIMMEL-1774 §4) --------------------
# Advisory (stderr); never gates the launch. A query failure is LOUDLY UNKNOWN
# (HIMMEL-1771). Runs only AFTER the egress gate authorized the lane; the credits
# call carries the key but NO corpus content.
$creditSurfaced = $false
try {
  $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -NoProxy -Method Get `
    -Headers @{Authorization="Bearer $key"} -Uri "$OpenRouterApiBase/credits"
  $j = $resp.Content | ConvertFrom-Json -ErrorAction Stop
  $d = if ($j.data) { $j.data } else { $j }
  if ($null -ne $d.total_credits -and $null -ne $d.total_usage) {
    $rem = ([double]$d.total_credits - [double]$d.total_usage).ToString('0.00')
    [Console]::Error.WriteLine("claude-openrouter: remaining metered credit: `$$rem (OpenRouter balance at $OpenRouterApiBase/credits). Advisory only.")
    $creditSurfaced = $true
  }
} catch { }
if (-not $creditSurfaced) {
  [Console]::Error.WriteLine("claude-openrouter: remaining metered credit: UNKNOWN (could not query $OpenRouterApiBase/credits). The metered balance is NOT verified — do not assume it is fine.")
}

# --- launch: env contract mirrors the bash twin ------------------------------
# ANTHROPIC_API_KEY is DELIBERATELY set EMPTY — load-bearing, not cosmetic: an
# inherited non-empty value would pull the SDK back onto its Anthropic-native
# auth path, while the empty key (plus the auth token above) is what forces the
# OpenRouter route (the shape every OpenRouter Claude Code example carries,
# verified 2026-08-15).
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine("claude-openrouter: 'claude' not found on PATH")
  exit 2
}
$env:ANTHROPIC_BASE_URL             = $OpenRouterAnthropicBaseUrl
$env:ANTHROPIC_AUTH_TOKEN           = $key
$env:ANTHROPIC_API_KEY              = ''
$env:ANTHROPIC_MODEL                = $OpenRouterModel
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $OpenRouterHaiku
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $OpenRouterModel
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $OpenRouterModel
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $OpenRouterContextWindow
$env:CLAUDE_CONFIG_DIR              = $ConfigDir

& claude @ClaudeArgs
exit $LASTEXITCODE
