import { describe, it, expect } from 'vitest';
import {
  parseArgs,
  extractKeys,
  parseKeyFile,
  versionSpec,
  assignFirstTags,
  planSync,
  runSync,
  checkNotTruncated,
} from './sync-versions.mjs';

// I/O-boundary functions this file does NOT cover (loadReleases, loadPrs,
// gitReach, makeJira, main): each needs `gh`, a git repo with the release tags,
// or a live Jira endpoint. The pure planner and the runSync orchestration are
// covered below through injected fakes.

const RELEASES = [
  { tagName: 'v0.1.0-pre.1', name: 'first', isPrerelease: true, isDraft: false, publishedAt: '2026-09-08T09:55:39Z' },
  { tagName: 'v0.1.0', name: 'himmel v1 (Linux)', isPrerelease: false, isDraft: false, publishedAt: '2026-09-09T14:50:47Z' },
  { tagName: 'v0.9.9', name: 'unpublished', isPrerelease: false, isDraft: true, publishedAt: null },
];

describe('parseArgs', () => {
  it('defaults to dry-run; --apply turns writes on, a later --dry-run turns them off', () => {
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    expect(parseArgs([]).apply).toBe(false);
    expect(parseArgs(['--apply']).apply).toBe(true);
    expect(parseArgs(['--apply', '--dry-run']).apply).toBe(false);
  });

  it('parses --project, --repo and --jira-cli', () => {
    const o = parseArgs(['--project', 'FOO', '--repo', 'a/b', '--jira-cli', '/x/index.js']);
    expect(o.project).toBe('FOO');
    expect(o.repo).toBe('a/b');
    expect(o.jiraCli).toBe('/x/index.js');
  });
});

describe('extractKeys', () => {
  it('takes every bracketed key of the project, once each, in order', () => {
    expect(extractKeys('fix(x): [HIMMEL-3290] a; [HIMMEL-3304] b [HIMMEL-3290]', 'HIMMEL')).toEqual([
      'HIMMEL-3290',
      'HIMMEL-3304',
    ]);
  });

  it('ignores unbracketed keys and other projects', () => {
    expect(extractKeys('HIMMEL-1 and [LUNA-2] and [HIMMEL-3]', 'HIMMEL')).toEqual(['HIMMEL-3']);
  });

  it('returns nothing for a title with no key', () => {
    expect(extractKeys('chore: bump', 'HIMMEL')).toEqual([]);
  });
});

describe('versionSpec', () => {
  it('a published pre-release: released, dated, description says pre-release', () => {
    expect(versionSpec(RELEASES[0])).toEqual({
      name: 'v0.1.0-pre.1',
      released: true,
      releaseDate: '2026-09-08',
      description: 'GitHub pre-release v0.1.0-pre.1',
    });
  });

  it('a full release: released, description carries the release title', () => {
    expect(versionSpec(RELEASES[1])).toEqual({
      name: 'v0.1.0',
      released: true,
      releaseDate: '2026-09-09',
      description: 'GitHub release v0.1.0 - himmel v1 (Linux)',
    });
  });
});

describe('assignFirstTags', () => {
  it('maps each commit to the FIRST tag (in the given order) that reaches it', () => {
    const reach = new Map([
      ['t1', new Set(['a', 'b'])],
      ['t2', new Set(['a', 'b', 'c'])],
      ['t3', new Set(['a', 'b', 'c', 'd'])],
    ]);
    const m = assignFirstTags(['t1', 't2', 't3'], reach);
    expect(m.get('a')).toBe('t1');
    expect(m.get('c')).toBe('t2');
    expect(m.get('d')).toBe('t3');
    expect(m.has('z')).toBe(false);
  });

  it('skips a tag whose reach set is missing (tag not in the local clone)', () => {
    const reach = new Map([['t2', new Set(['a'])]]);
    expect(assignFirstTags(['t1', 't2'], reach).get('a')).toBe('t2');
  });
});

