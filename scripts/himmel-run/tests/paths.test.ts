import { describe, it, expect } from 'vitest';
import { isAbsolute } from 'node:path';
import { platform } from 'node:os';
import { cacheRoot, tagDir, indexDir, logPath, errPath, repoContextPath } from '../src/paths.js';

describe('paths', () => {
  it('cacheRoot returns himmel-cli under OS cache dir', () => {
    const root = cacheRoot();
    expect(root).toMatch(/himmel-cli$/);
  });

  it('cacheRoot is absolute and (win32) has the Cache suffix stripped', () => {
    const root = cacheRoot();
    expect(isAbsolute(root)).toBe(true);
    if (platform() === 'win32') {
      // env-paths appends \Cache to the app dir on Windows; paths.ts strips it
      // via dirname() so the root ends in \himmel-cli, NOT \himmel-cli\Cache.
      // Positively pin the stripped layout — guards against an env-paths layout
      // change (the regression surface of the v3->v4 bump, HIMMEL-547).
      expect(root).toMatch(/[\\/]himmel-cli$/);
    }
  });

  it('tagDir nests <root>/<tag>', () => {
    expect(tagDir('jira')).toMatch(/himmel-cli[\\/]jira$/);
  });

  it('logPath returns <tag>/normal.log', () => {
    expect(logPath('jira')).toMatch(/jira[\\/]normal\.log$/);
  });

  it('errPath returns <tag>/error.log', () => {
    expect(errPath('jira')).toMatch(/jira[\\/]error\.log$/);
  });

  it('indexDir returns <tag>/index', () => {
    expect(indexDir('jira')).toMatch(/jira[\\/]index$/);
  });

  it('repoContextPath returns <tag>/repo-context.json', () => {
    expect(repoContextPath('gh')).toMatch(/gh[\\/]repo-context\.json$/);
  });
});
