import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname } from 'node:path';

function repoRoot(): string {
  try {
    const gitCommonDir = execFileSync(
      'git',
      ['rev-parse', '--git-common-dir'],
      { encoding: 'utf8' },
    ).trim();
    return dirname(gitCommonDir);
  } catch (e) {
    // Pre-HIMMEL-101 this silently fell back to cwd, which masked the case
    // where a corrupt/bare/missing local git state caused jira CLI to load
    // the WRONG .env (cwd) or no creds at all (cwd has no .env) → 401 with
    // no clue why. Surface the underlying error so an operator can diagnose.
    process.stderr.write(
      `jira: warning: git rev-parse --git-common-dir failed (${(e as Error).message}); ` +
        `falling back to cwd=${process.cwd()} for .env lookup. ` +
        `Set JIRA_API_TOKEN/JIRA_BASE_URL via env vars to bypass.\n`,
    );
    return process.cwd();
  }
}

function loadEnv(): void {
  const envPath = `${repoRoot()}/.env`;
  if (!existsSync(envPath)) return;
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
    const [key, ...rest] = trimmed.split('=');
    process.env[key.trim()] ??= rest.join('=').trim();
  }
}

// HIMMEL-111: normalize JIRA_* env vars regardless of how they got into
// process.env. The loadEnv() path above already trims (CRLF-safe), but
// `bash source ~/.config/himmel-cli/jira.env` with a CRLF file (common
// after Windows->Linux scp) preserves the trailing \r in the value, and
// node inherits it via process.env. The malformed Basic auth header then
// returns HTTP 401 with no hint that line endings are the cause. Strip
// trailing whitespace (CR/LF/tab/space) and warn ONCE per affected var so
// the operator can dos2unix their source if this keeps firing.
export function normalizeEnv(): void {
  for (const key of [
    'JIRA_BASE_URL',
    'JIRA_EMAIL',
    'JIRA_API_TOKEN',
    'JIRA_PROJECT_KEY',
    'JIRA_SEVERITY_FIELD',
    'JIRA_BOARD_ID',
    'CONFLUENCE_EMAIL',
    'CONFLUENCE_API_TOKEN',
  ]) {
    const raw = process.env[key];
    if (raw === undefined) continue;
    const cleaned = raw.replace(/[\s]+$/, '');
    if (cleaned !== raw) {
      process.stderr.write(
        `jira: warning: stripped trailing whitespace from ${key} ` +
          '(probably from CRLF env file - run dos2unix on the source to silence)\n',
      );
      process.env[key] = cleaned;
    }
  }
}

loadEnv();
normalizeEnv();

export const baseUrl = (): string => {
  // HIMMEL-286: no hardcoded default. A stranger who sets a token but
  // not the base URL must fail loud here — never silently send requests
  // to the author's instance.
  const url = process.env.JIRA_BASE_URL;
  if (!url) {
    throw new Error(
      'JIRA_BASE_URL is not set. Add it to your .env (or shell environment) ' +
        'and re-run. See .env.example + docs/setup/new-machine.md.',
    );
  }
  return url;
};

export const projectKey = (): string => {
  // HIMMEL-146: no hardcoded default. Operators must set
  // JIRA_PROJECT_KEY explicitly so this plugin is portable across
  // repos/projects without code edits.
  const key = process.env.JIRA_PROJECT_KEY;
  if (!key) {
    throw new Error(
      'JIRA_PROJECT_KEY is not set. Add it to your .env (or shell environment) ' +
        'and re-run. See .env.example + docs/setup/new-machine.md.',
    );
  }
  return key;
};

export const severityField = (): string | undefined =>
  process.env.JIRA_SEVERITY_FIELD || undefined;

export const boardId = (): string | undefined =>
  process.env.JIRA_BOARD_ID || undefined;

export function authHeader(): string {
  const email = process.env.JIRA_EMAIL ?? '';
  const token = process.env.JIRA_API_TOKEN ?? '';
  return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
}

// Confluence often needs its OWN Atlassian token: a *scoped* Jira API token
// 401s against /wiki (Confluence), same as the bitbucket CLI needs a separate
// scoped token. Use CONFLUENCE_EMAIL/CONFLUENCE_API_TOKEN when BOTH are set;
// otherwise fall back to the Jira creds (works when JIRA_API_TOKEN is a
// scopeless/full-account token covering both products).
export function confluenceAuthHeader(): string {
  const email = process.env.CONFLUENCE_EMAIL;
  const token = process.env.CONFLUENCE_API_TOKEN;
  if (email && token) {
    return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
  }
  return authHeader();
}

export async function requestAt<T>(
  apiBase: string,
  method: string,
  path: string,
  body?: unknown,
  auth: string = authHeader(),
): Promise<T> {
  const url = `${baseUrl()}${apiBase}${path}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: auth,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const text = await res.text();
  return (text.trim() ? JSON.parse(text) : {}) as T;
}

export const request = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/rest/api/3', method, path, body);
export const agileRequest = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/rest/agile/1.0', method, path, body);
export const confluenceV2 = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/wiki/api/v2', method, path, body, confluenceAuthHeader());
export const confluenceV1 = <T>(method: string, path: string, body?: unknown) =>
  requestAt<T>('/wiki/rest/api', method, path, body, confluenceAuthHeader());

export async function uploadMultipart(
  url: string,
  filePath: string,
  field = 'file',
  auth: string = authHeader(),
): Promise<unknown> {
  if (!existsSync(filePath)) {
    throw new Error(`attachment not found: ${filePath}`);
  }
  const data = readFileSync(filePath);
  const fd = new FormData();
  fd.append(field, new Blob([data]), basename(filePath));

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: auth,
      'X-Atlassian-Token': 'no-check',
      // intentionally NO Content-Type — fetch must set multipart boundary
    },
    body: fd,
  });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 500);
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const text = await res.text();
  return text.trim() ? JSON.parse(text) : {};
}

// Back-compat wrapper: Jira issue attachment upload composes its own URL.
export function uploadAttachment(issueKey: string, filePath: string): Promise<unknown> {
  return uploadMultipart(
    `${baseUrl()}/rest/api/3/issue/${issueKey}/attachments`,
    filePath,
  );
}

export async function downloadTo(fullUrl: string, outPath: string, auth: string = authHeader()): Promise<number> {
  const res = await fetch(fullUrl, { headers: { Authorization: auth } });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 500);
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  writeFileSync(outPath, buf);
  return buf.length;
}

// Jira accountIds are 24-hex or "<provider>:<uuid>"; an '@' means it's an email.
export async function resolveAccountId(emailOrId: string): Promise<string> {
  if (!emailOrId.includes('@')) return emailOrId;
  const users = await request<Array<{ accountId: string }>>(
    'GET',
    `/user/search?query=${encodeURIComponent(emailOrId)}`,
  );
  if (!users.length) throw new Error(`no Jira user found for "${emailOrId}"`);
  return users[0].accountId;
}

export async function resolveSpaceId(spaceKey: string): Promise<string> {
  const r = await confluenceV2<{ results: Array<{ id: string }> }>(
    'GET',
    `/spaces?keys=${encodeURIComponent(spaceKey)}`,
  );
  if (!r.results?.length) throw new Error(`no Confluence space with key "${spaceKey}"`);
  return r.results[0].id;
}
