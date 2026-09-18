import { describe, it, expect, vi, afterEach } from 'vitest';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs, loadConfig, loadHygieneKeys, loadCommits, runReconciliation } from './reconcile-backlog.mjs';

// I/O-boundary functions this file does NOT cover (loadBacklog,
// loadCommentBodies, loadDescription, makeJiraClient, main): each requires a
// built jira CLI dist/ + a live Jira endpoint (network + subprocess), with no
// local fixture standing in for either. The pure/local functions below —
// argv parsing, config/hygiene-doc file reads, and commit-corpus loading —
// carry no such dependency and are covered directly; the classification rules
// they feed into are already unit-tested in reconcile-lib.test.mjs (44/44).

function withTmpDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'reconcile-backlog-test-'));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe('parseArgs', () => {
  const OLD_PROJECT_KEY = process.env.JIRA_PROJECT_KEY;
  afterEach(() => {
    if (OLD_PROJECT_KEY === undefined) delete process.env.JIRA_PROJECT_KEY;
    else process.env.JIRA_PROJECT_KEY = OLD_PROJECT_KEY;
  });

  it('defaults to dry-run with JIRA_PROJECT_KEY as the project', () => {
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    const opts = parseArgs([]);
    expect(opts.apply).toBe(false);
    expect(opts.project).toBe('HIMMEL');
    expect(opts.limit).toBe('2000');
    expect(opts.hygieneDoc).toBeNull();
    expect(opts.commitsFile).toBeNull();
    expect(opts.only).toBeNull();
    expect(opts.maxClose).toBeNull();
  });

  it('--apply flips apply on; a later --dry-run flips it back off', () => {
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    expect(parseArgs(['--apply']).apply).toBe(true);
    expect(parseArgs(['--apply', '--dry-run']).apply).toBe(false);
  });

  it('parses every flag, overriding JIRA_PROJECT_KEY with an explicit --project', () => {
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    const opts = parseArgs([
      '--project', 'FOO',
      '--limit', '10',
      '--config', '/tmp/c.json',
      '--hygiene-doc', '/tmp/h.md',
      '--commits-file', '/tmp/commits.tsv',
      '--jira-cli', '/tmp/dist/index.js',
      '--only', 'FOO-1, FOO-2,FOO-3',
      '--max-close', '5',
    ]);
    expect(opts.project).toBe('FOO');
    expect(opts.limit).toBe('10');
    expect(opts.config).toBe('/tmp/c.json');
    expect(opts.hygieneDoc).toBe('/tmp/h.md');
    expect(opts.commitsFile).toBe('/tmp/commits.tsv');
    expect(opts.jiraCli).toBe('/tmp/dist/index.js');
    expect([...opts.only]).toEqual(['FOO-1', 'FOO-2', 'FOO-3']);
    expect(opts.maxClose).toBe(5);
  });

  it('exits 1 on an unrecognized argument', () => {
    process.env.JIRA_PROJECT_KEY = 'HIMMEL';
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => {
      throw new Error('exit');
    });
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    expect(() => parseArgs(['--bogus'])).toThrow('exit');
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('unknown argument "--bogus"'));
    exitSpy.mockRestore();
    errSpy.mockRestore();
  });

  it('exits 1 when neither --project nor JIRA_PROJECT_KEY is set', () => {
    delete process.env.JIRA_PROJECT_KEY;
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => {
      throw new Error('exit');
    });
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    expect(() => parseArgs([])).toThrow('exit');
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('--project or JIRA_PROJECT_KEY is required'));
    exitSpy.mockRestore();
    errSpy.mockRestore();
  });
});

describe('loadConfig', () => {
  it('returns {} when the path does not exist', () => {
    expect(loadConfig('/nonexistent/reconcile-config.json')).toEqual({});
  });

  it('parses an existing config file', () => {
    withTmpDir((dir) => {
      const path = join(dir, 'reconcile-config.json');
      writeFileSync(path, JSON.stringify({ HIMMEL: { targetStatus: 'Done' } }));
      expect(loadConfig(path)).toEqual({ HIMMEL: { targetStatus: 'Done' } });
    });
  });
});

