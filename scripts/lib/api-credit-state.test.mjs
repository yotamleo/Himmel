// HIMMEL-4904: secret-free accounting fixtures. No provider calls or credentials.
// Breaks caught: fallback to another account/bank, duplicate spend, automatic
// rollover, stale evidence admission, rounding and concurrent over-reservation.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SUT = join(HERE, 'api-credit-state.mjs');
const BANK = join(HERE, 'bank-preflight.sh');
const T = mkdtempSync(join(tmpdir(), 'api-credit-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));

function fixture() {
  const dir = mkdtempSync(join(T, 'case-'));
  const now = Math.floor(Date.now() / 1000);
  const config = { version: 1, accounts: {
    A: { organization_id: 'org-a', cycle_id: 'cycle-a', cap_usd: '1.00' },
    B: { organization_id: 'org-b', cycle_id: 'cycle-b', cap_usd: '2.00' },
  } };
  const snapshot = { version: 1, accounts: Object.fromEntries(['A', 'B'].map((account) => [account, {
    organization_id: config.accounts[account].organization_id,
    cycle_id: config.accounts[account].cycle_id,
    grant_usd: '2.00', remaining_usd: '2.00', reconciled_spent_usd: '0',
    starts_at: now - 1000, expires_at: now + 3600, observed_at: now,
    source: 'operator-console-snapshot', exclusive_org: true, discrepancy: false,
  }])) };
  const paths = { config: join(dir, 'config.json'), snapshot: join(dir, 'snapshot.json'), state: join(dir, 'ledger.json') };
  const save = () => {
    writeFileSync(paths.config, JSON.stringify(config));
    writeFileSync(paths.snapshot, JSON.stringify(snapshot));
  };
  save();
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir,
    HIMMEL_API_CREDIT_CONFIG: paths.config, HIMMEL_API_CREDIT_SNAPSHOT: paths.snapshot,
    HIMMEL_API_CREDIT_STATE: paths.state, HIMMEL_API_ACCOUNT: 'A' };
  const args = (command, extra = []) => [SUT, command, ...extra];
  const call = (command = 'status', extra = []) => {
    const r = spawnSync(process.execPath, args(command, extra), { env, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    return JSON.parse(r.stdout);
  };
  return { dir, now, config, snapshot, paths, save, env, args, call };
}

// First RED: current bank gate ignores api and falls through to native evidence.
test('API dispatch is OFF even when no native evidence exists', () => {
  const f = fixture();
  writeFileSync(join(f.dir, 'ps'), '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  const r = spawnSync('bash', [BANK], { encoding: 'utf8', env: {
    ...f.env, HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(f.dir, 'slots'),
    FLEET_PS_CMD: join(f.dir, 'ps'), FLEET_PROC: f.dir, CADENCE_BANK_LANE: 'api',
    CADENCE_BANK_LEDGER: join(f.dir, 'bank-ledger'), CADENCE_BANK_LAUNCH: '1',
    CADENCE_BANK_LEG: 'HIMMEL-test-api', CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_CACHE: join(f.dir, 'no-native-cache'),
  } });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'SKIPPED-BANK');
  assert.match(r.stderr, /api.*dispatch.*OFF/);
});

test('funded account reports precise estimated headroom without writing spend', () => {
  const f = fixture();
  const row = f.call();
  assert.equal(row.verdict, 'PROCEED');
  assert.equal(row.account, 'A');
  assert.equal(row.available_est_usd, '1.000000');
  assert.equal(row.grant_usd, '2.000000');
  assert.equal(row.reserved_usd, '0.000000');
  assert.equal(row.spent_est_usd, '0.000000');
  assert.equal(row.source, 'operator-console-snapshot');
});

