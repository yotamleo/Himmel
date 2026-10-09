import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

describe('edit --priority (HIMMEL-4640)', () => {
  let mockRequest: ReturnType<typeof vi.fn>;

  beforeEach(async () => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const { request } = await import('../client.js');
    mockRequest = request as unknown as ReturnType<typeof vi.fn>;
  });

  function freshProgram(register: (p: Command) => void): Command {
    const p = new Command();
    p.exitOverride();
    register(p);
    return p;
  }

  function readBack(name: string): void {
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? { fields: { priority: { name } } } : {},
    );
  }

  it('pins the PUT payload: fields.priority = {name}', async () => {
    readBack('Highest');
    const { registerEdit } = await import('./edit.js');
    await freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--priority', 'Highest']);
    const put = mockRequest.mock.calls.find((c) => c[0] === 'PUT');
    expect(put?.[1]).toBe('/issue/HIMMEL-1');
    expect(put?.[2]).toEqual({ fields: { priority: { name: 'Highest' } } });
  });

  it('reads the priority back after the PUT and succeeds when it matches', async () => {
    readBack('Highest');
    const { registerEdit } = await import('./edit.js');
    await freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--priority', 'highest']);
    const get = mockRequest.mock.calls.find((c) => c[0] === 'GET');
    expect(get?.[1]).toBe('/issue/HIMMEL-1?fields=priority');
    expect(console.log).toHaveBeenCalledWith('HIMMEL-1 edited');
  });

  it('fails naming the priority field when the read-back still shows the old value', async () => {
    readBack('Medium');
    const { registerEdit } = await import('./edit.js');
    await expect(
      freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--priority', 'Highest']),
    ).rejects.toThrow(/priority.*Highest.*Medium/s);
    expect(console.log).not.toHaveBeenCalledWith('HIMMEL-1 edited');
  });

  it('control: a --title edit reads back summary only, never priority (HIMMEL-4644)', async () => {
    mockRequest.mockImplementation(async (method: string) =>
      method === 'GET' ? { fields: { summary: 't' } } : {},
    );
    const { registerEdit } = await import('./edit.js');
    await freshProgram(registerEdit).parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--title', 't']);
    const gets = mockRequest.mock.calls.filter((c) => c[0] === 'GET');
    expect(gets).toHaveLength(1);
    expect(gets[0][1]).toBe('/issue/HIMMEL-1?fields=summary');
    expect(String(gets[0][1])).not.toContain('priority');
  });
});
