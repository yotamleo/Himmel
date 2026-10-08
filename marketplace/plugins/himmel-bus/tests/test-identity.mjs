import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';

const store = await import(new URL('../lib/store.mjs', import.meta.url));
const identity = await import(new URL('../lib/identity.mjs', import.meta.url));
const edges = await import(new URL('../lib/edges.mjs', import.meta.url));
const cli = new URL('../bin/bus', import.meta.url).pathname;

async function fixture(t) {
  const state = await mkdtemp(join(tmpdir(), 'bus-identity-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const root = await store.busRoot({ stateHome: state });
  return { root, state };
}

// A fake /proc: procs = [{ pid, ppid, comm, start }]. claude is the exe basename.
async function fakeProc(t, procs) {
  const proc = await mkdtemp(join(tmpdir(), 'bus-proc-'));
  t.after(() => rm(proc, { recursive: true, force: true }));
  for (const p of procs) {
    await mkdir(join(proc, String(p.pid)));
    const rest = Array(17).fill(0).join(' ');
    await writeFile(join(proc, String(p.pid), 'stat'), `${p.pid} (${p.comm}) S ${p.ppid} ${rest} ${p.start} 0 0\n`);
    await symlink(`/usr/bin/${p.comm}`, join(proc, String(p.pid), 'exe'));
  }
  return proc;
}
const P = (pid, ppid, comm, start) => ({ pid, ppid, comm, start });

// claude(console) -> bash -> konsole -> claude(leg) -> server
const chain = [P(1, 0, 'init', 1), P(100, 1, 'claude', 1000), P(101, 100, 'bash', 1001), P(102, 101, 'konsole', 1002),
  P(200, 102, 'claude', 2000), P(300, 200, 'node', 3000)];

async function bound(root, proc) {
  await identity.register(root, 'con', { role: 'console' });
  await identity.register(root, 'leg', { role: 'leg', console: 'con' });
  await identity.bind(root, 'con', 100, { proc });
  await identity.bind(root, 'leg', 200, { proc });
}

test('T1.1 nearest claude ancestor stamps the leg, not the console', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 300 }), { name: 'leg' });
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 101 }), { name: 'con' });
});

test('T1.2 nested unbound claude under a bound leg is unbound', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, [...chain, P(400, 200, 'claude', 4000), P(500, 400, 'node', 5000)]);
  await bound(root, proc);
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 500 }), { error: 'identity unbound' });
});

test('T1.3 second bind and re-register are refused', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  await assert.rejects(identity.bind(root, 'leg', 100, { proc }), /already bound/);
  await assert.rejects(identity.register(root, 'leg', { role: 'leg', console: 'con' }), /already registered/);
  assert.deepEqual(await identity.resolveIdentity(root, { proc, pid: 300 }), { name: 'leg' });
});

test('T1.4 pid reuse (same pid, different start time) is unbound', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  const reused = await fakeProc(t, chain.map(p => p.pid === 200 ? { ...p, start: 9999 } : p));
  assert.deepEqual(await identity.resolveIdentity(root, { proc: reused, pid: 300 }), { error: 'identity unbound' });
  assert.equal(await identity.status(root, 'leg', { proc: reused }), 'gone');
  assert.equal(await identity.status(root, 'leg', { proc }), 'live');
});

test('T5.2 refused send lists only the caller own edges, never another console', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'conA', { role: 'console' });
  await identity.register(root, 'conB', { role: 'console' });
  await identity.register(root, 'legA', { role: 'leg', console: 'conA' });
  await identity.register(root, 'judgeA', { role: 'judge', console: 'conA', pair: 'legA' });
  await identity.register(root, 'legB', { role: 'leg', console: 'conB' });
  const peers = await identity.loadPeers(root);
  assert.deepEqual(edges.edgeList(peers, 'legA'), ['conA', 'judgeA']);
  const refusal = edges.check(peers, 'legA', 'nobody');
  assert.equal(refusal.ok, false);
  assert.match(refusal.error, /^no edge to nobody/);
  assert.doesNotMatch(refusal.error, /conB|legB/);
  assert.match(refusal.error, /conA/);
});

