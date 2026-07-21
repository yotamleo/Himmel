export interface EffortInfo {
    level: string;
    symbol: string;
}
export interface ResolveEffortOptions {
    ultracodeActive?: boolean;
}
/**
 * Shape of the effort field in Claude Code stdin JSON.
 *
 * Historically absent; Claude Code 2.1.115+ sends an object with a string
 * `level` field (verified capture: `{ "level": "max" }`). The index signature
 * keeps the type permissive so future additions (e.g., a budget field) do not
 * require another breaking change here.
 */
export interface StdinEffort {
    level?: string | null;
    [key: string]: unknown;
}
export type StdinEffortInput = string | StdinEffort | null | undefined;
/**
 * Resolve the current session's effort level.
 *
 * Resolution order (matches `extractEffortString` below):
 * 1. stdin.effort as non-empty string — original PR #471 future-proofed path.
 * 2. stdin.effort as object with string `level` — Claude Code 2.1.115+ schema
 *    (e.g., `{ "level": "max" }`).
 * 3. null.
 *
 * When the transcript marks ultracode active (`options.ultracodeActive`), the
 * reported level is wrapped as `ultracode(<level>)` — the level is taken as-is,
 * not assumed to be `xhigh`.
 *
 * Non-matching inputs (numbers, booleans, arrays, objects without a string
 * `level`) return null rather than crashing.
 */
export declare function resolveEffortLevel(stdinEffort?: StdinEffortInput, options?: ResolveEffortOptions): EffortInfo | null;
//# sourceMappingURL=effort.d.ts.map