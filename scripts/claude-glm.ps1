#Requires -Version 7
<#
  claude-glm.ps1 - thin launcher: Claude Code on the Z.ai GLM flat-rate lane.
  HIMMEL-654 WS1 (child HIMMEL-665). PowerShell twin of scripts/claude-glm
  (bash). Behaviour-parallel: same 7-var env contract; same exit codes on the
  enumerated paths (2 = missing key, 3 = egress refusal / unreadable guard
  config, 4 = failed seed, 5 = claude not on PATH). A guard config (phi-roots /
  egress-denylist) that exists but is not a readable regular file fails CLOSED
  with the bash-parity message ("guard config <path> exists but is not a
  readable file — failing closed.") and exit 3. Any OTHER failure fails CLOSED
  via a PowerShell terminating error (exit 1) rather than matching the bash
  exit code. Spec: himmel/specs/design/ws1-claude-glm-wrapper.md

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

$GlmBaseUrl = 'https://api.z.ai/api/anthropic'
# [1m] = Z.ai 1M-context variant; $GlmContextWindow feeds CLAUDE_CODE_AUTO_COMPACT_WINDOW
# (env block below) so Claude Code stops auto-compacting at ~200k. Both overridable per
# task (small: $env:GLM_MODEL='glm-5.2' + $env:GLM_CONTEXT_WINDOW='200000'). HAIKU stays 4.7.
$GlmModel         = if ($env:GLM_MODEL) { $env:GLM_MODEL } else { 'glm-5.2[1m]' }
$GlmHaiku         = 'glm-4.7'
$GlmContextWindow = if ($env:GLM_CONTEXT_WINDOW) { $env:GLM_CONTEXT_WINDOW } else { '1000000' }
# CodeRabbit (HIMMEL-1027): validate the override — a non-positive-integer value
# falls back to the default; above the Z.ai [1m] ceiling WARNS but is honored
# (warn-not-clamp, twin-parity with the bash launcher + claude-codex).
[long]$GlmCtxParsed = 0
if (-not [long]::TryParse($GlmContextWindow, [ref]$GlmCtxParsed) -or $GlmCtxParsed -le 0) {
  [Console]::Error.WriteLine("claude-glm: WARNING - GLM_CONTEXT_WINDOW='$GlmContextWindow' is not a positive integer; using 1000000.")
  $GlmContextWindow = '1000000'
} elseif ($GlmCtxParsed -gt 1000000) {
  [Console]::Error.WriteLine("claude-glm: WARNING - GLM_CONTEXT_WINDOW=$GlmCtxParsed exceeds the Z.ai glm-5.2[1m] 1000000 ceiling. Proceeding as set.")
}

# HOME equivalent: bash uses $HOME; here $env:USERPROFILE so hermetic tests can
# override the home root per-invocation (PowerShell's $HOME is fixed at startup).
$HomeDir   = $env:USERPROFILE
$ConfigDir = Join-Path $HomeDir '.claude-glm'
# Sanitizer generation, stamped into the .seeded sentinel — keep in lockstep with
# claude-glm's SEED_VERSION. BUMP whenever the sanitizer TIGHTENS: a config dir
# seeded under the older, laxer rule is otherwise kept until the SOURCE
# settings.json happens to change, so a previously-persisted forbidden key would
# linger past the fix (CR). A mismatch forces exactly one re-seed.
# v2 = strip env.ANTHROPIC_*/CLAUDE_CODE_USE_* case-insensitively.
$SeedVersion = '2'

# --- key resolution: process env first, else the launcher-repo .env ----------
# CLAUDE_GLM_DOTENV_ROOT (test hook) pins the .env root; production falls back to
# the launcher's parent dir (the himmel checkout), NOT the CWD repo - the
# motivating workload runs with cwd in the luna vault, whose .env has no ZAI key.
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

$key = $env:ZAI_API_KEY
if ([string]::IsNullOrEmpty($key)) {
  $root = if ($env:CLAUDE_GLM_DOTENV_ROOT) { $env:CLAUDE_GLM_DOTENV_ROOT } else { Split-Path -Parent $PSScriptRoot }
  $key = Get-DotenvKey -Root $root -Name 'ZAI_API_KEY'
}

if ([string]::IsNullOrEmpty($key)) {
  [Console]::Error.WriteLine('claude-glm: ZAI_API_KEY is not set. Export it or add it to the repo .env (never settings.json).')
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

# Harness-integrity arg screen (HIMMEL-1040): $ClaudeArgs pass to claude verbatim
# via `& claude @ClaudeArgs` below, so a --settings payload that injected
# env.ANTHROPIC_* / CLAUDE_CODE_USE_* could redirect this lane away from the z.ai
# endpoint. Screen it (fail-closed on unparseable) — the twin of claude-codex.ps1's
# Test-SettingsArgOrRefuse. Scoped to --settings only (the glm lane's trust boundary
# is the tiered egress guard below, not a proxy; --bare/--add-dir out of scope).
# TOCTOU (CR): a FILE-backed --settings must not be forwarded as a PATH — claude
# would re-read it after the screen passed, so a swap in that window defeats the
# check. Get-ScreenedSettings therefore RETURNS the value to forward: an inline
# payload verbatim (already immutable), a file payload MATERIALIZED to inline JSON
# captured at validation time. The caller-controlled path never reaches claude.
function Get-ScreenedSettings {
  param([string]$Value)
  $bad = $false
  $forward = $null
  try {
    $inline = $Value.Trim().StartsWith('{')
    $raw = if ($inline) { $Value } else { Get-Content -LiteralPath $Value -Raw -ErrorAction Stop }
    $j = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($j -and $j.env) {
      foreach ($p in $j.env.PSObject.Properties) {
        $u = $p.Name.ToUpperInvariant()
        if ($u.StartsWith('ANTHROPIC_') -or $u.StartsWith('CLAUDE_CODE_USE_')) { $bad = $true; break }
      }
    }
    # Inline forwards verbatim (no round-trip mangling); only a file payload is
    # re-serialized, which it must be to break the re-read.
    if (-not $bad) { $forward = if ($inline) { $Value } else { $j | ConvertTo-Json -Depth 100 -Compress } }
  } catch { $bad = $true }
  if ($bad) {
    [Console]::Error.WriteLine('claude-glm: REFUSED - --settings payload sets env.ANTHROPIC_* / CLAUDE_CODE_USE_* (or is unparseable/unreadable); it would redirect this lane away from the z.ai endpoint.')
    exit 3
  }
  return $forward
}

# Rebuild the args with every --settings value replaced by its screened
# (materialized) form, so what reaches claude is exactly what was validated.
$screened = [System.Collections.Generic.List[string]]::new()
$pending = ''
foreach ($a in $ClaudeArgs) {
  if ($pending -eq 'settings') {
    $screened.Add((Get-ScreenedSettings -Value $a))
    $pending = ''
    continue
  }
  if ($a -eq '--settings') { $pending = 'settings'; $screened.Add($a); continue }
  if ($a -like '--settings=*') {
    $screened.Add('--settings=' + (Get-ScreenedSettings -Value $a.Substring('--settings='.Length)))
    continue
  }
  $screened.Add($a)
}
# A trailing bare --settings (no value) leaves $pending set and unscreened — refuse
# it before launch rather than forwarding a broken flag to claude.
if ($pending -eq 'settings') {
  [Console]::Error.WriteLine('claude-glm: REFUSED - trailing --settings with no value.')
  exit 3
}
# Hand the LAUNCH the screened argv (file-backed --settings now materialized inline).
$ClaudeArgs = $screened

# --- tiered egress guard -----------------------------------------------------
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
  [Console]::Error.WriteLine("claude-glm: guard config $ListFile exists but is not a readable file — failing closed.")
  exit 3
}

$cwd = (Get-Location).ProviderPath
Assert-GuardReadable (Join-Path $Cfg 'phi-roots')
if ((Test-Path -LiteralPath (Join-Path $cwd '.salus')) -or (Test-PathUnderAny -Target $cwd -ListFile (Join-Path $Cfg 'phi-roots'))) {
  [Console]::Error.WriteLine('claude-glm: REFUSED - this workspace is PHI-marked (.salus / phi-roots). No override exists; PHI never goes to a cloud GLM backend.')
  exit 3
}
Assert-GuardReadable (Join-Path $Cfg 'egress-denylist')
if (Test-PathUnderAny -Target $cwd -ListFile (Join-Path $Cfg 'egress-denylist')) {
  if ($Force) {
    [Console]::Error.WriteLine('claude-glm: WARNING - denylisted workspace, proceeding under --force. Content WILL be sent to Z.ai.')
  } else {
    [Console]::Error.WriteLine("claude-glm: REFUSED - workspace is on the egress denylist ($Cfg\egress-denylist). Re-run with --force to override.")
    exit 3
  }
}

# --- config-dir seeder -------------------------------------------------------
# Same allowlist as the bash twin; credentials/history never copied. settings
# sanitization delegates to the IDENTICAL node -e one-liner (no PS re-impl).
# CR: the seeded settings.json is an overlay claude reads at launch, so it must
# strip the SAME keys the --settings arg screen rejects, on the SAME terms —
# case-INSENSITIVELY and including CLAUDE_CODE_USE_* (BEDROCK/VERTEX/…). The old
# rule (case-sensitive, ANTHROPIC_* only) let the seed inject exactly the backend
# redirect the screen blocks. Byte-identical to claude-glm's sanitize_settings JS.
$SanitizerJs = @'
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
delete j.model;
if (j.env) for (const k of Object.keys(j.env)) {
  const u=k.toUpperCase();
  if (u.indexOf("ANTHROPIC_")===0 || u.indexOf("CLAUDE_CODE_USE_")===0) delete j.env[k];
}
fs.writeFileSync(process.argv[2], JSON.stringify(j,null,2));
'@

function Copy-SeedConfig {
  # Transactional: the .seeded sentinel is removed FIRST and (re)written LAST, and
  # every Copy-Item/sanitize runs under ErrorActionPreference=Stop, so ANY failure
  # — first seed OR -Reseed — aborts with no sentinel and the next launch re-seeds.
  # Without the up-front delete a failed -Reseed would exit 4 yet leave a stale
  # sentinel, and the next plain launch would proceed with the half-populated tree.
  $src = Join-Path $HomeDir '.claude'
  # The up-front delete is part of that exit-4 contract, so a REAL removal failure
  # must NOT be swallowed (HIMMEL-820 CR: codex-adv [high] + silent-failure-hunter
  # convergence). A blanket -ErrorAction SilentlyContinue hid a locked/ACL-denied
  # .seeded: the reseed then threw later and exited 4, but the OLD sentinel survived
  # next to a half-seeded tree, and a plain relaunch read it as "seeded" and launched
  # on the corrupt tree.
  # HIMMEL-828 Part A — race-free, mirroring bash `rm -f`: do NOT Test-Path-then-Remove
  # (a concurrent reseed sharing this config dir can delete the sentinel in that window,
  # so Remove-Item throws ItemNotFound even though sentinel-ABSENT is the desired end
  # state → a spurious exit 4). Attempt the removal unconditionally and treat a
  # missing-file (ItemNotFoundException) as success (goal reached); only a genuine
  # lock/ACL failure (the file is still there) exits 4.
  $sentinel = Join-Path $ConfigDir '.seeded'
  try {
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction Stop
  } catch [System.Management.Automation.ItemNotFoundException] {
    # already absent (first seed, or a concurrent reseed beat us to it) — goal reached.
  } catch {
    [Console]::Error.WriteLine("claude-glm: FAILED to clear stale .seeded sentinel ($($_.Exception.Message)). Refusing to reseed while a stale sentinel remains. Fix the cause and re-run (or rm -rf ~/.claude-glm).")
    exit 4
  }
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
      [Console]::Error.WriteLine('claude-glm: FAILED to sanitize settings.json (node missing/broken?). Refusing to launch with an unseeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-glm).')
      exit 4
    }
  }
  # Function-level seed wrap (HIMMEL-820, parity with routed's CR-F9 #830): the
  # remaining seed body — settings-absent mirror, CLAUDE.md/RTK.md copy, the
  # commands/skills/hooks/agents + marketplaces re-mirror, plugin-manifest
  # copy/delete, and the claude-hud config — all run under
  # ErrorActionPreference=Stop, so a Copy-Item/Remove-Item failure (locked file,
  # ACL denial) must map to the "4 = failed seed" contract, NOT surface as a raw
  # exit 1. #1044 left these blocks outside any try/catch (only claude-hud was
  # wrapped); this extends the wrap to the whole body, matching the routed twin.
  # The .seeded sentinel is written LAST inside this try, so any throw aborts with
  # no sentinel and the next launch re-seeds.
  try {
    if (-not (Test-Path -LiteralPath $settings)) {
      # True mirror (HIMMEL-819): a deleted source must not leave a stale copy
      # steering the lane — same rationale as the subtree re-mirror below.
      $dst = Join-Path $ConfigDir 'settings.json'
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
    }
    # Leaf files mirror deletion too (HIMMEL-828/819): CLAUDE.md literally steers the
    # lane, so a deleted source must not leave a stale copy behind — same as settings.
    foreach ($f in 'CLAUDE.md', 'RTK.md') {
      $p = Join-Path $src $f
      $dp = Join-Path $ConfigDir $f
      if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dp -Force }
      elseif (Test-Path -LiteralPath $dp) { Remove-Item -LiteralPath $dp -Force }
    }
    # Clean re-mirror + deletion mirror (HIMMEL-828/819): remove the destination subtree
    # FIRST — this both drops files deleted from the source AND mirrors a whole-subtree
    # deletion (a removed command/hook/skill must not linger steering the cloud lane:
    # "a deleted source must not leave a stale copy steering the lane") — then copy only
    # when the source still exists. No-op on the first seed. A REAL removal failure
    # (locked file, ACL denial) terminates under Stop and is caught below — same "no
    # sentinel on any failure" contract. Symmetric with the settings/manifest mirror.
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
    # claude-hud DISPLAY config — seed the single config.json only; the cache dirs
    # under plugins/claude-hud/ are runtime state, never seeded. Source-absent → mirror
    # the deletion (HIMMEL-828/819).
    $hudCfg = Join-Path $src (Join-Path 'plugins' (Join-Path 'claude-hud' 'config.json'))
    $hudDst = Join-Path $ConfigDir (Join-Path 'plugins' (Join-Path 'claude-hud' 'config.json'))
    if (Test-Path -LiteralPath $hudCfg) {
      New-Item -ItemType Directory -Force -Path (Join-Path $ConfigDir (Join-Path 'plugins' 'claude-hud')) | Out-Null
      Copy-Item -LiteralPath $hudCfg -Destination $hudDst -Force
    } elseif (Test-Path -LiteralPath $hudDst) {
      Remove-Item -LiteralPath $hudDst -Force
    }
    # sentinel LAST: only a fully-populated seed reads as "seeded"; stamped with the
    # sanitizer generation so a tightened rule re-seeds once (twin: SEED_VERSION).
    Set-Content -LiteralPath (Join-Path $ConfigDir '.seeded') -Value $SeedVersion
  } catch {
    [Console]::Error.WriteLine("claude-glm: FAILED to seed config dir ($($_.Exception.Message)). Refusing to launch with a half-seeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-glm).")
    exit 4
  }
}

