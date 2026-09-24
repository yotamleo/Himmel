import { describe, it, expect } from 'vitest';
import { BUG_FREEZE, freezeFixVersion, freezeCheckJql } from './freeze.js';

describe('freezeFixVersion — v1 bug freeze at create (HIMMEL-3411)', () => {
  it('defaults a Bug created after the cutoff without v1-blocker to v1.0.1', () => {
    expect(freezeFixVersion('Bug', undefined, '2026-09-26')).toBe('v1.0.1');
    expect(freezeFixVersion('Bug', ['hooks'], '2026-10-01')).toBe('v1.0.1');
  });

  it('matches the Bug type case-insensitively', () => {
    expect(freezeFixVersion('bug', undefined, '2026-09-26')).toBe('v1.0.1');
  });

  it('applies no default when the Bug carries v1-blocker', () => {
    expect(freezeFixVersion('Bug', ['hooks', 'v1-blocker'], '2026-09-26')).toBeUndefined();
  });

  it('applies no default on or before the cutoff day', () => {
    expect(freezeFixVersion('Bug', undefined, '2026-09-25')).toBeUndefined();
    expect(freezeFixVersion('Bug', undefined, '2026-09-24')).toBeUndefined();
  });

  it('leaves non-Bug types alone', () => {
    expect(freezeFixVersion('Task', undefined, '2026-09-26')).toBeUndefined();
    expect(freezeFixVersion('Story', undefined, '2026-10-01')).toBeUndefined();
  });
});

describe('freezeCheckJql', () => {
  it('finds post-cutoff Bugs in the v1 version without the blocker label', () => {
    const jql = freezeCheckJql('HIMMEL');
    expect(jql).toBe(
      'project = "HIMMEL" AND issuetype = Bug AND created > "2026-09-25" ' +
        'AND fixVersion = "v1.0.0" AND (labels IS EMPTY OR labels != "v1-blocker") ORDER BY key ASC',
    );
    expect(jql).toContain(BUG_FREEZE.cutoff);
  });
});
