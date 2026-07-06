import type { StdinData } from "./types.js";
export type ContextCacheDeps = {
    homeDir: () => string;
    now: () => number;
    random: () => number;
};
export type CompactHint = {
    /** Timestamp of the most recent compact_boundary entry in the transcript. */
    lastCompactBoundaryAt?: Date;
    /** Post-compact token count from compactMetadata, when Claude Code records it. */
    lastCompactPostTokens?: number;
};
/**
 * Apply context-window fallback in-place:
 * - For suspicious zero frames, try restoring from the session-scoped cache.
 * - For healthy frames, refresh the cache snapshot for this session
 *   (subject to TTL + value-change throttling to avoid hot-path writes).
 *
 * When `compactHint.lastCompactBoundaryAt` is newer than the cached snapshot's
 * `saved_at`, the zero frame is treated as a legitimate post-/compact reset and
 * the stale pre-compact snapshot is NOT restored. If `lastCompactPostTokens`
 * is provided, it is used to synthesize an accurate transition-window percent.
 *
 * No-op when stdin has no transcript_path, since without a stable session key
 * we cannot safely isolate cache entries across concurrent Claude Code sessions.
 */
export declare function applyContextWindowFallback(stdin: StdinData, overrides?: Partial<ContextCacheDeps>, sessionName?: string, compactHint?: CompactHint): void;
/**
 * Test-only entrypoint for deterministically exercising the sweep logic.
 */
export declare function _sweepCacheForTests(homeDir: string, now: number): void;
//# sourceMappingURL=context-cache.d.ts.map