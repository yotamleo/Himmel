#Requires -Version 7
<#
  claude-glm-seed-check.ps1 -- read-only drift check for the glm-launcher seeded set.
  HIMMEL-654 WS5 Task 1. PowerShell twin of scripts/claude-glm-seed-check.sh
  (bash). Behaviour-parallel: same env defaults as scripts/claude-glm.ps1
  ($env:USERPROFILE root, NOT $CLAUDE_DIR), same seeded set, same settings.json
  exclusion, same exit codes:
    0  in sync (seeded set matches; settings.json ignored)
    1  drift  (per-file list printed to stdout; reseed hint at the end)
    2  unseeded config dir (absent, or no .seeded sentinel -> first launch)
  Read-only: NEVER mutates either directory (no --fix; --reseed lives on the launcher).

  settings.json is INTENTIONALLY EXCLUDED: the launcher re-sanitizes it every
  seed (strips `model` + `env.ANTHROPIC_*`), so the sanitized copy never
  byte-matches the raw source -- comparing it would report permanent drift.

  Usage:
    pwsh scripts/claude-glm-seed-check.ps1 --check [--config-dir DIR] [--source DIR]
    (--check is the only mode and may be omitted)

  NB: deliberately a PLAIN script with NO declared params -- mirrors
  claude-glm.ps1 so a future same-prefix flag cannot bind by accident.
#>

$ErrorActionPreference = 'Stop'

# Same env defaults as claude-glm.ps1: $env:USERPROFILE (PowerShell's $HOME is
# fixed at startup; USERPROFILE lets hermetic tests override the home root).
$ConfigDir = Join-Path $env:USERPROFILE '.claude-glm'
$Source    = Join-Path $env:USERPROFILE '.claude'

function Print-Help {
  # Keep this a hand-written here-string (no `sed`): a clean Windows pwsh has no
  # sed on PATH, unlike the bash twin which reads its own header with sed.
  @'
claude-glm-seed-check.ps1 --check [--config-dir DIR] [--source DIR]

Read-only drift check for the glm-launcher seeded set under ~/.claude-glm
against ~/.claude. settings.json is excluded (re-sanitized per seed).
Exit 0 = in sync; 1 = drift (per-file list); 2 = unseeded config dir.
'@ | Write-Output
}

# --- arg parse (plain $args, no declared params) -----------------------------
for ($i = 0; $i -lt $args.Count; $i++) {
  switch -CaseSensitive ($args[$i]) {
    '--check' { }                                          # only mode; no-op
    '--config-dir' { $i++; if ($i -ge $args.Count) { throw '--config-dir needs a DIR' }; $ConfigDir = $args[$i] }
    '--source'     { $i++; if ($i -ge $args.Count) { throw '--source needs a DIR' }; $Source = $args[$i] }
    '-h' { Print-Help; exit 0 }
    '--help' { Print-Help; exit 0 }
    default { [Console]::Error.WriteLine("claude-glm-seed-check: unknown arg '$($args[$i])'"); exit 2 }
  }
}

# The EXACT seeded set the launcher's Copy-SeedConfig mirrors. Keep in sync with
# scripts/claude-glm + scripts/claude-glm.ps1. settings.json is NOT here.
$SeedFiles = 'CLAUDE.md', 'RTK.md', 'plugins/installed_plugins.json', 'plugins/known_marketplaces.json', 'plugins/claude-hud/config.json'
$SeedDirs  = 'commands', 'skills', 'hooks', 'agents', 'plugins/marketplaces'

# Unseeded = the launcher would re-seed on next run: dir absent OR no .seeded
# sentinel (mirrors claude-glm.ps1's own seed trigger).
if (-not (Test-Path -LiteralPath $ConfigDir -PathType Container) -or
    -not (Test-Path -LiteralPath (Join-Path $ConfigDir '.seeded'))) {
  [Console]::Out.WriteLine("claude-glm-seed-check: unseeded config dir ($ConfigDir) -- no .seeded sentinel. Run 'claude-glm' to seed on first launch.")
  exit 2
}

# rel-path (forward slashes, relative to $Root) -> SHA256, for every file under
# $Root. Empty table if $Root is absent. Used to compare a seeded subtree.
function Get-RelHashes {
  param([string]$Root)
  $h = @{}
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $h }
  foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
    $h[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
  }
  return $h
}

$drift = [System.Collections.Generic.List[string]]::new()

# Compare one seeded FILE entry (path relative to $Source/$ConfigDir).
foreach ($entry in $SeedFiles) {
  $src = Join-Path $Source $entry
  $cfg = Join-Path $ConfigDir $entry
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }   # source lacks it -> launcher skips
  if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { $null = $drift.Add($entry); continue }
  if ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ne
      (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash) { $null = $drift.Add($entry) }
}

# Compare each seeded DIR entry recursively: missing/changed-in-config, then
# extras-in-config a clean re-mirror would drop. Names use the entry prefix +
# the file's rel path, matching the bash twin's `entry/$sub` form.
foreach ($entry in $SeedDirs) {
  $src = Join-Path $Source $entry
  $cfg = Join-Path $ConfigDir $entry
  if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }  # source lacks it -> launcher skips
  $srcH = Get-RelHashes $src
  if (-not (Test-Path -LiteralPath $cfg -PathType Container)) { $null = $drift.Add("$entry/"); continue }
  $cfgH = Get-RelHashes $cfg
  foreach ($k in $srcH.Keys) {
    if (-not $cfgH.ContainsKey($k) -or $cfgH[$k] -ne $srcH[$k]) { $null = $drift.Add("$entry/$k") }
  }
  foreach ($k in $cfgH.Keys) {
    if (-not $srcH.ContainsKey($k)) { $null = $drift.Add("$entry/$k") }
  }
}

if ($drift.Count -gt 0) {
  [Console]::Out.WriteLine("claude-glm-seed-check: drift -- $($drift.Count) seeded file(s) in $ConfigDir lag $Source (--check)")
  foreach ($d in $drift) { [Console]::Out.WriteLine("  · $d") }
  [Console]::Out.WriteLine('  reseed: claude-glm --reseed')
  exit 1
}

[Console]::Out.WriteLine("claude-glm-seed-check: in sync ($ConfigDir matches the seeded set of $Source; settings.json excluded)")
exit 0
