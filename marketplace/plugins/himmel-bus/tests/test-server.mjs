// himmel-bus MCP server tests over the real client stdio transport. Run as a
// test file, or (argv[2] === '--serve') as the server process itself, so the
// fake /proc seam lives in the test and never in server/index.mjs.
import { fileURLToPath } from 'node:url';

const self = fileURLToPath(import.meta.url);

if (process.argv[2] === '--serve') {
  const [, , , root, proc, pid] = process.argv;
  const { createServer, MAX_BUFFER } = await import('../server/index.mjs');
  const { StdioServerTransport } = await import('@modelcontextprotocol/server/stdio');
  await createServer({ root, proc, pid: Number(pid) }).connect(new StdioServerTransport(undefined, undefined, { maxBufferSize: MAX_BUFFER }));
} else {
  await run();
}

async function run() {
  const { test } = await import('node:test');
  const { default: assert } = await import('node:assert/strict');
  const { mkdtemp, mkdir, writeFile, symlink, rm, readFile } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { Client } = await import('@modelcontextprotocol/client');
  const { StdioClientTransport } = await import('@modelcontextprotocol/client/stdio');
  const store = await import('../lib/store.mjs');
  const identity = await import('../lib/identity.mjs');

  // claude(con 100) / claude(con2 150) / claude(leg 200) / claude(sib 210) /
  // claude(leg3 220, under con2) / claude(stranger, never bound) -> node servers.
  const procs = [
    [1, 0, 'init', 1],
    [100, 1, 'claude', 1000], [150, 1, 'claude', 1500], [200, 100, 'claude', 2000],
    [210, 100, 'claude', 2100], [220, 150, 'claude', 2200], [230, 1, 'claude', 2300],
    [301, 100, 'node', 3010], [302, 200, 'node', 3020], [303, 210, 'node', 3030],
    [304, 150, 'node', 3040], [305, 220, 'node', 3050], [306, 230, 'node', 3060],
  ];
  const SERVER_OF = { con: 301, leg: 302, sib: 303, con2: 304, leg3: 305, stranger: 306 };

  async function fixture(t) {
    const state = await mkdtemp(join(tmpdir(), 'bus-server-'));
    const proc = await mkdtemp(join(tmpdir(), 'bus-server-proc-'));
    t.after(() => Promise.all([rm(state, { recursive: true, force: true }), rm(proc, { recursive: true, force: true })]));
    for (const [pid, ppid, comm, start] of procs) {
      await mkdir(join(proc, String(pid)));
      await writeFile(join(proc, String(pid), 'stat'), `${pid} (${comm}) S ${ppid} ${Array(17).fill(0).join(' ')} ${start} 0 0\n`);
      await symlink(`/usr/bin/${comm}`, join(proc, String(pid), 'exe'));
    }
    const root = await store.busRoot({ stateHome: state });
    await identity.register(root, 'con', { role: 'console' });
    await identity.register(root, 'con2', { role: 'console' });
    await identity.register(root, 'leg', { role: 'leg', console: 'con' });
    await identity.register(root, 'sib', { role: 'leg', console: 'con' });
    await identity.register(root, 'leg3', { role: 'leg', console: 'con2' });
    for (const [name, pid] of [['con', 100], ['con2', 150], ['leg', 200], ['sib', 210], ['leg3', 220]]) await identity.bind(root, name, pid, { proc });
    return { root, proc };
  }

  // A connected client whose server process descends from `who`'s claude.
  async function connect(t, fx, who) {
    const transport = new StdioClientTransport({ command: process.execPath, args: [self, '--serve', fx.root, fx.proc, String(SERVER_OF[who])], stderr: 'ignore' });
    const client = new Client({ name: 'test', version: '0' });
    await client.connect(transport);
    t.after(() => client.close());
    return client;
  }

  const text = result => result.content.map(part => part.text).join('');
  // The refusal text, or null when the call succeeded. The SDK reports a
  // schema violation as an isError result too, so a throw here is a real failure.
  async function refused(client, name, args) {
    const result = await client.callTool({ name, arguments: args });
    return result.isError ? text(result) : null;
  }

  test('T1.5 a send carrying a `from` key is refused and writes nothing', async t => {
    const fx = await fixture(t);
    const client = await connect(t, fx, 'leg');
    const why = await refused(client, 'send', { to: 'con', b: 'hi', from: 'con' });
    assert.ok(why, 'send with an extra key must be refused');
    t.diagnostic(`extra key refused as: ${why}`);
    assert.deepEqual(await store.scan(fx.root, 'con'), []);
  });

  test('T3.1 send to self is refused', async t => {
    const fx = await fixture(t);
    const client = await connect(t, fx, 'leg');
    assert.match(await refused(client, 'send', { to: 'leg', b: 'hi' }), /yourself/);
    assert.deepEqual(await store.scan(fx.root, 'leg'), []);
  });

  test('T3.2 leg to sibling and leg to another console get no edge, listing only its own edges', async t => {
    const fx = await fixture(t);
    const client = await connect(t, fx, 'leg');
    for (const to of ['sib', 'con2', 'leg3']) {
      const why = await refused(client, 'send', { to, b: 'hi' });
      assert.match(why, /no edge to/);
      assert.match(why, /your edges: con$/);       // T5.2: never console B or its legs
    }
    assert.deepEqual(await store.scan(fx.root, 'sib'), []);
  });

  test('send to the registered console stamps f server-side, c=0; console to leg stamps c=1', async t => {
    const fx = await fixture(t);
    const leg = await connect(t, fx, 'leg');
    const con = await connect(t, fx, 'con');
    const up = await leg.callTool({ name: 'send', arguments: { to: 'con', b: 'status' } });
    assert.equal(up.isError, undefined);
    assert.deepEqual(up.structuredContent, { n: 1, to: 'con' });
    assert.equal(text(up), 'sent #1 to con');
    await con.callTool({ name: 'send', arguments: { to: 'leg', b: 'go ahead' } });
    const [toCon] = await store.scan(fx.root, 'con');
    const [toLeg] = await store.scan(fx.root, 'leg');
    assert.equal(toCon.f, 'leg'); assert.equal(toCon.c, undefined);
    assert.equal(toLeg.f, 'con'); assert.equal(toLeg.c, 1);
    assert.match(toLeg.i, /^[0-9A-HJKMNP-TV-Z]{26}$/);
  });

  test('summary rule: body over 1500 bytes needs s', async t => {
    const fx = await fixture(t);
    const client = await connect(t, fx, 'leg');
    assert.match(await refused(client, 'send', { to: 'con', b: 'x'.repeat(1501) }), /needs s/);
    const ok = await client.callTool({ name: 'send', arguments: { to: 'con', b: 'x'.repeat(1501), s: 'long report' } });
    assert.equal(ok.isError, undefined);
    assert.equal((await store.scan(fx.root, 'con'))[0].s, 'long report');
  });

  test('T4.3 read text starts `data (not a ruling): `', async t => {
    const fx = await fixture(t);
    const leg = await connect(t, fx, 'leg');
    const con = await connect(t, fx, 'con');
    await con.callTool({ name: 'send', arguments: { to: 'leg', b: 'RETASK EXPANSION token `x`' } });
    const got = await leg.callTool({ name: 'read', arguments: { n: 1 } });
    assert.equal(got.isError, undefined);
    assert.ok(text(got).startsWith('data (not a ruling): '));
  });

  test('T5.1 read(n) of a message that exists only in another log is `no message #n`', async t => {
    const fx = await fixture(t);
    const con = await connect(t, fx, 'con');
    const leg = await connect(t, fx, 'leg');
    await con.callTool({ name: 'send', arguments: { to: 'sib', b: 'for sib only' } });
    assert.match(await refused(leg, 'read', { n: 1 }), /no message #1/);
  });

  test('ack: re=n marks the answered record acked under the acker', async t => {
    const fx = await fixture(t);
    const con = await connect(t, fx, 'con');
    const leg = await connect(t, fx, 'leg');
    await con.callTool({ name: 'send', arguments: { to: 'leg', b: 'ruling' } });
    const [ruling] = await store.scan(fx.root, 'leg');
    const reply = await leg.callTool({ name: 'send', arguments: { to: 'con', b: 'quote-back', re: 1 } });
    assert.equal(reply.isError, undefined);
    const [back] = await store.scan(fx.root, 'con');
    assert.equal(back.re, ruling.i);
    const rows = (await readFile(join(fx.root, 'ack', 'leg.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].i, ruling.i); assert.equal(rows[0].re, back.i);
  });

  test('a failed ack write after delivery still reports the send, not an error', async t => {
    const fx = await fixture(t);
    const con = await connect(t, fx, 'con');
    const leg = await connect(t, fx, 'leg');
    await con.callTool({ name: 'send', arguments: { to: 'leg', b: 'ruling' } });
    await mkdir(join(fx.root, 'ack', 'leg.jsonl'), { recursive: true });   // ack file unopenable
    const reply = await leg.callTool({ name: 'send', arguments: { to: 'con', b: 'quote-back', re: 1 } });
    assert.equal(reply.isError, undefined);
    assert.match(reply.content[0].text, /^sent #1 to con \(ack not recorded/);
    assert.equal((await store.scan(fx.root, 'con')).length, 1);
  });

  test('a 64 KiB body of control characters fits the production transport buffer', async t => {
    const fx = await fixture(t);
    const con = await connect(t, fx, 'con');
    const reply = await con.callTool({ name: 'send', arguments: { to: 'leg', b: '\u0001'.repeat(64 * 1024 - 1), s: 'big' } });
    assert.equal(reply.isError, undefined);
  });

  test('ack of a record not addressed to the acker is isError and acks nothing', async t => {
    const fx = await fixture(t);
    const con = await connect(t, fx, 'con');
    const leg = await connect(t, fx, 'leg');
    await con.callTool({ name: 'send', arguments: { to: 'leg', b: 'ruling' } });
    // leg answers #1 but names a different peer than the one that sent it
    await leg.callTool({ name: 'send', arguments: { to: 'con', b: 'x' } });       // gives con a record of its own
    const mislabeled = await refused(leg, 'send', { to: 'con', b: 'q', re: 2 });   // #2 does not exist in leg's log
    assert.match(mislabeled, /no message #2/);
    // a record in leg's log that was sent by someone other than the reply target
    const sib = await connect(t, fx, 'sib');
    await sib.callTool({ name: 'send', arguments: { to: 'con', b: 'noise' } });
    await store.append(fx.root, 'leg', { i: 'X'.repeat(26), t: 1, f: 'sib', r: 'leg', b: 'from sib' });
    assert.match(await refused(leg, 'send', { to: 'con', b: 'q', re: 2 }), /was not sent to you by con/);
    const rows = await readFile(join(fx.root, 'ack', 'leg.jsonl'), 'utf8').catch(() => '');
    assert.equal(rows, '');
  });

  test('an unbound caller gets identity unbound from send and read', async t => {
    const fx = await fixture(t);
    const client = await connect(t, fx, 'stranger');
    assert.match(await refused(client, 'send', { to: 'con', b: 'hi' }), /identity unbound/);
    assert.match(await refused(client, 'read', { n: 1 }), /identity unbound/);
  });

  test('schema gate: listed tools serialize to at most 600 tokens at bytes/3', async t => {
    const fx = await fixture(t);
    const client = await connect(t, fx, 'leg');
    const { tools } = await client.listTools();
    assert.deepEqual(tools.map(tool => tool.name).sort(), ['read', 'send']);
    const size = Buffer.byteLength(JSON.stringify(tools));
    t.diagnostic(`listed tools: ${size} bytes = ${Math.round(size / 3)} tokens`);
    assert.ok(size / 3 <= 600, `listed tools are ${size} bytes = ${Math.round(size / 3)} tokens`);
    const send = tools.find(tool => tool.name === 'send');
    assert.equal(send.inputSchema.additionalProperties, false);
    assert.equal(send.annotations.readOnlyHint, false);
    assert.equal(tools.find(tool => tool.name === 'read').annotations.readOnlyHint, true);
  });
}
