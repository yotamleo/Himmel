import { describe, it, expect } from 'vitest';
import { parseAuthStatus, REQUIRED_SCOPES, runInit, buildErrorStderr } from '../lib/init-flow.mjs';

const LOGGED_IN_STDOUT = `github.com
  ✓ Logged in to github.com account yotamleo (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
`;

const LOGGED_IN_MISSING_SCOPE_STDOUT = `github.com
  ✓ Logged in to github.com account yotamleo (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: 'gist', 'repo'
`;

const ENV_TOKEN_STDOUT = `github.com
  ✓ Logged in to github.com account yotamleo (GH_TOKEN)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: none
`;

const NOT_LOGGED_IN_STDERR = `You are not logged in to any GitHub hosts. To log in, run: gh auth login
`;

describe('parseAuthStatus', () => {
  it('keyring mode with all required scopes → ok, exit 0', () => {
    const r = parseAuthStatus({
      stdout: LOGGED_IN_STDOUT,
      stderr: '',
      exitCode: 0,
      envHasToken: false,
    });
    expect(r.mode).toBe('keyring');
    expect(r.user).toBe('yotamleo');
    expect(r.scopes).toEqual(expect.arrayContaining(['repo', 'read:org', 'workflow']));
    expect(r.missingScopes).toEqual([]);
    expect(r.exitCode).toBe(0);
    expect(r.summary).toMatch(/^gh OK: yotamleo @ github\.com \| scopes:/);
  });

  it('keyring mode missing scope → ok with warning, exit 0', () => {
    const r = parseAuthStatus({
      stdout: LOGGED_IN_MISSING_SCOPE_STDOUT,
      stderr: '',
      exitCode: 0,
      envHasToken: false,
    });
    expect(r.mode).toBe('keyring');
    expect(r.missingScopes).toEqual(expect.arrayContaining(['read:org', 'workflow']));
    expect(r.exitCode).toBe(0);
    expect(r.summary).toMatch(/missing: read:org, workflow/);
  });

  it('env-token mode → ok with skip-note, exit 0', () => {
    const r = parseAuthStatus({
      stdout: ENV_TOKEN_STDOUT,
      stderr: '',
      exitCode: 0,
      envHasToken: true,
    });
    expect(r.mode).toBe('env-token');
    expect(r.user).toBe('yotamleo');
    expect(r.missingScopes).toEqual([]);
    expect(r.exitCode).toBe(0);
    expect(r.summary).toMatch(/env-token, scope check skipped/);
  });

  it('not logged in → exit 1 with login instructions', () => {
    const r = parseAuthStatus({
      stdout: '',
      stderr: NOT_LOGGED_IN_STDERR,
      exitCode: 1,
      envHasToken: false,
    });
    expect(r.mode).toBe('unauth');
    expect(r.exitCode).toBe(1);
    expect(r.summary).toMatch(/gh auth login --web/);
  });

  it('GH_TOKEN env without gh detecting it (older gh) → still classified env-token by envHasToken', () => {
    const r = parseAuthStatus({
      stdout: LOGGED_IN_STDOUT.replace('(keyring)', '(oauth_token)'),
      stderr: '',
      exitCode: 0,
      envHasToken: true,
    });
    expect(r.mode).toBe('env-token');
  });

  it('REQUIRED_SCOPES exported as repo, read:org, workflow', () => {
    expect(REQUIRED_SCOPES).toEqual(['repo', 'read:org', 'workflow']);
  });

  it('extractScopes handles double-quoted scopes + trailing comma', () => {
    const stdout = `github.com
  ✓ Logged in to github.com account x (keyring)
  - Token scopes: "repo", "read:org", "workflow",
`;
    const r = parseAuthStatus({ stdout, stderr: '', exitCode: 0, envHasToken: false });
    expect(r.scopes).toEqual(expect.arrayContaining(['repo', 'read:org', 'workflow']));
    expect(r.missingScopes).toEqual([]);
  });

  it('Token scopes line missing → mode=keyring but treated as empty (caught by missing-scope warn)', () => {
    const stdout = `github.com
  ✓ Logged in to github.com account x (keyring)
  - Active account: true
`;
    const r = parseAuthStatus({ stdout, stderr: '', exitCode: 0, envHasToken: false });
    expect(r.scopes).toEqual([]);
    expect(r.missingScopes).toEqual(['repo', 'read:org', 'workflow']);
    expect(r.summary).toMatch(/missing: repo, read:org, workflow/);
  });

  it('extractUser returns null on unrecognised format → summary uses ? placeholder', () => {
    const stdout = `garbled output with no Logged-in line
  - Token scopes: 'repo', 'read:org', 'workflow'
`;
    const r = parseAuthStatus({ stdout, stderr: '', exitCode: 0, envHasToken: false });
    expect(r.user).toBeNull();
    expect(r.summary).toContain('? @ github.com');
  });
});

