import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// HIMMEL-618: jira-mutation breadcrumb.
//
// Every mutating verb (transition, comment, create, move, edit, assign,
// worklog, link, sprint) calls writeJiraBreadcrumb(<ticket>) immediately after
// its mutating request RESOLVES — NOT gated on the command's exit code, so a
// mutation that landed before a later non-fatal failure (e.g. an attachment
// upload) still leaves a breadcrumb.
//
// The SessionEnd hook scripts/hooks/jira-nudge-on-end.sh reads these
// breadcrumbs to decide whether a ticket-scoped session already synced Jira.
// Session-id keying is IMPOSSIBLE here: this standalone node process (spawned
// via the Bash tool) never receives the Claude session_id, so we key the file
// by repo+branch and let the hook match on `epoch >= session-start`.
//
// The path + sanitization MUST stay byte-identical to the bash reader in
// scripts/lib/jira-breadcrumb.sh — see that file's header.

// Keep [A-Za-z0-9._-]; replace everything else (notably the '/' in branch
// names like feat/foo) with '-'. Mirrors the reader's sed expression.
export function sanitizeBreadcrumbToken(s: string): string {
  return s.replace(/[^A-Za-z0-9._-]/g, '-');
}

// repo-key = basename of `git remote get-url origin`, trailing '.git' stripped.
// Stable across worktrees (they share one origin), so the CLI writer and the
// hook reader resolve the same key regardless of which checkout each runs in.
// Mirrors end-session-wiki.sh's REPO_NAME derivation.
export function deriveRepoKey(remoteUrl: string): string {
  const last = remoteUrl.replace(/\/+$/, '').split('/').pop() ?? '';
  return last.replace(/\.git$/, '');
}

export function breadcrumbDir(home: string = homedir()): string {
  return join(home, '.claude', 'jira-breadcrumbs');
}

export function breadcrumbFileName(repoKey: string, branch: string): string {
  return `${sanitizeBreadcrumbToken(repoKey)}__${sanitizeBreadcrumbToken(branch)}.log`;
}

function gitOut(args: string[]): string {
  try {
    return execFileSync('git', args, { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

export function writeJiraBreadcrumb(ticket: string): void {
  // Best-effort, fire-and-forget. The mutation already landed; a breadcrumb
  // write failure must NEVER fail the CLI command — swallow everything.
  try {
    if (!ticket) return;
    const remote = gitOut(['remote', 'get-url', 'origin']);
    let repoKey: string;
    if (remote) {
      repoKey = deriveRepoKey(remote);
    } else {
      const top = gitOut(['rev-parse', '--show-toplevel']);
      repoKey = top.split('/').pop() || 'unknown-repo';
    }
    const branch = gitOut(['branch', '--show-current']) || 'detached';
    const dir = breadcrumbDir();
    mkdirSync(dir, { recursive: true });
    const file = join(dir, breadcrumbFileName(repoKey, branch));
    const epoch = Math.floor(Date.now() / 1000);
    appendFileSync(file, `${epoch}\t${ticket}\n`);
  } catch {
    // never break the CLI on a breadcrumb write
  }
}
