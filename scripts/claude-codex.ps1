#Requires -Version 7
<#
  claude-codex.ps1 - thin launcher: Claude Code on the codex-subscription lane
  via a local CLIProxyAPI proxy. HIMMEL-979. PowerShell twin of
  scripts/claude-codex (bash). Behaviour-parallel: same env contract; same exit
  codes on the enumerated paths (2 = missing key / proxy unreachable, 3 = egress
  refusal / unreadable guard config, 4 = failed seed, 5 = claude not on PATH). A
  guard config (phi-roots / egress-denylist) that exists but is not a readable
  regular file fails CLOSED with the bash-parity message ("guard config <path>
  exists but is not a readable file — failing closed.") and exit 3. Any OTHER
  failure fails CLOSED via a PowerShell terminating error (exit 1) rather than
  matching the bash exit code. Twin of scripts/claude-glm, HIMMEL-665.

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

$CodexProxyBaseUrl = if ($env:CODEX_PROXY_BASE_URL) { $env:CODEX_PROXY_BASE_URL } else { 'http://127.0.0.1:8317' }
# Model names are whatever the local CLIProxyAPI /v1/models exposes for the
# authed codex subscription (gpt-5.6-sol at ship time). All overridable per task.
$CodexModel         = if ($env:CODEX_MODEL) { $env:CODEX_MODEL } else { 'gpt-5.6-sol' }
$CodexHaiku         = if ($env:CODEX_HAIKU) { $env:CODEX_HAIKU } else { $CodexModel }
$CodexSubagentModel = if ($env:CODEX_SUBAGENT_MODEL) { $env:CODEX_SUBAGENT_MODEL } else { $CodexModel }
# CODEX_CONTEXT_WINDOW feeds CLAUDE_CODE_AUTO_COMPACT_WINDOW (env block below) so
# Claude Code budgets against a real number instead of its ~200k default for the
# unrecognized gpt-5.6-sol slug — twin of the bash launcher. gpt-5.6's actual
# window is ~372k (95% effective ~353k, openai/codex#32486). The 272000 default is
# the COST-OPTIMAL compaction point, NOT a hard ceiling: input past 272k bills 2x
# input / 1.5x output for the whole request. Raise to CODEX_CONTEXT_WINDOW=353000
# to use the full effective window at 2x cost past 272k.
$CodexContextWindow = if ($env:CODEX_CONTEXT_WINDOW) { $env:CODEX_CONTEXT_WINDOW } else { '272000' }
# CodeRabbit (HIMMEL-1027): validate the override — a non-positive-integer value
# falls back to the default; above the ~372k backend window WARNS, above the 272k
# 2x-billing cliff NOTES the cost (both honored — warn-not-clamp, twin-parity).
[long]$CodexCtxParsed = 0
if (-not [long]::TryParse($CodexContextWindow, [ref]$CodexCtxParsed) -or $CodexCtxParsed -le 0) {
  [Console]::Error.WriteLine("claude-codex: WARNING - CODEX_CONTEXT_WINDOW='$CodexContextWindow' is not a positive integer; using 272000.")
  $CodexContextWindow = '272000'
} else {
  # Independent checks (CodeRabbit HIMMEL-1027): a value >372000 also exceeds the
  # 272k cliff, so emit BOTH the backend-window warning AND the billing note.
  if ($CodexCtxParsed -gt 372000) {
    [Console]::Error.WriteLine("claude-codex: WARNING - CODEX_CONTEXT_WINDOW=$CodexCtxParsed exceeds the ~372k gpt-5.6 backend window (95% effective ~353k); the backend may reject prompts past it. Proceeding as set.")
  }
  if ($CodexCtxParsed -gt 272000) {
    [Console]::Error.WriteLine("claude-codex: NOTE - CODEX_CONTEXT_WINDOW=$CodexCtxParsed is above the 272k 2x-billing cliff; input past 272k bills 2x (backend window ~372k). Proceeding as set.")
  }
}
# HOME equivalent: bash uses $HOME; here $env:USERPROFILE so hermetic tests can
# override the home root per-invocation (PowerShell's $HOME is fixed at startup).
$HomeDir   = $env:USERPROFILE
$ConfigDir = Join-Path $HomeDir '.claude-codex'

# --- key resolution: process env first, else the launcher-repo .env ----------
# CLAUDE_CODEX_DOTENV_ROOT (test hook) pins the .env root; production falls back to
# the launcher's parent dir (the himmel checkout), NOT the CWD repo - the
# motivating workload runs with cwd in the luna vault, whose .env has no CLIPROXY key.
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

$key = $env:CLIPROXY_API_KEY
if ([string]::IsNullOrEmpty($key)) {
  $root = if ($env:CLAUDE_CODEX_DOTENV_ROOT) { $env:CLAUDE_CODEX_DOTENV_ROOT } else { Split-Path -Parent $PSScriptRoot }
  $key = Get-DotenvKey -Root $root -Name 'CLIPROXY_API_KEY'
}

if ([string]::IsNullOrEmpty($key)) {
  [Console]::Error.WriteLine('claude-codex: CLIPROXY_API_KEY is not set. Export it or add it to the repo .env (never settings.json). It must match an api-keys entry in ~/.cli-proxy-api/config.yaml.')
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
$Cfg = Join-Path $HomeDir (Join-Path '.config' 'claude-codex')

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
    # MSYS drive-form translation (CR HIMMEL-979 R5): a root written from Git
    # Bash as /c/Users/... must match the Windows provider path C:\Users\...
    $r = $r -replace '^[\\/]([A-Za-z])(?=[\\/])', '$1:'
    $r = ($r -replace '/', '\').TrimEnd('\')
    if ($r -eq '') { continue }
    # Bidirectional overlap (CR HIMMEL-979 R5): target INSIDE a protected root
    # OR a protected root INSIDE the target (ancestor workspace grants the
    # protected subtree). Residual as in the bash twin: descendant .salus
    # markers without a phi-roots line need an unbounded scan — not done.
    if (($t + '\').StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if (($r + '\').StartsWith($t + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
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
  [Console]::Error.WriteLine("claude-codex: guard config $ListFile exists but is not a readable file — failing closed.")
  exit 3
}

# Guard-config UNION (CR HIMMEL-979 R2): this lane also honors the claude-glm
# guard dir — an operator who provisioned phi-roots/egress-denylist for the GLM
# lane must not launch a NEW cloud lane unguarded. Union is strictly more
# restrictive; per-lane files stay authoritative for lane-specific additions.
$CfgGlm = Join-Path $HomeDir (Join-Path '.config' 'claude-glm')

function Test-GuardHitAny {
  # Union over both lane guard dirs for one list basename. Fail-closed readable
  # check per dir (Assert-GuardReadable exits 3 itself on an unreadable config).
  param([string]$Target, [string]$BaseName)
  foreach ($dir in @($Cfg, $CfgGlm)) {
    $list = Join-Path $dir $BaseName
    Assert-GuardReadable $list
    if (Test-PathUnderAny -Target $Target -ListFile $list) { return $true }
  }
  return $false
}

# Invoke-GuardWorkspace (CR HIMMEL-979 R2/R3): the FULL screening for one
# directory — .salus ancestor walk + phi-roots union + egress-denylist union.
# Applied to the launch cwd AND every --add-dir value (R3: --add-dir <vault>
# must not bypass the no-override PHI invariant). Symlinked leaf resolved
# best-effort via ResolvedTarget (R3; documented residual: intermediate
# symlink components and symlinked ROOT entries compare as written).
function Invoke-GuardWorkspace {
  param([string]$Dir, [string]$Label)
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
    [Console]::Error.WriteLine("claude-codex: REFUSED - $Label ($Dir) is not an accessible directory.")
    exit 3
  }
  # Canonicalize to an ABSOLUTE provider path (CR HIMMEL-979 R5): a relative
  # --add-dir value would never prefix-match the absolute guard roots — the
  # bash twin gets this via `cd && pwd -P`.
  $gw = (Resolve-Path -LiteralPath $Dir).ProviderPath
  try {
    # ResolvedTarget exists on PS 7.3+ only; on 7.0-7.2 it is $null and the
    # unresolved absolute path is used (documented residual, CR R7 — same
    # class as intermediate symlink components; list roots in physical form).
    $rt = (Get-Item -LiteralPath $gw -ErrorAction Stop).ResolvedTarget
    if ($rt) { $gw = $rt }
  } catch { }
  $salusHit = $false
  $d = $gw
  while ($true) {
    if (Test-Path -LiteralPath (Join-Path $d '.salus')) { $salusHit = $true; break }
    $parent = Split-Path -Parent $d
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent
  }
  if ($salusHit -or (Test-GuardHitAny -Target $gw -BaseName 'phi-roots')) {
    [Console]::Error.WriteLine("claude-codex: REFUSED - $Label is PHI-marked (.salus / phi-roots). No override exists; PHI never goes to a cloud codex backend.")
    exit 3
  }
  if (Test-GuardHitAny -Target $gw -BaseName 'egress-denylist') {
    if ($Force) {
      [Console]::Error.WriteLine("claude-codex: WARNING - $Label is denylisted, proceeding under --force. Content WILL be sent to OpenAI via the local proxy.")
    } else {
      [Console]::Error.WriteLine("claude-codex: REFUSED - $Label is on the egress denylist (claude-codex/claude-glm guard union). Re-run with --force to override.")
      exit 3
    }
  }
}

$cwd = (Get-Location).ProviderPath
Invoke-GuardWorkspace -Dir $cwd -Label 'this workspace'

# Harness-integrity arg screen (CR HIMMEL-979 R3/R4): args pass to claude
# verbatim, so flags that disable hooks or inject settings would break the
# lane's core premise (the FULL guarded harness always runs). --bare /
# --safe-mode / --setting-sources are REFUSED; --settings payloads are
# screened; --add-dir is VARIADIC — every value until the next option gets the
# same screening as the launch cwd.
function Test-SettingsArgOrRefuse {
  param([string]$Value)
  $bad = $false
  try {
    $raw = if ($Value.Trim().StartsWith('{')) { $Value } else { Get-Content -LiteralPath $Value -Raw -ErrorAction Stop }
    $j = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($j -and $j.env) {
      foreach ($p in $j.env.PSObject.Properties) {
        $u = $p.Name.ToUpperInvariant()
        if ($u.StartsWith('ANTHROPIC_') -or $u.StartsWith('CLAUDE_CODE_USE_')) { $bad = $true; break }
      }
    }
  } catch { $bad = $true }
  if ($bad) {
    [Console]::Error.WriteLine('claude-codex: REFUSED - --settings payload sets env.ANTHROPIC_* / CLAUDE_CODE_USE_* (or is unparseable); it would defeat the proxy trust boundary.')
    exit 3
  }
}

$pending = ''
foreach ($a in $ClaudeArgs) {
  if ($pending -eq 'add-dir') {
    if ($a -like '-*') { $pending = '' }
    else { Invoke-GuardWorkspace -Dir $a -Label "--add-dir $a"; continue }
  } elseif ($pending -eq 'settings') {
    Test-SettingsArgOrRefuse -Value $a
    $pending = ''
    continue
  }
  if ($a -in @('--bare', '--safe-mode', '--setting-sources') -or $a -like '--setting-sources=*') {
    [Console]::Error.WriteLine("claude-codex: REFUSED - $a alters the hook/settings machinery; this lane requires the full guarded harness. Use plain claude if you need it.")
    exit 3
  }
  if ($a -eq '--add-dir') { $pending = 'add-dir'; continue }
  if ($a -like '--add-dir=*') {
    $v = $a.Substring('--add-dir='.Length)
    Invoke-GuardWorkspace -Dir $v -Label "--add-dir $v"
    continue
  }
  if ($a -eq '--settings') { $pending = 'settings'; continue }
  if ($a -like '--settings=*') { Test-SettingsArgOrRefuse -Value $a.Substring('--settings='.Length) }
}

# Project-settings backend-override refusal (CR HIMMEL-979 R2/R3): Claude Code
# merges $cwd/.claude/settings{,.local}.json env on top of the launcher's env,
# so a project-level ANTHROPIC_* key or an alternate-provider selector
# (CLAUDE_CODE_USE_BEDROCK/VERTEX/...) would silently reroute the session away
# from the validated proxy. Fail closed on any such key — and on an
# unparseable settings file.
$settingsFiles = [System.Collections.Generic.List[string]]::new()
$sd = $cwd
while ($true) {
  # R5: Claude resolves the project root by walking up from cwd — a nested
  # launch must not miss an ancestor settings file. Screen every level.
  $settingsFiles.Add((Join-Path $sd (Join-Path '.claude' 'settings.json')))
  $settingsFiles.Add((Join-Path $sd (Join-Path '.claude' 'settings.local.json')))
  $sp = Split-Path -Parent $sd
  if (-not $sp -or $sp -eq $sd) { break }
  $sd = $sp
}
foreach ($sf in $settingsFiles) {
  if (-not (Test-Path -LiteralPath $sf -PathType Leaf)) { continue }
  $sfBad = $false
  try {
    $j = Get-Content -LiteralPath $sf -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($j -and $j.env) {
      foreach ($p in $j.env.PSObject.Properties) {
        $u = $p.Name.ToUpperInvariant()
        if ($u.StartsWith('ANTHROPIC_') -or $u.StartsWith('CLAUDE_CODE_USE_')) { $sfBad = $true; break }
      }
    }
  } catch { $sfBad = $true }
  if ($sfBad) {
    [Console]::Error.WriteLine("claude-codex: REFUSED - $sf sets env.ANTHROPIC_* / CLAUDE_CODE_USE_* (or is unparseable); a project-level backend override defeats the proxy trust boundary. Remove those env keys to launch this lane here.")
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
if (j.env) for (const k of Object.keys(j.env)) { const u=k.toUpperCase(); if (u.indexOf("ANTHROPIC_")===0 || u.indexOf("CLAUDE_CODE_USE_")===0) delete j.env[k]; }
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
    [Console]::Error.WriteLine("claude-codex: FAILED to clear stale .seeded sentinel ($($_.Exception.Message)). Refusing to reseed while a stale sentinel remains. Fix the cause and re-run (or rm -rf ~/.claude-codex).")
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
      [Console]::Error.WriteLine('claude-codex: FAILED to sanitize settings.json (node missing/broken?). Refusing to launch with an unseeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-codex).')
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
    # sentinel LAST: only a fully-populated seed reads as "seeded"
    New-Item -ItemType File -Force -Path (Join-Path $ConfigDir '.seeded') | Out-Null
  } catch {
    [Console]::Error.WriteLine("claude-codex: FAILED to seed config dir ($($_.Exception.Message)). Refusing to launch with a half-seeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-codex).")
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
        [Console]::Error.WriteLine("claude-codex: timed out after ${SeedLockTimeout}s waiting for the config-dir seed lock ($Lock). If no other claude-codex launch of this lane is seeding, remove that dir, or tune CLAUDE_LANE_SEED_LOCK_TIMEOUT / CLAUDE_LANE_SEED_LOCK_STALE; last acquire error: $lastAcquireErr")
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
    catch { [Console]::Error.WriteLine("claude-codex: WARNING - failed to release seed lock $Lock (not empty or busy); it self-heals via stale steal after ${SeedLockStale}s but concurrent launches wait/time out until then.") }
  }
}

if ((-not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) -or $Reseed -or (Test-ConfigSeedStale)) {
  Invoke-SeedWithLock
}

# --- trust boundary (CR HIMMEL-979) -------------------------------------------
# The proxy receives the auth key AND all session content, so the default
# posture is loopback-only. A non-loopback CODEX_PROXY_BASE_URL needs the
# explicit CLAUDE_CODEX_REMOTE_PROXY_OK=1 opt-in (prefer HTTPS for remote).
$proxyHostPort = $CodexProxyBaseUrl -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', '' -replace '/.*$', ''
# Userinfo refusal (CR HIMMEL-979 R3, parity with the bash twin): an authority
# like 127.0.0.1:8317@evil.com carries the real host after the '@' — refuse
# outright; a local proxy never needs URL userinfo.
if ($proxyHostPort -like '*@*') {
  [Console]::Error.WriteLine("claude-codex: REFUSED - CODEX_PROXY_BASE_URL ($CodexProxyBaseUrl) contains userinfo ('@'); this can smuggle a non-loopback host past the trust boundary and is not supported.")
  exit 3
}
$isLoopback = $proxyHostPort -match '^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$'
if (-not $isLoopback) {
  if ($env:CLAUDE_CODEX_REMOTE_PROXY_OK -ne '1') {
    [Console]::Error.WriteLine("claude-codex: REFUSED - CODEX_PROXY_BASE_URL ($CodexProxyBaseUrl) is not loopback. The proxy receives the key and session content; set CLAUDE_CODEX_REMOTE_PROXY_OK=1 to override (prefer HTTPS).")
    exit 3
  }
  [Console]::Error.WriteLine("claude-codex: WARNING - non-loopback proxy ($proxyHostPort) under CLAUDE_CODEX_REMOTE_PROXY_OK=1. Key + session content WILL leave this machine.")
}

# --- proxy preflight ---------------------------------------------------------
# The lane is dead without a running cli-proxy-api; a refused/timed-out proxy is fatal.
try {
  # -NoProxy (CR HIMMEL-979 R6): the preflight must not route the bearer token
  # through an ambient/system transport proxy — it runs BEFORE the launch-time
  # proxy sweep.
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -NoProxy -Headers @{Authorization="Bearer $key"} -Uri "$CodexProxyBaseUrl/v1/models" | Out-Null
} catch {
  [Console]::Error.WriteLine("claude-codex: proxy not reachable at $CodexProxyBaseUrl — start cli-proxy-api (and complete --codex-login) first. See docs/tooling-catalog.md#claude-codex.")
  exit 2
}

# --- launch: env contract mirrors the bash `exec env … claude "$@"` -----------
# The CLAUDE_CODE_*/ENABLE_TOOL_SEARCH values follow the field-tested claudex
# recipe: subagents stay on the codex lane, effort controls stay on, and
# tool-search stays off for non-Claude models. They are intentionally not
# env-overridable in v1.
# Ambient provider-selector sweep (CR HIMMEL-979 R3/R4): clear EVERY
# CLAUDE_CODE_USE_* from the environment — unknown future selectors included —
# then keep the two known ones pinned empty as a belt.
foreach ($ev in (Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_CODE_USE_*' })) {
  Set-Item -Path ("Env:" + $ev.Name) -Value ''
}
$env:CLAUDE_CODE_USE_BEDROCK        = ''
$env:CLAUDE_CODE_USE_VERTEX        = ''
# Transport-proxy sweep (CR HIMMEL-979 R5): HTTP(S)_PROXY/ALL_PROXY route even
# loopback connections through an external proxy host — clear them and pin
# NO_PROXY so the lane's claude talks ONLY to the local proxy.
foreach ($pn in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy')) {
  if (Test-Path ("Env:" + $pn)) { Remove-Item ("Env:" + $pn) -ErrorAction SilentlyContinue }
}
$env:NO_PROXY = '127.0.0.1,localhost,::1'
$env:no_proxy = '127.0.0.1,localhost,::1'
# Ambient ANTHROPIC_* sweep (CR HIMMEL-979 R8): a pre-set provider/base/key
# variable not explicitly re-set below (e.g. ANTHROPIC_API_KEY) can steer
# auth/transport around the validated proxy — clear them all first.
foreach ($ev in (Get-ChildItem Env: | Where-Object { $_.Name -like 'ANTHROPIC_*' })) {
  Remove-Item ("Env:" + $ev.Name) -ErrorAction SilentlyContinue
}
$env:ANTHROPIC_BASE_URL             = $CodexProxyBaseUrl
$env:ANTHROPIC_AUTH_TOKEN           = $key
$env:ANTHROPIC_MODEL                = $CodexModel
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $CodexHaiku
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $CodexModel
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $CodexModel
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $CodexContextWindow
$env:CLAUDE_CODE_SUBAGENT_MODEL     = $CodexSubagentModel
$env:CLAUDE_CODE_ALWAYS_ENABLE_EFFORT = '1'
$env:CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = '3'
$env:ENABLE_TOOL_SEARCH             = 'false'
# HIMMEL-1001 effort default (twin of the bash launcher's ${VAR:-high}): pin the
# per-dispatch effort to 'high' when unset — theo's Codex ladder (medium/high
# default, xhigh rare, NEVER ultra). HIMMEL-1002 verified the effort reaches
# gpt-5.6-sol verbatim and the unset default is xhigh. OVERRIDABLE: an explicit
# $env:CLAUDE_CODE_EFFORT_LEVEL wins (-not is true for $null AND '', matching :-).
# Avoid 'max' — reachable but undocumented codex juice.
if (-not $env:CLAUDE_CODE_EFFORT_LEVEL) { $env:CLAUDE_CODE_EFFORT_LEVEL = 'high' }
$env:CLAUDE_CONFIG_DIR              = $ConfigDir
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine("claude-codex: 'claude' not found on PATH")
  exit 5
}

& claude @ClaudeArgs
exit $LASTEXITCODE
