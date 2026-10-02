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
#   anthropic/claude-opus-5.5 (default — parent tier, 1M)
#   anthropic/claude-fable-5  (the judgment/taste escalation tier)
#   anthropic/claude-opus-5-fast
#   anthropic/claude-sonnet-5
# ':batch' variants exist for async pricing — opt in deliberately, never default.
$OpenRouterModel         = if ($env:OPENROUTER_MODEL) { $env:OPENROUTER_MODEL } else { 'anthropic/claude-opus-5.5' }
# Independent subagent tiers (HIMMEL-4083), catalog verified 2026-10-02.
$OpenRouterHaiku         = if ($env:OPENROUTER_HAIKU) { $env:OPENROUTER_HAIKU } else { 'anthropic/claude-haiku-4.5' }
$OpenRouterSonnet        = if ($env:OPENROUTER_SONNET) { $env:OPENROUTER_SONNET } else { 'anthropic/claude-sonnet-5.5' }
$OpenRouterOpus          = if ($env:OPENROUTER_OPUS) { $env:OPENROUTER_OPUS } else { 'anthropic/claude-opus-5.5' }
# ponytail: offline Claude catalog snapshot (2026-10-02), refresh this allowlist
# and its bash twin when adopting a newly listed OpenRouter Claude slug.
$KnownTierSlugs = @(
  'anthropic/claude-sonnet-5.5', 'anthropic/claude-sonnet-5.5:batch',
  'anthropic/claude-opus-5.5', 'anthropic/claude-opus-5.5:batch',
  'anthropic/claude-fable-5.1', 'anthropic/claude-fable-5.1:batch',
  'anthropic/claude-opus-5', 'anthropic/claude-opus-5:batch',
  'anthropic/claude-sonnet-5', 'anthropic/claude-sonnet-5:batch',
  'anthropic/claude-fable-5', 'anthropic/claude-fable-5:batch',
  'anthropic/claude-opus-4.8', 'anthropic/claude-opus-4.8:batch',
  'anthropic/claude-opus-4.7', 'anthropic/claude-opus-4.7:batch',
  'anthropic/claude-sonnet-4.6', 'anthropic/claude-sonnet-4.6:batch',
  'anthropic/claude-opus-4.6', 'anthropic/claude-opus-4.6:batch',
  'anthropic/claude-opus-4.5', 'anthropic/claude-opus-4.5:batch',
  'anthropic/claude-haiku-4.5', 'anthropic/claude-haiku-4.5:batch',
  'anthropic/claude-sonnet-4.5', 'anthropic/claude-sonnet-4.5:batch',
  'anthropic/claude-opus-4.1', 'anthropic/claude-opus-4.1:batch',
  'anthropic/claude-sonnet-4'
)
function Assert-TierSlug([string]$Name, [string]$Slug) {
  if ($KnownTierSlugs -ccontains $Slug) { return }
  [Console]::Error.WriteLine("claude-openrouter: unknown or malformed $Name slug; use a Claude slug from the launcher catalog snapshot (2026-10-02), or update the snapshot before adopting a new model. Refusing to launch.")
  exit 2
}
Assert-TierSlug 'OPENROUTER_HAIKU' $OpenRouterHaiku
Assert-TierSlug 'OPENROUTER_SONNET' $OpenRouterSonnet
Assert-TierSlug 'OPENROUTER_OPUS' $OpenRouterOpus
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
// Marker detection uses the real cwd, never the caller-supplied test override.
let vaultMarker=false;
try {
 for(let p=fs.realpathSync(process.cwd());;p=path.dirname(p)) {
  const marker=path.join(p,".obsidian");
  if(fs.existsSync(marker)&&fs.statSync(marker).isDirectory()){vaultMarker=true;break;}
  if(path.dirname(p)===p)break;
 }
} catch(_) { console.error("claude-openrouter: cannot verify vault markers — failing closed."); process.exit(3); }
let corpus;
if (vaultMarker || under(process.env.LUNA_VAULT_PATH) || under(process.env.LUNA_VAULT)) corpus="luna-personal";
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

Import-Module (Join-Path $PSScriptRoot 'lane-mirror-seed.psm1') -Force
$LaneSeed = @{
  HomeDir = $HomeDir; ConfigDir = $ConfigDir; Lane = 'claude-openrouter'
  SanitizerJs = $SanitizerJs; Stamp = ''; StampRequired = $false; LeafOnly = $false
}
function Test-ConfigSeedStale { Test-LaneConfigSeedStale $LaneSeed }

