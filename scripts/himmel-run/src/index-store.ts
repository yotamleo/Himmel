import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import type { IndexEntry } from './types.js';

export function generateRunId(): string {
  return `${randomBytes(4).toString('hex')}-${Date.now().toString(36)}`;
}

export function writeEntry(indexDir: string, entry: IndexEntry): void {
  if (!existsSync(indexDir)) mkdirSync(indexDir, { recursive: true, mode: 0o700 });
  const file = join(indexDir, `${entry.runId}.json`);
  // Mode 0o600 is POSIX-only. Windows ignores the bits; isolation relies on
  // the per-user cache dir ACL inherited from paths.cacheRoot().
  writeFileSync(file, JSON.stringify(entry, null, 2), { mode: 0o600 });
}

export function readEntry(indexDir: string, runId: string): IndexEntry | null {
  const file = join(indexDir, `${runId}.json`);
  if (!existsSync(file)) return null;
  // B14: wrap JSON.parse so corrupt entries return null instead of crashing
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(file, 'utf8'));
  } catch (e) {
    process.stderr.write(`himmel-run: index entry ${runId} unreadable (${(e as Error).message}), skipping\n`);
    return null;
  }
  // I14: validate expected shape — all fields from RunResult + IndexEntry-only fields.
  // HIMMEL-101 §5: tightened to type-check exitCode/summary/bytesToClient/startedAt/finishedAt.
  // errOffsetStart/errOffsetEnd are intentionally NOT validated — they were added later
  // than the others and may be absent in legacy pre-HIMMEL-97 entries; tightening them
  // would break reads of older caches.
  if (
    typeof parsed !== 'object' ||
    parsed === null ||
    typeof (parsed as Record<string, unknown>).runId !== 'string' ||
    typeof (parsed as Record<string, unknown>).tag !== 'string' ||
    !Array.isArray((parsed as Record<string, unknown>).cmd) ||
    typeof (parsed as Record<string, unknown>).exitCode !== 'number' ||
    typeof (parsed as Record<string, unknown>).summary !== 'string' ||
    typeof (parsed as Record<string, unknown>).bytesToClient !== 'number' ||
    typeof (parsed as Record<string, unknown>).startedAt !== 'string' ||
    typeof (parsed as Record<string, unknown>).finishedAt !== 'string' ||
    typeof (parsed as Record<string, unknown>).logOffsetStart !== 'number' ||
    typeof (parsed as Record<string, unknown>).logOffsetEnd !== 'number'
  ) {
    process.stderr.write(`himmel-run: index entry ${runId} has unexpected shape, skipping\n`);
    return null;
  }
  return parsed as IndexEntry;
}

/** Returns run IDs sorted by file mtime (oldest first). */
export function listEntries(indexDir: string): string[] {
  if (!existsSync(indexDir)) return [];
  return readdirSync(indexDir)
    .filter((n) => n.endsWith('.json'))
    .map((n) => ({ id: n.replace(/\.json$/, ''), mtime: statSync(join(indexDir, n)).mtimeMs }))
    .sort((a, b) => a.mtime - b.mtime)
    .map((x) => x.id);
}
