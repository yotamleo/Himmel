// HIMMEL-4640: opt-in LIVE integration suite for the Jira CLI. It writes to a
// real Jira project, reads each change back and asserts the field really
// changed (the silent-no-op class). Never part of default CI:
//
//   npm run build && JIRA_LIVE_TEST=1 JIRA_LIVE_PROJECT=HTEST npx vitest run live/
//
// Safety: refuses to run unless JIRA_LIVE_PROJECT is set to a project key that
// is not HIMMEL — live writes never touch the real backlog. Needs the creds the
// CLI itself reads (.env at the repo root, or JIRA_* env vars) and a prior
// `npm run build` (the suite drives dist/index.js, the shipped binary).
import { describe, it, expect, beforeAll } from 'vitest';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ENABLED = process.env.JIRA_LIVE_TEST === '1';
const PROJECT = process.env.JIRA_LIVE_PROJECT ?? '';
const CLI = fileURLToPath(new URL('../dist/index.js', import.meta.url));

function jira(...args: string[]): string {
  return execFileSync('node', [CLI, ...args], {
    encoding: 'utf8',
    env: { ...process.env, JIRA_PROJECT_KEY: PROJECT },
  });
}

interface Issue {
  key: string;
  fields: {
    summary: string;
    priority?: { name: string };
    labels?: string[];
    fixVersions?: Array<{ name: string }>;
    status: { name: string };
  };
}

const read = (key: string): Issue => JSON.parse(jira('get', key, '--json')) as Issue;

describe.skipIf(!ENABLED)('jira CLI live (opt-in, JIRA_LIVE_TEST=1)', () => {
  const stamp = Date.now().toString(36);
  let key = '';

  beforeAll(() => {
    if (!PROJECT || PROJECT === 'HIMMEL') {
      throw new Error('JIRA_LIVE_PROJECT must name a dedicated test project, never HIMMEL');
    }
  });

  it('create: the issue exists and reads back its title', () => {
    const out = jira('create', '--type', 'Task', '--title', `live ${stamp}`);
    key = /Created (\S+)/.exec(out)?.[1] ?? '';
    expect(key).toMatch(new RegExp(`^${PROJECT}-\\d+$`));
    expect(read(key).fields.summary).toBe(`live ${stamp}`);
  });

  it('edit --priority: Medium to Highest and back, each read back', () => {
    jira('edit', key, '--priority', 'Medium');
    expect(read(key).fields.priority?.name).toBe('Medium');
    jira('edit', key, '--priority', 'Highest');
    expect(read(key).fields.priority?.name).toBe('Highest');
    jira('edit', key, '--priority', 'Medium');
    expect(read(key).fields.priority?.name).toBe('Medium');
  });

  it('edit --priority with an unknown name fails non-zero', () => {
    expect(() => jira('edit', key, '--priority', 'NoSuchPriority')).toThrow();
    expect(read(key).fields.priority?.name).toBe('Medium');
  });

  it('edit --title changes the summary', () => {
    jira('edit', key, '--title', `live ${stamp} renamed`);
    expect(read(key).fields.summary).toBe(`live ${stamp} renamed`);
  });

  it('edit --labels replaces and --add-labels appends', () => {
    jira('edit', key, '--labels', 'live-a,live-b');
    expect(read(key).fields.labels?.sort()).toEqual(['live-a', 'live-b']);
    jira('edit', key, '--add-labels', 'live-c');
    expect(read(key).fields.labels?.sort()).toEqual(['live-a', 'live-b', 'live-c']);
  });

  it('edit --desc is stored (visible in get output)', () => {
    jira('edit', key, '--desc', `description marker ${stamp}`);
    expect(jira('get', key)).toContain(`description marker ${stamp}`);
  });

  it('version-create + edit --fix-version: the version is set on the issue', () => {
    const v = `live-${stamp}`;
    jira('version-create', v, '--project', PROJECT);
    jira('edit', key, '--fix-version', v);
    expect(read(key).fields.fixVersions?.map((x) => x.name)).toEqual([v]);
  });

  it('comment: the text appears in comments', () => {
    jira('comment', key, `comment marker ${stamp}`);
    expect(jira('comments', key)).toContain(`comment marker ${stamp}`);
  });

  it('transition: the status changes', () => {
    jira('transition', key, 'In Progress');
    expect(read(key).fields.status.name).toBe('In Progress');
  });

  it('list: the issue is returned for the project', () => {
    // Jira's search index is eventually consistent: a list straight after the
    // create can miss the new issue (seen: empty 355 ms after create, present a
    // minute later). Poll with backoff before asserting; this is index lag, not
    // a CLI defect.
    const deadline = Date.now() + 20_000;
    const hasKey = (s: string) => new RegExp(`\\b${key}\\b`).test(s); // HTEST-1 must not match HTEST-10
    let out = '';
    for (let waitMs = 500; ; waitMs *= 2) {
      out = jira('list', '--project', PROJECT, '--limit', '100');
      const left = deadline - Date.now();
      if (hasKey(out) || left <= 0) break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.min(waitMs, left));
    }
    expect(hasKey(out)).toBe(true);
  }, 40_000);

  it('link: a second issue is linked and links lists it', () => {
    const out = jira('create', '--type', 'Task', '--title', `live ${stamp} peer`);
    const peer = /Created (\S+)/.exec(out)?.[1] ?? '';
    jira('link', key, peer);
    expect(jira('links', key)).toContain(peer);
  });
});
