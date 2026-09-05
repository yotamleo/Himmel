import { spawn, type ChildProcess } from 'node:child_process';
export declare const GIT_MAX_OUTPUT_BYTES: number;
export interface GitCommandRunner {
    run(args: readonly string[], timeout: number): Promise<{
        stdout: string;
    }>;
    close(): Promise<void>;
}
export declare function createGitEnvironment(base?: NodeJS.ProcessEnv): NodeJS.ProcessEnv;
export declare function createGitRunner(cwd: string, platform?: NodeJS.Platform): GitCommandRunner;
type KillableChild = Pick<ChildProcess, 'pid' | 'exitCode' | 'signalCode' | 'kill'>;
/**
 * Terminate only the Windows process tree rooted at the child this worker
 * spawned. `taskkill.exe` is invoked directly (never through a shell), and a
 * direct child kill is retained as a bounded fallback if tree termination is
 * unavailable.
 */
export declare function terminateWindowsProcessTree(child: KillableChild, spawnImpl?: typeof spawn, environment?: NodeJS.ProcessEnv): Promise<void>;
export declare function resolveTaskkillPath(environment?: NodeJS.ProcessEnv): string | null;
type ResolveCandidate = (candidate: string) => string | null;
/** Resolve git.exe from absolute PATH entries before the worker enters a repo cwd. */
export declare function resolveWindowsGitExecutable(environment?: NodeJS.ProcessEnv, resolveCandidate?: ResolveCandidate): string | null;
export {};
//# sourceMappingURL=git-runner.d.ts.map