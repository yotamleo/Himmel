import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { createIssue, getIssue } from '../client.js';
import { parseRepoArg } from '../remote.js';
import { printJson } from '../output.js';
import { exitFor } from './exit-codes.js';

function resolveBody(opts: { body?: string; bodyFile?: string }): string {
  if (opts.bodyFile) return readFileSync(opts.bodyFile, 'utf8');
  return opts.body ?? '';
}

export function registerIssue(program: Command): void {
  const issue = program.command('issue').description('Issue tracker operations');

  issue
    .command('create')
    .description('Create an issue (POST .../issues). 404 issues-disabled → exit 3.')
    .requiredOption('--title <title>', 'Issue title')
    .option('--body <text>', 'Issue body')
    .option('--body-file <path>', 'Read issue body from a file')
    .option('--kind <kind>', 'Issue kind (bug|enhancement|proposal|task)', 'task')
    .action(async (opts: { title: string; body?: string; bodyFile?: string; kind: string }) => {
      try {
        printJson(
          await createIssue({ title: opts.title, body: resolveBody(opts), kind: opts.kind }),
        );
      } catch (err) {
        // Issues-disabled (spec §5.2) gets a distinct exit code (404 → 3) so the
        // forge seam can degrade gracefully instead of treating it as a hard
        // failure. Mapping is unit-tested via exitFor (HIMMEL-341).
        const { code, message } = exitFor(err, 'issue create', { 404: 3 });
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  issue
    .command('get <id>')
    .description('Get issue detail for ingestion (GET .../issues/{id}). 404 → exit 3.')
    .option('--repo <workspace/repo>', 'Target repo (defaults to the origin remote)')
    .action(async (id: string, opts: { repo?: string }) => {
      try {
        printJson(await getIssue(Number(id), opts.repo ? parseRepoArg(opts.repo) : undefined));
      } catch (err) {
        // 404 (tracker disabled OR issue gone) → exit 3, same contract as
        // `issue create`. A non-numeric id throws status 0 (not in the special
        // map) → exit 1, never 3 (HIMMEL-341).
        const { code, message } = exitFor(err, 'issue get', { 404: 3 });
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });
}
