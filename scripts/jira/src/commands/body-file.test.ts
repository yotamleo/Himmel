import { describe, it, expect, vi, beforeEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { readBodyFile } from './body-file.js';

// readFileSync is an ESM export — spyOn can't redefine it, so mock the module.
vi.mock('node:fs', () => ({ readFileSync: vi.fn() }));
const mockRead = vi.mocked(readFileSync);

describe('readBodyFile', () => {
  beforeEach(() => {
    mockRead.mockReset();
  });

  it('returns the file contents verbatim (multi-line markdown body)', () => {
    const body = 'line one\n\nline two; with | and > chars\n';
    mockRead.mockReturnValue(body);
    expect(readBodyFile('/tmp/body.md', '--comment-file')).toBe(body);
    expect(mockRead).toHaveBeenCalledWith('/tmp/body.md', 'utf8');
  });

  it('exits 1 with a diagnostic when the file cannot be read', () => {
    mockRead.mockImplementation(() => {
      throw new Error('ENOENT: no such file');
    });
    const exit = vi.spyOn(process, 'exit').mockImplementation((() => {
      throw new Error('process.exit called');
    }) as never);
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});

    expect(() => readBodyFile('/nope.md', '--desc-file')).toThrow('process.exit called');
    expect(exit).toHaveBeenCalledWith(1);
    expect(err).toHaveBeenCalledWith(
      expect.stringContaining('cannot read --desc-file "/nope.md"'),
    );

    exit.mockRestore();
    err.mockRestore();
  });
});
