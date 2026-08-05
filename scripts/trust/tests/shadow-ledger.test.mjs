// HIMMEL-1529 — the suite is the spec for the R0 shadow ledger.
//
// The three properties that matter, in order:
//   1. it NEVER emits a permission decision (and above all never `ask`);
//   2. the blind verdict is on disk BEFORE the process exits toward the
//      permission layer;
//   3. it never blocks — every malformed input still exits 0.
// Everything else is bookkeeping.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  append, canonical, chainHash, classify, healthPath, isApprovalInterrupt,
  lastRecord, readAll, readDrops, readLedger, refFor, shadowVerdict, summarize,
  RECORDED_TOOLS,
} from '../shadow-ledger.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, '..', 'shadow-ledger.mjs');

let TMP;
// [glm-6]: every freshDir() is tracked so the suite does not leave a directory
// per test case behind in the system temp dir on every run.
const CASE_DIRS = [];
before(() => {
  TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'shadow-ledger-'));
  process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
});
after(() => {
  for (const d of [...CASE_DIRS, TMP]) {
    try { fs.rmSync(d, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

function freshDir() {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'shadow-ledger-case-'));
  CASE_DIRS.push(d);
  return d;
}

function runHook(args, stdin, dir) {
  return spawnSync(process.execPath, [SCRIPT, ...args], {
    input: stdin,
    encoding: 'utf8',
    env: { ...process.env, HIMMEL_TRUST_LEDGER_DIR: dir },
  });
}

const PRE_BASH = JSON.stringify({
  session_id: 's1',
  tool_name: 'Bash',
  tool_input: { command: 'git push --force origin main' },
  permission_mode: 'auto',
});

// --- 1. the hard constraint --------------------------------------------------

describe('never decides', () => {
  test('pre/post/notify all exit 0 with EMPTY stdout — no decision emitted', () => {
    const dir = freshDir();
    for (const [cmd, payload] of [
      ['pre', PRE_BASH],
      ['post', PRE_BASH],
      ['notify', JSON.stringify({ session_id: 's1', notification_type: 'permission' })],
    ]) {
      const r = runHook([cmd], payload, dir);
      assert.equal(r.status, 0, `${cmd} must exit 0`);
      assert.equal(r.stdout, '', `${cmd} must emit nothing on stdout`);
    }
  });

  // A source-text pin, not a behavioural one: `ask` reintroduces the dialog
  // `defaultMode: auto` exists to remove, and in an armed session that dialog is
  // unanswerable and unbounded (measured at 902.5s, still blocked when killed).
  // Behavioural tests only prove the paths they exercise; this proves the string
  // is not in the file at all.
  test('source contains no permissionDecision of any kind', () => {
    const src = fs.readFileSync(SCRIPT, 'utf8');
    const code = src.split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
    assert.ok(!/permissionDecision/.test(code), 'must never emit permissionDecision');
    assert.ok(!/["']ask["']/.test(code), 'must never emit an `ask` decision');
    assert.ok(!/hookSpecificOutput/.test(code), 'must not shape a hook decision payload');
  });
});

// --- 2. blind ordering -------------------------------------------------------

describe('blind ordering', () => {
  test('the shadow verdict is durably on disk when the process exits', () => {
    const dir = freshDir();
    const r = runHook(['pre'], PRE_BASH, dir);
    assert.equal(r.status, 0);
    // Read from a SEPARATE process's perspective: if the write were deferred or
    // buffered past exit, this file would not exist yet.
    const rows = readAll(path.join(dir, 'ledger.jsonl'));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].kind, 'request');
    assert.equal(rows[0].shadow_verdict, 'deny');
    assert.equal(rows[0].actual_verdict, null, 'actual is unknown at request time');
  });

  test('the request row carries the full record shape', () => {
    const dir = freshDir();
    runHook(['pre'], PRE_BASH, dir);
    const [row] = readAll(path.join(dir, 'ledger.jsonl'));
    for (const k of ['ts', 'class', 'requester_lane', 'lane_config_hash', 'target',
      'shadow_verdict', 'actual_verdict', 'prev_hash', 'hash']) {
      assert.ok(k in row, `missing field ${k}`);
    }
  });

  test('no transcript, no raw command, is stored', () => {
    const dir = freshDir();
    runHook(['pre'], PRE_BASH, dir);
    const text = fs.readFileSync(path.join(dir, 'ledger.jsonl'), 'utf8');
    assert.ok(!text.includes('--force'), 'raw command text must not reach the ledger');
    assert.ok(text.includes('git push'), 'the coarse class handle should survive');
  });
});

// --- 3. fail-open ------------------------------------------------------------

describe('fail-open', () => {
  for (const [name, stdin] of [
    ['empty stdin', ''],
    ['not json', 'this is not json'],
    ['json but not an object', '"hello"'],
    ['object with no tool', '{}'],
    ['null tool_input', '{"tool_name":"Bash","tool_input":null}'],
  ]) {
    test(`${name} → exit 0, silent`, () => {
      const r = runHook(['pre'], stdin, freshDir());
      assert.equal(r.status, 0);
      assert.equal(r.stdout, '');
    });
  }

  test('an unwritable ledger dir still exits 0', () => {
    const r = runHook(['pre'], PRE_BASH, path.join(os.devNull, 'nope', 'nested'));
    assert.equal(r.status, 0);
    assert.equal(r.stdout, '');
  });

  test('unknown subcommand exits 0', () => {
    const r = runHook(['wat'], PRE_BASH, freshDir());
    assert.equal(r.status, 0);
  });
});

// --- 4. the hash chain -------------------------------------------------------

describe('hash chain', () => {
  test('genesis, linkage, and order-independent canonicalisation', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    const a = append({ ts: '2026-08-04T00:00:00.000Z', kind: 'request', n: 1 });
    const b = append({ ts: '2026-08-04T00:00:01.000Z', kind: 'request', n: 2 });
    assert.equal(a.prev_hash, '0'.repeat(64), 'first record chains to genesis');
    assert.equal(b.prev_hash, a.hash, 'second record chains to the first');
    assert.equal(lastRecord().hash, b.hash);
    // canonical() sorts keys, so field order cannot change a hash.
    assert.equal(
      canonical({ b: 2, a: 1, hash: 'x' }),
      canonical({ a: 1, b: 2, hash: 'y' }),
    );
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  test('tampering with a record breaks its hash', () => {
    const rec = { ts: 'x', kind: 'request', class: 'bash:ls' };
    const h = chainHash('0'.repeat(64), rec);
    assert.notEqual(h, chainHash('0'.repeat(64), { ...rec, class: 'bash:rm' }));
    assert.notEqual(h, chainHash('f'.repeat(64), rec), 'prev_hash is bound in');
  });

  // [glm-2] regression. A lock holder killed between open and unlink used to
  // wedge the ledger PERMANENTLY: every later call burned all its retries and
  // dropped its record, so recording stopped for good, silently — and this
  // harness kills hook processes as a matter of course.
  test('a stale lock left by a killed writer is reclaimed, not fatal', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    const lock = path.join(dir, '.ledger.lock');
    fs.writeFileSync(lock, '');
    const old = Date.now() - 60_000;
    fs.utimesSync(lock, old / 1000, old / 1000);

    const rec = append({ ts: 'x', kind: 'request' });
    assert.ok(rec, 'append must succeed after reclaiming the stale lock');
    assert.equal(fs.existsSync(lock), false, 'the lock is released again');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  test('a FRESH lock is respected — reclamation is not a free-for-all', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, '.ledger.lock'), '');   // held right now
    assert.equal(append({ ts: 'x', kind: 'request' }), null, 'must not steal a live lock');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  // [codex-2] regression. Age alone is not evidence of death: a merely slow or
  // SIGSTOPped writer would lose exclusivity and the two writers would fork the
  // chain — trading a loud wedge for silent corruption, the worse bargain.
  test('an OLD lock owned by a LIVE pid is not broken', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    const lock = path.join(dir, '.ledger.lock');
    // Our own pid is alive by definition; stamp it as very old.
    fs.writeFileSync(lock, `${process.pid} ${Date.now() - 600_000}`);
    assert.equal(append({ ts: 'x', kind: 'request' }), null, 'a live owner keeps the lock');
    assert.ok(fs.existsSync(lock), 'the lock survives');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  test('an OLD lock owned by a DEAD pid is reclaimed', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    const lock = path.join(dir, '.ledger.lock');
    // PID 2^22 is above every platform's pid_max — reliably not a live process.
    fs.writeFileSync(lock, `4194304 ${Date.now() - 600_000}`);
    assert.ok(append({ ts: 'x', kind: 'request' }), 'a dead owner releases the lock');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  test('the lock records its owner so death can be proven, not inferred', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    let seen = '';
    const lock = path.join(dir, '.ledger.lock');
    // Observe the lock's contents from inside the critical section.
    const orig = fs.appendFileSync;
    fs.appendFileSync = (...a) => { seen = fs.readFileSync(lock, 'utf8'); return orig(...a); };
    try {
      append({ ts: 'x', kind: 'request' });
    } finally {
      fs.appendFileSync = orig;
    }
    assert.match(seen, new RegExp(`^${process.pid} \\d+$`), 'pid + timestamp are stamped');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  // [glm-3] regression. A record larger than the tail window used to be clipped
  // and unparseable, so the next append chained to an EARLIER record — a fork
  // that leaves no trace at the point it happens.
  test('a record larger than the tail window does not fork the chain', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    append({ ts: 'a', kind: 'request' });
    const big = append({ ts: 'b', kind: 'request', target: 'x'.repeat(40_000) });
    const next = append({ ts: 'c', kind: 'request' });
    assert.equal(next.prev_hash, big.hash, 'chains to the oversized record, not past it');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  // [codex-adv round 2] regression. An unconditional unlink on release deletes
  // whatever sits at the pathname — including a replacement lock a reclaimer
  // took after deciding we were dead, putting two writers in the section.
  test('release does not delete a lock this writer no longer owns', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    const lock = path.join(dir, '.ledger.lock');
    // Simulate a reclaimer replacing our lock mid-critical-section.
    const orig = fs.appendFileSync;
    fs.appendFileSync = (...a) => { fs.writeFileSync(lock, 'other-owner 1'); return orig(...a); };
    try {
      append({ ts: 'x', kind: 'request' });
    } finally {
      fs.appendFileSync = orig;
    }
    assert.equal(fs.readFileSync(lock, 'utf8'), 'other-owner 1', "the other writer's lock survives");
    fs.unlinkSync(lock);
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  // [codex-adv round 2] regression. Skipping a torn interior row and then
  // publishing a confident rate is the failure: the number comes out plausible
  // but understated, with nothing to signal it.
  describe('a damaged ledger cannot publish a rate', () => {
    test('an interior torn row is counted as malformed', () => {
      const dir = freshDir();
      process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
      fs.mkdirSync(dir, { recursive: true });
      const f = path.join(dir, 'ledger.jsonl');
      append({ ts: 'a', kind: 'request' });
      fs.appendFileSync(f, '{"torn":\n');          // interior damage
      append({ ts: 'b', kind: 'request' });
      const led = readLedger(f);
      assert.equal(led.malformed, 1);
      assert.equal(led.intact, false);
      process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
    });

    // [HIMMEL-1539] A torn FINAL line used to be exempted UNCONDITIONALLY as a
    // normal in-flight append. That is true only while a writer is alive to heal
    // it. Abandoned — a killed hook, a power loss — nothing ever heals it, the
    // event is permanently lost, and the ledger read `intact` forever. On a
    // quiet ledger, where one lost event moves the rate most, it could stay
    // missing indefinitely under a confidently published number.
    // [codex-adv round 1] A live writer buys the fragment a bounded WAIT, never
    // forgiveness. Liveness of some lock holder does not tie that holder to
    // THIS fragment — a later writer would briefly absolve an abandoned one it
    // never created — and a report racing an incomplete append must not publish
    // before the row lands. So after the wait, a tail that still does not parse
    // is damage no matter who holds the lock.
    test('a live writer does NOT make a torn tail intact — it only buys a wait', () => {
      const dir = freshDir();
      process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
      fs.mkdirSync(dir, { recursive: true });
      const f = path.join(dir, 'ledger.jsonl');
      append({ ts: 'a', kind: 'request' });
      fs.appendFileSync(f, '{"never-completed":');
      // A lock owned by THIS process, freshly stamped: a genuinely live writer
      // that nonetheless never completes the fragment.
      fs.writeFileSync(path.join(dir, '.ledger.lock'), `${process.pid} ${Date.now()}`);
      const led = readLedger(f);
      assert.equal(led.torn, 1, 'the wait expired and the fragment still does not parse');
      assert.equal(led.intact, false);
      process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
    });

    test('a fragment healed into an interior line is still counted', () => {
      const dir = freshDir();
      process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
      fs.mkdirSync(dir, { recursive: true });
      const f = path.join(dir, 'ledger.jsonl');
      append({ ts: 'a', kind: 'request' });
      fs.appendFileSync(f, '{"torn":');
      // A completing append heals the file by prefixing a newline to its OWN
      // record — that does not recover the lost event, it just stops the damage
      // swallowing the next one. The fragment becomes INTERIOR, so it must
      // still show up, as `malformed` rather than `torn`.
      append({ ts: 'b', kind: 'request' });
      const led = readLedger(f);
      assert.equal(led.torn, 0);
      assert.equal(led.malformed, 1, 'healing is not recovery — the event stays lost and counted');
      assert.equal(led.intact, false);
      process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
    });

    test('an ABANDONED torn FINAL row is damage and suppresses the rate', () => {
      const dir = freshDir();
      process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
      fs.mkdirSync(dir, { recursive: true });
      const f = path.join(dir, 'ledger.jsonl');
      append({ ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' });
      fs.appendFileSync(f, '{"abandoned":');       // no lock file => no live writer
      const led = readLedger(f);
      assert.equal(led.torn, 1, 'nothing will ever heal this fragment');
      assert.equal(led.intact, false);
      const s = summarize(led.records, null, '2026-08-04T00:00:00.000Z', led);
      assert.equal(s.interrupts, 1, 'the raw count is still shown');
      assert.equal(s.interrupts_per_week, null, 'but a ledger missing an event publishes no rate');
      process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
    });

    test('a torn FINAL row under a STALE lock is still damage', () => {
      const dir = freshDir();
      process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
      fs.mkdirSync(dir, { recursive: true });
      const f = path.join(dir, 'ledger.jsonl');
      append({ ts: 'a', kind: 'request' });
      fs.appendFileSync(f, '{"abandoned":');
      // Our own pid — alive — but stamped long ago. Liveness of the PID is not
      // evidence the LOCK is held; a recycled pid must not exempt the fragment.
      fs.writeFileSync(path.join(dir, '.ledger.lock'), `${process.pid} ${Date.now() - 600000}`);
      const led = readLedger(f);
      assert.equal(led.torn, 1, 'a stale stamp means the holder is long gone');
      assert.equal(led.intact, false);
      process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
    });

    test('a tampered row breaks the chain and suppresses the rate', () => {
      const rows = [
        { ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
      ];
      const damaged = { intact: false, malformed: 2, brokenLinks: 1 };
      const s = summarize(rows, null, '2026-08-04T00:00:00.000Z', damaged);
      assert.equal(s.interrupts, 1, 'the raw count is still shown');
      assert.equal(s.interrupts_per_week, null, 'but no rate is published');
      assert.equal(s.integrity.intact, false);
    });

    test('the report says the ledger is damaged rather than implying a floor is a measurement', () => {
      const dir = freshDir();
      fs.mkdirSync(dir, { recursive: true });
      const f = path.join(dir, 'ledger.jsonl');
      process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
      append({ ts: 'a', kind: 'request' });
      fs.appendFileSync(f, '{"torn":\n');
      append({ ts: 'b', kind: 'request' });
      process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
      const r = runHook(['report'], '', dir);
      assert.equal(r.status, 0);
      assert.match(r.stdout, /LEDGER DAMAGED/);
      assert.match(r.stdout, /INTEGRITY/);
    });
  });

  // Without healing, a record written after an interrupted append is GLUED onto
  // the partial line — the damage swallows the new record too, turning a
  // recoverable one-line loss into an ongoing one.
  test('an append after a torn final line does not glue onto it', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    const f = path.join(dir, 'ledger.jsonl');
    const a = append({ ts: 'a', kind: 'request' });
    fs.appendFileSync(f, '{"in-flight":');        // no trailing newline
    const b = append({ ts: 'b', kind: 'request' });
    const led = readLedger(f);
    assert.equal(led.records.length, 2, 'both real records survive');
    assert.equal(led.records[1].hash, b.hash);
    assert.equal(b.prev_hash, a.hash);
    assert.equal(led.malformed, 1, 'the torn line is now interior damage and is COUNTED');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  test('a torn trailing line does not break the next append', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    const a = append({ ts: 't', kind: 'request' });
    fs.appendFileSync(path.join(dir, 'ledger.jsonl'), '{"partial":\n');
    const b = append({ ts: 'u', kind: 'request' });
    assert.equal(b.prev_hash, a.hash, 'chains to the last PARSEABLE record');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });
});

// --- 5. classification + verdict ---------------------------------------------

describe('classification', () => {
  test('bash class is verb x subverb, not the whole command', () => {
    const c = classify('Bash', { command: 'git push --force origin main' });
    assert.equal(c.class, 'bash:git push');
    assert.equal(c.target, 'git push');
  });

  test('identical commands share a target_hash, different ones do not', () => {
    const a = classify('Bash', { command: 'ls -la' });
    const b = classify('Bash', { command: 'ls -la' });
    const c = classify('Bash', { command: 'ls -l' });
    assert.equal(a.target_hash, b.target_hash);
    assert.notEqual(a.target_hash, c.target_hash);
  });

  // [codex-adv] regression. Keeping the second token for EVERY binary stored
  // arguments verbatim, and arguments carry secrets — this made the ledger
  // itself a credential store while the README promised the opposite.
  test('a secret-bearing argument never reaches the target field', () => {
    const c = classify('Bash', { command: 'curl https://api.example.com/v1?token=SECRET123' });
    assert.equal(c.class, 'bash:curl');
    assert.equal(c.target, 'curl');
    assert.ok(!JSON.stringify(c).includes('SECRET123'));
  });

  test('known command families still keep their subcommand', () => {
    assert.equal(classify('Bash', { command: 'git push origin x' }).class, 'bash:git push');
    assert.equal(classify('Bash', { command: 'npm run build' }).class, 'bash:npm run');
  });

  // [codex-adv round 2] regression. A family allowlist was not enough: runner
  // commands take a PATH or PACKAGE as their second token, not a verb, so
  // recognising the family still persisted the argument verbatim.
  test('runner commands never record their second token', () => {
    for (const [cmd, secret] of [
      ['npx https://alice:TOKEN123@github.com/acme/private-tool', 'TOKEN123'],
      ['node /home/alice/clients/acme/deploy.mjs', 'acme'],
      ['bun /srv/secret-client/run.ts', 'secret-client'],
      ['dotnet /opt/AcmeCorp/Private.dll', 'AcmeCorp'],
    ]) {
      const c = classify('Bash', { command: cmd });
      assert.ok(!JSON.stringify(c).includes(secret), `${cmd} leaked into the ledger`);
    }
    assert.equal(classify('Bash', { command: 'npx some-pkg' }).class, 'bash:npx');
  });

  // [codex-adv round 3] regression, and the same class a THIRD time. The
  // subcommand half was allowlist-validated; the VERB half was not. Whitespace
  // splitting cannot see a quoted assignment value containing a space, so the
  // fragment after the space became the verb and was persisted verbatim.
  test('a quoted assignment value never becomes the verb', () => {
    for (const cmd of [
      "TOKEN='x SECRET123' git status",
      'TOKEN="x SECRET123" git status',
      "AWS_SECRET='a b' npm run build",
    ]) {
      const c = classify('Bash', { command: cmd });
      assert.equal(c.class, 'bash:unknown', `${cmd} classified as ${c.class}`);
      assert.ok(!JSON.stringify(c).includes('SECRET123'), `${cmd} leaked into the ledger`);
      assert.ok(!JSON.stringify(c).includes('a b'), `${cmd} leaked into the ledger`);
    }
    // An unquoted assignment is still stripped and the real verb still kept.
    assert.equal(classify('Bash', { command: 'LANG=C git log' }).class, 'bash:git log');
  });

  // The token itself is validated, so an unrecognised second word — which is
  // where secrets live — is dropped even for a recognised family.
  test('an unknown subcommand of a known family is dropped', () => {
    const c = classify('Bash', { command: 'git https://user:PASS@host/repo.git' });
    assert.equal(c.class, 'bash:git');
    assert.ok(!JSON.stringify(c).includes('PASS'));
  });

  test('leading assignments and absolute paths normalise to the binary', () => {
    // The assignment holds a VALUE, so it must never become the verb.
    assert.equal(classify('Bash', { command: 'TOKEN=abc123 git status' }).class, 'bash:git status');
    assert.equal(classify('Bash', { command: '/usr/local/bin/git status' }).class, 'bash:git status');
    assert.ok(!JSON.stringify(classify('Bash', { command: 'TOKEN=abc123 git status' })).includes('abc123'));
  });

  test('file tools classify by extension, not by full path', () => {
    const c = classify('Write', { file_path: '/repo/scripts/hooks/thing.sh' });
    assert.equal(c.class, 'write:.sh');
    assert.equal(c.target, '.sh');
  });

  // A directory basename leaks the same class of thing a command argument does.
  test('a file target never names the parent directory', () => {
    const c = classify('Edit', { file_path: '/work/clients/AcmeCorp/deploy.ts' });
    assert.ok(!JSON.stringify(c).includes('AcmeCorp'));
    assert.ok(!JSON.stringify(c).includes('clients'));
  });

  test('read-shaped tools are not recorded at all', () => {
    assert.ok(!RECORDED_TOOLS.includes('Read'));
    assert.ok(!RECORDED_TOOLS.includes('Grep'));
    const dir = freshDir();
    runHook(['pre'], JSON.stringify({
      session_id: 's', tool_name: 'Read', tool_input: { file_path: '/x.txt' },
    }), dir);
    assert.equal(readAll(path.join(dir, 'ledger.jsonl')).length, 0);
  });
});

describe('shadow verdict', () => {
  const bash = (command) => shadowVerdict('Bash', { command });

  test('provably read-only pipelines → allow', () => {
    assert.equal(bash('ls -la'), 'allow');
    assert.equal(bash('git status'), 'allow');
    assert.equal(bash('cat a.txt | grep foo | wc -l'), 'allow');
    assert.equal(bash('LANG=C git log --oneline -5'), 'allow');
  });

  test('hard-blocked shapes → deny', () => {
    assert.equal(bash('git push --force origin main'), 'deny');
    assert.equal(bash('git commit --amend -m x'), 'deny');
    assert.equal(shadowVerdict('Write', { file_path: '/repo/.git/config' }), 'deny');
  });

  test('force-with-lease is NOT the denied shape', () => {
    assert.notEqual(bash('git push --force-with-lease origin feat/x'), 'deny');
  });

  // The lease flag does not launder a bare --force: the bare flag clobbers
  // without the stale-tip check whatever else is on the line, and the
  // production guard refuses that combination outright.
  test('--force-with-lease alongside a bare --force is still a force push', () => {
    assert.equal(bash('git push --force-with-lease --force origin main'), 'deny');
    assert.equal(bash('git push --force --force-with-lease origin main'), 'deny');
  });

  // Some git global flags take a SEPARATE argument, so "first non-flag word"
  // read `repo` as the subcommand and missed the push entirely.
  test('a global flag with its own argument does not hide the subcommand', () => {
    assert.equal(bash('git -C repo push --force origin main'), 'deny');
    assert.equal(bash('git --git-dir /r/.git push --force origin main'), 'deny');
    assert.equal(bash('git -C repo status'), 'allow');
  });

  test('contested shapes → abstain, never a guess', () => {
    assert.equal(bash('node build.mjs'), 'abstain');
    assert.equal(bash('echo hi > out.txt'), 'abstain');
    assert.equal(bash('cat $(which node)'), 'abstain');
    assert.equal(bash('git commit -m wip'), 'abstain');
    assert.equal(shadowVerdict('Edit', { file_path: '/repo/src/a.ts' }), 'abstain');
    assert.equal(bash(''), 'abstain');
  });

  test('a safe head with an unsafe tail is contested', () => {
    assert.equal(bash('ls && rm -rf /tmp/x'), 'abstain');
  });

  // A bare `&` is a real separator — the `rm` in `ls & rm file` RUNS. Treating
  // the line as one `ls` segment produced a false `allow`, the most damaging
  // error this function can make.
  test('a bare & separator is not swallowed into the preceding segment', () => {
    assert.equal(bash('ls & rm file'), 'abstain');
    assert.equal(bash('cat a & node b.js'), 'abstain');
  });

  test('an & that belongs to a redirect stays attached', () => {
    assert.equal(bash('grep x f 2>&1'), 'allow');
    assert.equal(bash('ls >/dev/null 2>&1'), 'allow');
  });

  // The exclusion used to be a lookahead after `\s*`, which backtracks to zero
  // width: it was tested against the SPACE, so it never applied to the spaced
  // form, and a path merely PREFIXED by /dev/null slipped through to `allow`.
  test('the /dev/null exclusion is the whole target, spaced or not', () => {
    assert.equal(bash('ls > /dev/null'), 'allow');
    assert.equal(bash('ls >/dev/null'), 'allow');
    assert.equal(bash('ls >/dev/null.bak'), 'abstain');
    assert.equal(bash('ls > /dev/nullish'), 'abstain');
    // A control operator ends the target; it is not part of the filename.
    assert.equal(bash('ls >/dev/null; pwd'), 'allow');
    assert.equal(bash('ls >/dev/null | cat'), 'allow');
  });

  // `.git` with no trailing separator is the worktree pointer FILE; rewriting it
  // repoints the worktree at another repository.
  test('the .git worktree pointer file is a denial, not an abstain', () => {
    assert.equal(shadowVerdict('Edit', { file_path: '/repo/.git' }), 'deny');
    assert.equal(shadowVerdict('Write', { file_path: 'C:\\repo\\.git' }), 'deny');
    // A file that merely starts with `.git` is ordinary.
    assert.equal(shadowVerdict('Edit', { file_path: '/repo/.gitignore' }), 'abstain');
  });

  // A wrong `deny` corrupts the evidence exactly as a wrong `allow` does.
  test('a quoted redirect is literal text, not a redirect', () => {
    assert.notEqual(bash('echo "> .git/config"'), 'deny');
    assert.notEqual(bash("grep -r '> .git/hooks' docs"), 'deny');
    // The real thing still denies.
    assert.equal(bash('echo x > .git/config'), 'deny');
  });

  // [codex-3] regression. A whole-string regex classified `echo "git push
  // --force"` as a denied force-push: the words are there, but the segment runs
  // `echo`. A verdict engine that reads text instead of argv measures its own
  // parsing, and every such row is a false `deny` in the evidence.
  test('quoted text that merely MENTIONS a denied command is not a denial', () => {
    assert.notEqual(bash('echo "git push --force"'), 'deny');
    assert.notEqual(bash('grep -r "git commit --amend" docs'), 'deny');
  });

  // [codex-1] regression. Per-segment matching fixed the whole-string regex, but
  // the SEGMENT SPLIT still ran on raw text — so a separator INSIDE quotes cut
  // the line, and the tail fragment ran `git push --force`. Same false-deny
  // class, one layer down: the boundaries must come from the masked copy too.
  test('a control operator inside quotes does not split the command', () => {
    assert.notEqual(bash('echo "x && git push --force origin main"'), 'deny');
    assert.notEqual(bash('grep -r "a | git push --force b" docs'), 'deny');
    assert.equal(bash("echo 'x; git commit --amend'"), 'allow');
    // An UNquoted separator still splits.
    assert.equal(bash('echo x && git push --force origin main'), 'deny');
  });

  // [codex-adv-5] regression. maskQuoted ignored backslash escaping, so the
  // escaped quote in `echo \'> out` read as an opening delimiter and swallowed
  // the `>`. A real file write recorded as provably read-only.
  test('an escaped quote cannot hide a redirect', () => {
    assert.equal(bash("echo \\'> out"), 'abstain');
    assert.equal(bash('echo \\"> out'), 'abstain');
    // Inside single quotes a backslash is literal, so the quote still closes.
    assert.equal(bash("echo 'a\\' > /dev/null"), 'allow');
    // Inside double quotes it escapes, so this quote does NOT close.
    assert.notEqual(bash('echo "a\\"b > f"'), 'abstain');
  });

  // [codex-2] regression. The redirect deny matched only a cwd-relative `.git/`,
  // so the absolute and parent-relative forms recorded `abstain` — the
  // documented denial, silently missing.
  test('a redirect into git metadata denies wherever the file lives', () => {
    assert.equal(bash('echo x > /repo/.git/config'), 'deny');
    assert.equal(bash('echo x > ../.git/config'), 'deny');
    assert.equal(bash('echo x > .git/config'), 'deny');
    // The worktree pointer file, same predicate as the file-tool branch.
    assert.equal(bash('echo x > /repo/.git'), 'deny');
    // A file that merely starts with `.git` is an ordinary write.
    assert.equal(bash('echo x > /repo/.gitignore'), 'abstain');
  });

  test('the deny still fires on the real thing in any segment', () => {
    assert.equal(bash('git push --force origin main'), 'deny');
    assert.equal(bash('cd /repo && git push --force origin main'), 'deny');
    assert.equal(bash('/usr/bin/git push --force origin main'), 'deny');
  });

  // [glm-5] regression. `git push origin +main` force-updates the remote with
  // no flag at all, so a flag-only check missed it entirely.
  test('a + refspec is a force push even with no --force flag', () => {
    assert.equal(bash('git push origin +main'), 'deny');
    assert.equal(bash('git push origin +refs/heads/main'), 'deny');
    assert.notEqual(bash('git push origin main'), 'deny');
  });

  // [codex-adv round 2] regression. `allow` claims "provably safe", so it must
  // not drift from the production guard on the same command.
  describe('allow does not drift from auto-approve-safe-bash', () => {
    test('an execution-hijacking env assignment is never allowed', () => {
      assert.equal(bash('LD_PRELOAD=/tmp/evil.so ls'), 'abstain');
      assert.equal(bash('GIT_EXTERNAL_DIFF=/tmp/evil git diff'), 'abstain');
      assert.equal(bash('BASH_ENV=/tmp/evil grep x f'), 'abstain');
      assert.equal(bash('NODE_OPTIONS=--require=/tmp/e git status'), 'abstain');
    });

    test('locale and timezone assignments stay allowed', () => {
      assert.equal(bash('LANG=C git log'), 'allow');
      assert.equal(bash('LC_ALL=C sort f'), 'allow');
      assert.equal(bash('TZ=UTC date'), 'allow');
    });

    test('a write-capable flag on a read-only binary is not a read', () => {
      assert.equal(bash('sort input.txt -o output.txt'), 'abstain');
      assert.equal(bash('find . -name x -delete'), 'abstain');
      assert.equal(bash('find . -exec rm {} ;'), 'abstain');
      assert.equal(bash('xxd -r dump.hex out.bin'), 'abstain');
      assert.equal(bash('file -C -m custom.mgc'), 'abstain');
      // The plain read forms stay allowed.
      assert.equal(bash('sort input.txt'), 'allow');
      assert.equal(bash('find . -name x'), 'allow');
    });
  });
});

// --- 6. outcome correlation + report -----------------------------------------

describe('outcome + report', () => {
  test('pre and post agree on a ref so they can be joined', () => {
    const payload = { session_id: 's1', tool_name: 'Bash', tool_input: { command: 'ls' } };
    const cls = classify('Bash', payload.tool_input);
    assert.equal(refFor(payload, cls), refFor(payload, cls));
    const dir = freshDir();
    runHook(['pre'], JSON.stringify(payload), dir);
    runHook(['post'], JSON.stringify(payload), dir);
    const rows = readAll(path.join(dir, 'ledger.jsonl'));
    assert.equal(rows.length, 2);
    assert.equal(rows[0].ref, rows[1].ref);
    assert.equal(rows[1].actual_verdict, 'executed');
    assert.equal(rows[1].prev_hash, rows[0].hash, 'the outcome extends the chain');
  });

  // [codex-adv] regression. Without tool_use_id, two IDENTICAL calls in one
  // session collapsed onto one ref — and because outcomes are matched as a set,
  // one success marked BOTH executed, hiding a denial behind its twin.
  test('tool_use_id keeps repeated identical calls distinct', () => {
    const base = { session_id: 's1', tool_name: 'Bash', tool_input: { command: 'ls' } };
    const cls = classify('Bash', base.tool_input);
    const a = refFor({ ...base, tool_use_id: 'toolu_a' }, cls);
    const b = refFor({ ...base, tool_use_id: 'toolu_b' }, cls);
    assert.notEqual(a, b, 'distinct calls must not share a ref');
    assert.equal(a, 'toolu_a');
  });

  test('the derived fallback is marked so the ambiguity stays visible', () => {
    const base = { session_id: 's1', tool_name: 'Bash', tool_input: { command: 'ls' } };
    const r = refFor(base, classify('Bash', base.tool_input));
    assert.match(r, /^d:/, 'a derived ref is distinguishable from a real tool_use_id');
  });

  // [codex-1 round 2] regression. Outcomes were matched by SET membership, so
  // one outcome marked every request sharing that ref executed. Refs are shared
  // whenever the harness gives no tool_use_id and the derived fallback applies —
  // exactly the case the unresolved count exists to expose.
  test('one outcome cannot mark TWO same-ref requests executed', () => {
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:01.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:02.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
    ];
    const s = summarize(rows, null, '2026-08-04T00:00:00.000Z');
    assert.equal(s.requests, 2);
    assert.equal(s.executed, 1, 'one outcome means one executed');
    assert.equal(s.unresolved, 1, 'the other stays visible');
  });

  test('two outcomes for two same-ref requests resolve both', () => {
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:01.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:02.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
      { ts: '2026-07-28T00:00:03.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
    ];
    const s = summarize(rows, null, '2026-08-04T00:00:00.000Z');
    assert.equal(s.executed, 2);
    assert.equal(s.unresolved, 0);
  });

  test('one outcome does NOT mark a second identical request executed', () => {
    const dir = freshDir();
    const mk = (id) => JSON.stringify({
      session_id: 's1', tool_use_id: id, tool_name: 'Bash', tool_input: { command: 'ls' },
    });
    runHook(['pre'], mk('toolu_1'), dir);
    runHook(['pre'], mk('toolu_2'), dir);
    runHook(['post'], mk('toolu_1'), dir);   // only the FIRST one ran
    const s = summarize(readAll(path.join(dir, 'ledger.jsonl')));
    assert.equal(s.requests, 2);
    assert.equal(s.executed, 1);
    assert.equal(s.unresolved, 1, 'the un-executed twin must remain visible');
  });

  const WEEK_ROWS = [
    { ts: '2026-07-28T00:00:00.000Z', kind: 'request', ref: 'a', class: 'bash:ls', shadow_verdict: 'allow' },
    { ts: '2026-07-28T00:00:01.000Z', kind: 'outcome', ref: 'a', actual_verdict: 'executed' },
    { ts: '2026-07-29T00:00:00.000Z', kind: 'request', ref: 'b', class: 'bash:node x', shadow_verdict: 'abstain' },
    { ts: '2026-07-29T00:00:02.000Z', kind: 'notification', notification_type: 'permission_prompt' },
    { ts: '2026-08-04T00:00:00.000Z', kind: 'request', ref: 'c', class: 'bash:ls', shadow_verdict: 'allow' },
  ];

  test('the report counts interrupts per week and refuses to guess the rest', () => {
    const s = summarize(WEEK_ROWS, null, '2026-08-04T00:00:00.000Z');
    assert.equal(s.requests, 3);
    assert.equal(s.interrupts, 1);
    assert.equal(s.executed, 1);
    // b and c never produced an outcome row. That is NOT "denied" — it is
    // denied OR stranded OR crashed, and the field name says so.
    assert.equal(s.unresolved, 2);
    assert.equal(s.span_days, 7);
    assert.equal(s.interrupts_per_week, 1);
    assert.deepEqual(s.shadow_verdicts, { allow: 2, deny: 0, abstain: 1 });
    assert.deepEqual(s.top_classes[0], ['bash:ls', 2]);
  });

  test('a sub-day window reports the raw count but REFUSES a weekly rate', () => {
    // A 20-minute sample scaled to a week yields a confident six-figure number
    // that is pure artefact — and this is the figure the programme is gated on.
    const s = summarize([
      { ts: '2026-08-04T08:00:00.000Z', kind: 'request', ref: 'a', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-08-04T08:20:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
    ], null, '2026-08-04T08:20:00.000Z');
    assert.equal(s.interrupts, 1);
    assert.equal(s.interrupts_per_week, null);
  });

  // [codex-1] regression. The window is the OBSERVATION period, not the spread
  // between first and last event. Spread is biased short at both ends and both
  // errors inflate the rate — on the figure the programme is gated on.
  test('the window runs to NOW, not to the last event', () => {
    // Same events, but three quiet days have passed since the last one. The
    // old spread-based span said 7 days and 1/week; the truth is 10 days.
    const s = summarize(WEEK_ROWS, null, '2026-08-07T00:00:00.000Z');
    assert.equal(s.span_days, 10);
    assert.equal(s.interrupts_per_week, 0.7);
  });

  test('a quiet window with clustered events does not report an inflated rate', () => {
    // Two events a minute apart, a week of observation. Spread-based span was
    // ~0.0007 days → 10,080/week. The observation window is what is real.
    const s = summarize([
      { ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
      { ts: '2026-07-28T00:01:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
    ], null, '2026-08-04T00:00:00.000Z');
    assert.equal(s.span_days, 7);
    assert.equal(s.interrupts_per_week, 2);
  });

  test('--days N cannot claim more observation than the ledger holds', () => {
    // Asking for 7 days of a ledger that only started 2 days ago is 2 days of
    // evidence, not 7 — otherwise the rate is silently divided by too much.
    const s = summarize(
      [{ ts: '2026-08-02T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' }],
      '2026-07-28T00:00:00.000Z',
      '2026-08-04T00:00:00.000Z',
    );
    assert.equal(s.span_days, 2);
  });

  // [codex-adv] regression, the most consequential one: Notification does NOT
  // fire only for permission prompts. Counting idle-wait timeouts and
  // elicitation dialogs as approval interrupts inflates the exact number the
  // trust programme is gated on.
  describe('only permission notifications count as interrupts', () => {
    test('classification', () => {
      assert.ok(isApprovalInterrupt('permission_prompt'));
      assert.ok(isApprovalInterrupt('tool_permission'));
      assert.ok(!isApprovalInterrupt('idle_prompt'));
      assert.ok(!isApprovalInterrupt('auth_success'));
      assert.ok(!isApprovalInterrupt('elicitation'));
      assert.ok(!isApprovalInterrupt(null));
    });

    test('the gate number counts only the permission ones', () => {
      const s = summarize([
        { ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
        { ts: '2026-07-30T00:00:00.000Z', kind: 'notification', notification_type: 'idle_prompt' },
        { ts: '2026-08-01T00:00:00.000Z', kind: 'notification', notification_type: 'auth_success' },
      ], null, '2026-08-04T00:00:00.000Z');
      assert.equal(s.notifications, 3);
      assert.equal(s.interrupts, 1, 'idle + auth are not approval pressure');
      assert.equal(s.interrupts_per_week, 1);
    });

    // The safety net on the loose match: an unrecognised vocabulary must be
    // VISIBLE, not silently absent. A hook-side filter would have made a
    // changed type-name read as a genuinely quiet week.
    test('uncounted types are reported by name, never silently dropped', () => {
      const s = summarize([
        { ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'some_new_type' },
        { ts: '2026-07-29T00:00:00.000Z', kind: 'notification', notification_type: 'some_new_type' },
        { ts: '2026-07-30T00:00:00.000Z', kind: 'notification', notification_type: null },
      ], null, '2026-08-04T00:00:00.000Z');
      assert.equal(s.interrupts, 0);
      assert.deepEqual(s.uncounted_notification_types, { some_new_type: 2, '(none)': 1 });
    });

    test('the notify hook records every type, filtering happens at report time', () => {
      const dir = freshDir();
      runHook(['notify'], JSON.stringify({ session_id: 's', notification_type: 'idle_prompt' }), dir);
      const [row] = readAll(path.join(dir, 'ledger.jsonl'));
      assert.equal(row.kind, 'notification');
      assert.equal(row.notification_type, 'idle_prompt', 'recorded, so it can be reclassified later');
    });
  });

  test('report runs on an empty ledger without throwing', () => {
    const r = runHook(['report'], '', freshDir());
    assert.equal(r.status, 0);
    assert.match(r.stdout, /APPROVAL INTERRUPTS 0/);
    assert.match(r.stdout, /no weekly rate yet/);
  });

  test('report --json is machine-readable', () => {
    const dir = freshDir();
    runHook(['pre'], PRE_BASH, dir);
    const r = runHook(['report', '--json'], '', dir);
    assert.equal(r.status, 0);
    assert.equal(JSON.parse(r.stdout).requests, 1);
  });
});

// --- HIMMEL-1539: the recorder can say when it recorded NOTHING ---------------
//
// All three gaps this block covers failed in the SAME direction — the gate
// number came out understated with nothing to signal it — which is the one
// failure mode HIMMEL-1529's own README argues is worse than having no
// instrument at all, because the number still looks like a number.

describe('dropped writes are visible, not silent', () => {
  test('lock exhaustion records a drop instead of losing the event silently', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    // A lock held by a LIVE pid with a FRESH stamp: breakStaleLock must not
    // reclaim it, so withLock burns its retries and gives the record up.
    fs.writeFileSync(path.join(dir, '.ledger.lock'), `${process.pid} ${Date.now()}`);

    const result = append({ ts: 'a', kind: 'request' });
    assert.equal(result, null, 'the append is given up — fail-open, never block');

    const drops = readDrops(path.join(dir, 'drops.jsonl'));
    assert.equal(drops.length, 1, 'and the loss is RECORDED');
    assert.equal(drops[0].reason, 'lock_exhausted');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  test('a failed append records a drop rather than being swallowed by fail-open', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    fs.mkdirSync(dir, { recursive: true });
    // A directory where the ledger file belongs: every write to it throws.
    // Previously the exception reached the top-level fail-open handler, which
    // exited 0 and said nothing — correct for the tool call, silent for the
    // measurement.
    fs.mkdirSync(path.join(dir, 'ledger.jsonl'), { recursive: true });

    const result = append({ ts: 'a', kind: 'request' });
    assert.equal(result, null);

    const drops = readDrops(path.join(dir, 'drops.jsonl'));
    assert.equal(drops.length, 1);
    assert.equal(drops[0].reason, 'append_failed');
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });

  test('a window with dropped writes publishes NO rate', () => {
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
    ];
    const intact = { intact: true, malformed: 0, torn: 0, brokenLinks: 0 };
    const clean = summarize(rows, null, '2026-08-04T00:00:00.000Z', intact, []);
    assert.equal(clean.interrupts_per_week, 1, 'a clean window still reports a rate');

    const dropped = summarize(rows, null, '2026-08-04T00:00:00.000Z', intact, [
      { ts: '2026-07-30T00:00:00.000Z', reason: 'lock_exhausted' },
    ]);
    assert.equal(dropped.interrupts, 1, 'the raw count is still shown');
    assert.equal(dropped.dropped_writes, 1);
    assert.equal(
      dropped.interrupts_per_week, null,
      'the chain validates the rows that LANDED; it cannot attest the ones that never did',
    );
  });

  test('an unparseable drop row still counts as a drop', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    const f = path.join(dir, 'drops.jsonl');
    fs.writeFileSync(f, '{"ts":"2026-08-01T00:00:00.000Z","reason":"lock_exhausted"}\n{"tor\n');
    const drops = readDrops(f);
    assert.equal(drops.length, 2, 'discarding it would restore the exact blindness this removes');
    assert.equal(drops[1].ts, null);
    // Drops are not expired by timestamp at all (round 6), so BOTH count —
    // the readable one and the one whose row could not be parsed.
    const s = summarize([], '2026-08-04T00:00:00.000Z', '2026-08-05T00:00:00.000Z', null, drops);
    assert.equal(s.dropped_writes, 2, 'a recorded loss counts regardless of what its ts claims');
  });

  // [codex-adv round 5] A truthy-but-unusable `ts` defeated the window filter:
  // {"ts":123} is valid JSON, so readDrops kept it verbatim, `!d.ts` was false,
  // and `123 >= "2026-..."` compared false — excluding a KNOWN recorder failure
  // and restoring the rate it was supposed to suppress.
  test('a malformed drop timestamp cannot restore a suppressed rate', () => {
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
    ];
    const intact = { intact: true, malformed: 0, torn: 0, brokenLinks: 0 };
    for (const badTs of [123, null, undefined, {}, 'not-a-date', '']) {
      const s = summarize(rows, '2026-07-01T00:00:00.000Z', '2026-08-04T00:00:00.000Z', intact,
        [{ ts: badTs, reason: 'append_failed' }]);
      assert.equal(s.dropped_writes, 1, `ts=${JSON.stringify(badTs)} must still count`);
      assert.equal(s.interrupts_per_week, null, `ts=${JSON.stringify(badTs)} must suppress the rate`);
    }
  });

  // [codex-adv round 6] `null`, `42` and `"x"` are all valid JSON. Every
  // consumer dereferences `.kind`, so an unvalidated row threw a TypeError that
  // the fail-open handler turned into exit 0 with EMPTY stdout — corruption
  // producing neither a report nor a warning.
  test('a valid-JSON non-object row is damage, not a crash', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    const f = path.join(dir, 'ledger.jsonl');
    fs.writeFileSync(f, 'null\n42\n"x"\n[1,2]\n');
    const led = readLedger(f);
    assert.equal(led.records.length, 0);
    assert.equal(led.malformed, 4, 'each unusable shape is counted');
    assert.equal(led.intact, false);
  });

  test('report still produces output over a corrupted ledger', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ledger.jsonl'), 'null\n');
    const r = runHook(['report'], '', dir);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /shadow ledger/, 'corruption must not yield silent empty output');
    assert.match(r.stdout, /INTEGRITY/);
  });

  // [CodeRabbit App] process.exit() can truncate a pending stdout write when
  // stdout is a pipe — which is how report is always read. A truncated report
  // is the same silence rounds 6 and 7 closed, reached by another route.
  test('a LARGE report survives the pipe intact', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    // Enough distinct classes to push the report well past a pipe buffer's
    // first chunk, so a truncating exit would visibly cut the tail off.
    for (let i = 0; i < 400; i++) {
      runHook(['pre'], JSON.stringify({
        session_id: 's1', tool_use_id: `t${i}`, tool_name: 'Bash',
        tool_input: { command: `echo case-${i}` },
      }), dir);
    }
    const r = runHook(['report'], '', dir);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /shadow ledger/, 'the head is present');
    // The NOTE block is the last thing printed before the class table, so its
    // presence proves the tail was not cut off.
    assert.match(r.stdout, /gate number is APPROVAL INTERRUPTS per week/, 'the tail survived');
    assert.match(r.stdout, /requests recorded 400/);
  });

  test('report FAILS LOUDLY rather than exiting 0 with nothing', () => {
    // Fail-open is a HOOK contract; `report` is the operator reading the
    // instrument. A directory where the ledger belongs makes readLedger flag
    // it unreadable, which must still print — never a silent exit 0.
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    fs.mkdirSync(path.join(dir, 'ledger.jsonl'), { recursive: true });
    const r = runHook(['report'], '', dir);
    assert.equal(r.status, 0);
    assert.notEqual(r.stdout.trim(), '', 'silence is the one answer this file must not give');
  });

  // [codex-adv round 6] Drops are no longer expired by timestamp AT ALL. A
  // backward clock step across the cutoff re-dated an in-window failure as old,
  // producing dropped_writes=0 and a confident rate over known-missing events.
  // There is no durable proof a drop predates a window, so a recorded drop
  // suppresses until an operator acknowledges it by rotating drops.jsonl.
  test('a drop does not expire on wall-clock, however old it looks', () => {
    const rows = [
      { ts: '2026-08-02T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
    ];
    const intact = { intact: true, malformed: 0, torn: 0, brokenLinks: 0 };
    const s = summarize(rows, '2026-08-01T00:00:00.000Z', '2026-08-04T00:00:00.000Z', intact,
      [{ ts: '2026-07-01T00:00:00.000Z', reason: 'append_failed' }]);
    assert.equal(s.dropped_writes, 1);
    assert.equal(s.interrupts_per_week, null, 'a clock cannot be trusted to expire a known loss');
  });

  // [codex-adv round 7] Round 6 documented "rotate drops.jsonl to acknowledge",
  // which LAUNDERS the loss: the missing event is still absent from the window,
  // but the rate returns. Reproduced — null with a drop, 0/week immediately
  // after rotation. There is now deliberately no acknowledgement path that
  // restores a rate; doing it honestly needs HIMMEL-1547's checkpoint.
  test('the report does not offer a recovery that launders the loss', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'drops.jsonl'),
      '{"ts":"2026-08-01T00:00:00.000Z","reason":"append_failed"}\n');
    const r = runHook(['report'], '', dir);
    assert.match(r.stdout, /Drops do NOT/);
    assert.match(r.stdout, /HIMMEL-1547/);
    assert.doesNotMatch(r.stdout, /acknowledge them by rotating/);
  });

  test('report names the drop channel instead of implying a floor is a measurement', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'drops.jsonl'),
      '{"ts":"2026-08-01T00:00:00.000Z","reason":"append_failed"}\n',
    );
    const r = runHook(['report'], '', dir);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /DROPPED WRITES/);
    assert.match(r.stdout, /no rate published/);
  });

  // [codex-adv round 1, high] recordDrop writes beside the ledger, so a
  // volume-wide failure can lose the ledger event AND its drop row together.
  // That residual is documented, not claimed away. What IS fixed: a health
  // channel that exists but cannot be READ must not read as "no drops".
  test('an UNREADABLE health channel counts as a drop, never as clean', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    // A directory where drops.jsonl belongs: readFileSync throws EISDIR, not
    // ENOENT — i.e. the channel exists but cannot be read.
    fs.mkdirSync(path.join(dir, 'drops.jsonl'), { recursive: true });
    const drops = readDrops(path.join(dir, 'drops.jsonl'));
    assert.equal(drops.length, 1);
    assert.equal(drops[0].reason, 'health_channel_unreadable');

    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'notification', notification_type: 'permission_prompt' },
    ];
    const intact = { intact: true, malformed: 0, torn: 0, brokenLinks: 0 };
    const s = summarize(rows, null, '2026-08-04T00:00:00.000Z', intact, drops);
    assert.equal(s.interrupts_per_week, null, 'unknown must not present as clean');
    assert.equal(s.health_channel_unreadable, true);
  });

  test('a MISSING health channel is the ordinary healthy case', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    // ENOENT means no drop has ever been recorded — that is genuinely clean,
    // and must NOT suppress the rate or the gate becomes unusable.
    assert.deepEqual(readDrops(path.join(dir, 'drops.jsonl')), []);
  });

  test('an unreadable LEDGER does not read as an empty intact one', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    fs.mkdirSync(path.join(dir, 'ledger.jsonl'), { recursive: true });
    const led = readLedger(path.join(dir, 'ledger.jsonl'));
    assert.equal(led.intact, false, 'cannot-read is unknown, not clean');
    // [glm round 4] An unopenable FILE is not an unparseable ROW. Counting it
    // as malformed suppressed the rate correctly but printed "1 unreadable
    // row(s)" over a file with zero rows — a true verdict via a false claim.
    assert.equal(led.unreadable, true);
    assert.equal(led.malformed, 0, 'there are no rows to be malformed');
  });

  test('the report distinguishes an unreadable FILE from unparseable ROWS', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    fs.mkdirSync(path.join(dir, 'ledger.jsonl'), { recursive: true });
    const r = runHook(['report'], '', dir);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /could not be read/);
    assert.doesNotMatch(r.stdout, /unparseable row/);
  });

  test('a ledger that does not exist yet IS intact', () => {
    const dir = freshDir();
    fs.mkdirSync(dir, { recursive: true });
    const led = readLedger(path.join(dir, 'ledger.jsonl'));
    assert.equal(led.intact, true);
    assert.deepEqual(led.records, []);
  });

  test('healthPath is a different file from the ledger', () => {
    const dir = freshDir();
    process.env.HIMMEL_TRUST_LEDGER_DIR = dir;
    // The drop channel must not share the ledger's lock or its chain: the events
    // it records are precisely the ones the ledger could not record.
    assert.notEqual(healthPath(), path.join(dir, 'ledger.jsonl'));
    process.env.HIMMEL_TRUST_LEDGER_DIR = TMP;
  });
});

