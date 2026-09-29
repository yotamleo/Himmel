import { describe, it, expect } from 'vitest';
import {
  alignmentFromGoals,
  buildRoadmapFields,
  computeRoi,
  effortLabel,
  effortPoints,
  goalOptions,
  resolveRoadmapFields,
  roadmapExport,
  roadmapGet,
  roadmapSet,
  syncSprints,
  type RoadmapIds,
} from './roadmap.js';

interface Call { method: string; path: string; body?: unknown }

// Injected request stub: answers from a route table keyed "<METHOD> <path>";
// a function value computes the answer from the body. Unknown routes throw.
function stub(routes: Record<string, unknown>) {
  const calls: Call[] = [];
  const req = (async (method: string, path: string, body?: unknown) => {
    calls.push({ method, path, body });
    const hit = routes[`${method} ${path}`];
    if (hit === undefined) throw new Error(`no route ${method} ${path}`);
    return typeof hit === 'function' ? (hit as (b: unknown) => unknown)(body) : hit;
  }) as never;
  return { req, calls };
}

const IDS: RoadmapIds = {
  readiness: 'customfield_10171',
  theme: 'customfield_10172',
  goals: 'customfield_10173',
  impact: 'customfield_10174',
  alignment: 'customfield_10175',
  roi: 'customfield_10176',
  auditDate: 'customfield_10177',
  auditEvidence: 'customfield_10178',
  closeCandidate: 'customfield_10179',
  effort: 'customfield_10016',
};

const FIELD_LIST = [
  { id: 'customfield_10171', name: 'Readiness' },
  { id: 'customfield_10172', name: 'Theme' },
  { id: 'customfield_10173', name: 'Roadmap Goals' },
  { id: 'customfield_10174', name: 'Roadmap Impact' },
  { id: 'customfield_10175', name: 'Alignment' },
  { id: 'customfield_10176', name: 'ROI' },
  { id: 'customfield_10177', name: 'Audit date' },
  { id: 'customfield_10178', name: 'Audit evidence' },
  { id: 'customfield_10179', name: 'Close candidate' },
  { id: 'customfield_10016', name: 'Story point estimate' },
  { id: 'customfield_10004', name: 'Impact' },
];

describe('resolveRoadmapFields', () => {
  it('maps every roadmap field name to its id', async () => {
    const { req } = stub({ 'GET /field': FIELD_LIST });
    expect(await resolveRoadmapFields(req)).toEqual(IDS);
  });

  it('fails loud when a field is missing', async () => {
    const { req } = stub({ 'GET /field': FIELD_LIST.filter((f) => f.name !== 'ROI') });
    await expect(resolveRoadmapFields(req)).rejects.toThrow(/ROI/);
  });
});

describe('effort, alignment, ROI', () => {
  it('maps size buckets to S-equivalents, x1.3 for guard work', () => {
    expect(effortPoints('M')).toBe(2.2);
    expect(effortPoints('xs')).toBe(0.44);
    expect(effortPoints('L', true)).toBe(6.5);
    expect(() => effortPoints('XXL')).toThrow(/XS/);
  });

  it('labels a stored effort number back to its bucket', () => {
    expect(effortLabel(2.2)).toBe('M (2.2)');
    expect(effortLabel(6.5)).toBe('L+guard (6.5)');
    expect(effortLabel(3)).toBe('3');
    expect(effortLabel(null)).toBe('-');
  });

  it('expands goal codes to option values and takes the highest weight', () => {
    expect(goalOptions('G1,g3')).toEqual(['G1 Structural safety', 'G3 Trustworthy ship loop']);
    expect(() => goalOptions('G9')).toThrow(/G9/);
    expect(alignmentFromGoals(['G5 Adopter-ready install', 'G2 Work survives sessions'])).toBe(0.9);
    expect(alignmentFromGoals(['win'])).toBe(0.2);
    expect(alignmentFromGoals(['North Star'])).toBeUndefined();
  });

  it('computes ROI = impact x alignment x confidence / effort', () => {
    expect(computeRoi({ readiness: 3, impact: 4, alignment: 0.9, effort: 2.2 })).toBe(1.227);
    expect(computeRoi({ readiness: 0, impact: 4, alignment: 0.9, effort: 2.2 })).toBeNull();
    expect(computeRoi({ readiness: null, impact: 4, alignment: 0.9, effort: 2.2 })).toBeNull();
    expect(computeRoi({ readiness: 4, impact: null, alignment: 0.9, effort: 2.2 })).toBeNull();
  });
});

