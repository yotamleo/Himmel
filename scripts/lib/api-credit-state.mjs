// HIMMEL-4904: local, secret-free API grant accounting. No auth or network.
// Amounts are decimal-string USD with at most six places; arithmetic is BigInt.
// One shared ledger/lock covers both accounts. Locks are never reclaimed by age
// or PID: a crashed holder requires operator recovery, not guessed free credit.
// ponytail: launcher-supplied cost/completion evidence is trusted; task 2 must
// bound requests and prove terminal outcomes before API dispatch is enabled.
import {
  closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync,
  lstatSync, realpathSync, renameSync, rmdirSync, unlinkSync, writeFileSync,
} from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

const SCALE = 1000000n;
const MAX_AGE = 600;
const ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
const object = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const own = (v, k) => Object.hasOwn(v, k);

function refuse(reason, verdict = 'BANK-UNKNOWN') {
  const e = new Error(reason); e.verdict = verdict; throw e;
}
function money(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,12})(\.[0-9]{1,6})?$/.test(value)) refuse('invalid-money');
  const [whole, fraction = ''] = value.split('.');
  return BigInt(whole) * SCALE + BigInt(fraction.padEnd(6, '0'));
}
function usd(value) {
  return `${value / SCALE}.${String(value % SCALE).padStart(6, '0')}`;
}
function read(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { refuse('unreadable-state'); }
}
function id(value) {
  if (typeof value !== 'string' || !ID.test(value)) refuse('invalid-identity');
  return value;
}
function configs(config) {
  if (!object(config) || config.version !== 1 || !object(config.accounts)) refuse('invalid-config');
  const orgs = new Set();
  const names = Object.keys(config.accounts);
  if (names.length === 0) refuse('missing-account-config');
  for (const account of names) {
    if (!['A', 'B'].includes(account)) refuse('invalid-account-config');
    const c = config.accounts[account];
    if (!object(c)) refuse('invalid-account-config');
    id(c.organization_id); id(c.cycle_id); money(c.cap_usd);
    if (orgs.has(c.organization_id)) refuse('duplicate-organization');
    orgs.add(c.organization_id);
  }
}
function identity(a, c) {
  if (a.organization_id !== c.organization_id || a.cycle_id !== c.cycle_id) refuse('identity-or-cycle-mismatch');
}
function ledgerCheck(state) {
  if (!object(state) || state.version !== 1 || !object(state.accounts)) refuse('invalid-ledger');
  for (const [name, a] of Object.entries(state.accounts)) {
    if (!['A', 'B'].includes(name) || !object(a) || !object(a.jobs) || typeof a.discrepancy !== 'boolean') refuse('invalid-ledger');
    id(a.organization_id); id(a.cycle_id);
    for (const [job, j] of Object.entries(a.jobs)) {
      id(job);
      if (!object(j) || !['reserved', 'unknown', 'settled'].includes(j.status) || money(j.maximum_usd) === 0n) refuse('invalid-ledger');
      if (j.status === 'settled') {
        const actual = money(j.actual_usd);
        if (actual > money(j.maximum_usd) && !a.discrepancy) refuse('unrecorded-discrepancy');
      } else if (own(j, 'actual_usd')) refuse('invalid-ledger');
    }
  }
}
function totals(a) {
  let spent = 0n, reserved = 0n;
  for (const j of Object.values(a?.jobs ?? {})) {
    if (j.status === 'settled') spent += money(j.actual_usd);
    else reserved += money(j.maximum_usd);
  }
  return { spent, reserved };
}
function row(config, snapshot, a, account, now) {
  if (!object(snapshot) || snapshot.version !== 1 || !object(snapshot.accounts) || !own(snapshot.accounts, account)) refuse('missing-snapshot');
  const s = snapshot.accounts[account];
  if (!object(s)) refuse('invalid-snapshot');
  identity(s, config);
  const grant = money(s.grant_usd), remaining = money(s.remaining_usd), cap = money(config.cap_usd);
  const watermark = money(s.reconciled_spent_usd);
  const { spent, reserved } = totals(a);
  if (remaining > grant || cap > grant || watermark > spent || watermark > grant - remaining) refuse('unreconciled-amounts');
  if (s.exclusive_org !== true || s.discrepancy !== false || a?.discrepancy || s.source !== 'operator-console-snapshot') refuse('unverified-or-discrepant');
  for (const t of [s.starts_at, s.expires_at, s.observed_at]) {
    if (!Number.isSafeInteger(t) || t < 0) refuse('invalid-timestamp');
  }
  if (s.starts_at >= s.expires_at || s.starts_at > now || s.observed_at < s.starts_at) refuse('invalid-grant-interval');
  if (s.expires_at <= now) refuse('expired-grant', 'SKIPPED-BANK');
  const age = now - s.observed_at;
  if (age < 0 || age > MAX_AGE) refuse('stale-snapshot', 'BANK-STALE');
  // Snapshot includes provider-observed spend. Subtract only local completions
  // after the explicit reconciliation watermark, plus every outstanding maximum.
  const consumed = grant - remaining + spent - watermark;
  const available = (cap < grant ? cap : grant) - consumed - reserved;
  return {
    verdict: available > 0n ? 'PROCEED' : 'SKIPPED-BANK', account,
    organization_id: s.organization_id, cycle_id: s.cycle_id,
    grant_usd: usd(grant), cap_usd: usd(cap), spent_est_usd: usd(consumed),
    reserved_usd: usd(reserved), available_est_usd: usd(available > 0n ? available : 0n),
    expires_at: s.expires_at, age_seconds: age, source: s.source,
  };
}
function durableFile(path, contents) {
  const fd = openSync(path, 'wx', 0o600);
  try { writeFileSync(fd, contents); fsyncSync(fd); } finally { closeSync(fd); }
}
function syncDirectory(path) {
  const fd = openSync(path, 'r');
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
function save(statePath, state, lock) {
  // Sentinel precedes the first write: missing/corrupt ledger after a crash must
  // never look like an unused grant. Keep it through every cycle/settlement.
  const sentinel = `${statePath}.initialized`;
  if (!existsSync(sentinel)) {
    durableFile(sentinel, 'api-credit-ledger-v1\n');
    syncDirectory(dirname(statePath));
  }
  const temporary = join(lock, 'ledger.json');
  durableFile(temporary, `${JSON.stringify(state)}\n`);
  renameSync(temporary, statePath);
  syncDirectory(dirname(statePath));
}

export function creditState(command, options = {}, env = process.env) {
  const root = join(env.HOME || homedir(), '.himmel/state/api-credit');
  let lock, held = false;
  try {
    const account = env.HIMMEL_API_ACCOUNT;
    if (!['A', 'B'].includes(account)) refuse('account-required');
    if (!['status', 'reserve', 'unknown', 'settle'].includes(command)) refuse('invalid-command');
    const config = read(env.HIMMEL_API_CREDIT_CONFIG || join(root, 'config.json'));
    configs(config);
    if (!own(config.accounts, account)) refuse('account-not-configured');
    const c = config.accounts[account];
    let statePath = resolve(env.HIMMEL_API_CREDIT_STATE || join(root, 'ledger.json'));
    mkdirSync(dirname(statePath), { recursive: true, mode: 0o700 });
    // Canonicalise the parent so aliases through symlinked directories share
    // the same transaction lock. The operator must use one ledger for the fleet.
    statePath = join(realpathSync(dirname(statePath)), basename(statePath));
    lock = `${statePath}.lock`;
    try { mkdirSync(lock, { mode: 0o700 }); held = true; } catch { refuse('ledger-locked-or-unwritable'); }
    // A file symlink/hardlink alias has another basename and therefore another
    // mutex. Reject it rather than read shared spend under an unrelated lock.
    try {
      const stat = lstatSync(statePath);
      if (!stat.isFile() || stat.nlink !== 1) refuse('aliased-or-invalid-ledger');
    } catch (e) { if (e.code !== 'ENOENT') throw e; }
    const sentinel = `${statePath}.initialized`;
    if (existsSync(sentinel) && readFileSync(sentinel, 'utf8') !== 'api-credit-ledger-v1\n') refuse('invalid-ledger-sentinel');
    if (!existsSync(statePath) && existsSync(sentinel)) refuse('missing-initialized-ledger');
    const state = existsSync(statePath) ? read(statePath) : { version: 1, accounts: {} };
    ledgerCheck(state);
    // Changing a configured identity cannot hide a previous cycle's obligations.
    // Rollover is explicit operator reconciliation, never a calendar reset.
    for (const [name, a] of Object.entries(state.accounts)) {
      if (!own(config.accounts, name)) refuse('unconfigured-ledger-account');
      identity(a, config.accounts[name]);
    }
    let a = state.accounts[account];
    if (command === 'status' || command === 'reserve') {
      const snapshot = read(env.HIMMEL_API_CREDIT_SNAPSHOT || join(root, 'snapshot.json'));
      const result = row(c, snapshot, a, account, Math.floor(Date.now() / 1000));
      if (command === 'status') return result;
      id(options.id);
      const maximum = money(options.usd);
      if (maximum === 0n) refuse('positive-maximum-required');
      if (a && own(a.jobs, options.id)) refuse('duplicate-job');
      if (maximum > money(result.available_est_usd)) return { ...result, verdict: 'SKIPPED-BANK', reason: 'insufficient-headroom' };
      if (!a) {
        a = { organization_id: c.organization_id, cycle_id: c.cycle_id, discrepancy: false, jobs: {} };
        state.accounts[account] = a;
      }
      a.jobs[options.id] = { status: 'reserved', maximum_usd: usd(maximum) };
      save(statePath, state, lock);
      return { ...row(c, snapshot, a, account, Math.floor(Date.now() / 1000)), verdict: 'PROCEED', job_id: options.id };
    }
    id(options.id);
    if (!a || !own(a.jobs, options.id)) refuse('missing-job');
    const job = a.jobs[options.id];
    if (job.status === 'settled') refuse('already-settled');
    if (command === 'unknown') {
      job.status = 'unknown'; save(statePath, state, lock);
      return { verdict: 'PROCEED', account, job_id: options.id, reserved_usd: usd(totals(a).reserved) };
    }
    if (options.completion !== 'verified') refuse('terminal-completion-required');
    const actual = money(options.usd);
    job.status = 'settled'; job.actual_usd = usd(actual);
    if (actual > money(job.maximum_usd)) a.discrepancy = true;
    save(statePath, state, lock);
    return { verdict: a.discrepancy ? 'BANK-UNKNOWN' : 'PROCEED', account, job_id: options.id,
      reason: a.discrepancy ? 'reservation-overrun' : 'settled' };
  } catch (e) {
    return { verdict: e.verdict || 'BANK-UNKNOWN', reason: e.verdict ? e.message : 'state-io-failure' };
  } finally {
    if (held) {
      // Only our private lock is released; no stale-owner sweep anywhere.
      try { unlinkSync(join(lock, 'ledger.json')); } catch { /* no temporary file */ }
      try { rmdirSync(lock); } catch { /* orphan lock blocks future admissions */ }
    }
  }
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    const name = args[i]?.slice(2);
    if (!['--id', '--usd', '--completion'].includes(args[i]) || !args[i + 1] || own(options, name)) {
      console.log(JSON.stringify({ verdict: 'BANK-UNKNOWN', reason: 'invalid-arguments' })); return;
    }
    options[name] = args[i + 1];
  }
  const result = creditState(command, options);
  if (process.env.HIMMEL_API_CREDIT_FORMAT === 'bank') {
    if (result.account && result.grant_usd) {
      console.error(`api:${result.account} grant-cycle=${result.cycle_id} grant=${result.grant_usd} spent-est=${result.spent_est_usd} reserved=${result.reserved_usd} available-est=${result.available_est_usd} expires=${new Date(result.expires_at * 1000).toISOString()} age=${result.age_seconds} source=${result.source}`);
    } else console.error(`api credit-state: ${result.reason}`);
    console.log(result.verdict);
  } else console.log(JSON.stringify(result));
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) main();
