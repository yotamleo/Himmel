import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', () => ({ request: vi.fn() }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { registerLink } from './link.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerLink(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

const TYPES = {
  issueLinkTypes: [
    { name: 'Relates', inward: 'relates to', outward: 'relates to' },
    { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' },
  ],
};

describe('link / links / unlink', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('link --type blocks: validates the type, POSTs inward/outward, prints the stored reading', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? TYPES : {}));
    await run(['link', 'A-1', 'B-2', '--type', 'blocks']);
    expect(mockRequest).toHaveBeenNthCalledWith(1, 'GET', '/issueLinkType');
    expect(mockRequest).toHaveBeenNthCalledWith(2, 'POST', '/issueLink', {
      type: { name: 'Blocks' },
      inwardIssue: { key: 'A-1' },
      outwardIssue: { key: 'B-2' },
    });
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('A-1');
    expect(console.log).toHaveBeenCalledWith('Linked: A-1 is blocked by B-2');
  });

  it('link defaults to Relates', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? TYPES : {}));
    await run(['link', 'A-1', 'B-2']);
    expect(mockRequest.mock.calls[1][2]).toMatchObject({ type: { name: 'Relates' } });
    expect(console.log).toHaveBeenCalledWith('Linked: A-1 relates to B-2');
  });

  it('link with an unknown type lists the valid ones, exits 1, never POSTs', async () => {
    mockRequest.mockResolvedValue(TYPES);
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    await expect(run(['link', 'A-1', 'B-2', '--type', 'Nope'])).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    expect(console.error).toHaveBeenCalledWith('Link type "Nope" not found. Available:');
    expect(console.error).toHaveBeenCalledWith('- Blocks');
    expect(mockRequest.mock.calls.some((c) => c[0] === 'POST')).toBe(false);
    exit.mockRestore();
  });

  it('links: GETs issuelinks and prints a directed row per link', async () => {
    mockRequest.mockResolvedValue({
      fields: {
        issuelinks: [
          { id: '10', type: { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' }, outwardIssue: { key: 'B-2' } },
        ],
      },
    });
    await run(['links', 'A-1']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/issue/A-1?fields=issuelinks');
    expect(console.log).toHaveBeenCalledWith('10\tBlocks\tinward=A-1\toutward=B-2\tA-1 is blocked by B-2');
  });

  it('links with none prints the empty line', async () => {
    mockRequest.mockResolvedValue({ fields: {} });
    await run(['links', 'A-1']);
    expect(console.log).toHaveBeenCalledWith('A-1: no issue links');
  });

  it('unlink: DELETEs the single matching link id and prints it', async () => {
    mockRequest.mockImplementation(async (m: string) =>
      m === 'GET'
        ? {
            fields: {
              issuelinks: [
                { id: '10', type: { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' }, outwardIssue: { key: 'B-2' } },
                { id: '11', type: { name: 'Blocks', inward: 'is blocked by', outward: 'blocks' }, outwardIssue: { key: 'C-3' } },
              ],
            },
          }
        : {},
    );
    await run(['unlink', 'A-1', 'B-2']);
    expect(mockRequest).toHaveBeenCalledWith('DELETE', '/issueLink/10');
    expect(mockRequest.mock.calls.filter((c) => c[0] === 'DELETE')).toHaveLength(1);
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('A-1');
    expect(console.log).toHaveBeenCalledWith('Unlinked inward=A-1 outward=B-2 type=Blocks id=10');
  });

  it('unlink with no matching link rejects and never DELETEs', async () => {
    mockRequest.mockResolvedValue({ fields: { issuelinks: [] } });
    await expect(run(['unlink', 'A-1', 'B-2'])).rejects.toThrow(/No issue link found with inward=A-1, outward=B-2/);
    expect(mockRequest.mock.calls.some((c) => c[0] === 'DELETE')).toBe(false);
  });
});
