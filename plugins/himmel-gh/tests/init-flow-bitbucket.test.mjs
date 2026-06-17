import { describe, it, expect } from 'vitest';
import { runInit } from '../lib/init-flow.mjs';

const okAuth = async () => ({ stdout: '', stderr: '', exitCode: 0 });
const failAuth = async () => ({ stdout: '', stderr: 'auth 401\n', exitCode: 1 });
const userSlug = (slug, exitCode = 0) => async () => ({
  stdout: `${slug}\n`,
  stderr: '',
  exitCode,
});

describe('runInit — bitbucket forge', () => {
  it('auth status exit 0 → mode bitbucket, user from user --slug, exit 0', async () => {
    const r = await runInit({
      forge: 'bitbucket',
      execBitbucketAuth: okAuth,
      execBitbucketUserSlug: userSlug('yotamleo'),
    });
    expect(r.mode).toBe('bitbucket');
    expect(r.user).toBe('yotamleo');
    expect(r.scopes).toEqual([]);
    expect(r.missingScopes).toEqual([]);
    expect(r.exitCode).toBe(0);
    expect(r.summary).toBe('bitbucket OK: yotamleo @ bitbucket.org');
  });

  it('auth status non-zero → unauth with BITBUCKET_EMAIL/API_TOKEN hint, exit 1', async () => {
    const r = await runInit({
      forge: 'bitbucket',
      execBitbucketAuth: failAuth,
      execBitbucketUserSlug: userSlug('yotamleo'),
    });
    expect(r.mode).toBe('unauth');
    expect(r.user).toBeNull();
    expect(r.exitCode).toBe(1);
    expect(r.summary).toMatch(/BITBUCKET_EMAIL \+ BITBUCKET_API_TOKEN/);
  });

  it('user --slug failure is best-effort → still OK, user "?"', async () => {
    const r = await runInit({
      forge: 'bitbucket',
      execBitbucketAuth: okAuth,
      execBitbucketUserSlug: userSlug('', 1),
    });
    expect(r.mode).toBe('bitbucket');
    expect(r.exitCode).toBe(0);
    expect(r.summary).toBe('bitbucket OK: ? @ bitbucket.org');
  });

  it('FORGE=bitbucket env (no forge arg) routes to the bitbucket path', async () => {
    const r = await runInit({
      env: { FORGE: 'bitbucket' },
      execBitbucketAuth: okAuth,
      execBitbucketUserSlug: userSlug('ws-user'),
    });
    expect(r.mode).toBe('bitbucket');
    expect(r.user).toBe('ws-user');
  });
});

describe('runInit — github default on undetermined forge', () => {
  it('no FORGE → github path (uses injected execGh), never the bitbucket branch', async () => {
    const execGh = async () => ({
      stdout: `github.com\n  ✓ Logged in to github.com account yotamleo (keyring)\n  - Token scopes: 'repo', 'read:org', 'workflow'\n`,
      stderr: '',
      exitCode: 0,
    });
    // No `forge`, no FORGE env → detectForge falls back to github.
    const r = await runInit({ execGh, env: {} });
    expect(r.mode).toBe('keyring');
    expect(r.user).toBe('yotamleo');
    expect(r.exitCode).toBe(0);
  });
});
