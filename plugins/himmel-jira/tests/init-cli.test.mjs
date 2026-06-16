import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const initCli = resolve(__dirname, '..', 'lib', 'init-cli.mjs');

let emptyEnv;

beforeEach(() => {
  // An env file with no JIRA_* keys, so loadEnvIntoProcess sets nothing.
  const dir = mkdtempSync(join(tmpdir(), 'himmel-initcli-'));
  emptyEnv = join(dir, '.env');
  writeFileSync(emptyEnv, '# no jira keys\n');
});

function discover(extraArgs, envOverrides) {
  // Clear inherited JIRA_PROJECT* so the test machine's real env can't leak in.
  const env = { ...process.env, JIRA_PROJECT_KEY: '', JIRA_PROJECTS: '', ...envOverrides };
  return spawnSync(process.execPath, [initCli, '--discover', '--env-path', emptyEnv, ...extraArgs], {
    encoding: 'utf8',
    env,
  });
}

describe('init-cli --discover project resolution (portability)', () => {
  it('exits 2 with a hint when no project is configured (no HIMMEL default)', () => {
    const r = discover([], {});
    expect(r.status).toBe(2);
    expect(r.stderr).toContain('no project configured');
    expect(r.stderr).toContain('JIRA_PROJECT_KEY');
    // Must NOT silently fall back to the himmel project.
    expect(r.stderr).not.toContain('HIMMEL');
  });
});
