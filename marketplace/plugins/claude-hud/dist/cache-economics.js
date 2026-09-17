import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { getClaudeConfigDir, getHudPluginDir } from './claude-config-dir.js';
import { parseTranscript } from './transcript.js';
import { createDebug } from './debug.js';
const debug = createDebug('cache-economics');
const ALL_SESSIONS_CACHE_TTL_MS = 30_000;
const ALL_SESSIONS_CACHE_FILENAME = 'cache-economics-all.json';
const REFRESH_LOCK_DIRNAME = 'refresh.lock';
const REFRESH_LOCK_OWNER_FILENAME = 'owner';
const REFRESH_LOCK_STALE_MS = 120_000;
// Flag the detached refresh child is spawned with; index.ts checks argv for
// this to dispatch to runCacheEconomicsRefresh() instead of rendering. The
// token that follows it is the owner token acquireRefreshLock minted for
// this refresh cycle (see releaseRefreshLock).
export const REFRESH_CACHE_ECONOMICS_FLAG = '--refresh-cache-economics';
export function getRefreshLockTokenFromArgv(argv = process.argv) {
    const idx = argv.indexOf(REFRESH_CACHE_ECONOMICS_FLAG);
    if (idx === -1)
        return null;
    return argv[idx + 1] ?? null;
}
// Factory so tests can inject a fake `spawn` (an EventEmitter-like stub)
// instead of forking a real process, to drive the 'error' handling below.
export function createSpawnRefresh(spawnFn) {
    return (homeDir, lockToken) => {
        const entry = process.argv[1];
        if (!entry) {
            releaseRefreshLock(homeDir, lockToken);
            return;
        }
        try {
            const child = spawnFn(process.execPath, [entry, REFRESH_CACHE_ECONOMICS_FLAG, lockToken], {
                detached: true,
                stdio: 'ignore',
            });
            // spawn() can fail asynchronously (e.g. EAGAIN) after returning
            // successfully; an unhandled 'error' event would crash this process,
            // and the child never started, so the lock this call was handed must
            // be released here rather than left for a child that will never run.
            child.once('error', (err) => {
                debug('Failed to spawn cache-economics refresh child:', err.message);
                releaseRefreshLock(homeDir, lockToken);
            });
            child.unref();
        }
        catch (err) {
            debug('Failed to spawn cache-economics refresh child:', err instanceof Error ? err.message : err);
            releaseRefreshLock(homeDir, lockToken);
        }
    };
}
const defaultSpawnRefresh = createSpawnRefresh(spawn);
const defaultDeps = {
    homeDir: () => os.homedir(),
    now: () => Date.now(),
    spawnRefresh: defaultSpawnRefresh,
    rename: (oldPath, newPath) => fs.renameSync(oldPath, newPath),
    writeFile: (filePath, data) => fs.writeFileSync(filePath, data, { encoding: 'utf8', mode: 0o600 }),
};
function getCachePath(homeDir) {
    return path.join(getHudPluginDir(homeDir), ALL_SESSIONS_CACHE_FILENAME);
}
function getRefreshLockPath(homeDir) {
    return path.join(getHudPluginDir(homeDir), REFRESH_LOCK_DIRNAME);
}
function getRefreshLockOwnerPath(homeDir) {
    return path.join(getRefreshLockPath(homeDir), REFRESH_LOCK_OWNER_FILENAME);
}
// mkdir is atomic: EEXIST means another process is already refreshing.
// Ownership transfers to the detached child spawned right after a successful
// acquire here (via the returned token, threaded through spawnRefresh and
// the child's argv); the child releases the lock in the finally of its
// refresh body (runCacheEconomicsRefresh) once the scan + write are done.
// A stale (>120s) lock is reclaimed by minting a FRESH token: the original
// owner's eventual release call carries its now-superseded token, so
// releaseRefreshLock can tell the two apart and refuses to remove a lock it
// no longer owns (otherwise a slow-but-alive refresh's release could delete
// a different, newer refresh's lock out from under it).
function acquireRefreshLock(homeDir, now) {
    try {
        fs.mkdirSync(getHudPluginDir(homeDir), { recursive: true, mode: 0o700 });
    }
    catch (err) {
        debug('Failed to create hud plugin dir for refresh lock:', err instanceof Error ? err.message : err);
        return null;
    }
    const lockPath = getRefreshLockPath(homeDir);
    const tryAcquire = () => {
        try {
            fs.mkdirSync(lockPath);
        }
        catch (err) {
            if (err.code !== 'EEXIST') {
                debug('Failed to create cache-economics refresh lock:', err instanceof Error ? err.message : err);
            }
            return null;
        }
        const token = randomUUID();
        try {
            fs.writeFileSync(getRefreshLockOwnerPath(homeDir), token, 'utf8');
        }
        catch (err) {
            debug('Failed to record cache-economics refresh lock owner:', err instanceof Error ? err.message : err);
            // Without an owner file, isRefreshLockOwner/releaseRefreshLock can
            // never match this token, which would both block publish forever and
            // leak the lock dir. Give up the lock rather than hand back a token
            // that can never be honored.
            try {
                fs.rmSync(lockPath, { recursive: true, force: true });
            }
            catch (rmErr) {
                debug('Failed to clean up cache-economics refresh lock after a failed owner write:', rmErr instanceof Error ? rmErr.message : rmErr);
            }
            return null;
        }
        return token;
    };
    const acquired = tryAcquire();
    if (acquired)
        return acquired;
    try {
        const age = now - fs.statSync(lockPath).mtimeMs;
        if (age > REFRESH_LOCK_STALE_MS) {
            fs.rmSync(lockPath, { recursive: true, force: true });
            return tryAcquire();
        }
    }
    catch (err) {
        debug('Failed to reclaim stale cache-economics refresh lock:', err instanceof Error ? err.message : err);
    }
    return null;
}
// Removes the lock only if `lockToken` still matches the owner recorded at
// acquisition time — a mismatch (or missing owner file) means this lock was
// already reclaimed by a newer refresh, which this call must leave alone.
// True when `lockToken` still matches the owner recorded at acquisition
// time (or when there is no lock to check, i.e. a bare unit test of the
// write path). Used to skip publishing a superseded refresh's totals.
function isRefreshLockOwner(homeDir, lockToken) {
    if (lockToken === null)
        return true;
    try {
        return fs.readFileSync(getRefreshLockOwnerPath(homeDir), 'utf8') === lockToken;
    }
    catch (err) {
        debug('Failed to read cache-economics refresh lock owner:', err instanceof Error ? err.message : err);
        return false;
    }
}
function releaseRefreshLock(homeDir, lockToken) {
    const lockPath = getRefreshLockPath(homeDir);
    try {
        const owner = fs.readFileSync(getRefreshLockOwnerPath(homeDir), 'utf8');
        if (owner !== lockToken)
            return;
    }
    catch (err) {
        debug('Failed to read cache-economics refresh lock owner:', err instanceof Error ? err.message : err);
        return;
    }
    try {
        fs.rmSync(lockPath, { recursive: true, force: true });
    }
    catch (err) {
        debug('Failed to release cache-economics refresh lock:', err instanceof Error ? err.message : err);
    }
}
function readCache(homeDir) {
    try {
        const cachePath = getCachePath(homeDir);
        if (!fs.existsSync(cachePath))
            return null;
        const parsed = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
        if (typeof parsed.reads !== 'number'
            || typeof parsed.writes !== 'number'
            || typeof parsed.inputs !== 'number'
            || typeof parsed.computedAt !== 'number') {
            return null;
        }
        return parsed;
    }
    catch (err) {
        debug('Failed to read cache-economics cache:', err instanceof Error ? err.message : err);
        return null;
    }
}
function writeCache(homeDir, cache, rename, writeFile) {
    const cachePath = getCachePath(homeDir);
    // Write to a pid-suffixed tmp file then rename onto the real path so a
    // concurrent reader never observes partial JSON (rename is atomic).
    const tmpPath = `${cachePath}.tmp.${process.pid}`;
    try {
        fs.mkdirSync(path.dirname(cachePath), { recursive: true, mode: 0o700 });
        writeFile(tmpPath, JSON.stringify(cache));
        try {
            fs.chmodSync(tmpPath, 0o600);
        }
        catch {
            // Best-effort: some filesystems do not support POSIX modes.
        }
        rename(tmpPath, cachePath);
    }
    catch (err) {
        debug('Failed to write cache-economics cache:', err instanceof Error ? err.message : err);
        // Attempt cleanup even when writeFileSync itself threw partway (e.g.
        // ENOSPC): it may have left a partial tmp file despite tmpPath never
        // being confirmed written.
        try {
            fs.unlinkSync(tmpPath);
        }
        catch {
            // Best-effort: may never have been created, or rename already moved it.
        }
    }
}
function findTranscriptFiles(dir) {
    const results = [];
    let entries;
    try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
    }
    catch (err) {
        debug('Failed to read projects dir %s:', dir, err instanceof Error ? err.message : err);
        return results;
    }
    for (const entry of entries) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            results.push(...findTranscriptFiles(full));
        }
        else if (entry.isFile() && entry.name.endsWith('.jsonl')) {
            results.push(full);
        }
    }
    return results;
}
async function computeAllSessionsTotals(homeDir) {
    const projectsDir = path.join(getClaudeConfigDir(homeDir), 'projects');
    const files = findTranscriptFiles(projectsDir);
    const totals = { reads: 0, writes: 0, inputs: 0 };
    for (const file of files) {
        try {
            const data = await parseTranscript(file);
            if (data.sessionTokens) {
                totals.reads += data.sessionTokens.cacheReadTokens;
                totals.writes += data.sessionTokens.cacheCreationTokens;
                totals.inputs += data.sessionTokens.inputTokens;
            }
        }
        catch (err) {
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
export async function getAllSessionsCacheEconomics(overrides = {}) {
    const deps = { ...defaultDeps, ...overrides };
    const homeDir = deps.homeDir();
    const now = deps.now();
    // computedAt <= now guards against a system-clock rollback pinning a
    // stale cache as "fresh" indefinitely (a negative age would otherwise
    // always satisfy the TTL check below).
    const cached = readCache(homeDir);
    const isFresh = Boolean(cached && cached.computedAt <= now && now - cached.computedAt < ALL_SESSIONS_CACHE_TTL_MS);
    if (!isFresh) {
        const lockToken = acquireRefreshLock(homeDir, now);
        if (lockToken) {
            deps.spawnRefresh(homeDir, lockToken);
        }
    }
    if (cached) {
        return { reads: cached.reads, writes: cached.writes, inputs: cached.inputs };
    }
    return { reads: 0, writes: 0, inputs: 0 };
}
// Runs in the detached child spawned by getAllSessionsCacheEconomics (or
// in-process in tests): scans every transcript, writes the cache atomically,
// then releases the refresh lock the render path handed it via `lockToken`
// (null when driven without a lock, e.g. a bare unit test of the write path).
// Publish is skipped if `lockToken` no longer matches the lock's current
// owner (a stale-lock reclaim superseded this refresh while it was scanning)
// so a slow, superseded scan cannot overwrite a newer refresh's totals.
export async function runCacheEconomicsRefresh(overrides = {}, lockToken = null) {
    const deps = { ...defaultDeps, ...overrides };
    const homeDir = deps.homeDir();
    try {
        const totals = await computeAllSessionsTotals(homeDir);
        if (isRefreshLockOwner(homeDir, lockToken)) {
            writeCache(homeDir, { ...totals, computedAt: deps.now() }, deps.rename, deps.writeFile);
        }
    }
    finally {
        if (lockToken)
            releaseRefreshLock(homeDir, lockToken);
    }
}
// Port of the legacy bash format_tokens: 999 -> "999", 1000 -> "1k",
// 45321 -> "45k", 1_234_567 -> "1.2M" (pinned against the bash function).
export function formatCacheTokens(n) {
    if (!Number.isFinite(n) || n <= 0)
        return '0';
    if (n >= 1_000_000_000)
        return `${(n / 1_000_000_000).toFixed(1)}B`;
    if (n >= 1_000_000)
        return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1000)
        return `${Math.round(n / 1000)}k`;
    return `${Math.trunc(n)}`;
}
// Port of the bash `denom = inputs + reads; hit = floor(reads*100/denom)`.
export function computeCacheHitPercent(reads, inputs) {
    const denom = inputs + reads;
    if (denom <= 0)
        return 0;
    return Math.floor((reads * 100) / denom);
}
// Port of the bash `net_usd = reads*read_savings_rate - writes*write_overhead_rate`.
export function computeCacheNetUsd(reads, writes, readSavingsRate, writeOverheadRate) {
    return reads * readSavingsRate - writes * writeOverheadRate;
}
// Port of the legacy bash format_usd (K/M/B thresholds at >=1000, else 4dp).
export function formatCacheUsd(amount) {
    const abs = Math.abs(amount);
    if (abs >= 1_000_000_000)
        return `${(abs / 1_000_000_000).toFixed(1)}B`;
    if (abs >= 1_000_000)
        return `${(abs / 1_000_000).toFixed(1)}M`;
    if (abs >= 1000)
        return `${(abs / 1000).toFixed(1)}K`;
    return abs.toFixed(4);
}
//# sourceMappingURL=cache-economics.js.map