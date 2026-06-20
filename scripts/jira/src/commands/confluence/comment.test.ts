import { describe, it, expect } from 'vitest';
import { buildCommentBody } from './comment.js';

const adf = { type: 'doc', version: 1, content: [] };

describe('confluence comment', () => {
  it('puts pageId at top level alongside the body', () => {
    expect(buildCommentBody('123', adf)).toEqual({
      pageId: '123',
      body: { representation: 'atlas_doc_format', value: JSON.stringify(adf) },
    });
  });
});
