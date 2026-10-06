import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const uploadAttachment = vi.fn();
vi.mock('../client.js', () => ({ request: vi.fn(), uploadAttachment: (...a: unknown[]) => uploadAttachment(...a) }));
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { registerComment } from './comment.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerComment(p);
  return p.parseAsync(['node', 'jira', 'comment', ...args]);
}

describe('comment', () => {
  let dir: string;
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    mockRequest.mockResolvedValue({});
    dir = mkdtempSync(join(tmpdir(), 'jira-comment-'));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('POSTs /issue/<key>/comment with an ADF doc built from the text, then breadcrumb + success line', async () => {
    await run(['HIMMEL-1', 'hello world']);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [method, path, payload] = mockRequest.mock.calls[0];
    expect(method).toBe('POST');
    expect(path).toBe('/issue/HIMMEL-1/comment');
    const body = (payload as { body: { type: string; version: number } }).body;
    expect(body.type).toBe('doc');
    expect(body.version).toBe(1);
    expect(JSON.stringify(body)).toContain('hello world');
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('HIMMEL-1');
    expect(console.log).toHaveBeenCalledWith('Comment added to HIMMEL-1');
  });

  it('--adf-file sends the parsed JSON verbatim, overriding text', async () => {
    const adf = { type: 'doc', version: 1, content: [{ type: 'paragraph', content: [{ type: 'text', text: 'raw' }] }] };
    const f = join(dir, 'c.json');
    writeFileSync(f, JSON.stringify(adf));
    await run(['HIMMEL-2', 'ignored', '--adf-file', f]);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/issue/HIMMEL-2/comment', { body: adf });
  });

  it('--comment-file reads the markdown body from the file, overriding text', async () => {
    const f = join(dir, 'c.md');
    writeFileSync(f, 'from file body');
    await run(['HIMMEL-3', 'ignored text', '--comment-file', f]);
    const json = JSON.stringify(mockRequest.mock.calls[0][2]);
    expect(json).toContain('from file body');
    expect(json).not.toContain('ignored text');
  });

  it('no text and no file: exits 1 with a usage error and makes no request', async () => {
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    await expect(run(['HIMMEL-1'])).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    expect(console.error).toHaveBeenCalledWith('jira: comment requires <text> or --comment-file or --adf-file');
    expect(mockRequest).not.toHaveBeenCalled();
    exit.mockRestore();
  });

  it('unreadable --adf-file: exits 1, no request', async () => {
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    await expect(run(['HIMMEL-1', '--adf-file', join(dir, 'missing.json')])).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    expect(mockRequest).not.toHaveBeenCalled();
    exit.mockRestore();
  });

  it('--attach uploads after the comment lands; success line printed first', async () => {
    uploadAttachment.mockResolvedValue({});
    await run(['HIMMEL-1', 'hi', '--attach', 'a.txt', '--attach', 'b.txt']);
    expect(uploadAttachment.mock.calls).toEqual([['HIMMEL-1', 'a.txt'], ['HIMMEL-1', 'b.txt']]);
    expect(console.log).toHaveBeenCalledWith('Comment added to HIMMEL-1');
    expect(console.error).toHaveBeenCalledWith('  attachments: 2');
  });

  it('attachment failure: comment + breadcrumb already done, exits 1 with stderr message', async () => {
    uploadAttachment.mockRejectedValue(new Error('boom'));
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => { throw new Error('exit'); }) as never);
    await expect(run(['HIMMEL-1', 'hi', '--attach', 'a.txt'])).rejects.toThrow('exit');
    expect(exit).toHaveBeenCalledWith(1);
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('HIMMEL-1');
    expect(console.log).toHaveBeenCalledWith('Comment added to HIMMEL-1');
    expect(console.error).toHaveBeenCalledWith('Comment added to HIMMEL-1 but attachment failed: a.txt: boom');
    exit.mockRestore();
  });
});
