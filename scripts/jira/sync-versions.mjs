#!/usr/bin/env node
// scripts/jira/sync-versions.mjs — HIMMEL-3429: Jira fixVersions mirror the
// GitHub release tags.
//
//   1. Every published GitHub release becomes a Jira project version with the
//      same name (tag), released=true, the release date, and — for a
//      pre-release — a description that says so. Draft releases are skipped.
//   2. Every merged PR's merge commit is mapped to the FIRST tag that contains
//      it; that version is added to every [<PROJECT>-N] key in the PR title.
//      A PR whose merge commit is in no tag is left alone.
//
// Idempotent: an existing version is never re-created, a fixVersion a ticket
// already carries is never re-added. Default is a dry-run report; --apply
// writes. Only versions that are GitHub tags — plus v1.0.0 under --v1-keys —
// are ever created or released here; any other hand-made version is left alone.
//
// Reads AND writes go through the jira CLI (dist/, `npm run build`) as a
// subprocess — one auth path, breadcrumbs intact — and `gh` / local `git` for
// the GitHub side. The planner is pure so it is unit-tested with fixtures.
//
// Usage:
//   node sync-versions.mjs [--apply | --dry-run] [--project HIMMEL]
//     [--repo owner/name] [--jira-cli <path-to-dist/index.js>]
//     [--v1-keys <file>]
//
// --v1-keys <file> (one key per line, blanks and # comments skipped) also
// ensures an unreleased v1.0.0 version (Linux GA) exists and adds it to those
// tickets, in addition to their tag versions. Add-only: a ticket dropped from
// the list keeps v1.0.0 until `fix-version <key> --remove v1.0.0`. The v1 scope
// has moved before, so the list is a file the operator reconciles, never baked
// in here.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const BUF = 256 * 1024 * 1024;
const V1_VERSION = 'v1.0.0';
const V1_DESCRIPTION = 'Linux GA; scope = the v1 milestone tickets';

export function parseArgs(argv) {
  const opts = {
    apply: false,
    project: process.env.JIRA_PROJECT_KEY,
    repo: null,
    jiraCli: join(HERE, 'dist', 'index.js'),
    v1KeysFile: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') opts.apply = true;
    else if (a === '--dry-run') opts.apply = false;
    else if (a === '--project') opts.project = argv[++i];
    else if (a === '--repo') opts.repo = argv[++i];
    else if (a === '--jira-cli') opts.jiraCli = argv[++i];
    else if (a === '--v1-keys') opts.v1KeysFile = argv[++i];
    else {
      process.stderr.write(`sync-versions: unknown argument "${a}"\n`);
      process.exit(1);
    }
  }
  if (!opts.project) {
    process.stderr.write('sync-versions: --project or JIRA_PROJECT_KEY is required\n');
    process.exit(1);
  }
  return opts;
}

// Every bracketed `[PROJECT-N]` in a PR title, once each, in order. Unbracketed
// mentions are prose, not the ticket-ID convention the commit gate enforces.
export function extractKeys(title, project) {
  const seen = new Set();
  for (const m of title.matchAll(new RegExp(`\\[(${project}-\\d+)\\]`, 'g'))) seen.add(m[1]);
  return [...seen];
}

// One Jira key per line; blank lines and `#` comments skipped; duplicates dropped.
export function parseKeyFile(text) {
  const keys = [];
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (!/^[A-Z][A-Z0-9]*-\d+$/.test(line)) throw new Error(`"${line}" is not a Jira key`);
    if (!keys.includes(line)) keys.push(line);
  }
  return keys;
}

export function versionSpec(release) {
  const kind = release.isPrerelease ? 'pre-release' : 'release';
  const title = !release.isPrerelease && release.name && release.name !== release.tagName
    ? ` - ${release.name.replace(/^v[\w.-]+\s+[—-]\s+/, '')}`
    : '';
  return {
    name: release.tagName,
    released: true,
    releaseDate: release.publishedAt.slice(0, 10),
    description: `GitHub ${kind} ${release.tagName}${title}`,
  };
}

