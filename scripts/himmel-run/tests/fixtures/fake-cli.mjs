#!/usr/bin/env node
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const [mode] = process.argv.slice(2);

if (mode === 'ok') {
  process.stdout.write('hello\n');
  process.exit(0);
}
if (mode === 'json') {
  process.stdout.write(JSON.stringify({ title: 'PR-42', state: 'open' }) + '\n');
  process.exit(0);
}
if (mode === 'fail') {
  process.stderr.write('boom\n');
  process.exit(1);
}
if (mode === 'retry') {
  // File-based counter so state survives across separate child processes.
  // RETRY_STATE_FILE env var must point to a writable file path.
  const stateFile = process.env.RETRY_STATE_FILE;
  if (!stateFile) {
    process.stderr.write('RETRY_STATE_FILE not set\n');
    process.exit(2);
  }
  let count = 0;
  if (existsSync(stateFile)) {
    try { count = Number(readFileSync(stateFile, 'utf8').trim()) || 0; } catch { count = 0; }
  }
  writeFileSync(stateFile, String(count + 1));
  if (count < 1) {
    process.stderr.write('flaky\n');
    process.exit(1);
  }
  process.stdout.write('recovered\n');
  process.exit(0);
}

if (mode === 'recovery-trigger') {
  // First call: write a marker indicating recovery should run; exit with stderr match
  const marker = process.env.RECOVERY_MARKER;
  if (!marker) { process.stderr.write('missing RECOVERY_MARKER\n'); process.exit(2); }
  const fs = await import('node:fs');
  if (!fs.existsSync(marker)) {
    process.stderr.write('field foo is required\n');
    process.exit(1);
  }
  process.stdout.write('post-recovery-ok\n');
  process.exit(0);
}
if (mode === 'recovery-touch') {
  const marker = process.env.RECOVERY_MARKER;
  if (!marker) { process.stderr.write('missing RECOVERY_MARKER\n'); process.exit(2); }
  const fs = await import('node:fs');
  fs.writeFileSync(marker, 'touched');
  process.exit(0);
}

if (mode === 'oversized-summary') {
  // Emit a single 500-char line on stdout. The runner picks this up as the
  // summary (last-line tier), which then gets sliced to 200 chars before emit.
  process.stdout.write('z'.repeat(500) + '\n');
  process.exit(0);
}

if (mode === 'sleep-forever') {
  // Block on a 30s timer; expected to be killed by the test harness via SIGKILL.
  process.stdout.write('starting\n');
  setTimeout(() => process.exit(0), 30_000);
}

if (mode === 'self-sigkill') {
  // Self-SIGKILL on POSIX. process.kill(pid, 9) sends signal 9 directly.
  process.stdout.write('about to die\n');
  // Brief tick so the message flushes; then deliver the signal.
  setImmediate(() => {
    try { process.kill(process.pid, 'SIGKILL'); } catch {}
  });
  // Fall through to a long block in case kill is delayed (shouldn't happen).
  setTimeout(() => process.exit(99), 5000);
}

process.stderr.write(`unknown mode: ${mode}\n`);
process.exit(2);
