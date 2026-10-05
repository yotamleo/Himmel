import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Command } from 'commander';

// Mock the network + breadcrumb layers so the command action resolves without
// a real Jira or a real breadcrumb file write (same pattern as
// breadcrumb-wiring.test.ts).
vi.mock('../client.js', () => ({
  request: vi.fn(async () => ({ key: 'HIMMEL-1' })),
  projectKey: () => 'HIMMEL',
}));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { resolveTitle, registerCreate } from './create.js';
import { request } from '../client.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

describe('create — resolveTitle (HIMMEL-1188)', () => {
  it('accepts --title', () => {
    expect(resolveTitle({ title: 'From title' })).toBe('From title');
  });

  it('accepts --summary as an alias for --title', () => {
    expect(resolveTitle({ summary: 'From summary' })).toBe('From summary');
  });

  it('prefers --title when both --title and --summary are given', () => {
    expect(resolveTitle({ title: 'Title wins', summary: 'Summary loses' })).toBe(
      'Title wins',
    );
  });

  it('throws when neither --title nor --summary is given', () => {
    expect(() => resolveTitle({})).toThrow(/--title.*--summary/);
  });
});

// Command-level wiring (CR #1191 follow-up): exercise Commander option parsing
// + the resulting POST /issue payload, not just resolveTitle in isolation — a
// regression in the --summary option registration or the fields.summary wiring
// would slip past the unit tests above.
describe('create — command wiring (--summary → POST /issue payload)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  });

  it('parses --summary and wires it into the POST /issue summary field', async () => {
    const p = new Command();
    p.exitOverride(); // throw instead of process.exit on parse errors
    registerCreate(p);
    await p.parseAsync([
      'node',
      'jira',
      'create',
      '--type',
      'Task',
      '--summary',
      'From CLI summary',
    ]);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [method, path, body] = mockRequest.mock.calls[0] as [
      string,
      string,
      { fields: { summary: string; issuetype: { name: string } } },
    ];
    expect(method).toBe('POST');
    expect(path).toBe('/issue');
    expect(body.fields.summary).toBe('From CLI summary');
    expect(body.fields.issuetype.name).toBe('Task');
  });

  it('lets --title win over --summary through the parsed command', async () => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync([
      'node',
      'jira',
      'create',
      '--type',
      'Task',
      '--summary',
      'summary loses',
      '--title',
      'title wins',
    ]);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [, , body] = mockRequest.mock.calls.find((c) => c[0] === 'POST') as [
      string,
      string,
      { fields: { summary: string } },
    ];
    expect(body.fields.summary).toBe('title wins');
  });
});

// HIMMEL-4489: a Bug defaults to the earliest unreleased version at the filing point.
describe('create — Bug default fixVersion wiring', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  });

  async function createFields(args: string[]) {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--title', 't', ...args]);
    const [, , body] = mockRequest.mock.calls.find((c) => c[0] === 'POST') as [
      string,
      string,
      { fields: { fixVersions?: { name: string }[] } },
    ];
    return body.fields;
  }

  const VERSIONS = [
    { id: '1', name: 'v1.0.0', released: true },
    { id: '2', name: 'v1.0.1', released: true },
    { id: '3', name: 'v1.0.2', released: false },
  ];
  const withVersions = (versions: unknown) =>
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? versions : { key: 'HIMMEL-1' },
    );
  const postedFields = () => {
    const call = mockRequest.mock.calls.find((c) => c[0] === 'POST');
    return (call?.[2] as { fields: { fixVersions?: { name: string }[] } }).fields;
  };

  it('defaults a Bug to the earliest unreleased version and says so', async () => {
    withVersions(VERSIONS);
    await createFields(['--type', 'Bug']);
    expect(postedFields().fixVersions).toEqual([{ name: 'v1.0.2' }]);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/defaults to fixVersion v1\.0\.2/));
  });

  it('lets an explicit --fix-version win over the default', async () => {
    withVersions(VERSIONS);
    await createFields(['--type', 'Bug', '--fix-version', 'v1.0.0']);
    expect(postedFields().fixVersions).toEqual([{ name: 'v1.0.0' }]);
  });

  it('files with no fixVersion and a warning when no unreleased version can be found', async () => {
    withVersions([{ id: '1', name: 'v1.0.0', released: true }]);
    await createFields(['--type', 'Bug']);
    expect(postedFields().fixVersions).toBeUndefined();
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/no unreleased version.*no fixVersion/));
  });

  it('files with no fixVersion and a warning when the versions cannot be read', async () => {
    mockRequest.mockImplementation(async (method: string) => {
      if (method === 'GET') throw new Error('boom');
      return { key: 'HIMMEL-1' };
    });
    await createFields(['--type', 'Bug']);
    expect(postedFields().fixVersions).toBeUndefined();
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/no unreleased version.*no fixVersion/));
  });

  it('sets no fixVersion on a Task', async () => {
    withVersions(VERSIONS);
    const fields = await createFields(['--type', 'Task']);
    expect(fields.fixVersions).toBeUndefined();
  });
});

describe('create --fix-version (HIMMEL-3713)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('validates against the project versions then sets fixVersions', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-20T12:00:00'));
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? [{ id: '1', name: 'v1.0.0' }] : { key: 'HIMMEL-1' },
    );
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync([
      'node',
      'jira',
      'create',
      '--type',
      'Task',
      '--title',
      't',
      '--fix-version',
      'v1.0.0',
    ]);
    const postCall = mockRequest.mock.calls.find((c) => c[0] === 'POST');
    expect((postCall?.[2] as { fields: { fixVersions?: unknown } }).fields.fixVersions).toEqual([
      { name: 'v1.0.0' },
    ]);
  });

  it('rejects an unknown --fix-version naming the project, without ever POSTing', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-09-20T12:00:00'));
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? [{ id: '1', name: 'v1.0.0' }] : { key: 'HIMMEL-1' },
    );
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await expect(
      p.parseAsync([
        'node',
        'jira',
        'create',
        '--type',
        'Task',
        '--title',
        't',
        '--fix-version',
        'v9.9.9',
      ]),
    ).rejects.toThrow(/no version named "v9\.9\.9" in project HIMMEL/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
  });
});