describe('planSync', () => {
  const base = {
    project: 'HIMMEL',
    releases: RELEASES,
    prs: [
      { number: 1, title: 'feat: [HIMMEL-10] one', sha: 'a' },
      { number: 2, title: 'feat: [HIMMEL-11] [HIMMEL-12] two', sha: 'b' },
      { number: 3, title: 'chore: no ticket', sha: 'a' },
      { number: 4, title: 'fix: [HIMMEL-99] ghost', sha: 'b' },
      { number: 5, title: 'fix: [HIMMEL-13] not yet tagged', sha: 'zzz' },
    ],
    shaToTag: new Map([['a', 'v0.1.0-pre.1'], ['b', 'v0.1.0']]),
    jiraVersions: [],
    jiraKeys: new Set(['HIMMEL-10', 'HIMMEL-11', 'HIMMEL-12', 'HIMMEL-13']),
    carriers: new Map(),
  };

  it('creates every published tag as a version, skips drafts', () => {
    const p = planSync(base);
    expect(p.createVersions.map((v) => v.name)).toEqual(['v0.1.0-pre.1', 'v0.1.0']);
  });

  it('adds the first-tag version to each cited key that exists in Jira', () => {
    const p = planSync(base);
    expect(p.addFix).toEqual([
      { key: 'HIMMEL-10', version: 'v0.1.0-pre.1' },
      { key: 'HIMMEL-11', version: 'v0.1.0' },
      { key: 'HIMMEL-12', version: 'v0.1.0' },
    ]);
  });

  it('reports keys cited by PRs that Jira does not have, with the PR numbers', () => {
    expect(planSync(base).unknownKeys).toEqual([{ key: 'HIMMEL-99', prs: [4] }]);
  });

  it('counts PRs with no tagged merge commit as untagged and leaves their keys alone', () => {
    const p = planSync(base);
    expect(p.counts.prsUntagged).toBe(1);
    expect(p.addFix.some((a) => a.key === 'HIMMEL-13')).toBe(false);
  });

  it('is idempotent: existing versions and carriers produce no writes', () => {
    const p = planSync({
      ...base,
      jiraVersions: [
        { name: 'v0.1.0-pre.1', released: true, releaseDate: '2026-09-08' },
        { name: 'v0.1.0', released: true, releaseDate: '2026-09-09' },
      ],
      carriers: new Map([
        ['v0.1.0-pre.1', new Set(['HIMMEL-10'])],
        ['v0.1.0', new Set(['HIMMEL-11', 'HIMMEL-12'])],
      ]),
    });
    expect(p.createVersions).toEqual([]);
    expect(p.releaseVersions).toEqual([]);
    expect(p.addFix).toEqual([]);
    expect(p.counts.fixAlready).toBe(3);
  });

  it('releases an existing version that is not yet released', () => {
    const p = planSync({
      ...base,
      jiraVersions: [{ name: 'v0.1.0', released: false }],
    });
    expect(p.releaseVersions).toEqual([{ name: 'v0.1.0', releaseDate: '2026-09-09' }]);
    expect(p.createVersions.map((v) => v.name)).toEqual(['v0.1.0-pre.1']);
  });

  it('never plans a version that is not a GitHub tag (v1.0.0 is left alone)', () => {
    const p = planSync({ ...base, jiraVersions: [{ name: 'v1.0.0', released: false }] });
    expect(p.releaseVersions).toEqual([]);
    expect(p.createVersions.some((v) => v.name === 'v1.0.0')).toBe(false);
  });

  it('a key in two PRs gets both tag versions (fixVersion is multi-valued)', () => {
    const p = planSync({
      ...base,
      prs: [
        { number: 1, title: '[HIMMEL-10] slice 1', sha: 'a' },
        { number: 2, title: '[HIMMEL-10] slice 2', sha: 'b' },
      ],
    });
    expect(p.addFix).toEqual([
      { key: 'HIMMEL-10', version: 'v0.1.0-pre.1' },
      { key: 'HIMMEL-10', version: 'v0.1.0' },
    ]);
  });
});

