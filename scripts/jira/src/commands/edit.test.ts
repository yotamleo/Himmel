import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { buildEditFields } from './edit.js';

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
});