describe('loadHygieneKeys', () => {
  it('returns an empty set for a null path', () => {
    expect(loadHygieneKeys(null)).toEqual(new Set());
  });

  it('exits 1 when an explicitly-given path does not exist (does not silently treat it as un-swept)', () => {
    const exitSpy = vi.spyOn(process, 'exit').mockImplementation(() => {
      throw new Error('exit');
    });
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    expect(() => loadHygieneKeys('/nonexistent/hygiene.md')).toThrow('exit');
    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('/nonexistent/hygiene.md'));
    exitSpy.mockRestore();
    errSpy.mockRestore();
  });

  it('extracts ticket keys from every markdown table, including LEFT ALONE rows', () => {
    withTmpDir((dir) => {
      const path = join(dir, 'hygiene.md');
      writeFileSync(
        path,
        [
          '## CLOSED',
          '| HIMMEL-1 | closed as done |',
          '## LEFT ALONE',
          '| HIMMEL-2 | no action taken |',
          'not a table row mentioning HIMMEL-3',
        ].join('\n'),
      );
      expect(loadHygieneKeys(path)).toEqual(new Set(['HIMMEL-1', 'HIMMEL-2']));
    });
  });
});

describe('loadCommits', () => {
  it('parses a --commits-file (date\\tsubject, tab-separated)', () => {
    withTmpDir((dir) => {
      const path = join(dir, 'commits.tsv');
      writeFileSync(path, '2026-09-01\tfeat: [HIMMEL-1] one\n2026-09-02\tfix: [HIMMEL-2] two\n');
      const commits = loadCommits(path);
      expect(commits).toEqual([
        { sha: null, date: '2026-09-01', subject: 'feat: [HIMMEL-1] one', body: '' },
        { sha: null, date: '2026-09-02', subject: 'fix: [HIMMEL-2] two', body: '' },
      ]);
    });
  });

  it('falls back to `git log` on this repo when no --commits-file is given, warning on stderr', () => {
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const commits = loadCommits(null);
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('no --commits-file given'));
    expect(commits.length).toBeGreaterThan(0);
    expect(commits[0]).toHaveProperty('sha');
    expect(commits[0]).toHaveProperty('date');
    expect(commits[0]).toHaveProperty('subject');
    errSpy.mockRestore();
  });
});

// HIMMEL-3127: the /backlog-reconcile surface's operator-approval gate is
// `apply` on this injectable orchestration entrypoint — the only thing that
// decides whether the loop ever calls into jiraClient. A fixture backlog
// with a CLOSE-worthy commit proves the classifier still finds the
// candidate; the assertion that matters is zero writes when apply is false
// (approval declined).
describe('runReconciliation — operator-approval gate', () => {
  const backlog = [{ key: 'HIMMEL-1', issueType: 'Task', status: 'To Do' }];
  const commits = [{ sha: 'abc123', date: '2026-09-01', subject: 'feat: [HIMMEL-1] ship it', body: '' }];
  const baseOpts = {
    backlog,
    commits,
    hygieneKeys: new Set(),
    targetStatus: 'Done',
    only: null,
    loadCommentBodies: async () => [],
    loadDescription: async () => '',
  };

  it('DECLINED approval (apply:false) against a fixture backlog makes zero Jira writes', async () => {
    const jiraClient = { comment: vi.fn(), transition: vi.fn() };
    const result = await runReconciliation({ ...baseOpts, apply: false, maxClose: null, jiraClient });
    expect(result.counts.CLOSE).toBe(1);
    expect(jiraClient.comment).not.toHaveBeenCalled();
    expect(jiraClient.transition).not.toHaveBeenCalled();
  });

  it('APPROVED (apply:true, max-close headroom) comments and transitions the CLOSE candidate', async () => {
    const jiraClient = { comment: vi.fn(), transition: vi.fn() };
    const result = await runReconciliation({ ...baseOpts, apply: true, maxClose: 5, jiraClient });
    expect(jiraClient.comment).toHaveBeenCalledOnce();
    expect(jiraClient.transition).toHaveBeenCalledOnce();
    expect(result.closed).toBe(1);
  });
});
