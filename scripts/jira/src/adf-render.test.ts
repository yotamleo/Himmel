import { describe, it, expect } from 'vitest';
import { adfToPlainText, type ADFDocument } from './adf-render.js';

describe('adfToPlainText', () => {
  it('returns empty string for null/undefined', () => {
    expect(adfToPlainText(null)).toBe('');
    expect(adfToPlainText(undefined)).toBe('');
  });

  it('extracts text from a single paragraph', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [{ type: 'paragraph', content: [{ type: 'text', text: 'hello world' }] }],
    };
    expect(adfToPlainText(doc)).toBe('hello world');
  });

  it('joins multiple paragraphs with newlines', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        { type: 'paragraph', content: [{ type: 'text', text: 'first' }] },
        { type: 'paragraph', content: [{ type: 'text', text: 'second' }] },
      ],
    };
    expect(adfToPlainText(doc)).toBe('first\nsecond');
  });

  it('preserves heading text without the # syntax', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        { type: 'heading', attrs: { level: 2 }, content: [{ type: 'text', text: 'Section' }] },
        { type: 'paragraph', content: [{ type: 'text', text: 'body' }] },
      ],
    };
    expect(adfToPlainText(doc)).toBe('Section\nbody');
  });

  it('renders bullet lists with - markers', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'bulletList',
          content: [
            {
              type: 'listItem',
              content: [{ type: 'paragraph', content: [{ type: 'text', text: 'one' }] }],
            },
            {
              type: 'listItem',
              content: [{ type: 'paragraph', content: [{ type: 'text', text: 'two' }] }],
            },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('- one\n- two');
  });

  it('renders ordered lists with N. markers', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'orderedList',
          content: [
            {
              type: 'listItem',
              content: [{ type: 'paragraph', content: [{ type: 'text', text: 'first' }] }],
            },
            {
              type: 'listItem',
              content: [{ type: 'paragraph', content: [{ type: 'text', text: 'second' }] }],
            },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('1. first\n2. second');
  });

  it('strips marks but preserves text content', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'paragraph',
          content: [
            { type: 'text', text: 'plain ' },
            { type: 'text', text: 'bold', marks: [{ type: 'strong' }] },
            { type: 'text', text: ' ' },
            { type: 'text', text: 'code', marks: [{ type: 'code' }] },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('plain bold code');
  });

  it('renders mentions as @displayName', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'paragraph',
          content: [
            { type: 'text', text: 'cc ' },
            { type: 'mention', attrs: { displayName: 'yotam' } },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('cc @yotam');
  });

  it('renders deleted-user mention as @user:<id>', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'paragraph',
          content: [
            { type: 'text', text: 'cc ' },
            { type: 'mention', attrs: { id: 'abc123' } },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('cc @user:abc123');
  });

  it('renders mention with no attrs as @unknown', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'paragraph',
          content: [
            { type: 'text', text: 'cc ' },
            { type: 'mention' },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('cc @unknown');
  });

  it('renders emojis as :shortName:', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'paragraph',
          content: [
            { type: 'text', text: 'hi ' },
            { type: 'emoji', attrs: { shortName: 'wave' } },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('hi :wave:');
  });

  it('treats hardBreak as newline', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'paragraph',
          content: [
            { type: 'text', text: 'line1' },
            { type: 'hardBreak' },
            { type: 'text', text: 'line2' },
          ],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('line1\nline2');
  });

  it('skips unknown node types but walks their children', () => {
    const doc: ADFDocument = {
      type: 'doc',
      content: [
        {
          type: 'someFutureBlockType',
          content: [{ type: 'text', text: 'still extracted' }],
        },
      ],
    };
    expect(adfToPlainText(doc)).toBe('still extracted');
  });

  it('does not throw on malformed nodes', () => {
    expect(() =>
      adfToPlainText({ type: 'doc', content: [null as never, undefined as never] }),
    ).not.toThrow();
  });
});
