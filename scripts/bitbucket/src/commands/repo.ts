import type { Command } from 'commander';
import { getRepo, getRepoForIngest } from '../client.js';
import { parseRepoArg } from '../remote.js';
import { printJson } from '../output.js';
import { exitFor } from './exit-codes.js';

export function registerRepo(program: Command): void {
  const repo = program.command('repo').description('Repository operations');
  repo
    .command('view')
    .description('Get repo context (workspace, repo_slug, full_name, default_branch)')
    .action(async () => {
      try {
        printJson(await getRepo());
      } catch (err) {
        const { code, message } = exitFor(err, 'repo view');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  repo
    .command('get')
    .description('Get repo metadata + README for ingestion (luna-ingest source fetch).')
    .option('--repo <workspace/repo>', 'Target repo (defaults to the origin remote)')
    .action(async (opts: { repo?: string }) => {
      try {
        printJson(await getRepoForIngest(opts.repo ? parseRepoArg(opts.repo) : undefined));
      } catch (err) {
        const { code, message } = exitFor(err, 'repo get');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });
}