describe('v1.0.0 scope (--v1-keys)', () => {
  const base = {
    project: 'HIMMEL',
    releases: [],
    prs: [],
    shaToTag: new Map(),
    jiraVersions: [],
    jiraKeys: new Set(['HIMMEL-374', 'HIMMEL-1084']),
    carriers: new Map(),
  };
  const v1 = { version: 'v1.0.0', description: 'Linux GA; scope = the v1 milestone tickets', keys: ['HIMMEL-374', 'HIMMEL-1084', 'HIMMEL-5'] };

  it('creates v1.0.0 unreleased and adds it to every listed key that exists', () => {
    const p = planSync({ ...base, v1 });
    expect(p.createVersions).toEqual([
      { name: 'v1.0.0', released: false, description: v1.description },
    ]);
    expect(p.addFix).toEqual([
      { key: 'HIMMEL-374', version: 'v1.0.0' },
      { key: 'HIMMEL-1084', version: 'v1.0.0' },
    ]);
  });

  it('reports a listed key that Jira does not have', () => {
    expect(planSync({ ...base, v1 }).unknownKeys).toEqual([{ key: 'HIMMEL-5', prs: [] }]);
  });

  it('is idempotent once v1.0.0 exists and carries the keys', () => {
    const p = planSync({
      ...base,
      v1,
      jiraVersions: [{ name: 'v1.0.0', released: false }],
      carriers: new Map([['v1.0.0', new Set(['HIMMEL-374', 'HIMMEL-1084'])]]),
    });
    expect(p.createVersions).toEqual([]);
    expect(p.addFix).toEqual([]);
    expect(p.counts.fixAlready).toBe(2);
  });

  it('without --v1-keys nothing about v1.0.0 is planned', () => {
    const p = planSync(base);
    expect(p.createVersions).toEqual([]);
    expect(p.addFix).toEqual([]);
  });

  it('parseArgs takes --v1-keys <file>', () => {
    expect(parseArgs(['--project', 'HIMMEL', '--v1-keys', '/tmp/k.txt']).v1KeysFile).toBe('/tmp/k.txt');
  });

  it('parseKeyFile keeps one key per line, skipping blanks and # comments', () => {
    expect(parseKeyFile('HIMMEL-1\n\n# note\n  HIMMEL-2  \nHIMMEL-1\n')).toEqual(['HIMMEL-1', 'HIMMEL-2']);
  });

  it('parseKeyFile rejects a line that is not a Jira key', () => {
    expect(() => parseKeyFile('HIMMEL-1\nnot a key\n')).toThrow(/not a Jira key/);
  });

  it('creates v1.0.0 once when it is ALSO a published GitHub release', () => {
    const v1Release = { tagName: 'v1.0.0', name: 'v1.0.0', isPrerelease: false, isDraft: false, publishedAt: '2026-12-01T00:00:00Z' };
    const p = planSync({ ...base, releases: [...RELEASES, v1Release], v1 });
    expect(p.createVersions.filter((v) => v.name === 'v1.0.0')).toHaveLength(1);
  });

  it('runSync applies v1.0.0: create, then add to the listed keys', async () => {
    const { writes, deps } = fakeDeps({
      loadReleases: async () => [],
      loadPrs: async () => [],
    });
    await runSync({ project: 'HIMMEL', apply: true, v1Keys: ['HIMMEL-10'] }, deps);
    expect(writes).toEqual([
      ['create', 'v1.0.0'],
      ['fix', 'HIMMEL-10', 'v1.0.0'],
    ]);
  });
});

