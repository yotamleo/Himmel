import { spawn } from 'node:child_process';
import { terminateWindowsProcessTree } from './git-runner.js';
export interface GitWorkerRuntime {
    argv: string[];
    connected: boolean;
    send?: (message: object) => boolean;
    disconnect?: () => void;
    exit: (code?: number) => never | void;
    on: (event: 'message', listener: (message: unknown) => void) => unknown;
    once: (event: 'disconnect', listener: () => void) => unknown;
}
export interface GitWorkerDependencies {
    runtime?: GitWorkerRuntime;
    spawnGit?: typeof spawn;
    terminateTree?: typeof terminateWindowsProcessTree;
}
export interface GitWorkerController {
    handleMessage(message: unknown): void;
    beginShutdown(): void;
    getState(): {
        active: boolean;
        starting: boolean;
        shuttingDown: boolean;
    };
}
export declare function startWindowsGitWorker(dependencies?: GitWorkerDependencies): GitWorkerController;
//# sourceMappingURL=windows-git-worker.d.ts.map