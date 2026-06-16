import { openSync, readSync, closeSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { cacheRoot, tagDir, logPath, errPath, indexDir } from './paths.js';
import { readEntry } from './index-store.js';

function readRange(file: string, start: number, end: number): string {
  if (!existsSync(file) || end <= start) return '';
  const fd = openSync(file, 'r');
  try {
    const len = end - start;
    const buf = Buffer.alloc(len);
    readSync(fd, buf, 0, len, start);
    return buf.toString('utf8');
  } finally {
    closeSync(fd);
  }
}

export async function inspect(tag: string, runId: string, rootOverride?: string): Promise<string> {
  // B10: guard against path traversal via tag
  if (!tag || /[/\\]|^\.\.?$/.test(tag)) {
    throw new Error(`himmel-run: invalid tag "${tag}" (no path separators or '..' allowed)`);
  }

  const root = rootOverride ?? cacheRoot();
  const tDir = rootOverride ? join(root, tag) : tagDir(tag);
  const idx = rootOverride ? join(tDir, 'index') : indexDir(tag);
  const normal = rootOverride ? join(tDir, 'normal.log') : logPath(tag);
  const err = rootOverride ? join(tDir, 'error.log') : errPath(tag);

  const entry = readEntry(idx, runId);
  if (!entry) return `himmel-run: no entry for run=${runId}\n`;

  const out = readRange(normal, entry.logOffsetStart, entry.logOffsetEnd);
  const errOut = readRange(err, entry.errOffsetStart, entry.errOffsetEnd);
  return [
    `run=${runId} tag=${tag} exit=${entry.exitCode}`,
    `cmd: ${entry.cmd.join(' ')}`,
    `started: ${entry.startedAt}  finished: ${entry.finishedAt}`,
    '--- stdout ---',
    out,
    '--- stderr ---',
    errOut,
  ].join('\n');
}
