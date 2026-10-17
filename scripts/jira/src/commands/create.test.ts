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
import { PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';

// A body that satisfies the plain-block rule.
const PLAIN = PLAIN_BLOCK_TEMPLATE.replace(/<[^>\n]*>/g, 'filled');

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

// A Sector and a parent epic: the home a Task, Story or Bug needs to be filed.
const HOME = ['--sector', 'Ship loop', '--parent', 'HIMMEL-9'];

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
      '--desc',
      PLAIN,
      '--type',
      'Task',
      '--summary',
      'From CLI summary',
      ...HOME,
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
      '--desc',
      PLAIN,
      '--type',
      'Task',
      '--summary',
      'summary loses',
      '--title',
      'title wins',
      ...HOME,
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

// A Bug defaults to the earliest unreleased version at the filing point.
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
    await p.parseAsync(['node', 'jira', 'create', '--title', 't', '--desc', PLAIN, ...HOME, ...args]);
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
      '--desc',
      PLAIN,
      '--type',
      'Task',
      '--title',
      't',
      '--fix-version',
      'v1.0.0',
      ...HOME,
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
        '--desc',
        PLAIN,
        '--type',
        'Task',
        '--title',
        't',
        '--fix-version',
        'v9.9.9',
        ...HOME,
      ]),
    ).rejects.toThrow(/no version named "v9\.9\.9" in project HIMMEL/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
  });
});

// A body without the plain Impact/What/Why block is refused.
describe('create — plain block rule (HIMMEL-5226)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(process, 'exit').mockImplementation(((c?: number) => {
      throw new Error(`exit ${c}`);
    }) as never);
    mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  });

  async function run(args: string[]) {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--title', 't', ...args]);
  }
  const posted = () => mockRequest.mock.calls.some((c) => c[0] === 'POST');

  it('refuses a Task whose body has no plain block, names what is missing and prints the template', async () => {
    await expect(run(['--type', 'Task', '--desc', 'just agent notes'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
    const msg = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');
    expect(msg).toMatch(/missing "## Impact"/);
    expect(msg).toContain('## Agent detail');
  });

  it('refuses a Task with every section but no DoD, naming DoD (HIMMEL-5643)', async () => {
    const noDod = PLAIN.replace(/## DoD\n[^\n]*\n\n/, '');
    await expect(run(['--type', 'Task', '--desc', noDod])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
    const msg = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');
    expect(msg).toMatch(/missing "## DoD"/);
  });

  it('refuses a Task whose Plan and DoD are only the skeleton placeholders (HIMMEL-5643)', async () => {
    await expect(run(['--type', 'Task', '--desc', PLAIN_BLOCK_TEMPLATE])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
    const msg = (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');
    expect(msg).toMatch(/"## Plan" has no bullet.*"## DoD" has no bullet/s);
  });

  it('refuses a body-less Task', async () => {
    await expect(run(['--type', 'Task'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
  });

  it('refuses a block with an empty Impact section', async () => {
    const empty = PLAIN.replace(/## Impact\n[^\n]*\n/, '## Impact\n');
    await expect(run(['--type', 'Story', '--desc', empty])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
  });

  it('accepts a body that carries the full block', async () => {
    await run(['--type', 'Task', '--desc', PLAIN, ...HOME]);
    expect(posted()).toBe(true);
  });

  it('--skeleton prints the six-heading body to fill and creates nothing', async () => {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--type', 'Task', '--skeleton']);
    expect(console.log).toHaveBeenCalledWith(PLAIN_BLOCK_TEMPLATE);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('only warns for an Epic with no body, and still files it', async () => {
    await run(['--type', 'Epic']);
    expect(posted()).toBe(true);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/warning.*Impact.*Epic is exempt/s));
  });

  it('only warns for an Epic that lacks Plan and DoD (HIMMEL-5643)', async () => {
    const noPlanDod = PLAIN.replace(/## Plan\n[^\n]*\n\n## DoD\n[^\n]*\n\n/, '');
    await run(['--type', 'Epic', '--desc', noPlanDod]);
    expect(posted()).toBe(true);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/warning.*Plan.*DoD.*Epic is exempt/s));
  });

  it('refuses a pre-built --adf-file with no plain block', async () => {
    const { writeFileSync, mkdtempSync } = await import('node:fs');
    const { join } = await import('node:path');
    const { tmpdir } = await import('node:os');
    const f = join(mkdtempSync(join(tmpdir(), 'adf-')), 'b.json');
    writeFileSync(
      f,
      JSON.stringify({ type: 'doc', version: 1, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'x' }] }] }),
    );
    await expect(run(['--type', 'Task', '--adf-file', f])).rejects.toThrow(/exit 1/);
    expect(posted()).toBe(false);
  });
});

// create refuses a ticket with no Sector and no epic / standalone marker.
describe('create — Sector and home rule (HIMMEL-6223)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(process, 'exit').mockImplementation(((c?: number) => {
      throw new Error(`exit ${c}`);
    }) as never);
    mockRequest.mockResolvedValue({ key: 'HIMMEL-1' });
  });

  async function run(args: string[]) {
    const p = new Command();
    p.exitOverride();
    registerCreate(p);
    await p.parseAsync(['node', 'jira', 'create', '--title', 't', '--desc', PLAIN, ...args]);
  }
  const posted = () => mockRequest.mock.calls.find((c) => c[0] === 'POST');
  const errText = () => (console.error as unknown as ReturnType<typeof vi.fn>).mock.calls.flat().join('\n');

  it('refuses a Task with no Sector and names the missing field', async () => {
    await expect(run(['--type', 'Task', '--parent', 'HIMMEL-9'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBeUndefined();
    expect(errText()).toMatch(/no Sector.*--sector/s);
  });

  it('refuses a Task with a Sector but neither --parent nor the standalone label', async () => {
    await expect(run(['--type', 'Task', '--sector', 'Ship loop'])).rejects.toThrow(/exit 1/);
    expect(posted()).toBeUndefined();
    expect(errText()).toMatch(/--parent.*--labels standalone/s);
  });

  it('creates with a Sector and --parent, writing the Sector field', async () => {
    await run(['--type', 'Task', '--sector', 'ship loop', '--parent', 'HIMMEL-9']);
    const body = posted()![2] as { fields: Record<string, unknown> };
    expect(body.fields['customfield_10212']).toEqual({ value: 'Ship loop' });
    expect(body.fields['parent']).toEqual({ key: 'HIMMEL-9' });
  });

  it('creates with a Sector and the standalone label', async () => {
    await run(['--type', 'Task', '--sector', 'Ship loop', '--labels', 'standalone']);
    expect(posted()).toBeDefined();
  });

  it('only warns for an Epic with neither, and still files it', async () => {
    await run(['--type', 'Epic']);
    expect(posted()).toBeDefined();
    expect(errText()).toMatch(/warning.*Sector.*Epic is exempt/s);
  });

  it('refuses an unknown --sector before posting', async () => {
    await expect(run(['--type', 'Task', '--sector', 'Bogus', '--parent', 'HIMMEL-9'])).rejects.toThrow(
      /Unknown sector 'Bogus'/,
    );
    expect(posted()).toBeUndefined();
  });
});
