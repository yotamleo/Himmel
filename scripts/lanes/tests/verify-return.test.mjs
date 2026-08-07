// Tests for scripts/lanes/verify-return.mjs (HIMMEL-1621, Phase 1a).
// Hermetic: git/gh are injected via the exec seam — nothing touches the real
// repo, network, or ledger. Run: node --test "scripts/lanes/tests/**/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { verifyReturn, deriveTicket, ledgerRow, ledgerPath } from '../verify-return.mjs';

// Build an exec stub from per-command canned outputs. A missing key throws,
// mimicking a real execFileSync failure — used by the cannot-evaluate cases.
function stubExec(responses) {
  return (cmd, args) => {
    const key = `${cmd} ${args.join(' ')}`;
    for (const [pattern, value] of Object.entries(responses)) {
      if (key.includes(pattern)) {
        if (value instanceof Error) throw value;
        return value;
      }
    }
    throw new Error(`unexpected exec: ${key}`);
  };
}

const HEALTHY = {
  'for-each-ref': 'origin/feat/himmel-1-x\n',
  'rev-list': '3\n',
  'pr list': '[{"number":42}]\n',
  'log -1': 'feat: [HIMMEL-1] thing\n\nPlatforms tested: windows\n',
};

test('all four checks pass -> PASS with derived ticket', () => {
  const r = verifyReturn('feat/himmel-1-x', { exec: stubExec(HEALTHY) });
  assert.equal(r.verdict, 'PASS');
  assert.equal(r.failedCheck, null);
  assert.equal(r.line, 'PASS HIMMEL-1 feat/himmel-1-x');
});

test('missing upstream fails first: no-upstream', () => {
  const r = verifyReturn('feat/himmel-1-x', { exec: stubExec({ ...HEALTHY, 'for-each-ref': '\n' }) });
  assert.equal(r.line, 'FAILED HIMMEL-1 feat/himmel-1-x no-upstream');
});

test('zero commits over origin/main fails: empty-diff (the silent-death class)', () => {
  const r = verifyReturn('feat/himmel-1-x', { exec: stubExec({ ...HEALTHY, 'rev-list': '0\n' }) });
  assert.equal(r.line, 'FAILED HIMMEL-1 feat/himmel-1-x empty-diff');
});

test('no PR fails: no-pr', () => {
  const r = verifyReturn('feat/himmel-1-x', { exec: stubExec({ ...HEALTHY, 'pr list': '[]\n' }) });
  assert.equal(r.line, 'FAILED HIMMEL-1 feat/himmel-1-x no-pr');
});

test('head commit without a test receipt fails: no-test-receipt', () => {
  const r = verifyReturn('feat/himmel-1-x', {
    exec: stubExec({ ...HEALTHY, 'log -1': 'feat: [HIMMEL-1] looks right to me\n' }),
  });
  assert.equal(r.line, 'FAILED HIMMEL-1 feat/himmel-1-x no-test-receipt');
});

test('a Tests: trailer also satisfies the receipt check', () => {
  const r = verifyReturn('feat/himmel-1-x', {
    exec: stubExec({ ...HEALTHY, 'log -1': 'fix: [HIMMEL-1] y\n\nTests: 12/12 pass\n' }),
  });
  assert.equal(r.verdict, 'PASS');
});

test('first failure wins: upstream missing masks the later empty diff', () => {
  const r = verifyReturn('feat/himmel-1-x', {
    exec: stubExec({ ...HEALTHY, 'for-each-ref': '', 'rev-list': '0\n' }),
  });
  assert.equal(r.failedCheck, 'no-upstream');
});

test('a gh error THROWS (exit-2 class) — it is never read as no-pr', () => {
  assert.throws(
    () => verifyReturn('feat/himmel-1-x', {
      exec: stubExec({ ...HEALTHY, 'pr list': new Error('network unreachable') }),
    }),
    /network unreachable/,
  );
});

test('non-JSON gh output throws instead of producing a verdict', () => {
  assert.throws(() => verifyReturn('feat/himmel-1-x', {
    exec: stubExec({ ...HEALTHY, 'pr list': 'gh: not logged in\n' }),
  }));
});

test('non-numeric rev-list output throws instead of producing a verdict', () => {
  assert.throws(() => verifyReturn('feat/himmel-1-x', {
    exec: stubExec({ ...HEALTHY, 'rev-list': 'fatal: bad revision\n' }),
  }), /non-count/);
});

test('deriveTicket: explicit wins, branch token uppercased, dash fallback', () => {
  assert.equal(deriveTicket('glm/himmel-1614-x', ''), 'HIMMEL-1614');
  assert.equal(deriveTicket('glm/himmel-1614-x', 'HIMMEL-9'), 'HIMMEL-9');
  assert.equal(deriveTicket('scratch/no-ticket-here-x', '').startsWith('HIMMEL'), false);
  assert.equal(deriveTicket('scratch', ''), '-');
});

test('ledgerRow: PASS -> exit 0/complete; FAILED -> exit 1/error; HIMMEL-921 grammar', () => {
  const now = new Date('2026-08-07T03:04:05Z');
  const pass = JSON.parse(ledgerRow({ verdict: 'PASS', line: 'PASS T-1 b' }, { now, pid: 7 }));
  assert.deepEqual(pass, {
    v: 1, ev: 'end', flow: 'verify-return', run_id: 'verify-return-20260807T0304-7',
    ended_at: '2026-08-07T03:04:05Z', exit_code: 0, outcome: 'complete',
    items_processed: null, note: 'PASS T-1 b',
  });
  const fail = JSON.parse(ledgerRow({ verdict: 'FAILED', line: 'FAILED T-1 b no-pr' }, { now, pid: 7 }));
  assert.equal(fail.exit_code, 1);
  assert.equal(fail.outcome, 'error');
});

test('ledgerPath: env override wins over the HOME default', () => {
  assert.equal(ledgerPath({ HIMMEL_FLOW_RUNS_LEDGER: '/x/l.jsonl' }), '/x/l.jsonl');
  assert.match(ledgerPath({ HOME: '/home/u' }).replace(/\\/g, '/'), /\/home\/u\/.himmel\/flow-runs.jsonl$/);
});
