import { describe, it, expect, vi } from 'vitest';
import { resolveThenCmd } from '../src/index.js';

describe('resolveThenCmd', () => {
  it('returns undefined when neither option provided', () => {
    expect(resolveThenCmd(undefined, undefined)).toBeUndefined();
  });

  it('parses --then-cmd-json into a string array', () => {
    expect(resolveThenCmd(undefined, '["node","x.js","--flag"]')).toEqual(['node', 'x.js', '--flag']);
  });

  it('preserves args containing commas in --then-cmd-json', () => {
    expect(resolveThenCmd(undefined, '["node","x.js","--list=a,b,c"]')).toEqual([
      'node', 'x.js', '--list=a,b,c',
    ]);
  });

  it('falls back to comma-split for --then-cmd (with deprecation warn)', () => {
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => undefined as never);
    try {
      const out = resolveThenCmd('node,x.js,--flag', undefined);
      expect(out).toEqual(['node', 'x.js', '--flag']);
      const warned = stderrSpy.mock.calls.flat().join('');
      expect(warned).toMatch(/--then-cmd is deprecated/);
      expect(exitSpy).not.toHaveBeenCalled();
    } finally {
      stderrSpy.mockRestore();
      exitSpy.mockRestore();
    }
  });

  it('exits 2 on invalid JSON', () => {
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => undefined as never);
    try {
      resolveThenCmd(undefined, '{not-json');
      expect(exitSpy).toHaveBeenCalledWith(2);
      const errOut = stderrSpy.mock.calls.flat().join('');
      expect(errOut).toMatch(/not valid JSON/);
    } finally {
      stderrSpy.mockRestore();
      exitSpy.mockRestore();
    }
  });

  it('exits 2 on non-array JSON', () => {
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => undefined as never);
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      resolveThenCmd(undefined, '"string"');
      expect(exitSpy).toHaveBeenCalledWith(2);
    } finally {
      stderrSpy.mockRestore();
      exitSpy.mockRestore();
    }
  });

  it('exits 2 on array of non-strings', () => {
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => undefined as never);
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      resolveThenCmd(undefined, '[1,2,3]');
      expect(exitSpy).toHaveBeenCalledWith(2);
    } finally {
      stderrSpy.mockRestore();
      exitSpy.mockRestore();
    }
  });

  it('exits 2 on empty array', () => {
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => undefined as never);
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      resolveThenCmd(undefined, '[]');
      expect(exitSpy).toHaveBeenCalledWith(2);
    } finally {
      stderrSpy.mockRestore();
      exitSpy.mockRestore();
    }
  });

  it('prefers --then-cmd-json when both are given', () => {
    const out = resolveThenCmd('legacy,format', '["json","format"]');
    expect(out).toEqual(['json', 'format']);
  });
});