// tagOrder: tag names oldest-first. reachByTag: Map tag -> Set of commit shas
// reachable from it (a tag absent from the map is skipped). Returns
// Map sha -> the first tag in tagOrder whose reach set holds it.
export function assignFirstTags(tagOrder, reachByTag) {
  const first = new Map();
  for (const tag of tagOrder) {
    const reach = reachByTag.get(tag);
    if (!reach) continue;
    for (const sha of reach) if (!first.has(sha)) first.set(sha, tag);
  }
  return first;
}

export function planSync({ project, releases, prs, shaToTag, jiraVersions, jiraKeys, carriers, v1 }) {
  const published = releases
    .filter((r) => !r.isDraft && r.publishedAt)
    .sort((a, b) => a.publishedAt.localeCompare(b.publishedAt));
  const existing = new Map(jiraVersions.map((v) => [v.name, v]));

  const createVersions = [];
  const releaseVersions = [];
  let versionsUnchanged = 0;
  for (const r of published) {
    const spec = versionSpec(r);
    const have = existing.get(spec.name);
    if (!have) createVersions.push(spec);
    else if (spec.released && !have.released) {
      releaseVersions.push({ name: spec.name, releaseDate: spec.releaseDate });
    } else versionsUnchanged++;
  }

  const addFix = [];
  const unknown = new Map();
  const seenPair = new Set();
  let prsTagged = 0;
  let prsUntagged = 0;
  let fixAlready = 0;
  for (const pr of prs) {
    const tag = shaToTag.get(pr.sha);
    if (tag) prsTagged++;
    else prsUntagged++;
    for (const key of extractKeys(pr.title, project)) {
      if (!jiraKeys.has(key)) {
        if (!unknown.has(key)) unknown.set(key, []);
        unknown.get(key).push(pr.number);
        continue;
      }
      if (!tag) continue;
      const pair = `${key}|${tag}`;
      if (seenPair.has(pair)) continue;
      seenPair.add(pair);
      if (carriers.get(tag)?.has(key)) fixAlready++;
      else addFix.push({ key, version: tag });
    }
  }

  if (v1) {
    // v1.0.0 may also be a published GitHub tag: that create is already planned.
    if (!existing.has(v1.version) && !createVersions.some((c) => c.name === v1.version)) {
      createVersions.push({ name: v1.version, released: false, description: v1.description });
    }
    for (const key of v1.keys) {
      if (!jiraKeys.has(key)) {
        if (!unknown.has(key)) unknown.set(key, []);
        continue;
      }
      const pair = `${key}|${v1.version}`;
      if (seenPair.has(pair)) continue;
      seenPair.add(pair);
      if (carriers.get(v1.version)?.has(key)) fixAlready++;
      else addFix.push({ key, version: v1.version });
    }
  }

  return {
    createVersions,
    releaseVersions,
    addFix,
    unknownKeys: [...unknown].map(([key, nums]) => ({ key, prs: nums })),
    counts: {
      versionsCreate: createVersions.length,
      versionsRelease: releaseVersions.length,
      versionsUnchanged,
      fixAdd: addFix.length,
      fixAlready,
      prsMerged: prs.length,
      prsTagged,
      prsUntagged,
    },
  };
}

