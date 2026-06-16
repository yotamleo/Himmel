#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { readCache, writeCache } from './repo-context.mjs';
import { buildErrorStderr } from './init-flow.mjs';

function execGhRepoView() {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    const proc = spawn('gh', ['repo', 'view', '--json', 'owner,name'], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    proc.stdout.on('data', (d) => (stdout += d.toString()));
    proc.stderr.on('data', (d) => (stderr += d.toString()));
    proc.on('error', (err) => {
      const code = err.code === 'ENOENT' ? 127 : 1;
      resolve({ stdout, stderr: buildErrorStderr(stderr, err), exitCode: code });
    });
    proc.on('close', (code, signal) =>
      resolve({
        stdout,
        stderr: signal ? `${stderr}gh killed by signal ${signal}\n` : stderr,
        exitCode: code ?? (signal ? 129 : 1),
      }),
    );
  });
}

const cwd = process.cwd();
const cached = readCache(undefined, cwd);
if (cached) {
  process.stdout.write(`owner=${cached.owner} name=${cached.name} (cached)\n`);
  process.exit(0);
}

const { stdout, stderr, exitCode } = await execGhRepoView();
if (exitCode !== 0) {
  process.stderr.write(stderr || `gh repo view failed (exit ${exitCode})\n`);
  process.exit(exitCode);
}

let parsed;
try {
  parsed = JSON.parse(stdout);
} catch (e) {
  process.stderr.write(`gh repo view: invalid JSON: ${e.message}\n`);
  process.exit(1);
}

const owner = parsed?.owner?.login;
const name = parsed?.name;
if (!owner || !name) {
  process.stderr.write(`gh repo view: missing owner/name in response\n`);
  process.exit(1);
}

try {
  writeCache(undefined, { cwd, owner, name });
} catch (e) {
  process.stderr.write(`[gh] warning: cache write failed: ${e.message}\n`);
}
process.stdout.write(`owner=${owner} name=${name}\n`);
