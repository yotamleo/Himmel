import type { SessionTokenUsage, StdinData } from './types.js';
export type ModelPricing = {
    inputUsdPerMillion: number;
    outputUsdPerMillion: number;
    cacheReadUsdPerMillion?: number;
    cacheWriteUsdPerMillion?: number | null;
};
export interface SessionCostEstimate {
    totalUsd: number;
    inputUsd: number;
    cacheCreationUsd: number;
    cacheReadUsd: number;
    outputUsd: number;
}
export interface SessionCostDisplay {
    totalUsd: number;
    source: 'native' | 'estimate';
}
export declare function getModelPricing(stdin: StdinData): ModelPricing | null;
export interface EffectiveCachePricing {
    inputUsdPerMillion: number;
    cacheReadUsdPerMillion: number;
    cacheWriteUsdPerMillion: number;
}
export declare function resolveEffectiveCachePricing(pricing: ModelPricing): EffectiveCachePricing;
export declare function estimateSessionCost(stdin: StdinData, sessionTokens: SessionTokenUsage | undefined, options?: {
    allowRoutedCost?: boolean;
}): SessionCostEstimate | null;
export declare function getNativeCostUsd(stdin: StdinData, options?: {
    allowRoutedCost?: boolean;
}): number | null;
export declare function resolveSessionCost(stdin: StdinData, sessionTokens: SessionTokenUsage | undefined, options?: {
    allowRoutedCost?: boolean;
}): SessionCostDisplay | null;
export declare function formatUsd(amount: number): string;
//# sourceMappingURL=cost.d.ts.map