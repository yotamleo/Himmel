import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';
import { join } from 'node:path';

const downloadTo = vi.fn();
vi.mock('../client.js', () => ({
  request: vi.fn(),
  downloadTo: (...a: unknown[]) => downloadTo(...a),
  baseUrl: () => 'https://jira.test',
}));

import { request } from '../client.js';
import { registerAttachments } from './attachments.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerAttachments(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

const ISSUE = {
  fields: {
    attachment: [
      { id: '1', filename: 'a.txt', size: 10, author: { displayName: 'Ann' } },
      { id: '2', filename: '../evil.txt' },
    ],
  },
};

describe('attachments / download', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    mockRequest.mockResolvedValue(ISSUE);
    downloadTo.mockResolvedValue(10);
  });

  it('attachments: GET fields=attachment and prints id/filename/size/author rows', async () => {
    await run(['attachments', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenCalledWith('GET', '/issue/HIMMEL-1?fields=attachment');
    expect(console.log).toHaveBeenNthCalledWith(1, '1\ta.txt\t10b\tAnn');
    expect(console.log).toHaveBeenNthCalledWith(2, '2\t../evil.txt\t?b\t');
  });

  it('attachments with none prints the empty line', async () => {
    mockRequest.mockResolvedValue({ fields: {} });
    await run(['attachments', 'HIMMEL-1']);
    expect(console.log).toHaveBeenCalledWith('HIMMEL-1: no attachments');
  });

  it('download <id> --out: fetches the content URL and writes under --out', async () => {
    await run(['download', 'HIMMEL-1', '1', '--out', '/tmp/x']);
    expect(downloadTo).toHaveBeenCalledWith('https://jira.test/rest/api/3/attachment/content/1', join('/tmp/x', 'a.txt'));
    expect(console.log).toHaveBeenCalledWith(`${join('/tmp/x', 'a.txt')} (10b)`);
  });

  it('download --all: downloads every attachment; server filename is basename()d so it cannot escape --out', async () => {
    await run(['download', 'HIMMEL-1', '--all', '--out', '/tmp/x']);
    expect(downloadTo).toHaveBeenCalledTimes(2);
    expect(downloadTo.mock.calls[1]).toEqual(['https://jira.test/rest/api/3/attachment/content/2', join('/tmp/x', 'evil.txt')]);
  });

  it('download with an unknown id rejects and downloads nothing', async () => {
    await expect(run(['download', 'HIMMEL-1', '99'])).rejects.toThrow('no attachment with id 99 on the issue');
    expect(downloadTo).not.toHaveBeenCalled();
  });
});
