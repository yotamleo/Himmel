import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { spawn } from 'node:child_process';
import { getClaudeConfigDir, getHudPluginDir } from './claude-config-dir.js';
import { parseTranscript } from './transcript.js';
import { createDebug } from './debug.js';

const debug = createDebug('cache-economics');

export interface CacheEconomicsTotals {
  reads: number;
  writes: number;
  inputs: number;
}

const ALL_SESSIONS_CACHE_TTL_MS = 30_000;
const ALL_SESSIONS_CACHE_FILENAME = 'cache-economics-all.json';
const REFRESH_LOCK_DIRNAME = 'refresh.lock';
const REFRESH_LOCK_STALE_MS = 120_000;

// Flag the detached refresh child is spawned with; index.ts checks argv for
// this to dispatch to runCacheEconomicsRefresh() instead of rendering.
export const REFRESH_CACHE_ECONOMICS_FLAG = '--refresh-cache-economics';

function defaultSpawnRefresh(): void {
  const entry = process.argv[1];
  if (!entry) return;
  try {
    spawn(process.execPath, [entry, REFRESH_CACHE_ECONOMICS_FLAG], {
      detached: true,
      stdio: 'ignore',
    }).unref();
  } catch (err) {
    debug('Failed to spawn cache-economics refresh child:', err instanceof Error ? err.message : err);
  }
}

export type CacheEconomicsDeps = {
  homeDir: () => string;
  now: () => number;
  spawnRefresh: (homeDir: string) => void;
  rename: (oldPath: string, newPath: string) => void;
};

const defaultDeps: CacheEconomicsDeps = {
  homeDir: () => os.homedir(),
  now: () => Date.now(),
  spawnRefresh: defaultSpawnRefresh,
  rename: (oldPath, newPath) => fs.renameSync(oldPath, newPath),
};

interface AllSessionsCache extends CacheEconomicsTotals {
  computedAt: number;
}

function getCachePath(homeDir: string): string {
  return path.join(getHudPluginDir(homeDir), ALL_SESSIONS_CACHE_FILENAME);
}

function getRefreshLockPath(homeDir: string): string {
  return path.join(getHudPluginDir(homeDir), REFRESH_LOCK_DIRNAME);
}

// mkdir is atomic: EEXIST means another process is already refreshing.
// Ownership transfers to the detached child spawned right after a successful
// acquire here; the child releases the lock in the finally of its refresh
// body (runCacheEconomicsRefresh) once the scan + write are done.
function acquireRefreshLock(homeDir: string, now: number): boolean {
  try {
    fs.mkdirSync(getHudPluginDir(homeDir), { recursive: true, mode: 0o700 });
  } catch (err) {
    debug('Failed to create hud plugin dir for refresh lock:', err instanceof Error ? err.message : err);
    return false;
  }
  const lockPath = getRefreshLockPath(homeDir);
  const tryMkdir = (): boolean => {
    try {
      fs.mkdirSync(lockPath);
      return true;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EEXIST') {
        debug('Failed to create cache-economics refresh lock:', err instanceof Error ? err.message : err);
      }
      return false;
    }
  };
  if (tryMkdir()) return true;

  try {
    const age = now - fs.statSync(lockPath).mtimeMs;
    if (age > REFRESH_LOCK_STALE_MS) {
      fs.rmdirSync(lockPath);
      return tryMkdir();
    }
  } catch (err) {
    debug('Failed to reclaim stale cache-economics refresh lock:', err instanceof Error ? err.message : err);
  }
  return false;
}

function releaseRefreshLock(homeDir: string): void {
  try {
    fs.rmdirSync(getRefreshLockPath(homeDir));
  } catch (err) {
    debug('Failed to release cache-economics refresh lock:', err instanceof Error ? err.message : err);
  }
}

function readCache(homeDir: string): AllSessionsCache | null {
  try {
    const cachePath = getCachePath(homeDir);
    if (!fs.existsSync(cachePath)) return null;
    const parsed = JSON.parse(fs.readFileSync(cachePath, 'utf8')) as AllSessionsCache;
    if (
      typeof parsed.reads !== 'number'
      || typeof parsed.writes !== 'number'
      || typeof parsed.inputs !== 'number'
      || typeof parsed.computedAt !== 'number'
    ) {
      return null;
    }
    return parsed;
  } catch (err) {
    debug('Failed to read cache-economics cache:', err instanceof Error ? err.message : err);
    return null;
  }
}

function writeCache(homeDir: string, cache: AllSessionsCache, rename: CacheEconomicsDeps['rename']): void {
  try {
    const cachePath = getCachePath(homeDir);
    fs.mkdirSync(path.dirname(cachePath), { recursive: true, mode: 0o700 });
    // Write to a pid-suffixed tmp file then rename onto the real path so a
    // concurrent reader never observes partial JSON (rename is atomic).
    const tmpPath = `${cachePath}.tmp.${process.pid}`;
    fs.writeFileSync(tmpPath, JSON.stringify(cache), { encoding: 'utf8', mode: 0o600 });
    try {
      fs.chmodSync(tmpPath, 0o600);
    } catch {
      // Best-effort: some filesystems do not support POSIX modes.
    }
    rename(tmpPath, cachePath);
  } catch (err) {
    debug('Failed to write cache-economics cache:', err instanceof Error ? err.message : err);
  }
}

