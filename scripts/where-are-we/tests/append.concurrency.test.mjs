// scripts/where-are-we/tests/append.concurrency.test.mjs
//
// Cross-process concurrency test: N OS processes append to one ledger concurrently.
// Proves the mkdir-based advisory lock prevents torn/interleaved lines and data loss.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';
import { readRecords } from '../lib/ledger.mjs';

const N = 8;   // number of concurrent worker processes
const K = 25;  // records per worker

// Resolve the absolute path to lib/append.mjs and convert to a file:// URL
// so ESM import works on Windows (raw C:\... paths fail ESM import).
const __filename = fileURLToPath(import.meta.url);
const appendMjsUrl = pathToFileURL(join(__filename, '..', '..', 'lib', 'append.mjs')).href;

/**
 * Worker source: run as a plain .mjs file via node.
 * Receives APPEND_URL (file:// URL to append.mjs), LEDGER_PATH, WORKER_ID, K
 * as environment variables.
 *
 * Uses dynamic import() so the module URL can be a runtime value.
 */
function workerSource() {
  return `
const { appendRecords } = await import(process.env.APPEND_URL);
const ledgerPath = process.env.LEDGER_PATH;
const workerId = Number(process.env.WORKER_ID);
const k = Number(process.env.K);
const records = [];
for (let seq = 0; seq < k; seq++) {
  records.push({
    ts: new Date(Date.now() + seq).toISOString(),
    source: 'test',
    key: 'W' + workerId + '-' + seq,
    kind: 'ticket',
    w: workerId,
    seq,
  });
}
// Append with a generous timeout in case of heavy contention
const result = appendRecords(ledgerPath, records, { timeoutMs: 30000, backoffMs: 10 });
if (result.dropped > 0) {
  process.stderr.write('worker ' + workerId + ' dropped ' + result.dropped + ' records\\n');
  process.exit(1);
}
`;
}

test('concurrent append: N*K records, no torn lines, no loss', { timeout: 120000 }, async () => {
  const tmpDir = mkdtempSync(join(tmpdir(), 'waw-conc-'));
  const ledgerPath = join(tmpDir, 'ledger.jsonl');

  // Write the worker source to a temp file so we can pass it via stdin
  // (avoids shell escaping issues on Windows with --eval / -e).
  const workerFile = join(tmpDir, 'worker.mjs');
  writeFileSync(workerFile, workerSource(), 'utf8');

  // Spawn N workers concurrently
  const workerPromises = [];
  for (let i = 0; i < N; i++) {
    workerPromises.push(new Promise((resolve, reject) => {
      const child = spawn(
        process.execPath,
        [workerFile],
        {
          env: {
            ...process.env,
            APPEND_URL: appendMjsUrl,
            LEDGER_PATH: ledgerPath,
            WORKER_ID: String(i),
            K: String(K),
          },
          stdio: ['ignore', 'pipe', 'pipe'],
        }
      );

      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (d) => { stdout += d; });
      child.stderr.on('data', (d) => { stderr += d; });

      child.on('close', (code) => {
        resolve({ code, stdout, stderr, workerId: i });
      });
      child.on('error', (err) => {
        reject(err);
      });
    }));
  }

  const results = await Promise.all(workerPromises);

  // Assert every worker exited cleanly
  for (const { code, stderr, workerId } of results) {
    assert.equal(
      code,
      0,
      `worker ${workerId} exited with code ${code}; stderr: ${stderr.trim()}`
    );
  }

  // Read the ledger and verify integrity
  const recs = readRecords(ledgerPath);

  // 1. Total record count must be exactly N * K
  assert.equal(
    recs.length,
    N * K,
    `expected ${N * K} records, got ${recs.length}`
  );

  // 2. Every non-empty line must have parsed (readRecords throws on bad JSON)
  //    — already guaranteed by readRecords above; we re-verify the count.

  // 3. Exact multiset of (w, seq) pairs — nothing lost, nothing duplicated
  //    Build the expected set: {0..N-1} x {0..K-1}
  const expected = new Map();
  for (let w = 0; w < N; w++) {
    for (let seq = 0; seq < K; seq++) {
      expected.set(`${w}:${seq}`, 0);
    }
  }

  for (const r of recs) {
    const key = `${r.w}:${r.seq}`;
    assert.ok(
      expected.has(key),
      `unexpected record key=${r.key} w=${r.w} seq=${r.seq}`
    );
    expected.set(key, expected.get(key) + 1);
  }

  for (const [pair, count] of expected) {
    assert.equal(
      count,
      1,
      `pair (${pair}) appeared ${count} time(s), expected exactly 1`
    );
  }
});
