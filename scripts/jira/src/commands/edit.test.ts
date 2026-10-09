import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { buildEditFields } from './edit.js';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

describe('edit', () => {
  const orig = process.env.JIRA_SEVERITY_FIELD;

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    if (orig === undefined) delete process.env.JIRA_SEVERITY_FIELD;
    else process.env.JIRA_SEVERITY_FIELD = orig;
  });

  it('builds fields payload for priority only', () => {
    const fields = buildEditFields({ priority: 'High' });
    expect(fields).toEqual({ priority: { name: 'High' } });
  });

  it('builds fields payload for severity only when env var is set', () => {
    process.env.JIRA_SEVERITY_FIELD = 'customfield_10016';
    const fields = buildEditFields({ severity: 'Major' });
    expect(fields).toEqual({ customfield_10016: { value: 'Major' } });
  });

  it('builds combined fields payload', () => {
    process.env.JIRA_SEVERITY_FIELD = 'customfield_10016';
    const fields = buildEditFields({ priority: 'High', severity: 'Major' });
    expect(fields).toEqual({
      priority: { name: 'High' },
      customfield_10016: { value: 'Major' },
    });
  });

  it('throws when --severity is passed but JIRA_SEVERITY_FIELD is unset', () => {
    delete process.env.JIRA_SEVERITY_FIELD;
    expect(() => buildEditFields({ severity: 'Major' })).toThrow(
      /JIRA_SEVERITY_FIELD/,
    );
  });

  it('throws when nothing to edit', () => {
    expect(() => buildEditFields({})).toThrow(/at least one of/i);
  });

  it('builds fields payload for parent only', () => {
    const fields = buildEditFields({ parent: 'HIMMEL-199' });
    expect(fields).toEqual({ parent: { key: 'HIMMEL-199' } });
  });

  it('combines parent with another field', () => {
    const fields = buildEditFields({ parent: 'HIMMEL-199', priority: 'High' });
    expect(fields).toEqual({
      parent: { key: 'HIMMEL-199' },
      priority: { name: 'High' },
    });
  });

  it('maps --title to the summary field (plain string)', () => {
    const fields = buildEditFields({ title: 'New title' });
    expect(fields).toEqual({ summary: 'New title' });
  });

  it('maps --description through markdownToAdf', () => {
    const fields = buildEditFields({ description: 'Plain paragraph.' });
    expect(fields).toEqual({
      description: {
        type: 'doc',
        version: 1,
        content: [
          {
            type: 'paragraph',
            content: [{ type: 'text', text: 'Plain paragraph.' }],
          },
        ],
      },
    });
  });

  it('combines title + description in one payload', () => {
    const fields = buildEditFields({ title: 'T', description: 'D' });
    expect(fields).toHaveProperty('summary', 'T');
    expect(fields).toHaveProperty('description');
    expect((fields.description as { type: string }).type).toBe('doc');
  });

  it('maps --labels to a full-replace labels array (HIMMEL-243)', () => {
    const fields = buildEditFields({ labels: 'a, b ,c' });
    expect(fields).toEqual({ labels: ['a', 'b', 'c'] });
  });

  it('combines labels with another field', () => {
    const fields = buildEditFields({ labels: 'ai-tasklist', priority: 'High' });
    expect(fields).toEqual({
      labels: ['ai-tasklist'],
      priority: { name: 'High' },
    });
  });

  it('throws on an empty --labels (would otherwise wipe all labels)', () => {
    expect(() => buildEditFields({ labels: '' })).toThrow(
      /at least one non-empty label/,
    );
  });

  it('throws on a whitespace/commas-only --labels', () => {
    expect(() => buildEditFields({ labels: ' , ' })).toThrow(
      /at least one non-empty label/,
    );
  });

  it('allows empty string description to clear the field', () => {
    // Empty markdown -> ADF doc with no content blocks; Jira accepts this as
    // "clear the description". The undefined-check (not truthy-check) in
    // buildEditFields makes this reachable.
    const fields = buildEditFields({ description: '' });
    expect(fields).toEqual({
      description: { type: 'doc', version: 1, content: [] },
    });
  });

  it('throws when --labels and --add-labels are both given', () => {
    expect(() =>
      buildEditFields({ labels: 'a', addLabels: 'b' }),
    ).toThrow(/mutually exclusive/);
  });

  it('does not throw "nothing to edit" when only --add-labels is given', () => {
    expect(buildEditFields({ addLabels: 'a,b' })).toEqual({});
  });

  it('maps --fix-version to a full-replace fixVersions array (HIMMEL-3713)', () => {
    const fields = buildEditFields({ fixVersion: 'v1.0.0' });
    expect(fields).toEqual({ fixVersions: [{ name: 'v1.0.0' }] });
  });

  it('combines fixVersion with another field', () => {
    const fields = buildEditFields({ fixVersion: 'v1.0.0', priority: 'High' });
    expect(fields).toEqual({
      fixVersions: [{ name: 'v1.0.0' }],
      priority: { name: 'High' },
    });
  });

  it('throws when --fix-version and --add-fix-version are both given', () => {
    expect(() =>
      buildEditFields({ fixVersion: 'v1.0.0', addFixVersion: 'v1.0.1' }),
    ).toThrow(/mutually exclusive/);
  });

  it('does not throw "nothing to edit" when only --add-fix-version is given', () => {
    expect(buildEditFields({ addFixVersion: 'v1.0.0' })).toEqual({});
  });
});

