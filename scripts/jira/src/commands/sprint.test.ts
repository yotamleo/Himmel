import { describe, it, expect, afterEach } from 'vitest';
import { sprintTarget, resolveBoard } from './sprint.js';

afterEach(() => { delete process.env.JIRA_BOARD_ID; });

describe('sprint helpers', () => {
  it('parses a backlog target', () => {
    expect(sprintTarget('backlog')).toEqual({ backlog: true });
  });
  it('parses a numeric sprint id', () => {
    expect(sprintTarget('42')).toEqual({ backlog: false, sprintId: '42' });
  });
  it('resolveBoard prefers --board', () => {
    expect(resolveBoard('5')).toBe('5');
  });
  it('resolveBoard falls back to JIRA_BOARD_ID', () => {
    process.env.JIRA_BOARD_ID = '7';
    expect(resolveBoard(undefined)).toBe('7');
  });
  it('resolveBoard throws when neither set', () => {
    expect(() => resolveBoard(undefined)).toThrow(/board/i);
  });
});