// deps: { loadReleases, loadPrs, reach(tag) -> Set|null, jira: {versions, keys,
// carriers(name), createVersion(spec), releaseVersion(name, date),
// fixVersion(key, name)} }. Reads always run; writes only under opts.apply.
export async function runSync(opts, deps) {
  const releases = await deps.loadReleases();
  const prs = await deps.loadPrs();
  const tagOrder = releases
    .filter((r) => !r.isDraft && r.publishedAt)
    .sort((a, b) => a.publishedAt.localeCompare(b.publishedAt))
    .map((r) => r.tagName);

  const reachByTag = new Map();
  const missingTags = [];
  for (const tag of tagOrder) {
    const r = await deps.reach(tag);
    if (r) reachByTag.set(tag, r);
    else missingTags.push(tag);
  }
  // A skipped tag hands its commits to the NEXT tag, and a wrong fixVersion is
  // never removed by a later run — so a partial clone may report but not write.
  if (opts.apply && missingTags.length) {
    throw new Error(
      `tags not in the local clone (run \`git fetch --tags\`): ${missingTags.join(', ')} — refusing to write`,
    );
  }

  const jiraVersions = await deps.jira.versions();
  const jiraKeys = await deps.jira.keys();
  const carriers = new Map();
  for (const v of jiraVersions) {
    if (tagOrder.includes(v.name) || v.name === V1_VERSION) {
      carriers.set(v.name, await deps.jira.carriers(v.name));
    }
  }

  const plan = planSync({
    project: opts.project,
    releases,
    prs,
    shaToTag: assignFirstTags(tagOrder, reachByTag),
    jiraVersions,
    jiraKeys,
    carriers,
    v1: opts.v1Keys
      ? { version: V1_VERSION, description: V1_DESCRIPTION, keys: opts.v1Keys }
      : undefined,
  });

  const failed = [];
  if (opts.apply) {
    const broken = new Set();
    const attempt = async (label, fn) => {
      try {
        await fn();
        return true;
      } catch (e) {
        failed.push(`${label}: ${e.message}`);
        return false;
      }
    };
    for (const spec of plan.createVersions) {
      if (!(await attempt(`version-create ${spec.name}`, () => deps.jira.createVersion(spec)))) {
        broken.add(spec.name);
      }
    }
    for (const r of plan.releaseVersions) {
      await attempt(`version-release ${r.name}`, () => deps.jira.releaseVersion(r.name, r.releaseDate));
    }
    for (const a of plan.addFix) {
      if (broken.has(a.version)) continue;
      await attempt(`fix-version ${a.key} +${a.version}`, () => deps.jira.fixVersion(a.key, a.version));
    }
  }

  return { ...plan, missingTags, failed, applied: Boolean(opts.apply) };
}

export function formatReport(r) {
  const c = r.counts;
  const lines = [
    `mode: ${r.applied ? 'APPLY' : 'DRY-RUN (no Jira writes)'}`,
    `versions: create=${c.versionsCreate} release=${c.versionsRelease} unchanged=${c.versionsUnchanged}`,
    ...r.createVersions.map((v) => `  create ${v.name}\t${v.releaseDate ?? '-'}\t${v.description}`),
    ...r.releaseVersions.map((v) => `  release ${v.name}\t${v.releaseDate}`),
    `prs: merged=${c.prsMerged} tagged=${c.prsTagged} untagged=${c.prsUntagged}`,
    `fixVersion: add=${c.fixAdd} already=${c.fixAlready}`,
    ...r.addFix.map((a) => `  add ${a.key}\t${a.version}`),
    `keys cited by PRs but not in Jira: ${r.unknownKeys.length}`,
    ...r.unknownKeys.map((u) => `  ${u.key}\t${u.prs.length ? `PR ${u.prs.map((n) => `#${n}`).join(',')}` : 'v1-keys file'}`),
  ];
  if (r.missingTags.length) {
    lines.push(`tags not in the local clone (run \`git fetch --tags\`): ${r.missingTags.join(', ')}`);
  }
  if (r.failed.length) {
    lines.push(`FAILED: ${r.failed.length}`, ...r.failed.map((f) => `  ${f}`));
  }
  return lines.join('\n');
}

// ---- I/O boundary (needs gh, git with the tags, and a built jira CLI) ----

function sh(cmd, args) {
  return execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: BUF });
}

