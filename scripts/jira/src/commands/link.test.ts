import { describe, it, expect } from 'vitest';
import { findLinkType } from './link.js';

describe('findLinkType', () => {
  const types = [{ name: 'Relates' }, { name: 'Blocks' }, { name: 'Duplicate' }];

  it('matches an exact name', () => {
    expect(findLinkType(types, 'Blocks')).toEqual({ name: 'Blocks' });
  });

  it('matches case-insensitively', () => {
    expect(findLinkType(types, 'relates')).toEqual({ name: 'Relates' });
    expect(findLinkType(types, 'DUPLICATE')).toEqual({ name: 'Duplicate' });
  });

  it('returns undefined for an unknown type', () => {
    expect(findLinkType(types, 'Clones')).toBeUndefined();
  });
});