function fakeDeps(over = {}) {
  const writes = [];
  const jira = {
    versions: async () => [],
    keys: async () => new Set(['HIMMEL-10']),
    carriers: async () => new Set(),
    createVersion: async (spec) => writes.push(['create', spec.name]),
    releaseVersion: async (name) => writes.push(['release', name]),
    fixVersion: async (key, name) => writes.push(['fix', key, name]),
    ...(over.jira ?? {}),
  };
  return {
    writes,
    deps: {
      loadReleases: async () => [RELEASES[0]],
      loadPrs: async () => [{ number: 1, title: '[HIMMEL-10] x', sha: 'a' }],
      reach: async () => new Set(['a']),
      jira,
      log: () => {},
      ...over,
      ...(over.jira ? { jira } : {}),
    },
  };
}

describe('runSync', () => {
  it('dry-run plans but performs no Jira write', async () => {
    const { writes, deps } = fakeDeps();
    const report = await runSync({ project: 'HIMMEL', apply: false }, deps);
    expect(writes).toEqual([]);
    expect(report.counts.versionsCreate).toBe(1);
    expect(report.counts.fixAdd).toBe(1);
  });

  it('--apply performs the writes: create the version first, then add the fixVersion', async () => {
    const { writes, deps } = fakeDeps();
    await runSync({ project: 'HIMMEL', apply: true }, deps);
    expect(writes).toEqual([
      ['create', 'v0.1.0-pre.1'],
      ['fix', 'HIMMEL-10', 'v0.1.0-pre.1'],
    ]);
  });

  it('a second apply against the synced state writes nothing', async () => {
    const { writes, deps } = fakeDeps({
      jira: {
        versions: async () => [{ name: 'v0.1.0-pre.1', released: true, releaseDate: '2026-09-08' }],
        keys: async () => new Set(['HIMMEL-10']),
        carriers: async () => new Set(['HIMMEL-10']),
      },
    });
    const report = await runSync({ project: 'HIMMEL', apply: true }, deps);
    expect(writes).toEqual([]);
    expect(report.counts.fixAlready).toBe(1);
  });

  it('a failing write is recorded and the run continues; report.failed counts it', async () => {
    const { deps } = fakeDeps({
      loadPrs: async () => [
        { number: 1, title: '[HIMMEL-10] x', sha: 'a' },
        { number: 2, title: '[HIMMEL-11] y', sha: 'a' },
      ],
      jira: {
        keys: async () => new Set(['HIMMEL-10', 'HIMMEL-11']),
        fixVersion: async (key) => {
          if (key === 'HIMMEL-10') throw new Error('HTTP 400');
        },
      },
    });
    const report = await runSync({ project: 'HIMMEL', apply: true }, deps);
    expect(report.failed).toHaveLength(1);
    expect(report.failed[0]).toMatch(/HIMMEL-10/);
  });

  it('--apply refuses (zero writes) when a published tag is missing from the local clone', async () => {
    const { writes, deps } = fakeDeps({
      loadReleases: async () => [RELEASES[0], RELEASES[1]],
      reach: async (tag) => (tag === RELEASES[0].tagName ? null : new Set(['a'])),
    });
    await expect(runSync({ project: 'HIMMEL', apply: true }, deps)).rejects.toThrow(/git fetch --tags/);
    expect(writes).toEqual([]);
  });

  it('dry-run still reports a missing tag instead of throwing', async () => {
    const { deps } = fakeDeps({
      loadReleases: async () => [RELEASES[0], RELEASES[1]],
      reach: async (tag) => (tag === RELEASES[0].tagName ? null : new Set(['a'])),
    });
    const report = await runSync({ project: 'HIMMEL', apply: false }, deps);
    expect(report.missingTags).toEqual([RELEASES[0].tagName]);
  });
});

describe('checkNotTruncated', () => {
  it('passes a result shorter than the limit', () => {
    expect(() => checkNotTruncated(new Array(9), 10, 'releases')).not.toThrow();
  });

  it('throws when the result hit the limit (it may be cut off)', () => {
    expect(() => checkNotTruncated(new Array(10), 10, 'releases')).toThrow(/releases.*10/);
  });
});
