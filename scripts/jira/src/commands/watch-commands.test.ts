import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return {
    ...actual,
    request: vi.fn(),
    // the real resolveAccountId calls client.ts's internal request, not the mock
    resolveAccountId: vi.fn(async (v: string) => (v.includes('@') ? 'acc-3' : v)),
  };
});

import { request } from '../client.js';
import { registerWatchers } from './watchers.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerWatchers(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

describe('watch / unwatch / watchers', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
  });

  it('watch (no user): GET /myself then POST accountId string to /issue/<key>/watchers', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? { accountId: 'me-1' } : {}));
    await run(['watch', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenNthCalledWith(1, 'GET', '/myself');
    expect(mockRequest).toHaveBeenNthCalledWith(2, 'POST', '/issue/HIMMEL-1/watchers', 'me-1');
    expect(console.log).toHaveBeenCalledWith('Watching HIMMEL-1 as me-1');
  });

  it('watch <user-id>: no lookup, id used verbatim', async () => {
    mockRequest.mockResolvedValue({});
    await run(['watch', 'HIMMEL-1', 'acc-2']);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issue/HIMMEL-1/watchers', 'acc-2');
    expect(console.log).toHaveBeenCalledWith('Watching HIMMEL-1 as acc-2');
  });

  it('watch <email>: the resolved accountId (not the email) is POSTed', async () => {
    mockRequest.mockResolvedValue({});
    await run(['watch', 'HIMMEL-1', 'a@b.co']);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issue/HIMMEL-1/watchers', 'acc-3');
    expect(console.log).toHaveBeenCalledWith('Watching HIMMEL-1 as acc-3');
  });

  it('unwatch (no user): DELETE with the encoded accountId query', async () => {
    mockRequest.mockImplementation(async (m: string) => (m === 'GET' ? { accountId: 'me:1' } : {}));
    await run(['unwatch', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenNthCalledWith(2, 'DELETE', '/issue/HIMMEL-1/watchers?accountId=me%3A1');
    expect(console.log).toHaveBeenCalledWith('Unwatched HIMMEL-1 for me:1');
  });

  it('watchers: GET and print accountId/displayName rows', async () => {
    mockRequest.mockResolvedValue({
      watchers: [
        { accountId: 'a1', displayName: 'Ann' },
        { accountId: 'b2', displayName: 'Bob' },
      ],
    });
    await run(['watchers', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/issue/HIMMEL-1/watchers');
    expect(console.log).toHaveBeenNthCalledWith(1, 'a1\tAnn');
    expect(console.log).toHaveBeenNthCalledWith(2, 'b2\tBob');
  });
});
