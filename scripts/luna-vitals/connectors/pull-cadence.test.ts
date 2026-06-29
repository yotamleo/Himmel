/**
 * pull-cadence.sh behavioral tests — no network, no real connector.
 *
 * Uses the PULL_CMD test seam: the wrapper passes PULL_CMD to `bash -c` so
 * a shell snippet like 'exit 75' substitutes the real pull invocation.
 *
 * The .ps1 twin is verified by code-review parity (not run here):
 * its PULL_CMD seam uses `pwsh -NoProfile -Command $env:PULL_CMD`.
 */
import { test, expect } from 'bun:test';
import { existsSync, mkdtempSync } from 'fs';
import { dirname, join } from 'path';
import { tmpdir } from 'os';

// ── helpers ───────────────────────────────────────────────────────────────────

const SCRIPT = join(import.meta.dir, 'pull-cadence.sh');

/**
 * Locate Git Bash on Windows, avoiding the WSL System32 stub.
 * See luna-upgrade-all.ps1 and docs/internals/environment-gotchas.md.
 */
function findGitBash(): string {
  const candidates: string[] = [
    'C:/Program Files/Git/bin/bash.exe',
    'C:/Program Files (x86)/Git/bin/bash.exe',
  ];
  // Derive from the git.exe location if available.
  const gitExe = Bun.which('git');
  if (gitExe) {
    // git.exe lives at <GitRoot>/cmd/git.exe; bash at <GitRoot>/bin/bash.exe
    const gitRoot = dirname(dirname(gitExe.replace(/\\/g, '/')));
    candidates.push(gitRoot + '/bin/bash.exe');
  }
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  // PATH fallback: exclude Windows System32 WSL stub.
  const pathBash = Bun.which('bash');
  if (pathBash && !pathBash.toLowerCase().includes('system32')) return pathBash;
  return 'bash';
}

const BASH = findGitBash();

interface RunResult {
  rc: number;
  stdout: string;
  stderr: string;
}

/**
 * Invoke pull-cadence.sh with a PULL_CMD snippet and pinned date window.
 * LUNA_VITALS_ARTIFACT_DIR is a fresh tmpdir to avoid cross-test pollution.
 */
async function runWrapper(pullCmdSnippet: string): Promise<RunResult> {
  // Forward-slash path for Git Bash compatibility on Windows.
  const dir = mkdtempSync(join(tmpdir(), 'pull-cadence-test-')).replace(/\\/g, '/');
  const proc = Bun.spawn([BASH, SCRIPT], {
    env: {
      ...process.env,
      PULL_CMD: pullCmdSnippet,
      LUNA_VITALS_ARTIFACT_DIR: dir,
      FROM: '2026-06-28',
      TO: '2026-06-29',
    },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const [rc, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  return { rc, stdout: stdout.trim(), stderr: stderr.trim() };
}

// ── tests ─────────────────────────────────────────────────────────────────────

// 15 s per test — bash startup on Windows can be slow (cold cache).
const TIMEOUT = 15_000;

test('PULL_CMD exit 75 -> wrapper exits 75 and prints re-consent reminder', async () => {
  const { rc, stderr } = await runWrapper('exit 75');
  expect(rc).toBe(75);
  const msg = stderr.toLowerCase();
  // Must mention re-consent and auth steps.
  expect(msg).toContain('re-consent');
  expect(msg).toContain('auth');
}, TIMEOUT);

test('PULL_CMD exit 0 -> wrapper exits 0, artifact path on stdout, no re-consent', async () => {
  const { rc, stdout, stderr } = await runWrapper('exit 0');
  expect(rc).toBe(0);
  // Artifact file name must appear on stdout (operator needs to review it).
  expect(stdout).toContain('gh-2026-06-29.json');
  // No re-consent reminder on success.
  expect(stderr.toLowerCase()).not.toContain('re-consent');
}, TIMEOUT);

test('PULL_CMD exit 1 -> wrapper exits 1, no re-consent reminder', async () => {
  const { rc, stderr } = await runWrapper('exit 1');
  expect(rc).toBe(1);
  expect(stderr.toLowerCase()).not.toContain('re-consent');
}, TIMEOUT);