# Staleness-aware reseed (HIMMEL-819): a once-only seed strands lane workers on
# whatever plugin/settings profile existed at first launch — the operator's lean
# enabledPlugins profile never reaches the lane, so every worker pays duplicated
# plugin context + duplicate MCP invocations. Track every allowlisted leaf source
# (settings, CLAUDE.md, RTK.md, the two plugin manifests, claude-hud config — newer
# than the sentinel OR deleted while a lane copy remains) AND the copied subtrees
# (HIMMEL-828 Part B — a half-seeded/externally-removed subtree, a command/skill
# added/removed at the top level, or a deleted source, self-heals on plain launch); a
# deep in-file edit inside a subtree still needs -Reseed (directory mtime granularity).
# Opt-out: CLAUDE_LANE_AUTO_RESEED=0 restores the once-only seed (first seed +
# explicit -Reseed only) — the escape hatch if auto-reseed ever blocks a
# launch in your setup (e.g. seed re-runs surfacing a broken node).
function Test-ConfigSeedStale {
  # Sanitizer-generation migration — checked BEFORE the freshness opt-out (CR).
  # A seed written by an older, laxer sanitizer can carry a forbidden env key
  # (e.g. CLAUDE_CODE_USE_BEDROCK) that silently reroutes an unattended lane off
  # z.ai. CLAUDE_LANE_AUTO_RESEED=0 is an escape hatch for freshness CHURN — it
  # must NOT keep a poisoned config loaded, so a generation mismatch always
  # re-seeds regardless (twin: config_seed_stale).
  $sentinelEarly = Join-Path $ConfigDir '.seeded'
  if (Test-Path -LiteralPath $sentinelEarly) {
    $stampEarly = (Get-Content -LiteralPath $sentinelEarly -Raw -ErrorAction SilentlyContinue)
    if (($null -eq $stampEarly) -or ($stampEarly.Trim() -ne $SeedVersion)) { return $true }
  }
  if ($env:CLAUDE_LANE_AUTO_RESEED -eq '0') { return $false }
  # try/catch: the predicate must never block a launch. A TOCTOU race (file
  # deleted between Test-Path and Get-Item under ErrorActionPreference=Stop)
  # reads as not-stale — worst case a slightly stale config, never an abort.
  # (The bash twin's [ -f ] && [ -nt ] is race-safe by construction.)
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
      } elseif (Test-Path -LiteralPath $d) {
        return $true  # source deleted but lane copy remains — reseed mirrors the removal
      }
    }
    # HIMMEL-828 Part B — also track the copied subtrees, fully symmetric with the
    # settings/manifest loop above, so a half-seeded OR a source-deleted subtree
    # self-heals on a plain launch. Per subtree: SOURCE present but DEST missing = a
    # half-seed → reseed; SOURCE newer than the sentinel = top-level drift → reseed;
    # SOURCE absent but DEST present = a deleted source whose lane copy lingers → reseed
    # (the seeder mirrors the deletion, so this fires once then clears — no churn).
    foreach ($rel in @('commands', 'skills', 'hooks', 'agents', (Join-Path 'plugins' 'marketplaces'))) {
      $s = Join-Path $src $rel
      $d = Join-Path $ConfigDir $rel
      if (Test-Path -LiteralPath $s -PathType Container) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { return $true }
        if ((Get-Item -LiteralPath $s).LastWriteTimeUtc -gt $sentinelTime) { return $true }
      } elseif (Test-Path -LiteralPath $d -PathType Container) {
        return $true  # source deleted but lane copy remains — reseed mirrors the removal
      }
    }
    return $false
  } catch {
    return $false
  }
}

