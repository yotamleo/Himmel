import { describe, it, expect } from 'vitest';
import { BUG_FREEZE, freezeApplies, pickFreezeVersion, freezeCheckJql } from './freeze.js';

describe('freezeApplies — v1 bug freeze at create (HIMMEL-3411)', () => {
  it('applies to a Bug created after the cutoff without v1-blocker', () => {
    expect(freezeApplies('Bug', undefined, '2026-09-26')).toBe(true);
    expect(freezeApplies('Bug', ['hooks'], '2026-10-01')).toBe(true);
  });

  it('matches the Bug type case-insensitively', () => {
    expect(freezeApplies('bug', undefined, '2026-09-26')).toBe(true);
  });

  it('does not apply when the Bug carries v1-blocker', () => {
    expect(freezeApplies('Bug', ['hooks', 'v1-blocker'], '2026-09-26')).toBe(false);
  });

  it('does not apply on or before the cutoff day', () => {
    expect(freezeApplies('Bug', undefined, '2026-09-25')).toBe(false);
    expect(freezeApplies('Bug', undefined, '2026-09-24')).toBe(false);
  });

  it('leaves non-Bug types alone', () => {
    expect(freezeApplies('Task', undefined, '2026-09-26')).toBe(false);
    expect(freezeApplies('Story', undefined, '2026-10-01')).toBe(false);
  });
});

describe('pickFreezeVersion (HIMMEL-4489)', () => {
  const v = (name: string, released = false, archived = false) => ({ id: name, name, released, archived });

  it('skips a released defer version and takes the next unreleased one after v1.0.0', () => {
    const versions = [v('v1.0.0', true), v('v1.0.1', true), v('v1.0.2'), v('v1.1.0')];
    expect(pickFreezeVersion(versions)).toBe('v1.0.2');
  });

  it('takes the first unreleased version when none is released yet', () => {
    expect(pickFreezeVersion([v('v1.0.0', true), v('v1.0.1')])).toBe('v1.0.1');
  });

  it('ignores archived versions and versions before v1.0.0', () => {
    const versions = [v('v0.9', false), v('v1.0.0', true), v('v1.0.1', false, true), v('v1.0.2')];
    expect(pickFreezeVersion(versions)).toBe('v1.0.2');
  });

  it('returns undefined when there is no unreleased version after v1.0.0', () => {
    expect(pickFreezeVersion([v('v1.0.0', true), v('v1.0.1', true)])).toBeUndefined();
  });

  it('returns undefined when v1.0.0 is not in the list', () => {
    expect(pickFreezeVersion([v('v2.0.0')])).toBeUndefined();
  });
});

describe('freezeCheckJql', () => {
  it('finds post-cutoff Bugs in the v1 version without the blocker label', () => {
    const jql = freezeCheckJql('HIMMEL');
    expect(jql).toBe(
      'project = "HIMMEL" AND issuetype = Bug AND created >= "2026-09-26" ' +
        'AND fixVersion = "v1.0.0" AND (labels IS EMPTY OR labels != "v1-blocker") ORDER BY key ASC',
    );
  });

  it('starts the day after the cutoff, matching create (a Bug filed ON the cutoff day is not a leak)', () => {
    // Jira reads `created > "2026-09-25"` as after 00:00 that day, which would flag the cutoff day itself.
    expect(freezeCheckJql('HIMMEL')).not.toContain(`created > "${BUG_FREEZE.cutoff}"`);
    expect(freezeCheckJql('HIMMEL')).toContain('created >= "2026-09-26"');
  });
});
