import { describe, it, expect, beforeEach, vi } from 'vitest';
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
    const [, , body] = mockRequest.mock.calls[0] as [
      string,
      string,
      { fields: { summary: string } },
    ];
    expect(body.fields.summary).toBe('title wins');
  });
});
