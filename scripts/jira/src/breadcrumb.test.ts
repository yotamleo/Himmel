import { describe, it, expect, afterEach } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  sanitizeBreadcrumbToken,
  deriveRepoKey,
  breadcrumbDir,
  breadcrumbFileName,
  writeJiraBreadcrumb,
} from './breadcrumb.js';

describe('sanitizeBreadcrumbToken', () => {
  it('keeps safe filename chars', () => {
    expect(sanitizeBreadcrumbToken('himmel-private_1.0')).toBe('himmel-private_1.0');
  });
  it('replaces slashes (branch names) with dashes', () => {
    expect(sanitizeBreadcrumbToken('feat/jira-nudge')).toBe('feat-jira-nudge');
  });
  it('replaces other unsafe chars', () => {
    expect(sanitizeBreadcrumbToken('a b@c:d')).toBe('a-b-c-d');
  });
});

describe('deriveRepoKey', () => {
  it('handles https remotes', () => {
    expect(deriveRepoKey('https://github.com/yotamleo/himmel-private.git')).toBe('himmel-private');
  });
  it('handles ssh remotes', () => {
    expect(deriveRepoKey('git@github.com:yotamleo/himmel-private.git')).toBe('himmel-private');
  });
  it('handles a remote with no .git suffix', () => {
    expect(deriveRepoKey('https://github.com/yotamleo/himmel-private')).toBe('himmel-private');
  });
});

describe('breadcrumbFileName', () => {
  it('joins sanitized repo key and branch', () => {
    expect(breadcrumbFileName('himmel-private', 'feat/x')).toBe('himmel-private__feat-x.log');
  });
});

describe('writeJiraBreadcrumb (integration)', () => {
  const tmps: string[] = [];
  const origCwd = process.cwd();
  const origHome = process.env.HOME;
  const origUserprofile = process.env.USERPROFILE;

  afterEach(() => {
    process.chdir(origCwd);
    if (origHome === undefined) delete process.env.HOME;
    else process.env.HOME = origHome;
    if (origUserprofile === undefined) delete process.env.USERPROFILE;
    else process.env.USERPROFILE = origUserprofile;
    for (const d of tmps.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  it('appends an <epoch>\\t<ticket> line at the repo+branch path', () => {
    const home = mkdtempSync(join(tmpdir(), 'bc-home-'));
    const repo = mkdtempSync(join(tmpdir(), 'bc-repo-'));
    tmps.push(home, repo);
    // os.homedir() reads HOME (POSIX) / USERPROFILE (Windows); set both.
    process.env.HOME = home;
    process.env.USERPROFILE = home;

    const git = (...args: string[]) =>
      execFileSync('git', args, { cwd: repo, stdio: 'pipe' });
    git('init', '-q');
    git('remote', 'add', 'origin', 'https://github.com/acme/demo-repo.git');
    git('checkout', '-q', '-b', 'feat/thing');
    process.chdir(repo);

    writeJiraBreadcrumb('HIMMEL-618');

    const file = join(breadcrumbDir(home), 'demo-repo__feat-thing.log');
    const content = readFileSync(file, 'utf8');
    expect(content).toMatch(/^\d+\tHIMMEL-618\n$/);
  });

  it('is a no-op for an empty ticket', () => {
    const home = mkdtempSync(join(tmpdir(), 'bc-home-'));
    tmps.push(home);
    process.env.HOME = home;
    process.env.USERPROFILE = home;
    // Must not throw even with no git repo / empty ticket.
    expect(() => writeJiraBreadcrumb('')).not.toThrow();
  });
});
