import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import { uploadAll } from './attach-helper.js';
import { readBodyFile } from './body-file.js';

function collect(value: string, prev: string[]): string[] {
  return [...prev, value];
}

export function registerComment(program: Command): void {
  program
    .command('comment <key> [text]')
    .description('Add a comment to a Jira issue (text supports markdown)')
    .option('--adf-file <path>', 'Path to pre-built ADF JSON document (overrides <text>)')
    .option(
      '--comment-file <path>',
      'Read the markdown comment body from a file (overrides <text>; keeps the ' +
        'shell command single-line for multi-line bodies)',
    )
    .option('--attach <path>', 'File to attach to the parent issue (repeatable)', collect, [])
    .action(
      async (
        key: string,
        text: string | undefined,
        options: { adfFile?: string; commentFile?: string; attach: string[] },
      ) => {
        let body: unknown;
        if (options.adfFile) {
          try {
            body = JSON.parse(readFileSync(options.adfFile, 'utf8'));
          } catch (e) {
            console.error(`jira: cannot read --adf-file "${options.adfFile}": ${(e as Error).message}`);
            process.exit(1);
          }
        } else {
          const markdown = options.commentFile
            ? readBodyFile(options.commentFile, '--comment-file')
            : text;
          if (markdown === undefined) {
            console.error('jira: comment requires <text> or --comment-file or --adf-file');
            process.exit(1);
          }
          body = markdownToAdf(markdown);
        }
        await request('POST', `/issue/${key}/comment`, { body });
        // Breadcrumb BEFORE attachments: the comment mutation has landed even
        // if a later attachment upload fails and we exit 1 (HIMMEL-618 F11).
        writeJiraBreadcrumb(key);

        // Print the success indicator to STDOUT immediately, BEFORE
        // attempting attachments. Scripted callers piping stdout still
        // see the comment landed even if a subsequent attachment fails
        // and we exit 1. Attachment-failure message goes to stderr.
        console.log(`Comment added to ${key}`);

        const attachments = options.attach ?? [];
        if (attachments.length === 0) return;
        try {
          const n = await uploadAll(key, attachments);
          console.error(`  attachments: ${n}`);
        } catch (e) {
          console.error(`Comment added to ${key} but attachment failed: ${(e as Error).message}`);
          process.exit(1);
        }
      },
    );
}
