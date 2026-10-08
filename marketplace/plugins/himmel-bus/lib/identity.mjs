import { readFile, readdir, readlink, link, rename, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { basename, join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { openChainFile, withChainLock } from '../../../../scripts/telegram/bus.ts';
import * as store from './store.mjs';

const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const ROLES = ['leg', 'console', 'judge', 'consult'];
const UNBOUND = { error: 'identity unbound' };

function checkName(name) {
  if (!NAME.test(name)) throw new Error(`invalid session name: ${name}`);
}

// {ppid, start, comm} of a pid under an injectable /proc root, or null.
// comm may contain spaces and parens, so split after the LAST ')'.
export async function procStat(proc, pid) {
  let text;
  try { text = await readFile(join(proc, String(pid), 'stat'), 'utf8'); }
  catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') return null; throw error; }
  const open = text.indexOf('('), close = text.lastIndexOf(')');
  if (open < 0 || close < open) return null;
  const rest = text.slice(close + 2).split(' ');
  return { comm: text.slice(open + 1, close), ppid: Number(rest[1]), start: rest[19] };
}

async function isClaude(proc, pid, comm) {
  if (comm === 'claude') return true;
  try { return basename(await readlink(join(proc, String(pid), 'exe'))) === 'claude'; } catch { return false; }
}

// Nearest claude ancestor (inclusive) of `pid`: {pid, start}, or null. Nearest,
// not outermost: the console is an ancestor of every leg it launches.
export async function nearestClaude(proc, pid) {
  for (let hops = 0; pid > 1 && hops < 128; hops++) {
    const st = await procStat(proc, pid);
    if (!st) return null;
    if (await isClaude(proc, pid, st.comm)) return { pid, start: st.start };
    pid = st.ppid;
  }
  return null;
}

const peersDir = root => join(root, 'peers');
const peerFile = (root, name) => join(peersDir(root), name + '.json');
const registryLock = root => join(root, 'lock', '.peers');

async function readPeer(root, name) {
  checkName(name);
  let handle;
  try { handle = await openChainFile(peerFile(root, name), constants.O_RDONLY); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  try { return JSON.parse(await handle.readFile('utf8')); } finally { await handle.close(); }
}

// Writes `data` to a private temp file and returns its path.
async function temp(root, name, data) {
  const path = join(peersDir(root), `.${name}.${randomBytes(6).toString('hex')}.tmp`);
  const handle = await openChainFile(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL);
  try { await handle.writeFile(JSON.stringify(data) + '\n'); } finally { await handle.close(); }
  return path;
}

async function update(root, name, change) {
  return withChainLock(registryLock(root), async () => {
    const peer = await readPeer(root, name);
    if (!peer) throw new Error(`unknown session: ${name}`);
    const next = await change(peer);
    const path = await temp(root, name, next);
    try { await rename(path, peerFile(root, name)); } catch (error) { await unlink(path).catch(() => {}); throw error; }
    return next;
  });
}

export async function loadPeers(root) {
  const peers = {};
  for (const file of await readdir(peersDir(root))) {
    const match = /^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.json$/.exec(file);
    if (!match) continue;
    try { const peer = await readPeer(root, match[1]); if (peer) peers[match[1]] = peer; } catch { /* unreadable peer: no edges */ }
  }
  return peers;
}

// Names are single-use: the exclusive link() fails if the name ever existed.
export async function register(root, name, { role, console: owner, pair, predecessor } = {}) {
  checkName(name);
  if (!ROLES.includes(role)) throw new Error(`invalid role: ${role} (one of ${ROLES.join('|')})`);
  if (role !== 'console' && !owner) throw new Error(`role ${role} needs --console`);
  for (const other of [owner, pair, predecessor]) if (other !== undefined) checkName(other);
  const peer = { n: name, role, launched: new Date().toISOString() };
  if (owner) peer.console = owner;
  if (pair) peer.pair = pair;
  if (predecessor) peer.predecessor = predecessor;
  const path = await temp(root, name, peer);
  try { await link(path, peerFile(root, name)); }
  catch (error) { throw error.code === 'EEXIST' ? new Error(`name already registered: ${name}`) : error; }
  finally { await unlink(path).catch(() => {}); }
  return peer;
}

async function start(proc, pid) {
  const st = Number.isSafeInteger(pid) && pid > 1 ? await procStat(proc, pid) : null;
  if (!st) throw new Error(`no such process: ${pid}`);
  return st.start;
}

// One process identity, one name: refuse a bind that another session already holds.
async function unclaimed(root, name, pid, begun) {
  for (const [other, p] of Object.entries(await loadPeers(root))) {
    if (other !== name && p.pid === pid && p.start === begun) throw new Error(`process ${pid} is already bound to ${other}`);
  }
}

export async function status(root, name, { proc = '/proc' } = {}) {
  const peer = await readPeer(root, name);
  if (!peer) throw new Error(`unknown session: ${name}`);
  if (peer.pid === undefined) return 'unbound';
  const st = await procStat(proc, peer.pid);
  return st && st.start === peer.start ? 'live' : 'gone';
}

export async function bind(root, name, pid, { proc = '/proc' } = {}) {
  const begun = await start(proc, pid);
  return update(root, name, async peer => {
    if (peer.pid !== undefined) throw new Error(`already bound: ${name}`);
    await unclaimed(root, name, pid, begun);
    return { ...peer, pid, start: begun };
  });
}

// A resumed session gets a new claude pid; only when the old one is gone.
export async function rebind(root, name, pid, { proc = '/proc' } = {}) {
  const begun = await start(proc, pid);
  return update(root, name, async peer => {
    if (peer.pid === undefined) throw new Error(`not bound yet (use bind): ${name}`);
    if (await status(root, name, { proc }) === 'live') throw new Error(`bound pid is still live: ${name}`);
    await unclaimed(root, name, pid, begun);
    return { ...peer, pid, start: begun };
  });
}

// Console succession (spec §8.6): `name` follows `next` only if its old console
// is gone, or the old console itself sent a record naming `next`.
export async function adopt(root, name, next, { proc = '/proc' } = {}) {
  checkName(next);
  return update(root, name, async peer => {
    const old = peer.console;
    if (!old) throw new Error(`${name} has no console to replace`);
    const target = await readPeer(root, next);
    if (!target) throw new Error(`unknown session: ${next}`);
    if (target.role !== 'console') throw new Error(`${next} is not a console`);
    const names = new RegExp(`(^|[^A-Za-z0-9._-])${next.replace(/[.]/g, '\\.')}($|[^A-Za-z0-9._-])`);
    const relayed = async () => (await store.read(root, name)).records.some(r => r.f === old && typeof r.b === 'string' && names.test(r.b));
    if (await status(root, old, { proc }) !== 'gone' && !await relayed()) throw new Error(`old console ${old} is not gone and sent no relay naming ${next}`);
    return { ...peer, console: next };
  });
}

// Who is the session this process belongs to? {name} or {error}.
export async function resolveIdentity(root, { proc = '/proc', pid = process.pid } = {}) {
  const claude = await nearestClaude(proc, pid);
  if (!claude) return UNBOUND;
  const matches = Object.entries(await loadPeers(root)).filter(([, p]) => p.pid === claude.pid && p.start === claude.start);
  return matches.length === 1 ? { name: matches[0][0] } : UNBOUND;
}
