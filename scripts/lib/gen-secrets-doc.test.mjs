// scripts/lib/gen-secrets-doc.test.mjs — HIMMEL-2176 Task 5, design §7 V8.
// Three mandatory suites: (1) manifest shape + every probe id resolves in
// probes.js's real PROBES dispatch map, (2) every manifest name appears in
// the generated .env.example block, (3) red-then-green on the CI check
// itself (delete FIRECRAWL_API_KEY's block -> check fails; write -> passes).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  validateManifestShape,
  renderSecretsBlock,
  regenerateEnvExample,
  loadProbeIds,
  loadManifestSecrets,
  main,
  BEGIN_MARKER,
  END_MARKER,
  FEATURE_IDS,
} from './gen-secrets-doc.mjs';

const ROOT = resolve(join(fileURLToPath(import.meta.url), '..', '..', '..'));
const MANIFEST_PATH = join(ROOT, 'scripts/himmelctl/lib/secrets-manifest.json');
const PROBES_JS_PATH = join(ROOT, 'scripts/himmelctl/lib/probes.js');
const ENV_EXAMPLE_PATH = join(ROOT, '.env.example');
const INSTALL_MANIFEST_PATH = join(ROOT, 'scripts/install/manifest.json');

function loadRealSecrets() {
  return JSON.parse(readFileSync(MANIFEST_PATH, 'utf8')).secrets;
}

// CR fix (codex-3, retask stage1-build-6d2e): a manifest entry naming probe
// "luna-sources" only actually gets validated if fetch-health.py's registry
// carries a matching source AND scripts/install/manifest.json's own
// luna-sources item lists that source in ITS `sources` array — the id-only
// check above (loadProbeIds) is blind to that second link. Mapping is
// hand-verified against scripts/luna/fetch-health.py's build_probe_registry()
// (the file that actually implements every source below).
const SECRET_TO_LUNA_SOURCE = {
  BITBUCKET_API_TOKEN: 'bitbucket',
  BITBUCKET_EMAIL: 'bitbucket',
  FIRECRAWL_API_KEY: 'firecrawl',
  FIRECRAWL_BASE_URL: 'firecrawl',
  INSTAGRAM_COOKIE_FILE: 'instagram-media',
  REDDIT_COOKIE_FILE: 'reddit',
  TWITTER_AUTH_TOKEN: 'x-twitter-cli',
  TWITTER_CT0: 'x-twitter-cli',
  TWITTER_COOKIE_FILE: 'x-media',
  YOUTUBE_STORAGE_STATE: 'youtube-playwright',
};

// mktemp-style templated temp dir per CLAUDE.md's own known-findings rule:
// a bare mktemp/mkdtemp failure must never leave cleanup pointed at the
// filesystem root. mkdtempSync throws on failure (never returns ''), so the
// finally-block rmSync target is always a real, freshly created subdir.
function makeTempDir(prefix) {
  return mkdtempSync(join(tmpdir(), `${prefix}.`));
}

// ── 1. Manifest validation ──────────────────────────────────────────────

test('real secrets-manifest.json: every entry has all mandated fields, unique names', () => {
  const secrets = loadRealSecrets();
  assert.ok(secrets.length > 0, 'manifest has at least one secret');
  const problems = validateManifestShape(secrets);
  assert.deepEqual(problems, []);
  const names = secrets.map((s) => s.name);
  assert.equal(new Set(names).size, names.length, 'no duplicate names');
});

test('validateManifestShape: flags a missing field loudly (not silently)', () => {
  const problems = validateManifestShape([{ name: 'X', storage: 's', obtain: 'o', probe: 'p', feature: 'core' /* required missing */ }]);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /X.*required/);
});

test('validateManifestShape: flags an invalid required|optional value', () => {
  const problems = validateManifestShape([{ name: 'X', storage: 's', obtain: 'o', probe: 'p', required: 'sometimes', feature: 'core' }]);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /required.*optional/);
});

test('validateManifestShape: flags a duplicate name', () => {
  const base = { name: 'X', storage: 's', obtain: 'o', probe: 'p', required: 'optional', feature: 'core' };
  const problems = validateManifestShape([base, { ...base }]);
  assert.deepEqual(problems, ['duplicate secret name: X']);
});

