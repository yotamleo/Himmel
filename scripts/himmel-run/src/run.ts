import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { existsSync, mkdirSync, openSync, closeSync, statSync } from 'node:fs';
import type { RunResult, IndexEntry } from './types.js';
import { cacheRoot } from './paths.js';
import { appendLog, rotateIfLarge } from './log.js';
import { withLock } from './lock.js';
import { extractSummary } from './summary.js';
import { writeEntry, generateRunId } from './index-store.js';
import { redact, DEFAULT_REDACT_PATTERNS } from './redact.js';
import { shouldRetryExit, shouldRunRecovery, computeBackoffMs, sleep } from './retry.js';

export interface RunInput {
  tag: string;
  cmd: [string, ...string[]];
  summaryJq?: string;
  summaryRegex?: string;
  retryOn?: number[];
  retryJitterMs?: [number, number];
  onStderrMatch?: string;
  thenCmd?: string[];
  redactRegex?: string[];
  noCache?: boolean;
  cacheRootOverride?: string;
  env?: Record<string, string>;
}

function fileSize(p: string): number {
  try {
    return statSync(p).size;
  } catch {
    return 0;
  }
}

async function execOnce(
  cmd: string[],
  env: Record<string, string>,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let settled = false;
    const settle = (v: { stdout: string; stderr: string; exitCode: number }) => {
      if (settled) return;
      settled = true;
      resolve(v);
    };
    const proc = spawn(cmd[0], cmd.slice(1), {
      env: { ...process.env, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    proc.stdout.on('data', (d: Buffer) => (stdout += d.toString()));
    proc.stderr.on('data', (d: Buffer) => (stderr += d.toString()));
    proc.on('error', (err: NodeJS.ErrnoException) => {
      const code = err.code === 'ENOENT' ? 127 : 1;
      settle({ stdout, stderr: `${stderr}${err.message}\n`, exitCode: code });
    });
    proc.on('close', (code: number | null, signal: NodeJS.Signals | null) => {
      let exitCode = code ?? 0;
      if (code === null && signal) {
        // Process killed by signal: use POSIX 128+signum convention
        exitCode = signal === 'SIGKILL' ? 137 : signal === 'SIGTERM' ? 143 : 128;
      }
      settle({ stdout, stderr, exitCode });
    });
  });
}

export async function run(input: RunInput): Promise<RunResult> {
  // B10: guard against path traversal via tag
  if (!input.tag || /[/\\]|^\.\.?$/.test(input.tag)) {
    throw new Error(`himmel-run: invalid tag "${input.tag}" (no path separators or '..' allowed)`);
  }

  // B11: runtime guard for empty cmd (TypeScript erases tuple type at runtime)
  if (input.cmd.length === 0) {
    throw new Error('himmel-run: cmd must be non-empty');
  }

  // Validate retryJitterMs before any side effects (log dirs, execution)
  if (input.retryJitterMs) {
    const [base, cap] = input.retryJitterMs;
    if (base >= cap) throw new Error('himmel-run: retryJitterMs base must be < cap');
  }

  const root = input.cacheRootOverride ?? cacheRoot();
  const tDir = join(root, input.tag);
  const normal = join(tDir, 'normal.log');
  const err = join(tDir, 'error.log');
  const idx = join(tDir, 'index');

  // Ensure tDir exists before withLock (proper-lockfile requires target to exist)
  mkdirSync(tDir, { recursive: true, mode: 0o700 });

  // B2: lock on a per-tag file (not the directory) so sibling tags don't share one lock
  const lockFile = join(tDir, '.lock');
  if (!existsSync(lockFile)) {
    const fd = openSync(lockFile, 'a');
    closeSync(fd);
  }

  const runId = generateRunId();
  const startedAt = new Date().toISOString();
  const patterns = input.redactRegex ?? DEFAULT_REDACT_PATTERNS;
  const env = input.env ?? {};

  let { stdout, stderr, exitCode } = await execOnce(input.cmd, env);

  // Execution flow: 1 initial attempt → optional 1 recovery retry → up to 2
  // exit-code retries = max 4 executions. Recovery happens before the retry loop.

  // Recovery hook: if stderr matches pattern, run recovery cmd then retry once
  if (
    input.onStderrMatch &&
    input.thenCmd &&
    shouldRunRecovery(stderr, input.onStderrMatch)
  ) {
    // B9: capture recovery result; surface failure in stderr
    const rec = await execOnce(input.thenCmd, env);
    if (rec.exitCode !== 0) {
      stderr += `\n[recovery exit=${rec.exitCode}] ${rec.stderr}`;
    }
    const next = await execOnce(input.cmd, env);
    const nextStderr = next.stderr;
    exitCode = next.exitCode;
    stdout = next.stdout;
    stderr = (stderr + nextStderr).trim();
  }

  // Exit-code retry: up to 2 retries (3 total attempts)
  let attempts = 1;
  while (exitCode !== 0 && shouldRetryExit(exitCode, input.retryOn) && attempts < 3) {
    const [base, cap] = input.retryJitterMs ?? [200, 800];
    await sleep(computeBackoffMs(base, cap));
    ({ stdout, stderr, exitCode } = await execOnce(input.cmd, env));
    attempts++;
  }

  const redactedOut = redact(stdout, patterns);
  const redactedErr = redact(stderr, patterns);

  // B6: rotate logs AND capture offsets INSIDE the lock to prevent concurrent races
  let logStart = 0, logEnd = 0, errStart = 0, errEnd = 0;
  await withLock(lockFile, async () => {
    rotateIfLarge(normal);
    rotateIfLarge(err);
    logStart = fileSize(normal);
    if (redactedOut) appendLog(normal, redactedOut.endsWith('\n') ? redactedOut : redactedOut + '\n');
    logEnd = fileSize(normal);
    errStart = fileSize(err);
    if (redactedErr) appendLog(err, redactedErr.endsWith('\n') ? redactedErr : redactedErr + '\n');
    errEnd = fileSize(err);
  });

  const summary = extractSummary({
    stdout: redactedOut,
    stderr: redactedErr,
    exitCode,
    summaryJq: input.summaryJq,
    summaryRegex: input.summaryRegex,
  });

  const finishedAt = new Date().toISOString();
  // HIMMEL-101 §6: bytesToClient = length of the formatted summary line AFTER
  // the 200-char cap applied at index.ts:59. This must mirror the index.ts
  // slice exactly so the cached entry agrees with what Claude actually received.
  const rawLine = `exit=${exitCode} | ${summary} | run=${runId}`;
  const bytesToClient = rawLine.slice(0, 200).length;
  const result: RunResult = { runId, exitCode, summary, bytesToClient, startedAt, finishedAt };

  if (!input.noCache) {
    const entry: IndexEntry = {
      ...result,
      tag: input.tag,
      cmd: input.cmd,
      logOffsetStart: logStart,
      logOffsetEnd: logEnd,
      errOffsetStart: errStart,
      errOffsetEnd: errEnd,
    };
    writeEntry(idx, entry);
  }

  return result;
}