describe('edit --add-labels (HIMMEL-3610)', () => {
  let mockRequest: ReturnType<typeof vi.fn>;

  beforeEach(async () => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { request } = await import('../client.js');
    mockRequest = request as unknown as ReturnType<typeof vi.fn>;
    // PUT returns {}; the HIMMEL-4644 read-back GET returns the labels.
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? { fields: { labels: ['a', 'b'] } } : {},
    );
  });

  function freshProgram(register: (p: Command) => void): Command {
    const p = new Command();
    p.exitOverride();
    register(p);
    return p;
  }

  it('sends update.labels add ops and NO fields.labels', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--add-labels', 'a,b']);
    expect(mockRequest).toHaveBeenCalledTimes(2);
    const [method, path, body] = mockRequest.mock.calls.find((c) => c[0] === 'PUT')!;
    expect(method).toBe('PUT');
    expect(path).toBe('/issue/HIMMEL-1');
    expect(body).toEqual({
      update: { labels: [{ add: 'a' }, { add: 'b' }] },
    });
    expect((body as { fields?: unknown }).fields).toBeUndefined();
  });

  it('rejects --labels together with --add-labels as a usage error', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await expect(
      p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--labels', 'a', '--add-labels', 'b']),
    ).rejects.toThrow(/mutually exclusive/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('control: --labels alone still sends a full-replace fields.labels, unchanged', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--labels', 'a,b']);
    const [, , body] = mockRequest.mock.calls[0];
    expect(body).toEqual({ fields: { labels: ['a', 'b'] } });
    expect((body as { update?: unknown }).update).toBeUndefined();
  });
});

