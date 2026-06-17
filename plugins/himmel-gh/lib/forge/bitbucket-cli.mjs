// forge/bitbucket-cli.mjs — resolve the himmel `bitbucket` CLI argv prefix,
// the JS parallel of _bb_cmd / BITBUCKET_CMD in scripts/lib/forge-bitbucket.sh.
//
// Default mirrors the Jira-CLI convention: invoke dist/index.js by absolute
// path from the repo root (dist/ is an untracked build artifact). Override via
// env.BITBUCKET_CLI — the test seam, exact parallel to the shell's BITBUCKET_CMD.
// Two forms: a JSON array (`["node","C:\\…\\index.js"]`) is parsed as an exact
// argv with NO splitting — the Windows-safe form, since `process.execPath`
// contains a space (`C:\Program Files\nodejs\node.exe`) that the space-split
// form mangles (HIMMEL-345); any other string is space-split for back-compat.

import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';

export function bitbucketCli(env = process.env, cwd = process.cwd()) {
  if (env.BITBUCKET_CLI && env.BITBUCKET_CLI.trim()) {
    const raw = env.BITBUCKET_CLI.trim();
    if (raw.startsWith('[')) {
      try {
        const argv = JSON.parse(raw);
        if (Array.isArray(argv) && argv.length && argv.every((a) => typeof a === 'string')) {
          return argv;
        }
      } catch {
        // Not valid JSON — fall through to the space-split form.
      }
    }
    return raw.split(/\s+/);
  }
  let root = '';
  try {
    // Use --git-common-dir, NOT --show-toplevel: from a worktree the latter
    // gives the worktree root, which lacks the untracked (gitignored) dist/.
    // --git-common-dir points at the PRIMARY checkout's .git, whose parent is
    // the primary repo root where dist/ is built (exact parallel to _bb_cmd in
    // scripts/lib/forge-bitbucket.sh). The path may be relative — resolve it
    // against cwd before taking the parent.
    const r = spawnSync('git', ['rev-parse', '--git-common-dir'], {
      cwd,
      encoding: 'utf8',
    });
    if (r.status === 0 && typeof r.stdout === 'string' && r.stdout.trim()) {
      root = dirname(resolve(cwd, r.stdout.trim()));
    }
  } catch {
    root = '';
  }
  if (!root) return ['bitbucket'];
  return ['node', join(root, 'scripts', 'bitbucket', 'dist', 'index.js')];
}

// spawnForge(argv, args, opts) — run a forge CLI (argv = bitbucketCli()) with
// the given args, returning { stdout, stderr, exitCode } the same async shape
// the github exec helpers use. Mirrors the spawn/close/error handling in
// repo-context-cli.mjs and init-flow.mjs.
import { spawn } from 'node:child_process';
import { buildErrorStderr } from '../init-flow.mjs';

export function spawnForge(argv, args, opts = {}) {
  const [cmd, ...prefix] = argv;
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    const proc = spawn(cmd, [...prefix, ...args], {
      stdio: ['ignore', 'pipe', 'pipe'],
      ...opts,
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
        stderr: signal ? `${stderr}${cmd} killed by signal ${signal}\n` : stderr,
        exitCode: code ?? (signal ? 129 : 1),
      }),
    );
  });
}
