import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';

const uploadAttachment = vi.fn();
vi.mock('../client.js', () => ({ request: vi.fn(), uploadAttachment: (...a: unknown[]) => uploadAttachment(...a) }));

import { registerAttach } from './attach.js';

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerAttach(p);
  return p.parseAsync(['node', 'jira', 'attach', ...args]);
}

describe('attach', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('uploads each path in order to the key and prints the count', async () => {
    uploadAttachment.mockResolvedValue({});
    await run(['HIMMEL-1', 'a.txt', 'b.png']);
    expect(uploadAttachment.mock.calls).toEqual([
      ['HIMMEL-1', 'a.txt'],
      ['HIMMEL-1', 'b.png'],
    ]);
    expect(console.log).toHaveBeenCalledWith('Attached 2 file(s) to HIMMEL-1');
  });

  it('on upload failure stops, reports to stderr, exits 1, prints no success line', async () => {
    uploadAttachment.mockResolvedValueOnce({}).mockRejectedValueOnce(new Error('HTTP 413'));
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    await expect(run(['HIMMEL-1', 'a', 'b', 'c'])).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    expect(uploadAttachment).toHaveBeenCalledTimes(2);
    expect(console.error).toHaveBeenCalledWith('jira: attach to HIMMEL-1 failed: b: HTTP 413');
    expect(console.log).not.toHaveBeenCalled();
    exit.mockRestore();
  });
});
