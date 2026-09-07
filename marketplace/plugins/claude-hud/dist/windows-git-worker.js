import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { GIT_MAX_OUTPUT_BYTES, createGitEnvironment, terminateWindowsProcessTree, } from './git-runner.js';
const MAX_CWD_LENGTH = 32 * 1024;
const IDLE_TIMEOUT_MS = 5000;
const SHUTDOWN_HARD_TIMEOUT_MS = 2500;
function isRunRequest(value) {
    if (!value || typeof value !== 'object')
        return false;
    const request = value;
    return request.type === 'run'
        && Number.isSafeInteger(request.id)
        && typeof request.cwd === 'string'
        && request.cwd.length > 0
        && request.cwd.length <= MAX_CWD_LENGTH
        && Array.isArray(request.args)
        && request.args.length > 0
        && request.args.length <= 32
        && request.args.every((arg) => typeof arg === 'string' && arg.length <= 4096)
        && Number.isInteger(request.timeout)
        && (request.timeout ?? 0) > 0
        && (request.timeout ?? 0) <= 5000;
}
function isValidGitExecutable(value) {
    if (!value || value.includes('\0') || !path.isAbsolute(value))
        return false;
    const basename = path.basename(value).toLowerCase();
    return basename === 'git.exe' || basename === 'git';
}
export function startWindowsGitWorker(dependencies = {}) {
    const runtime = dependencies.runtime ?? process;
    const spawnGit = dependencies.spawnGit ?? spawn;
    const terminateTree = dependencies.terminateTree ?? terminateWindowsProcessTree;
    const gitExecutable = runtime.argv[2];
    let active = null;
    let starting = false;
    let shuttingDown = false;
    let idleTimer;
    let shutdownTimer;
    function scheduleIdleShutdown() {
        if (idleTimer)
            clearTimeout(idleTimer);
        idleTimer = setTimeout(beginShutdown, IDLE_TIMEOUT_MS);
    }
    function sendResult(id, result) {
        if (!runtime.connected || shuttingDown)
            return;
        try {
            runtime.send?.({ type: 'result', id, ...result });
        }
        catch {
            beginShutdown();
        }
    }
    function terminateActive(command, reason) {
        command.failure ??= reason;
        command.termination ??= terminateTree(command.child);
    }
    function runCommand(request) {
        if (shuttingDown)
            return;
        if (active || starting) {
            sendResult(request.id, { ok: false, error: 'Git worker is already running a command' });
            return;
        }
        if (idleTimer)
            clearTimeout(idleTimer);
        if (!isValidGitExecutable(gitExecutable)) {
            sendResult(request.id, { ok: false, error: 'Git executable path is invalid' });
            scheduleIdleShutdown();
            return;
        }
        starting = true;
        let child;
        try {
            child = spawnGit(gitExecutable, request.args, {
                cwd: request.cwd,
                env: createGitEnvironment(),
                windowsHide: true,
                shell: false,
                stdio: ['ignore', 'pipe', 'ignore'],
            });
        }
        catch {
            starting = false;
            if (!shuttingDown) {
                sendResult(request.id, { ok: false, error: 'Unable to start Git' });
                scheduleIdleShutdown();
            }
            exitWhenIdle();
            return;
        }
        const command = {
            id: request.id,
            child,
            chunks: [],
            outputBytes: 0,
            timer: setTimeout(() => {
                terminateActive(command, `Git command exceeded ${request.timeout}ms timeout`);
            }, request.timeout),
        };
        active = command;
        starting = false;
        child.stdout?.on('data', (chunk) => {
            if (command.failure)
                return;
            command.outputBytes += chunk.length;
            if (command.outputBytes > GIT_MAX_OUTPUT_BYTES) {
                terminateActive(command, `Git output exceeded ${GIT_MAX_OUTPUT_BYTES} bytes`);
                return;
            }
            command.chunks.push(chunk);
        });
        child.once('error', () => {
            command.failure ??= 'Unable to start Git';
        });
        child.once('close', (code, signal) => {
            void finishCommand(command, code, signal);
        });
        // A disconnect cannot normally interleave with synchronous spawn(), but
        // this recheck closes the registration race even if shutdown was triggered
        // by a synchronous runtime or instrumentation callback during process start.
        if (shuttingDown)
            terminateActive(command, 'Git worker parent disconnected');
    }
    async function finishCommand(command, code, signal) {
        clearTimeout(command.timer);
        if (command.termination)
            await command.termination;
        if (active !== command)
            return;
        active = null;
        if (!shuttingDown) {
            if (command.failure) {
                sendResult(command.id, { ok: false, error: command.failure });
            }
            else if (code !== 0) {
                sendResult(command.id, {
                    ok: false,
                    error: `Git exited with ${signal ? `signal ${signal}` : `code ${code ?? 'unknown'}`}`,
                });
            }
            else {
                sendResult(command.id, { ok: true, stdout: Buffer.concat(command.chunks).toString('utf8') });
            }
        }
        if (!shuttingDown)
            scheduleIdleShutdown();
        exitWhenIdle();
    }
    function beginShutdown() {
        if (!shuttingDown) {
            shuttingDown = true;
            if (idleTimer)
                clearTimeout(idleTimer);
            shutdownTimer = setTimeout(() => {
                // Tree termination already had its bounded attempt. This last exact-
                // child kill and hard exit ensure the guardian cannot persist.
                active?.child.kill();
                runtime.exit(1);
            }, SHUTDOWN_HARD_TIMEOUT_MS);
        }
        if (active)
            terminateActive(active, 'Git worker parent disconnected');
        exitWhenIdle();
    }
    function exitWhenIdle() {
        if (!shuttingDown || active || starting)
            return;
        if (shutdownTimer)
            clearTimeout(shutdownTimer);
        if (runtime.connected && runtime.disconnect)
            runtime.disconnect();
    }
    function handleMessage(message) {
        const request = message;
        if (request.type === 'shutdown') {
            beginShutdown();
        }
        else if (request.type === 'cancel' && Number.isSafeInteger(request.id)) {
            const command = active;
            if (command && command.id === request.id)
                terminateActive(command, 'Git command cancelled');
        }
        else if (isRunRequest(message)) {
            runCommand(message);
        }
    }
    runtime.on('message', handleMessage);
    runtime.once('disconnect', beginShutdown);
    scheduleIdleShutdown();
    return {
        handleMessage,
        beginShutdown,
        getState: () => ({ active: active !== null, starting, shuttingDown }),
    };
}
function isDirectEntrypoint() {
    if (!process.argv[1])
        return false;
    const current = path.resolve(fileURLToPath(import.meta.url));
    const entrypoint = path.resolve(process.argv[1]);
    return process.platform === 'win32'
        ? current.toLowerCase() === entrypoint.toLowerCase()
        : current === entrypoint;
}
if (isDirectEntrypoint())
    startWindowsGitWorker();
//# sourceMappingURL=windows-git-worker.js.map