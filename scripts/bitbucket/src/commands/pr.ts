import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import {
  createPr,
  editPr,
  mergePr,
  listPrs,
  getPr,
  listPrComments,
  replyPrComment,
  resolvePrComment,
} from '../client.js';
import { parseRepoArg } from '../remote.js';
import { printJson } from '../output.js';
import { exitFor } from './exit-codes.js';

function resolveBody(opts: { body?: string; bodyFile?: string }): string {
  if (opts.bodyFile) return readFileSync(opts.bodyFile, 'utf8');
  return opts.body ?? '';
}

export function registerPr(program: Command): void {
  const pr = program.command('pr').description('Pull request operations');

  pr.command('create')
    .description('Create a pull request (POST .../pullrequests)')
    .requiredOption('--title <title>', 'PR title')
    .requiredOption('--source <branch>', 'Source branch name')
    .requiredOption('--destination <branch>', 'Destination branch name')
    .option('--body <text>', 'PR description')
    .option('--body-file <path>', 'Read PR description from a file')
    .action(
      async (opts: {
        title: string;
        source: string;
        destination: string;
        body?: string;
        bodyFile?: string;
      }) => {
        try {
          printJson(
            await createPr({
              title: opts.title,
              body: resolveBody(opts),
              source: opts.source,
              destination: opts.destination,
            }),
          );
        } catch (err) {
          const { code, message } = exitFor(err, 'pr create');
          process.stderr.write(`${message}\n`);
          process.exit(code);
        }
      },
    );

  pr.command('edit <id>')
    .description('Edit a pull request (PUT .../{id}). API requires --title.')
    .requiredOption('--title <title>', 'PR title')
    .option('--body <text>', 'PR description')
    .option('--body-file <path>', 'Read PR description from a file')
    .action(async (id: string, opts: { title: string; body?: string; bodyFile?: string }) => {
      try {
        printJson(await editPr(Number(id), { title: opts.title, body: resolveBody(opts) }));
      } catch (err) {
        const { code, message } = exitFor(err, 'pr edit');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  pr.command('merge <id>')
    .description('Merge a pull request (POST .../{id}/merge). 400 conflict → exit 2.')
    .option('--squash', 'Use the squash merge strategy', false)
    .option('--delete-branch', 'Close the source branch on merge', false)
    .action(async (id: string, opts: { squash?: boolean; deleteBranch?: boolean }) => {
      try {
        printJson(
          await mergePr(Number(id), {
            squash: Boolean(opts.squash),
            closeSourceBranch: Boolean(opts.deleteBranch),
          }),
        );
      } catch (err) {
        // Distinguish merge-conflict (400 → exit 2) so callers can map it to the
        // same "not mergeable" failure the GitHub path raises (spec §5.1).
        const { code, message } = exitFor(err, 'pr merge', { 400: 2 });
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  pr.command('list')
    .description('List pull requests (GET .../pullrequests?q=state=...). JSON array.')
    .option('--state <state>', 'PR state (OPEN|MERGED|DECLINED|SUPERSEDED)', 'OPEN')
    .option('--head <branch>', 'Filter by source branch name')
    .action(async (opts: { state: string; head?: string }) => {
      try {
        printJson(await listPrs({ state: opts.state.toUpperCase(), sourceBranch: opts.head }));
      } catch (err) {
        const { code, message } = exitFor(err, 'pr list');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  pr.command('get <id>')
    .description('Get PR detail for ingestion (GET .../pullrequests/{id}). JSON object.')
    .option('--repo <workspace/repo>', 'Target repo (defaults to the origin remote)')
    .action(async (id: string, opts: { repo?: string }) => {
      try {
        printJson(await getPr(Number(id), opts.repo ? parseRepoArg(opts.repo) : undefined));
      } catch (err) {
        const { code, message } = exitFor(err, 'pr get');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  // ── PR review threads (spec §5.3) — the `gh api graphql` analogue over REST ──

  pr.command('comments <id>')
    .description(
      'List PR review threads (GET .../{id}/comments). JSON { threads, truncated, pages }.',
    )
    .action(async (id: string) => {
      try {
        printJson(await listPrComments(Number(id)));
      } catch (err) {
        const { code, message } = exitFor(err, 'pr comments');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  pr.command('reply <id> <parentId>')
    .description('Reply to a review thread (POST .../{id}/comments with parent.id).')
    .option('--body <text>', 'Reply text')
    .option('--body-file <path>', 'Read reply text from a file')
    .action(async (id: string, parentId: string, opts: { body?: string; bodyFile?: string }) => {
      try {
        printJson(await replyPrComment(Number(id), Number(parentId), resolveBody(opts)));
      } catch (err) {
        const { code, message } = exitFor(err, 'pr reply');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });

  pr.command('resolve <id> <commentId>')
    .description('Resolve a review thread (POST .../{id}/comments/{cid}/resolve).')
    .action(async (id: string, commentId: string) => {
      try {
        await resolvePrComment(Number(id), Number(commentId));
        printJson({ resolved: true, id: Number(commentId) });
      } catch (err) {
        const { code, message } = exitFor(err, 'pr resolve');
        process.stderr.write(`${message}\n`);
        process.exit(code);
      }
    });
}
