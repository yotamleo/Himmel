import type { RenderContext } from '../../types.js';
export declare function sanitize(value: string): string;
export declare function basenameOf(dir: string): string;
export declare const MAX_RENDERED_ADDED_DIRS = 5;
export declare const MAX_ADDED_DIR_NAME_LEN = 24;
export declare function truncateBasename(name: string): string;
export declare function normalizeAddedDirs(value: unknown): string[];
export declare function renderAddedDirsLine(ctx: RenderContext): string | null;
//# sourceMappingURL=added-dirs.d.ts.map