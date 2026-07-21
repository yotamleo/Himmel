import type { RenderContext } from '../types.js';
export declare function renderAgentsLine(ctx: RenderContext): string | null;
/**
 * Compacts an agent model into a statusline-sized label.
 *
 * The transcript reports raw model IDs (e.g. "claude-opus-4-8[1m]",
 * "claude-haiku-4-5-20251001"), which are far too long to sit inside an agent
 * line. Family plus version is the part that carries meaning, so the wrapper
 * bits are dropped: the "claude-" prefix, the bracketed context-window variant,
 * and the trailing release date.
 *
 * Anything that does not look like a model ID — notably the short aliases a
 * caller can pass as `model` ("opus", "sonnet", "haiku") — is returned
 * unchanged, so explicit overrides keep rendering the way they always have.
 */
export declare function formatAgentModel(model: string | undefined): string | undefined;
//# sourceMappingURL=agents-line.d.ts.map