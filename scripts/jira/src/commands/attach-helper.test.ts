import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { uploadAll } from './attach-helper.js';

describe('uploadAll', () => {
  let stderrSpy: ReturnType<typeof vi.spyOn>;
  let stderrLines: string[];

  beforeEach(() => {
    stderrLines = [];
    stderrSpy = vi.spyOn(console, 'error').mockImplementation((msg: unknown) => {
      stderrLines.push(String(msg));
    });
  });

  afterEach(() => {
    stderrSpy.mockRestore();
  });

  it('uploads each path and returns count on success', async () => {
    const calls: Array<[string, string]> = [];
    const fakeUpload = vi.fn(async (key: string, p: string) => {
      calls.push([key, p]);
      return [{ id: '1' }];
    });
    const n = await uploadAll('HIMMEL-1', ['a.png', 'b.log'], fakeUpload);
    expect(n).toBe(2);
    expect(calls).toEqual([
      ['HIMMEL-1', 'a.png'],
      ['HIMMEL-1', 'b.log'],
    ]);
  });

  it('logs per-file success breadcrumbs to stderr on full success', async () => {
    const fakeUpload = vi.fn(async () => [{ id: '1' }]);
    await uploadAll('HIMMEL-1', ['a.png', 'b.log'], fakeUpload);
    const joined = stderrLines.join('\n');
    expect(joined).toMatch(/✓ a\.png/);
    expect(joined).toMatch(/✓ b\.log/);
  });

  it('returns count of successes; first failure throws after partial upload', async () => {
    const fakeUpload = vi.fn(async (_k: string, p: string) => {
      if (p === 'bad') throw new Error('HTTP 413: Payload Too Large');
      return [{ id: '1' }];
    });
    await expect(uploadAll('HIMMEL-1', ['ok', 'bad', 'never'], fakeUpload)).rejects.toThrow(
      /bad.*HTTP 413/,
    );
    expect(fakeUpload).toHaveBeenCalledTimes(2);
  });

  it('logs success breadcrumb for first file AND failure breadcrumb for failing file', async () => {
    const fakeUpload = vi.fn(async (_k: string, p: string) => {
      if (p === 'b.png') throw new Error('HTTP 413: Payload Too Large');
      return [{ id: '1' }];
    });
    await expect(
      uploadAll('HIMMEL-1', ['a.png', 'b.png', 'c.png'], fakeUpload),
    ).rejects.toThrow();
    const joined = stderrLines.join('\n');
    expect(joined).toMatch(/✓ a\.png/);
    expect(joined).toMatch(/✗ b\.png/);
    expect(joined).toMatch(/HTTP 413/);
    // c.png never attempted
    expect(joined).not.toMatch(/c\.png/);
  });

  it('returns 0 when given no paths', async () => {
    const fake = vi.fn();
    expect(await uploadAll('HIMMEL-1', [], fake)).toBe(0);
    expect(fake).not.toHaveBeenCalled();
  });
});