// ── 1c. HIMMEL-2305: the `feature` field — closed enum, required ──────────

test('validateManifestShape: flags a missing "feature" field loudly (not silently)', () => {
  const problems = validateManifestShape([{ name: 'X', storage: 's', obtain: 'o', probe: 'p', required: 'optional' /* feature missing */ }]);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /X.*feature/);
});

test('validateManifestShape: flags an unknown "feature" value (closed enum)', () => {
  const problems = validateManifestShape([{ name: 'X', storage: 's', obtain: 'o', probe: 'p', required: 'optional', feature: 'not-a-real-feature' }]);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /feature.*core\|vault\|cadence\|bridge\|whisper\|lane:codex\|lane:hermes/);
});

test('validateManifestShape: accepts every FEATURE_IDS value', () => {
  for (const feature of FEATURE_IDS) {
    const problems = validateManifestShape([{ name: 'X', storage: 's', obtain: 'o', probe: 'p', required: 'optional', feature }]);
    assert.deepEqual(problems, [], `feature "${feature}" should be accepted`);
  }
});

test('real secrets-manifest.json: every entry\'s feature is one of FEATURE_IDS', () => {
  const secrets = loadRealSecrets();
  for (const s of secrets) {
    assert.ok(FEATURE_IDS.includes(s.feature), `secret ${s.name}: feature "${s.feature}" is not one of ${FEATURE_IDS.join('|')}`);
  }
});

test('loadProbeIds: extracts the real PROBES dispatch map keys from probes.js, including the bare-identifier "dep" key', () => {
  const probesJsText = readFileSync(PROBES_JS_PATH, 'utf8');
  const ids = loadProbeIds(probesJsText);
  // Spot-check a quoted key and the one bare-identifier key (`dep: probeDep,`)
  // to prove the extraction regex handles BOTH shapes probes.js actually uses.
  assert.ok(ids.has('file-exists'));
  assert.ok(ids.has('dep'));
  assert.ok(ids.has('cmd:telegram_getme'));
  assert.ok(ids.has('luna-sources'));
});

test('every real manifest probe id resolves in probes.js\'s PROBES dispatch map', () => {
  const secrets = loadRealSecrets();
  const probeIds = loadProbeIds(readFileSync(PROBES_JS_PATH, 'utf8'));
  for (const s of secrets) {
    assert.ok(probeIds.has(s.probe), `secret ${s.name}: probe id "${s.probe}" does not resolve in probes.js's PROBES map`);
  }
});

test('an unknown probe id fails LOUDLY, not silently (the whole point of carrying the id)', () => {
  const secrets = [{ name: 'X', storage: 's', obtain: 'o', probe: 'cmd:does_not_exist', required: 'optional' }];
  const probeIds = loadProbeIds(readFileSync(PROBES_JS_PATH, 'utf8'));
  const bad = secrets.filter((s) => !probeIds.has(s.probe));
  assert.equal(bad.length, 1);
  assert.equal(bad[0].probe, 'cmd:does_not_exist');
});

// CR fix (codex-3, retask stage1-build-6d2e): the "probe id resolves in
// PROBES" check above is satisfied by every luna-sources secret regardless
// of whether that secret's own fetch-health.py source is actually in the
// luna-sources item's `sources` list -- BITBUCKET_EMAIL/BITBUCKET_API_TOKEN
// and TWITTER_AUTH_TOKEN/TWITTER_CT0 named probe "luna-sources" while their
// sources (bitbucket, x-twitter-cli) were absent from that list, so the
// manifest promised validation that never ran. Assert the second link too.
test('every luna-sources secret\'s fetch-health.py source is actually in install-manifest.json\'s luna-sources.sources list', () => {
  const secrets = loadRealSecrets();
  const installManifest = JSON.parse(readFileSync(INSTALL_MANIFEST_PATH, 'utf8'));
  const lunaSourcesItem = installManifest.items.find((i) => i.id === 'luna-sources');
  assert.ok(lunaSourcesItem, 'scripts/install/manifest.json must carry a luna-sources item');
  const sources = new Set(lunaSourcesItem.probe.sources || []);
  for (const s of secrets) {
    if (s.probe !== 'luna-sources') continue;
    const expectedSource = SECRET_TO_LUNA_SOURCE[s.name];
    assert.ok(expectedSource, `secret ${s.name} names probe "luna-sources" but has no entry in this test's SECRET_TO_LUNA_SOURCE map -- add one (see scripts/luna/fetch-health.py's build_probe_registry)`);
    assert.ok(sources.has(expectedSource), `secret ${s.name} names probe "luna-sources" but its source "${expectedSource}" is missing from scripts/install/manifest.json's luna-sources.sources -- the probe never actually validates this secret`);
  }
});

