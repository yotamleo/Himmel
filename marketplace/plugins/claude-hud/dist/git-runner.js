import { execFile, spawn } from 'node:child_process';
import { realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
const execFileAsync = promisify(execFile);
export const GIT_MAX_OUTPUT_BYTES = 1024 * 1024;
const WORKER_TIMEOUT_GRACE_MS = 1500;
const WORKER_CLOSE_GRACE_MS = 2000;
const TREE_KILL_TIMEOUT_MS = 1000;
export function createGitEnvironment(base = process.env) {
    return {
        ...base,
        GIT_OPTIONAL_LOCKS: '0',
        GIT_TERMINAL_PROMPT: '0',
        GCM_INTERACTIVE: 'Never',
    };
}
class DirectGitRunner {
    cwd;
    constructor(cwd) {
        this.cwd = cwd;
    }
    async run(args, timeout) {
        const { stdout } = await execFileAsync('git', [...args], {
            cwd: this.cwd,
            timeout,
            maxBuffer: GIT_MAX_OUTPUT_BYTES,
            encoding: 'utf8',
            windowsHide: true,
            shell: false,
            env: createGitEnvironment(),
        });
        return { stdout };
    }
    async close() {
        // Direct commands have no session process to release.
    }
}
class WindowsGitRunner {
    cwd;
    worker;
    nextId = 1;
    pending = null;
    exited = false;
    closing = false;
    constructor(cwd) {
        this.cwd = cwd;
        const workerPath = fileURLToPath(new URL('./windows-git-worker.js', import.meta.url));
        const gitExecutable = resolveWindowsGitExecutable();
        if (!gitExecutable)
            throw new Error('Unable to resolve an absolute git.exe from PATH');
        this.worker = spawn(process.execPath, [workerPath, gitExecutable], {
            env: createGitEnvironment(),
            windowsHide: true,
            shell: false,
            stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
        });
        this.worker.on('message', (message) => this.handleMessage(message));
        this.worker.once('error', (error) => this.failPending(error));
        this.worker.once('exit', (code, signal) => {
            this.exited = true;
            if (!this.closing) {
                this.failPending(new Error(`Git worker exited unexpectedly (${signal ?? code ?? 'unknown'})`));
            }
        });
    }
    run(args, timeout) {
        if (this.closing || this.exited || !this.worker.connected) {
            return Promise.reject(new Error('Git worker is not available'));
        }
        if (this.pending) {
            return Promise.reject(new Error('Git worker only accepts one command at a time'));
        }
        const id = this.nextId++;
        return new Promise((resolve, reject) => {
            const guardTimer = setTimeout(() => {
                this.send({ type: 'cancel', id });
                const pending = this.pending;
                if (!pending || pending.id !== id)
                    return;
                pending.cancelTimer = setTimeout(() => {
                    if (this.pending?.id === id) {
                        this.failPending(new Error(`Git command exceeded ${timeout}ms timeout`));
                    }
                }, WORKER_TIMEOUT_GRACE_MS);
            }, timeout + WORKER_TIMEOUT_GRACE_MS);
            this.pending = { id, resolve, reject, guardTimer };
            this.send({ type: 'run', id, cwd: this.cwd, args: [...args], timeout }, (error) => {
                if (error && this.pending?.id === id)
                    this.failPending(error);
            });
        });
    }
    async close() {
        if (this.closing)
            return;
        this.closing = true;
        if (this.exited)
            return;
        this.send({ type: 'shutdown' });
        await new Promise((resolve) => {
            const timer = setTimeout(() => {
                if (!this.exited)
                    this.worker.kill();
                resolve();
            }, WORKER_CLOSE_GRACE_MS);
            this.worker.once('exit', () => {
                clearTimeout(timer);
                resolve();
            });
        });
    }
    send(message, callback) {
        if (!this.worker.connected) {
            callback?.(new Error('Git worker IPC channel is closed'));
            return;
        }
        try {
            this.worker.send(message, callback);
        }
        catch (error) {
            callback?.(error instanceof Error ? error : new Error('Unable to send Git worker message'));
        }
    }
    handleMessage(message) {
        if (!isWorkerResponse(message) || this.pending?.id !== message.id)
            return;
        const pending = this.pending;
        this.pending = null;
        clearTimeout(pending.guardTimer);
        if (pending.cancelTimer)
            clearTimeout(pending.cancelTimer);
        if (message.ok) {
            pending.resolve({ stdout: message.stdout ?? '' });
        }
        else {
            pending.reject(new Error(message.error ?? 'Git command failed'));
        }
    }
    failPending(error) {
        const pending = this.pending;
        if (!pending)
            return;
        this.pending = null;
        clearTimeout(pending.guardTimer);
        if (pending.cancelTimer)
            clearTimeout(pending.cancelTimer);
        pending.reject(error);
    }
}
function isWorkerResponse(value) {
    if (!value || typeof value !== 'object')
        return false;
    const candidate = value;
    return candidate.type === 'result'
        && Number.isSafeInteger(candidate.id)
        && typeof candidate.ok === 'boolean'
        && (candidate.stdout === undefined || typeof candidate.stdout === 'string')
        && (candidate.error === undefined || typeof candidate.error === 'string');
}
export function createGitRunner(cwd, platform = process.platform) {
    return platform === 'win32' ? new WindowsGitRunner(cwd) : new DirectGitRunner(cwd);
}
/**
 * Terminate only the Windows process tree rooted at the child this worker
 * spawned. `taskkill.exe` is invoked directly (never through a shell), and a
 * direct child kill is retained as a bounded fallback if tree termination is
 * unavailable.
 */
export async function terminateWindowsProcessTree(child, spawnImpl = spawn, environment = process.env) {
    if (child.exitCode !== null || child.signalCode !== null)
        return;
    const pid = child.pid;
    if (!pid || !Number.isSafeInteger(pid) || pid <= 0) {
        child.kill();
        return;
    }
    const taskkillPath = resolveTaskkillPath(environment);
    if (!taskkillPath) {
        child.kill();
        return;
    }
    await new Promise((resolve) => {
        let settled = false;
        let killer;
        let timer;
        const finish = (fallback) => {
            if (settled)
                return;
            settled = true;
            if (timer)
                clearTimeout(timer);
            if (fallback && child.exitCode === null && child.signalCode === null)
                child.kill();
            resolve();
        };
        try {
            killer = spawnImpl(taskkillPath, ['/PID', String(pid), '/T', '/F'], { windowsHide: true, shell: false, stdio: 'ignore' });
        }
        catch {
            child.kill();
            resolve();
            return;
        }
        timer = setTimeout(() => {
            killer.kill();
            finish(true);
        }, TREE_KILL_TIMEOUT_MS);
        killer.once('error', () => finish(true));
        killer.once('exit', (code) => finish(code !== 0));
    });
}
export function resolveTaskkillPath(environment = process.env) {
    const systemRoot = environment.SystemRoot ?? environment.SYSTEMROOT;
    if (!systemRoot || systemRoot.includes('\0'))
        return null;
    // SystemRoot is normally drive-absolute (for example C:\\Windows). Reject
    // relative, UNC, and device paths rather than PATH-resolving a repository-
    // controlled taskkill.exe.
    if (!/^[A-Za-z]:[\\/]/.test(systemRoot) || !path.win32.isAbsolute(systemRoot))
        return null;
    return path.win32.join(path.win32.normalize(systemRoot), 'System32', 'taskkill.exe');
}
/** Resolve git.exe from absolute PATH entries before the worker enters a repo cwd. */
export function resolveWindowsGitExecutable(environment = process.env, resolveCandidate = (candidate) => {
    try {
        const resolved = realpathSync(candidate);
        return statSync(resolved).isFile() ? resolved : null;
    }
    catch {
        return null;
    }
}) {
    const pathValue = Object.entries(environment)
        .find(([key]) => key.toLowerCase() === 'path')?.[1];
    if (!pathValue)
        return null;
    for (const rawEntry of pathValue.split(path.win32.delimiter)) {
        const entry = rawEntry.trim().replace(/^"(.*)"$/, '$1');
        if (!entry || entry.includes('\0') || !path.win32.isAbsolute(entry))
            continue;
        const candidate = path.win32.join(entry, 'git.exe');
        const resolved = resolveCandidate(candidate);
        if (resolved && path.win32.isAbsolute(resolved))
            return resolved;
    }
    return null;
}
//# sourceMappingURL=git-runner.js.map