import { execFileSync } from 'node:child_process';

export interface RepoRef {
  workspace: string;
  repoSlug: string;
}

// Matches both https and ssh Bitbucket Cloud origin URLs, optional trailing
// `.git`, case-insensitive host:
//   https://bitbucket.org/<workspace>/<repo>(.git)
//   git@bitbucket.org:<workspace>/<repo>(.git)
const BB_REMOTE_RE =
  /^(?:https?:\/\/(?:[^@/]+@)?bitbucket\.org\/|git@bitbucket\.org:)([^/]+)\/(.+?)(?:\.git)?\/?$/i;

export function parseBitbucketRemote(url: string): RepoRef | null {
  const m = BB_REMOTE_RE.exec(url.trim());
  if (!m) return null;
  return { workspace: m[1], repoSlug: m[2] };
}

// Parse a bare `<workspace>/<repo_slug>` argument (the `--repo` override on the
// ingestion read verbs, which target an arbitrary URL-named repo rather than
// the origin's repoRef). The leading-char rule rejects `.`/`..` segments that
// would otherwise let a `..` traverse into a different endpoint.
const REPO_ARG_RE = /^([A-Za-z0-9_-][A-Za-z0-9_.-]*)\/([A-Za-z0-9_-][A-Za-z0-9_.-]*)$/;

export function parseRepoArg(arg: string): RepoRef {
  const m = REPO_ARG_RE.exec(arg.trim());
  if (!m) {
    throw new Error(`bitbucket: --repo must be <workspace>/<repo_slug>, got: ${arg}`);
  }
  return { workspace: m[1], repoSlug: m[2] };
}

// CHANGE-2770: always derive {workspace}/{repo} from the `origin` remote and
// call workspace-scoped endpoints — never list workspaces. Env overrides
// (BITBUCKET_WORKSPACE / BITBUCKET_REPO_SLUG) take precedence for tests and
// for non-origin invocations.
export function repoRef(): RepoRef {
  const ws = process.env.BITBUCKET_WORKSPACE;
  const slug = process.env.BITBUCKET_REPO_SLUG;
  if (ws && slug) return { workspace: ws, repoSlug: slug };

  let originUrl: string;
  try {
    originUrl = execFileSync('git', ['remote', 'get-url', 'origin'], {
      encoding: 'utf8',
    }).trim();
  } catch {
    throw new Error(
      'bitbucket: cannot read `git remote get-url origin` — run inside a git repo ' +
        'with a bitbucket.org origin, or set BITBUCKET_WORKSPACE + BITBUCKET_REPO_SLUG.',
    );
  }
  const ref = parseBitbucketRemote(originUrl);
  if (!ref) {
    throw new Error(
      `bitbucket: origin remote (${originUrl}) is not a bitbucket.org URL. ` +
        'Set BITBUCKET_WORKSPACE + BITBUCKET_REPO_SLUG to override.',
    );
  }
  return ref;
}
