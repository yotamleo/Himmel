'use strict';
// provenance.js -- the install-provenance ledger writer, node dialect
// (HIMMEL-3332 S1). Twins: scripts/lib/provenance.sh and provenance.ps1 write
// BYTE-IDENTICAL rows; scripts/himmelctl/test/test-provenance-js.sh cross-checks
// this file against the bash one on the same input. Format, kinds, write points:
// docs/internals/install-provenance.md.
//
// API -- each function takes the SAME argv the bash function takes:
//   provBegin(['--writer', 'himmelctl', '--', ...argv])   // opens a session, sets process.env.HIMMEL_PROVENANCE_IID
//   provRecord(['replace', 'file', dest, '--pre-file', snap, '--backup', '--post-file', dest, ...])
//   provEnd('ok' | 'failed' | 'partial', failedStep?)
// provRecord returns 'DRY: record <op> <kind> <path>' on a dry run (the caller
// prints it) and null otherwise. Failures throw ProvError (.code 2 = usage,
// 1 = I/O or a missing tool). CLI: node provenance.js begin|record|end ...
// (same flags; `end` closes the exported session unconditionally).
//
// Call provRecord AFTER the writer's atomic write, BEFORE its success line.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const OPS = ['create', 'replace', 'insert', 'append', 'register', 'link', 'noop'];
const KINDS = ['file', 'tree', 'json-key', 'json-elem', 'block', 'line', 'plugin', 'marketplace',
  'job', 'unit', 'shim', 'symlink', 'git-hook', 'mcp', 'collection', 'tool'];
const SCOPES = ['user', 'project', 'clone', 'machine'];
const CLASSES = ['code', 'state', 'keep'];
const RESERVED = ['t', 'iid', 'op', 'kind', 'path', 'unit', 'scope', 'class', 'pre', 'post', 'writer', 'manifest_row'];
const ROOT = path.resolve(__dirname, '..', '..', '..').replace(/\\/g, '/');

let owned = null; // the iid this process opened (provEnd closes only its own)

class ProvError extends Error {
  constructor(code, msg) { super(msg); this.code = code; }
}
const usage = (m) => new ProvError(2, m);
const fail = (m) => new ProvError(1, m);

// ── encoding: exactly what `jq -c` emits ────────────────────────────────
// JSON.stringify differs from jq in one place that matters here: DEL (0x7f) is
// escaped by jq as \u007f. Control chars are lowercase \u00xx in both;
// U+2028 and non-BMP characters stay raw in both.
const jstr = (s) => JSON.stringify(String(s)).replace(/\x7f/g, '\\u007f');
const jstrOrNull = (s) => (s ? jstr(s) : 'null');
const obj = (pairs) => '{' + pairs.map(([k, v]) => jstr(k) + ':' + v).join(',') + '}';

let jqOk = null;
function jqCanon(text) {
  if (jqOk !== false) {
    const r = spawnSync('jq', ['-cS', '.'], { input: text, encoding: 'utf8' });
    if (!r.error) {
      jqOk = true;
      if (r.status !== 0) return null;
      const out = r.stdout.replace(/\n$/, '');
      // one JSON document only: jq -c prints a line per document ('1 2' -> two lines)
      return out === '' || out.includes('\n') ? null : out;
    }
    jqOk = false;
  }
  // ponytail: no jq on PATH -- this fallback sorts keys by UTF-16 code unit and
  // prints numbers through JS Number, so it diverges from `jq -cS` on non-BMP
  // key order and on non-canonical number literals (1.0, 1E+2, integers past
  // 2^53). The hashes then differ from the bash/ps1 dialects for such values;
  // every install host already has jq (deps-engine requires it).
  try { return sortedJson(JSON.parse(text)); } catch (_) { return null; }
}
function sortedJson(v) {
  if (Array.isArray(v)) return '[' + v.map(sortedJson).join(',') + ']';
  if (v !== null && typeof v === 'object') {
    return '{' + Object.keys(v).sort().map((k) => jstr(k) + ':' + sortedJson(v[k])).join(',') + '}';
  }
  return typeof v === 'string' ? jstr(v) : JSON.stringify(v);
}
function canonOrThrow(text, code) {
  const c = jqCanon(text);
  if (c === null) throw new ProvError(code, `not valid JSON: ${text}`);
  return c;
}

const shaBuf = (b) => crypto.createHash('sha256').update(b).digest('hex');
const shaText = (s) => shaBuf(Buffer.from(String(s), 'utf8'));
const shaFile = (f) => shaBuf(fs.readFileSync(f));
const shaJson = (text) => shaText(canonOrThrow(text, 1));