describe('edit --fix-version / --add-fix-version (HIMMEL-3713)', () => {
  let mockRequest: ReturnType<typeof vi.fn>;
  const origProject = process.env.JIRA_PROJECT_KEY;

  const KNOWN_VERSIONS = [
    { id: '10001', name: 'v1.0.0' },
    { id: '10002', name: 'v1.0.1' },
  ];

  beforeEach(async () => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    const { request } = await import('../client.js');
    mockRequest = request as unknown as ReturnType<typeof vi.fn>;
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method !== 'GET') return {};
      // /versions GETs return the known versions; the HIMMEL-4644 issue read-back
      // returns the fixVersions the edit set.
      return path.endsWith('/versions') ? KNOWN_VERSIONS : { fields: { fixVersions: [{ name: 'v1.0.0' }] } };
    });
  });

  afterEach(() => {
    if (origProject === undefined) delete process.env.JIRA_PROJECT_KEY;
    else process.env.JIRA_PROJECT_KEY = origProject;
  });

  function freshProgram(register: (p: Command) => void): Command {
    const p = new Command();
    p.exitOverride();
    register(p);
    return p;
  }

  it('validates against the project versions then sends a full-replace fields.fixVersions', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--fix-version', 'v1.0.0']);
    const putCall = mockRequest.mock.calls.find((c) => c[0] === 'PUT');
    expect(putCall?.[2]).toEqual({ fields: { fixVersions: [{ name: 'v1.0.0' }] } });
  });

  it('sends update.fixVersions add op and NO fields.fixVersions for --add-fix-version', async () => {
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method !== 'GET') return {};
      return path.endsWith('/versions') ? KNOWN_VERSIONS : { fields: { fixVersions: [{ name: 'v1.0.1' }] } };
    });
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--add-fix-version', 'v1.0.1']);
    const putCall = mockRequest.mock.calls.find((c) => c[0] === 'PUT');
    expect(putCall?.[2]).toEqual({ update: { fixVersions: [{ add: { name: 'v1.0.1' } }] } });
    expect((putCall?.[2] as { fields?: unknown }).fields).toBeUndefined();
  });

  it('validates against the ISSUE KEY\'s own project, not the configured default (HIMMEL-3713 CR fix)', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await p.parseAsync(['node', 'jira', 'edit', 'OTHER-1', '--fix-version', 'v1.0.0']);
    const getCall = mockRequest.mock.calls.find((c) => c[0] === 'GET');
    expect(getCall?.[1]).toBe('/project/OTHER/versions');
  });

  it('rejects an unknown --fix-version naming the ISSUE KEY\'s project on a cross-project issue', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await expect(
      p.parseAsync(['node', 'jira', 'edit', 'OTHER-1', '--fix-version', 'v9.9.9']),
    ).rejects.toThrow(/no version named "v9\.9\.9" in project OTHER/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
  });

  it('rejects an unknown --fix-version naming the project, without ever PUTting', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await expect(
      p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--fix-version', 'v9.9.9']),
    ).rejects.toThrow(/no version named "v9\.9\.9" in project HIMMEL/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'PUT')).toBe(false);
  });

  it('rejects --fix-version together with --add-fix-version as a usage error, without a network call', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await expect(
      p.parseAsync([
        'node',
        'jira',
        'edit',
        'HIMMEL-1',
        '--fix-version',
        'a',
        '--add-fix-version',
        'b',
      ]),
    ).rejects.toThrow(/mutually exclusive/);
    expect(mockRequest).not.toHaveBeenCalled();
  });
});

