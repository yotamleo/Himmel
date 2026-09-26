import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Command } from 'commander';
import { buildEditFields } from './edit.js';

vi.mock('../client.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../client.js')>();
  return { ...actual, request: vi.fn() };
});

describe('edit', () => {
  const orig = process.env.JIRA_SEVERITY_FIELD;

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    if (orig === undefined) delete process.env.JIRA_SEVERITY_FIELD;
    else process.env.JIRA_SEVERITY_FIELD = orig;
  });

  it('builds fields payload for priority only', () => {
    const fields = buildEditFields({ priority: 'High' });
    expect(fields).toEqual({ priority: { name: 'High' } });
  });

  it('builds fields payload for severity only when env var is set', () => {
    process.env.JIRA_SEVERITY_FIELD = 'customfield_10016';
    const fields = buildEditFields({ severity: 'Major' });
    expect(fields).toEqual({ customfield_10016: { value: 'Major' } });
  });

  it('builds combined fields payload', () => {
    process.env.JIRA_SEVERITY_FIELD = 'customfield_10016';
    const fields = buildEditFields({ priority: 'High', severity: 'Major' });
    expect(fields).toEqual({
      priority: { name: 'High' },
      customfield_10016: { value: 'Major' },
    });
  });

  it('throws when --severity is passed but JIRA_SEVERITY_FIELD is unset', () => {
    delete process.env.JIRA_SEVERITY_FIELD;
    expect(() => buildEditFields({ severity: 'Major' })).toThrow(
      /JIRA_SEVERITY_FIELD/,
    );
  });

  it('throws when nothing to edit', () => {
    expect(() => buildEditFields({})).toThrow(/at least one of/i);
  });

  it('builds fields payload for parent only', () => {
    const fields = buildEditFields({ parent: 'HIMMEL-199' });
    expect(fields).toEqual({ parent: { key: 'HIMMEL-199' } });
  });

  it('combines parent with another field', () => {
    const fields = buildEditFields({ parent: 'HIMMEL-199', priority: 'High' });
    expect(fields).toEqual({
      parent: { key: 'HIMMEL-199' },
      priority: { name: 'High' },
    });
  });

  it('maps --title to the summary field (plain string)', () => {
    const fields = buildEditFields({ title: 'New title' });
    expect(fields).toEqual({ summary: 'New title' });
  });

  it('maps --description through markdownToAdf', () => {
    const fields = buildEditFields({ description: 'Plain paragraph.' });
    expect(fields).toEqual({
      description: {
        type: 'doc',
        version: 1,
        content: [
          {
            type: 'paragraph',
            content: [{ type: 'text', text: 'Plain paragraph.' }],
          },
        ],
      },
    });
  });

  it('combines title + description in one payload', () => {
    const fields = buildEditFields({ title: 'T', description: 'D' });
    expect(fields).toHaveProperty('summary', 'T');
    expect(fields).toHaveProperty('description');
    expect((fields.description as { type: string }).type).toBe('doc');
  });

  it('maps --labels to a full-replace labels array (HIMMEL-243)', () => {
    const fields = buildEditFields({ labels: 'a, b ,c' });
    expect(fields).toEqual({ labels: ['a', 'b', 'c'] });
  });

  it('combines labels with another field', () => {
    const fields = buildEditFields({ labels: 'ai-tasklist', priority: 'High' });
    expect(fields).toEqual({
      labels: ['ai-tasklist'],
      priority: { name: 'High' },
    });
  });

  it('throws on an empty --labels (would otherwise wipe all labels)', () => {
    expect(() => buildEditFields({ labels: '' })).toThrow(
      /at least one non-empty label/,
    );
  });

  it('throws on a whitespace/commas-only --labels', () => {
    expect(() => buildEditFields({ labels: ' , ' })).toThrow(
      /at least one non-empty label/,
    );
  });

  it('allows empty string description to clear the field', () => {
    // Empty markdown -> ADF doc with no content blocks; Jira accepts this as
    // "clear the description". The undefined-check (not truthy-check) in
    // buildEditFields makes this reachable.
    const fields = buildEditFields({ description: '' });
    expect(fields).toEqual({
      description: { type: 'doc', version: 1, content: [] },
    });
  });

  it('throws when --labels and --add-labels are both given', () => {
    expect(() =>
      buildEditFields({ labels: 'a', addLabels: 'b' }),
    ).toThrow(/mutually exclusive/);
  });

  it('does not throw "nothing to edit" when only --add-labels is given', () => {
    expect(buildEditFields({ addLabels: 'a,b' })).toEqual({});
  });
});

describe('edit --add-labels (HIMMEL-3610)', () => {
  let mockRequest: ReturnType<typeof vi.fn>;

  beforeEach(async () => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { request } = await import('../client.js');
    mockRequest = request as unknown as ReturnType<typeof vi.fn>;
    mockRequest.mockResolvedValue({});
  });

  function freshProgram(register: (p: Command) => void): Command {
    const p = new Command();
    p.exitOverride();
    register(p);
    return p;
  }

  it('sends update.labels add ops and NO fields.labels', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--add-labels', 'a,b']);
    expect(mockRequest).toHaveBeenCalledTimes(1);
    const [method, path, body] = mockRequest.mock.calls[0];
    expect(method).toBe('PUT');
    expect(path).toBe('/issue/HIMMEL-1');
    expect(body).toEqual({
      update: { labels: [{ add: 'a' }, { add: 'b' }] },
    });
    expect((body as { fields?: unknown }).fields).toBeUndefined();
  });

  it('rejects --labels together with --add-labels as a usage error', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await expect(
      p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--labels', 'a', '--add-labels', 'b']),
    ).rejects.toThrow(/mutually exclusive/);
    expect(mockRequest).not.toHaveBeenCalled();
  });

  it('control: --labels alone still sends a full-replace fields.labels, unchanged', async () => {
    const { registerEdit } = await import('./edit.js');
    const p = freshProgram(registerEdit);
    await p.parseAsync(['node', 'jira', 'edit', 'HIMMEL-1', '--labels', 'a,b']);
    const [, , body] = mockRequest.mock.calls[0];
    expect(body).toEqual({ fields: { labels: ['a', 'b'] } });
    expect((body as { update?: unknown }).update).toBeUndefined();
  });
});
