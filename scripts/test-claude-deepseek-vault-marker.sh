#!/usr/bin/env bash
# HIMMEL-4084: marker classification must beat an ancestor handover root and
# caller CWD overrides. Execute both launchers and their actual PS egress JS.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)" || exit 2
bash "$HERE/lib/clean-sandbox.sh" -- node - "$HERE" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process'),assert=require('assert');
const scripts=process.argv[2],roots=[];
let passed=0,failed=0;
function test(name,fn){try{fn();passed++;console.log('ok: '+name);}catch(e){failed++;console.error('FAIL: '+name+' — '+e.message);}}
for(const lane of ['deepseek','openrouter']) for(const twin of ['bash','ps-js']) for(const kind of ['root','nested','symlink','override','file-control','outside-control']) test(lane+' '+twin+' '+kind,()=>{
 const root=fs.mkdtempSync(path.join(process.env.TMPDIR,'vault-marker-'));roots.push(root);
 const home=path.join(root,'home'),bin=path.join(root,'bin'),vault=path.join(root,'vault'),nested=path.join(vault,'nested');
 for(const d of [home,bin,nested])fs.mkdirSync(d,{recursive:true});
 if(kind==='file-control')fs.writeFileSync(path.join(vault,'.obsidian'),'not a vault directory');
 else fs.mkdirSync(path.join(vault,'.obsidian'));
 let cwd=kind==='root'?vault:nested;
 if(kind==='symlink'){cwd=path.join(root,'link');fs.symlinkSync(nested,cwd,'dir');}
 if(kind==='outside-control')cwd=home;
 const matrix=path.join(root,'matrix.json');
 fs.writeFileSync(matrix,JSON.stringify({providers:{[lane]:{}},rules:[{corpus:'luna-personal',provider:lane,purpose:'inference',verdict:'deny'},{corpus:'handover-state',provider:lane,purpose:'inference',verdict:'allow'}],default:'deny'}));
 const capture=path.join(root,'child.json'),curlCapture=path.join(root,'curl.jsonl');
 fs.writeFileSync(path.join(bin,'curl'),`#!/usr/bin/env node
const fs=require('fs');fs.appendFileSync(process.env.CURL_CAPTURE,JSON.stringify(process.argv.slice(2))+'\\n');fs.readFileSync(0,'utf8');console.log(JSON.stringify(process.argv.at(-1).endsWith('/key')?{data:{limit:null,limit_remaining:null}}:process.env.DEEPSEEK_API_KEY?{is_available:true,balance_infos:[{currency:'USD',total_balance:'50'}]}:{data:{total_credits:51,total_usage:1}}));
`,{mode:0o755});
 fs.writeFileSync(path.join(bin,'claude'),`#!/usr/bin/env node
require('fs').writeFileSync(process.env.CHILD_CAPTURE,JSON.stringify({argv:process.argv.slice(2)}));
`,{mode:0o755});
 const env={...process.env,HOME:home,PATH:bin+':'+process.env.PATH,HANDOVER_DIR:root,HIMMEL_DEEPSEEK_INFERENCE_OK:'1',CHILD_CAPTURE:capture,CURL_CAPTURE:curlCapture};
 const prefix='CLAUDE_'+lane.toUpperCase();
 env[lane.toUpperCase()+'_API_KEY']='marker-test-secret';env[prefix+'_EGRESS_MATRIX']=matrix;env[prefix+'_DOTENV_ROOT']=home;
 if(kind==='override')env[prefix+'_CWD']=home;
 let args;
 if(twin==='bash')args=[path.join(scripts,'claude-'+lane)];
 else{const source=fs.readFileSync(path.join(scripts,'claude-'+lane+'.ps1'),'utf8');const m=source.match(/\$EgressJs = @'\r?\n([\s\S]*?)\r?\n'@/);assert(m,'missing twin egress predicate');args=['-e',m[1],matrix,path.dirname(scripts)];}
 const r=cp.spawnSync(twin==='bash'?'bash':'node',args,{cwd,env,encoding:'utf8'});
 const control=kind.endsWith('control');assert.strictEqual(r.status,control?0:3,r.stderr);
 assert(!(r.stdout+r.stderr).includes('marker-test-secret'),'secret in output');
 if(control&&twin==='bash')assert(fs.existsSync(capture),'allowed workspace did not launch Claude');
 if(!control){assert(!fs.existsSync(capture),'Claude launched in a vault');assert(!fs.existsSync(curlCapture),'network reached before vault refusal');assert(/vault corpus|luna-personal/.test(r.stderr),'missing vault classification');}
 if(fs.existsSync(capture))assert(!fs.readFileSync(capture,'utf8').includes('marker-test-secret'),'secret in Claude argv');
 if(fs.existsSync(curlCapture))assert(!fs.readFileSync(curlCapture,'utf8').includes('marker-test-secret'),'secret in curl argv');
});
for(const root of roots)fs.rmSync(root,{recursive:true,force:true});
console.log(passed+' passed; '+failed+' failed');process.exit(failed?1:0);
NODE
