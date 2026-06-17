import { describe, it, expect } from 'vitest';
import { bitbucketCli } from '../lib/forge/bitbucket-cli.mjs';

// HIMMEL-345: BITBUCKET_CLI accepts a JSON-array form parsed as exact argv (no
// space-split), so a path containing a space — e.g. Windows'
// C:\Program Files\nodejs\node.exe in process.execPath — survives intact. The
// legacy space-split string form stays for back-compat.
describe('bitbucketCli override parsing', () => {
  it('parses a JSON-array BITBUCKET_CLI as exact argv (preserves spaced paths)', () => {
    const env = {
      BITBUCKET_CLI: JSON.stringify(['C:\\Program Files\\nodejs\\node.exe', 'C:\\a b\\stub.mjs']),
    };
    expect(bitbucketCli(env)).toEqual([
      'C:\\Program Files\\nodejs\\node.exe',
      'C:\\a b\\stub.mjs',
    ]);
  });

  it('space-splits a plain-string BITBUCKET_CLI (legacy form)', () => {
    expect(bitbucketCli({ BITBUCKET_CLI: 'node /path/index.js' })).toEqual([
      'node',
      '/path/index.js',
    ]);
  });

  it('falls back to space-split when a [-leading value is not valid JSON', () => {
    // Not parseable as JSON → treated as a (degenerate) space-split string,
    // never throws.
    expect(bitbucketCli({ BITBUCKET_CLI: '[not json' })).toEqual(['[not', 'json']);
  });

  it('ignores a JSON array that is empty or has non-string entries', () => {
    expect(bitbucketCli({ BITBUCKET_CLI: '[]' })).toEqual(['[]']);
    expect(bitbucketCli({ BITBUCKET_CLI: '[1,2]' })).toEqual(['[1,2]']);
  });
});
