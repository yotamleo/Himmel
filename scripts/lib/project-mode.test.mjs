// Tests for scripts/lib/project-mode.mjs (HIMMEL-4758). Walks the same two
// tables as test-project-mode.sh, so the JS and shell resolvers cannot drift:
// fixtures/project-modes.tsv and fixtures/forge-origins.tsv.
// Run: node --test scripts/lib/project-mode.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  projectModeTracker, projectModeForge, projectModeIdPattern,
  projectModeIdRequired, projectModePhases, projectModeEnv,
} from './project-mode.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const T = mkdtempSync(join(tmpdir(), 'project-mode-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));

const BASE_ENV = {
  PATH: process.env.PATH, HOME: T, GIT_CONFIG_NOSYSTEM: '1',
  GIT_CONFIG_GLOBAL: '/dev/null', GIT_CEILING_DIRECTORIES: T,
};

function makeDir(origin, cfg) {
  const d = mkdtempSync(join(T, 'row.'));
  if (origin === 'NOGIT') return d;
  const g = (...a) => execFileSync('git', ['-C', d, ...a], { env: BASE_ENV, stdio: 'ignore' });
  g('init', '-q');
  if (origin !== '-') g('remote', 'add', 'origin', origin);
  if (cfg !== '-') {
    for (const kv of cfg.split(' ')) {
      const i = kv.indexOf('=');
      g('config', kv.slice(0, i), kv.slice(i + 1));
    }
  }
  return d;
}

function rowEnv(envs) {
  const env = { ...BASE_ENV };
  if (envs !== '-') {
    for (const kv of envs.split(' ')) {
      const i = kv.indexOf('=');
      env[kv.slice(0, i)] = kv.slice(i + 1);
    }
  }
  return env;
}

const FNS = {
  tracker: (o) => projectModeTracker(o),
  forge: (o) => projectModeForge(o),
  'forge-guard': (o) => projectModeForge({ ...o, forGuard: true }),
  pattern: (o) => projectModeIdPattern(o),
  required: (o) => projectModeIdRequired(o),
  phases: (o) => projectModePhases(o),
  env: (o) => projectModeEnv(o),
};

// The resolver's answer in the fixture's encoding (EXIT2, <empty>, \t).
function resolve(fn, o) {
  let out;
  try {
    out = FNS[fn]({ ...o, quiet: true });
  } catch (err) {
    if (err.code === 2) return 'EXIT2';
    throw err;
  }
  return out === '' ? '<empty>' : out.replaceAll('\t', '\\t');
}

function rows(file) {
  return readFileSync(join(HERE, 'fixtures', file), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#')).map((l) => l.split('\t'));
}

test('every row of fixtures/project-modes.tsv', () => {
  const table = rows('project-modes.tsv');
  assert.ok(table.length >= 50, `only ${table.length} rows`);
  for (const [fn, origin, envs, cfg, want] of table) {
    const cwd = makeDir(origin, cfg);
    assert.equal(resolve(fn, { cwd, env: rowEnv(envs) }), want, `${fn} origin=${origin} env=${envs} cfg=${cfg}`);
  }
});

test('every origin of fixtures/forge-origins.tsv (none -> local-git inside a work tree)', () => {
  const table = rows('forge-origins.tsv');
  assert.ok(table.length >= 30, `only ${table.length} origins`);
  for (const [want, url] of table) {
    const expected = want === 'none' ? 'local-git' : want;
    const cwd = makeDir(url, '-');
    assert.equal(resolve('forge', { cwd, env: rowEnv('-') }), expected, `forge ${url}`);
    assert.equal(resolve('forge-guard', { cwd, env: rowEnv('-') }), expected, `forge-guard ${url}`);
  }
});

test('CLI: prints the answer, and exits 2 with the I8 message on a refusal', () => {
  const cli = join(HERE, 'project-mode.mjs');
  const cwd = makeDir('https://github.com/o/r', '-');
  const ok = spawnSync(process.execPath, [cli, 'env'], { cwd, env: rowEnv('JIRA_PROJECT_KEY=HIMMEL'), encoding: 'utf8' });
  assert.equal(ok.status, 0);
  assert.equal(ok.stdout, 'TRACKER=jira\tFORGE=github\tTICKET_ID_REQUIRED=1\tTICKET_ID_PATTERN=HIMMEL-[0-9]+\n');
  const bad = spawnSync(process.execPath, [cli, 'forge'], { cwd, env: rowEnv('FORGE=local-git'), encoding: 'utf8' });
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /local-git.*github\.com/);
});

test('a multi-line TICKET_ID_PATTERN is refused, never cut to its first line', () => {
  const cwd = makeDir('-', '-');
  assert.throws(() => projectModeIdPattern({ cwd, env: { ...BASE_ENV, TICKET_ID_PATTERN: 'A-[0-9]+\nB-[0-9]+' } }), /multi-line/);
});

test('a TICKET_ID_REQUIRED carrying a newline or TAB is refused', () => {
  const cwd = makeDir('-', '-');
  for (const v of ['1\nx', '1\tx']) {
    assert.throws(() => projectModeIdRequired({ cwd, env: { ...BASE_ENV, TICKET_ID_REQUIRED: v } }), /TICKET_ID_REQUIRED/);
  }
});
