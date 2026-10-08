import { it, expect, vi, beforeEach, afterEach } from 'vitest';

const keys = ['BITBUCKET_EMAIL', 'BITBUCKET_API_TOKEN', 'BITBUCKET_WORKSPACE', 'BITBUCKET_REPO_SLUG', 'TEST_ANTHROPIC_API_KEY', 'JIRA_API_TOKEN'];
vi.mock('node:fs', async (importOriginal) => {
  const real = await importOriginal<typeof import('node:fs')>();
  const fixture = 'BITBUCKET_EMAIL=fixture@example.invalid\nBITBUCKET_API_TOKEN=dummy\nBITBUCKET_WORKSPACE=fixture\nBITBUCKET_REPO_SLUG=repo\nTEST_ANTHROPIC_API_KEY=dummy-test\nJIRA_API_TOKEN=dummy-jira\n';
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

it('bitbucket-env-excludes-unlisted-keys', async () => {
  await import('./env.js');
  expect(process.env.TEST_ANTHROPIC_API_KEY).toBeUndefined();
  expect(process.env.JIRA_API_TOKEN).toBeUndefined();
});
it('consumer-keys-still-load: Bitbucket', async () => {
  const env = await import('./env.js');
  expect(env.authHeader()).toBe(`Basic ${Buffer.from('fixture@example.invalid:dummy').toString('base64')}`);
  expect(process.env.BITBUCKET_WORKSPACE).toBe('fixture');
  expect(process.env.BITBUCKET_REPO_SLUG).toBe('repo');
});
