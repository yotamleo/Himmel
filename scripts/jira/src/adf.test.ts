import { describe, it, expect, vi, afterEach } from 'vitest';
import { markdownToAdf } from './adf.js';

describe('markdownToAdf', () => {
  it('empty string → doc with no content blocks', () => {
    const doc = markdownToAdf('');
    expect(doc).toEqual({ type: 'doc', version: 1, content: [] });
  });

  it('single paragraph', () => {
    const doc = markdownToAdf('Hello world');
    expect(doc.content).toHaveLength(1);
    expect(doc.content[0].type).toBe('paragraph');
  });

  it('two paragraphs separated by blank line', () => {
    const doc = markdownToAdf('First paragraph\n\nSecond paragraph');
    expect(doc.content).toHaveLength(2);
    expect(doc.content[0].type).toBe('paragraph');
    expect(doc.content[1].type).toBe('paragraph');
  });

  it('# Heading → heading block level 1', () => {
    const doc = markdownToAdf('# My Heading');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('heading');
    if (block.type === 'heading') {
      expect(block.attrs.level).toBe(1);
      expect(block.content[0]).toMatchObject({ type: 'text', text: 'My Heading' });
    }
  });

  it('## Heading → heading block level 2', () => {
    const doc = markdownToAdf('## Sub heading');
    const block = doc.content[0];
    expect(block.type).toBe('heading');
    if (block.type === 'heading') expect(block.attrs.level).toBe(2);
  });

  it('### Heading → heading block level 3', () => {
    const doc = markdownToAdf('### Deep heading');
    const block = doc.content[0];
    expect(block.type).toBe('heading');
    if (block.type === 'heading') expect(block.attrs.level).toBe(3);
  });

  it('```js code fence → codeBlock with language js', () => {
    const doc = markdownToAdf('```js\nconsole.log("hi");\n```');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('codeBlock');
    if (block.type === 'codeBlock') {
      expect(block.attrs).toMatchObject({ language: 'js' });
      expect(block.content[0].text).toBe('console.log("hi");');
    }
  });

  it('code fence without language → codeBlock with empty attrs', () => {
    const doc = markdownToAdf('```\nplain code\n```');
    const block = doc.content[0];
    expect(block.type).toBe('codeBlock');
    if (block.type === 'codeBlock') {
      expect(block.attrs).toEqual({});
    }
  });

  it('- item1\\n- item2 → bulletList with 2 listItems', () => {
    const doc = markdownToAdf('- item1\n- item2');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('bulletList');
    if (block.type === 'bulletList') {
      expect(block.content).toHaveLength(2);
      expect(block.content[0].type).toBe('listItem');
    }
  });

  it('1. a\\n2. b → orderedList with 2 listItems', () => {
    const doc = markdownToAdf('1. a\n2. b');
    expect(doc.content).toHaveLength(1);
    const block = doc.content[0];
    expect(block.type).toBe('orderedList');
    if (block.type === 'orderedList') {
      expect(block.content).toHaveLength(2);
    }
  });

  it('**bold** inline → text with strong mark', () => {
    const doc = markdownToAdf('**bold text**');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'bold text');
      expect(node?.marks).toEqual([{ type: 'strong' }]);
    }
  });

  it('`code` inline → text with code mark', () => {
    const doc = markdownToAdf('Use `console.log` here');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'console.log');
      expect(node?.marks).toEqual([{ type: 'code' }]);
    }
  });

  it('[text](http://x) inline → text with link mark + href', () => {
    const doc = markdownToAdf('[click here](http://example.com)');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'click here');
      expect(node?.marks).toEqual([{ type: 'link', attrs: { href: 'http://example.com' } }]);
    }
  });

  it('*italic* inline → text with em mark', () => {
    const doc = markdownToAdf('*italic text*');
    const block = doc.content[0];
    expect(block.type).toBe('paragraph');
    if (block.type === 'paragraph') {
      const node = block.content.find((n) => n.text === 'italic text');
      expect(node?.marks).toEqual([{ type: 'em' }]);
    }
  });

  it('unclosed code fence — produces valid codeBlock, emits warning to stderr', () => {
    const stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      const doc = markdownToAdf('```js\nconsole.log("hi");');
      expect(doc.content).toHaveLength(1);
      const block = doc.content[0];
      expect(block.type).toBe('codeBlock');
      if (block.type === 'codeBlock') {
        expect(block.content[0].text).toBe('console.log("hi");');
      }
      expect(stderrSpy).toHaveBeenCalledWith(
        expect.stringContaining('unclosed code fence'),
      );
    } finally {
      stderrSpy.mockRestore();
    }
  });

  it('mixed: heading + paragraph + code block + list', () => {
    const md = [
      '# Title',
      '',
      'Some **bold** text.',
      '',
      '```ts',
      'const x = 1;',
      '```',
      '',
      '- alpha',
      '- beta',
    ].join('\n');

    const doc = markdownToAdf(md);
    expect(doc.content).toHaveLength(4);
    expect(doc.content[0].type).toBe('heading');
    expect(doc.content[1].type).toBe('paragraph');
    expect(doc.content[2].type).toBe('codeBlock');
    expect(doc.content[3].type).toBe('bulletList');
  });

  describe('heading level clamp', () => {
    it('#### (4 hashes) is NOT a heading — falls through to paragraph', () => {
      // The regex /^(#{1,3})\s+(.+)$/ rejects 4+ hashes, so the line is parsed as paragraph.
      const doc = markdownToAdf('#### too deep');
      expect(doc.content).toHaveLength(1);
      expect(doc.content[0].type).toBe('paragraph');
    });

    it('heading.attrs.level is always 1, 2, or 3 (never out-of-range)', () => {
      for (const md of ['# h1', '## h2', '### h3']) {
        const doc = markdownToAdf(md);
        const b = doc.content[0];
        if (b.type === 'heading') {
          expect([1, 2, 3]).toContain(b.attrs.level);
        }
      }
    });
  });

  describe('inline-mark regex documented limitations', () => {
    it('nested bold + italic (**bold *and italic***) parses ambiguously — documented as out-of-spec', () => {
      const doc = markdownToAdf('**bold *and italic***');
      const p = doc.content[0];
      expect(p.type).toBe('paragraph');
      if (p.type === 'paragraph') {
        expect(p.content.length).toBeGreaterThan(0);
        // No node should have BOTH strong and em marks (no recursion).
        for (const node of p.content) {
          if ('marks' in node && node.marks) {
            const types = node.marks.map((m) => m.type).sort();
            expect(types).not.toEqual(['em', 'strong']);
          }
        }
      }
    });

    it('escaped delimiters (\\*not italic\\*) are NOT escaped — parsed by current regex', () => {
      const doc = markdownToAdf('\\*not italic\\*');
      const p = doc.content[0];
      expect(p.type).toBe('paragraph');
      if (p.type === 'paragraph') {
        expect(p.content.length).toBeGreaterThan(0);
      }
    });
  });
});
