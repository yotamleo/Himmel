import { describe, it, expect } from 'vitest';
import { searchPath } from './search.js';

describe('confluence search', () => {
  it('builds the v1 CQL search path with encoded cql + limit', () => {
    expect(searchPath('type=page AND text~"x"', 10)).toBe(
      '/search?cql=type%3Dpage%20AND%20text~%22x%22&limit=10',
    );
  });
});
