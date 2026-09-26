import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Command } from 'commander';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

import { request } from '../client.js';
import { registerGet } from './get.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

function freshProgram(): Command {
  const p = new Command();
  p.exitOverride();
  registerGet(p);
  return p;
}

describe('get labels (HIMMEL-3610)', () => {
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('requests the labels field alongside the existing fields', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        labels: ['a', 'b'],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [method, path] = mockRequest.mock.calls[0];
    expect(method).toBe('GET');
    expect(path).toContain('fields=summary,status,issuetype,parent,assignee,description,labels');
  });

  it('prints a Labels line when the issue has labels', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        labels: ['a', 'b'],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
    const printed = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(printed).toContain('Labels: a, b');
  });

  it('prints no Labels line when the issue has no labels', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        labels: [],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
    const printed = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(printed).not.toContain('Labels:');
  });

  it('prints no Labels line when the field is absent (undefined)', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
    const printed = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(printed).not.toContain('Labels:');
  });

  it('--short still prints the Labels line, header unchanged otherwise', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        labels: ['ai-tasklist'],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1', '--short']);
    expect(logSpy).toHaveBeenNthCalledWith(1, 'HIMMEL-1\tTask\tTo Do\tS');
    const printed = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(printed).toContain('Labels: ai-tasklist');
  });
});