describe('failed and denied calls get a terminal outcome', () => {
  const CALL = JSON.stringify({
    session_id: 's1',
    tool_use_id: 'toolu_x',
    tool_name: 'Bash',
    tool_input: { command: 'ls' },
  });

  test('PostToolUseFailure records executed_failed, not a silent unresolved', () => {
    const dir = freshDir();
    runHook(['pre'], CALL, dir);
    runHook(['postfail'], CALL, dir);
    const rows = readAll(path.join(dir, 'ledger.jsonl'));
    assert.equal(rows.length, 2);
    assert.equal(rows[1].actual_verdict, 'executed_failed');
    assert.equal(rows[1].prev_hash, rows[0].hash, 'the outcome extends the chain');

    const s = summarize(rows);
    assert.equal(s.executed_failed, 1);
    assert.equal(s.unresolved, 0, 'a call that ran and failed is RESOLVED');
    assert.equal(s.executed, 0, 'and it is not counted as a success');
  });

  test('PermissionDenied records an AUTO-CLASSIFIER-scoped denial', () => {
    const dir = freshDir();
    runHook(['pre'], CALL, dir);
    runHook(['denied'], CALL, dir);
    const rows = readAll(path.join(dir, 'ledger.jsonl'));
    // [codex-adv round 1] The hook reference is explicit that PermissionDenied
    // fires only "when a tool call is denied by the auto mode classifier" —
    // manual denials, deny rules and PreToolUse blocks do NOT raise it. The
    // verdict is named for what it actually observes; a plain `denied` would
    // read as complete denial coverage, which is the exact failure class this
    // ticket exists to remove.
    assert.equal(rows[1].actual_verdict, 'denied_auto_classifier');
    const s = summarize(rows);
    assert.equal(s.denied_auto_classifier, 1);
    assert.equal(s.unresolved, 0);
  });

  test('the report does not claim denial coverage it does not have', () => {
    const dir = freshDir();
    runHook(['pre'], CALL, dir);
    runHook(['denied'], CALL, dir);
    const r = runHook(['report'], '', dir);
    assert.match(r.stdout, /AUTO-MODE CLASSIFIER denials ONLY/);
    assert.match(r.stdout, /manual denials, deny rules and PreToolUse blocks do NOT appear here/);
  });

  test('failures and denials no longer collapse into one bucket', () => {
    // The defect: with only PostToolUse wired, BOTH of these landed in
    // `unresolved` alongside genuine strands, so actual_verdict data was
    // corrupted by construction — a failure is not an approval interrupt and a
    // denial is.
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'request', ref: 'a', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:01.000Z', kind: 'request', ref: 'b', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:02.000Z', kind: 'request', ref: 'c', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:03.000Z', kind: 'outcome', ref: 'a', actual_verdict: 'executed' },
      { ts: '2026-07-28T00:00:04.000Z', kind: 'outcome', ref: 'b', actual_verdict: 'executed_failed' },
      { ts: '2026-07-28T00:00:05.000Z', kind: 'outcome', ref: 'c', actual_verdict: 'denied_auto_classifier' },
    ];
    const s = summarize(rows, null, '2026-08-04T00:00:00.000Z');
    assert.deepEqual(
      { e: s.executed, f: s.executed_failed, d: s.denied_auto_classifier, u: s.unresolved },
      { e: 1, f: 1, d: 1, u: 0 },
    );
  });

  test('an UNRECOGNISED verdict surfaces as other, never as executed', () => {
    // Same rule as uncounted_notification_types: a vocabulary this file does not
    // control must show up by name rather than vanish into the flattering bucket.
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'request', ref: 'a', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:01.000Z', kind: 'outcome', ref: 'a', actual_verdict: 'teleported' },
    ];
    const s = summarize(rows, null, '2026-08-04T00:00:00.000Z');
    assert.equal(s.executed, 0);
    assert.equal(s.outcome_other, 1);
    assert.equal(s.unresolved, 0, 'it IS resolved — just not by a verdict we know');
  });

  test('the outcome verdict is consumed per request, not shared across a ref', () => {
    // The per-ref budget still holds under verdict-bearing outcomes: two
    // same-ref requests with one denial are one denied and one unresolved.
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:01.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-28T00:00:02.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'denied_auto_classifier' },
    ];
    const s = summarize(rows, null, '2026-08-04T00:00:00.000Z');
    assert.equal(s.denied_auto_classifier, 1);
    assert.equal(s.unresolved, 1);
  });

  // [codex-adv round 2] A `--days` cutoff that slices between a request and its
  // outcome leaves an ORPHAN outcome inside the window. Before this fix a later
  // request sharing the derived `d:` ref consumed it — codex's reproduction
  // returned executed=1/unresolved=0 for a request that never ran.
  test('an orphan outcome cannot resolve a LATER request', () => {
    const rows = [
      // The earlier call's request is outside the window; only its outcome is in.
      { ts: '2026-07-30T00:00:00.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
      // A later, identical call that never produced an outcome of its own.
      { ts: '2026-07-31T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
    ];
    const s = summarize(rows, '2026-07-29T00:00:00.000Z', '2026-08-05T00:00:00.000Z');
    assert.equal(s.requests, 1);
    assert.equal(s.executed, 0, 'an outcome that PRECEDES a request is not its outcome');
    assert.equal(s.unresolved, 1, 'the un-executed request must stay visible');
  });

  // [codex-adv round 3] Wall-clock does not prove ordering. Row position does —
  // the ledger is append-only and hash-chained. These are the two boundaries
  // where a `ts` comparison broke, both measured on the previous fix.
  test('an EQUAL timestamp does not let an orphan outcome be consumed', () => {
    const rows = [
      { ts: '2026-07-31T00:00:00.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
      { ts: '2026-07-31T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
    ];
    const s = summarize(rows, null, '2026-08-05T00:00:00.000Z');
    assert.equal(s.executed, 0, 'the outcome sits EARLIER in the ledger; it cannot be this request\'s');
    assert.equal(s.unresolved, 1);
  });

  test('a BACKWARD clock adjustment does not lose a real outcome', () => {
    const rows = [
      { ts: '2026-07-31T00:00:00.002Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      // Physically after the request, but stamped 1 ms earlier by a clock step.
      { ts: '2026-07-31T00:00:00.001Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
    ];
    const s = summarize(rows, null, '2026-08-05T00:00:00.000Z');
    assert.equal(s.executed, 1, 'row position says it followed, and row position is the truth');
    assert.equal(s.unresolved, 0);
  });

  // [codex-adv round 4] Correlation must run over the FULL history, with the
  // window applied to the RESULTS. Filtering requests first left the pre-cutoff
  // request's outcome unclaimed, and the in-window request sharing its derived
  // ref consumed it — reporting an execution that request never had.
  test('an outcome belonging to a PRE-CUTOFF request cannot be stolen', () => {
    const rows = [
      // Owner, before the cutoff.
      { ts: '2026-07-20T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      // A new request after the cutoff, sharing the derived ref.
      { ts: '2026-08-01T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      // The FIRST request's outcome, landing after the second request started.
      { ts: '2026-08-02T00:00:00.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
    ];
    const s = summarize(rows, '2026-07-30T00:00:00.000Z', '2026-08-05T00:00:00.000Z');
    assert.equal(s.requests, 1, 'only the post-cutoff request is counted');
    assert.equal(s.executed, 0, 'its predecessor claimed that outcome');
    assert.equal(s.unresolved, 1);
  });

  test('an outcome outside the window still resolves an in-window request', () => {
    // Outcomes are deliberately NOT window-filtered: a request just inside the
    // cutoff must still be resolvable by its own outcome.
    const rows = [
      { ts: '2026-07-31T00:00:00.000Z', kind: 'request', ref: 'r1', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-08-01T00:00:00.000Z', kind: 'outcome', ref: 'r1', actual_verdict: 'executed' },
    ];
    const s = summarize(rows, '2026-07-30T00:00:00.000Z', '2026-08-05T00:00:00.000Z');
    assert.equal(s.executed, 1);
    assert.equal(s.unresolved, 0);
  });

  test('an outcome that follows its request still resolves it', () => {
    // The guard must not over-correct: ordinary same-ref pairs still match.
    const rows = [
      { ts: '2026-07-31T00:00:00.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-31T00:00:01.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'executed' },
      { ts: '2026-07-31T00:00:02.000Z', kind: 'request', ref: 'd:same', class: 'bash:ls', shadow_verdict: 'allow' },
      { ts: '2026-07-31T00:00:03.000Z', kind: 'outcome', ref: 'd:same', actual_verdict: 'denied_auto_classifier' },
    ];
    const s = summarize(rows, null, '2026-08-05T00:00:00.000Z');
    assert.equal(s.executed, 1);
    assert.equal(s.denied_auto_classifier, 1);
    assert.equal(s.unresolved, 0);
  });

  test('the failure and denial hooks still never emit a permission decision', () => {
    const dir = freshDir();
    for (const verb of ['postfail', 'denied', 'permreq']) {
      const r = runHook([verb], CALL, dir);
      assert.equal(r.status, 0, `${verb} exits 0`);
      assert.equal(r.stdout.trim(), '', `${verb} writes nothing to stdout`);
    }
  });
});

describe('PermissionRequest is an EVENT count, not an interrupt count', () => {
  test('it is recorded and counted separately from the Notification proxy', () => {
    const dir = freshDir();
    runHook(['permreq'], JSON.stringify({ session_id: 's1', tool_name: 'Bash' }), dir);
    runHook(['notify'], JSON.stringify({ session_id: 's1', notification_type: 'permission_prompt' }), dir);
    const s = summarize(readAll(path.join(dir, 'ledger.jsonl')));
    assert.equal(s.permission_request_events, 1, 'the event count');
    assert.equal(s.interrupts, 1, 'the Notification-derived count, kept independent');
  });

  // [codex-adv round 2] The event fires when a decision is NEEDED, which is not
  // the same as a human being interrupted — W0 probe P5 measured an `ask`
  // hanging 902 s in an armed session with nobody present to answer. Labelling
  // the count a direct interrupt observation would inflate the gate number
  // precisely in the unattended runs this harness does most.
  test('the report does not claim these are human interruptions', () => {
    const dir = freshDir();
    runHook(['permreq'], JSON.stringify({ session_id: 's1', tool_name: 'Bash' }), dir);
    const r = runHook(['report'], '', dir);
    assert.match(r.stdout, /permission-request events/);
    assert.match(r.stdout, /NOT proof anyone was interrupted/);
  });

  test('permission_mode is persisted but not interpreted', () => {
    const dir = freshDir();
    runHook(['permreq'], JSON.stringify({
      session_id: 's1', tool_name: 'Bash', permission_mode: 'auto',
    }), dir);
    const rows = readAll(path.join(dir, 'ledger.jsonl'));
    // Stored as the only interactivity-adjacent signal on the payload. No count
    // splits on it yet — that would claim a distinction not yet demonstrated.
    assert.equal(rows[0].permission_mode, 'auto');
  });

  test('it does NOT silently become the gate number', () => {
    // Two independent estimators of one quantity are how you find out which is
    // right. Swapping the gate metric onto the new surface would replace a
    // measured number with an unvalidated one and destroy the comparison.
    const rows = [
      { ts: '2026-07-28T00:00:00.000Z', kind: 'permission_request', tool: 'Bash' },
      { ts: '2026-07-29T00:00:00.000Z', kind: 'permission_request', tool: 'Bash' },
    ];
    const s = summarize(rows, null, '2026-08-04T00:00:00.000Z');
    assert.equal(s.permission_request_events, 2);
    assert.equal(s.interrupts, 0, 'interrupts still counts Notification rows only');
    assert.equal(s.interrupts_per_week, 0);
  });

  test('an interrupt on a non-recorded tool is still an interrupt', () => {
    // No RECORDED_TOOLS filter: the row carries no request payload to classify,
    // and an approval interrupt counts whatever tool raised it.
    const dir = freshDir();
    runHook(['permreq'], JSON.stringify({ session_id: 's1', tool_name: 'WebFetch' }), dir);
    const rows = readAll(path.join(dir, 'ledger.jsonl'));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].kind, 'permission_request');
    assert.equal(rows[0].tool, 'WebFetch');
  });
});