describe('edit read-back of every field it sends (HIMMEL-4644)', () => {
  let mockRequest: ReturnType<typeof vi.fn>;
  const origProject = process.env.JIRA_PROJECT_KEY;
  const origSeverity = process.env.JIRA_SEVERITY_FIELD;

  beforeEach(async () => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    process.env.JIRA_SEVERITY_FIELD = 'customfield_10016';
    const { request } = await import('../client.js');
    mockRequest = request as unknown as ReturnType<typeof vi.fn>;
  });

  afterEach(() => {
    if (origProject === undefined) delete process.env.JIRA_PROJECT_KEY;
    else process.env.JIRA_PROJECT_KEY = origProject;
    if (origSeverity === undefined) delete process.env.JIRA_SEVERITY_FIELD;
    else process.env.JIRA_SEVERITY_FIELD = origSeverity;
  });

  // The PUT returns {}, the project-versions GET returns the known versions,
  // and the issue GET returns `fields` as the post-PUT read-back.
  function readBack(fields: Record<string, unknown>): void {
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method !== 'GET') return {};
      if (path.endsWith('/versions')) return [{ id: '1', name: 'v1.0.0' }, { id: '2', name: 'v1.0.1' }];
      return { fields };
    });
  }

  async function runEdit(args: string[]): Promise<void> {
    const { registerEdit } = await import('./edit.js');
    const p = new Command();
    p.exitOverride();
    registerEdit(p);
    await p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', ...args]);
  }

  function issueGetPath(): string | undefined {
    return mockRequest.mock.calls.find((c) => c[0] === 'GET' && String(c[1]).startsWith('/issue/'))?.[1];
  }

  const cases: Array<{
    name: string;
    args: string[];
    field: string;
    pass: Record<string, unknown>;
    fail: Record<string, unknown>;
    message: RegExp;
  }> = [
    {
      name: 'severity',
      args: ['--severity', 'Major'],
      field: 'customfield_10016',
      pass: { customfield_10016: { value: 'Major' } },
      fail: { customfield_10016: { value: 'Minor' } },
      message: /severity was not changed.*Major.*Minor/s,
    },
    {
      name: 'title',
      args: ['--title', 'New title'],
      field: 'summary',
      pass: { summary: 'New title' },
      fail: { summary: 'Old title' },
      message: /title was not changed.*New title.*Old title/s,
    },
    {
      name: 'description',
      args: ['--desc', 'Some **bold** text.'],
      field: 'description',
      pass: {
        description: {
          type: 'doc',
          version: 1,
          content: [
            {
              type: 'paragraph',
              content: [
                { type: 'text', text: 'Some ' },
                { type: 'text', text: 'bold', marks: [{ type: 'strong' }] },
                { type: 'text', text: ' text.' },
              ],
            },
          ],
        },
      },
      fail: {
        description: {
          type: 'doc',
          version: 1,
          content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Old body.' }] }],
        },
      },
      message: /description was not changed.*Some bold text\..*Old body\./s,
    },
    {
      name: 'parent',
      args: ['--parent', 'HIMMEL-199'],
      field: 'parent',
      pass: { parent: { key: 'HIMMEL-199' } },
      fail: { parent: { key: 'HIMMEL-7' } },
      message: /parent was not changed.*HIMMEL-199.*HIMMEL-7/s,
    },
    {
      name: 'labels',
      args: ['--labels', 'a,b'],
      field: 'labels',
      pass: { labels: ['b', 'a'] },
      fail: { labels: ['a', 'old'] },
      message: /labels was not changed.*a, b.*a, old/s,
    },
    {
      name: 'labels with a duplicate value (Jira stores it once)',
      args: ['--labels', 'a,a'],
      field: 'labels',
      pass: { labels: ['a'] },
      fail: { labels: ['old'] },
      message: /labels was not changed/s,
    },
    {
      name: 'add-labels',
      args: ['--add-labels', 'a,b'],
      field: 'labels',
      pass: { labels: ['existing', 'a', 'b'] },
      fail: { labels: ['existing', 'a'] },
      message: /add-labels was not changed.*a, b.*existing, a/s,
    },
    {
      name: 'fix-version',
      args: ['--fix-version', 'v1.0.0'],
      field: 'fixVersions',
      pass: { fixVersions: [{ name: 'v1.0.0' }] },
      fail: { fixVersions: [{ name: 'v1.0.1' }] },
      message: /fix-version was not changed.*v1\.0\.0.*v1\.0\.1/s,
    },
    {
      name: 'add-fix-version',
      args: ['--add-fix-version', 'v1.0.1'],
      field: 'fixVersions',
      pass: { fixVersions: [{ name: 'v1.0.0' }, { name: 'v1.0.1' }] },
      fail: { fixVersions: [{ name: 'v1.0.0' }] },
      message: /add-fix-version was not changed.*v1\.0\.1.*v1\.0\.0/s,
    },
  ];

  for (const c of cases) {
    it(`${c.name}: reads ${c.field} back after the PUT and succeeds when it matches`, async () => {
      readBack(c.pass);
      await runEdit(c.args);
      expect(issueGetPath()).toBe(`/issue/HIMMEL-1?fields=${c.field}`);
      const putIdx = mockRequest.mock.calls.findIndex((x) => x[0] === 'PUT');
      const getIdx = mockRequest.mock.calls.findIndex((x) => x[1] === issueGetPath());
      expect(getIdx).toBeGreaterThan(putIdx);
      expect(console.log).toHaveBeenCalledWith('HIMMEL-1 edited');
    });

    it(`${c.name}: fails naming the field when the read-back does not match`, async () => {
      readBack(c.fail);
      await expect(runEdit(c.args)).rejects.toThrow(c.message);
      expect(console.log).not.toHaveBeenCalledWith('HIMMEL-1 edited');
    });
  }

  it('reads every sent field back in ONE GET and reports every mismatch', async () => {
    readBack({ priority: { name: 'Low' }, summary: 'Old', labels: ['x'] });
    await expect(
      runEdit(['--priority', 'High', '--title', 'New', '--labels', 'x']),
    ).rejects.toThrow(/priority was not changed[\s\S]*title was not changed/);
    const gets = mockRequest.mock.calls.filter((c) => c[0] === 'GET');
    expect(gets).toHaveLength(1);
    expect(gets[0][1]).toBe('/issue/HIMMEL-1?fields=priority,summary,labels');
  });

  it('treats a missing field in the read-back as a mismatch', async () => {
    readBack({});
    await expect(runEdit(['--parent', 'HIMMEL-199'])).rejects.toThrow(
      /parent was not changed.*HIMMEL-199.*none/s,
    );
  });

  it('accepts an emptied description when --desc is empty', async () => {
    readBack({ description: null });
    await runEdit(['--desc', '']);
    expect(console.log).toHaveBeenCalledWith('HIMMEL-1 edited');
  });
});
