import { describe, it, expect, beforeEach } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { detectForge } from '../lib/forge/detect.mjs';

let repo;

function gitRepoWithOrigin(url) {
  const dir = mkdtempSync(join(tmpdir(), 'himmel-forge-detect-'));
  spawnSync('git', ['init', '-q'], { cwd: dir });
  if (url) spawnSync('git', ['remote', 'add', 'origin', url], { cwd: dir });
  return dir;
}

describe('detectForge — FORGE override', () => {
  it('FORGE=github returns github (even with a bitbucket origin)', () => {
    repo = gitRepoWithOrigin('git@bitbucket.org:ws/repo.git');
    expect(detectForge(repo, { FORGE: 'github' })).toBe('github');
  });

  it('FORGE=bitbucket returns bitbucket (even with a github origin)', () => {
    repo = gitRepoWithOrigin('https://github.com/o/r.git');
    expect(detectForge(repo, { FORGE: 'bitbucket' })).toBe('bitbucket');
  });
});

describe('detectForge — origin URL', () => {
  it('github https → github', () => {
    repo = gitRepoWithOrigin('https://github.com/yotamleo/himmel');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('github https .git → github', () => {
    repo = gitRepoWithOrigin('https://github.com/yotamleo/himmel.git');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('github ssh → github', () => {
    repo = gitRepoWithOrigin('git@github.com:yotamleo/himmel.git');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('bitbucket https → bitbucket', () => {
    repo = gitRepoWithOrigin('https://bitbucket.org/example-ws/repo.git');
    expect(detectForge(repo, {})).toBe('bitbucket');
  });

  it('bitbucket ssh → bitbucket', () => {
    repo = gitRepoWithOrigin('git@bitbucket.org:example-ws/repo.git');
    expect(detectForge(repo, {})).toBe('bitbucket');
  });

  it('uppercase host → matched case-insensitively', () => {
    repo = gitRepoWithOrigin('https://BitBucket.ORG/ws/repo.git');
    expect(detectForge(repo, {})).toBe('bitbucket');
  });
});

describe('detectForge — safe github default', () => {
  it('no origin → github', () => {
    repo = gitRepoWithOrigin(null);
    expect(detectForge(repo, {})).toBe('github');
  });

  it('unknown host → github', () => {
    repo = gitRepoWithOrigin('https://gitlab.com/o/r.git');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('non-git dir (git error) → github', () => {
    const dir = mkdtempSync(join(tmpdir(), 'himmel-forge-nogit-'));
    expect(detectForge(dir, {})).toBe('github');
  });
});