// ── paths ───────────────────────────────────────────────────────────────
const fwd = (p) => p.replace(/\\/g, '/');
const isDir = (p) => { try { return fs.statSync(p).isDirectory(); } catch (_) { return false; } };

// realpath of the deepest existing ancestor, the missing tail appended
// (canon-path.sh canon_path_partial).
function canonPartial(p) {
  if (!p) throw fail('cannot resolve an empty path');
  p = fwd(p);
  let rest = '';
  while (!isDir(p)) {
    const i = p.lastIndexOf('/');
    if (i < 0) throw fail(`cannot resolve ${p}`);
    rest = p.slice(i) + rest;
    p = p.slice(0, i) || '/';
  }
  return fwd(fs.realpathSync(p)).replace(/\/$/, '') + rest;
}

// absolute, parent chain resolved, basename left as given (a link stays a link).
function absPath(p) {
  p = fwd(p);
  if (!(p.startsWith('/') || /^[A-Za-z]:\//.test(p))) p = fwd(process.cwd()) + '/' + p;
  while (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
  const i = p.lastIndexOf('/');
  const base = p.slice(i + 1);
  const dir = canonPartial(p.slice(0, i) || '/');
  return base === '' ? (dir || '/') : dir.replace(/\/$/, '') + '/' + base;
}

function homeDir() {
  return process.env.HOME || process.env.USERPROFILE || '';
}
function ledgerDir() {
  let d = process.env.HIMMEL_PROVENANCE_DIR || '';
  if (!d) {
    const h = homeDir();
    if (!h) throw fail('HOME is unset and HIMMEL_PROVENANCE_DIR is not given');
    d = h + '/.himmel';
  }
  return canonPartial(d);
}
const ledgerPath = () => ledgerDir() + '/provenance.jsonl';

// ── misc ────────────────────────────────────────────────────────────────
const now = () => process.env.HIMMEL_PROVENANCE_NOW || new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const pad = (n, w) => String(n).padStart(w, '0');
function newIid() {
  const d = new Date();
  const stamp = `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1, 2)}${pad(d.getUTCDate(), 2)}T` +
    `${pad(d.getUTCHours(), 2)}${pad(d.getUTCMinutes(), 2)}${pad(d.getUTCSeconds(), 2)}Z`;
  return `${stamp}-${crypto.randomBytes(3).toString('hex')}`;
}
const isDry = () => process.env.DRY_RUN === '1';
const modeOf = (f) => pad((fs.statSync(f).mode & 0o7777).toString(8), 4);

function append(line) {
  const dir = ledgerDir();
  const file = dir + '/provenance.jsonl';
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    let torn = false;
    try {
      const st = fs.statSync(file);
      if (st.size > 0) {
        const fd = fs.openSync(file, 'r');
        const b = Buffer.alloc(1);
        fs.readSync(fd, b, 0, 1, st.size - 1);
        fs.closeSync(fd);
        torn = b[0] !== 0x0a;
      }
    } catch (_) { /* no ledger yet */ }
    fs.appendFileSync(file, (torn ? '\n' : '') + line + '\n', { mode: 0o600 });
  } catch (e) {
    throw fail(`cannot append to ${file}: ${e.message}`);
  }
}

// ── rows ────────────────────────────────────────────────────────────────
function beginRow(iid, writer, target, root, argv) {
  let head = '';
  const g = spawnSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  if (!g.error && g.status === 0) head = g.stdout.trim();
  let version = '';
  try { version = fs.readFileSync(root + '/VERSION', 'utf8').replace(/[ \r\n]/g, ''); } catch (_) { /* none */ }
  const h = homeDir();
  let home = h;
  try { home = fwd(fs.realpathSync(h)); } catch (_) { /* raw */ }
  const cfgRaw = process.env.CLAUDE_CONFIG_DIR || (h + '/.claude');
  let cfg = cfgRaw;
  try { cfg = canonPartial(cfgRaw); } catch (_) { /* raw */ }
  return obj([
    ['t', jstr(now())], ['iid', jstr(iid)], ['op', jstr('install-begin')],
    ['himmel_root', jstr(root)], ['himmel_head', jstrOrNull(head)], ['version', jstrOrNull(version)],
    ['argv', '[' + argv.map(jstr).join(',') + ']'], ['home', jstr(home)], ['claude_config_dir', jstr(cfg)],
    ['target', jstrOrNull(target)], ['platform', jstr(process.platform)], ['writer', jstrOrNull(writer)],
  ]);
}
const endRow = (iid, status, step) => obj([
  ['t', jstr(now())], ['iid', jstr(iid)], ['op', jstr('install-end')],
  ['status', jstr(status)], ['failed_step', jstrOrNull(step)],
]);

// ── sessions ────────────────────────────────────────────────────────────
function provBegin(args) {
  let writer = ''; let target = ''; let root = ROOT; let iid = ''; let dry = false;
  const need = (i, f) => { if (i + 1 >= args.length) throw usage(`prov_begin: ${f} needs a value`); return args[i + 1]; };
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i];
    if (a === '--writer') { writer = need(i, a); i++; }
    else if (a === '--target') { target = need(i, a); i++; }
    else if (a === '--root') { root = need(i, a); i++; }
    else if (a === '--iid') { iid = need(i, a); i++; }
    else if (a === '--dry-run') dry = true;
    else if (a === '--') { i++; break; }
    else throw usage(`prov_begin: unknown option ${a}`);
  }
  const argv = args.slice(i);
  if (dry || isDry()) return;
  if (!iid) {
    if (process.env.HIMMEL_PROVENANCE_IID) return;
    iid = newIid();
  }
  if (target) { try { target = absPath(target); } catch (_) { /* raw */ } }
  append(beginRow(iid, writer, target, root, argv));
  process.env.HIMMEL_PROVENANCE_IID = iid;
  owned = iid;
  return iid;
}

