#!/usr/bin/env node
// bundle-registry-lint.mjs — HIMMEL-4379: every config-feed row id must match
// exactly one entry of the bundle table scripts/himmelctl/lib/feed-bundles.json,
// and every entry must match at least one id. The config UI groups rows by that
// table, so an unmapped id would silently land in Unsorted.
//
// Row ids are enumerated from the registries the feed reads, from --root:
// manifest.json items, `emit <SEV> <Cnn-id>` literals of himmel-doctor.sh,
// lanes.json, bypass-flags.json, secrets-manifest.json, settings-template.json
// onDemandPlugins. The code constants (CADENCES, INITIATIVE_LEGS, DOCTOR_OWNER)
// come from this tree's config-feed.js, so a fixture root needs only JSON and a
// stub doctor.
//
// usage: bundle-registry-lint.mjs [--root <repo>]   lint, exit 1 on a finding
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { CADENCES, INITIATIVE_LEGS, DOCTOR_OWNER } = require(path.join(here, '..', 'himmelctl', 'lib', 'config-feed.js'));
const { matches, UNSORTED } = require(path.join(here, '..', 'himmelctl', 'lib', 'feed-bundles.js'));

const TABLE_REL = 'scripts/himmelctl/lib/feed-bundles.json';
// `emit` after line start, whitespace, ';' or ')' (many emits sit in case arms)
const EMIT_RE = /(?:^|[\s;)])emit\s+"?\$?\w+"?\s+(C\d+-[a-z0-9-]+)/gm;

function readJson(root, rel) {
  return JSON.parse(fs.readFileSync(path.join(root, rel), 'utf8'));
}

// Every row id the feed can emit, per the registries under `root`; `anchors`
// is the smaller of the manifest item count and the doctor emit count (0 =
// nothing to lint).
export function enumerateIds(root) {
  const ids = new Set();
  const items = readJson(root, 'scripts/install/manifest.json').items || [];
  for (const i of items) ids.add(i.id);
  const doctor = fs.readFileSync(path.join(root, 'scripts/himmel-doctor.sh'), 'utf8');
  const emits = [...doctor.matchAll(EMIT_RE)];
  for (const m of emits) ids.add(`doctor:${m[1]}`);
  for (const l of readJson(root, 'scripts/lanes/lanes.json').lanes || []) ids.add(`lane:${l.id}`);
  for (const f of readJson(root, 'scripts/himmelctl/lib/bypass-flags.json').flags || []) ids.add(`flag:${f.name}`);
  for (const s of readJson(root, 'scripts/himmelctl/lib/secrets-manifest.json').secrets || []) ids.add(`secret:${s.name}`);
  for (const k of Object.keys(readJson(root, 'docs/setup/settings-template.json').onDemandPlugins || {})) ids.add(`plugin:${k}`);
  for (const c of CADENCES) ids.add(`${c.name}-cadence`);
  for (const leg of INITIATIVE_LEGS) ids.add(`initiative:${leg}`);
  for (const k of Object.keys(DOCTOR_OWNER)) ids.add(`probe-disagree:${k}`);
  ids.add('doctor:run');
  ids.add('plugin:run');
  return { ids, anchors: Math.min(items.length, emits.length) };
}

export function lint(root) {
  let bundles;
  let found;
  try {
    bundles = readJson(root, TABLE_REL).bundles;
    if (!Array.isArray(bundles)) throw new Error('no bundles array');
  } catch (e) {
    return [`cannot read ${TABLE_REL}: ${e.message}`];
  }
  try {
    found = enumerateIds(root);
  } catch (e) {
    return [`cannot enumerate row ids under ${root}: ${e.message}`];
  }
  const { ids, anchors } = found;
  // An empty manifest or a doctor with no emits would pass vacuously.
  if (anchors === 0) {
    return [`no manifest items or doctor checks found under ${root}: nothing to lint, refusing to pass vacuously`];
  }
  const errors = [];
  const seen = new Set();
  for (const b of bundles) {
    if (seen.has(b.id)) errors.push(`DUPLICATE ${b.id}`);
    seen.add(b.id);
    if (b.id === UNSORTED) errors.push(`RESERVED ${b.id} (the runtime fallback bundle; it may not appear in the table)`);
  }
  const used = new Set();
  for (const id of [...ids].sort()) {
    const hit = []; // one bundle id per matching entry
    for (const b of bundles) {
      for (const e of b.rows || []) {
        if (!matches(e, id)) continue;
        used.add(`${b.id}\n${e}`);
        hit.push(b.id);
      }
    }
    if (hit.length === 0) errors.push(`UNMAPPED ${id}`);
    else if (hit.length > 1) errors.push(`MULTI ${id} ${hit.join(',')}`);
  }
  for (const b of bundles) {
    for (const e of b.rows || []) {
      if (!used.has(`${b.id}\n${e}`)) errors.push(`DEAD ${b.id} ${e}`);
    }
  }
  return errors;
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const argv = process.argv.slice(2);
  const ri = argv.indexOf('--root');
  const root = ri !== -1 ? path.resolve(argv[ri + 1]) : path.resolve(here, '..', '..');
  const errors = lint(root);
  if (errors.length > 0) {
    for (const e of errors) console.error(`bundle-registry-lint: ${e}`);
    process.exit(1);
  }
  console.log('bundle-registry-lint: ok');
}
