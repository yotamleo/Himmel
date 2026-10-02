#!/usr/bin/env bash
# Hermetic launcher contract (HIMMEL-4084). Mock only the network and Claude.
# Breaks caught: opt-in bypass, wrong routing, torn seed, unknown credit launch,
# and credentials passed in argv/output. Node drives independent clean fixtures.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/lib/clean-sandbox.sh" -- node - "$HERE" <<'NODE'
const fs=require('fs'), path=require('path'), cp=require('child_process'), assert=require('assert');
const scripts=process.argv[2], launcher=path.join(scripts,'claude-deepseek');
const primary=path.dirname(cp.execFileSync('/usr/bin/git',['-C',path.dirname(scripts),'rev-parse','--path-format=absolute','--git-common-dir'],{encoding:'utf8'}).trim());
let count=0, fails=0;
const roots=[];
function test(name, fn) { try { fn(); console.log('ok: '+name); count++; } catch(e) { fails++; console.error('FAIL: '+name+' — '+e.message); } }
function setup() {
 const root=fs.mkdtempSync(path.join(process.env.TMPDIR,'deepseek-')); roots.push(root);
 const home=path.join(root,'home'), bin=path.join(root,'bin'), work=path.join(root,'work');
 for(const d of [home,bin,work,path.join(home,'.claude')]) fs.mkdirSync(d,{recursive:true});
 fs.writeFileSync(path.join(home,'.claude','settings.json'),JSON.stringify({model:'native',env:{ANTHROPIC_AUTH_TOKEN:'other-secret',KEEP:'yes'}}));
 fs.writeFileSync(path.join(bin,'curl'),`#!/usr/bin/env node
const fs=require('fs');fs.appendFileSync(process.env.CAPTURE_CURL,JSON.stringify(process.argv.slice(2))+'\\n');
const config=fs.readFileSync(0,'utf8');
if(!config.includes('Authorization: Bearer '+process.env.DEEPSEEK_API_KEY)) process.exit(8);
process.stdout.write(process.env.BALANCE_RESPONSE);
`,{mode:0o755});
 fs.writeFileSync(path.join(bin,'claude'),`#!/usr/bin/env node
require('fs').writeFileSync(process.env.CAPTURE_CHILD,JSON.stringify({env:process.env,argv:process.argv.slice(2)}));process.exit(Number(process.env.CHILD_EXIT||0));
`,{mode:0o755});
 const env={...process.env,HOME:home,PATH:bin+':'+process.env.PATH,DEEPSEEK_API_KEY:'ds-hermetic-secret',HIMMEL_DEEPSEEK_INFERENCE_OK:'1',CLAUDE_DEEPSEEK_DOTENV_ROOT:work,CLAUDE_DEEPSEEK_CWD:path.dirname(scripts),CAPTURE_CURL:path.join(root,'curl.jsonl'),CAPTURE_CHILD:path.join(root,'child.json'),BALANCE_RESPONSE:JSON.stringify({is_available:true,balance_infos:[{currency:'USD',total_balance:'50.00',granted_balance:'0',topped_up_balance:'50.00'}]})};
 return {root,home,bin,work,env};
}
function run(f, want=0, args=[]) {
 const r=cp.spawnSync('bash',[launcher,...args],{env:f.env,cwd:f.cwd||path.dirname(scripts),encoding:'utf8'});
 assert.strictEqual(r.status,want,'exit '+r.status+' want '+want+'; '+r.stderr);
 if(want!==0) assert(!fs.existsSync(f.env.CAPTURE_CHILD),'Claude launched after refusal');
 assert(!(r.stdout+r.stderr).includes('ds-hermetic-secret'),'secret leaked in output');
 if(fs.existsSync(f.env.CAPTURE_CURL)) assert(!fs.readFileSync(f.env.CAPTURE_CURL,'utf8').includes('ds-hermetic-secret'),'secret leaked in curl argv');
 return r;
}
function child(f) {return JSON.parse(fs.readFileSync(f.env.CAPTURE_CHILD,'utf8'));}
function matrix(f, rules) {
 const p=path.join(f.root,'matrix.json');
 fs.writeFileSync(p,JSON.stringify({providers:{deepseek:{region:'CN'}},rules,default:'deny'})); f.env.CLAUDE_DEEPSEEK_EGRESS_MATRIX=p;
}
const cell={corpus:'himmel-code',provider:'deepseek',purpose:'inference',verdict:'conditional',condition:'HIMMEL_DEEPSEEK_INFERENCE_OK=1'};
test('missing station opt-in refuses before network',()=>{const f=setup(); delete f.env.HIMMEL_DEEPSEEK_INFERENCE_OK;run(f,3);assert(!fs.existsSync(f.env.CAPTURE_CURL));});
for(const flag of ['0','true','yes','2',' 1']) test('invalid station flag '+JSON.stringify(flag)+' refuses',()=>{const f=setup();f.env.HIMMEL_DEEPSEEK_INFERENCE_OK=flag;run(f,3);});
test('dotenv-only opt-in refuses even when key loads',()=>{const f=setup();delete f.env.HIMMEL_DEEPSEEK_INFERENCE_OK;delete f.env.DEEPSEEK_API_KEY;fs.writeFileSync(path.join(f.work,'.env'),'DEEPSEEK_API_KEY="ds-hermetic-secret"\nHIMMEL_DEEPSEEK_INFERENCE_OK=1\n');run(f,3);assert(!fs.existsSync(f.env.CAPTURE_CURL));});
test('documented routing, labels, auto-mode, args and balance log',()=>{const f=setup();const r=run(f,0,['--model','sonnet','hello']);const c=child(f);for(const [k,v] of Object.entries({ANTHROPIC_BASE_URL:'https://api.deepseek.com/anthropic',ANTHROPIC_AUTH_TOKEN:'ds-hermetic-secret',ANTHROPIC_API_KEY:'',ANTHROPIC_MODEL:'deepseek-flash[1m]',ANTHROPIC_DEFAULT_OPUS_MODEL:'deepseek-flash[1m]',ANTHROPIC_DEFAULT_SONNET_MODEL:'deepseek-flash[1m]',ANTHROPIC_DEFAULT_HAIKU_MODEL:'deepseek-flash',CLAUDE_CODE_SUBAGENT_MODEL:'deepseek-flash',CLAUDE_CODE_AUTO_COMPACT_WINDOW:'786432',CLAUDE_CODE_AUTO_MODE_SERVER:'0',CLAUDE_CODE_EFFORT_LEVEL:'max'})) assert.strictEqual(c.env[k],v,k);for(const tier of ['OPUS','SONNET','HAIKU'])assert(c.env['ANTHROPIC_DEFAULT_'+tier+'_MODEL_NAME'].includes('DeepSeek'));assert.deepStrictEqual(c.argv,['--model','sonnet','hello']);assert(!JSON.stringify(c.argv).includes('ds-hermetic-secret'));assert(r.stderr.includes('lane=deepseek')&&r.stderr.includes('balance=50.00'));assert(fs.readFileSync(f.env.CAPTURE_CURL,'utf8').includes('https://api.deepseek.com/user/balance'));});
test('seed preserves unrelated JSON and is idempotent',()=>{const f=setup();const dir=path.join(f.home,'.claude-deepseek');fs.mkdirSync(dir);const config=path.join(dir,'.claude.json');fs.writeFileSync(config,JSON.stringify({unrelated:42,projects:{[primary]:{keep:'yes'}}}));run(f);const first=fs.readFileSync(config,'utf8'),j=JSON.parse(first);assert.strictEqual(j.unrelated,42);assert.strictEqual(j.hasCompletedOnboarding,true);assert.strictEqual(j.projects[primary].keep,'yes');assert.strictEqual(j.projects[primary].hasTrustDialogAccepted,true);const s=JSON.parse(fs.readFileSync(path.join(dir,'settings.json'),'utf8'));assert(!s.model);assert(!s.env.ANTHROPIC_AUTH_TOKEN);assert.strictEqual(s.env.KEEP,'yes');assert(!fs.existsSync(dir+'.seed-lock'));run(f);assert.strictEqual(fs.readFileSync(config,'utf8'),first);});
test('actual vault cwd cannot be authorized by a CWD override',()=>{const f=setup();f.cwd=f.work;f.env.LUNA_VAULT_PATH=f.work;run(f,3);});
test('actual PHI cwd cannot be authorized by a CWD override',()=>{const f=setup();f.cwd=f.work;fs.writeFileSync(path.join(f.work,'.salus'),'');run(f,3);});
test('handover inference permitted when outside vault',()=>{const f=setup();f.cwd=f.work;f.env.HANDOVER_DIR=f.work;run(f);});
for(const kind of ['vault','nested-vault-handover','salus','parent-salus','salus-profile','unknown'])test(kind+' refuses despite opt-in',()=>{const f=setup();f.cwd=f.work;if(kind.includes('vault'))f.env.LUNA_VAULT_PATH=f.work;if(kind==='nested-vault-handover')f.env.HANDOVER_DIR=f.work;if(kind.startsWith('salus'))fs.writeFileSync(path.join(f.work,kind==='salus-profile'?'.salus-profile':'.salus'),'');if(kind==='parent-salus'){fs.writeFileSync(path.join(f.work,'.salus'),'');const nested=path.join(f.work,'nested');fs.mkdirSync(nested);f.cwd=nested;}const r=run(f,3);if(kind.includes('vault'))assert(r.stderr.includes('vault corpus'));if(kind.includes('salus'))assert(r.stderr.includes('PHI-marked'));});
test('explicit deny beats later allow',()=>{const f=setup();matrix(f,[{...cell,verdict:'deny'},{...cell,verdict:'allow'}]);run(f,3);});
test('wildcard hard deny beats explicit conditional',()=>{const f=setup();matrix(f,[{corpus:'*',provider:'*',purpose:'*',verdict:'deny',hard:true},cell]);run(f,3);});
test('wildcard allow cannot authorize a provider',()=>{const f=setup();matrix(f,[{corpus:'*',provider:'*',purpose:'*',verdict:'allow'}]);run(f,3);});
test('unknown condition refuses',()=>{const f=setup();matrix(f,[{...cell,condition:'some other condition'}]);run(f,3);});
test('extraction cell cannot authorize inference',()=>{const f=setup();matrix(f,[{...cell,purpose:'extraction'}]);run(f,3);});
for(const response of [JSON.stringify({is_available:true,balance_infos:[{currency:'USD',total_balance:'2.99'}]}),JSON.stringify({is_available:false,balance_infos:[{currency:'USD',total_balance:'50'}]}),'{}','not json',JSON.stringify({is_available:true,balance_infos:[{currency:'CNY',total_balance:'50'}]}),JSON.stringify({is_available:true,balance_infos:[{currency:'USD',total_balance:null}]}),JSON.stringify({is_available:true,balance_infos:[{currency:'USD',total_balance:'NaN'}]})]) test('unavailable, low or unknown balance refuses '+response,()=>{const f=setup();f.env.BALANCE_RESPONSE=response;run(f,5);});
test('exact balance floor accepted',()=>{const f=setup();f.env.BALANCE_RESPONSE=JSON.stringify({is_available:true,balance_infos:[{currency:'USD',total_balance:'3.00'}]});run(f);});
test('custom balance floor enforced',()=>{const f=setup();f.env.DEEPSEEK_MIN_BALANCE_USD='51';run(f,5);});
test('missing key refuses',()=>{const f=setup();delete f.env.DEEPSEEK_API_KEY;run(f,2);});
test('malformed seed refuses',()=>{const f=setup();fs.mkdirSync(path.join(f.home,'.claude-deepseek'));fs.writeFileSync(path.join(f.home,'.claude-deepseek','.claude.json'),'{');run(f,4);});
test('PowerShell mirrored settings use the real sanitizer predicate',()=>{const f=setup();const source=fs.readFileSync(path.join(scripts,'claude-deepseek.ps1'),'utf8');const m=source.match(/\$SanitizerJs = @'\r?\n([\s\S]*?)\r?\n'@/);assert(m,'PowerShell cannot mirror sanitized settings without its sanitizer');const out=path.join(f.root,'sanitized.json');cp.execFileSync('node',['-e',m[1],path.join(f.home,'.claude','settings.json'),out],{env:f.env});const j=JSON.parse(fs.readFileSync(out,'utf8'));assert(!j.model);assert(!j.env.ANTHROPIC_AUTH_TOKEN);assert.strictEqual(j.env.KEEP,'yes');});
for(const root of roots)fs.rmSync(root,{recursive:true,force:true});
console.log(count+' passed; '+fails+' failed');process.exit(fails?1:0);
NODE
