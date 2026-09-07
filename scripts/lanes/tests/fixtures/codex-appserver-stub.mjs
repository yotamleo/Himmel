// scripts/lanes/tests/fixtures/codex-appserver-stub.mjs — HIMMEL-1678
// Stub `codex app-server` for codex-bank-probe tests: newline-delimited
// JSON-RPC over stdio (the framing the probe sends; the probe's reader also
// tolerates Content-Length, but one framing is enough to exercise the wire).
// Deliberately NEVER exits on its own — the probe MUST kill it; that kill is
// the non-negotiable behavior under test.
//
// Env:
//   STUB_PID_FILE=<path>  write own pid at startup (so the test can assert
//                         the process is gone after the probe exits)
//   STUB_SILENT=1         accept requests but never answer (timeout path)
import { writeFileSync } from 'node:fs';

if (process.env.STUB_PID_FILE) writeFileSync(process.env.STUB_PID_FILE, String(process.pid));
const silent = process.env.STUB_SILENT === '1';

// Shaped after the LIVE `account/rateLimits/read` result (captured 2026-08-17):
// two limitIds whose weekly windows reset DAYS apart, planType nested inside
// each bucket, and null slots the normalizer must skip.
const now = Math.floor(Date.now() / 1000);
const codexBucket = {
  limitId: 'codex',
  limitName: null,
  primary: { usedPercent: 20, windowDurationMins: 10080, resetsAt: now + 86400 },
  secondary: null,
  credits: { hasCredits: false, unlimited: false, balance: '0' },
  planType: 'prolite',
};
const rateLimits = {
  rateLimits: codexBucket,
  rateLimitsByLimitId: {
    codex: codexBucket,
    codex_bengalfox: {
      limitId: 'codex_bengalfox',
      limitName: 'GPT-5.3-Codex-Spark',
      primary: { usedPercent: 0, windowDurationMins: 10080, resetsAt: now + 5 * 86400 },
      secondary: null,
      credits: null,
      planType: 'prolite',
    },
  },
};

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  input += chunk;
  let nl;
  while ((nl = input.indexOf('\n')) !== -1) {
    const line = input.slice(0, nl).trim();
    input = input.slice(nl + 1);
    if (!line.startsWith('{')) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (silent || !('id' in msg)) continue; // notifications (e.g. `initialized`) are ignored
    if (msg.method === 'initialize') reply({ jsonrpc: '2.0', id: msg.id, result: { capabilities: {} } });
    else if (msg.method === 'account/rateLimits/read') reply({ jsonrpc: '2.0', id: msg.id, result: rateLimits });
  }
});

// A non-JSON preamble line: real servers print one, and skipping it used to
// spin the probe's reader forever (HIMMEL-1678). Emitting it here keeps that
// regression covered end-to-end, not just in the parser unit test.
if (!silent) process.stdout.write('codex app-server (stub) ready\n');

function reply(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}
