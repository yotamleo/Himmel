#!/usr/bin/env node
// scripts/lib/gen-secrets-doc.mjs — HIMMEL-2176 Task 5 (externalization Stage
// 1, PR-B, design A14/A15).
//
// .env.example's generated secrets block (bounded by the BEGIN/END markers
// below) is rendered straight from scripts/himmelctl/lib/secrets-manifest.json
// — the SAME manifest the wizard's secrets step reads. One source, two
// consumers: editing the manifest and re-running `write` is the only
// supported way to change either. Modeled on scripts/lib/gen-commands-
// catalog.mjs's three-verb shape (HIMMEL-2064) — see that file for the
// CI/pre-commit staged-vs-working-tree rationale this one reuses verbatim.
//
// Usage:
//   node scripts/lib/gen-secrets-doc.mjs check   # CI: exit 1 on drift
//   node scripts/lib/gen-secrets-doc.mjs write   # regenerate in place
//   node scripts/lib/gen-secrets-doc.mjs check --staged  # pre-commit: STAGED blobs
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const BEGIN_MARKER = '# === GENERATED: secrets manifest (scripts/lib/gen-secrets-doc.mjs -- DO NOT HAND-EDIT; source: scripts/himmelctl/lib/secrets-manifest.json) -- BEGIN ===';
export const END_MARKER = '# === GENERATED: secrets manifest -- END ===';

const REQUIRED_FIELDS = ['name', 'storage', 'obtain', 'probe', 'required', 'feature'];

// HIMMEL-2305: the closed set of feature areas a secret can be scoped by --
// mirrors scripts/himmelctl/lib/adopter-profile.js's own FEATURE_IDS
// constant (kept as a literal copy, not a cross-import: that module is CJS,
// this one is ESM, and the set is small and closed enough that duplicating
// it is simpler than bridging module systems for one array). Also drives
// this file's own per-feature section grouping/labels below.
export const FEATURE_IDS = ['core', 'vault', 'cadence', 'bridge', 'whisper', 'lane:codex', 'lane:hermes'];

// Manifest shape validation (design §7 V8 test 1's non-probe half — every
// entry has all mandated fields, and names are unique). The probe-id-
// resolves half needs probes.js's PROBES map and lives in the test file
// instead, so `check`/`write` never need to load probes.js just to render
// docs.
export function validateManifestShape(secrets) {
  const problems = [];
  const seen = new Set();
  for (const s of secrets) {
    const label = (s && s.name) || '(unnamed)';
    for (const field of REQUIRED_FIELDS) {
      if (!s || typeof s[field] !== 'string' || s[field].trim() === '') {
        problems.push(`secret ${label}: missing/empty field "${field}"`);
      }
    }
    if (s && s.name) {
      if (seen.has(s.name)) problems.push(`duplicate secret name: ${s.name}`);
      seen.add(s.name);
    }
    if (s && s.required && s.required !== 'required' && s.required !== 'optional') {
      problems.push(`secret ${label}: "required" must be "required" or "optional", got "${s.required}"`);
    }
    if (s && s.feature && FEATURE_IDS.indexOf(s.feature) === -1) {
      problems.push(`secret ${label}: "feature" must be one of ${FEATURE_IDS.join('|')}, got "${s.feature}"`);
    }
  }
  return problems;
}

// HIMMEL-2305: the TRACKED .env.example block stays selection-independent
// (every adopter sees the full union of keys — see the module header on why
// scoping applies only to the per-machine wizard walk / status nags, never
// here) but is reorganized into these labeled per-feature sections, in this
// fixed order, so an adopter can tell at a glance which block applies to
// them without reading every entry's prose.
const FEATURE_SECTION_LABELS = {
  core: 'core -- always applies, every profile',
  vault: 'luna vault sources (asked when vault!=none; skip if you answered vault=none)',
  cadence: 'luna cadences (asked when vault!=none; skip if no cadence is armed)',
  bridge: 'telegram bridge (asked when vault!=none; skip if you declined it)',
  whisper: 'voice transcription / whisper (needs the telegram bridge enabled; skip if you declined it)',
  'lane:codex': 'codex lane (opt-in; skip unless you selected codex)',
  'lane:hermes': 'hermes lane (opt-in; skip unless you selected hermes)',
};

// Deterministic render: grouped by feature (in FEATURE_IDS order), then
// alphabetical by name within a group, so re-running `write` on an
// unchanged manifest is a byte-for-byte no-op. A secret whose `feature`
// doesn't resolve to a known section (shouldn't happen once
// validateManifestShape has run, but render stays defensive/pure) still
// renders, under a catch-all trailing section, rather than silently vanishing.
export function renderSecretsBlock(secrets) {
  const lines = [BEGIN_MARKER];
  const byName = (a, b) => a.name.localeCompare(b.name);
  const emitGroup = (label, group) => {
    if (group.length === 0) return;
    lines.push(`# -- ${label} --`);
    for (const s of [...group].sort(byName)) {
      lines.push(`# ${s.name} (${s.required}) -- probe: ${s.probe}`);
      lines.push(`#   storage: ${s.storage}`);
      lines.push(`#   obtain:  ${s.obtain}`);
    }
  };
  for (const feature of FEATURE_IDS) {
    emitGroup(FEATURE_SECTION_LABELS[feature] || feature, secrets.filter((s) => s.feature === feature));
  }
  emitGroup('other', secrets.filter((s) => FEATURE_IDS.indexOf(s.feature) === -1));
  lines.push(END_MARKER);
  return lines.join('\n');
}

