import { describe, it, expect } from 'vitest';
import { buildWorklogBody } from './worklog.js';

describe('worklog', () => {
  it('requires time spent', () => {
    expect(() => buildWorklogBody({ time: '' })).toThrow(/time/i);
  });
  it('builds a timeSpent-only body', () => {
    expect(buildWorklogBody({ time: '1h 30m' })).toEqual({ timeSpent: '1h 30m' });
  });
  it('adds an ADF comment when given', () => {
    const b = buildWorklogBody({ time: '2h', comment: 'work' });
    expect(b.timeSpent).toBe('2h');
    expect((b.comment as { type: string }).type).toBe('doc');
  });
  it('passes started through', () => {
    const b = buildWorklogBody({ time: '1h', started: '2026-06-20T10:00:00.000+0000' });
    expect(b.started).toBe('2026-06-20T10:00:00.000+0000');
  });
});
