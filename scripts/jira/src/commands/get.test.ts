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

  it('--short never prints a Labels line (one-line header only, consumed by pr-open.sh)', async () => {
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
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(logSpy).toHaveBeenNthCalledWith(1, 'HIMMEL-1\tTask\tTo Do\tS');
  });
});

describe('get fix versions (HIMMEL-3713)', () => {
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.clearAllMocks();
    logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('requests the fixVersions field alongside the existing fields', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        fixVersions: [{ name: 'v1.0.0' }],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
    const [, path] = mockRequest.mock.calls[0];
    expect(path).toContain(
      'fields=summary,status,issuetype,parent,assignee,description,labels,fixVersions',
    );
  });

  it('prints a Fix versions line when the issue has fixVersions', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        fixVersions: [{ name: 'v1.0.0' }, { name: 'v1.0.1' }],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
    const printed = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(printed).toContain('Fix versions: v1.0.0, v1.0.1');
  });

  it('prints no Fix versions line when the issue has no fixVersions', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        fixVersions: [],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1']);
    const printed = logSpy.mock.calls.map((c) => c[0]).join('\n');
    expect(printed).not.toContain('Fix versions:');
  });

  it('prints no Fix versions line when the field is absent (undefined)', async () => {
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
    expect(printed).not.toContain('Fix versions:');
  });

  it('--short never prints a Fix versions line', async () => {
    mockRequest.mockResolvedValue({
      key: 'HIMMEL-1',
      fields: {
        summary: 'S',
        status: { name: 'To Do' },
        issuetype: { name: 'Task' },
        description: null,
        fixVersions: [{ name: 'v1.0.0' }],
      },
    });
    const p = freshProgram();
    await p.parseAsync(['node', 'jira', 'get', 'HIMMEL-1', '--short']);
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(logSpy).toHaveBeenNthCalledWith(1, 'HIMMEL-1\tTask\tTo Do\tS');
  });
});