// ── 1b. Manifest malformation gate (CR round 3, retask stage1-build-6d2e) ──
// A missing/null/non-array/empty `secrets` key used to be silently coerced
// to [] -- the drift gate happily accepted a malformed manifest and
// generated an EMPTY secrets block, defeating the generator's entire
// purpose. RED before the fix: every case below returned `[]` instead of
// throwing, and `check`/`write`/`check --staged` all exited 0 having
// emitted/accepted an empty block.

test('loadManifestSecrets: throws, naming the file, when "secrets" is missing entirely', () => {
  assert.throws(
    () => loadManifestSecrets(JSON.stringify({}), '/fake/manifest.json'),
    /\/fake\/manifest\.json.*missing, null, non-array, or empty/,
  );
});

test('loadManifestSecrets: throws when "secrets" is null', () => {
  assert.throws(
    () => loadManifestSecrets(JSON.stringify({ secrets: null }), '/fake/manifest.json'),
    /missing, null, non-array, or empty/,
  );
});

test('loadManifestSecrets: throws when "secrets" is not an array', () => {
  assert.throws(
    () => loadManifestSecrets(JSON.stringify({ secrets: 'nope' }), '/fake/manifest.json'),
    /missing, null, non-array, or empty/,
  );
});

test('loadManifestSecrets: throws when "secrets" is an empty array', () => {
  assert.throws(
    () => loadManifestSecrets(JSON.stringify({ secrets: [] }), '/fake/manifest.json'),
    /missing, null, non-array, or empty/,
  );
});

test('loadManifestSecrets: a well-formed non-empty array passes through unchanged', () => {
  const secrets = [{ name: 'X', storage: 's', obtain: 'o', probe: 'p', required: 'optional' }];
  assert.deepEqual(loadManifestSecrets(JSON.stringify({ secrets }), '/fake/manifest.json'), secrets);
});

// `check`, `write`, and `check --staged` all route through loadManifestSecrets
// via main() -- prove each verb actually fails loudly end-to-end on a
// malformed manifest, not just that the shared helper throws in isolation.
function withCapturedError(fn) {
  const errors = [];
  const orig = console.error;
  console.error = (msg) => errors.push(msg);
  try {
    return { rc: fn(), errors };
  } finally {
    console.error = orig;
  }
}

