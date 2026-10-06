import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, agileRequest: vi.fn() };
});
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { agileRequest } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { registerSprint } from './sprint.js';

const mockAgile = agileRequest as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerSprint(p);
  return p.parseAsync(['node', 'jira', ...args]);
}

describe('boards / sprints / sprint', () => {
  const savedBoard = process.env.JIRA_BOARD_ID;
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    delete process.env.JIRA_BOARD_ID;
  });
  afterEach(() => {
    if (savedBoard === undefined) delete process.env.JIRA_BOARD_ID;
    else process.env.JIRA_BOARD_ID = savedBoard;
  });

  it('boards: GET /board, prints id/type/name', async () => {
    mockAgile.mockResolvedValue({ values: [{ id: 3, name: 'Main Board', type: 'scrum' }] });
    await run(['boards']);
    expect(mockAgile).toHaveBeenCalledWith('GET', '/board');
    expect(console.log).toHaveBeenCalledWith('3\tscrum\tMain Board');
  });

  it('sprints --board: GET /board/<id>/sprint, prints id/state/name', async () => {
    mockAgile.mockResolvedValue({ values: [{ id: 9, name: 'Sprint 9', state: 'active' }] });
    await run(['sprints', '--board', '42']);
    expect(mockAgile).toHaveBeenCalledWith('GET', '/board/42/sprint');
    expect(console.log).toHaveBeenCalledWith('9\tactive\tSprint 9');
  });

  it('sprints falls back to JIRA_BOARD_ID', async () => {
    process.env.JIRA_BOARD_ID = '77';
    mockAgile.mockResolvedValue({ values: [] });
    await run(['sprints']);
    expect(mockAgile).toHaveBeenCalledWith('GET', '/board/77/sprint');
  });

  it('sprints with no board and no env rejects without a request', async () => {
    await expect(run(['sprints'])).rejects.toThrow(/--board/);
    expect(mockAgile).not.toHaveBeenCalled();
  });

  it('sprint <key> <id>: POST /sprint/<id>/issue with {issues:[key]}, breadcrumb, line', async () => {
    mockAgile.mockResolvedValue({});
    await run(['sprint', 'HIMMEL-5', '12']);
    expect(mockAgile).toHaveBeenCalledWith('POST', '/sprint/12/issue', { issues: ['HIMMEL-5'] });
    expect(writeJiraBreadcrumb).toHaveBeenCalledWith('HIMMEL-5');
    expect(console.log).toHaveBeenCalledWith('HIMMEL-5 moved to sprint 12');
  });

  it('sprint <key> backlog (any case): POST /backlog/issue', async () => {
    mockAgile.mockResolvedValue({});
    await run(['sprint', 'HIMMEL-5', 'Backlog']);
    expect(mockAgile).toHaveBeenCalledWith('POST', '/backlog/issue', { issues: ['HIMMEL-5'] });
    expect(console.log).toHaveBeenCalledWith('HIMMEL-5 moved to backlog');
  });
});
