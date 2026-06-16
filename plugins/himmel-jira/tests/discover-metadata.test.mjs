import { describe, it, expect, vi } from 'vitest';

// Stub the network layer so discoverMetadata runs offline. /project/search
// deliberately returns the projects in a DIFFERENT order than configured
// (BETA before ACME) to prove default_project follows the configured order,
// not the API response order.
vi.mock('../lib/jira-fetch.mjs', () => ({
  envFilePath: () => '/tmp/unused.env',
  jiraFetch: vi.fn(async (_method, path) => {
    if (path === '/project/search') {
      return { values: [
        { key: 'BETA', id: '2', name: 'Beta' },
        { key: 'ACME', id: '1', name: 'Acme' },
      ] };
    }
    if (path.includes('/issuetypes')) return { issueTypes: [] };
    if (path.startsWith('/search')) return { issues: [] };
    return {};
  }),
}));

const { discoverMetadata } = await import('../lib/init-flow.mjs');

describe('discoverMetadata default_project ordering', () => {
  it('default_project follows configured order, not API response order', async () => {
    const out = await discoverMetadata(['ACME', 'BETA']);
    expect(out.default_project).toBe('ACME');
    expect(Object.keys(out.projects)).toEqual(['ACME', 'BETA']);
  });

  it('drops a configured key the API does not return, default_project stays first-resolved', async () => {
    const out = await discoverMetadata(['ACME', 'NOPE']);
    expect(out.default_project).toBe('ACME');
    expect(Object.keys(out.projects)).toEqual(['ACME']);
  });
});
