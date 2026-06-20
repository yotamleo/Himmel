import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { uploadAttachment, normalizeEnv, baseUrl } from './client.js';

describe('uploadAttachment', () => {
  let dir: string;
  const origEmail = process.env.JIRA_EMAIL;
  const origToken = process.env.JIRA_API_TOKEN;
  const origBase = process.env.JIRA_BASE_URL;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'jira-attach-'));
    process.env.JIRA_EMAIL = 'u@example.com';
    process.env.JIRA_API_TOKEN = 'secret';
    process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    if (origEmail === undefined) delete process.env.JIRA_EMAIL; else process.env.JIRA_EMAIL = origEmail;
    if (origToken === undefined) delete process.env.JIRA_API_TOKEN; else process.env.JIRA_API_TOKEN = origToken;
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    vi.restoreAllMocks();
  });

  it('POSTs multipart with correct URL, headers, and file field', async () => {
    const file = join(dir, 'screenshot.png');
    writeFileSync(file, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    const fetchMock = vi.fn(async () => ({
      ok: true,
      status: 200,
      text: async () => '[{"id":"10001","filename":"screenshot.png"}]',
    }));
    vi.stubGlobal('fetch', fetchMock);

    const out = await uploadAttachment('HIMMEL-1', file);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://example.atlassian.net/rest/api/3/issue/HIMMEL-1/attachments');
    expect(init.method).toBe('POST');
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toMatch(/^Basic /);
    expect(headers['X-Atlassian-Token']).toBe('no-check');
    expect(headers['Content-Type']).toBeUndefined();
    expect(init.body).toBeInstanceOf(FormData);
    const fd = init.body as FormData;
    const fileField = fd.get('file');
    expect(fileField).toBeInstanceOf(Blob);
    expect((fileField as File).name ?? (fd as unknown as { _filename?: string })._filename).toMatch(/screenshot\.png$/);

    expect(Array.isArray(out)).toBe(true);
    expect((out as Array<{ filename: string }>)[0].filename).toBe('screenshot.png');
  });

  it('throws on missing file with clear message', async () => {
    await expect(uploadAttachment('HIMMEL-1', join(dir, 'nope.png'))).rejects.toThrow(
      /nope\.png/,
    );
  });

  it('normalizeEnv strips trailing CR from CRLF-source env vars (HIMMEL-111)', () => {
    const stderrCaptured: string[] = [];
    const origWrite = process.stderr.write.bind(process.stderr);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (process.stderr as any).write = (chunk: string | Buffer): boolean => {
      stderrCaptured.push(String(chunk));
      return true;
    };
    try {
      process.env.JIRA_API_TOKEN = 'good-token-value\r';
      process.env.JIRA_EMAIL = 'u@example.com\r\n';
      process.env.JIRA_BASE_URL = 'https://example.atlassian.net\r';
      normalizeEnv();
      expect(process.env.JIRA_API_TOKEN).toBe('good-token-value');
      expect(process.env.JIRA_EMAIL).toBe('u@example.com');
      expect(process.env.JIRA_BASE_URL).toBe('https://example.atlassian.net');
      const stderrText = stderrCaptured.join('');
      expect(stderrText).toMatch(/stripped trailing whitespace from JIRA_API_TOKEN/);
      expect(stderrText).toMatch(/stripped trailing whitespace from JIRA_EMAIL/);
      expect(stderrText).toMatch(/stripped trailing whitespace from JIRA_BASE_URL/);
      expect(stderrText).toMatch(/dos2unix/);
    } finally {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (process.stderr as any).write = origWrite;
    }
  });

  it('normalizeEnv is a no-op when values are already clean', () => {
    const stderrCaptured: string[] = [];
    const origWrite = process.stderr.write.bind(process.stderr);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (process.stderr as any).write = (chunk: string | Buffer): boolean => {
      stderrCaptured.push(String(chunk));
      return true;
    };
    try {
      process.env.JIRA_API_TOKEN = 'clean-token';
      process.env.JIRA_EMAIL = 'u@example.com';
      process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
      normalizeEnv();
      expect(stderrCaptured.join('')).toBe('');
    } finally {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (process.stderr as any).write = origWrite;
    }
  });

  it('throws HTTP error including status and body', async () => {
    const file = join(dir, 'a.txt');
    writeFileSync(file, 'hi');
    const fetchMock = vi.fn(async () => ({
      ok: false,
      status: 413,
      text: async () => 'Payload Too Large',
    }));
    vi.stubGlobal('fetch', fetchMock);

    await expect(uploadAttachment('HIMMEL-1', file)).rejects.toThrow(/HTTP 413.*Payload Too Large/);
  });
});

