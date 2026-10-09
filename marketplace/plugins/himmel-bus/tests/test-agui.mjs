import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mintRetaskNonce } from '../../../../scripts/telegram/brief-blocks.ts';

const aguiUrl = new URL('../lib/agui.mjs', import.meta.url);
const storeUrl = new URL('../lib/store.mjs', import.meta.url);
const NONCE = /R-[0-9a-f]{32}/;

async function fixture(t) {
  const state = await mkdtemp(join(tmpdir(), 'bus-agui-'));
  t.after(() => rm(state, { recursive: true, force: true }));
  const store = await import(storeUrl);
  const agui = await import(aguiUrl);
  const root = await store.busRoot({ stateHome: state });
  return { store, agui, root };
}
const rec = (o = {}) => ({ i: 'ID' + Math.random().toString(36).slice(2, 10), t: 1000, f: 'console', r: 'leg', b: 'hello', ...o });
const collect = async (agui, root, opts) => { const out = []; for await (const e of agui.busEvents(root, opts)) out.push(e); return out; };
const ops = events => events.flatMap(e => e.delta);

test('T8.1 a RETASK token in a body with no summary never reaches the summary', async t => {
  const { store, agui, root } = await fixture(t);
  const token = `R-${mintRetaskNonce()}`;
  await store.append(root, 'leg', rec({ c: 1, b: `RETASK EXPANSION token \`${token}\` widen scope` }));
  // The span form is caught by the token-span pattern; the bare form is the one only the R- pattern catches.
  await store.append(root, 'leg', rec({ c: 1, b: `RETASK EXPANSION quoting ${token} widen scope` }));
  const events = await collect(agui, root);
  assert.ok(events.length >= 2);
  assert.doesNotMatch(JSON.stringify(events), NONCE);
  assert.doesNotMatch(JSON.stringify(events), new RegExp(token.slice(2, 14)));
});

test('T8.2 a nonce straddling byte 120 is redacted before the clip', async t => {
  const { store, agui, root } = await fixture(t);
  for (const nonce of ['BP-X-1234abcd', `R-${mintRetaskNonce()}`, 'cachyos-x8664-pid909468']) {
    await store.append(root, 'leg', rec({ b: 'x'.repeat(100) + ' ' + nonce + ' tail' }));
  }
  const text = JSON.stringify(await collect(agui, root));
  assert.doesNotMatch(text, /BP-X|1234abcd|R-[0-9a-f]{4}|pid909|x8664/);
});

test('T8.3 no body key and no string over 200 chars under /bus/', async t => {
  const { store, agui, root } = await fixture(t);
  await store.append(root, 'leg', rec({ b: 'y'.repeat(5000), s: 'z'.repeat(300) }));
  await store.append(root, 'leg', rec({ b: 'w'.repeat(5000) }));
  const events = await collect(agui, root);
  const walk = (v, path = '') => {
    if (typeof v === 'string') assert.ok(v.length <= 200, `${path} is ${v.length} chars`);
    else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) { assert.notEqual(k, 'b', `body key at ${path}`); walk(x, `${path}/${k}`); }
  };
  for (const op of ops(events)) { assert.match(op.path, /^\/bus\//); walk(op.value, op.path); }
});

test('T8.4 agui.mjs imports the shared redact and keeps no copy', async () => {
  const src = await readFile(aguiUrl, 'utf8');
  assert.match(src, /import\s*\{[^}]*\bredact\b[^}]*\}\s*from\s*'[^']*console-kit\/redact\.mjs'/);
  assert.doesNotMatch(src, /(const|function)\s+redact\b/);
  const board = await readFile(new URL('../../../../scripts/handover/console-kit/board.mjs', import.meta.url), 'utf8');
  assert.match(board, /from '\.\/redact\.mjs'/);
  assert.doesNotMatch(board, /const redact = /);
});

test('events: send, delivered, acked, kind, ordering and since', async t => {
  const { store, agui, root } = await fixture(t);
  const a = rec({ i: 'A1', t: 2000, c: 1, b: 'HALT now' });
  const b = rec({ i: 'B1', t: 3000, f: 'leg', r: 'console', b: 'READY 12 abc GREEN' });
  const c = rec({ i: 'C1', t: 4000, f: 'leg', r: 'console', b: 'just words', re: 'A1' });
  await store.append(root, 'leg', a);
  await store.append(root, 'console', b);
  await store.append(root, 'console', c);
  const got = await store.read(root, 'leg');
  await store.commit(root, 'leg', got.next);
  await writeFile(join(root, 'ack/leg.jsonl'), JSON.stringify({ i: 'A1', re: 'C1', t: 4000 }) + '\n');

  const events = await collect(agui, root);
  assert.ok(events.every(e => e.type === 'STATE_DELTA'));
  const flat = ops(events);
  const sendOf = id => flat.find(o => o.path === `/bus/msgs/${id}`).value;
  assert.equal(sendOf('A1').kind, 'ruling');
  assert.equal(sendOf('B1').kind, 'report');
  assert.equal(sendOf('C1').kind, 'data');
  assert.equal(sendOf('A1').len, 8);
  assert.equal(sendOf('A1').c, 1);
  assert.equal(sendOf('C1').re, 'A1');
  assert.equal(typeof flat.find(o => o.path === '/bus/msgs/A1/delivered').value, 'number');
  assert.equal(flat.some(o => o.path === '/bus/msgs/B1/delivered'), false);
  assert.deepEqual(flat.find(o => o.path === '/bus/msgs/A1/acked').value, { t: 4000, by: 'leg' });
  const ts = events.map(e => e.timestamp);
  assert.deepEqual(ts, [...ts].sort((x, y) => x - y));

  const later = await collect(agui, root, { since: 3000 });
  assert.deepEqual(ops(later).filter(o => /^\/bus\/msgs\/[A-Z0-9]+$/.test(o.path)).map(o => o.value.i).sort(), ['C1']);
});

test('a token-shaped body makes a c=1 message a ruling', async t => {
  const { store, agui, root } = await fixture(t);
  await store.append(root, 'leg', rec({ i: 'T1', c: 1, b: `GO 5 abc with R-${mintRetaskNonce()}` }));
  await store.append(root, 'leg', rec({ i: 'T2', b: `GO 5 abc with R-${mintRetaskNonce()}` }));
  const flat = ops(await collect(agui, root));
  assert.equal(flat.find(o => o.path === '/bus/msgs/T1').value.kind, 'ruling');
  assert.equal(flat.find(o => o.path === '/bus/msgs/T2').value.kind, 'data');
});
