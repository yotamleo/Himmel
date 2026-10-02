#!/usr/bin/env bash
# HIMMEL-4091: exercise real launchers; only network and Claude are stubbed.
# Breaks caught: nested content stranded by directory mtimes, live-lock theft,
# dead-owner recovery lost, and PID reuse mistaken for the original owner.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/lib/clean-sandbox.sh" -- node - "$HERE" <<'NODE'
const fs=require('fs'), path=require('path'), cp=require('child_process'), assert=require('assert');
const scripts=process.argv[2], roots=[];
let passed=0, failed=0;
function test(name, fn) { try { fn(); passed++; console.log('ok: '+name); } catch(e) { failed++; console.error('FAIL: '+name+' — '+e.message); } }
function start(pid) { return 'linux:'+fs.readFileSync('/proc/'+pid+'/stat','utf8').replace(/^.*\) /,'').split(' ')[19]; }
function setup(lane) {
 const root=fs.mkdtempSync(path.join(process.env.TMPDIR,'mirror-seed-')); roots.push(root);
 const home=path.join(root,'home'), bin=path.join(root,'bin'), work=path.join(root,'work');
 for(const d of [home,bin,work,path.join(home,'.claude','hooks','sub')])fs.mkdirSync(d,{recursive:true});
 fs.writeFileSync(path.join(home,'.claude','settings.json'),'{}');
 fs.writeFileSync(path.join(home,'.claude','CLAUDE.md'),'operator rules\n');
 fs.writeFileSync(path.join(home,'.claude','hooks','sub','x.sh'),'old\n');
 fs.writeFileSync(path.join(bin,'claude'),'#!/usr/bin/env node\nrequire("fs").writeFileSync(process.env.CHILD_MARKER,"launched");\n',{mode:0o755});
 fs.writeFileSync(path.join(bin,'curl'),`#!/usr/bin/env node
const fs=require('fs');fs.readFileSync(0,'utf8');
const last=process.argv[process.argv.length-1];
process.stdout.write(last.endsWith('/user/balance')?JSON.stringify({is_available:true,balance_infos:[{currency:'USD',total_balance:'50'}]}):last.endsWith('/key')?JSON.stringify({data:{limit:null}}):JSON.stringify({data:{total_credits:50,total_usage:0}}));
`,{mode:0o755});
 const matrix=path.join(root,'matrix.json');
 fs.writeFileSync(matrix,JSON.stringify({providers:{openrouter:{region:'US'},deepseek:{region:'CN'}},rules:['openrouter','deepseek'].map(provider=>({corpus:'himmel-code',provider,purpose:'inference',verdict:'allow'})),default:'deny'}));
 const env={...process.env,HOME:home,PATH:bin+':'+process.env.PATH,CLIPROXY_API_KEY:'fixture',OPENROUTER_API_KEY:'fixture',DEEPSEEK_API_KEY:'fixture',HIMMEL_DEEPSEEK_INFERENCE_OK:'1',CLAUDE_CODEX_DOTENV_ROOT:work,CLAUDE_OPENROUTER_DOTENV_ROOT:work,CLAUDE_DEEPSEEK_DOTENV_ROOT:work,CLAUDE_OPENROUTER_EGRESS_MATRIX:matrix,CLAUDE_DEEPSEEK_EGRESS_MATRIX:matrix,CLAUDE_LANE_SEED_LOCK_TIMEOUT:'0',CLAUDE_LANE_SEED_LOCK_STALE:'1',CHILD_MARKER:path.join(root,'child')};
 return {root,home,lane,env,dir:path.join(home,'.claude-'+lane)};
}
function run(f, want=0) {
 fs.rmSync(f.env.CHILD_MARKER,{force:true});
 const r=cp.spawnSync('bash',[path.join(scripts,'claude-'+f.lane)],{env:f.env,cwd:path.dirname(scripts),encoding:'utf8',timeout:15000});
 assert.strictEqual(r.status,want,'exit '+r.status+' want '+want+'; '+r.stderr);
 assert.strictEqual(fs.existsSync(f.env.CHILD_MARKER),want===0,'launch boundary');
}
function lock(f,pid,birth,old=true) {
 const p=f.dir+'.seed-lock';fs.mkdirSync(p);fs.writeFileSync(path.join(p,'owner'),pid+'\n'+birth+'\n');
 const age=new Date(Date.now()-(old?300000:0));fs.utimesSync(p,age,age);return p;
}
try {
 for(const lane of ['codex','openrouter','deepseek']) {
  test(lane+': nested in-file edit reseeds even with preserved mtimes',()=>{const f=setup(lane);run(f);const p=path.join(f.home,'.claude','hooks','sub','x.sh'),s=fs.statSync(p);fs.writeFileSync(p,'new\n');fs.utimesSync(p,s.atime,s.mtime);run(f);assert.strictEqual(fs.readFileSync(path.join(f.dir,'hooks','sub','x.sh'),'utf8'),'new\n');});
  test(lane+': old live-owner lock is not stolen',()=>{const f=setup(lane),p=lock(f,process.pid,start(process.pid));run(f,4);assert(fs.existsSync(p));assert.strictEqual(fs.readFileSync(path.join(p,'owner'),'utf8'),process.pid+'\n'+start(process.pid)+'\n');assert(!fs.existsSync(path.join(f.dir,'.seeded')));});
  test(lane+': old dead-owner lock is stolen',()=>{const f=setup(lane);lock(f,2147483647,'linux:1');run(f);assert(!fs.existsSync(f.dir+'.seed-lock'));assert(fs.existsSync(path.join(f.dir,'.seeded')));});
  test(lane+': recycled PID with different start is dead',()=>{const f=setup(lane);lock(f,process.pid,'linux:0');run(f);assert(!fs.existsSync(f.dir+'.seed-lock'));});
  test(lane+': young dead-owner lock is not stolen',()=>{const f=setup(lane);lock(f,2147483647,'linux:1',false);run(f,4);assert(fs.existsSync(f.dir+'.seed-lock'));});
  test(lane+': auto-reseed opt-out preserves nested old content',()=>{const f=setup(lane);run(f);fs.writeFileSync(path.join(f.home,'.claude','hooks','sub','x.sh'),'new\n');f.env.CLAUDE_LANE_AUTO_RESEED='0';run(f);assert.strictEqual(fs.readFileSync(path.join(f.dir,'hooks','sub','x.sh'),'utf8'),'old\n');});
 }
} finally { for(const root of roots)fs.rmSync(root,{recursive:true,force:true}); }
console.log(passed+' passed; '+failed+' failed');process.exit(failed?1:0);
NODE
