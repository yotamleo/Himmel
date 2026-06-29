import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';

// Mock the network layer so the verb actions resolve without a real Jira.
vi.mock('../client.js', () => ({
  request: vi.fn(),
  agileRequest: vi.fn(),
  projectKey: () => 'HIMMEL',
  severityField: () => undefined,
  resolveAccountId: vi.fn(async (x: string) => x),
}));
// Mock the breadcrumb writer so we can assert which verbs call it.
vi.mock('../breadcrumb.js', () => ({ writeJiraBreadcrumb: vi.fn() }));

import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { registerTransition } from './transition.js';
import { registerMove } from './move.js';
import { registerGet } from './get.js';
import { registerWorklog } from './worklog.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;
const mockBreadcrumb = writeJiraBreadcrumb as unknown as ReturnType<typeof vi.fn>;

function freshProgram(register: (p: Command) => void): Command {
  const p = new Command();
  p.exitOverride(); // throw instead of process.exit on parse errors
  register(p);
  return p;
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('jira breadcrumb wiring', () => {
  it('transition (mutation) drops a breadcrumb for the key', async () => {
    mockRequest.mockImplementation(async (method: string) => {
      if (method === 'GET') return { transitions: [{ id: '31', name: 'Done' }] };
      return {};
    });
    const p = freshProgram(registerTransition);
    await p.parseAsync(['node', 'jira', 'transition', 'HIMMEL-1', 'Done']);
    expect(mockBreadcrumb).toHaveBeenCalledTimes(1);
    expect(mockBreadcrumb).toHaveBeenCalledWith('HIMMEL-1');
  });

  it('move (mutation) drops a breadcrumb for the source key', async () => {
    mockRequest.mockImplementation(async (method: string, path: string) => {
      if (method === 'GET' && path.startsWith('/project/')) return {};
      if (method === 'GET' && /\/issue\/[^/]+\?fields/.test(path))
        return { key: 'HIMMEL-2', fields: { summary: 'S', issuetype: { name: 'Task' }, description: null } };
      if (method === 'GET' && path.endsWith('/comment')) return { comments: [] };
      if (method === 'POST' && path === '/issue') return { key: 'LUNA-9' };
      if (method === 'GET' && path.endsWith('/transitions')) return { transitions: [{ id: '31', name: 'Done' }] };
      return {};
    });
    const p = freshProgram(registerMove);
    await p.parseAsync(['node', 'jira', 'move', 'HIMMEL-2', '--to-project', 'LUNA']);
    expect(mockBreadcrumb).toHaveBeenCalledTimes(1);
    expect(mockBreadcrumb).toHaveBeenCalledWith('HIMMEL-2');
  });

  it('get (read) does NOT drop a breadcrumb', async () => {
    mockRequest.mockImplementation(async () => ({
      key: 'HIMMEL-3',
      fields: { summary: 'S', status: { name: 'To Do' }, issuetype: { name: 'Task' }, description: null },
    }));
    const p = freshProgram(registerGet);
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-3']);
    expect(mockBreadcrumb).not.toHaveBeenCalled();
  });

  it('worklog list (read) does NOT drop a breadcrumb', async () => {
    mockRequest.mockImplementation(async () => ({ worklogs: [] }));
    const p = freshProgram(registerWorklog);
    await p.parseAsync(['node', 'jira', 'worklog', 'list', 'HIMMEL-4']);
    expect(mockBreadcrumb).not.toHaveBeenCalled();
  });
});