describe('buildRoadmapFields', () => {
  it('writes only the given fields', () => {
    expect(buildRoadmapFields(IDS, { readiness: '3' })).toEqual({ customfield_10171: 3 });
  });

  it('shapes select, multiselect, checkbox, effort and derived alignment', () => {
    expect(
      buildRoadmapFields(IDS, {
        theme: 'Guard safety',
        goals: 'G1,G6',
        effort: 'S',
        guard: true,
        closeCandidate: 'yes',
        auditDate: '2026-09-30',
        auditEvidence: 'https://example.com/a',
      }),
    ).toEqual({
      customfield_10172: { value: 'Guard safety' },
      customfield_10173: [{ value: 'G1 Structural safety' }, { value: 'G6 Honest test signal' }],
      customfield_10175: 1,
      customfield_10016: 1.3,
      customfield_10179: [{ value: 'yes' }],
      customfield_10177: '2026-09-30',
      customfield_10178: 'https://example.com/a',
    });
  });

  it('keeps an explicit alignment and clears close candidate on no', () => {
    expect(buildRoadmapFields(IDS, { goals: 'G1', alignment: '0.5', closeCandidate: 'no' })).toEqual({
      customfield_10173: [{ value: 'G1 Structural safety' }],
      customfield_10175: 0.5,
      customfield_10179: [],
    });
  });

  it('rejects out-of-range and unknown values', () => {
    expect(() => buildRoadmapFields(IDS, { readiness: '5' })).toThrow(/readiness/);
    expect(() => buildRoadmapFields(IDS, { readiness: '2.5' })).toThrow(/readiness/);
    expect(() => buildRoadmapFields(IDS, { impact: '0' })).toThrow(/impact/);
    expect(() => buildRoadmapFields(IDS, { alignment: '1.5' })).toThrow(/alignment/);
    expect(() => buildRoadmapFields(IDS, { theme: 'Nope' })).toThrow(/theme/);
    expect(() => buildRoadmapFields(IDS, { auditDate: '30/09/2026' })).toThrow(/YYYY-MM-DD/);
    expect(() => buildRoadmapFields(IDS, { auditEvidence: 'not a url' })).toThrow(/URL/);
    expect(() => buildRoadmapFields(IDS, { closeCandidate: 'maybe' })).toThrow(/yes\|no/);
    expect(() => buildRoadmapFields(IDS, { guard: true })).toThrow(/--guard/);
    expect(() => buildRoadmapFields(IDS, {})).toThrow(/nothing to set/);
  });
});

describe('roadmapSet', () => {
  const after = {
    fields: { customfield_10171: 3, customfield_10174: 4, customfield_10175: 0.9, customfield_10016: 2.2, customfield_10176: null },
  };

  it('writes the fields, then recomputes ROI from the stored values', async () => {
    const { req, calls } = stub({
      'GET /field': FIELD_LIST,
      'PUT /issue/HIMMEL-1': '',
      [`GET /issue/HIMMEL-1?fields=${Object.values(IDS).join(',')}`]: after,
    });
    const out = await roadmapSet('HIMMEL-1', { readiness: '3' }, req);
    expect(calls.filter((c) => c.method === 'PUT').map((c) => c.body)).toEqual([
      { fields: { customfield_10171: 3 } },
      { fields: { customfield_10176: 1.227 } },
    ]);
    expect(out).toMatch(/ROI 1\.227/);
  });

  it('skips the ROI write with noRoi', async () => {
    const { req, calls } = stub({ 'GET /field': FIELD_LIST, 'PUT /issue/HIMMEL-1': '' });
    await roadmapSet('HIMMEL-1', { readiness: '3', noRoi: true }, req);
    expect(calls.filter((c) => c.method === 'PUT')).toHaveLength(1);
  });
});

describe('roadmapGet', () => {
  it('prints every roadmap field with effort as a bucket', async () => {
    const { req } = stub({
      'GET /field': FIELD_LIST,
      [`GET /issue/HIMMEL-1?fields=${Object.values(IDS).join(',')}`]: {
        fields: {
          customfield_10171: 3,
          customfield_10172: { value: 'Guard safety' },
          customfield_10173: [{ value: 'G1 Structural safety' }],
          customfield_10016: 2.2,
          customfield_10179: [{ value: 'yes' }],
        },
      },
    });
    const out = await roadmapGet('HIMMEL-1', req);
    expect(out).toContain('Readiness: 3');
    expect(out).toContain('Theme: Guard safety');
    expect(out).toContain('Roadmap Goals: G1 Structural safety');
    expect(out).toContain('Effort: M (2.2)');
    expect(out).toContain('Close candidate: yes');
    expect(out).toContain('ROI: -');
  });
});