describe('runInit', () => {
  it('ENOENT (exitCode 127) → install-banner summary, exitCode 127, mode unauth', async () => {
    const execGh = async () => ({ stdout: '', stderr: 'gh: command not found\n', exitCode: 127 });
    const r = await runInit({ execGh, env: {} });
    expect(r.exitCode).toBe(127);
    expect(r.mode).toBe('unauth');
    expect(r.user).toBeNull();
    expect(r.scopes).toEqual([]);
    expect(r.missingScopes).toEqual([]);
    expect(r.summary).toMatch(/gh CLI not found on PATH/);
    expect(r.summary).toMatch(/https:\/\/cli\.github\.com/);
  });

  it('signal-killed close → exitCode 1, stderr carries signal name', async () => {
    const execGh = async () => ({
      stdout: '',
      stderr: 'gh killed by signal SIGTERM\n',
      exitCode: 129,
    });
    const r = await runInit({ execGh, env: {} });
    expect(r.exitCode).toBe(1);
    expect(r.mode).toBe('unauth');
    expect(r.stderrHint).toMatch(/SIGTERM/);
  });

  it('non-ENOENT spawn error → exitCode 1, stderr contains err.code (EACCES/EPERM)', async () => {
    const execGh = async () => ({
      stdout: '',
      stderr: 'EACCES: permission denied, spawn gh\n',
      exitCode: 1,
    });
    const r = await runInit({ execGh, env: {} });
    expect(r.exitCode).toBe(1);
    expect(r.stderrHint).toMatch(/EACCES/);
  });
});

import { spawnSync } from 'node:child_process';
import { resolve as pathResolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const INIT_CLI = pathResolve(fileURLToPath(new URL('.', import.meta.url)), '../lib/init-cli.mjs');

describe('init-cli unhandled-throw contract', () => {
  it('unexpected throw → one-line summary on stderr, non-zero exit, no node stack', () => {
    const r = spawnSync(process.execPath, [INIT_CLI], { encoding: 'utf8' });
    const stdoutLines = r.stdout.trim().split('\n').filter(Boolean);
    expect(stdoutLines.length).toBeLessThanOrEqual(1);
    expect(r.stderr).not.toMatch(/UnhandledPromiseRejection/);
    expect(r.stderr).not.toMatch(/at process\.<anonymous>/);
  });
});

describe('buildErrorStderr', () => {
  it('prepends err.code when present (EACCES)', () => {
    const out = buildErrorStderr('prior\n', Object.assign(new Error('boom'), { code: 'EACCES' }));
    expect(out).toBe('prior\nEACCES: boom\n');
  });

  it('falls back to message-only when err.code is absent', () => {
    const out = buildErrorStderr('', new Error('boom'));
    expect(out).toBe('boom\n');
  });

  it('handles non-Error throwables (string)', () => {
    const out = buildErrorStderr('', 'boom');
    expect(out).toBe('boom\n');
  });
});
