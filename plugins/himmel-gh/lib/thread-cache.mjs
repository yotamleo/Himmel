import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { platform } from 'node:os';
import { createHash } from 'node:crypto';

function osCacheRoot() {
  const win = platform() === 'win32';
  const base = win
    ? process.env.LOCALAPPDATA
    : (process.env.XDG_CACHE_HOME || (process.env.HOME && join(process.env.HOME, '.cache')));
  if (!base) {
    throw new Error(
      `Cannot resolve cache dir: ${win ? 'LOCALAPPDATA' : 'HOME / XDG_CACHE_HOME'} unset`,
    );
  }
  return join(base, 'himmel-cli');
}

export function cachePath(cacheRootOverride, owner, repo, number) {
  const root = cacheRootOverride ?? osCacheRoot();
  return join(root, 'gh', 'threads', `${owner}-${repo}-${number}.json`);
}

function hashId(id) {
  return createHash('sha256').update(id).digest('hex');
}

export function buildPrefixMap(threads) {
  // Assign each thread the shortest hex prefix of sha256(id) that is unique
  // across the batch. Start at 6; on collision, extend the offending pair (and
  // everyone else for shape consistency) by one char. Capped at 64 (full sha256
  // hex length) — exhausting that range means two ids hashed identically, which
  // for sha256 implies the input ids were themselves equal (GitHub GraphQL
  // guarantees thread ids are unique, so this is an API-invariant violation).
  const items = threads.map((t) => ({ thread: t, hash: hashId(t.id) }));
  let len = 6;
  while (len <= 64) {
    const tentative = {};
    let collision = false;
    for (const { thread, hash } of items) {
      const p = hash.slice(0, len);
      if (tentative[p]) {
        collision = true;
        break;
      }
      tentative[p] = thread;
    }
    if (!collision) return tentative;
    len++;
  }
  throw new Error(
    'duplicate thread id detected (sha256 collision on full hash) — '
    + 'GitHub GraphQL API invariant violation, refusing to build prefix map',
  );
}

export const SCHEMA_VERSION = 1;

export function writeThreadCache(cacheRootOverride, owner, repo, number, threads) {
  const file = cachePath(cacheRootOverride, owner, repo, number);
  const dir = dirname(file);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
  const data = {
    schema_version: SCHEMA_VERSION,
    owner,
    repo,
    number,
    fetched_at: new Date().toISOString(),
    threads: buildPrefixMap(threads),
  };
  writeFileSync(file, JSON.stringify(data, null, 2), { mode: 0o600 });
  if (platform() !== 'win32') {
    try {
      chmodSync(file, 0o600);
    } catch {
      /* best-effort */
    }
  }
  return data;
}

export function readThreadCache(cacheRootOverride, owner, repo, number) {
  const file = cachePath(cacheRootOverride, owner, repo, number);
  if (!existsSync(file)) return null;
  let data;
  try {
    data = JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    process.stderr.write(`[gh] warning: ${file} corrupt, ignoring: ${e.message}\n`);
    return null;
  }
  if (!data || typeof data !== 'object' || Array.isArray(data) || !data.threads) return null;
  // Schema-version gate (HIMMEL-106 RepoContextCache precedent). A legacy or
  // future version triggers a single refetch — safer than silently returning
  // a misshaped object.
  if (data.schema_version !== SCHEMA_VERSION) {
    process.stderr.write(
      `[gh] warning: ${file} schema_version=${data.schema_version ?? '<missing>'} `
      + `(expected ${SCHEMA_VERSION}), ignoring\n`,
    );
    return null;
  }
  // Defense-in-depth: cache filename embeds (owner, repo, number), but a
  // corrupted or copied file could carry stale identifiers. Refuse mismatch.
  if (data.owner !== owner || data.repo !== repo || data.number !== Number(number)) {
    process.stderr.write(
      `[gh] warning: ${file} identifier mismatch `
      + `(file=${data.owner}/${data.repo}#${data.number}, req=${owner}/${repo}#${number}), ignoring\n`,
    );
    return null;
  }
  return data;
}

export function lookupPrefix(cached, prefix) {
  if (!cached || !cached.threads) return { status: 'no-match' };
  const keys = Object.keys(cached.threads);
  const matches = keys.filter((k) => k.startsWith(prefix));
  if (matches.length === 0) return { status: 'no-match' };
  if (matches.length > 1) return { status: 'ambiguous', prefixes: matches };
  return { status: 'ok', id: cached.threads[matches[0]].id };
}