// Pure core: locate the BEGIN/END region in envExampleText and either report
// drift (`check`) or return the regenerated text (`write`). No filesystem I/O.
// Missing/misordered markers is a hard error, not a violation — that means
// the generated region itself was hand-edited away, and `write` cannot know
// where to put the block back.
export function regenerateEnvExample(envExampleText, secrets, mode) {
  const lines = envExampleText.split(/\r?\n/);
  const beginIdx = lines.indexOf(BEGIN_MARKER);
  const endIdx = lines.indexOf(END_MARKER);
  if (beginIdx === -1 || endIdx === -1 || endIdx < beginIdx) {
    throw new Error('gen-secrets-doc: BEGIN/END markers not found in .env.example (or END before BEGIN) -- the generated region was removed or hand-edited; restore the marker pair before running write');
  }
  const wantBlock = renderSecretsBlock(secrets).split('\n');
  const haveBlock = lines.slice(beginIdx, endIdx + 1);
  const changed = haveBlock.join('\n') !== wantBlock.join('\n');
  if (mode === 'check') {
    return { violations: changed ? [{ have: haveBlock.join('\n'), want: wantBlock.join('\n') }] : [], changed };
  }
  const out = [...lines.slice(0, beginIdx), ...wantBlock, ...lines.slice(endIdx + 1)];
  return { text: out.join('\n'), changed, violations: [] };
}

// Manifest malformation gate (HIMMEL-2176 CR round 3, retask
// stage1-build-6d2e): a missing or null `secrets` key used to be silently
// coerced to [] at the call site, so a malformed manifest produced an EMPTY
// generated block instead of failing -- the drift gate this generator exists
// to run happily accepted it. Same fail-open-silently class this repo lints
// for (HIMMEL-1776) and rules against (HIMMEL-1128): the generator's entire
// purpose is that documentation cannot silently drift, so it must not trust
// the one input (the manifest) it exists to validate. `check`, `write`, and
// `check --staged` all route through this one function (main(), below), so
// all three now fail loudly -- naming the file and the problem -- instead of
// emitting or accepting an empty secrets block.
export function loadManifestSecrets(manifestText, manifestLabel) {
  const parsed = JSON.parse(manifestText);
  const secrets = parsed && parsed.secrets;
  if (!Array.isArray(secrets) || secrets.length === 0) {
    throw new Error(`gen-secrets-doc: ${manifestLabel} has a missing, null, non-array, or empty "secrets" key -- refusing to generate or accept an empty secrets block`);
  }
  return secrets;
}

// Read-only extraction of scripts/himmelctl/lib/probes.js's `PROBES = { ... }`
// dispatch-map keys, by TEXT (never `require`d — probes.js is sibling-owned
// in this ticket and this generator must never execute a single probe just
// to render docs, several of which shell out or hit the network). Exported
// so the test suite can assert every manifest probe id actually resolves.
export function loadProbeIds(probesJsText) {
  const body = probesJsText.match(/const PROBES = \{([\s\S]*?)\n\};/);
  if (!body) throw new Error('gen-secrets-doc: could not locate the PROBES dispatch map in probes.js');
  const ids = new Set();
  const re = /^\s*(?:'([^']+)'|([A-Za-z_$][\w$]*))\s*:/gm;
  let m;
  while ((m = re.exec(body[1])) !== null) {
    ids.add(m[1] || m[2]);
  }
  return ids;
}

// `overrides` (root/manifestPath/envExamplePath) exists only so the test
// suite can drive `check`/`write`/`check --staged` end-to-end against a
// throwaway fixture instead of the real repo's own manifest -- the CLI
// invocation below never passes it, so real usage is unaffected.
export function main(mode, staged, overrides = {}) {
  const root = overrides.root || resolve(join(fileURLToPath(import.meta.url), '..', '..', '..'));
  const manifestPath = overrides.manifestPath || join(root, 'scripts/himmelctl/lib/secrets-manifest.json');
  const envExamplePath = overrides.envExamplePath || join(root, '.env.example');

  const manifestText = staged
    ? execFileSync('git', ['show', ':scripts/himmelctl/lib/secrets-manifest.json'], { cwd: root, encoding: 'utf8' })
    : readFileSync(manifestPath, 'utf8');
  const envExampleText = staged
    ? execFileSync('git', ['show', ':.env.example'], { cwd: root, encoding: 'utf8' })
    : readFileSync(envExamplePath, 'utf8');

  const manifestLabel = staged ? `${manifestPath} (staged)` : manifestPath;
  let secrets;
  try {
    secrets = loadManifestSecrets(manifestText, manifestLabel);
  } catch (e) {
    console.error(e.message);
    return 1;
  }
  const shapeProblems = validateManifestShape(secrets);
  if (shapeProblems.length > 0) {
    for (const p of shapeProblems) console.error(`gen-secrets-doc: ${p}`);
    return 1;
  }

  const { violations, changed, text } = regenerateEnvExample(envExampleText, secrets, mode);

  if (mode === 'check') {
    if (violations.length === 0) return 0;
    console.error('gen-secrets-doc: .env.example\'s generated secrets block is stale relative to scripts/himmelctl/lib/secrets-manifest.json.');
    console.error('Run: node scripts/lib/gen-secrets-doc.mjs write');
    return 1;
  }
  if (changed) writeFileSync(envExamplePath, text);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const staged = args.includes('--staged');
  const mode = args.find((a) => a === 'check' || a === 'write');
  if (!mode) {
    console.error('usage: node scripts/lib/gen-secrets-doc.mjs <check|write> [--staged]');
    process.exitCode = 2;
  } else if (staged && mode !== 'check') {
    console.error('gen-secrets-doc: --staged is only valid with check (write always regenerates the working tree)');
    process.exitCode = 2;
  } else {
    process.exitCode = main(mode, staged);
  }
}
