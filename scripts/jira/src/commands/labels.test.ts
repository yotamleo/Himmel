import { describe, it, expect } from 'vitest';
import { parseLabels } from './labels.js';

describe('parseLabels (HIMMEL-243)', () => {
  it('splits a comma-separated arg into a label array', () => {
    expect(parseLabels('a,b')).toEqual(['a', 'b']);
  });

  it('returns a single-element array for one label', () => {
    expect(parseLabels('ai-tasklist')).toEqual(['ai-tasklist']);
  });

  it('trims whitespace around each token', () => {
    expect(parseLabels('  a , b  ,c ')).toEqual(['a', 'b', 'c']);
  });

  it('drops empty tokens (consecutive commas, leading/trailing)', () => {
    expect(parseLabels(',a,,b,')).toEqual(['a', 'b']);
  });

  it('throws on an empty string', () => {
    expect(() => parseLabels('')).toThrow(/at least one non-empty label/);
  });

  it('throws on whitespace-only input', () => {
    expect(() => parseLabels('   ')).toThrow(/at least one non-empty label/);
  });

  it('throws on commas-only input', () => {
    expect(() => parseLabels(',, ,')).toThrow(/at least one non-empty label/);
  });
});
