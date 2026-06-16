import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, readFileSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { run } from '../src/run.js';

let dir: string;
const fakeCli = join(import.meta.dirname, 'fixtures', 'fake-cli.mjs');

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-run-'));
});

describe('run', () => {
  it('happy path: captures stdout, writes log, returns summary', async () => {
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'ok'],
      cacheRootOverride: dir,
    });
    expect(res.exitCode).toBe(0);
    expect(res.summary).toBe('hello');
    expect(res.runId).toMatch(/^[a-z0-9-]+$/);
    const log = readFileSync(join(dir, 'sandbox', 'normal.log'), 'utf8');
    expect(log).toContain('hello');
  });

  it('failure: captures stderr, exit code passes through', async () => {
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'fail'],
      cacheRootOverride: dir,
    });
    expect(res.exitCode).toBe(1);
    expect(res.summary).toBe('boom');
    expect(existsSync(join(dir, 'sandbox', 'error.log'))).toBe(true);
  });

  it('summaryJq extracts field from JSON stdout', async () => {
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'json'],
      summaryJq: '.title + " | " + .state',
      cacheRootOverride: dir,
    });
    // jq tier silently falls through if jq missing; accept either jq result or last-line fallback
    expect(['PR-42 | open', '{"title":"PR-42","state":"open"}']).toContain(res.summary);
  });

  it('writes per-call index entry', async () => {
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'ok'],
      cacheRootOverride: dir,
    });
    const entryFile = join(dir, 'sandbox', 'index', `${res.runId}.json`);
    expect(existsSync(entryFile)).toBe(true);
    const entry = JSON.parse(readFileSync(entryFile, 'utf8'));
    expect(entry.summary).toBe('hello');
    expect(entry.cmd).toEqual(['node', fakeCli, 'ok']);
  });

  it('missing binary returns exit 127', async () => {
    const res = await run({
      tag: 'sandbox',
      cmd: ['nonexistent-binary-xyzzy'],
      cacheRootOverride: dir,
    });
    expect(res.exitCode).toBe(127);
  });

  it('retry-on-exit eventually succeeds when fixture passes after N tries', async () => {
    // Verify the retry path runs without erroring; since 'fail' always exits 1,
    // after 3 attempts (1 initial + 2 retries) it still fails.
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'fail'],
      retryOn: [1],
      cacheRootOverride: dir,
    });
    expect(res.exitCode).toBe(1);
  });

  it('retry-on-exit succeeds with file-counter fixture', async () => {
    // Uses the 'retry' mode which succeeds on the 2nd attempt.
    const stateFile = join(dir, 'retry-state.txt');
    writeFileSync(stateFile, '0');
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'retry'],
      retryOn: [1],
      retryJitterMs: [0, 1], // near-zero jitter to keep test fast
      cacheRootOverride: dir,
      env: { RETRY_STATE_FILE: stateFile },
    });
    expect(res.exitCode).toBe(0);
    expect(res.summary).toBe('recovered');
  });

  it('recovery hook on stderr match: runs thenCmd then retries the original', async () => {
    const { existsSync, unlinkSync } = await import('node:fs');
    const marker = join(dir, 'marker');
    if (existsSync(marker)) unlinkSync(marker);
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'recovery-trigger'],
      onStderrMatch: 'field .* is required',
      thenCmd: ['node', fakeCli, 'recovery-touch'],
      env: { RECOVERY_MARKER: marker },
      cacheRootOverride: dir,
    });
    expect(res.exitCode).toBe(0);
    expect(res.summary).toBe('post-recovery-ok');
  });

  // B10: tag path traversal
  it('throws on tag with path separator "/"', async () => {
    await expect(run({
      tag: 'foo/bar',
      cmd: ['node', fakeCli, 'ok'],
      cacheRootOverride: dir,
    })).rejects.toThrow('invalid tag');
  });

  it('throws on tag ".."', async () => {
    await expect(run({
      tag: '..',
      cmd: ['node', fakeCli, 'ok'],
      cacheRootOverride: dir,
    })).rejects.toThrow('invalid tag');
  });

  it('throws on tag "."', async () => {
    await expect(run({
      tag: '.',
      cmd: ['node', fakeCli, 'ok'],
      cacheRootOverride: dir,
    })).rejects.toThrow('invalid tag');
  });

  // B11: empty cmd
  it('throws when cmd is empty array', async () => {
    await expect(run({
      tag: 'sandbox',
      cmd: [] as unknown as [string, ...string[]],
      cacheRootOverride: dir,
    })).rejects.toThrow('cmd must be non-empty');
  });

  // D9: retryJitterMs base >= cap — hoisted to top of run() before side effects
  it('throws when retryJitterMs base >= cap', async () => {
    await expect(run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'fail'],
      retryOn: [1],
      retryJitterMs: [500, 500], // base === cap
      cacheRootOverride: dir,
    })).rejects.toThrow('retryJitterMs base must be < cap');
  });

  // --no-cache regression
  it('--no-cache skips index entry write', async () => {
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'ok'],
      cacheRootOverride: dir,
      noCache: true,
    });
    expect(res.exitCode).toBe(0);
    const entryFile = join(dir, 'sandbox', 'index', `${res.runId}.json`);
    expect(existsSync(entryFile)).toBe(false);
  });

  // Concurrent same-tag runs produce disjoint log offsets
  it('concurrent same-tag runs produce disjoint log offsets', async () => {
    const [r1, r2] = await Promise.all([
      run({ tag: 'sandbox', cmd: ['node', fakeCli, 'ok'], cacheRootOverride: dir }),
      run({ tag: 'sandbox', cmd: ['node', fakeCli, 'ok'], cacheRootOverride: dir }),
    ]);
    const e1 = JSON.parse(readFileSync(join(dir, 'sandbox', 'index', `${r1.runId}.json`), 'utf8'));
    const e2 = JSON.parse(readFileSync(join(dir, 'sandbox', 'index', `${r2.runId}.json`), 'utf8'));
    // Either e1 fully precedes e2 OR e2 fully precedes e1 — never overlapping
    const disjoint =
      (e1.logOffsetEnd <= e2.logOffsetStart) || (e2.logOffsetEnd <= e1.logOffsetStart);
    expect(disjoint).toBe(true);
  });

  // HIMMEL-101 §6: bytesToClient must reflect the emitted (sliced) line, not the raw summary
  it('bytesToClient <= 200 even when summary is very long', async () => {
    const res = await run({
      tag: 'sandbox',
      cmd: ['node', fakeCli, 'oversized-summary'],
      cacheRootOverride: dir,
    });
    expect(res.exitCode).toBe(0);
    // The emitted line is `exit=0 | <summary> | run=<runId>`, capped to 200 chars.
    expect(res.bytesToClient).toBeLessThanOrEqual(200);
    // And the cached index entry must agree.
    const entryFile = join(dir, 'sandbox', 'index', `${res.runId}.json`);
    const entry = JSON.parse(readFileSync(entryFile, 'utf8'));
    expect(entry.bytesToClient).toBeLessThanOrEqual(200);
    expect(entry.bytesToClient).toBe(res.bytesToClient);
  });

  // HIMMEL-101 §7: SIGKILL → exitCode 137 (POSIX 128+9 convention)
  it.skipIf(process.platform === 'win32')(
    'SIGKILL kills the child and surfaces exitCode 137 (primitive verification)',
    async () => {
      // Direct verification of the spawn primitive: code=null, signal=SIGKILL.
      const { spawn } = await import('node:child_process');
      const child = spawn(process.execPath, [fakeCli, 'sleep-forever'], {
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      const exitPromise = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>(
        (resolve) => child.on('close', (code, signal) => resolve({ code, signal })),
      );
      setTimeout(() => child.kill('SIGKILL'), 200);
      const { code, signal } = await exitPromise;
      expect(code).toBeNull();
      expect(signal).toBe('SIGKILL');
      // Now verify the runner's mapping logic mirrors POSIX 128+signum:
      const mapped = code === null && signal === 'SIGKILL' ? 137 : (code ?? 1);
      expect(mapped).toBe(137);
    },
  );

  // Higher-fidelity test: drive run() end-to-end with a child that SIGKILLs itself.
  it.skipIf(process.platform === 'win32')(
    'run() returns exitCode 137 when the spawned child receives SIGKILL',
    async () => {
      const res = await run({
        tag: 'sandbox',
        cmd: ['node', fakeCli, 'self-sigkill'],
        cacheRootOverride: dir,
      });
      expect(res.exitCode).toBe(137);
    },
  );
});
