// forge/bitbucket-threads.mjs — Bitbucket review-thread backend (spec §5.3).
//
// Bitbucket Cloud has NO GraphQL, so the GitHub reviewThreads path can't be
// reused. This calls the himmel `bitbucket` CLI `pr comments|reply|resolve`
// verbs and adapts the flat ReviewThread[] the CLI emits into the GraphQL-node
// shape that thread-cache.mjs (buildPrefixMap) and threads-list-cli.mjs (table
// formatter) already consume from the GitHub path — so everything downstream of
// "give me an array of nodes" stays forge-agnostic.

import { bitbucketCli, spawnForge } from './bitbucket-cli.mjs';

// Adapt one CLI ReviewThread → a GitHub-GraphQL-shaped node. `id` MUST be a
// string: thread-cache's hashId() feeds it to createHash().update(), which
// rejects a bare number. The single-comment `comments.nodes` mirrors the
// `comments(first: 1)` preview the GraphQL query fetches.
function nodeFromThread(t) {
  return {
    id: String(t.id),
    isResolved: Boolean(t.isResolved),
    path: t.path ?? null,
    line: t.line ?? null,
    comments: { nodes: [{ author: { login: t.author ?? '?' }, bodyText: t.body ?? '' }] },
  };
}

// Resolve the CLI argv once per call. `cli` (an argv array) overrides for tests
// — passing it directly avoids the BITBUCKET_CLI env string-split, so callers
// can drive a node stub on Windows too.
function resolveCli(cli, env, cwd) {
  return cli ?? bitbucketCli(env, cwd);
}

export async function listThreads({ number, env = process.env, cwd = process.cwd(), cli } = {}) {
  const argv = resolveCli(cli, env, cwd);
  const res = await spawnForge(argv, ['pr', 'comments', String(number)]);
  if (res.exitCode !== 0) {
    throw new Error(res.stderr.trim() || `bitbucket pr comments failed (exit ${res.exitCode})`);
  }
  let payload;
  try {
    payload = JSON.parse(res.stdout);
  } catch (e) {
    throw new Error(`bitbucket pr comments: parse error: ${e.message}`);
  }
  // `pr comments` wraps the threads in { threads, truncated, pages } (HIMMEL-344)
  // so a page-capped list isn't mistaken for a complete one. Return the mapped
  // nodes array (the forge-agnostic shape downstream consumes), and surface the
  // truncation on stderr so the caller knows the cache it builds is partial.
  const threads = payload?.threads;
  if (!Array.isArray(threads)) {
    throw new Error('bitbucket pr comments: expected { threads: [...] }');
  }
  if (payload.truncated) {
    // `?? '?'` defends the message against a payload that flags truncated
    // without a numeric pages (the real CLI always co-emits both).
    process.stderr.write(
      `bitbucket pr comments for #${number}: thread list truncated at ${payload.pages ?? '?'} pages — results may be incomplete\n`,
    );
  }
  return threads.map(nodeFromThread);
}

export async function replyThread({
  number,
  id,
  body,
  env = process.env,
  cwd = process.cwd(),
  cli,
} = {}) {
  const argv = resolveCli(cli, env, cwd);
  const res = await spawnForge(argv, ['pr', 'reply', String(number), String(id), '--body', body]);
  if (res.exitCode !== 0) {
    throw new Error(res.stderr.trim() || `bitbucket pr reply failed (exit ${res.exitCode})`);
  }
  return res.stdout;
}

export async function resolveThread({ number, id, env = process.env, cwd = process.cwd(), cli } = {}) {
  const argv = resolveCli(cli, env, cwd);
  const res = await spawnForge(argv, ['pr', 'resolve', String(number), String(id)]);
  if (res.exitCode !== 0) {
    throw new Error(res.stderr.trim() || `bitbucket pr resolve failed (exit ${res.exitCode})`);
  }
  return res.stdout;
}
