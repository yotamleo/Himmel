import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';
import { jqlStatusClause, resolveListJql, registerList } from './list.js';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

import { request } from '../client.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

describe('jqlStatusClause (HIMMEL-112)', () => {
  it('defaults to To Do + In Progress when status is undefined', () => {
    expect(jqlStatusClause(undefined)).toBe('status in ("To Do","In Progress")');
  });

  it('defaults to To Do + In Progress when status is empty string', () => {
    expect(jqlStatusClause('')).toBe('status in ("To Do","In Progress")');
  });

  it('quote-wraps a single multi-word status', () => {
    expect(jqlStatusClause('To Do')).toBe('status in ("To Do")');
  });

  it('quote-wraps each comma-separated multi-word status', () => {
    expect(jqlStatusClause('To Do,In Progress')).toBe('status in ("To Do","In Progress")');
  });

  it('trims whitespace around each token', () => {
    expect(jqlStatusClause('  To Do  ,  In Progress  ')).toBe(
      'status in ("To Do","In Progress")',
    );
  });

  it('handles single-word statuses (no quoting needed but still safe)', () => {
    expect(jqlStatusClause('Done')).toBe('status in ("Done")');
  });

  it('handles mixed single-word + multi-word', () => {
    expect(jqlStatusClause('Done,To Do,Blocked')).toBe(
      'status in ("Done","To Do","Blocked")',
    );
  });

  it('drops empty tokens (consecutive commas, leading/trailing)', () => {
    expect(jqlStatusClause(',Done,,In Progress,')).toBe(
      'status in ("Done","In Progress")',
    );
  });

  it('falls back to defaults when arg is just commas/whitespace', () => {
    expect(jqlStatusClause(',,, ,')).toBe('status in ("To Do","In Progress")');
  });

  it('escapes embedded double-quotes in status names', () => {
    // Atlassian custom statuses can technically contain quotes; defend against
    // operator-supplied values that include them.
    expect(jqlStatusClause('Need "approval"')).toBe(
      'status in ("Need \\"approval\\"")',
    );
  });
});

describe('resolveListJql (HIMMEL-215)', () => {
  it('passes --jql through verbatim, ignoring project/status/type', () => {
    expect(
      resolveListJql({
        jql: 'project=LUNA AND text ~ "foo" ORDER BY updated DESC',
        project: 'HIMMEL',
        type: 'Story',
        status: 'Done',
      }),
    ).toBe('project=LUNA AND text ~ "foo" ORDER BY updated DESC');
  });

  it('treats an empty --jql as not supplied (falls through to default build)', () => {
    expect(resolveListJql({ jql: '', project: 'HIMMEL' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") ORDER BY created DESC',
    );
  });

  it('treats a whitespace-only --jql as not supplied (falls through to default build)', () => {
    expect(resolveListJql({ jql: '   ', project: 'HIMMEL' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") ORDER BY created DESC',
    );
  });

  it('trims surrounding whitespace from a non-empty --jql passthrough', () => {
    expect(
      resolveListJql({ jql: '  project=LUNA ORDER BY updated DESC  ' }),
    ).toBe('project=LUNA ORDER BY updated DESC');
  });

  it('builds the default project/status query when --jql is absent', () => {
    expect(resolveListJql({ project: 'HIMMEL' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") ORDER BY created DESC',
    );
  });

  it('appends issuetype filter when --type is set (no --jql)', () => {
    expect(resolveListJql({ project: 'HIMMEL', type: 'Task' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") AND issuetype="Task" ORDER BY created DESC',
    );
  });

  it('honours --status in the default build', () => {
    expect(resolveListJql({ project: 'HIMMEL', status: 'Done' })).toBe(
      'project=HIMMEL AND status in ("Done") ORDER BY created DESC',
    );
  });
});

describe('resolveListJql --label (HIMMEL-243)', () => {
  it('composes a labels clause into the built JQL', () => {
    expect(resolveListJql({ project: 'HIMMEL', label: 'ai-tasklist' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") AND labels = "ai-tasklist" ORDER BY created DESC',
    );
  });

  it('composes labels alongside type and status filters', () => {
    expect(
      resolveListJql({ project: 'HIMMEL', type: 'Task', status: 'Done', label: 'x' }),
    ).toBe(
      'project=HIMMEL AND status in ("Done") AND issuetype="Task" AND labels = "x" ORDER BY created DESC',
    );
  });

  it('is ignored when --jql is supplied (--jql wins)', () => {
    expect(
      resolveListJql({ jql: 'project=LUNA ORDER BY updated DESC', label: 'x' }),
    ).toBe('project=LUNA ORDER BY updated DESC');
  });

  it('trims the label value', () => {
    expect(resolveListJql({ project: 'HIMMEL', label: '  x  ' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") AND labels = "x" ORDER BY created DESC',
    );
  });

  it('treats an empty --label as not supplied', () => {
    expect(resolveListJql({ project: 'HIMMEL', label: '' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") ORDER BY created DESC',
    );
  });

  it('treats a whitespace-only --label as not supplied', () => {
    expect(resolveListJql({ project: 'HIMMEL', label: '   ' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") ORDER BY created DESC',
    );
  });

  it('escapes embedded double-quotes in the label value', () => {
    expect(resolveListJql({ project: 'HIMMEL', label: 'a"b' })).toBe(
      'project=HIMMEL AND status in ("To Do","In Progress") AND labels = "a\\"b" ORDER BY created DESC',
    );
  });
});

describe('list --labels display flag (HIMMEL-3610)', () => {
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  function freshProgram(): Command {
    const p = new Command();
    p.exitOverride();
    return p;
  }

  it('does NOT request labels by default (unchanged column count)', async () => {
    mockRequest.mockResolvedValue({ issues: [], total: 0 });
    const p = freshProgram();
    registerList(p);
    await p.parseAsync(['node', 'jira', 'list']);
    const [, path] = mockRequest.mock.calls[0];
    expect(path).toContain('fields=summary,status,issuetype&');
    expect(path).not.toContain('labels');
  });

  it('requests labels and appends a 5th column only with --labels', async () => {
    mockRequest.mockResolvedValue({
      issues: [
        {
          key: 'HIMMEL-1',
          fields: {
            summary: 'S',
            status: { name: 'To Do' },
            issuetype: { name: 'Task' },
            labels: ['a', 'b'],
          },
        },
      ],
      total: 1,
    });
    const p = freshProgram();
    registerList(p);
    await p.parseAsync(['node', 'jira', 'list', '--labels']);
    const [, path] = mockRequest.mock.calls[0];
    expect(path).toContain('fields=summary,status,issuetype,labels');
    expect(logSpy).toHaveBeenCalledWith('HIMMEL-1\tTask\tTo Do\tS\ta,b');
  });

  it('appends an empty trailing column when the issue has no labels', async () => {
    mockRequest.mockResolvedValue({
      issues: [
        {
          key: 'HIMMEL-2',
          fields: {
            summary: 'S2',
            status: { name: 'To Do' },
            issuetype: { name: 'Task' },
            labels: [],
          },
        },
      ],
      total: 1,
    });
    const p = freshProgram();
    registerList(p);
    await p.parseAsync(['node', 'jira', 'list', '--labels']);
    expect(logSpy).toHaveBeenCalledWith('HIMMEL-2\tTask\tTo Do\tS2\t');
  });
});
