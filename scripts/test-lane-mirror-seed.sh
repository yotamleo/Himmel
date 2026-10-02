#!/usr/bin/env bash
# HIMMEL-4091 / HIMMEL-4096: shared mirror contract and real launchers.
# Breaks caught: omitted copies/deletions, source changes during seeding,
# nested content stranded by mtimes, live-lock theft, and dead-owner/PID reuse.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# Optional scripts copy lets mutation checks leave the real helper untouched.
bash "$HERE/lib/clean-sandbox.sh" -- node - "${1:-$HERE}" <<'NODE'
const fs=require('fs'), path=require('path'), cp=require('child_process'), assert=require('assert');
const scripts=process.argv[2], roots=[];
let passed=0, failed=0;
function test(name, fn) { try { fn(); passed++; console.log('ok: '+name); } catch(e) { failed++; console.error('FAIL: '+name+' — '+e.message); } }
function start(pid) {
 const stat='/proc/'+pid+'/stat';
 if(fs.existsSync(stat))return 'linux:'+fs.readFileSync(stat,'utf8').replace(/^.*\) /,'').split(' ')[19];
 return 'ps:'+cp.execFileSync('ps',['-p',String(pid),'-o','lstart='],{encoding:'utf8'}).replace(/\n$/,'');
}
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
 const env={...process.env,HOME:home,PATH:bin+':'+process.env.PATH,CLIPROXY_API_KEY:'fixture',OPENROUTER_API_KEY:'fixture',DEEPSEEK_API_KEY:'fixture',HIMMEL_DEEPSEEK_INFERENCE_OK:'1',CLAUDE_CODEX_DOTENV_ROOT:work,CLAUDE_OPENROUTER_DOTENV_ROOT:work,CLAUDE_DEEPSEEK_DOTENV_ROOT:work,CLAUDE_OPENROUTER_EGRESS_MATRIX:matrix,CLAUDE_DEEPSEEK_EGRESS_MATRIX:matrix,CLAUDE_LANE_SEED_LOCK_TIMEOUT:'0',CLAUDE_LANE_SEED_LOCK_STALE:'60',CHILD_MARKER:path.join(root,'child')};
 return {root,home,lane,env,dir:path.join(home,'.claude-'+lane)};
}
function run(f, want=0) {
 fs.rmSync(f.env.CHILD_MARKER,{force:true});
 const r=cp.spawnSync('bash',[path.join(scripts,'claude-'+f.lane)],{env:f.env,cwd:path.dirname(scripts),encoding:'utf8',timeout:15000});
 assert.strictEqual(r.status,want,'exit '+r.status+' want '+want+'; '+r.stderr);
 assert.strictEqual(fs.existsSync(f.env.CHILD_MARKER),want===0,'launch boundary');
 return r;
}
function lock(f,pid,birth,old=true) {
 const p=f.dir+'.seed-lock';fs.mkdirSync(p);fs.writeFileSync(path.join(p,'owner'),pid+'\n'+birth+'\n');
 const age=new Date(Date.now()-(old?300000:0));fs.utimesSync(p,age,age);return p;
}
// Explicit allowlist, independent of the helper's fingerprint/copy loops.
const mirrorFiles=['settings.json','CLAUDE.md','RTK.md','commands/sub/x.md','skills/sub/x.md','hooks/sub/x.sh','agents/sub/x.md','plugins/installed_plugins.json','plugins/known_marketplaces.json','plugins/marketplaces/sub/x.json','plugins/claude-hud/config.json','claude-hud.json'];
const mirrorEntries=['settings.json','CLAUDE.md','RTK.md','commands','skills','hooks','agents','plugins/installed_plugins.json','plugins/known_marketplaces.json','plugins/marketplaces','plugins/claude-hud/config.json','claude-hud.json'];
function mirrorSetup() {
 const f=setup('mirror');
 for(const rel of mirrorFiles) {
  const p=path.join(f.home,'.claude',rel);fs.mkdirSync(path.dirname(p),{recursive:true});
  fs.writeFileSync(p,rel.endsWith('.json')?'{}\n':'fixture: '+rel+'\n');
 }
 fs.mkdirSync(f.dir,{recursive:true});return f;
}
function mirrorRun(f, want=0, changeSource=false) {
 const r=cp.spawnSync('bash',['-eu','-c',`
. "$1"
seed_fail() { echo "$1" >&2; exit 4; }
sanitize_settings() { cp "$1" "$2"; }
seed_stamp() { printf 'fixture\\n'; }
if [ "$2" = change ]; then
 seed_after_leaves() { printf 'changed during copy\\n' > "$HOME/.claude/RTK.md"; }
elif [ "$2" != stable ]; then
 change_rel="$2"
 seed_after_leaves() { printf '{"concurrent":true}\\n' > "$HOME/.claude/$change_rel"; }
fi
if [ "$2" != stable ] || [ ! -f "$CONFIG_DIR/.seeded" ] || config_seed_stale; then seed_config_dir; fi
`,'mirror-test',path.join(scripts,'lane-mirror-seed.sh'),typeof changeSource==='string'?changeSource:changeSource?'change':'stable'],{env:{...f.env,CONFIG_DIR:f.dir},encoding:'utf8',timeout:15000});
 assert.strictEqual(r.status,want,'mirror exit '+r.status+' want '+want+'; '+r.stderr);
 return r;
}
// Delay both contenders after their real stale check using the sourced helper's
// existing function seam; file handshakes, not elapsed time, order the race.
async function stealRace(scripts, f) {
 const fs=require('fs'), path=require('path'), cp=require('child_process'), assert=require('assert');
 const children=[];
 const shell=`
. "$1"
seed_fail() { echo "$1" >&2; exit 4; }
SEED_LANE="$LANE"; LOCK="$CONFIG_DIR.seed-lock"; SEED_LOCK_STALE=60; SEED_LOCK_TIMEOUT=0; RESEED=1
seed_config_dir() { :; }
if [ "$ROLE" = fresh ]; then
 seed_after_mirror() { touch "$RACE/fresh.ready"; while [ ! -f "$RACE/fresh.go" ]; do sleep 0.01; done; }
else
 eval "$(declare -f seed_lock_is_stale | sed '1s/seed_lock_is_stale/race_original_stale/')"
 seed_lock_is_stale() {
  race_original_stale || return 1
  if [ "$WINDOW" = checked ]; then
   touch "$RACE/$ROLE.ready"
   while [ ! -f "$RACE/$ROLE.go" ]; do sleep 0.01; done
  else
   touch "$RACE/$ROLE.checked"
   while [ ! -f "$RACE/checked.go" ]; do sleep 0.01; done
  fi
 }
fi
seed_with_lock
`;
 function spawn(role) {
  const child=cp.spawn('bash',['-eu','-c',shell,'race',path.join(scripts,'lane-mirror-seed.sh')],{env:{...f.env,CONFIG_DIR:f.dir,LANE:f.lane,RACE:f.root,ROLE:role,WINDOW:f.window||'checked'}});
  const result={child,code:null,stderr:''};children.push(result);
  child.stderr.on('data',s=>{result.stderr+=s;});child.on('exit',code=>{result.code=code;});
  return result;
 }
 async function wait(check, name) {
  const end=Date.now()+10000;
  while(!check()) { assert(Date.now()<end,'handshake timeout: '+name);await new Promise(r=>setTimeout(r,10)); }
 }
 const go=role=>fs.writeFileSync(path.join(f.root,role+'.go'),'');
 try {
  const first=spawn('first'), second=spawn('second');
  if(f.window==='rename') {
   await wait(()=>fs.existsSync(path.join(f.root,'first.checked'))&&fs.existsSync(path.join(f.root,'second.checked')),'two stale checks');
   go('checked');
  }
  await wait(()=>fs.existsSync(path.join(f.root,'first.ready'))&&fs.existsSync(path.join(f.root,'second.ready')),'two stale checks');
  go('first');await wait(()=>first.code!==null,'first retires and releases');assert.strictEqual(first.code,0,first.stderr);
  const fresh=spawn('fresh');await wait(()=>fs.existsSync(path.join(f.root,'fresh.ready')),'fresh acquisition');
  const lock=f.dir+'.seed-lock', before=fs.statSync(lock), owner=fs.readFileSync(path.join(lock,'owner'),'utf8');
  go('second');await wait(()=>second.code!==null,'delayed contender');
  assert(fs.existsSync(lock),'fresh lock was stolen by delayed contender');
  assert.strictEqual(fs.statSync(lock).ino,before.ino,'fresh lock inode changed');
  assert.strictEqual(fs.readFileSync(path.join(lock,'owner'),'utf8'),owner,'fresh ownership changed');
  assert.strictEqual(second.code,4,'delayed contender acquired fresh lock: '+second.stderr);
  go('fresh');await wait(()=>fresh.code!==null,'fresh release');assert.strictEqual(fresh.code,0,fresh.stderr);
 } finally {
  for(const role of ['first','second','fresh','checked'])go(role);
  for(const r of children)if(r.code===null)r.child.kill();
  await Promise.all(children.map(r=>r.code!==null?Promise.resolve():new Promise(resolve=>r.child.once('exit',resolve))));
 }
}
function raceRun(f, window='checked', legacy=false) {
 const p=lock(f,2147483647,'linux:1');
 if(legacy) { fs.unlinkSync(path.join(p,'owner'));const old=new Date(Date.now()-300000);fs.utimesSync(p,old,old); }
 f.window=window;
 if(window==='rename') {
  // Test-only preload delays the actual syscall AFTER its final identity stat.
  // Both contenders have already checked the same inode when readiness fires.
  const preload=path.join(f.root,'delay-rename.cjs');
  fs.writeFileSync(preload,`const fs=require('fs'),path=require('path'),rename=fs.renameSync;
fs.renameSync=function(from,to){
 if(String(to).includes('.stale.') && ['first','second'].includes(process.env.ROLE)) {
  const role=process.env.ROLE, root=process.env.RACE, deadline=Date.now()+10000;
  fs.writeFileSync(path.join(root,role+'.ready'),'');
  while(!fs.existsSync(path.join(root,role+'.go'))){if(Date.now()>deadline)throw Error('rename handshake timeout');Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,10);}
 }
 return rename.apply(this,arguments);
};\n`);
  f.env.NODE_OPTIONS='--require='+preload;
 }
 const result=cp.spawnSync(process.execPath,['-e','('+stealRace.toString()+')(process.argv[1],JSON.parse(process.argv[2])).catch(e=>{console.error(e.message);process.exitCode=1;})',scripts,JSON.stringify(f)],{encoding:'utf8',timeout:20000});
 assert.strictEqual(result.status,0,result.stderr);
}
function helperRun(f, body, want=0) {
 const r=cp.spawnSync('bash',['-eu','-c',`. "$1"
seed_fail() { echo "$1" >&2; exit 4; }
SEED_LANE=fixture; LOCK="$CONFIG_DIR.seed-lock"; SEED_LOCK_STALE=60; SEED_LOCK_TIMEOUT=0; RESEED=1
${body}`,'helper-test',path.join(scripts,'lane-mirror-seed.sh')],{env:{...f.env,CONFIG_DIR:f.dir},encoding:'utf8',timeout:15000});
 assert.strictEqual(r.status,want,'helper exit '+r.status+' want '+want+'; '+r.stderr);
 return r;
}
try {
 test('helper: orphaned pending directory for reused PID does not block acquisition',()=>{
  const f=setup('mirror');
  helperRun(f,`mkdir "$LOCK.pending.$$"
printf 'orphan\\n' > "$LOCK.pending.$$/owner"
seed_config_dir() { :; }
seed_with_lock
[ "$(cat "$LOCK.pending.$$/owner")" = orphan ]`);
 });
 test('helper: failed second identity check removes only its planted owner',()=>{
  const f=setup('mirror'),p=lock(f,2147483647,'linux:1'),preload=path.join(f.root,'plant-owner.cjs');
  fs.unlinkSync(path.join(p,'owner'));
  fs.writeFileSync(preload,`const fs=require('fs'),path=require('path'),write=fs.writeFileSync,open=fs.openSync;
const lock=process.env.CONFIG_DIR+'.seed-lock',owner=path.join(lock,'owner');let swapped=false;
function swap(p,flags) { if(!swapped && p===owner && flags==='wx') { swapped=true;fs.renameSync(lock,lock+'.held');fs.mkdirSync(lock); } }
fs.writeFileSync=function(p,data,opts){swap(p,opts&&opts.flag);return write.apply(this,arguments);};
fs.openSync=function(p,flags){swap(p,flags);return open.apply(this,arguments);};\n`);
  f.env.NODE_OPTIONS='--require='+preload;
  helperRun(f,'SEED_LOCK_IDENTITY="$(lane_seed_lock_identity)"; lane_seed_retire_lock',1);
  assert(fs.existsSync(p+'.held'),'owner-plant race did not execute');
  assert(!fs.existsSync(path.join(p,'owner')),'retirement left its planted owner in fresh lock');
  assert(fs.existsSync(p),'fresh lock removed');
 });
 for(const legacy of [false,true]) {
  test('helper: stale check rejects identity swapped during '+(legacy?'legacy recovery':'owner liveness'),()=>{
   const f=setup('mirror'),p=lock(f,process.pid,'linux:0');
   if(legacy)fs.unlinkSync(path.join(p,'owner'));
   const age=new Date(Date.now()-300000);fs.utimesSync(p,age,age);
   helperRun(f,`${legacy?'seed_legacy_lock_stale':'seed_process_start'}() {
mv "$LOCK" "$LOCK.held"
mkdir "$LOCK"
printf 'fixture\\n' > "$LOCK/owner"
printf 'linux:1'
}
seed_lock_is_stale`,1);
   assert(fs.existsSync(p+'.held'),'stale-check identity swap did not execute');
   assert(fs.existsSync(path.join(p,'owner')),'fresh acquisition lost');
  });
 }
 test('helper: copied private directories retain source access restrictions',()=>{
  const f=mirrorSetup(),src=path.join(f.home,'.claude','hooks');
  fs.chmodSync(src,0o700);fs.chmodSync(path.join(src,'sub'),0o500);
  try {
   mirrorRun(f);
   assert.strictEqual(fs.statSync(path.join(f.dir,'hooks')).mode&0o777,0o700,'private tree became public');
   assert.strictEqual(fs.statSync(path.join(f.dir,'hooks','sub')).mode&0o777,0o500,'read-only subtree mode changed');
  } finally {
   fs.chmodSync(path.join(src,'sub'),0o700);
   const dst=path.join(f.dir,'hooks','sub');if(fs.existsSync(dst))fs.chmodSync(dst,0o700);
  }
 });
 for(const rel of ['commands','skills','hooks','agents','plugins/marketplaces']) {
  test('helper: reseeds read-only '+rel+' directories without changing source modes',()=>{
   const f=mirrorSetup(),src=path.join(f.home,'.claude',rel),dst=path.join(f.dir,rel);
   const file=rel==='hooks'?'x.sh':rel==='plugins/marketplaces'?'x.json':'x.md';
   fs.chmodSync(src,0o500);fs.chmodSync(path.join(src,'sub'),0o500);
   try {
    mirrorRun(f);
    fs.writeFileSync(path.join(src,'sub',file),'updated read-only tree\n');
    mirrorRun(f);
    assert.strictEqual(fs.readFileSync(path.join(dst,'sub',file),'utf8'),'updated read-only tree\n');
    for(const p of [src,path.join(src,'sub'),dst,path.join(dst,'sub')]) {
     assert.strictEqual(fs.statSync(p).mode&0o777,0o500,'read-only mode changed: '+p);
    }
   } finally {
    for(const p of [src,path.join(src,'sub'),dst,path.join(dst,'sub')])if(fs.existsSync(p))fs.chmodSync(p,0o700);
   }
  });
 }
 test('helper: clearing stale directories never chmods symlink targets',()=>{
  const f=mirrorSetup(),outside=path.join(f.root,'outside'),src=path.join(f.home,'.claude','hooks');
  fs.mkdirSync(outside);fs.writeFileSync(path.join(outside,'private'),'private\n',{mode:0o400});
  fs.symlinkSync(outside,path.join(src,'linked'),'dir');fs.chmodSync(outside,0o500);
  try {
   mirrorRun(f);
   fs.writeFileSync(path.join(src,'sub','x.sh'),'changed\n');
   mirrorRun(f);
   assert.strictEqual(fs.statSync(outside).mode&0o777,0o500,'external directory mode changed');
   assert.strictEqual(fs.statSync(path.join(outside,'private')).mode&0o777,0o400,'external file mode changed');
   assert.strictEqual(fs.readFileSync(path.join(outside,'private'),'utf8'),'private\n','external file changed');
  } finally { fs.chmodSync(outside,0o700); }
 });
 for(const [kind,target] of [['directory','sub'],['file','sub/x.sh'],['dangling','missing-target']]) {
  test('helper: preserves '+kind+' symlink and its target while copying',()=>{
   const f=mirrorSetup(),src=path.join(f.home,'.claude','hooks',kind),dst=path.join(f.dir,'hooks',kind);
   fs.symlinkSync(target,src,kind==='directory'?'dir':'file');
   mirrorRun(f);
   assert(fs.lstatSync(dst).isSymbolicLink(),'copier dereferenced '+kind+' link');
   assert.strictEqual(fs.readlinkSync(dst),target,'symlink target changed');
   if(kind==='dangling')assert(!fs.existsSync(dst),'dangling link unexpectedly resolved');
  });
 }
 test('helper: destination symlink creation failure still refuses completion',()=>{
  const f=mirrorSetup();fs.symlinkSync('sub/x.sh',path.join(f.home,'.claude','hooks','linked'));
  const preload=path.join(f.root,'unwritable-link.cjs');
  fs.writeFileSync(preload,'require("fs").symlinkSync=()=>{throw Object.assign(Error("fixture destination denied"),{code:"EACCES"});};\n');
  f.env.NODE_OPTIONS='--require='+preload;
  mirrorRun(f,4);assert(!fs.existsSync(path.join(f.dir,'.seeded')),'failed destination published completion');
 });
 for(const kind of ['fifo','socket','cycle','unreadable']) {
  test('helper: tolerates '+kind+' seed entry with a diagnostic',()=>{
   const f=mirrorSetup(),p=path.join(f.home,'.claude','hooks',kind);
   if(kind==='fifo')assert.strictEqual(cp.spawnSync('mkfifo',[p]).status,0);
   if(kind==='socket')assert.strictEqual(cp.spawnSync(process.execPath,['-e','require("net").createServer().listen(process.argv[1],()=>process.exit(0))',p]).status,0);
   if(kind==='cycle')fs.symlinkSync('.',p,'dir');
   if(kind==='unreadable') {
    fs.writeFileSync(p,'private');
    const preload=path.join(f.root,'unreadable.cjs');
    fs.writeFileSync(preload,`const fs=require('fs'),read=fs.readFileSync;fs.readFileSync=function(p){if(p===${JSON.stringify(p)})throw Object.assign(Error('fixture unreadable'),{code:'EACCES'});return read.apply(this,arguments);};\n`);
    f.env.NODE_OPTIONS='--require='+preload;
   }
   const r=mirrorRun(f);
   assert(r.stderr.includes('hooks/'+kind),'skipped path not reported: '+r.stderr);
   const dst=path.join(f.dir,'hooks',kind);
   if(kind==='cycle') {
    assert(fs.lstatSync(dst).isSymbolicLink(),'cycle was not preserved as a link');
    assert.strictEqual(fs.readlinkSync(dst),'.','cycle target changed');
   } else assert(!fs.existsSync(dst),'unsupported entry copied');
   assert.strictEqual(fs.readFileSync(path.join(f.dir,'hooks/sub/x.sh'),'utf8'),'fixture: hooks/sub/x.sh\n');
  });
 }
 for(const rel of ['settings.json','plugins/marketplaces/sub/x.json']) {
  test('helper: concurrent write to '+rel+' completes and next launch reseeds',()=>{
   const f=mirrorSetup();mirrorRun(f);mirrorRun(f,0,rel);
   assert(fs.existsSync(path.join(f.dir,'.seeded')),'tolerated copy lacks completion');
   mirrorRun(f);
   assert.strictEqual(fs.readFileSync(path.join(f.dir,rel),'utf8'),'{"concurrent":true}\n');
  });
 }
 for(const rel of mirrorFiles) {
  test('helper: copies '+rel,()=>{const f=mirrorSetup();mirrorRun(f);assert.strictEqual(fs.readFileSync(path.join(f.dir,rel),'utf8'),rel.endsWith('.json')?'{}\n':'fixture: '+rel+'\n');});
  test('helper: changed '+rel+' reseeds with preserved mtimes',()=>{const f=mirrorSetup();mirrorRun(f);const p=path.join(f.home,'.claude',rel),s=fs.statSync(p);fs.writeFileSync(p,rel.endsWith('.json')?'{"changed":true}\n':'changed: '+rel+'\n');fs.utimesSync(p,s.atime,s.mtime);mirrorRun(f);assert.strictEqual(fs.readFileSync(path.join(f.dir,rel),'utf8'),rel.endsWith('.json')?'{"changed":true}\n':'changed: '+rel+'\n');});
 }
 for(const rel of mirrorEntries) {
  test('helper: deleted source removes target '+rel,()=>{const f=mirrorSetup();mirrorRun(f);assert(fs.existsSync(path.join(f.dir,rel)),'target must exist before deletion');fs.rmSync(path.join(f.home,'.claude',rel),{recursive:true});mirrorRun(f);assert(!fs.existsSync(path.join(f.dir,rel)),'stale target '+rel);assert(fs.existsSync(path.join(f.dir,'.seeded')),'deletion reseed completed');});
 }
 test('helper: a source changed during copy refuses completion',()=>{const f=mirrorSetup();mirrorRun(f);const r=mirrorRun(f,4,true);assert(r.stderr.includes('source that changed during seeding'));assert(!fs.existsSync(path.join(f.dir,'.seeded')),'failed copy published completion');});
 for(const lane of ['codex','openrouter','deepseek']) {
  test(lane+': two delayed stale contenders preserve a fresh acquisition',()=>raceRun(setup(lane)));
  test(lane+': two contenders delayed after final stat cannot rename the fresh lock',()=>raceRun(setup(lane),'rename'));
  test(lane+': empty legacy retirement stays non-empty across delayed renames',()=>raceRun(setup(lane),'rename',true));
  test(lane+': failed retirement can be recovered by the next contender',()=>{
   const f=setup(lane);lock(f,2147483647,'linux:1');
   const preload=path.join(f.root,'fail-retirement.cjs');
   fs.writeFileSync(preload,`const fs=require('fs'),rename=fs.renameSync;
fs.renameSync=function(from,to){if(String(to).includes('.stale.'))throw Object.assign(Error('fixture retirement failure'),{code:'EIO'});return rename.apply(this,arguments);};\n`);
   f.env.NODE_OPTIONS='--require='+preload;run(f,4);
   delete f.env.NODE_OPTIONS;run(f);
   assert(!fs.existsSync(f.dir+'.seed-lock'),'stale lock became permanently unrecoverable');
  });
  test(lane+': nested in-file edit reseeds even with preserved mtimes',()=>{const f=setup(lane);run(f);const p=path.join(f.home,'.claude','hooks','sub','x.sh'),s=fs.statSync(p);fs.writeFileSync(p,'new\n');fs.utimesSync(p,s.atime,s.mtime);run(f);assert.strictEqual(fs.readFileSync(path.join(f.dir,'hooks','sub','x.sh'),'utf8'),'new\n');});
  test(lane+': edits through symlinked mirror trees reseed',()=>{const f=setup(lane),src=path.join(f.home,'.claude','hooks'),target=path.join(f.root,'linked-hooks');fs.renameSync(src,target);fs.symlinkSync(target,src,'dir');run(f);const before=fs.readFileSync(path.join(f.dir,'.seed-fingerprint'),'utf8');fs.writeFileSync(path.join(target,'sub','x.sh'),'new linked content\n');run(f);assert.notStrictEqual(fs.readFileSync(path.join(f.dir,'.seed-fingerprint'),'utf8'),before,'symlink target content omitted from freshness');});
  test(lane+': old live-owner lock is not stolen',()=>{const f=setup(lane),p=lock(f,process.pid,start(process.pid));run(f,4);assert(fs.existsSync(p));assert.strictEqual(fs.readFileSync(path.join(p,'owner'),'utf8'),process.pid+'\n'+start(process.pid)+'\n');assert(!fs.existsSync(path.join(f.dir,'.seeded')));});
  test(lane+': old dead-owner lock is stolen',()=>{const f=setup(lane);lock(f,2147483647,'linux:1');run(f);assert(!fs.existsSync(f.dir+'.seed-lock'));assert(fs.existsSync(path.join(f.dir,'.seeded')));});
  test(lane+': recycled PID with different start is dead',()=>{const f=setup(lane);lock(f,process.pid,'linux:0');run(f);assert(!fs.existsSync(f.dir+'.seed-lock'));});
  test(lane+': interrupted directory creation never publishes an ownerless lock',()=>{
   const f=setup(lane);f.env.REAL_TEST_PATH=process.env.PATH;
   fs.writeFileSync(path.join(f.root,'bin','mkdir'),`#!/usr/bin/env node
const cp=require('child_process'), args=process.argv.slice(2);
const r=cp.spawnSync('mkdir',args,{env:{...process.env,PATH:process.env.REAL_TEST_PATH}});
if(r.status!==0)process.exit(r.status||1);
process.exit(args.some(a=>a.includes('.seed-lock'))?42:0);
`,{mode:0o755});
   run(f,4);
   const p=f.dir+'.seed-lock';
   assert(!fs.existsSync(p)||fs.existsSync(path.join(p,'owner')),'published ownerless lock after failed mkdir');
  });
  test(lane+': old legacy ownerless lock is stolen',()=>{const f=setup(lane),p=lock(f,2147483647,'linux:1');fs.unlinkSync(path.join(p,'owner'));const age=new Date(Date.now()-300000);fs.utimesSync(p,age,age);const r=run(f);assert(!fs.existsSync(p));assert(r.stderr.includes(p)&&/age [0-9]+s/.test(r.stderr),'legacy recovery path/age not logged');});
  test(lane+': young legacy ownerless lock is not stolen',()=>{const f=setup(lane),p=lock(f,2147483647,'linux:1',false);fs.unlinkSync(path.join(p,'owner'));run(f,4);assert(fs.existsSync(p));});
  test(lane+': young dead-owner lock is not stolen',()=>{const f=setup(lane);lock(f,2147483647,'linux:1',false);run(f,4);assert(fs.existsSync(f.dir+'.seed-lock'));});
  test(lane+': auto-reseed opt-out preserves nested old content',()=>{const f=setup(lane);run(f);fs.writeFileSync(path.join(f.home,'.claude','hooks','sub','x.sh'),'new\n');f.env.CLAUDE_LANE_AUTO_RESEED='0';run(f);assert.strictEqual(fs.readFileSync(path.join(f.dir,'hooks','sub','x.sh'),'utf8'),'old\n');});
 }
} finally { for(const root of roots)fs.rmSync(root,{recursive:true,force:true}); }
console.log(passed+' passed; '+failed+' failed');process.exit(failed?1:0);
NODE
