import { describe, it, expect } from 'vitest';
import { formatIssue } from './output.js';
import type { JiraIssue } from './types.js';

describe('formatIssue', () => {
  it('returns KEY\tTYPE\tSTATUS\tSUMMARY', () => {
    const issue: JiraIssue = {
      key: 'HIMMEL-5',
      fields: {
        summary: 'My epic title',
        status: { name: 'In Progress' },
        issuetype: { name: 'Epic' },
      },
    };
    expect(formatIssue(issue)).toBe('HIMMEL-5\tEpic\tIn Progress\tMy epic title');
  });

  it('handles pipe characters in summary without breaking format', () => {
    const issue: JiraIssue = {
      key: 'HIMMEL-6',
      fields: {
        summary: 'Add | support for pipes',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
      },
    };
    expect(formatIssue(issue)).toBe('HIMMEL-6\tTask\tTo Do\tAdd | support for pipes');
  });
});