test('main(): "check" fails loudly on a malformed manifest (missing secrets key), never emits an empty block', () => {
  const dir = makeTempDir('gen-secrets-doc-malformed-check');
  try {
    const manifestPath = join(dir, 'manifest.json');
    const envExamplePath = join(dir, '.env.example');
    writeFileSync(manifestPath, JSON.stringify({ notSecrets: [] }));
    writeFileSync(envExamplePath, `${BEGIN_MARKER}\n${END_MARKER}\n`);
    const { rc, errors } = withCapturedError(() => main('check', false, { manifestPath, envExamplePath }));
    assert.equal(rc, 1);
    assert.ok(errors.some((m) => m.includes('missing, null, non-array, or empty')), `expected a loud malformed-manifest error, got: ${JSON.stringify(errors)}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('main(): "write" fails loudly on a malformed manifest (null secrets), never writes an empty block to disk', () => {
  const dir = makeTempDir('gen-secrets-doc-malformed-write');
  try {
    const manifestPath = join(dir, 'manifest.json');
    const envExamplePath = join(dir, '.env.example');
    const before = `${BEGIN_MARKER}\n# untouched\n${END_MARKER}\n`;
    writeFileSync(manifestPath, JSON.stringify({ secrets: null }));
    writeFileSync(envExamplePath, before);
    const { rc, errors } = withCapturedError(() => main('write', false, { manifestPath, envExamplePath }));
    assert.equal(rc, 1);
    assert.ok(errors.some((m) => m.includes('missing, null, non-array, or empty')), `expected a loud malformed-manifest error, got: ${JSON.stringify(errors)}`);
    assert.equal(readFileSync(envExamplePath, 'utf8'), before, '.env.example must be left untouched -- write must never emit an empty block');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('main(): "check --staged" fails loudly on a malformed STAGED manifest (empty secrets array)', () => {
  const dir = makeTempDir('gen-secrets-doc-malformed-staged');
  try {
    execFileSync('git', ['init', '-q'], { cwd: dir });
    execFileSync('git', ['config', 'user.email', 'test@test'], { cwd: dir });
    execFileSync('git', ['config', 'user.name', 'test'], { cwd: dir });
    mkdirSync(join(dir, 'scripts/himmelctl/lib'), { recursive: true });
    writeFileSync(join(dir, 'scripts/himmelctl/lib/secrets-manifest.json'), JSON.stringify({ secrets: [] }));
    writeFileSync(join(dir, '.env.example'), `${BEGIN_MARKER}\n${END_MARKER}\n`);
    execFileSync('git', ['add', '.'], { cwd: dir });

    const { rc, errors } = withCapturedError(() => main('check', true, { root: dir }));
    assert.equal(rc, 1);
    assert.ok(errors.some((m) => m.includes('missing, null, non-array, or empty')), `expected a loud malformed-manifest error, got: ${JSON.stringify(errors)}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── 2. Completeness: every manifest name appears in the generated block ──

test('every manifest-entry name appears in the generated .env.example block', () => {
  const secrets = loadRealSecrets();
  const block = renderSecretsBlock(secrets);
  for (const s of secrets) {
    assert.ok(block.includes(s.name), `"${s.name}" missing from the generated block`);
  }
});

// HIMMEL-2305: the tracked block stays selection-independent (full union,
// every adopter sees every key) but is reorganized into labeled per-feature
// sections — a scoping-out only ever applies to the per-machine wizard walk/
// status nags, never here (see gen-secrets-doc.mjs's own header).
test('renderSecretsBlock: groups entries into labeled per-feature sections, in FEATURE_IDS order', () => {
  const secrets = [
    { name: 'BBB_BRIDGE', storage: 's', obtain: 'o', probe: 'p', required: 'optional', feature: 'bridge' },
    { name: 'AAA_VAULT', storage: 's', obtain: 'o', probe: 'p', required: 'optional', feature: 'vault' },
    { name: 'ZZZ_VAULT', storage: 's', obtain: 'o', probe: 'p', required: 'optional', feature: 'vault' },
  ];
  const block = renderSecretsBlock(secrets);
  const vaultIdx = block.indexOf('AAA_VAULT');
  const zzzVaultIdx = block.indexOf('ZZZ_VAULT');
  const bridgeIdx = block.indexOf('BBB_BRIDGE');
  assert.ok(vaultIdx !== -1 && zzzVaultIdx !== -1 && bridgeIdx !== -1, 'every secret should appear in the block');
  // vault comes before bridge in FEATURE_IDS order, regardless of input order.
  assert.ok(vaultIdx < bridgeIdx, 'the vault section should render before the bridge section (FEATURE_IDS order)');
  // within a section, alphabetical by name (AAA before ZZZ).
  assert.ok(vaultIdx < zzzVaultIdx, 'within one feature section, entries should sort alphabetically by name');
  assert.match(block, /# -- luna vault sources/);
  assert.match(block, /# -- telegram bridge/);
});

test('renderSecretsBlock: a secret with no recognized feature still renders, under a catch-all trailing section (never silently dropped)', () => {
  const secrets = [{ name: 'ORPHAN', storage: 's', obtain: 'o', probe: 'p', required: 'optional', feature: 'not-a-real-feature' }];
  const block = renderSecretsBlock(secrets);
  assert.ok(block.includes('ORPHAN'), 'an unrecognized-feature secret must still appear in the block');
  assert.match(block, /# -- other --/);
});

test('the COMMITTED .env.example actually contains the current generated block (not just renderable in isolation)', () => {
  const envExampleText = readFileSync(ENV_EXAMPLE_PATH, 'utf8');
  const secrets = loadRealSecrets();
  const { violations } = regenerateEnvExample(envExampleText, secrets, 'check');
  assert.deepEqual(violations, [], 'run `node scripts/lib/gen-secrets-doc.mjs write` to regenerate');
  for (const s of secrets) {
    assert.ok(envExampleText.includes(s.name), `"${s.name}" missing from .env.example`);
  }
});

// ── 3. Red-then-green on the CI check itself ──────────────────────────────

test('check: RED when a secret\'s block is missing from .env.example, GREEN once regenerated (FIRECRAWL_API_KEY)', () => {
  const secrets = loadRealSecrets();
  const goodText = renderSecretsBlock(secrets);
  const goodBlock = goodText.split('\n');

  // Build a minimal .env.example fixture: the two markers, wrapping the full
  // GOOD block, then delete just FIRECRAWL_API_KEY's 3 lines from it -- the
  // exact "gap this closes" scenario named in the brief.
  const fixtureGood = [
    '# unrelated preamble',
    ...goodBlock,
    '# unrelated tail',
  ].join('\n');

  const firecrawlStart = goodBlock.findIndex((l) => l.startsWith('# FIRECRAWL_API_KEY '));
  assert.ok(firecrawlStart !== -1, 'fixture setup: FIRECRAWL_API_KEY must be in the real manifest');
  const brokenBlock = [...goodBlock.slice(0, firecrawlStart), ...goodBlock.slice(firecrawlStart + 3)];
  const fixtureBroken = [
    '# unrelated preamble',
    ...brokenBlock,
    '# unrelated tail',
  ].join('\n');

  // RED: FIRECRAWL_API_KEY's own entry heading is gone -> check must fail and
  // say so. (Other entries' `obtain`/`storage` prose legitimately MENTIONS
  // "FIRECRAWL_API_KEY" as a cross-reference -- e.g. FIRECRAWL_BASE_URL's own
  // text -- so the assertion targets the specific entry HEADING line, not a
  // bare substring match that those cross-references would false-negative.)
  const redResult = regenerateEnvExample(fixtureBroken, secrets, 'check');
  assert.equal(redResult.violations.length, 1);
  assert.ok(!redResult.violations[0].have.includes('# FIRECRAWL_API_KEY ('));
  assert.ok(redResult.violations[0].want.includes('# FIRECRAWL_API_KEY ('));

  // GREEN: regenerate (write) from the broken fixture -> FIRECRAWL_API_KEY is
  // back, and a subsequent check is clean.
  const writeResult = regenerateEnvExample(fixtureBroken, secrets, 'write');
  assert.ok(writeResult.text.includes('FIRECRAWL_API_KEY'));
  const greenResult = regenerateEnvExample(writeResult.text, secrets, 'check');
  assert.deepEqual(greenResult.violations, []);
  assert.equal(writeResult.text, fixtureGood);
});

test('check --staged path: reads the STAGED .env.example blob via a real git repo, ignoring an unstaged edit', () => {
  const dir = makeTempDir('gen-secrets-doc-staged');
  try {
    execFileSync('git', ['init', '-q'], { cwd: dir });
    execFileSync('git', ['config', 'user.email', 'test@test'], { cwd: dir });
    execFileSync('git', ['config', 'user.name', 'test'], { cwd: dir });

    const secrets = [{ name: 'FOO', storage: 's', obtain: 'o', probe: 'dep', required: 'optional' }];
    const goodText = renderSecretsBlock(secrets);
    writeFileSync(join(dir, '.env.example'), goodText);
    execFileSync('git', ['add', '.env.example'], { cwd: dir });
    // Dirty the working tree AFTER staging with a BROKEN block -- --staged
    // must see the STAGED (good) blob, not this unstaged corruption.
    writeFileSync(join(dir, '.env.example'), `${END_MARKER}\n`);

    const staged = execFileSync('git', ['show', ':.env.example'], { cwd: dir, encoding: 'utf8' });
    assert.equal(staged, goodText);
    const { violations } = regenerateEnvExample(staged, secrets, 'check');
    assert.deepEqual(violations, []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('regenerateEnvExample throws when the marker pair is missing (hand-edited away), rather than silently no-oping', () => {
  assert.throws(() => regenerateEnvExample('no markers here', [], 'check'), /BEGIN\/END markers not found/);
});
