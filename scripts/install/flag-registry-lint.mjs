#!/usr/bin/env node
// flag-registry-lint.mjs — HIMMEL-4254 P2 (spec §5.1): every `*_OK` / `*_BYPASS`
// environment flag a hook reads must have an entry in the display registry
// scripts/himmelctl/lib/bypass-flags.json, and every entry must name a hook
// file that exists. The config UI shows bypass flags display-only, so an
// unregistered flag is a flag the UI silently cannot show.
//
// Scans every non-test file under scripts/hooks/ plus every scripts/lib/*.sh
// those hooks source (one level). Test files (test-*, *.test.*, fixtures/) and
// *.md are not hooks and are skipped; a flag that only a test mentions is not
// a bypass.
//
// usage: flag-registry-lint.mjs [--root <repo>]   lint, exit 1 on a finding
//        flag-registry-lint.mjs --seed [--root <repo>]
//                                                  print a registry skeleton
//                                                  (name + hooks[]) from the scan
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const FLAG_RE = /\b[A-Z][A-Z0-9_]{3,}_(?:OK|BYPASS)\b/g;
const REGISTRY_REL = 'scripts/himmelctl/lib/bypass-flags.json';

function isHookFile(rel) {
  const base = path.posix.basename(rel);
  if (/^test-/.test(base) || /\.test\./.test(base)) return false;
  if (rel.split('/').includes('fixtures')) return false;
  if (rel.split('/').includes('node_modules')) return false;
  return !/\.md$/.test(base);
}

function walk(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.isFile()) out.push(p);
  }
  return out;
}

// Files the scan covers: the hooks plus the scripts/lib/*.sh they source.
export function scannedFiles(root) {
  const hooksDir = path.join(root, 'scripts', 'hooks');
  const rel = (p) => path.relative(root, p).split(path.sep).join('/');
  const hooks = walk(hooksDir).map(rel).filter(isHookFile);
  const files = new Set(hooks);
  for (const h of hooks) {
    let text;
    try { text = fs.readFileSync(path.join(root, h), 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      if (!/^\s*(?:source|\.)\s/.test(line)) continue;
      const m = /scripts\/lib\/([A-Za-z0-9_.-]+\.sh)/.exec(line);
      if (m && fs.existsSync(path.join(root, 'scripts', 'lib', m[1]))) files.add(`scripts/lib/${m[1]}`);
    }
  }
  return [...files].sort();
}

// name -> sorted list of scanned files that mention it
export function scanFlags(root) {
  const found = new Map();
  for (const f of scannedFiles(root)) {
    let text;
    try { text = fs.readFileSync(path.join(root, f), 'utf8'); } catch { continue; }
    for (const name of new Set(text.match(FLAG_RE) || [])) {
      if (!found.has(name)) found.set(name, []);
      found.get(name).push(f);
    }
  }
  return found;
}

export function lint(root) {
  const errors = [];
  let registry;
  try {
    registry = JSON.parse(fs.readFileSync(path.join(root, REGISTRY_REL), 'utf8'));
  } catch (e) {
    return [`cannot read ${REGISTRY_REL}: ${e.message}`];
  }
  const flags = Array.isArray(registry.flags) ? registry.flags : [];
  const named = new Set(flags.map((f) => f.name));
  for (const [name, files] of [...scanFlags(root)].sort()) {
    if (!named.has(name)) errors.push(`${name} is read by ${files.join(', ')} but has no entry in ${REGISTRY_REL}`);
  }
  for (const f of flags) {
    for (const k of ['name', 'bypasses', 'remedy']) {
      if (typeof f[k] !== 'string' || f[k] === '') errors.push(`${f.name || '(unnamed entry)'}: missing ${k}`);
    }
    if (!Array.isArray(f.hooks) || f.hooks.length === 0) {
      errors.push(`${f.name}: names no hook`);
      continue;
    }
    for (const h of f.hooks) {
      if (!fs.existsSync(path.join(root, h))) errors.push(`${f.name}: names hook ${h}, which does not exist`);
    }
  }
  return errors;
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const argv = process.argv.slice(2);
  const ri = argv.indexOf('--root');
  const root = ri !== -1 ? path.resolve(argv[ri + 1]) : path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
  if (argv.includes('--seed')) {
    const flags = [...scanFlags(root)].sort().map(([name, hooks]) => ({ name, hooks }));
    process.stdout.write(JSON.stringify({ flags }, null, 2) + '\n');
  } else {
    const errors = lint(root);
    if (errors.length > 0) {
      for (const e of errors) console.error(`flag-registry-lint: ${e}`);
      process.exit(1);
    }
    console.log('flag-registry-lint: ok');
  }
}
