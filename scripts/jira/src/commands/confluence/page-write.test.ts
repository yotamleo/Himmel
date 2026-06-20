import { describe, it, expect } from 'vitest';
import { buildCreateBody, buildUpdateBody } from './page-write.js';

const adf = { type: 'doc', version: 1, content: [] };

describe('confluence page write', () => {
  it('builds a create body with atlas_doc_format', () => {
    const b = buildCreateBody({ spaceId: '99', title: 'T', adf });
    expect(b).toMatchObject({
      spaceId: '99', status: 'current', title: 'T',
      body: { representation: 'atlas_doc_format', value: JSON.stringify(adf) },
    });
  });
  it('includes parentId when given', () => {
    expect(buildCreateBody({ spaceId: '99', title: 'T', adf, parentId: '5' }).parentId).toBe('5');
  });
  it('bumps the version on update', () => {
    const b = buildUpdateBody({ id: '1', currentVersion: 4, title: 'T', adf });
    expect(b).toMatchObject({ id: '1', status: 'current', title: 'T', version: { number: 5 } });
  });
  it('omits the body on a title-only update (no adf)', () => {
    const b = buildUpdateBody({ id: '1', currentVersion: 4, title: 'T' });
    expect(b).not.toHaveProperty('body');
    expect(b).toMatchObject({ id: '1', title: 'T', version: { number: 5 } });
  });
});