const invalid = [
  ['missing account snapshot', (f) => delete f.snapshot.accounts.A, 'BANK-UNKNOWN'],
  ['stale observation', (f) => { f.snapshot.accounts.A.observed_at = f.now - 601; }, 'BANK-STALE'],
  ['expired grant', (f) => { f.snapshot.accounts.A.expires_at = f.now - 1; }, 'SKIPPED-BANK'],
  ['future observation', (f) => { f.snapshot.accounts.A.observed_at = f.now + 60; }, 'BANK-STALE'],
  ['future grant', (f) => { f.snapshot.accounts.A.starts_at = f.now + 60; }, 'BANK-UNKNOWN'],
  ['wrong cycle', (f) => { f.snapshot.accounts.A.cycle_id = 'other'; }, 'BANK-UNKNOWN'],
  ['wrong org', (f) => { f.snapshot.accounts.A.organization_id = 'other'; }, 'BANK-UNKNOWN'],
  ['shared org configured twice', (f) => { f.config.accounts.B.organization_id = 'org-a'; }, 'BANK-UNKNOWN'],
  ['uncontrolled outside consumers', (f) => { f.snapshot.accounts.A.exclusive_org = false; }, 'BANK-UNKNOWN'],
  ['snapshot discrepancy', (f) => { f.snapshot.accounts.A.discrepancy = true; }, 'BANK-UNKNOWN'],
  ['unknown provenance', (f) => { f.snapshot.accounts.A.source = 'guess'; }, 'BANK-UNKNOWN'],
  ['exhausted A does not borrow funded B', (f) => { f.snapshot.accounts.A.remaining_usd = '0'; }, 'SKIPPED-BANK'],
  ['cap does not exceed verified grant', (f) => { f.config.accounts.A.cap_usd = '3'; }, 'BANK-UNKNOWN'],
  ['invalid cap', (f) => { f.config.accounts.A.cap_usd = 'unlimited'; }, 'BANK-UNKNOWN'],
  ['numeric money rejected', (f) => { f.config.accounts.A.cap_usd = 1; }, 'BANK-UNKNOWN'],
  ['submicro precision rejected', (f) => { f.config.accounts.A.cap_usd = '0.0000001'; }, 'BANK-UNKNOWN'],
  ['negative balance rejected', (f) => { f.snapshot.accounts.A.remaining_usd = '-1'; }, 'BANK-UNKNOWN'],
  ['remaining greater than grant', (f) => { f.snapshot.accounts.A.remaining_usd = '3'; }, 'BANK-UNKNOWN'],
  ['fractional timestamp rejected', (f) => { f.snapshot.accounts.A.observed_at += 0.5; }, 'BANK-UNKNOWN'],
  ['timestamp string rejected', (f) => { f.snapshot.accounts.A.observed_at = String(f.now); }, 'BANK-UNKNOWN'],
  ['invalid interval rejected', (f) => { f.snapshot.accounts.A.starts_at = f.snapshot.accounts.A.expires_at; }, 'BANK-UNKNOWN'],
  ['unrecognized account refused', (f) => { f.env.HIMMEL_API_ACCOUNT = 'C'; }, 'BANK-UNKNOWN'],
  ['account must be explicit', (f) => { delete f.env.HIMMEL_API_ACCOUNT; }, 'BANK-UNKNOWN'],
];
for (const [name, change, verdict] of invalid) {
  test(name, () => {
    const f = fixture(); change(f); f.save();
    assert.equal(f.call().verdict, verdict);
    assert.equal(f.call('reserve', ['--id', 'job', '--usd', '0.01']).verdict, verdict);
  });
}

for (const name of ['config', 'snapshot']) {
  test(`missing ${name} refuses`, () => {
    const f = fixture(); rmSync(f.paths[name]);
    assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  });
  test(`malformed ${name} refuses`, () => {
    const f = fixture(); writeFileSync(f.paths[name], '{');
    assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  });
}

test('reservations isolated by A/B account and no subscription bank consulted', () => {
  const f = fixture();
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '0.70']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '0.300000');
  f.env.HIMMEL_API_ACCOUNT = 'B';
  assert.equal(f.call().available_est_usd, '2.000000');
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1.50']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '0.500000');
  f.env.HIMMEL_API_ACCOUNT = 'A';
  assert.equal(f.call().available_est_usd, '0.300000');
});

test('duplicate reservation never overwrites or re-admits a job', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.40']);
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '0.10']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().reserved_usd, '0.400000');
});

test('reservation maximum rejects zero, unknown prices and unsafe job IDs', () => {
  const f = fixture();
  for (const amount of ['0', 'unknown', '1e-2', '0.0000001', '-1']) {
    assert.equal(f.call('reserve', ['--id', 'job', '--usd', amount]).verdict, 'BANK-UNKNOWN');
  }
  assert.equal(f.call('reserve', ['--id', '../job', '--usd', '0.01']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().reserved_usd, '0.000000');
});

test('unknown completion retains full reservation across new processes', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '1']);
  assert.equal(f.call('unknown', ['--id', 'job']).verdict, 'PROCEED');
  assert.equal(f.call().reserved_usd, '1.000000');
  assert.equal(f.call('reserve', ['--id', 'next', '--usd', '0.000001']).verdict, 'SKIPPED-BANK');
});

test('settlement requires verified terminal completion and reconciles only unused maximum', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.80']);
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.25']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().reserved_usd, '0.800000');
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.25', '--completion', 'verified']).verdict, 'PROCEED');
  assert.equal(f.call().spent_est_usd, '0.250000');
  assert.equal(f.call().available_est_usd, '0.750000');
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0', '--completion', 'verified']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().spent_est_usd, '0.250000');
});

test('late completion can reconcile after snapshot expiry without admitting new work', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.80']);
  f.snapshot.accounts.A.expires_at = f.now - 1; f.save();
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.25', '--completion', 'verified']).verdict, 'PROCEED');
  assert.equal(f.call().verdict, 'SKIPPED-BANK');
});

test('overspent completion records discrepancy and blocks further admission', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.10']);
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0.11', '--completion', 'verified']).verdict, 'BANK-UNKNOWN');
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  assert.equal(JSON.parse(readFileSync(f.paths.state)).accounts.A.jobs.job.actual_usd, '0.110000');
});

