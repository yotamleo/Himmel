#Requires -Version 7
# claude-deepseek.ps1 — isolated DeepSeek inference lane (HIMMEL-4084).
# Security predicates are byte-identical to bash. The seed mirrors the sibling
# allowlist into this lane only; native ~/.claude remains read-only.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# Script invocation shares the caller process environment. Save every variable
# this lane changes before key loading, and restore even on refusal or failure.
$LaneEnvNames = @('HOME','DEEPSEEK_API_KEY','ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL_NAME','ANTHROPIC_DEFAULT_SONNET_MODEL_NAME','ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME','CLAUDE_CODE_SUBAGENT_MODEL','CLAUDE_CODE_AUTO_COMPACT_WINDOW','CLAUDE_CODE_MAX_CONTEXT_TOKENS','CLAUDE_CODE_EFFORT_LEVEL','CLAUDE_CODE_AUTO_MODE_SERVER','CLAUDE_CONFIG_DIR')
$SavedLaneEnv = [Environment]::GetEnvironmentVariables('Process')
try {
$Here = $PSScriptRoot
$RepoRoot = Split-Path $Here -Parent
$ConfigDir = Join-Path $HOME '.claude-deepseek'
$env:HOME = $HOME
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('claude-deepseek: node required; failing closed.'); exit 3 }
$Common = (& git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $Common) { [Console]::Error.WriteLine('claude-deepseek: cannot resolve primary checkout.'); exit 4 }
$Primary = Split-Path $Common -Parent
if (-not $env:DEEPSEEK_API_KEY) {
    $DotenvRoot = if ($env:CLAUDE_DEEPSEEK_DOTENV_ROOT) { $env:CLAUDE_DEEPSEEK_DOTENV_ROOT } else { $Primary }
    $Dotenv = Join-Path $DotenvRoot '.env'
    if (Test-Path -LiteralPath $Dotenv -PathType Leaf) {
        # The flag is never loaded: .env supplies ONLY the key.
        foreach ($Line in Get-Content -LiteralPath $Dotenv) {
            if ($Line -match '^\s*DEEPSEEK_API_KEY\s*=(.*)$') {
                $Key = $Matches[1].Trim()
                if ($Key.Length -ge 2 -and (($Key.StartsWith('"') -and $Key.EndsWith('"')) -or ($Key.StartsWith("'") -and $Key.EndsWith("'")))) { $Key = $Key.Substring(1,$Key.Length-2) }
                $env:DEEPSEEK_API_KEY = $Key
                break
            }
        }
    }
}
if (-not $env:DEEPSEEK_API_KEY) { [Console]::Error.WriteLine('claude-deepseek: DEEPSEEK_API_KEY missing.'); exit 2 }
$PassArgs = @($args)
$Reseed = $false
$HomeDir = $HOME
if ($PassArgs.Count -gt 0 -and $PassArgs[0] -eq '--reseed') { $Reseed = $true; $PassArgs = @($PassArgs | Select-Object -Skip 1) }
$EgressJs = @'
const fs=require("fs"), path=require("path");
const fail=s=>{console.error("claude-deepseek: REFUSED - "+s);process.exit(3);};
try {
 const M=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
 const cwd=fs.realpathSync(process.cwd());
 const under=root=>{if(!root)return false;const r=fs.realpathSync(root);return cwd===r||cwd.startsWith(r+path.sep);};
 // Ancestor markers also fence nested workspaces (including .salus-profile).
 for(let p=cwd;;p=path.dirname(p)) {
  if(fs.existsSync(path.join(p,".salus"))||fs.existsSync(path.join(p,".salus-profile"))) fail("PHI-marked workspace");
  const marker=path.join(p,".obsidian");
  if(fs.existsSync(marker)&&fs.statSync(marker).isDirectory())fail("vault corpus");
  if(path.dirname(p)===p)break;
 }
 for(const name of ["phi-roots","egress-denylist"]) {
  const p=path.join(process.env.HOME,".config/claude-glm",name);
  if(fs.existsSync(p)) {
   if(!fs.statSync(p).isFile())fail("invalid guard config");
   for(const r of fs.readFileSync(p,"utf8").split(/\r?\n/).filter(Boolean))if(under(r))fail("guarded workspace");
  }
 }
 if(under(process.env.LUNA_VAULT_PATH)||under(process.env.LUNA_VAULT))fail("vault corpus");
 const corpus=under(process.env.HANDOVER_DIR)?"handover-state":under(process.argv[2])?"himmel-code":"unknown";
 if(!["himmel-code","handover-state"].includes(corpus))fail("unknown corpus");
 if(!M.providers||!Object.prototype.hasOwnProperty.call(M.providers,"deepseek"))fail("provider undeclared");
 if(process.env.HIMMEL_DEEPSEEK_INFERENCE_OK!=="1")fail("station requires HIMMEL_DEEPSEEK_INFERENCE_OK=1 in process environment (not .env)");
 let match=null;
 for(const r of M.rules) {
  if(!(r.corpus===corpus||r.corpus==="*"))continue;
  if(!(r.provider==="deepseek"||r.provider==="*"))continue;
  if(!(r.purpose==="inference"||r.purpose==="*"))continue;
  // A wildcard allow never authorizes a new provider, but its deny still wins.
  if(r.provider==="*"&&["allow","allow+log"].includes(r.verdict))continue;
  match=r;break;
 }
 if(!match||match.provider!=="deepseek")fail("no explicit permitting inference cell");
 const conditional=match.verdict==="conditional"&&match.condition==="HIMMEL_DEEPSEEK_INFERENCE_OK=1";
 // allow+log is refused: this launcher does not implement the ledger obligation.
 if(match.verdict!=="allow"&&!conditional)fail("first matching inference cell denies or has unknown condition");
} catch(_) {fail("cannot verify egress policy or workspace");}
'@
$Matrix = if ($env:CLAUDE_DEEPSEEK_EGRESS_MATRIX) { $env:CLAUDE_DEEPSEEK_EGRESS_MATRIX } else { Join-Path $Here 'guardrails/egress-matrix.json' }
& node -e $EgressJs $Matrix $RepoRoot
if ($LASTEXITCODE -ne 0) { exit 3 }
# Resolve the native application by ordinary PATH order, like bash. Naming
# curl.exe first would skip a hermetic curl.cmd fixture on Windows.
$CurlCommand = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue
if (-not $CurlCommand) { [Console]::Error.WriteLine('claude-deepseek: balance UNKNOWN (curl missing).'); exit 5 }
if ($env:DEEPSEEK_API_KEY -match '[\r\n"\\]') { [Console]::Error.WriteLine('claude-deepseek: invalid API key format.'); exit 2 }
$Raw = ('header = "Authorization: Bearer ' + $env:DEEPSEEK_API_KEY + '"') | & $CurlCommand.Source -fsS --max-time 10 --noproxy '*' -K - https://api.deepseek.com/user/balance 2>$null
if ($LASTEXITCODE -ne 0) { $Raw = '' }
$BalanceJs = @'
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
 try {
  const j=JSON.parse(s), rows=j.balance_infos;
  if(j.is_available!==true||!Array.isArray(rows))throw Error();
  const usd=rows.filter(r=>r.currency==="USD");
  if(usd.length!==1||typeof usd[0].total_balance!=="string"||!/^\d+(\.\d+)?$/.test(usd[0].total_balance))throw Error();
  const n=Number(usd[0].total_balance);
  if(!Number.isFinite(n))throw Error();
  const raw=process.env.DEEPSEEK_MIN_BALANCE_USD||"3";
  const floor=/^\d+(\.\d+)?$/.test(raw)&&Number.isFinite(Number(raw))?Number(raw):3;
  if(n<floor)throw Error();
  process.stdout.write(n.toFixed(2));
 }catch(_){process.exit(5);}
});
'@
$Balance = ($Raw | & node -e $BalanceJs | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $Balance) { [Console]::Error.WriteLine('claude-deepseek: balance below floor, unavailable or UNKNOWN; refusing.'); exit 5 }
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
    [Console]::Error.WriteLine("claude-deepseek: FAILED to clear stale .seeded sentinel ($($_.Exception.Message)). Refusing to reseed while a stale sentinel remains. Fix the cause and re-run (or rm -rf ~/.claude-deepseek).")
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
    [Console]::Error.WriteLine("claude-deepseek: FAILED to create the config dir $ConfigDir ($($_.Exception.Message)). Refusing to launch with an unseeded config dir. Fix the cause and re-run.")
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
      [Console]::Error.WriteLine('claude-deepseek: FAILED to sanitize settings.json (node missing/broken?). Refusing to launch with an unseeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-deepseek).')
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
    # HIMMEL-3334: the un-swept claude-hud config path, alongside the legacy one above.
    $hudNewSrc = Join-Path $src 'claude-hud.json'
    $hudNewDst = Join-Path $ConfigDir 'claude-hud.json'
    if (Test-Path -LiteralPath $hudNewSrc) {
      Copy-Item -LiteralPath $hudNewSrc -Destination $hudNewDst -Force
    } elseif (Test-Path -LiteralPath $hudNewDst) {
      Remove-Item -LiteralPath $hudNewDst -Force
    }
    New-Item -ItemType File -Force -Path (Join-Path $ConfigDir '.seeded') | Out-Null
  } catch {
    [Console]::Error.WriteLine("claude-deepseek: FAILED to seed config dir ($($_.Exception.Message)). Refusing to launch with a half-seeded config dir. Fix the cause and re-run (or rm -rf ~/.claude-deepseek).")
    exit 4
  }
}