function provEnd(status, step, opts) {
  if (!['ok', 'failed', 'partial'].includes(status)) throw usage('prov_end: status must be ok|failed|partial');
  if (isDry()) return;
  const iid = process.env.HIMMEL_PROVENANCE_IID || '';
  if (!iid) return;
  if (!(opts && opts.force) && owned !== iid) return;
  append(endRow(iid, status, step || ''));
  // close ownership only once the end row is on disk, so a failed append can be retried
  delete process.env.HIMMEL_PROVENANCE_IID;
  owned = null;
}

// ── artifact rows ───────────────────────────────────────────────────────
function body(kind, type, val) {
  if (type === 'file') {
    let st;
    try { st = fs.statSync(val); } catch (_) { st = null; }
    if (!st || !st.isFile()) throw fail(`not a file: ${val}`);
    return obj([['sha', jstr(shaFile(val))], ['size', String(st.size)], ['mode', jstr(modeOf(val))]]);
  }
  if (type === 'text') return obj([['sha', jstr(shaText(val))]]);
  const c = canonOrThrow(val, 1);
  return (kind === 'json-key' || kind === 'json-elem')
    ? obj([['sha', jstr(shaText(c))]])
    : obj([['value', c]]);
}

function backup(iid, upath, type, val) {
  const bdir = ledgerDir() + '/provenance-backups/' + iid;
  try {
    fs.mkdirSync(bdir, { recursive: true, mode: 0o700 });
    let n = fs.readdirSync(bdir).length + 1;
    let dest;
    for (;;) {
      let name = pad(n, 3) + '-' + upath.slice(upath.lastIndexOf('/') + 1);
      if (type === 'json') name += '.prior.json';
      else if (type === 'text') name += '.prior.txt';
      dest = bdir + '/' + name;
      // reserve the name atomically (O_EXCL) so two writers sharing an iid
      // cannot both pick the same sequence number
      try { fs.closeSync(fs.openSync(dest, 'wx', 0o600)); break; } catch (e) { if (e.code !== 'EEXIST') throw e; }
      n++;
    }
    if (type === 'file') {
      fs.copyFileSync(val, dest);
      fs.chmodSync(dest, fs.statSync(val).mode & 0o7777);
    } else {
      fs.writeFileSync(dest, type === 'json' ? canonOrThrow(val, 1) : val);
    }
    return dest;
  } catch (e) {
    if (e instanceof ProvError) throw e;
    throw fail(`cannot write backup in ${bdir}: ${e.message}`);
  }
}

