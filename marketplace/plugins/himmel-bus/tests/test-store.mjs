import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, chmod, symlink, mkdir, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import * as primitive from '../../../../scripts/telegram/bus.ts';

const storeUrl = new URL('../lib/store.mjs', import.meta.url);
async function fixture(t) {
  const state = await mkdtemp(join(tmpdir(), 'bus-store-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const store = await import(storeUrl);
  const root = await store.busRoot({ stateHome: state });
  return { store, root, state };
}
const message = (b = 'hello') => ({ i: 'id', t: 1, f: 'console', r: 'leg', c: 1, b });

test('plain node exposes the new bridge primitives and loads store', async () => {
  assert.equal(typeof primitive.appendChained, 'function');
  assert.equal(typeof primitive.readPast, 'function');
  assert.equal(typeof primitive.commitCursor, 'function');
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(storeUrl.href)})`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});

test('readPast twice without commit returns identical records and byte cursors', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message('héllo'));
  const file = join(root, 'log/leg.jsonl');
  const cur = { k: 0, off: 0, n: 0, h: '' };
  const a = await primitive.readPast(file, cur);
  assert.deepEqual(await primitive.readPast(file, cur), a);
  assert.equal(a.records[0].n, 1);
  assert.equal(a.next.off, Buffer.byteLength(await readFile(file)));
  await primitive.commitCursor(join(root, 'cur/leg'), a.next);
  assert.deepEqual((await primitive.readPast(file, a.next)).records, []);
});

test('T6.1 edited record halts at the break, emits notice once, and does not commit delivery', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  const file = join(root, 'log/leg.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('hello', 'jello'));
  const first = await store.read(root, 'leg');
  assert.deepEqual(first.records, []);
  assert.equal(first.next.halted, 1);
  assert.match(first.notice, /chain broken at #1/);
  assert.equal((await store.read(root, 'leg')).notice, undefined);
  assert.equal((await store.read(root, 'leg')).next.n, 0);
});

test('T6.2 truncation below committed offset halts instead of replaying', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  const got = await store.read(root, 'leg');
  await store.commit(root, 'leg', got.next);
  await writeFile(join(root, 'log/leg.jsonl'), '');
  const broken = await store.read(root, 'leg');
  assert.deepEqual(broken.records, []);
  assert.equal(broken.next.halted, 2);
});

test('T6.3 root symlink and permissive root are refused', async t => {
  const { store, root, state } = await fixture(t);
  await chmod(root, 0o755);
  await assert.rejects(store.busRoot({ stateHome: state }), /permission/);
  await chmod(root, 0o700);
  const alias = join(state, 'alias');
  await symlink(join(state, 'himmel'), alias);
  await assert.rejects(store.busRoot({ stateHome: alias }), /symlink/);
});

test('T6.3 log symlink is refused without touching its target', async t => {
  const { store, root, state } = await fixture(t);
  const victim = join(state, 'victim');
  await writeFile(victim, 'untouched', { mode: 0o600 });
  await symlink(victim, join(root, 'log/leg.jsonl'));
  await assert.rejects(store.append(root, 'leg', message()));
  assert.equal(await readFile(victim, 'utf8'), 'untouched');
});

test('T6.4 chain crosses rotated compressed segments from a committed hash', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  const first = await store.read(root, 'leg');
  await store.commit(root, 'leg', first.next);
  for (let i = 0; i < 6; i++) await store.append(root, 'leg', message('x'.repeat(64000)));
  assert.ok((await readdir(join(root, 'log'))).some(n => /\.jsonl\.(zst|gz)$/.test(n)));
  const got = await store.read(root, 'leg');
  assert.deepEqual(got.records.map(r => r.n), [2, 3, 4, 5, 6, 7]);
  assert.equal(got.next.n, 7);
  assert.equal(got.next.halted, undefined);
});

test('T6.5 halted log refuses new sends and exposes no pending wake', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  const file = join(root, 'log/leg.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('hello', 'jello'));
  await store.read(root, 'leg');
  await assert.rejects(store.append(root, 'leg', message('again')), /halted/);
  assert.equal(await store.pending(root, 'leg'), false);
});

test('T7.1 state home inside a git work tree is refused', async t => {
  const state = await mkdtemp(join(tmpdir(), 'bus-git-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  await mkdir(join(state, '.git'));
  const store = await import(storeUrl);
  await assert.rejects(store.busRoot({ stateHome: state }), /work tree/);
});

test('concurrent writers stamp unique consecutive sequence numbers', async t => {
  const { store, root } = await fixture(t);
  await Promise.all(Array.from({ length: 12 }, (_, i) => store.append(root, 'leg', message(String(i)))));
  const got = await store.read(root, 'leg');
  assert.deepEqual(got.records.map(r => r.n), Array.from({ length: 12 }, (_, i) => i + 1));
});

test('a later chain break never commits earlier un-emitted records', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message('first'));
  await store.append(root, 'leg', message('second'));
  const file = join(root, 'log/leg.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('second', 'tamper'));
  const got = await store.read(root, 'leg');
  const persisted = JSON.parse(await readFile(join(root, 'cur/leg'), 'utf8'));
  assert.equal(persisted.n, 0);
  assert.equal(persisted.off, 0);
  assert.equal(persisted.halted, 2);
  assert.deepEqual(got.records, []);
});

test('permissions are rechecked on the bus parent after startup', async t => {
  const { store, root, state } = await fixture(t);
  await chmod(join(state, 'himmel'), 0o755);
  await assert.rejects(store.append(root, 'leg', message()), /permission/);
});

test('cursor commit refuses a symlink and preserves its target', async t => {
  const { store, root, state } = await fixture(t);
  const target = join(state, 'cursor-target');
  await writeFile(target, 'untouched', { mode: 0o600 });
  await symlink(target, join(root, 'cur/leg'));
  await assert.rejects(store.commit(root, 'leg', { k: 0, off: 0, n: 0, h: '' }));
  assert.equal(await readFile(target, 'utf8'), 'untouched');
});

test('withChainLock owns the named lock inode, not a relative filename', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'bus-lock-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const lock = join(dir, 'lock');
  await primitive.withChainLock(lock, async () => {
    const contender = spawnSync('flock', ['-n', lock, 'true']);
    assert.equal(contender.status, 1);
  });
  assert.equal(spawnSync('flock', ['-n', lock, 'true']).status, 0);
});

test('CR codex-1 stale delivery commit cannot clear a persisted halt', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  const before = await store.read(root, 'leg');
  const file = join(root, 'log/leg.jsonl');
  await writeFile(file, (await readFile(file, 'utf8')).replace('hello', 'jello'));
  await store.read(root, 'leg');
  await assert.rejects(store.commit(root, 'leg', before.next), /halted|stale/);
  assert.equal(JSON.parse(await readFile(join(root, 'cur/leg'), 'utf8')).halted, 1);
  await assert.rejects(store.append(root, 'leg', message()), /halted/);
});

test('CR codex-1 delivery commits cannot move an already committed cursor backwards', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  const first = await store.read(root, 'leg');
  await store.append(root, 'leg', message('second'));
  const second = await store.read(root, 'leg');
  await store.commit(root, 'leg', second.next);
  await assert.rejects(store.commit(root, 'leg', first.next), /stale/);
  assert.equal(JSON.parse(await readFile(join(root, 'cur/leg'), 'utf8')).n, 2);
});

test('CR codex-2 pending serializes with a recipient writer lock', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  let waiting;
  await primitive.withChainLock(join(root, 'lock/leg'), async () => {
    let finished = false;
    waiting = store.pending(root, 'leg').then(value => { finished = true; return value; });
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(finished, false);
  });
  assert.equal(await waiting, true);
});

test('CR codex-3 pending wakes on a truncated or missing committed log', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message());
  await store.commit(root, 'leg', (await store.read(root, 'leg')).next);
  const file = join(root, 'log/leg.jsonl');
  await writeFile(file, '');
  assert.equal(await store.pending(root, 'leg'), true);
  await rm(file);
  assert.equal(await store.pending(root, 'leg'), true);
});

test('CR codex-4 a malformed later record reports its actual sequence', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message('first'));
  await store.append(root, 'leg', message('second'));
  const file = join(root, 'log/leg.jsonl');
  const lines = (await readFile(file, 'utf8')).trimEnd().split('\n');
  await writeFile(file, lines[0] + '\n{malformed}\n');
  const got = await store.read(root, 'leg');
  assert.equal(got.next.halted, 2);
  assert.deepEqual(got.records, []);
  assert.equal(got.next.n, 0);
});

test('a torn undelivered tail halts once rather than leaving a perpetual wake', async t => {
  const { store, root } = await fixture(t);
  await store.append(root, 'leg', message('first'));
  await store.append(root, 'leg', message('second'));
  const file = join(root, 'log/leg.jsonl');
  const lines = (await readFile(file, 'utf8')).trimEnd().split('\n');
  await writeFile(file, lines[0] + '\n' + lines[1].slice(0, -5));
  assert.equal(await store.pending(root, 'leg'), true);
  const got = await store.read(root, 'leg');
  assert.equal(got.next.halted, 2);
  assert.deepEqual(got.records, []);
  assert.equal(await store.pending(root, 'leg'), false);
});

test('CR round-2 codex-2 append refuses missing or truncated committed live bytes', async t => {
  for (const missing of [true, false]) {
    const { store, root } = await fixture(t);
    await store.append(root, 'leg', message());
    await store.commit(root, 'leg', (await store.read(root, 'leg')).next);
    const file = join(root, 'log/leg.jsonl');
    if (missing) await rm(file); else await writeFile(file, '');
    await assert.rejects(store.append(root, 'leg', message('again')), /committed.*missing|truncated/);
    if (missing) await assert.rejects(readFile(file), { code: 'ENOENT' });
    else assert.equal(await readFile(file, 'utf8'), '');
    const broken = await store.read(root, 'leg');
    assert.equal(broken.next.halted, 2);
    assert.deepEqual(broken.records, []);
  }
});

test('appendChained never recreates a missing log', async t => {
  assert.equal(typeof primitive.appendChained, 'function');
  const dir = await mkdtemp(join(tmpdir(), 'bus-missing-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await assert.rejects(primitive.appendChained(join(dir, 'missing'), message(), join(dir, 'lock')), /ENOENT/);
  assert.deepEqual(await readdir(dir), ['lock']);
});
