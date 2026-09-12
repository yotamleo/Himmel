import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { getClaudeConfigDir, getHudPluginDir } from './claude-config-dir.js';
import { parseTranscript } from './transcript.js';
import { createDebug } from './debug.js';
const debug = createDebug('cache-economics');
const ALL_SESSIONS_CACHE_TTL_MS = 30_000;
const ALL_SESSIONS_CACHE_FILENAME = 'cache-economics-all.json';
const defaultDeps = {
    homeDir: () => os.homedir(),
    now: () => Date.now(),
};
function getCachePath(homeDir) {
    return path.join(getHudPluginDir(homeDir), ALL_SESSIONS_CACHE_FILENAME);
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
function writeCache(homeDir, cache) {
    try {
        const cachePath = getCachePath(homeDir);
        fs.mkdirSync(path.dirname(cachePath), { recursive: true, mode: 0o700 });
        fs.writeFileSync(cachePath, JSON.stringify(cache), { encoding: 'utf8', mode: 0o600 });
        try {
            fs.chmodSync(cachePath, 0o600);
        }
        catch {
            // Best-effort: some filesystems do not support POSIX modes.
        }
    }
    catch (err) {
        debug('Failed to write cache-economics cache:', err instanceof Error ? err.message : err);
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
// aggregate is recomputed at most once per ALL_SESSIONS_CACHE_TTL_MS.
export async function getAllSessionsCacheEconomics(overrides = {}) {
    const deps = { ...defaultDeps, ...overrides };
    const homeDir = deps.homeDir();
    const now = deps.now();
    const cached = readCache(homeDir);
    if (cached && now - cached.computedAt < ALL_SESSIONS_CACHE_TTL_MS) {
        return { reads: cached.reads, writes: cached.writes, inputs: cached.inputs };
    }
    const totals = await computeAllSessionsTotals(homeDir);
    writeCache(homeDir, { ...totals, computedAt: now });
    return totals;
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