import { describe, it, expect } from 'vitest';
import { shouldRetryExit, shouldRunRecovery, computeBackoffMs } from '../src/retry.js';

describe('retry', () => {
  it('shouldRetryExit returns true for matching code', () => {
    expect(shouldRetryExit(1, [1, 2])).toBe(true);
    expect(shouldRetryExit(3, [1, 2])).toBe(false);
    expect(shouldRetryExit(1, undefined)).toBe(false);
  });

  it('shouldRunRecovery true when stderr matches pattern', () => {
    expect(shouldRunRecovery('field foo is required', 'field .* is required')).toBe(true);
    expect(shouldRunRecovery('all good', 'field .* is required')).toBe(false);
    expect(shouldRunRecovery('x', undefined)).toBe(false);
  });

  it('computeBackoffMs is between base and cap with jitter', () => {
    for (let i = 0; i < 50; i++) {
      const ms = computeBackoffMs(200, 800);
      expect(ms).toBeGreaterThanOrEqual(200);
      expect(ms).toBeLessThanOrEqual(800);
    }
  });
});
