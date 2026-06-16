import { describe, it, expect } from 'vitest';
import { cacheRoot, tagDir, indexDir, logPath, errPath, repoContextPath } from '../src/paths.js';

describe('paths', () => {
  it('cacheRoot returns himmel-cli under OS cache dir', () => {
    const root = cacheRoot();
    expect(root).toMatch(/himmel-cli$/);
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
