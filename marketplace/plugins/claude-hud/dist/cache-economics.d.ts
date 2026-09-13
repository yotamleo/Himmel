export interface CacheEconomicsTotals {
    reads: number;
    writes: number;
    inputs: number;
}
export declare const REFRESH_CACHE_ECONOMICS_FLAG = "--refresh-cache-economics";
export type CacheEconomicsDeps = {
    homeDir: () => string;
    now: () => number;
    spawnRefresh: (homeDir: string) => void;
    rename: (oldPath: string, newPath: string) => void;
};
export declare function getAllSessionsCacheEconomics(overrides?: Partial<CacheEconomicsDeps>): Promise<CacheEconomicsTotals>;
export declare function runCacheEconomicsRefresh(overrides?: Partial<CacheEconomicsDeps>): Promise<void>;
export declare function formatCacheTokens(n: number): string;
export declare function computeCacheHitPercent(reads: number, inputs: number): number;
export declare function computeCacheNetUsd(reads: number, writes: number, readSavingsRate: number, writeOverheadRate: number): number;
export declare function formatCacheUsd(amount: number): string;
//# sourceMappingURL=cache-economics.d.ts.map