describe('roadmapExport', () => {
  it('writes versions and every open issue with the resolved field ids', async () => {
    const fields = ['summary', 'issuetype', 'status', 'priority', 'parent', 'fixVersions', 'issuelinks', 'labels', 'customfield_10020', ...Object.values(IDS)].join(',');
    const jql = 'project = HIMMEL AND statusCategory != Done ORDER BY fixVersion ASC, Rank ASC';
    const page = (tok?: string) =>
      `GET /search/jql?jql=${encodeURIComponent(jql)}&fields=${fields}&maxResults=100${tok ? `&nextPageToken=${tok}` : ''}`;
    const { req } = stub({
      'GET /field': [...FIELD_LIST, { id: 'customfield_10020', name: 'Sprint' }],
      'GET /project/HIMMEL/versions': [{ id: '1', name: 'v1.0.0' }],
      [page()]: { issues: [{ key: 'HIMMEL-1', fields: {} }], nextPageToken: 'p2' },
      [page('p2')]: { issues: [{ key: 'HIMMEL-2', fields: {} }] },
    });
    const out = await roadmapExport('HIMMEL', req, () => '2026-09-30T00:00:00.000Z');
    expect(out).toEqual({
      project: 'HIMMEL',
      generatedAt: '2026-09-30T00:00:00.000Z',
      jql,
      fieldIds: { ...IDS, sprint: 'customfield_10020' },
      versions: [{ id: '1', name: 'v1.0.0' }],
      issues: [{ key: 'HIMMEL-1', fields: {} }, { key: 'HIMMEL-2', fields: {} }],
    });
  });
});

describe('syncSprints', () => {
  const versions = [
    { id: '1', name: 'v1.0.0', released: false, startDate: '2026-10-01', releaseDate: '2026-10-04' },
    { id: '2', name: 'v1.0.1', released: false, startDate: '2026-10-05', releaseDate: '2026-10-08' },
    { id: '3', name: 'v0.9.0', released: true, startDate: '2026-09-01', releaseDate: '2026-09-04' },
    { id: '4', name: 'v2.0.0', released: false },
  ];
  const jql = (v: string, sprint?: number) =>
    `project = HIMMEL AND fixVersion = "${v}" AND statusCategory != Done` +
    (sprint === undefined ? '' : ` AND (sprint is EMPTY OR sprint != ${sprint})`);
  const search = (j: string) => `GET /search/jql?jql=${encodeURIComponent(j)}&fields=summary&maxResults=100`;

  it('dry-run reports a missing sprint and drifted issues without writing', async () => {
    const api = stub({
      'GET /project/HIMMEL/versions': versions,
      [search(jql('v1.0.0', 7))]: { issues: [{ key: 'HIMMEL-1' }] },
      [search(jql('v1.0.1'))]: { issues: [{ key: 'HIMMEL-2' }, { key: 'HIMMEL-3' }] },
    });
    const agile = stub({
      'GET /board/166/sprint?state=active,future&maxResults=50': { values: [{ id: 7, name: 'v1.0.0', state: 'active' }], isLast: true },
    });
    const r = await syncSprints('HIMMEL', '166', true, api.req, agile.req);
    expect(r.drift).toBe(4); // 3 issues + 1 missing sprint
    expect(r.lines).toEqual([
      'v1.0.0: sprint 7, move 1 (HIMMEL-1)',
      'v1.0.1: sprint missing (would create 2026-10-05..2026-10-08), move 2 (HIMMEL-2 HIMMEL-3)',
    ]);
    expect(agile.calls.filter((c) => c.method !== 'GET')).toEqual([]);
  });

  it('apply creates the sprint and moves issues in chunks of 50', async () => {
    const many = Array.from({ length: 51 }, (_, i) => ({ key: `HIMMEL-${i + 10}` }));
    const api = stub({
      'GET /project/HIMMEL/versions': versions.slice(1, 2),
      [search(jql('v1.0.1'))]: { issues: many },
    });
    const agile = stub({
      'GET /board/166/sprint?state=active,future&maxResults=50': { values: [], isLast: true },
      'POST /sprint': { id: 9, name: 'v1.0.1' },
      'POST /sprint/9/issue': '',
    });
    const r = await syncSprints('HIMMEL', '166', false, api.req, agile.req);
    expect(agile.calls.find((c) => c.path === '/sprint')?.body).toEqual({
      name: 'v1.0.1',
      originBoardId: 166,
      startDate: '2026-10-05T00:00:00.000Z',
      endDate: '2026-10-08T23:59:00.000Z',
    });
    const moves = agile.calls.filter((c) => c.path === '/sprint/9/issue').map((c) => (c.body as { issues: string[] }).issues.length);
    expect(moves).toEqual([50, 1]);
    expect(r.lines[0]).toBe('v1.0.1: created sprint 9, moved 51');
  });
});
