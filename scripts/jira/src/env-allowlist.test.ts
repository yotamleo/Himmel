import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Reintroducing the blanket loader must leak these dummy unrelated keys.
const keys = [
  'JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_PROJECT_KEY',
  'JIRA_SEVERITY_FIELD', 'JIRA_BOARD_ID', 'CONFLUENCE_EMAIL', 'CONFLUENCE_API_TOKEN',
  'TEST_ANTHROPIC_API_KEY', 'UNRELATED_API_KEY', 'HANDOVER_DIR',
];
vi.mock('node:fs', async (importOriginal) => {
  const real = await importOriginal<typeof import('node:fs')>();
  const fixture = [
    'JIRA_BASE_URL=https://fixture.invalid', 'JIRA_EMAIL=fixture@example.invalid',
    'JIRA_API_TOKEN=dummy', 'JIRA_PROJECT_KEY=FIXTURE', 'JIRA_SEVERITY_FIELD=customfield_1',
    'JIRA_BOARD_ID=42', 'CONFLUENCE_EMAIL=wiki@example.invalid', 'CONFLUENCE_API_TOKEN=dummy-wiki',
    'TEST_ANTHROPIC_API_KEY=dummy-test', 'UNRELATED_API_KEY=dummy-unrelated', 'HANDOVER_DIR=/dummy',
  ].join('\n');
  return {
    ...real,
    existsSync: (p: Parameters<typeof real.existsSync>[0]) => String(p).endsWith('/.env') || real.existsSync(p),
    readFileSync: (...args: Parameters<typeof real.readFileSync>) => String(args[0]).endsWith('/.env') ? fixture : real.readFileSync(...args),
  };
});

beforeEach(() => {
  vi.resetModules();
  for (const key of keys) vi.stubEnv(key, undefined);
});
afterEach(() => vi.unstubAllEnvs());

describe('dotenv allowlist', () => {
  it('jira-cli-env-excludes-unlisted-keys', async () => {
    await import('./client.js');
    for (const key of ['TEST_ANTHROPIC_API_KEY', 'UNRELATED_API_KEY', 'HANDOVER_DIR']) {
      expect(process.env[key]).toBeUndefined();
    }
  });
  it('consumer-keys-still-load: Jira and Confluence', async () => {
    const client = await import('./client.js');
    expect(client.baseUrl()).toBe('https://fixture.invalid');
    expect(client.projectKey()).toBe('FIXTURE');
    expect(client.severityField()).toBe('customfield_1');
    expect(client.boardId()).toBe('42');
    expect(client.authHeader()).toBe(`Basic ${Buffer.from('fixture@example.invalid:dummy').toString('base64')}`);
    expect(client.confluenceAuthHeader()).toBe(`Basic ${Buffer.from('wiki@example.invalid:dummy-wiki').toString('base64')}`);
  });
  it('live values still win', async () => {
    vi.stubEnv('JIRA_PROJECT_KEY', 'LIVE');
    const client = await import('./client.js');
    expect(client.projectKey()).toBe('LIVE');
  });
});