function findTranscriptFiles(dir: string): string[] {
  const results: string[] = [];
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    debug('Failed to read projects dir %s:', dir, err instanceof Error ? err.message : err);
    return results;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...findTranscriptFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
      results.push(full);
    }
  }
  return results;
}

async function computeAllSessionsTotals(homeDir: string): Promise<CacheEconomicsTotals> {
  const projectsDir = path.join(getClaudeConfigDir(homeDir), 'projects');
  const files = findTranscriptFiles(projectsDir);
  const totals: CacheEconomicsTotals = { reads: 0, writes: 0, inputs: 0 };
  for (const file of files) {
    try {
      const data = await parseTranscript(file);
      if (data.sessionTokens) {
        totals.reads += data.sessionTokens.cacheReadTokens;
        totals.writes += data.sessionTokens.cacheCreationTokens;
        totals.inputs += data.sessionTokens.inputTokens;
      }
    } catch (err) {
      debug('Failed to parse transcript for cache economics %s:', file, err instanceof Error ? err.message : err);
    }
  }
  return totals;
}

// Mirrors the legacy bash's 30s-file-cached read_all_sessions_cache_stats:
// scanning every session transcript on each render is too expensive, so the
// aggregate is recomputed at most once per ALL_SESSIONS_CACHE_TTL_MS — and,
// unlike the legacy bash's synchronous rebuild, that recompute never blocks
// this render: a detached, locked background process (runCacheEconomicsRefresh,
// dispatched via REFRESH_CACHE_ECONOMICS_FLAG) does the scan and atomic write
// while this call returns immediately with whatever it already has cached
// (zeros on a cold start, exactly like the legacy bash).
export async function getAllSessionsCacheEconomics(
  overrides: Partial<CacheEconomicsDeps> = {},
): Promise<CacheEconomicsTotals> {
  const deps = { ...defaultDeps, ...overrides };
  const homeDir = deps.homeDir();
  const now = deps.now();

  // computedAt <= now guards against a system-clock rollback pinning a
  // stale cache as "fresh" indefinitely (a negative age would otherwise
  // always satisfy the TTL check below).
  const cached = readCache(homeDir);
  const isFresh = Boolean(
    cached && cached.computedAt <= now && now - cached.computedAt < ALL_SESSIONS_CACHE_TTL_MS,
  );

  if (!isFresh && acquireRefreshLock(homeDir, now)) {
    deps.spawnRefresh(homeDir);
  }

  if (cached) {
    return { reads: cached.reads, writes: cached.writes, inputs: cached.inputs };
  }
  return { reads: 0, writes: 0, inputs: 0 };
}

// Runs in the detached child spawned by getAllSessionsCacheEconomics (or
// in-process in tests): scans every transcript, writes the cache atomically,
// then releases the refresh lock the render path already acquired.
export async function runCacheEconomicsRefresh(
  overrides: Partial<CacheEconomicsDeps> = {},
): Promise<void> {
  const deps = { ...defaultDeps, ...overrides };
  const homeDir = deps.homeDir();
  try {
    const totals = await computeAllSessionsTotals(homeDir);
    writeCache(homeDir, { ...totals, computedAt: deps.now() }, deps.rename);
  } finally {
    releaseRefreshLock(homeDir);
  }
}

// Port of the legacy bash format_tokens: 999 -> "999", 1000 -> "1k",
// 45321 -> "45k", 1_234_567 -> "1.2M" (pinned against the bash function).
export function formatCacheTokens(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0';
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(1)}B`;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}k`;
  return `${Math.trunc(n)}`;
}

// Port of the bash `denom = inputs + reads; hit = floor(reads*100/denom)`.
export function computeCacheHitPercent(reads: number, inputs: number): number {
  const denom = inputs + reads;
  if (denom <= 0) return 0;
  return Math.floor((reads * 100) / denom);
}

// Port of the bash `net_usd = reads*read_savings_rate - writes*write_overhead_rate`.
export function computeCacheNetUsd(
  reads: number,
  writes: number,
  readSavingsRate: number,
  writeOverheadRate: number,
): number {
  return reads * readSavingsRate - writes * writeOverheadRate;
}

// Port of the legacy bash format_usd (K/M/B thresholds at >=1000, else 4dp).
export function formatCacheUsd(amount: number): string {
  const abs = Math.abs(amount);
  if (abs >= 1_000_000_000) return `${(abs / 1_000_000_000).toFixed(1)}B`;
  if (abs >= 1_000_000) return `${(abs / 1_000_000).toFixed(1)}M`;
  if (abs >= 1000) return `${(abs / 1000).toFixed(1)}K`;
  return abs.toFixed(4);
}