test('outside consumption lowers headroom without double-counting reported local spend', () => {
  const f = fixture();
  f.call('reserve', ['--id', 'job', '--usd', '0.50']);
  f.call('settle', ['--id', 'job', '--usd', '0.20', '--completion', 'verified']);
  f.snapshot.accounts.A.remaining_usd = '1.50';
  f.snapshot.accounts.A.reconciled_spent_usd = '0.20'; f.save();
  assert.equal(f.call().spent_est_usd, '0.500000');
  assert.equal(f.call().available_est_usd, '0.500000');
  f.snapshot.accounts.A.reconciled_spent_usd = '0.21'; f.save();
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
});

test('microdollar arithmetic refuses a one-microdollar overrun without cent rounding', () => {
  const f = fixture(); f.config.accounts.A.cap_usd = '0.010001'; f.save();
  f.call('reserve', ['--id', 'one', '--usd', '0.01']);
  assert.equal(f.call('reserve', ['--id', 'two', '--usd', '0.000002']).verdict, 'SKIPPED-BANK');
  assert.equal(f.call('reserve', ['--id', 'three', '--usd', '0.000001']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '0.000000');
});

test('calendar rollover does not refill a cycle or abandon unknown reservations', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  assert.equal(f.call().available_est_usd, '0.000000');
  f.config.accounts.A.cycle_id = 'next-month'; f.snapshot.accounts.A.cycle_id = 'next-month'; f.save();
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
  assert.equal(f.call('reserve', ['--id', 'new', '--usd', '0.01']).verdict, 'BANK-UNKNOWN');
});

test('corrupt existing ledger is not replaced with fresh empty spend', () => {
  const f = fixture(); writeFileSync(f.paths.state, '{');
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1']).verdict, 'BANK-UNKNOWN');
  assert.equal(readFileSync(f.paths.state, 'utf8'), '{');
});

test('symlinked ledger alias cannot use a different lock for the same spend', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '0.50']);
  const alias = join(f.dir, 'alias.json'); symlinkSync(f.paths.state, alias);
  f.env.HIMMEL_API_CREDIT_STATE = alias;
  assert.equal(f.call('reserve', ['--id', 'new', '--usd', '0.50']).verdict, 'BANK-UNKNOWN');
  f.env.HIMMEL_API_CREDIT_STATE = f.paths.state;
  assert.equal(f.call().reserved_usd, '0.500000');
});

test('deleted initialized ledger cannot erase already reserved credit', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  rmSync(f.paths.state);
  assert.equal(f.call('reserve', ['--id', 'new', '--usd', '1']).verdict, 'BANK-UNKNOWN');
});

test('zero-cost verified completion releases unknown reservation without grant refill', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  f.call('unknown', ['--id', 'job']);
  assert.equal(f.call('settle', ['--id', 'job', '--usd', '0', '--completion', 'verified']).verdict, 'PROCEED');
  assert.equal(f.call().available_est_usd, '1.000000');
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1']).verdict, 'BANK-UNKNOWN');
});

test('corrupt job record cannot silently disappear from totals', () => {
  const f = fixture(); f.call('reserve', ['--id', 'job', '--usd', '1']);
  const state = JSON.parse(readFileSync(f.paths.state));
  state.accounts.A.jobs.job.status = 'lost';
  writeFileSync(f.paths.state, JSON.stringify(state));
  assert.equal(f.call().verdict, 'BANK-UNKNOWN');
});

test('orphan or busy transaction lock fails closed without reclamation', () => {
  const f = fixture(); mkdirSync(`${f.paths.state}.lock`);
  assert.equal(f.call('reserve', ['--id', 'job', '--usd', '1']).verdict, 'BANK-UNKNOWN');
});

test('simultaneous last-dollar reservations can admit exactly one at most', async () => {
  const f = fixture();
  const run = (id) => new Promise((resolve, reject) => {
    const p = spawn(process.execPath, f.args('reserve', ['--id', id, '--usd', '1']), { env: f.env });
    let out = ''; p.stdout.on('data', (b) => { out += b; }); p.on('error', reject);
    p.on('close', (code) => { if (code !== 0) reject(new Error(`child ${code}`)); else resolve(JSON.parse(out)); });
  });
  const results = await Promise.all([run('one'), run('two')]);
  assert.equal(results.filter((r) => r.verdict === 'PROCEED').length, 1);
  assert.equal(f.call().reserved_usd, '1.000000');
  assert.equal(f.call().available_est_usd, '0.000000');
});

test('bank read prints API row and does not use native producer', () => {
  const f = fixture();
  writeFileSync(join(f.dir, 'ps'), '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  const r = spawnSync('bash', [BANK], { encoding: 'utf8', env: {
    ...f.env, HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(f.dir, 'slots'),
    FLEET_PS_CMD: join(f.dir, 'ps'), FLEET_PROC: f.dir, CADENCE_BANK_LANE: 'api',
    CADENCE_BANK_LEDGER: join(f.dir, 'bank-ledger'), CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_PRODUCER: join(f.dir, 'must-not-run'),
  } });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'PROCEED');
  assert.match(r.stderr, /api:A.*grant-cycle=cycle-a.*available-est=1\.000000/);
});
