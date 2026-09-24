import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir, platform } from 'node:os';
import { join, resolve } from 'node:path';
import { envFilePath, jiraFetch } from '../lib/jira-fetch.mjs';

// envFilePath behaviour depends on:
//   1. git rev-parse --git-common-dir (to find repo root)
//   2. existsSync(join(repoRoot, '.env'))
//   3. HOME / USERPROFILE env for the fallback path
//
// We test the explicit-override path (trivially safe) and the fallback path
// (where no .env exists in the git root and we just check the returned value
// is deterministic — we do NOT write to the real ~/.config).

describe('envFilePath', () => {
  it('returns the custom path when an explicit override is given', () => {
    expect(envFilePath('/custom/path/jira.env')).toBe('/custom/path/jira.env');
  });

  it('returns a non-null string for undefined override (no crash)', () => {
    // This runs in a git repo (the himmel worktree), so git rev-parse succeeds.
    // The result is either the in-repo .env (if present) or the home fallback.
    const result = envFilePath(undefined);
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });

  it('returns HOME-based fallback when HOME is set and cwd is outside any git repo', () => {
    // Deterministic fallback branch: chdir into a fresh, non-git mktemp dir so
    // repoRoot()'s `git rev-parse --git-common-dir` fails (not a repository)
    // and falls back to cwd itself, which has no .env — guaranteeing the
    // HOME-fallback branch runs, rather than depending on whether the real
    // checkout happens to have a .env (previously a no-op pass either way).
    const fakeHome = mkdtempSync(join(tmpdir(), 'himmel-jira-home-'));
    const nonRepoDir = mkdtempSync(join(tmpdir(), 'himmel-jira-norepo-'));
    const origHome = process.env.HOME;
    const origUserProfile = process.env.USERPROFILE;
    const origCwd = process.cwd();
    process.env.HOME = fakeHome;
    process.env.USERPROFILE = fakeHome;
    process.chdir(nonRepoDir);
    try {
      const result = envFilePath(undefined);
      expect(result).toBe(join(fakeHome, '.config', 'himmel-cli', 'jira.env'));
    } finally {
      process.chdir(origCwd);
      if (origHome === undefined) delete process.env.HOME;
      else process.env.HOME = origHome;
      if (origUserProfile === undefined) delete process.env.USERPROFILE;
      else process.env.USERPROFILE = origUserProfile;
    }
  });

  it('returns the in-repo .env when one exists, taking precedence over the HOME fallback', () => {
    // Repository precedence, tested independently of the HOME-fallback branch
    // above: a real git repo whose root has a committed .env must win even
    // when HOME points elsewhere.
    const fakeHome = mkdtempSync(join(tmpdir(), 'himmel-jira-home2-'));
    const repoDir = mkdtempSync(join(tmpdir(), 'himmel-jira-repo-'));
    const origHome = process.env.HOME;
    const origUserProfile = process.env.USERPROFILE;
    const origCwd = process.cwd();
    execFileSync('git', ['init', '-q'], { cwd: repoDir });
    writeFileSync(join(repoDir, '.env'), 'JIRA_BASE_URL=https://example.atlassian.net\n');
    process.env.HOME = fakeHome;
    process.env.USERPROFILE = fakeHome;
    process.chdir(repoDir);
    try {
      const result = envFilePath(undefined);
      // repoRoot() derives the root from `git rev-parse --git-common-dir`,
      // which git may print relative (".git") to the invoking cwd — resolve
      // against repoDir (the cwd at call time) rather than assume an
      // absolute path, then confirm it lands on the exact fixture file.
      expect(resolve(repoDir, result)).toBe(join(repoDir, '.env'));
    } finally {
      process.chdir(origCwd);
      if (origHome === undefined) delete process.env.HOME;
      else process.env.HOME = origHome;
      if (origUserProfile === undefined) delete process.env.USERPROFILE;
      else process.env.USERPROFILE = origUserProfile;
    }
  });
});

