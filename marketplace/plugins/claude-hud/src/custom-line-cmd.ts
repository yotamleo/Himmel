import { spawn } from 'node:child_process';
import { isExtraCmdAllowed } from './extra-cmd.js';
import { sanitizeDisplayText } from './utils/sanitize.js';

export const MAX_BUFFER = 10 * 1024;
export const MAX_LINES = 10;
export const MAX_LINE_LENGTH = 200;
export const TIMEOUT_MS = 3000;

// Kill the whole process tree, not just the shell wrapper. Under `shell: true`
// the direct child is the shell (`/bin/sh -c …` / `cmd.exe /c …`); the actual
// command runs as a grandchild. A plain `child.kill()` reaps only the shell, so
// a slow command survives the timeout as an orphan — exactly the HIMMEL-717
// leak class this migration exists to eliminate.
function killChildTree(child: ReturnType<typeof spawn>): void {
  const pid = child.pid;
  if (pid === undefined) {
    return;
  }
  if (process.platform === 'win32') {
    // taskkill /T reaps the tree; /F forces it. Best-effort, fire-and-forget.
    try {
      spawn('taskkill', ['/pid', String(pid), '/t', '/f'], { windowsHide: true });
    } catch {
      try {
        child.kill();
      } catch {
        /* already gone */
      }
    }
  } else {
    // The child was spawned `detached`, so it leads its own process group; a
    // negative pid signals the whole group, reaping any grandchild.
    try {
      process.kill(-pid, 'SIGKILL');
    } catch {
      try {
        child.kill('SIGKILL');
      } catch {
        /* already gone */
      }
    }
  }
}

export function shouldRunCustomLine(
  cmd: string | undefined,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  return Boolean(cmd) && isExtraCmdAllowed(env);
}

export async function runCustomLineCommand(
  cmd: string,
  stdinJson: string,
  opts: { cwd?: string; timeout?: number } = {},
): Promise<string[] | null> {
  return new Promise(resolve => {
    let stdout = '';
    let stdoutBytes = 0;
    let settled = false;
    let timedOut = false;

    const finish = (result: string[] | null) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(result);
    };

    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(cmd, {
        shell: true,
        cwd: opts.cwd,
        windowsHide: true,
        // POSIX: own process group so killChildTree can signal the whole group.
        detached: process.platform !== 'win32',
        // stderr is unused; ignoring it avoids a full-pipe write-block when a
        // command spews >64KB to stderr (it would otherwise stall until the
        // timeout fires). stdin + stdout stay piped.
        stdio: ['pipe', 'pipe', 'ignore'],
      });
    } catch {
      finish(null);
      return;
    }

    const timeout = setTimeout(() => {
      timedOut = true;
      killChildTree(child);
      finish(null);
    }, opts.timeout ?? TIMEOUT_MS);

    // Decode as UTF-8 on the stream so Node's StringDecoder buffers any
    // multi-byte sequence split across chunk boundaries — accumulating
    // `String(chunk)` per raw Buffer chunk would garble such characters (the
    // where-are-we composer emits non-ASCII) and skew the byte count.
    child.stdout?.setEncoding('utf8');
    child.stdout?.on('data', (chunk: string) => {
      stdoutBytes += Buffer.byteLength(chunk);
      if (stdoutBytes > MAX_BUFFER) {
        clearTimeout(timeout);
        killChildTree(child);
        finish(null);
        return;
      }
      stdout += chunk;
    });

    child.on('error', () => {
      clearTimeout(timeout);
      finish(null);
    });

    child.on('close', code => {
      clearTimeout(timeout);
      if (timedOut || code !== 0) {
        finish(null);
        return;
      }

      const lines = stdout.split(/\r?\n/);
      while (lines.length > 0 && lines[lines.length - 1] === '') {
        lines.pop();
      }

      const sanitized = lines
        .slice(0, MAX_LINES)
        .map(line => sanitizeDisplayText(line).slice(0, MAX_LINE_LENGTH));

      finish(sanitized.length > 0 ? sanitized : null);
    });

    // The child may close stdin before (or while) we write — e.g. a command
    // that ignores stdin, or one that exits fast. Without this listener the
    // resulting EPIPE surfaces as an unhandled 'error' event and crashes the
    // render process. The child 'close'/'error' handlers settle the result.
    child.stdin?.on('error', () => {});
    child.stdin?.write(stdinJson);
    child.stdin?.end();
  });
}