# --- config-dir seed concurrency lock (HIMMEL-830) ---------------------------
$Lock            = "$ConfigDir.seed-lock"
$SeedLockTimeout = if ($env:CLAUDE_LANE_SEED_LOCK_TIMEOUT) { [int]$env:CLAUDE_LANE_SEED_LOCK_TIMEOUT } else { 60 }
$SeedLockStale   = if ($env:CLAUDE_LANE_SEED_LOCK_STALE) { [int]$env:CLAUDE_LANE_SEED_LOCK_STALE } else { 120 }

$LaneSeed.LockTimeout = $SeedLockTimeout
$LaneSeed.LockStale = $SeedLockStale

function Invoke-LegTrustSeed {
  # Only the primary checkout is trusted, under the existing seed lock.
  $savedGitEnv = @{}
  try {
    foreach ($name in 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE') {
      $savedGitEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
      [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $common = & git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve primary checkout for leg trust' }
    $primary = Split-Path -Parent $common
  } finally {
    foreach ($name in $savedGitEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedGitEnv[$name], 'Process') }
  }
  $trustJs = @'
const fs=require("fs"), p=process.argv[1], root=process.argv[2];
try {
  const j=fs.existsSync(p)?JSON.parse(fs.readFileSync(p,"utf8")):{};
  const object=v=>v && typeof v==="object" && !Array.isArray(v);
  if (!object(j) || (j.projects!==undefined && !object(j.projects))) throw Error("invalid lane config object");
  j.projects=j.projects||{};
  const project=j.projects[root]||{};
  if (!object(project)) throw Error("invalid primary project object");
  if (j.hasCompletedOnboarding===true && project.hasTrustDialogAccepted===true) process.exit(0);
  j.hasCompletedOnboarding=true;
  project.hasTrustDialogAccepted=true;
  j.projects[root]=project;
  const temp=p+".tmp."+process.pid;
  fs.writeFileSync(temp,JSON.stringify(j,null,2)+"\n",{mode:0o600});
  fs.renameSync(temp,p);
} catch(e) { console.error("claude-openrouter: leg onboarding seed failed: "+e.message); process.exit(4); }
'@
  & node -e $trustJs (Join-Path $ConfigDir '.claude.json') $primary
  if ($LASTEXITCODE -ne 0) { throw 'Failed to seed leg onboarding and primary-root trust' }
}

function Invoke-SeedWithLock {
  Invoke-LaneSeedWithLock $LaneSeed $Reseed {
    if ($env:LEG_LANE -eq 'openrouter') { Invoke-LegTrustSeed }
  }
}

if (($env:LEG_LANE -eq 'openrouter') -or (-not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) -or $Reseed -or (Test-ConfigSeedStale)) {
  Invoke-SeedWithLock
}

# --- remaining-credit GATE (HIMMEL-1774 §4, hardened by HIMMEL-4076) ----------
# Twin of the bash launcher: a balance below OPENROUTER_MIN_CREDIT_USD (default 3;
# non-numeric falls back to 3) or an UNKNOWN balance refuses with exit 5 BEFORE
# claude starts. Runs only AFTER the egress gate authorized the lane; the credits
# call carries the key but NO corpus content.
$minCredit = 3.0
$parsedMin = 0.0
if ($env:OPENROUTER_MIN_CREDIT_USD -and [double]::TryParse($env:OPENROUTER_MIN_CREDIT_USD, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedMin) -and -not [double]::IsNaN($parsedMin) -and -not [double]::IsInfinity($parsedMin) -and $parsedMin -ge 0) { $minCredit = $parsedMin }
function Test-OpenRouterNumber($value) {
  return (($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) -and -not [double]::IsNaN([double]$value) -and -not [double]::IsInfinity([double]$value))
}
$creditSurfaced = $false
$remVal = 0.0
try {
  $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -NoProxy -Method Get `
    -Headers @{Authorization="Bearer $key"} -Uri "$OpenRouterApiBase/credits"
  $j = $resp.Content | ConvertFrom-Json -ErrorAction Stop
  $d = if ($j.data) { $j.data } else { $j }
  if ((Test-OpenRouterNumber $d.total_credits) -and (Test-OpenRouterNumber $d.total_usage)) {
    $remVal = [double]$d.total_credits - [double]$d.total_usage
    $creditSurfaced = Test-OpenRouterNumber $remVal
  }
} catch { }
if (-not $creditSurfaced) {
  [Console]::Error.WriteLine("claude-openrouter: remaining metered credit: UNKNOWN (could not query $OpenRouterApiBase/credits). The metered balance is NOT verified; refusing to launch (exit 5).")
  exit 5
}
$rem = $remVal.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
[Console]::Error.WriteLine("claude-openrouter: remaining metered credit: `$$rem (OpenRouter balance at $OpenRouterApiBase/credits).")
if ($remVal -lt $minCredit) {
  [Console]::Error.WriteLine("claude-openrouter: remaining credit `$$rem is below the floor (OPENROUTER_MIN_CREDIT_USD=$minCredit); refusing to launch (exit 5).")
  exit 5
}
# Per-key monthly cap (GET /key): null limit = uncapped; unreadable or
# limit_remaining under the floor refuses (exit 5). Twin of the bash gate.
$keyKnown = $false
$keyCapped = $false
$keyVal = 0.0
try {
  $kresp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -NoProxy -Method Get `
    -Headers @{Authorization="Bearer $key"} -Uri "$OpenRouterApiBase/key"
  $kj = $kresp.Content | ConvertFrom-Json -ErrorAction Stop
  $kd = if ($kj.data) { $kj.data } else { $kj }
  if ($kd.PSObject.Properties['limit'] -and $null -eq $kd.limit) { $keyKnown = $true }
  elseif ((Test-OpenRouterNumber $kd.limit) -and (Test-OpenRouterNumber $kd.limit_remaining)) {
    $keyVal = [double]$kd.limit_remaining
    $keyKnown = $true
    $keyCapped = $true
  }
} catch { }
if (-not $keyKnown) {
  [Console]::Error.WriteLine("claude-openrouter: key limit_remaining: UNKNOWN (could not read $OpenRouterApiBase/key); refusing to launch (exit 5).")
  exit 5
}
$effVal = $remVal
$effSrc = 'credit'
if ($keyCapped) {
  $krem = $keyVal.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
  [Console]::Error.WriteLine("claude-openrouter: key limit_remaining: `$$krem (OpenRouter per-key cap at $OpenRouterApiBase/key).")
  if ($keyVal -lt $minCredit) {
    [Console]::Error.WriteLine("claude-openrouter: key limit_remaining `$$krem is below the floor (OPENROUTER_MIN_CREDIT_USD=$minCredit) or exhausted; refusing to launch (exit 5).")
    exit 5
  }
  if ($keyVal -lt $remVal) { $effVal = $keyVal; $effSrc = 'key limit_remaining' }
}
$eff = $effVal.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
[Console]::Error.WriteLine("claude-openrouter: effective balance `$$eff ($effSrc).")

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
if ($env:LEG_LANE -eq 'openrouter') {
  # Use an alias only when it resolves to the exact session pin.
  if ($OpenRouterModel -like 'anthropic/claude-sonnet-*' -and $OpenRouterModel -ceq $OpenRouterSonnet) { $env:ANTHROPIC_MODEL = 'sonnet' }
  elseif ($OpenRouterModel -like 'anthropic/claude-opus-*' -and $OpenRouterModel -ceq $OpenRouterOpus) { $env:ANTHROPIC_MODEL = 'opus' }
}
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $OpenRouterHaiku
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $OpenRouterSonnet
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $OpenRouterOpus
$orLabel = $OpenRouterModel
if ($OpenRouterModel -match '^anthropic/claude-(sonnet|opus|fable)-(.+)$') {
  $family = $Matches[1]
  $orLabel = $family.Substring(0, 1).ToUpperInvariant() + $family.Substring(1) + ' ' + $Matches[2] + ' (OpenRouter)'
}
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME  = if ($OpenRouterHaiku -eq $OpenRouterModel) { $orLabel } else { $OpenRouterHaiku }
$env:ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = if ($OpenRouterSonnet -ceq $OpenRouterModel) { $orLabel } else { $OpenRouterSonnet }
$env:ANTHROPIC_DEFAULT_OPUS_MODEL_NAME   = if ($OpenRouterOpus -ceq $OpenRouterModel) { $orLabel } else { $OpenRouterOpus }
# ponytail: client-side auto classifier through the gateway (HIMMEL-4086),
# remove this temporary switch when safeguards/safeguard_results pass through.
$env:CLAUDE_CODE_AUTO_MODE_SERVER = '0'
if ($env:LEG_LANE -eq 'openrouter') {
  [Console]::Error.WriteLine("claude-openrouter: lane=openrouter slug=$OpenRouterModel alias=$($env:ANTHROPIC_MODEL) labels=$orLabel")
}
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $OpenRouterContextWindow
$env:CLAUDE_CONFIG_DIR              = $ConfigDir

& claude @ClaudeArgs
exit $LASTEXITCODE
