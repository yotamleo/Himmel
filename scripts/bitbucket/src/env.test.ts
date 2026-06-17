import { describe, it, expect, afterEach } from 'vitest';
import { authHeader, normalizeEnv } from './env.js';

describe('normalizeEnv', () => {
  const keys = ['BITBUCKET_EMAIL', 'BITBUCKET_API_TOKEN', 'BITBUCKET_WORKSPACE', 'BITBUCKET_REPO_SLUG'];
  const saved = Object.fromEntries(keys.map((k) => [k, process.env[k]]));
  afterEach(() => {
    for (const k of keys) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it('strips trailing CR/whitespace from CRLF-sourced env vars (CRLF-safe Basic auth)', () => {
    process.env.BITBUCKET_API_TOKEN = 'tok\r';
    process.env.BITBUCKET_EMAIL = 'u@example.com\r\n';
    normalizeEnv();
    expect(process.env.BITBUCKET_API_TOKEN).toBe('tok');
    expect(process.env.BITBUCKET_EMAIL).toBe('u@example.com');
  });

  it('is a no-op when values are already clean', () => {
    process.env.BITBUCKET_EMAIL = 'u@example.com';
    process.env.BITBUCKET_API_TOKEN = 'clean';
    normalizeEnv();
    expect(process.env.BITBUCKET_EMAIL).toBe('u@example.com');
    expect(process.env.BITBUCKET_API_TOKEN).toBe('clean');
  });
});

describe('authHeader', () => {
  const origEmail = process.env.BITBUCKET_EMAIL;
  const origToken = process.env.BITBUCKET_API_TOKEN;
  afterEach(() => {
    if (origEmail === undefined) delete process.env.BITBUCKET_EMAIL;
    else process.env.BITBUCKET_EMAIL = origEmail;
    if (origToken === undefined) delete process.env.BITBUCKET_API_TOKEN;
    else process.env.BITBUCKET_API_TOKEN = origToken;
  });

  it('builds a Basic header from email:token', () => {
    process.env.BITBUCKET_EMAIL = 'u@example.com';
    process.env.BITBUCKET_API_TOKEN = 'secret';
    const h = authHeader();
    expect(h).toBe(`Basic ${Buffer.from('u@example.com:secret').toString('base64')}`);
  });

  it('throws an actionable error when creds are missing', () => {
    delete process.env.BITBUCKET_EMAIL;
    delete process.env.BITBUCKET_API_TOKEN;
    expect(() => authHeader()).toThrow(/BITBUCKET_EMAIL and BITBUCKET_API_TOKEN/);
  });
});
