import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  buildVersionCreateBody,
  buildFixVersionBody,
  listVersions,
  createVersion,
  releaseVersion,
  setFixVersion,
} from './versions.js';

interface Call {
  method: string;
  url: string;
  body: unknown;
}

// Mocked Jira: records every request and answers from a route table keyed by
// "<METHOD> <path>" (path = everything after /rest/api/3).
function stubJira(routes: Record<string, unknown>): Call[] {
  const calls: Call[] = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string, init: { method: string; body?: string }) => {
      const path = url.replace('https://x.example/rest/api/3', '');
      calls.push({
        method: init.method,
        url: path,
        body: init.body ? JSON.parse(init.body) : undefined,
      });
      const hit = routes[`${init.method} ${path}`];
      if (hit === undefined) {
        return { ok: false, status: 404, text: async () => `no route ${init.method} ${path}` };
      }
      return {
        ok: true,
        status: 200,
        text: async () => (hit === '' ? '' : JSON.stringify(hit)),
      };
    }),
  );
  return calls;
}

const VERSIONS = [
  { id: '10001', name: 'v0.2.0', released: true, releaseDate: '2026-09-10' },
  { id: '10002', name: 'v1.0.0', released: false },
];

beforeEach(() => {
  process.env.JIRA_BASE_URL = 'https://x.example';
  process.env.JIRA_PROJECT_KEY = 'HIMMEL';
});
afterEach(() => vi.unstubAllGlobals());

describe('buildVersionCreateBody', () => {
  it('carries only name + project when no options are given', () => {
    expect(buildVersionCreateBody('HIMMEL', 'v1.0.0', {})).toEqual({
      name: 'v1.0.0',
      project: 'HIMMEL',
    });
  });

  it('maps description, release date and released', () => {
    expect(
      buildVersionCreateBody('HIMMEL', 'v0.2.0', {
        description: 'stable',
        releaseDate: '2026-09-10',
        released: true,
      }),
    ).toEqual({
      name: 'v0.2.0',
      project: 'HIMMEL',
      description: 'stable',
      releaseDate: '2026-09-10',
      released: true,
    });
  });

  it('rejects a release date that is not YYYY-MM-DD', () => {
    expect(() =>
      buildVersionCreateBody('HIMMEL', 'v1', { releaseDate: '09/10/2026' }),
    ).toThrow(/YYYY-MM-DD/);
  });

  it('rejects a blank version name', () => {
    expect(() => buildVersionCreateBody('HIMMEL', '  ', {})).toThrow(/name/);
  });
});

describe('buildFixVersionBody', () => {
  it('builds an add update by version name', () => {
    expect(buildFixVersionBody('add', 'v1.0.0')).toEqual({
      update: { fixVersions: [{ add: { name: 'v1.0.0' } }] },
    });
  });

  it('builds a remove update by version name', () => {
    expect(buildFixVersionBody('remove', 'v1.0.0')).toEqual({
      update: { fixVersions: [{ remove: { name: 'v1.0.0' } }] },
    });
  });
});

describe('listVersions', () => {
  it('GETs the project versions and prints name, released, releaseDate', async () => {
    const calls = stubJira({ 'GET /project/HIMMEL/versions': VERSIONS });
    const rows = await listVersions('HIMMEL');
    expect(calls).toHaveLength(1);
    expect(rows).toEqual([
      'v0.2.0\ttrue\t2026-09-10',
      'v1.0.0\tfalse\t',
    ]);
  });
});

describe('createVersion', () => {
  it('POSTs /version with the built body', async () => {
    const calls = stubJira({ 'POST /version': { id: '10003', name: 'v1.0.0' } });
    const out = await createVersion('HIMMEL', 'v1.0.0', { description: 'GA' });
    expect(calls[0]).toEqual({
      method: 'POST',
      url: '/version',
      body: { name: 'v1.0.0', project: 'HIMMEL', description: 'GA' },
    });
    expect(out).toBe('Created version v1.0.0 (id 10003)');
  });
});

describe('releaseVersion', () => {
  it('resolves the id by name then PUTs released:true (+ date)', async () => {
    const calls = stubJira({
      'GET /project/HIMMEL/versions': VERSIONS,
      'PUT /version/10002': {},
    });
    const out = await releaseVersion('HIMMEL', 'v1.0.0', '2026-09-22');
    expect(calls[1]).toEqual({
      method: 'PUT',
      url: '/version/10002',
      body: { released: true, releaseDate: '2026-09-22' },
    });
    expect(out).toBe('Released version v1.0.0');
  });

  it('omits releaseDate when --date is not given', async () => {
    const calls = stubJira({
      'GET /project/HIMMEL/versions': VERSIONS,
      'PUT /version/10002': {},
    });
    await releaseVersion('HIMMEL', 'v1.0.0');
    expect(calls[1].body).toEqual({ released: true });
  });

  it('throws when the version name does not exist', async () => {
    stubJira({ 'GET /project/HIMMEL/versions': VERSIONS });
    await expect(releaseVersion('HIMMEL', 'v9.9.9')).rejects.toThrow(/no version named "v9.9.9"/);
  });
});

describe('setFixVersion', () => {
  it('PUTs the add update on the issue', async () => {
    const calls = stubJira({ 'PUT /issue/HIMMEL-374': '' });
    const out = await setFixVersion('HIMMEL-374', 'add', 'v1.0.0');
    expect(calls).toEqual([
      {
        method: 'PUT',
        url: '/issue/HIMMEL-374',
        body: { update: { fixVersions: [{ add: { name: 'v1.0.0' } }] } },
      },
    ]);
    expect(out).toBe('HIMMEL-374 fixVersion +v1.0.0');
  });

  it('PUTs the remove update on the issue', async () => {
    const calls = stubJira({ 'PUT /issue/HIMMEL-374': '' });
    const out = await setFixVersion('HIMMEL-374', 'remove', 'v1.0.0');
    expect(calls[0].body).toEqual({ update: { fixVersions: [{ remove: { name: 'v1.0.0' } }] } });
    expect(out).toBe('HIMMEL-374 fixVersion -v1.0.0');
  });
});
