import { describe, it, expect } from 'vitest';
import {
  lintPlainBlock,
  lintPlainBlockAdf,
  plainBlockVerdict,
  homeVerdict,
  PLAIN_BLOCK_TEMPLATE,
} from './plain-block.js';

const OK =
  '## Impact\nOperators lose X.\n\n## What\nFix X.\n\n## Why\nIt hurts.\n\n## Plan\n1. Edit a.ts.\n\n## DoD\n- A test fails before and passes after.\n\n## Agent detail\nfiles: a.ts';

const NO_BULLET = 'has no bullet or numbered line beyond the placeholder';

describe('lintPlainBlock (HIMMEL-5226)', () => {
  it('passes a full block', () => expect(lintPlainBlock(OK)).toEqual([]));

  it('names every missing section on an empty body', () => {
    expect(lintPlainBlock('')).toEqual([
      'missing "## Impact"',
      'missing "## What"',
      'missing "## Why"',
      'missing "## Plan"',
      'missing "## DoD"',
      'missing "## Agent detail"',
    ]);
  });

  it('flags an empty section', () => {
    expect(lintPlainBlock(OK.replace('Fix X.', ''))).toEqual(['"## What" is empty']);
  });

  it('does not count a heading inside a code fence', () => {
    expect(lintPlainBlock('```\n' + OK + '\n```')).toHaveLength(6);
  });

  it('a shorter or different closing marker does not end a fence (HIMMEL-5226)', () => {
    expect(lintPlainBlock('````\n```\n' + OK + '\n```')).toHaveLength(6);
    expect(lintPlainBlock('~~~\n```\n' + OK + '\n```')).toHaveLength(6);
    expect(lintPlainBlock('```\ncode\n```\n' + OK)).toEqual([]);
    expect(lintPlainBlock('```\n```not-a-close\n' + OK + '\n```')).toHaveLength(6);
  });

  it('a hash run with no space is text, not a heading (HIMMEL-5226)', () => {
    const noSpace = OK.replace(/^## /gm, '##');
    expect(lintPlainBlock(noSpace)).toHaveLength(6);
  });

  it('the template alone fails on Plan and DoD only, so a skeleton never files as is (HIMMEL-5643)', () => {
    expect(lintPlainBlock(PLAIN_BLOCK_TEMPLATE)).toEqual([
      `"## Plan" ${NO_BULLET}`,
      `"## DoD" ${NO_BULLET}`,
    ]);
  });

  it('refuses a body with no DoD and names it (HIMMEL-5643)', () => {
    expect(lintPlainBlock(OK.replace(/## DoD\n[^\n]*\n\n/, ''))).toEqual(['missing "## DoD"']);
  });

  it('refuses a body with no Plan and names it (HIMMEL-5643)', () => {
    expect(lintPlainBlock(OK.replace(/## Plan\n[^\n]*\n\n/, ''))).toEqual(['missing "## Plan"']);
  });

  it('refuses a DoD that holds only the placeholder line (HIMMEL-5643)', () => {
    const ph = OK.replace('- A test fails before and passes after.', '- <checkable result>');
    expect(lintPlainBlock(ph)).toEqual([`"## DoD" ${NO_BULLET}`]);
  });

  it('refuses Plan or DoD prose with no bullet or numbered line (HIMMEL-5643)', () => {
    const prose = OK.replace('- A test fails before and passes after.', 'A test fails before.');
    expect(lintPlainBlock(prose)).toEqual([`"## DoD" ${NO_BULLET}`]);
  });

  it('accepts a real line next to a placeholder line (HIMMEL-5643)', () => {
    expect(lintPlainBlock(OK.replace('1. Edit a.ts.', '1. <step>\n2. Edit a.ts.'))).toEqual([]);
  });
});

describe('lintPlainBlockAdf', () => {
  const h = (t: string) => ({
    type: 'heading',
    attrs: { level: 2 },
    content: [{ type: 'text', text: t }],
  });
  const p = (t: string) => ({ type: 'paragraph', content: [{ type: 'text', text: t }] });
  const list = (type: string, ts: string[]) => ({
    type,
    content: ts.map((t) => ({ type: 'listItem', content: [p(t)] })),
  });
  const ul = (...ts: string[]) => list('bulletList', ts);
  const ol = (...ts: string[]) => list('orderedList', ts);

  it('reads heading nodes', () => {
    const doc = {
      type: 'doc',
      content: [
        h('Impact'), p('a'), h('What'), p('b'), h('Why'), p('c'),
        h('Plan'), ol('step'), h('DoD'), ul('check'), h('Agent detail'), p('d'),
      ],
    };
    expect(lintPlainBlockAdf(doc)).toEqual([]);
    expect(lintPlainBlockAdf({ type: 'doc', content: [p('x')] })).toHaveLength(6);
  });

  it('agrees with the markdown path: list items count as lines, placeholders and prose do not (HIMMEL-5643)', () => {
    const base = [h('Impact'), p('a'), h('What'), p('b'), h('Why'), p('c'), h('Agent detail'), p('d')];
    const doc = (plan: unknown[], dod: unknown[]) => ({
      type: 'doc',
      content: [...base, h('Plan'), ...plan, h('DoD'), ...dod],
    });
    const dodBad = [`"## DoD" ${NO_BULLET}`];
    expect(lintPlainBlockAdf(doc([ol('step')], [ul('<checkable result>')]))).toEqual(dodBad);
    expect(lintPlainBlockAdf(doc([ol('step')], [p('only prose')]))).toEqual(dodBad);
    expect(lintPlainBlockAdf(doc([ol('<step>', 'real')], [ul('ok')]))).toEqual([]);
    expect(lintPlainBlockAdf(doc([], [ul('ok')]))).toEqual(['"## Plan" is empty']);
  });

  it('an empty paragraph under a section still leaves it empty (HIMMEL-5643)', () => {
    const doc = { type: 'doc', content: [h('Impact'), p(''), h('What'), p('b'), h('Why'), p('c'), h('Plan'), ol('s'), h('DoD'), ul('d'), h('Agent detail'), p('e')] };
    expect(lintPlainBlockAdf(doc)).toEqual(['"## Impact" is empty']);
  });

  it('a paragraph or code block that merely reads like a list line is not a list item (HIMMEL-5643)', () => {
    const base = [h('Impact'), p('a'), h('What'), p('b'), h('Why'), p('c'), h('Plan'), ol('step'), h('Agent detail'), p('d')];
    const code = { type: 'codeBlock', content: [{ type: 'text', text: '- fake' }] };
    const dodBad = [`"## DoD" ${NO_BULLET}`];
    expect(lintPlainBlockAdf({ type: 'doc', content: [...base, h('DoD'), p('- fake')] })).toEqual(dodBad);
    expect(lintPlainBlockAdf({ type: 'doc', content: [...base, h('DoD'), code] })).toEqual(dodBad);
  });
});

describe('plainBlockVerdict', () => {
  it('refuses Task/Story/Bug, warns Epic/Subtask, passes when nothing is missing', () => {
    expect(plainBlockVerdict('Task', ['missing "## Why"']).action).toBe('refuse');
    expect(plainBlockVerdict('bug', ['x']).action).toBe('refuse');
    expect(plainBlockVerdict('Epic', ['x']).action).toBe('warn');
    expect(plainBlockVerdict('Subtask', ['x']).action).toBe('warn');
    expect(plainBlockVerdict('Task', []).action).toBe('ok');
  });

  it('names a missing Plan and DoD in the refusal and keeps an Epic warn-only (HIMMEL-5643)', () => {
    const found = lintPlainBlock(
      OK.replace(/## Plan\n[^\n]*\n\n## DoD\n[^\n]*\n\n/, ''),
    );
    expect(plainBlockVerdict('Task', found).message).toMatch(/missing "## Plan"; missing "## DoD"/);
    expect(plainBlockVerdict('Epic', found).action).toBe('warn');
  });
});

describe('homeVerdict (HIMMEL-6223)', () => {
  const home = { sector: 'Ship loop', parent: 'HIMMEL-1', labels: [] as string[] };

  it('refuses a Task, Story or Bug with no Sector, naming the field and the fix', () => {
    for (const t of ['Task', 'Story', 'bug']) {
      const v = homeVerdict(t, { ...home, sector: undefined });
      expect(v.action).toBe('refuse');
      expect(v.message).toMatch(/no Sector.*--sector/s);
    }
  });

  it('refuses a Sector with neither a parent nor the standalone label, naming the marker', () => {
    const v = homeVerdict('Task', { sector: 'Ship loop', labels: ['x'] });
    expect(v.action).toBe('refuse');
    expect(v.message).toMatch(/--parent.*--labels standalone/s);
  });

  it('passes with a Sector and a parent, or with a Sector and the standalone label', () => {
    expect(homeVerdict('Task', home).action).toBe('ok');
    expect(homeVerdict('Task', { sector: 'Ship loop', labels: ['a', 'standalone'] }).action).toBe('ok');
    // Jira labels are case-sensitive, so a differently cased label is a different label.
    expect(homeVerdict('Task', { sector: 'Ship loop', labels: ['Standalone'] }).action).toBe('refuse');
  });

  it('only warns for an Epic or Subtask with neither', () => {
    expect(homeVerdict('Epic', { labels: [] }).action).toBe('warn');
    expect(homeVerdict('Subtask', { labels: [] }).action).toBe('warn');
    expect(homeVerdict('Epic', home).action).toBe('ok');
  });
});