function provRecord(args) {
  if (args.length < 3) throw usage('prov_record: usage: prov_record <op> <kind> <path|-> [flags]');
  const [op, kind, p0] = args;
  if (!OPS.includes(op)) throw usage(`prov_record: unknown op '${op}'`);
  if (!KINDS.includes(kind)) throw usage(`prov_record: unknown kind '${kind}'`);
  let unit = ''; let scope = ''; let cls = ''; let row = ''; let writer = '';
  let preT = ''; let preV = ''; let postT = ''; let postV = ''; let doBackup = false; let dry = false;
  const fields = new Map();
  for (let i = 3; i < args.length; i++) {
    const a = args[i];
    if (a === '--backup') { doBackup = true; continue; }
    if (a === '--dry-run') { dry = true; continue; }
    if (a === '--pre-absent') { preT = 'absent'; preV = ''; continue; }
    if (i + 1 >= args.length) throw usage(`prov_record: ${a} needs a value`);
    const v = args[++i];
    switch (a) {
      case '--unit': unit = v; break;
      case '--scope':
        if (!SCOPES.includes(v)) throw usage(`prov_record: bad scope '${v}'`);
        scope = v; break;
      case '--class':
        if (!CLASSES.includes(v)) throw usage(`prov_record: bad class '${v}'`);
        cls = v; break;
      case '--row': row = v; break;
      case '--writer': writer = v; break;
      case '--field': {
        const eq = v.indexOf('=');
        if (eq < 0) throw usage('prov_record: --field wants KEY=JSON');
        const k = v.slice(0, eq);
        if (!/^[a-z_][a-z0-9_]*$/.test(k)) throw usage(`prov_record: bad field key '${k}'`);
        if (RESERVED.includes(k)) throw usage(`prov_record: field key '${k}' is reserved`);
        const c = jqCanon(v.slice(eq + 1));
        if (c === null) throw usage(`prov_record: --field ${k} is not valid JSON`);
        fields.set(k, c);
        break;
      }
      case '--pre-file': preT = 'file'; preV = v; break;
      case '--pre-json': preT = 'json'; preV = v; break;
      case '--pre-text': preT = 'text'; preV = v; break;
      case '--post-file': postT = 'file'; postV = v; break;
      case '--post-json': postT = 'json'; postV = v; break;
      case '--post-text': postT = 'text'; postV = v; break;
      default: throw usage(`prov_record: unknown option ${a}`);
    }
  }
  if (doBackup && !['file', 'json', 'text'].includes(preT)) {
    throw usage('prov_record: --backup needs --pre-file, --pre-json or --pre-text');
  }
  if (dry || isDry()) return `DRY: record ${op} ${kind} ${p0}`;

  let iid = process.env.HIMMEL_PROVENANCE_IID || '';
  const implicit = !iid;
  if (implicit) iid = newIid();
  let cpath = '';
  if (p0 !== '-' && p0 !== '') {
    try { cpath = absPath(p0); } catch (_) { throw fail(`cannot resolve ${p0}`); }
  }

  let pre = null;
  if (preT === 'absent') pre = '{"state":"absent"}';
  else if (preT) {
    const b = body(kind, preT, preV);
    let bk = 'null';
    if (doBackup) bk = jstr(backup(iid, cpath || unit || 'unit', preT, preV));
    pre = b.slice(0, -1).replace(/^\{/, '{"state":"present",') + ',"backup":' + bk + '}';
  }
  const post = postT ? body(kind, postT, postV) : null;

  const pairs = [['t', jstr(now())], ['iid', jstr(iid)], ['op', jstr(op)], ['kind', jstr(kind)]];
  if (cpath) pairs.push(['path', jstr(cpath)]);
  if (unit) pairs.push(['unit', jstr(unit)]);
  if (scope) pairs.push(['scope', jstr(scope)]);
  if (cls) pairs.push(['class', jstr(cls)]);
  for (const [k, v] of fields) pairs.push([k, v]);
  if (pre !== null) pairs.push(['pre', pre]);
  if (post !== null) pairs.push(['post', post]);
  if (writer) pairs.push(['writer', jstr(writer)]);
  if (row) pairs.push(['manifest_row', jstr(row)]);

  if (implicit) append(beginRow(iid, writer, '', ROOT, []));
  append(obj(pairs));
  if (implicit) append(endRow(iid, 'ok', ''));
  return null;
}

module.exports = {
  provBegin, provRecord, provEnd, ledgerPath, ledgerDir, shaFile, shaText, shaJson, jqCanon, ProvError,
};

if (require.main === module) {
  const [cmd, ...rest] = process.argv.slice(2);
  try {
    if (cmd === 'begin') { const id = provBegin(rest); if (id) process.stdout.write(id + '\n'); }
    else if (cmd === 'record') { const d = provRecord(rest); if (d) process.stdout.write(d + '\n'); }
    else if (cmd === 'end') provEnd(rest[0], rest[1], { force: true });
    else throw usage('usage: provenance.js begin|record|end ...');
  } catch (e) {
    if (!(e instanceof ProvError)) throw e;
    process.stderr.write(`provenance: ${e.message}\n`);
    process.exit(e.code);
  }
}
