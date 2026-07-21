import type { GitStatus } from './git.js';
export interface JjRunnerOptions {
    cwd: string;
    timeout: number;
    maxBuffer: number;
    encoding: 'utf8';
    windowsHide: boolean;
    shell: false;
}
export type JjRunner = (file: string, args: readonly string[], options: JjRunnerOptions) => Promise<{
    stdout: string;
}>;
/**
 * Cheap, synchronous, subprocess-free check: walk upward from cwd looking for
 * a `.jj` directory, the same way jj's own CLI locates a repo root. Runs
 * before any subprocess is spawned so non-jj users pay ~zero cost per
 * invocation (a few fs.statSync calls, never an execFile).
 */
export declare function isJjRepo(cwd?: string): boolean;
export declare function getJjStatus(cwd?: string, runner?: JjRunner): Promise<GitStatus | null>;
//# sourceMappingURL=jj.d.ts.map