function Test-ConfigSeedStale {
  if ($env:CLAUDE_LANE_AUTO_RESEED -eq '0') { return $false }
  try {
    $sentinel = Join-Path $ConfigDir '.seeded'
    if (-not (Test-Path -LiteralPath $sentinel)) { return $false }
    $sentinelTime = (Get-Item -Force -LiteralPath $sentinel).LastWriteTimeUtc
    $src = Join-Path $HomeDir '.claude'
    foreach ($rel in @('settings.json', 'CLAUDE.md', 'RTK.md', (Join-Path 'plugins' 'installed_plugins.json'), (Join-Path 'plugins' 'known_marketplaces.json'), (Join-Path 'plugins' (Join-Path 'claude-hud' 'config.json')), 'claude-hud.json')) {
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

$SeedJs = @'
const fs=require("fs"), p=process.argv[1], root=process.argv[2];
try {
 const j=fs.existsSync(p)?JSON.parse(fs.readFileSync(p,"utf8")):{};
 const object=v=>v&&typeof v==="object"&&!Array.isArray(v);
 if(!object(j)||(j.projects!==undefined&&!object(j.projects)))throw Error("invalid config object");
 j.projects=j.projects||{};
 const project=j.projects[root]||{};
 if(!object(project))throw Error("invalid project object");
 if(j.hasCompletedOnboarding===true&&project.hasTrustDialogAccepted===true)process.exit(0);
 j.hasCompletedOnboarding=true;project.hasTrustDialogAccepted=true;j.projects[root]=project;
 const temp=p+".tmp."+process.pid;
 fs.writeFileSync(temp,JSON.stringify(j,null,2)+"\n",{mode:0o600});fs.renameSync(temp,p);
}catch(e){console.error("claude-deepseek: onboarding seed failed: "+e.message);process.exit(4);}
'@
# --- config-dir seed concurrency lock (HIMMEL-830) ---------------------------
$Lock            = "$ConfigDir.seed-lock"
function Read-SeedLockSeconds([string]$Name, [int]$Default) {
  $Raw = [Environment]::GetEnvironmentVariable($Name, 'Process')
  if ($null -eq $Raw) { return $Default }
  $Seconds = 0
  if ($Raw -notmatch '^[0-9]+$' -or -not [int]::TryParse($Raw, [ref]$Seconds)) {
    [Console]::Error.WriteLine("claude-deepseek: invalid seed setting $Name; expected a nonnegative integer.")
    exit 4
  }
  return $Seconds
}
$SeedLockTimeout = Read-SeedLockSeconds 'CLAUDE_LANE_SEED_LOCK_TIMEOUT' 60
$SeedLockStale   = Read-SeedLockSeconds 'CLAUDE_LANE_SEED_LOCK_STALE' 120

function Test-SeedLockStale {
  if (-not (Test-Path -LiteralPath $Lock -PathType Container)) { return $false }
  try {
    $age = ([DateTime]::UtcNow - (Get-Item -Force -LiteralPath $Lock).LastWriteTimeUtc).TotalSeconds
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
        [Console]::Error.WriteLine("claude-deepseek: timed out after ${SeedLockTimeout}s waiting for the config-dir seed lock ($Lock). If no other claude-deepseek launch of this lane is seeding, remove that dir, or tune CLAUDE_LANE_SEED_LOCK_TIMEOUT / CLAUDE_LANE_SEED_LOCK_STALE; last acquire error: $lastAcquireErr")
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
    & node -e $SeedJs (Join-Path $ConfigDir '.claude.json') $Primary
    if ($LASTEXITCODE -ne 0) { exit 4 }
  } finally {
    try { [System.IO.Directory]::Delete($Lock) }
    catch { [Console]::Error.WriteLine("claude-deepseek: WARNING - failed to release seed lock $Lock (not empty or busy); it self-heals via stale steal after ${SeedLockStale}s but concurrent launches wait/time out until then.") }
  }
}

Invoke-SeedWithLock
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('claude-deepseek: claude missing.'); exit 2 }
$env:ANTHROPIC_BASE_URL = 'https://api.deepseek.com/anthropic'
$env:ANTHROPIC_AUTH_TOKEN = $env:DEEPSEEK_API_KEY
$env:ANTHROPIC_API_KEY = ''
$env:ANTHROPIC_MODEL = 'sonnet'
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'deepseek-flash[1m]'
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'deepseek-flash[1m]'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'deepseek-flash'
$env:ANTHROPIC_DEFAULT_OPUS_MODEL_NAME = 'DeepSeek Flash 1M'
$env:ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = 'DeepSeek Flash 1M'
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = 'DeepSeek Flash'
$env:CLAUDE_CODE_SUBAGENT_MODEL = 'deepseek-flash'
$ContextWindow = '786432'
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $ContextWindow
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $ContextWindow
$env:CLAUDE_CODE_EFFORT_LEVEL = 'max'
# ponytail: gateway lacks safeguard results, remove after HIMMEL-4086 verifies support.
$env:CLAUDE_CODE_AUTO_MODE_SERVER = '0'
$env:CLAUDE_CONFIG_DIR = $ConfigDir
[Console]::Error.WriteLine("claude-deepseek: lane=deepseek model=$env:ANTHROPIC_MODEL labels=$env:ANTHROPIC_DEFAULT_OPUS_MODEL_NAME/$env:ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME balance=$Balance USD (start snapshot; session cost is balance delta)")
& claude @PassArgs
exit $LASTEXITCODE
} finally {
    foreach ($Name in $LaneEnvNames) {
        if ($SavedLaneEnv.Contains($Name)) {
            [Environment]::SetEnvironmentVariable($Name, [string]$SavedLaneEnv[$Name], 'Process')
        } else {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
        }
    }
}
