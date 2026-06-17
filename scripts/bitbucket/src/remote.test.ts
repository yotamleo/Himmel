import { describe, it, expect, afterEach } from 'vitest';
import { parseBitbucketRemote, parseRepoArg, repoRef } from './remote.js';

describe('parseBitbucketRemote', () => {
  it('parses https URLs', () => {
    expect(parseBitbucketRemote('https://bitbucket.org/myws/myrepo')).toEqual({
      workspace: 'myws',
      repoSlug: 'myrepo',
    });
  });

  it('parses https URLs with trailing .git', () => {
    expect(parseBitbucketRemote('https://bitbucket.org/myws/myrepo.git')).toEqual({
      workspace: 'myws',
      repoSlug: 'myrepo',
    });
  });

  it('parses https URLs with an embedded user', () => {
    expect(parseBitbucketRemote('https://user@bitbucket.org/myws/myrepo.git')).toEqual({
      workspace: 'myws',
      repoSlug: 'myrepo',
    });
  });

  it('parses ssh URLs', () => {
    expect(parseBitbucketRemote('git@bitbucket.org:myws/myrepo.git')).toEqual({
      workspace: 'myws',
      repoSlug: 'myrepo',
    });
  });

  it('is case-insensitive on the host', () => {
    expect(parseBitbucketRemote('https://BitBucket.org/myws/myrepo')).toEqual({
      workspace: 'myws',
      repoSlug: 'myrepo',
    });
  });

  it('returns null for non-bitbucket URLs', () => {
    expect(parseBitbucketRemote('https://github.com/owner/repo.git')).toBeNull();
    expect(parseBitbucketRemote('git@github.com:owner/repo.git')).toBeNull();
    expect(parseBitbucketRemote('not a url')).toBeNull();
  });
});

describe('parseRepoArg', () => {
  it('parses a bare <workspace>/<repo>', () => {
    expect(parseRepoArg('myws/myrepo')).toEqual({ workspace: 'myws', repoSlug: 'myrepo' });
  });

  it('trims surrounding whitespace', () => {
    expect(parseRepoArg('  myws/myrepo  ')).toEqual({ workspace: 'myws', repoSlug: 'myrepo' });
  });

  it('rejects `.`/`..` traversal segments', () => {
    expect(() => parseRepoArg('../etc')).toThrow(/must be <workspace>\/<repo_slug>/);
    expect(() => parseRepoArg('ws/..')).toThrow(/must be <workspace>\/<repo_slug>/);
  });

  it('rejects shapes with too few or too many segments', () => {
    expect(() => parseRepoArg('justone')).toThrow(/must be <workspace>\/<repo_slug>/);
    expect(() => parseRepoArg('a/b/c')).toThrow(/must be <workspace>\/<repo_slug>/);
  });
});

describe('repoRef', () => {
  const origWs = process.env.BITBUCKET_WORKSPACE;
  const origSlug = process.env.BITBUCKET_REPO_SLUG;
  afterEach(() => {
    if (origWs === undefined) delete process.env.BITBUCKET_WORKSPACE;
    else process.env.BITBUCKET_WORKSPACE = origWs;
    if (origSlug === undefined) delete process.env.BITBUCKET_REPO_SLUG;
    else process.env.BITBUCKET_REPO_SLUG = origSlug;
  });

  it('honors BITBUCKET_WORKSPACE + BITBUCKET_REPO_SLUG overrides (no git call)', () => {
    process.env.BITBUCKET_WORKSPACE = 'envws';
    process.env.BITBUCKET_REPO_SLUG = 'envrepo';
    expect(repoRef()).toEqual({ workspace: 'envws', repoSlug: 'envrepo' });
  });
});
