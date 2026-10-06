import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', () => ({ request: vi.fn() }));

import { request } from '../client.js';
import { registerProjectCreate } from './project-create.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function run(args: string[]): Promise<Command> {
  const p = new Command();
  p.exitOverride();
  registerProjectCreate(p);
  return p.parseAsync(['node', 'jira', 'project-create', ...args]);
}

describe('project-create', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
  });

  it('looks up /myself for the lead, then POSTs /project with default type + template', async () => {
    mockRequest.mockImplementation(async (_method: string, path: string) =>
      path === '/myself' ? { accountId: 'me-1', displayName: 'Me' } : { id: 10001, key: 'NEW', self: 'x' },
    );
    await run(['--key', 'NEW', '--name', 'New Project']);
    expect(mockRequest).toHaveBeenNthCalledWith(1, 'GET', '/myself');
    expect(mockRequest).toHaveBeenNthCalledWith(2, 'POST', '/project', {
      key: 'NEW',
      name: 'New Project',
      projectTypeKey: 'software',
      projectTemplateKey: 'com.pyxis.greenhopper.jira:gh-simplified-kanban-classic',
      leadAccountId: 'me-1',
    });
    expect(console.log).toHaveBeenCalledWith('Created NEW (id=10001)');
  });

  it('--lead/--type/--template skip the /myself lookup and are sent verbatim', async () => {
    mockRequest.mockResolvedValue({ id: 7, key: 'BIZ', self: 'x' });
    await run(['--key', 'BIZ', '--name', 'Biz', '--type', 'business', '--template', 'tmpl:x', '--lead', 'acc-9']);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    expect(mockRequest).toHaveBeenCalledWith('POST', '/project', {
      key: 'BIZ',
      name: 'Biz',
      projectTypeKey: 'business',
      projectTemplateKey: 'tmpl:x',
      leadAccountId: 'acc-9',
    });
    expect(console.log).toHaveBeenCalledWith('Created BIZ (id=7)');
  });

  it('requires --key and --name', async () => {
    vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    await expect(run(['--name', 'x'])).rejects.toThrow(/--key/);
    await expect(run(['--key', 'ABC'])).rejects.toThrow(/--name/);
    expect(mockRequest).not.toHaveBeenCalled();
  });
});