test('edges: leg to sibling refused, leg to console allowed, console to other console leg refused', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'conA', { role: 'console' });
  await identity.register(root, 'conB', { role: 'console' });
  await identity.register(root, 'leg1', { role: 'leg', console: 'conA' });
  await identity.register(root, 'leg2', { role: 'leg', console: 'conA' });
  await identity.register(root, 'legB', { role: 'leg', console: 'conB' });
  const peers = await identity.loadPeers(root);
  assert.equal(edges.check(peers, 'leg1', 'leg2').ok, false);
  assert.equal(edges.check(peers, 'leg1', 'conA').ok, true);
  assert.equal(edges.check(peers, 'conA', 'leg1').ok, true);
  assert.equal(edges.check(peers, 'conA', 'legB').ok, false);
  assert.equal(edges.check(peers, 'conA', 'conB').ok, false);
  assert.equal(edges.check(peers, 'leg1', 'leg1').ok, false);
  assert.equal(edges.check(peers, 'ghost', 'conA').ok, false);
});

test('edges: predecessor link creates console to console edge both ways', async t => {
  const { root } = await fixture(t);
  await identity.register(root, 'old', { role: 'console' });
  await identity.register(root, 'next', { role: 'console', predecessor: 'old' });
  const peers = await identity.loadPeers(root);
  assert.equal(edges.check(peers, 'old', 'next').ok, true);
  assert.equal(edges.check(peers, 'next', 'old').ok, true);
});

test('rebind only when the bound pid is gone', async t => {
  const { root } = await fixture(t);
  const proc = await fakeProc(t, chain);
  await bound(root, proc);
  await assert.rejects(identity.rebind(root, 'leg', 300, { proc }), /still live/);
  const after = await fakeProc(t, [P(1, 0, 'init', 1), P(201, 1, 'claude', 2500)]);
  await identity.rebind(root, 'leg', 201, { proc: after });
  assert.deepEqual(await identity.resolveIdentity(root, { proc: after, pid: 201 }), { name: 'leg' });
});

test('adopt needs the old console gone or a relay record from it naming the new one', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'console', predecessor: 'con' });
  await assert.rejects(identity.adopt(root, 'leg', 'new', { proc: live }), /not gone/);
  await store.append(root, 'leg', { i: 'x', t: 1, f: 'con', r: 'leg', c: 1, b: 'handing over to new' });
  await identity.adopt(root, 'leg', 'new', { proc: live });
  assert.equal((await identity.loadPeers(root)).leg.console, 'new');
});

test('adopt succeeds when the old console is gone', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'console', predecessor: 'con' });
  const gone = await fakeProc(t, [P(1, 0, 'init', 1), P(200, 1, 'claude', 2000)]);
  await identity.adopt(root, 'leg', 'new', { proc: gone });
  assert.equal((await identity.loadPeers(root)).leg.console, 'new');
});

test('adopt refuses a record from someone else naming the new console', async t => {
  const { root } = await fixture(t);
  const live = await fakeProc(t, chain);
  await bound(root, live);
  await identity.register(root, 'new', { role: 'console', predecessor: 'con' });
  await store.append(root, 'leg', { i: 'x', t: 1, f: 'rogue', r: 'leg', c: 1, b: 'adopt new' });
  await assert.rejects(identity.adopt(root, 'leg', 'new', { proc: live }), /not gone/);
});

test('CLI: register, bind, status, peers, rebind against real processes', async t => {
  const state = await mkdtemp(join(tmpdir(), 'bus-cli-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const env = { ...process.env, XDG_STATE_HOME: state };
  const run = (...args) => spawnSync(process.execPath, [cli, ...args], { env, encoding: 'utf8' });
  assert.equal(run('register', 'con', '--role', 'console').status, 0);
  assert.equal(run('register', 'leg', '--role', 'leg', '--console', 'con').status, 0);
  assert.notEqual(run('register', 'leg', '--role', 'leg', '--console', 'con').status, 0);
  assert.notEqual(run('register', 'bad', '--role', 'wizard').status, 0);
  const child = spawn('sleep', ['30']);
  t.after(() => child.kill());
  assert.equal(run('bind', 'leg', String(child.pid)).status, 0);
  assert.notEqual(run('bind', 'leg', String(child.pid)).status, 0);
  assert.equal(run('status', 'leg').stdout.trim(), 'live');
  assert.notEqual(run('rebind', 'leg', String(process.pid)).status, 0);
  child.kill('SIGKILL');
  await new Promise(r => child.once('exit', r));
  assert.equal(run('status', 'leg').stdout.trim(), 'gone');
  const second = spawn('sleep', ['30']);
  t.after(() => second.kill());
  assert.equal(run('rebind', 'leg', String(second.pid)).status, 0);
  assert.equal(run('status', 'leg').stdout.trim(), 'live');
  // the CLI process itself has no bound claude ancestor
  const peers = run('peers');
  assert.notEqual(peers.status, 0);
  assert.match(peers.stderr, /identity unbound/);
  assert.equal((await stat(join(state, 'himmel/bus/peers/leg.json'))).mode & 0o777, 0o600);
});
