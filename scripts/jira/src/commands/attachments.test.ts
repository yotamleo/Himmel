import { describe, it, expect } from 'vitest';
import { pickAttachments } from './attachments.js';

const issue = { fields: { attachment: [
  { id: '1', filename: 'a.png' },
  { id: '2', filename: 'b.pdf' },
] } };

describe('download selection', () => {
  it('selects one by id', () => {
    expect(pickAttachments(issue, '2', false)).toEqual([{ id: '2', filename: 'b.pdf' }]);
  });
  it('selects all with --all', () => {
    expect(pickAttachments(issue, undefined, true)).toHaveLength(2);
  });
  it('throws when id not found', () => {
    expect(() => pickAttachments(issue, '9', false)).toThrow(/no attachment/i);
  });
  it('throws on duplicate filenames in --all', () => {
    const dup = { fields: { attachment: [
      { id: '1', filename: 'x' }, { id: '2', filename: 'x' },
    ] } };
    expect(() => pickAttachments(dup, undefined, true)).toThrow(/duplicate filename/i);
  });
});
