#Requires -Version 7
# claude-deepseek.ps1 — isolated DeepSeek inference lane (HIMMEL-4084).
# Security predicates are byte-identical to bash. The seed mirrors the sibling
# allowlist into this lane only; native ~/.claude remains read-only.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Native stdin must be BOM-free: JSON.parse rejects the UTF8 preamble.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
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
$CurlCommand = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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

Import-Module (Join-Path $PSScriptRoot 'lane-mirror-seed.psm1') -Force
$LaneSeed = @{
  HomeDir = $HomeDir; ConfigDir = $ConfigDir; Lane = 'claude-deepseek'
  SanitizerJs = $SanitizerJs; Stamp = ''; StampRequired = $false; LeafOnly = $false
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

$LaneSeed.LockTimeout = $SeedLockTimeout
$LaneSeed.LockStale = $SeedLockStale
Invoke-LaneSeedWithLock $LaneSeed $Reseed {
  & node -e $SeedJs (Join-Path $ConfigDir '.claude.json') $Primary
  if ($LASTEXITCODE -ne 0) { exit 4 }
}
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
            # PowerShell coerces $null to an empty string for this overload.
            [Environment]::SetEnvironmentVariable($Name, [NullString]::Value, 'Process')
        }
    }
}
