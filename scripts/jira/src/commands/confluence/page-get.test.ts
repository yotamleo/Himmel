import { describe, it, expect } from 'vitest';
import { pageGetPath } from './page-get.js';

describe('page get', () => {
  it('requests the atlas_doc_format body by id', () => {
    expect(pageGetPath('123')).toBe('/pages/123?body-format=atlas_doc_format');
  });
});
