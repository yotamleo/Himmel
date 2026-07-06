import type { RenderContext } from '../types.js';
/**
 * Format a token count into a human-readable short string.
 *   >= 1M  → "1.2M"
 *   >= 1k  → "45k"
 *   < 1k   → "800"
 */
export declare function formatTokens(n: number): string;
/**
 * Format the context-window value for display.
 *   percent   → "45%"
 *   tokens    → "45k/200k"
 *   remaining → "55%"
 *   both      → "45% (45k/200k)"
 */
export declare function formatContextValue(ctx: RenderContext, percent: number, mode: 'percent' | 'tokens' | 'remaining' | 'both'): string;
//# sourceMappingURL=format.d.ts.map