# --- config-dir seed concurrency lock (HIMMEL-830) ---------------------------
# Serialize concurrent same-lane reseeds so two launches of THIS lane cannot
# interleave Copy-SeedConfig's remove/copy sequence into a torn config dir (the
# .seeded sentinel guards FAILED seeds, not CONCURRENT ones). The lock is a
# DIRECTORY sibling of $ConfigDir (NOT under it, so the seeder's own recursive
# removes can never delete it); New-Item -ItemType Directory is atomic and throws
# if it already exists. The dir is kept EMPTY so the release remove is atomic and
# steal-safe. Env names + defaults + rc=4 mirror the bash twin exactly.
$Lock            = "$ConfigDir.seed-lock"
$SeedLockTimeout = if ($env:CLAUDE_LANE_SEED_LOCK_TIMEOUT) { [int]$env:CLAUDE_LANE_SEED_LOCK_TIMEOUT } else { 60 }   # seconds to wait
$SeedLockStale   = if ($env:CLAUDE_LANE_SEED_LOCK_STALE) { [int]$env:CLAUDE_LANE_SEED_LOCK_STALE } else { 120 }     # seconds before a held lock is presumed abandoned

function Test-SeedLockStale {
  # $true when $Lock exists and its mtime is older than $SeedLockStale seconds.
  if (-not (Test-Path -LiteralPath $Lock -PathType Container)) { return $false }
  try {
    $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $Lock).LastWriteTimeUtc).TotalSeconds
    return ($age -ge $SeedLockStale)
  } catch { return $false }
}