describe('jiraFetch error path', () => {
  let origFetch;
  let origBase;
  let origEmail;
  let origToken;

  beforeEach(() => {
    origFetch = globalThis.fetch;
    origBase = process.env.JIRA_BASE_URL;
    origEmail = process.env.JIRA_EMAIL;
    origToken = process.env.JIRA_API_TOKEN;
    process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
    process.env.JIRA_EMAIL = 'a@b.com';
    process.env.JIRA_API_TOKEN = 'secret-token';
  });

  afterEach(() => {
    globalThis.fetch = origFetch;
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    if (origEmail === undefined) delete process.env.JIRA_EMAIL; else process.env.JIRA_EMAIL = origEmail;
    if (origToken === undefined) delete process.env.JIRA_API_TOKEN; else process.env.JIRA_API_TOKEN = origToken;
  });

  it('throws Error with HTTP status + truncated (300 chars + ellipsis) body on non-2xx', async () => {
    const longBody = 'x'.repeat(500);
    globalThis.fetch = vi.fn(async () => ({
      ok: false,
      status: 500,
      text: async () => longBody,
    }));
    await expect(jiraFetch('GET', '/myself')).rejects.toThrow(/HTTP 500/);
    globalThis.fetch = vi.fn(async () => ({
      ok: false,
      status: 500,
      text: async () => longBody,
    }));
    let caught;
    try { await jiraFetch('GET', '/myself'); } catch (e) { caught = e; }
    expect(caught).toBeDefined();
    expect(caught.message).toContain('x'.repeat(300) + '…');
    expect(caught.message).not.toContain('x'.repeat(301));
  });

  it('does NOT truncate body when it is exactly 300 chars or fewer', async () => {
    const shortBody = 'y'.repeat(300);
    globalThis.fetch = vi.fn(async () => ({
      ok: false,
      status: 400,
      text: async () => shortBody,
    }));
    let caught;
    try { await jiraFetch('GET', '/myself'); } catch (e) { caught = e; }
    expect(caught.message).toContain(shortBody);
    expect(caught.message).not.toContain('…');
  });

  it('builds Authorization header as Basic base64(email:token)', async () => {
    let capturedHeaders;
    globalThis.fetch = vi.fn(async (url, init) => {
      capturedHeaders = init.headers;
      return { ok: true, text: async () => '{}' };
    });
    await jiraFetch('GET', '/myself');
    const expected = 'Basic ' + Buffer.from('a@b.com:secret-token').toString('base64');
    expect(capturedHeaders.Authorization).toBe(expected);
    expect(capturedHeaders['Content-Type']).toBe('application/json');
    expect(capturedHeaders.Accept).toBe('application/json');
  });

  it('appends /rest/api/3 prefix to path', async () => {
    let capturedUrl;
    globalThis.fetch = vi.fn(async (url) => {
      capturedUrl = url;
      return { ok: true, text: async () => '{}' };
    });
    await jiraFetch('GET', '/myself');
    expect(capturedUrl).toBe('https://example.atlassian.net/rest/api/3/myself');
  });

  it('throws when JIRA_BASE_URL is unset', async () => {
    delete process.env.JIRA_BASE_URL;
    await expect(jiraFetch('GET', '/myself')).rejects.toThrow(/JIRA_BASE_URL not set/);
  });

  it('returns {} for 2xx with empty body', async () => {
    globalThis.fetch = vi.fn(async () => ({ ok: true, text: async () => '' }));
    const out = await jiraFetch('GET', '/myself');
    expect(out).toEqual({});
  });

  it('serializes body as JSON when provided', async () => {
    let capturedBody;
    globalThis.fetch = vi.fn(async (url, init) => {
      capturedBody = init.body;
      return { ok: true, text: async () => '{}' };
    });
    await jiraFetch('POST', '/issue', { fields: { summary: 'hi' } });
    expect(capturedBody).toBe(JSON.stringify({ fields: { summary: 'hi' } }));
  });
});
