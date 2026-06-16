import { appendFileSync, chmodSync, existsSync, mkdirSync, openSync, renameSync, statSync, closeSync } from 'node:fs';
import { dirname } from 'node:path';

export const ROTATION_BYTES_DEFAULT = 10 * 1024 * 1024; // 10 MB
// 4000 bytes keeps each line well under 4096 to reduce (but not eliminate)
// interleaving risk on concurrent POSIX appends to regular files. POSIX's
// PIPE_BUF atomicity guarantee covers pipes/FIFOs only, not regular files.
export const MAX_LINE_BYTES = 4000;

function ensureDir(file: string): void {
  const dir = dirname(file);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
}

function ensureFile(file: string): void {
  if (existsSync(file)) return;
  ensureDir(file);
  const fd = openSync(file, 'a');
  closeSync(fd);
  if (process.platform !== 'win32') chmodSync(file, 0o600);
}

export function appendLog(file: string, chunk: string): number {
  ensureFile(file);
  let payload = chunk;
  const buf = Buffer.from(payload, 'utf8');
  if (buf.length > MAX_LINE_BYTES) {
    // Cut at byte boundary, ensure valid UTF-8 by re-decoding with replacement,
    // then re-encode. Append a marker so truncation is visible.
    const truncated = buf.subarray(0, MAX_LINE_BYTES).toString('utf8');
    payload = truncated + '…\n';
  }
  appendFileSync(file, payload);
  return statSync(file).size;
}

// rotateIfLarge is called under a per-tag lock acquired in run.ts (see lock.ts).
// Do not call standalone in parallel writers — the existsSync/statSync/renameSync
// sequence is not internally atomic.
export function rotateIfLarge(file: string, threshold = ROTATION_BYTES_DEFAULT): boolean {
  if (!existsSync(file)) return false;
  const size = statSync(file).size;
  if (size < threshold) return false;
  const ts = Date.now();
  const target = `${file}.${ts}`;
  try {
    renameSync(file, target);
    return true;
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    if (err.code === 'EBUSY' || err.code === 'EPERM') return false;
    throw e;
  }
}