function Invoke-SeedWithLock {
  # Acquire (New-Item dir), poll on contention, steal a stale holder, or time out (exit 4).
  $ticks = 0
  $maxTicks = $SeedLockTimeout * 2   # two 500ms polls per second
  $lastAcquireErr = ''
  while ($true) {
    try {
      New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null
      break   # acquired
    } catch {
      $lastAcquireErr = $_.Exception.Message
      # SINGLE-WINNER stale steal via atomic same-dir rename: only ONE waiter's
      # Rename-Item succeeds (the path is gone for every loser, whose rename simply
      # throws), and the winner's FRESH replacement lock can never be renamed away
      # by a queued loser (a fresh lock is never stale). A plain remove steal is a
      # TOCTOU double-acquire: two waiters both judge the dead lock stale, one
      # removes+re-acquires, the other's queued remove then deletes the winner's
      # fresh EMPTY lock, both seed concurrently -- the torn config this lock
      # exists to prevent. The renamed dir is removed best-effort with the
      # empty-only [IO.Directory]::Delete (rmdir parity; no -Recurse vaporizing);
      # if it was non-empty (invariant violation) the orphan is harmless -- it is
      # not the lock path. Accepted residual: a LIVE seeder holding the lock past
      # $SeedLockStale gets stolen -- but seeds are sub-second copies, so a hold
      # that long means a dead/hung holder in practice.
      if (Test-SeedLockStale) {
        try {
          Rename-Item -LiteralPath $Lock -NewName ((Split-Path -Leaf $Lock) + ".stale.$PID") -ErrorAction Stop
          try { [System.IO.Directory]::Delete("$Lock.stale.$PID") } catch { }   # orphaned .stale dir is harmless (not the lock path)
          continue
        } catch {
          # not the steal winner -- fall through to poll
        }
      }
      if ($ticks -ge $maxTicks) {
        [Console]::Error.WriteLine("claude-glm: timed out after ${SeedLockTimeout}s waiting for the config-dir seed lock ($Lock). If no other claude-glm launch of this lane is seeding, remove that dir, or tune CLAUDE_LANE_SEED_LOCK_TIMEOUT / CLAUDE_LANE_SEED_LOCK_STALE; last acquire error: $lastAcquireErr")
        exit 4
      }
      Start-Sleep -Milliseconds 500
      $ticks++
    }
  }
  # Release in finally so a seed failure (Copy-SeedConfig's exit 4) still frees the
  # lock -- PowerShell runs finally blocks even when a called function calls exit.
  # Accepted residual: an untrapped Ctrl+C / process kill while holding leaks the
  # lock until the stale steal (~$SeedLockStale s) -- deliberate; adding signal
  # handling would change the launcher's existing semantics.
  try {
    # Double-checked recheck UNDER the lock: the OUTER if was a cheap pre-check that
    # raced other launches; a concurrent winner may have just seeded while we waited,
    # so re-evaluate and skip a redundant reseed. -Reseed forces a reseed regardless
    # (explicit operator intent), but still under the lock.
    # Residual (accepted): a READER launch that judged the sentinel fresh a moment
    # before the winner removed it can still launch claude against a mid-seed dir --
    # the window shrinks from the full seed duration to one stat. Full reader-writer
    # exclusion would need an atomic dir swap Windows cannot give; out of scope.
    if ($Reseed -or (-not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) -or (Test-ConfigSeedStale)) {
      Copy-SeedConfig
    }
  } finally {
    # Empty-only release ([IO.Directory]::Delete = rmdir parity, never -Recurse:
    # recursing would silently vaporize evidence of an invariant violation). A
    # failure warns (worth surfacing) but stays NON-FATAL: the seed itself succeeded.
    try { [System.IO.Directory]::Delete($Lock) }
    catch { [Console]::Error.WriteLine("claude-glm: WARNING - failed to release seed lock $Lock (not empty or busy); it self-heals via stale steal after ${SeedLockStale}s but concurrent launches wait/time out until then.") }
  }
}