describe('baseUrl', () => {
  const origBase = process.env.JIRA_BASE_URL;

  afterEach(() => {
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
  });

  it('returns JIRA_BASE_URL when set', () => {
    process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
    expect(baseUrl()).toBe('https://example.atlassian.net');
  });

  it('throws when JIRA_BASE_URL is unset — no personal-instance fallback (HIMMEL-286)', () => {
    delete process.env.JIRA_BASE_URL;
    expect(() => baseUrl()).toThrow(/JIRA_BASE_URL is not set/);
  });

  it('throws with actionable guidance when JIRA_BASE_URL is unset', () => {
    delete process.env.JIRA_BASE_URL;
    expect(() => baseUrl()).toThrow(/\.env\.example/);
  });

  it('never falls back to the author instance when unset (HIMMEL-286)', () => {
    delete process.env.JIRA_BASE_URL;
    let message = '';
    try {
      baseUrl();
    } catch (e) {
      message = (e as Error).message;
    }
    expect(message).not.toBe('');
    expect(message).not.toMatch(/yotamleo/);
  });
});

describe('requestAt base composition (HIMMEL-437)', () => {
  const origBase = process.env.JIRA_BASE_URL;
  afterEach(() => {
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    vi.restoreAllMocks();
  });

  it('prefixes the apiBase + path onto baseUrl for each named helper', async () => {
    process.env.JIRA_BASE_URL = 'https://x.example';
    const fetchMock = vi.fn(async () => ({ ok: true, status: 200, text: async () => '{}' }));
    vi.stubGlobal('fetch', fetchMock);
    const { agileRequest, confluenceV2, confluenceV1 } = await import('./client.js');
    await agileRequest('GET', '/board');
    await confluenceV2('GET', '/pages/1');
    await confluenceV1('GET', '/search');
    expect(fetchMock.mock.calls[0][0]).toBe('https://x.example/rest/agile/1.0/board');
    expect(fetchMock.mock.calls[1][0]).toBe('https://x.example/wiki/api/v2/pages/1');
    expect(fetchMock.mock.calls[2][0]).toBe('https://x.example/wiki/rest/api/search');
  });
});

describe('confluenceAuthHeader (HIMMEL-437)', () => {
  const keys = ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'CONFLUENCE_EMAIL', 'CONFLUENCE_API_TOKEN'];
  const orig: Record<string, string | undefined> = {};
  for (const k of keys) orig[k] = process.env[k];
  afterEach(() => {
    for (const k of keys) {
      if (orig[k] === undefined) delete process.env[k]; else process.env[k] = orig[k];
    }
  });

  it('uses CONFLUENCE_* creds when both are set', async () => {
    process.env.JIRA_EMAIL = 'j@x'; process.env.JIRA_API_TOKEN = 'jtok';
    process.env.CONFLUENCE_EMAIL = 'c@x'; process.env.CONFLUENCE_API_TOKEN = 'ctok';
    const { confluenceAuthHeader } = await import('./client.js');
    expect(confluenceAuthHeader()).toBe(`Basic ${Buffer.from('c@x:ctok').toString('base64')}`);
  });

  it('falls back to JIRA_* creds when CONFLUENCE_* is not fully set', async () => {
    process.env.JIRA_EMAIL = 'j@x'; process.env.JIRA_API_TOKEN = 'jtok';
    delete process.env.CONFLUENCE_EMAIL; delete process.env.CONFLUENCE_API_TOKEN;
    const { confluenceAuthHeader, authHeader } = await import('./client.js');
    expect(confluenceAuthHeader()).toBe(authHeader());
  });
});

describe('resolveAccountId (HIMMEL-437)', () => {
  const origBase = process.env.JIRA_BASE_URL;
  afterEach(() => {
    if (origBase === undefined) delete process.env.JIRA_BASE_URL; else process.env.JIRA_BASE_URL = origBase;
    vi.restoreAllMocks();
  });

  it('returns the input unchanged when it has no @ (accountId passthrough)', async () => {
    const { resolveAccountId } = await import('./client.js');
    expect(await resolveAccountId('5b10ac8d82e05b22cc7d4ef5')).toBe('5b10ac8d82e05b22cc7d4ef5');
  });

  it('looks up an email and returns the first accountId', async () => {
    process.env.JIRA_BASE_URL = 'https://x.example';
    const fetchMock = vi.fn(async () => ({ ok: true, status: 200, text: async () => '[{"accountId":"abc"}]' }));
    vi.stubGlobal('fetch', fetchMock);
    const { resolveAccountId } = await import('./client.js');
    expect(await resolveAccountId('a@b.com')).toBe('abc');
    expect(decodeURIComponent(String(fetchMock.mock.calls[0][0]))).toContain('/user/search?query=a@b.com');
  });
});
