import { describe, it, expect, vi, beforeEach } from 'vitest';

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
    if (path.includes('/transitions')) {
      return { transitions: [
        { id: '11', to: { name: 'To Do' } },
        { id: '21', to: { name: 'In Progress' } },
        { id: '31', to: { name: 'Done' } },
      ] };
    }
    // The enhanced /search/jql returns the same `{ issues: [...] }` shape;
    // return a sample issue so the transitions-parse success path is exercised.
    if (path.startsWith('/search')) return { issues: [{ key: 'ACME-1' }] };
    return {};
  }),
}));

const { discoverMetadata } = await import('../lib/init-flow.mjs');
const { jiraFetch } = await import('../lib/jira-fetch.mjs');

beforeEach(() => { jiraFetch.mockClear(); });

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

  it('warns (not silently) when a configured key is not returned (HIMMEL-334)', async () => {
    const errs = [];
    const spy = vi.spyOn(process.stderr, 'write').mockImplementation((s) => { errs.push(String(s)); return true; });
    try {
      await discoverMetadata(['ACME', 'NOPE']);
    } finally {
      spy.mockRestore();
    }
    expect(errs.join('')).toContain("configured project 'NOPE' not found");
  });

  it('queries transitions via the enhanced /search/jql endpoint, not the removed /search?jql (HIMMEL-337)', async () => {
    await discoverMetadata(['ACME']);
    const searchCalls = jiraFetch.mock.calls.filter(([, path]) => path.startsWith('/search'));
    expect(searchCalls.length).toBeGreaterThan(0);
    for (const [, path] of searchCalls) {
      expect(path).toContain('/search/jql?jql=');
      expect(path).not.toMatch(/\/search\?jql=/);
    }
  });

  it('consumes the /search/jql response shape — transitions parse into the cache (HIMMEL-337)', async () => {
    // Guards against a silent regression: if the new endpoint returned a
    // different shape, search.issues[0].key would be undefined and transitions
    // would silently stay empty. Proves the success path still works.
    const out = await discoverMetadata(['ACME']);
    expect(out.projects.ACME.transitions).toEqual({ 'To Do': '11', 'In Progress': '21', 'Done': '31' });
  });
});
