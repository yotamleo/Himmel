import { describe, it, expect, beforeEach, vi } from 'vitest';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { listThreads, replyThread, resolveThread } from '../lib/forge/bitbucket-threads.mjs';

// Drive the backend at a node stub passed as a `cli` argv array. Passing the
// array directly (vs the BITBUCKET_CLI env string) sidesteps the space-split
// that forces the integration tests to skip on Windows — so these run anywhere.
let workDir;
let stub;

function writeStub(body) {
  stub = join(workDir, 'bb-stub.mjs');
  writeFileSync(stub, body);
}

function cli() {
  return [process.execPath, stub];
}

beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), 'himmel-gh-bb-threads-'));
});

describe('bitbucket-threads backend', () => {
  it('listThreads adapts flat ReviewThread[] into GraphQL-shaped nodes', async () => {
    writeStub(
      `process.stdout.write(JSON.stringify({ threads: [
        { id: 10, path: 'src/x.ts', line: 42, isResolved: false, author: 'rev', body: 'fix this' },
        { id: 20, path: 'src/y.ts', line: 7, isResolved: true, author: 'acc-1', body: 'done' }
      ], truncated: false, pages: 1 })); process.exit(0);`,
    );
    const nodes = await listThreads({ number: 5, cli: cli() });
    expect(nodes).toEqual([
      {
        id: '10',
        isResolved: false,
        path: 'src/x.ts',
        line: 42,
        comments: { nodes: [{ author: { login: 'rev' }, bodyText: 'fix this' }] },
      },
      {
        id: '20',
        isResolved: true,
        path: 'src/y.ts',
        line: 7,
        comments: { nodes: [{ author: { login: 'acc-1' }, bodyText: 'done' }] },
      },
    ]);
    // Cross-language contract: id MUST be a string — thread-cache hashId() feeds
    // it to createHash().update(), which rejects a bare number.
    expect(nodes.every((n) => typeof n.id === 'string')).toBe(true);
  });

  it('listThreads passes `pr comments <number>` to the CLI', async () => {
    writeStub(
      `const a = process.argv.slice(2);
       if (a[0] === 'pr' && a[1] === 'comments' && a[2] === '5') { process.stdout.write('{"threads":[],"truncated":false,"pages":1}'); process.exit(0); }
       process.stderr.write('bad args: ' + a.join(' ')); process.exit(9);`,
    );
    const nodes = await listThreads({ number: 5, cli: cli() });
    expect(nodes).toEqual([]);
  });

  it('listThreads warns on a truncated payload but still returns the nodes (HIMMEL-344)', async () => {
    writeStub(
      `process.stdout.write(JSON.stringify({ threads: [
        { id: 10, path: 'a', line: 1, isResolved: false, author: 'rev', body: 'x' }
      ], truncated: true, pages: 21 })); process.exit(0);`,
    );
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const nodes = await listThreads({ number: 7, cli: cli() });
    expect(nodes).toHaveLength(1);
    expect(nodes[0].id).toBe('10');
    // The truncation signal must reach the caller as a stderr warning naming the
    // PR number and page count — not be silently dropped.
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('#7'));
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('truncated at 21 pages'));
    errSpy.mockRestore();
  });

  it('listThreads truncation warning degrades to "?" when pages is absent', async () => {
    // Defensive: a truncated payload missing `pages` must not print "undefined".
    writeStub(
      `process.stdout.write(JSON.stringify({ threads: [], truncated: true })); process.exit(0);`,
    );
    const errSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const nodes = await listThreads({ number: 7, cli: cli() });
    expect(nodes).toEqual([]);
    expect(errSpy).toHaveBeenCalledWith(expect.stringContaining('truncated at ? pages'));
    expect(errSpy).not.toHaveBeenCalledWith(expect.stringContaining('undefined'));
    errSpy.mockRestore();
  });

  it('listThreads throws on a non-zero CLI exit (no silent empty list)', async () => {
    writeStub(`process.stderr.write('boom\\n'); process.exit(1);`);
    await expect(listThreads({ number: 5, cli: cli() })).rejects.toThrow(/boom/);
  });

  it('listThreads throws on unparseable output', async () => {
    writeStub(`process.stdout.write('nope'); process.exit(0);`);
    await expect(listThreads({ number: 5, cli: cli() })).rejects.toThrow(/parse error/);
  });

  it('listThreads throws on a valid-JSON payload missing the threads array', async () => {
    // The pre-HIMMEL-344 bare-array shape must now be rejected, not silently
    // mishandled — the contract is { threads: [...] }.
    writeStub(`process.stdout.write('[]'); process.exit(0);`);
    await expect(listThreads({ number: 5, cli: cli() })).rejects.toThrow(/expected \{ threads/);
  });

  it('replyThread invokes `pr reply <number> <id> --body <body>`', async () => {
    writeStub(
      `const a = process.argv.slice(2);
       if (a[0]==='pr'&&a[1]==='reply'&&a[2]==='5'&&a[3]==='10'&&a[4]==='--body'&&a[5]==='hi there') {
         process.stdout.write('{"id":99}'); process.exit(0);
       }
       process.stderr.write('bad args: ' + a.join('|')); process.exit(9);`,
    );
    const out = await replyThread({ number: 5, id: '10', body: 'hi there', cli: cli() });
    expect(out).toContain('99');
  });

  it('resolveThread invokes `pr resolve <number> <id>` and throws on failure', async () => {
    writeStub(
      `const a = process.argv.slice(2);
       if (a[0]==='pr'&&a[1]==='resolve'&&a[2]==='5'&&a[3]==='10') { process.stdout.write('{"resolved":true}'); process.exit(0); }
       process.stderr.write('bad'); process.exit(9);`,
    );
    const out = await resolveThread({ number: 5, id: '10', cli: cli() });
    expect(out).toContain('resolved');

    writeStub(`process.stderr.write('comment gone\\n'); process.exit(1);`);
    await expect(resolveThread({ number: 5, id: '10', cli: cli() })).rejects.toThrow(/comment gone/);
  });
});