if ((-not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) -or $Reseed -or (Test-ConfigSeedStale)) {
  Invoke-SeedWithLock
}

# --- off-peak annotation -----------------------------------------------------
# Peak window 14:00-18:00 UTC+8 == 06:00-10:00 UTC (unverified for the
# Anthropic-compatible endpoint - advisory only, spec Launch step 4).
$hourUtc = [DateTime]::UtcNow.Hour
if ($hourUtc -ge 6 -and $hourUtc -le 9) {
  [Console]::Error.WriteLine('claude-glm: inside GLM peak window (14:00-18:00 UTC+8); off-peak resumes 10:00 UTC. Advisory only.')
} else {
  [Console]::Error.WriteLine('claude-glm: outside GLM peak window (14:00-18:00 UTC+8). Advisory only.')
}

# --- launch: env contract mirrors the bash `exec env … claude "$@"` -----------
$env:ANTHROPIC_BASE_URL           = $GlmBaseUrl
$env:ANTHROPIC_AUTH_TOKEN         = $key
$env:ANTHROPIC_MODEL              = $GlmModel
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $GlmHaiku
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $GlmModel
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $GlmModel
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $GlmContextWindow
$env:CLAUDE_CONFIG_DIR            = $ConfigDir

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine("claude-glm: 'claude' not found on PATH")
  exit 5
}

& claude @ClaudeArgs
exit $LASTEXITCODE