// gh list --limit truncates silently; a result that fills the limit may be cut
// off, and a cut-off release list hands old commits to a later tag.
export function checkNotTruncated(rows, limit, what) {
  if (rows.length >= limit) {
    throw new Error(`${what}: got ${rows.length} rows, the --limit of ${limit} — the list may be truncated; raise the limit`);
  }
  return rows;
}

// The repo the local tags belong to: gh resolves it from this script's own
// checkout, the same one gitReach reads, so the two cannot disagree.
function defaultRepo() {
  return execFileSync('gh', ['repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'], {
    encoding: 'utf8',
    cwd: HERE,
  }).trim();
}

const RELEASE_LIMIT = 1000;
const PR_LIMIT = 5000;

function loadReleases(repo) {
  return checkNotTruncated(
    JSON.parse(
      sh('gh', [
        'release', 'list', '--repo', repo, '--limit', String(RELEASE_LIMIT),
        '--json', 'tagName,name,isPrerelease,isDraft,publishedAt',
      ]),
    ),
    RELEASE_LIMIT,
    'gh release list',
  );
}

function loadPrs(repo) {
  const rows = checkNotTruncated(
    JSON.parse(
      sh('gh', [
        'pr', 'list', '--repo', repo, '--state', 'merged', '--limit', String(PR_LIMIT),
        '--json', 'number,title,mergeCommit',
      ]),
    ),
    PR_LIMIT,
    'gh pr list',
  );
  return rows.map((p) => ({ number: p.number, title: p.title, sha: p.mergeCommit?.oid }));
}

function gitReach(tag) {
  try {
    sh('git', ['-C', HERE, 'rev-parse', '-q', '--verify', `refs/tags/${tag}^{commit}`]);
  } catch {
    return null;
  }
  return new Set(sh('git', ['-C', HERE, 'rev-list', `refs/tags/${tag}`]).split('\n').filter(Boolean));
}

function makeJira(cli, project) {
  const run = (args) => sh('node', [cli, ...args]);
  const lines = (out) => out.split('\n').filter(Boolean);
  const keysOf = (jql) =>
    new Set(lines(run(['list', '--jql', jql, '--limit', '50000'])).map((l) => l.split('\t')[0]));
  return {
    versions: async () =>
      lines(run(['versions', '--project', project])).map((l) => {
        const [name, released, releaseDate] = l.split('\t');
        return { name, released: released === 'true', releaseDate: releaseDate || undefined };
      }),
    keys: async () => keysOf(`project = ${project}`),
    carriers: async (name) => keysOf(`project = ${project} AND fixVersion = "${name}"`),
    createVersion: async (s) => {
      run([
        'version-create', s.name, '--project', project,
        '--description', s.description,
        ...(s.releaseDate ? ['--release-date', s.releaseDate] : []),
        ...(s.released ? ['--released'] : []),
      ]);
    },
    releaseVersion: async (name, date) => {
      run(['version-release', name, '--project', project, '--date', date]);
    },
    fixVersion: async (key, name) => {
      run(['fix-version', key, '--add', name]);
    },
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.v1KeysFile) opts.v1Keys = parseKeyFile(readFileSync(opts.v1KeysFile, 'utf8'));
  const localRepo = defaultRepo();
  const repo = opts.repo ?? localRepo;
  // Reachability is read from THIS clone's tags; another repo's release names
  // would silently resolve against the wrong history.
  if (repo.toLowerCase() !== localRepo.toLowerCase()) {
    throw new Error(`--repo ${repo} is not this checkout's repo (${localRepo}); run the sync from a clone of ${repo}`);
  }
  const report = await runSync(opts, {
    loadReleases: async () => loadReleases(repo),
    loadPrs: async () => loadPrs(repo),
    reach: async (tag) => gitReach(tag),
    jira: makeJira(opts.jiraCli, opts.project),
  });
  console.log(formatReport(report));
  if (report.failed.length) process.exit(1);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error(`sync-versions: ${e.message}`);
    process.exit(1);
  });
}
