import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', () => ({ request: vi.fn() }));

import { request } from '../client.js';
import { registerProjects } from './projects.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerProjects(p);
  return p.parseAsync(['node', 'jira', 'projects', ...args]);
}

describe('projects', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
  });

  it('GETs /project/search with default limit 50 ordered by key and prints key/id/name rows', async () => {
    mockRequest.mockResolvedValue({
      values: [
        { id: '1', key: 'AAA', name: 'Alpha' },
        { id: '2', key: 'BBB', name: 'Beta Project' },
      ],
      total: 2,
      isLast: true,
    });
    await run([]);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/project/search?maxResults=50&orderBy=key');
    expect(console.log).toHaveBeenNthCalledWith(1, 'AAA\t1\tAlpha');
    expect(console.log).toHaveBeenNthCalledWith(2, 'BBB\t2\tBeta Project');
  });

  it('--limit is forwarded as maxResults', async () => {
    mockRequest.mockResolvedValue({ values: [], total: 0, isLast: true });
    await run(['--limit', '5']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/project/search?maxResults=5&orderBy=key');
    expect(console.log).not.toHaveBeenCalled();
  });
});
