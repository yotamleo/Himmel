import { lstat, mkdir, readdir, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { join, resolve, dirname, parse } from 'node:path';
import { homedir } from 'node:os';
import * as zlib from 'node:zlib';
import { appendChained, readPast, commitCursor, chainHash, openChainFile, withChainLock } from '../../../../scripts/telegram/bus.ts';

export { readPast, commitCursor };
export const ROTATE_BYTES = 256 * 1024;
const initial = () => ({ k: 0, off: 0, n: 0, h: '' });

async function info(path) {
  try { return await lstat(path); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

async function directory(path, privateMode = true) {
  const stat = await info(path);
  if (!stat?.isDirectory() || stat.isSymbolicLink()) throw new Error(`symlink or non-directory: ${path}`);
  if (privateMode && (stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o700)) throw new Error(`unsafe directory permissions: ${path}`);
}

export async function busRoot({ stateHome = process.env.XDG_STATE_HOME || join(homedir(), '.local/state') } = {}) {
  if (!stateHome.startsWith('/')) throw new Error('state home must be absolute');
  const root = join(resolve(stateHome), 'himmel/bus');
  let path = parse(root).root;
  for (const part of root.slice(path.length).split('/')) {
    path = join(path, part);
    const stat = await info(path);
    if (stat?.isSymbolicLink()) throw new Error(`symlink: ${path}`);
    if (!stat) await mkdir(path, { mode: 0o700 }).catch(error => { if (error.code !== 'EEXIST') throw error; });
    // Shared ancestors (e.g. /tmp, /home) need not be private. The XDG
    // state directory and bus-owned directories must be private and owned.
    await directory(path, path === resolve(stateHome) || path.startsWith(resolve(stateHome) + '/'));
    if (await info(join(path, '.git'))) throw new Error(`bus root inside a git work tree: ${path}`);
  }
  for (const name of ['peers', 'log', 'cur', 'ack', 'lock']) {
    await mkdir(join(root, name), { mode: 0o700 }).catch(error => { if (error.code !== 'EEXIST') throw error; });
    await directory(join(root, name));
  }
  return root;
}

async function paths(root, name) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name)) throw new Error('invalid session name');
  // Re-check on every operation, not just startup; a replaced root must fail.
  let path = resolve(root);
  while (true) {
    const stat = await info(path);
    if (stat?.isSymbolicLink()) throw new Error(`symlink: ${path}`);
    if (await info(join(path, '.git'))) throw new Error(`bus root inside a git work tree: ${path}`);
    if (dirname(path) === path) break;
    path = dirname(path);
  }
  await directory(dirname(dirname(root)));
  await directory(dirname(root));
  await directory(root);
  for (const dir of ['log', 'cur', 'lock']) await directory(join(root, dir));
  return { file: join(root, 'log', name + '.jsonl'), cursor: join(root, 'cur', name), lock: join(root, 'lock', name) };
}

async function bytes(path) {
  const handle = await openChainFile(path, constants.O_RDONLY);
  try { return await handle.readFile(); } finally { await handle.close(); }
}

async function create(path) {
  const handle = await openChainFile(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL);
  await handle.close();
}

async function segments(root, name) {
  const pattern = new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\.(\\d+)\\.jsonl(?:\\.(zst|gz))?$`);
  const found = new Map();
  for (const file of await readdir(join(root, 'log'))) {
    const match = pattern.exec(file);
    if (!match) continue;
    const k = Number(match[1]);
    if (!Number.isSafeInteger(k) || k < 0) throw new Error('invalid segment number');
    const raw = await bytes(join(root, 'log', file));
    const data = match[2] === 'zst' ? zlib.zstdDecompressSync(raw) : match[2] === 'gz' ? zlib.gunzipSync(raw) : raw;
    if (found.has(k) && !found.get(k).equals(data)) throw new Error(`conflicting segment #${k}`);
    found.set(k, data);
  }
  return [...found].sort((a, b) => a[0] - b[0]);
}

function tail(buf) {
  if (!buf.length) return { n: 0, h: '' };
  if (buf[buf.length - 1] !== 10) throw new Error('incomplete segment tail');
  return JSON.parse(buf.subarray(buf.lastIndexOf(10, buf.length - 2) + 1, buf.length - 1).toString('utf8'));
}

async function cursor(file) {
  let cur;
  try { cur = JSON.parse((await bytes(file)).toString('utf8')); }
  catch (error) { if (error.code === 'ENOENT') return initial(); throw error; }
  if (!Number.isSafeInteger(cur.k) || cur.k < 0 || !Number.isSafeInteger(cur.off) || cur.off < 0 || !Number.isSafeInteger(cur.n) || cur.n < 0 || typeof cur.h !== 'string' || (cur.n === 0 ? cur.h !== '' : !/^[0-9a-f]{64}$/.test(cur.h)) || (cur.halted !== undefined && (!Number.isSafeInteger(cur.halted) || cur.halted < 1))) throw new Error('invalid bus cursor');
  return cur;
}

