import { describe, it, expect } from 'vitest';
import { pickPageAttachments } from './attachments.js';

const list = [
  { id: 'att1', title: 'a.png', downloadLink: '/download/att/1' },
  { id: 'att2', title: 'b.pdf', downloadLink: '/download/att/2' },
];

describe('confluence attachment selection', () => {
  it('selects one by id', () => {
    expect(pickPageAttachments(list, 'att2', false)).toEqual([list[1]]);
  });
  it('selects all with --all', () => {
    expect(pickPageAttachments(list, undefined, true)).toHaveLength(2);
  });
  it('throws on a missing id', () => {
    expect(() => pickPageAttachments(list, 'nope', false)).toThrow(/no attachment/i);
  });
  it('throws on duplicate titles in --all', () => {
    const dup = [{ id: '1', title: 'x', downloadLink: '/a' }, { id: '2', title: 'x', downloadLink: '/b' }];
    expect(() => pickPageAttachments(dup, undefined, true)).toThrow(/duplicate filename/i);
  });
});
