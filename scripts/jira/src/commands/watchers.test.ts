import { describe, it, expect } from 'vitest';
import { watcherDeletePath } from './watchers.js';

describe('watchers', () => {
  it('builds the DELETE path with an encoded accountId', () => {
    expect(watcherDeletePath('HIMMEL-1', 'abc:1/2')).toBe(
      '/issue/HIMMEL-1/watchers?accountId=abc%3A1%2F2',
    );
  });
});
