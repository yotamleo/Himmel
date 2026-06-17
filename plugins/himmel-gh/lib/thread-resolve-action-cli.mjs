#!/usr/bin/env node
// thread-resolve-action-cli.mjs — forge-routed PR review-thread resolve (spec
// §5.3). Expands a 6-char prefix to its thread id, then resolves via the active
// forge: GitHub uses the GraphQL resolveReviewThread mutation; Bitbucket (no
// GraphQL) routes through the `bitbucket pr resolve` CLI verb. Prints a
// `resolved: ok` summary line the runner's --summary-regex captures.
//
// (Distinct from thread-resolve-cli.mjs, which only expands prefix → id and is
// kept for back-compat.)

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { expandPrefix } from './thread-prefix.mjs';
import { detectForge } from './forge/detect.mjs';
import { resolveThread } from './forge/bitbucket-threads.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const QUERY_FILE = join(__dirname, '..', 'graphql', 'resolve-thread.gql');

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

function execGhResolve(threadId) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    // -f (raw-field) for threadId so a value is never interpreted as `@file` or
    // type-coerced; -F only for the query, where `@file` must expand to the .gql.
    const proc = spawn('gh', ['api', 'graphql', '-f', `threadId=${threadId}`, '-F', `query=@${QUERY_FILE}`], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
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
const { owner, repo, number, prefix } = args;

if (!owner || !repo || !number || !prefix) {
  process.stderr.write(
    'usage: thread-resolve-action-cli.mjs --owner O --repo R --number N --prefix P\n',
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
    const out = await resolveThread({ number: Number(number), id: expanded.id });
    if (out.trim()) process.stdout.write(`${out.trim()}\n`);
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
  }
} else {
  const res = await execGhResolve(expanded.id);
  if (res.exitCode !== 0) {
    process.stderr.write(res.stderr || `gh api graphql resolve failed (exit ${res.exitCode})\n`);
    process.exit(res.exitCode);
  }
  if (res.stdout.trim()) process.stdout.write(`${res.stdout.trim()}\n`);
}

process.stdout.write('resolved: ok\n');
