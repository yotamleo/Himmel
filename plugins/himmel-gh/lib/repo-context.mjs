import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { platform } from 'node:os';

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

export function cachePath(cacheRootOverride) {
  const root = cacheRootOverride ?? osCacheRoot();
  return join(root, 'gh', 'repo-context.json');
}

export function readCache(cacheRootOverride, cwd) {
  const file = cachePath(cacheRootOverride);
  if (!existsSync(file)) return null;
  let data;
  try {
    data = JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    process.stderr.write(`[gh] warning: ${file} corrupt, ignoring: ${e.message}\n`);
    return null;
  }
  if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
  if (data.schema_version !== 1) return null;
  if (typeof data.owner !== 'string' || data.owner.length === 0) return null;
  if (typeof data.name !== 'string' || data.name.length === 0) return null;
  // Strict string compare — Windows case-folding and POSIX-symlink resolution
  // are NOT normalized here. False-negative (cwd looks different than cached)
  // is safe: worst case is one extra `gh repo view` call. See HIMMEL-106 §4
  // for rationale.
  if (data.cwd !== cwd) return null;
  return data;
}

export function writeCache(cacheRootOverride, { cwd, owner, name }) {
  const file = cachePath(cacheRootOverride);
  const dir = dirname(file);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
  const data = {
    schema_version: 1,
    cwd,
    owner,
    name,
    fetched_at: new Date().toISOString(),
  };
  writeFileSync(file, JSON.stringify(data, null, 2), { mode: 0o600 });
  if (platform() !== 'win32') {
    try {
      chmodSync(file, 0o600);
    } catch (e) {
      process.stderr.write(`[gh] warning: chmod 600 ${file} failed: ${e.message}\n`);
    }
  }
}