export async function append(root, name, record) {
  const p = await paths(root, name);
  return appendChained(p.file, record, p.lock, async () => {
    const cur = await cursor(p.cursor);
    if (cur.halted) throw new Error(`log ${name} halted`);
    const closed = await segments(root, name);
    const k = closed.length ? closed.at(-1)[0] + 1 : 0;
    let live;
    try { live = await bytes(p.file); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      if (cur.k === k && cur.off > 0) throw new Error('committed live bytes missing');
      await create(p.file); live = Buffer.alloc(0);
    }
    if (cur.k === k && live.length < cur.off) throw new Error('committed live bytes truncated');
    if (live.length >= ROTATE_BYTES) {
      const plain = join(root, 'log', `${name}.${k}.jsonl`);
      if (await info(plain)) throw new Error('segment already exists');
      // The plain segment is recoverable if compression or a crash interrupts
      // rotation. Publish compressed bytes before removing that plain segment.
      await rename(p.file, plain);
      await create(p.file);
      const codec = zlib.zstdCompressSync ? 'zst' : 'gz';
      const compressed = codec === 'zst' ? zlib.zstdCompressSync(live) : zlib.gzipSync(live);
      const temp = plain + '.' + codec + '.tmp';
      const handle = await openChainFile(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL);
      try { await handle.writeFile(compressed); } finally { await handle.close(); }
      await rename(temp, plain + '.' + codec);
      await unlink(plain);
      return tail(live);
    }
    return closed.length ? tail(closed.at(-1)[1]) : { n: 0, h: '' };
  });
}

export async function read(root, name) {
  const p = await paths(root, name);
  return withChainLock(p.lock, async () => {
    const cur = await cursor(p.cursor);
    if (cur.halted) return { records: [], next: cur, cursors: [] };
    const records = [], cursors = [];
    let next = { ...cur };
    try {
      const closed = await segments(root, name);
      const liveK = closed.length ? closed.at(-1)[0] + 1 : 0;
      let live;
      try { live = await bytes(p.file); }
      catch (error) { if (error.code !== 'ENOENT') throw error; live = Buffer.alloc(0); }
      const all = [...closed, [liveK, live]];
      if (!all.some(([k]) => k === cur.k)) throw new Error('cursor segment missing');
      let expectedK = cur.k;
      for (const [k, buf] of all) {
        if (k < cur.k) continue;
        if (k !== expectedK++) throw new Error('segment gap');
        const start = k === cur.k ? cur.off : 0;
        if (start > buf.length) throw new Error('cursor beyond EOF');
        if (start > 0 && buf[start - 1] !== 10) throw new Error('cursor not on record boundary');
        next = { ...next, k, off: start };
        while (next.off < buf.length) {
          // Verify each parsed record before reading the next: a malformed
          // later line must not hide an earlier break or its actual sequence.
          const batch = await readPast(buf, next, 1);
          if (!batch.records.length) throw new Error('incomplete log tail');
          const record = batch.records[0];
          if (record.n !== next.n + 1 || record.h !== chainHash(next.h, record)) throw new Error('chain mismatch');
          next = batch.next;
          records.push(record); cursors.push(next);
        }
      }
      return { records, next, cursors };
    } catch (error) {
      // Filesystem access-policy errors are refused, not mislabelled as tamper.
      if (error.code === 'ELOOP' || /permissions|symlink/.test(error.message)) throw error;
      const halted = next.n + 1;
      next = { ...cur, halted };
      await commitCursor(p.cursor, next);
      // Fail closed for this entire batch: nothing was emitted or delivered.
      // The delivery hook owns notifying the console, not this store primitive.
      return { records: [], next, cursors: [], notice: `bus: log ${name} chain broken at #${halted}` };
    }
  });
}

export async function commit(root, name, next) {
  const p = await paths(root, name);
  return withChainLock(p.lock, async () => {
    const cur = await cursor(p.cursor);
    if (cur.halted) throw new Error(`log ${name} halted`);
    if (next.n < cur.n || next.k < cur.k || (next.k === cur.k && next.off < cur.off) || (next.n === cur.n && next.h !== cur.h)) throw new Error('stale delivery cursor');
    await commitCursor(p.cursor, next);
  });
}

// Shared predicate for the wait CLI: a halted log never creates a hot loop.
export async function pending(root, name) {
  const p = await paths(root, name);
  return withChainLock(p.lock, async () => {
    const cur = await cursor(p.cursor);
    if (cur.halted) return false;
    let closed;
    try { closed = await segments(root, name); }
    catch (error) {
      if (error.code === 'ELOOP' || /permissions|symlink/.test(error.message)) throw error;
      // Wake on damaged archives too; read() owns persisting the halt/notice.
      return true;
    }
    const liveK = closed.length ? closed.at(-1)[0] + 1 : 0;
    let size = 0;
    try {
      const handle = await openChainFile(p.file, constants.O_RDONLY);
      try { size = (await handle.stat()).size; } finally { await handle.close(); }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    // Shrinkage/missing bytes wake the reader too, so it can persist a halt.
    return liveK !== cur.k || size !== cur.off;
  });
}
