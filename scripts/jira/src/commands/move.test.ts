import { describe, it, expect } from 'vitest';
import {
  findTransitionByName,
  prependSupersedesNote,
  safeContent,
  wrapMovedComment,
  type AdfDoc,
  type JiraComment,
} from './move.js';
import type { JiraTransition } from '../types.js';

const fixedNow = new Date('2026-05-27T08:00:00.000Z');

describe('safeContent', () => {
  it('returns [] for null', () => {
    expect(safeContent(null)).toEqual([]);
  });

  it('returns [] for undefined', () => {
    expect(safeContent(undefined)).toEqual([]);
  });

  it('returns [] when content is missing', () => {
    expect(safeContent({})).toEqual([]);
  });

  it('returns [] when content is not an array (malformed legacy ADF)', () => {
    // Legacy issues sometimes carry a stringified description that survived
    // earlier migrations. The shape is malformed for our purposes.
    expect(safeContent({ content: 'some legacy text' } as { content: unknown })).toEqual([]);
  });

  it('returns the array when content is well-formed', () => {
    const arr = [{ type: 'paragraph' }];
    expect(safeContent({ content: arr } as { content: unknown })).toEqual(arr);
  });
});

describe('prependSupersedesNote', () => {
  it('prepends a supersedes paragraph to an existing description', () => {
    const original: AdfDoc = {
      type: 'doc',
      version: 1,
      content: [
        {
          type: 'paragraph',
          content: [{ type: 'text', text: 'Existing body line.' }],
        },
      ],
    };
    const result = prependSupersedesNote('HIMMEL-180', original, fixedNow);
    expect(result.type).toBe('doc');
    expect(result.version).toBe(1);
    expect(result.content).toHaveLength(2);
    const note = result.content[0];
    expect(note.type).toBe('paragraph');
    expect((note.content?.[0] as { text: string }).text).toBe(
      'Originally filed as HIMMEL-180 — moved 2026-05-27 via jira move.',
    );
    expect((note.content?.[0] as { marks: Array<{ type: string }> }).marks).toEqual([
      { type: 'em' },
    ]);
    expect(result.content[1]).toEqual(original.content[0]);
  });

  it('handles null source description', () => {
    const result = prependSupersedesNote('HIMMEL-180', null, fixedNow);
    expect(result.content).toHaveLength(1);
    expect((result.content[0].content?.[0] as { text: string }).text).toBe(
      'Originally filed as HIMMEL-180 — moved 2026-05-27 via jira move.',
    );
  });

  it('handles undefined source description', () => {
    const result = prependSupersedesNote('HIMMEL-180', undefined, fixedNow);
    expect(result.content).toHaveLength(1);
  });

  it('preserves non-paragraph nodes (codeBlock, panel, heading) unchanged', () => {
    const original: AdfDoc = {
      type: 'doc',
      version: 1,
      content: [
        {
          type: 'codeBlock',
          attrs: { language: 'bash' },
          content: [{ type: 'text', text: 'echo hello' }],
        },
        {
          type: 'panel',
          attrs: { panelType: 'info' },
          content: [
            {
              type: 'paragraph',
              content: [{ type: 'text', text: 'callout body' }],
            },
          ],
        },
        {
          type: 'heading',
          attrs: { level: 2 },
          content: [{ type: 'text', text: 'Section' }],
        },
      ],
    };
    const result = prependSupersedesNote('HIMMEL-180', original, fixedNow);
    expect(result.content).toHaveLength(4); // note + 3 originals
    expect(result.content[1].type).toBe('codeBlock');
    expect(result.content[2].type).toBe('panel');
    expect(result.content[3].type).toBe('heading');
  });

  it('falls back to safe doc when source description has malformed content (non-array)', () => {
    // Cast through unknown to simulate a legacy/malformed shape that escaped
    // the type system in the wild.
    const malformed = {
      type: 'doc',
      version: 1,
      content: 'string content from a legacy migration',
    } as unknown as AdfDoc;
    const result = prependSupersedesNote('HIMMEL-180', malformed, fixedNow);
    expect(result.content).toHaveLength(1); // only the note; bad content dropped
    expect((result.content[0].content?.[0] as { text: string }).text).toContain(
      'Originally filed as HIMMEL-180',
    );
  });
});

describe('wrapMovedComment', () => {
  it('wraps comment body with author + date prefix', () => {
    const comment: JiraComment = {
      id: '1',
      author: { displayName: 'Yotam' },
      created: '2026-05-15T10:30:00.000Z',
      body: {
        type: 'doc',
        version: 1,
        content: [
          {
            type: 'paragraph',
            content: [{ type: 'text', text: 'Original comment text.' }],
          },
        ],
      },
    };
    const wrapped = wrapMovedComment(comment);
    expect(wrapped.type).toBe('doc');
    expect(wrapped.content).toHaveLength(2);
    expect((wrapped.content[0].content?.[0] as { text: string }).text).toBe(
      'Original by Yotam on 2026-05-15:',
    );
    expect(wrapped.content[1]).toEqual(comment.body.content[0]);
  });

  it('handles empty source comment body content', () => {
    const comment: JiraComment = {
      id: '1',
      author: { displayName: 'Yotam' },
      created: '2026-05-15T10:30:00.000Z',
      body: { type: 'doc', version: 1, content: [] },
    };
    const wrapped = wrapMovedComment(comment);
    expect(wrapped.content).toHaveLength(1);
    expect((wrapped.content[0].content?.[0] as { text: string }).text).toContain(
      'Original by Yotam',
    );
  });

  it('handles malformed comment body (content non-array)', () => {
    const comment = {
      id: '1',
      author: { displayName: 'Yotam' },
      created: '2026-05-15T10:30:00.000Z',
      body: { type: 'doc', version: 1, content: null },
    } as unknown as JiraComment;
    const wrapped = wrapMovedComment(comment);
    expect(wrapped.content).toHaveLength(1); // only the prefix; bad content dropped
  });
});

describe('findTransitionByName', () => {
  const transitions: JiraTransition[] = [
    { id: '11', name: 'To Do' },
    { id: '21', name: 'In Progress' },
    { id: '31', name: 'Done' },
    { id: '41', name: "Won't Do" },
  ];

  it('matches by exact name', () => {
    expect(findTransitionByName(transitions, 'Done')).toEqual({ id: '31', name: 'Done' });
  });

  it('matches case-insensitively', () => {
    expect(findTransitionByName(transitions, 'done')).toEqual({ id: '31', name: 'Done' });
    expect(findTransitionByName(transitions, 'IN PROGRESS')).toEqual({
      id: '21',
      name: 'In Progress',
    });
  });

  it('returns undefined for missing name', () => {
    expect(findTransitionByName(transitions, 'Closed')).toBeUndefined();
  });

  it('returns undefined for undefined transitions (malformed response)', () => {
    expect(findTransitionByName(undefined, 'Done')).toBeUndefined();
  });

  it('returns undefined for null transitions', () => {
    expect(findTransitionByName(null, 'Done')).toBeUndefined();
  });

  it('returns undefined for empty array', () => {
    expect(findTransitionByName([], 'Done')).toBeUndefined();
  });
});
