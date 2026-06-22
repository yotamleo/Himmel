// scripts/where-are-we/lib/append.mjs
import { mkdirSync, rmdirSync } from 'node:fs';
import { validateRecord } from './schema.mjs';
import { appendRecord } from './ledger.mjs';

/**
 * Acquire an advisory lock by creating a directory at `ledgerPath + '.lock'`.
 * Uses a synchronous spin-sleep (Atomics.wait) so the lock is never leaked
 * across an await boundary.
 *
 * @param {string} ledgerPath
 * @param {{ timeoutMs?: number, backoffMs?: number }} opts
 */
export function acquireLock(ledgerPath, opts = {}) {
  const { timeoutMs = 10000, backoffMs = 20 } = opts;
  const lockPath = ledgerPath + '.lock';
  const deadline = Date.now() + timeoutMs;
  while (true) {
    try {
      mkdirSync(lockPath);
      return; // success
    } catch (err) {
      if (err.code !== 'EEXIST') throw err; // non-lock error — surface immediately
      if (Date.now() >= deadline) {
        throw new Error('append: lock timeout for ' + ledgerPath);
      }
      // Synchronous sleep — must not be async to prevent lock leaks
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, backoffMs);
    }
  }
}

/**
 * Release the advisory lock by removing the lock directory.
 * Silently ignores ENOENT (already released).
 *
 * @param {string} ledgerPath
 */
export function releaseLock(ledgerPath) {
  try {
    rmdirSync(ledgerPath + '.lock');
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
}

/**
 * Validate each record, drop invalid ones, then append all valid records
 * under an advisory lock.
 *
 * @param {string} ledgerPath
 * @param {object[]} records
 * @param {object} opts  - forwarded to acquireLock (timeoutMs, backoffMs)
 * @returns {{ appended: number, dropped: number, dropReasons: Array<{index: number, error: string}> }}
 */
export function appendRecords(ledgerPath, records, opts = {}) {
  const valid = [];
  const dropReasons = [];
  for (let i = 0; i < records.length; i++) {
    const result = validateRecord(records[i]);
    if (result.ok) {
      valid.push(records[i]);
    } else {
      dropReasons.push({ index: i, error: result.error });
    }
  }
  acquireLock(ledgerPath, opts);
  try {
    for (const r of valid) {
      appendRecord(ledgerPath, r);
    }
  } finally {
    releaseLock(ledgerPath);
  }
  return { appended: valid.length, dropped: dropReasons.length, dropReasons };
}
