#!/usr/bin/env node
// thread-reply-cli.mjs — forge-routed PR review-thread reply (spec §5.3).
// Expands a 6-char prefix to its thread id, then posts the reply via the active
// forge: GitHub uses the GraphQL reply mutation; Bitbucket (no GraphQL) routes
// through the `bitbucket pr reply` CLI verb. Prints a `reply: ok` summary line
// the runner's --summary-regex captures, regardless of forge.

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { expandPrefix } from './thread-prefix.mjs';
import { detectForge } from './forge/detect.mjs';
import { replyThread } from './forge/bitbucket-threads.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const QUERY_FILE = join(__dirname, '..', 'graphql', 'reply-thread.gql');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      out[a.slice(2)] = next;
      i++;
    } else {
      out[a.slice(2)] = true;
    }
  }
  return out;
}

function execGhReply(threadId, body) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    const proc = spawn(
      'gh',
      // -f (raw-field), NOT -F (typed --field): -F treats a leading `@` in the
      // value as "read this file" (local file inclusion) and coerces
      // true/false/null/numbers. threadId + a user-supplied body must be sent as
      // literal strings. Only the query keeps -F so `@file` expands to the .gql.
      ['api', 'graphql', '-f', `threadId=${threadId}`, '-f', `body=${body}`, '-F', `query=@${QUERY_FILE}`],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
    proc.stdout.on('data', (d) => (stdout += d.toString()));
    proc.stderr.on('data', (d) => (stderr += d.toString()));
    proc.on('error', (err) => {
      const code = err.code === 'ENOENT' ? 127 : 1;
      resolve({ stdout, stderr: `${stderr}${err.message}\n`, exitCode: code });
    });
    proc.on('close', (code, signal) => {
      const exitCode = code ?? (signal ? 129 : 1);
      const finalStderr = signal ? `${stderr}gh killed by signal ${signal}\n` : stderr;
      resolve({ stdout, stderr: finalStderr, exitCode });
    });
  });
}

const args = parseArgs(process.argv.slice(2));
const { owner, repo, number, prefix, body } = args;

if (!owner || !repo || !number || !prefix || body === undefined || body === true) {
  process.stderr.write(
    'usage: thread-reply-cli.mjs --owner O --repo R --number N --prefix P --body "<text>"\n',
  );
  process.exit(2);
}

const expanded = expandPrefix({ owner, repo, number, prefix });
if (!expanded.ok) {
  process.stderr.write(`${expanded.message}\n`);
  process.exit(1);
}

if (detectForge() === 'bitbucket') {
  try {
    const out = await replyThread({ number: Number(number), id: expanded.id, body });
    if (out.trim()) process.stdout.write(`${out.trim()}\n`);
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
  }
} else {
  const res = await execGhReply(expanded.id, body);
  if (res.exitCode !== 0) {
    process.stderr.write(res.stderr || `gh api graphql reply failed (exit ${res.exitCode})\n`);
    process.exit(res.exitCode);
  }
  if (res.stdout.trim()) process.stdout.write(`${res.stdout.trim()}\n`);
}

process.stdout.write('reply: ok\n');
