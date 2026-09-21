import { describe, it, expect, beforeEach } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectForge } from '../lib/forge/detect.mjs';

let repo;

function gitRepoWithOrigin(url) {
  const dir = mkdtempSync(join(tmpdir(), 'himmel-forge-detect-'));
  spawnSync('git', ['init', '-q'], { cwd: dir });
  if (url) spawnSync('git', ['remote', 'add', 'origin', url], { cwd: dir });
  return dir;
}

describe('detectForge — FORGE override', () => {
  it('FORGE=github returns github (even with a bitbucket origin)', () => {
    repo = gitRepoWithOrigin('git@bitbucket.org:ws/repo.git');
    expect(detectForge(repo, { FORGE: 'github' })).toBe('github');
  });

  it('FORGE=bitbucket returns bitbucket (even with a github origin)', () => {
    repo = gitRepoWithOrigin('https://github.com/o/r.git');
    expect(detectForge(repo, { FORGE: 'bitbucket' })).toBe('bitbucket');
  });
});

describe('detectForge — origin URL', () => {
  it('github https → github', () => {
    repo = gitRepoWithOrigin('https://github.com/yotamleo/himmel');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('github https .git → github', () => {
    repo = gitRepoWithOrigin('https://github.com/yotamleo/himmel.git');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('github ssh → github', () => {
    repo = gitRepoWithOrigin('git@github.com:yotamleo/himmel.git');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('bitbucket https → bitbucket', () => {
    repo = gitRepoWithOrigin('https://bitbucket.org/example-ws/repo.git'); // leak-allow: hostname test fixture bitbucket https origin for forge detection
    expect(detectForge(repo, {})).toBe('bitbucket');
  });

  it('bitbucket ssh → bitbucket', () => {
    repo = gitRepoWithOrigin('git@bitbucket.org:example-ws/repo.git'); // leak-allow: hostname test fixture bitbucket ssh origin for forge detection
    expect(detectForge(repo, {})).toBe('bitbucket');
  });

  it('uppercase host → matched case-insensitively', () => {
    repo = gitRepoWithOrigin('https://BitBucket.ORG/ws/repo.git');
    expect(detectForge(repo, {})).toBe('bitbucket');
  });
});

describe('detectForge — safe github default', () => {
  it('no origin → github', () => {
    repo = gitRepoWithOrigin(null);
    expect(detectForge(repo, {})).toBe('github');
  });

  it('unknown host → github', () => {
    repo = gitRepoWithOrigin('https://gitlab.com/o/r.git');
    expect(detectForge(repo, {})).toBe('github');
  });

  it('non-git dir (git error) → github', () => {
    const dir = mkdtempSync(join(tmpdir(), 'himmel-forge-nogit-'));
    expect(detectForge(dir, {})).toBe('github');
  });
});

// HIMMEL-3337: the forge is the origin URL's HOST (the domain or a subdomain of
// it), never a substring of the URL. Driven by the answer table forge.sh's own
// suite and status-report's suite read (scripts/lib/fixtures/forge-origins.tsv),
// so this matcher is held to the same answers as forge_detect. `none` (neither
// forge; forge_detect exits 3) is the one place the plugin diverges on purpose:
// it defaults to github.
const ORIGINS_TSV = fileURLToPath(new URL('../../../scripts/lib/fixtures/forge-origins.tsv', import.meta.url));
const FORGE_SH = fileURLToPath(new URL('../../../scripts/lib/forge.sh', import.meta.url));
const rows = readFileSync(ORIGINS_TSV, 'utf8')
  .split('\n')
  .filter((l) => l && !l.startsWith('#'))
  .map((l) => {
    const [want, url] = l.split('\t');
    return { want, url };
  });

// forge_detect's answer for `url`, or 'none' when it exits non-zero (FORGE unset).
function shellForge(dir) {
  const env = { ...process.env };
  delete env.FORGE;
  const r = spawnSync('bash', ['-c', `. "$1"; forge_detect 2>/dev/null`, '_', FORGE_SH], {
    cwd: dir,
    env,
    encoding: 'utf8',
  });
  return r.status === 0 ? r.stdout.trim() : 'none';
}

describe('detectForge — host-anchored (forge-origins.tsv)', () => {
  it('reads the whole origin table', () => {
    expect(rows.length).toBeGreaterThanOrEqual(30);
  });

  for (const { want, url } of rows) {
    const expected = want === 'bitbucket' ? 'bitbucket' : 'github';
    it(`${url} → ${expected}`, () => {
      repo = gitRepoWithOrigin(url);
      expect(detectForge(repo, {})).toBe(expected);
    });

    it(`${url} agrees with forge_detect`, () => {
      repo = gitRepoWithOrigin(url);
      const sh = shellForge(repo);
      expect(sh).toBe(want);
      // `none` is the plugin's github default; any real answer must match exactly.
      expect(detectForge(repo, {})).toBe(sh === 'none' ? 'github' : sh);
    });
  }
});
