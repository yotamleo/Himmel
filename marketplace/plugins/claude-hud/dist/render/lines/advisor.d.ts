import type { RenderContext } from '../../types.js';
/**
 * Prettifies a raw advisor model ID (as captured from the transcript) into a
 * human-friendly label. Falls back to the input string when the pattern is
 * not recognised.
 *
 *   claude-opus-4-7              → Opus 4.7
 *   claude-sonnet-4-6            → Sonnet 4.6
 *   claude-haiku-4-5-20251001    → Haiku 4.5
 *   opus                         → Opus
 */
export declare function prettifyAdvisorId(rawId: string): string;
export declare function renderAdvisorLine(ctx: RenderContext): string | null;
//# sourceMappingURL=advisor.d.ts.map