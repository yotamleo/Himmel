import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { request, projectKey } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import type { CreateIssueResponse } from '../types.js';
import { uploadAll } from './attach-helper.js';
import { readBodyFile } from './body-file.js';
import { parseLabels } from './labels.js';
import { BUG_FREEZE, freezeFixVersion, todayIso } from '../freeze.js';
import { assertVersionExists } from './versions.js';

function collect(value: string, prev: string[]): string[] {
  return [...prev, value];
}

/**
 * Jira's REST field is `summary`; the CLI's long-standing flag is `--title`
 * (matches `edit --title`). `--summary` is accepted as an alias since that's
 * the literal Jira field name and the natural reach for anyone who knows the
 * API. If both are given, `--title` wins — it's the documented flag, so this
 * is the least-surprising resolution (no error; --summary is a pure
 * alias, not a distinct value to reconcile).
 */
export function resolveTitle(opts: { title?: string; summary?: string }): string {
  const title = opts.title ?? opts.summary;
  if (title === undefined) {
    throw new Error('Create requires --title (or --summary)');
  }
  return title;
}

export function registerCreate(program: Command): void {
  program
    .command('create')
    .description('Create a Jira issue')
    .requiredOption('--type <type>', 'Issue type: Epic, Story, Task, Subtask')
    .option('--title <title>', 'Issue summary (required; alias: --summary)')
    .option(
      '--summary <summary>',
      "Issue summary — alias for --title (Jira's own field name). If both are given, --title wins.",
    )
    .option('--desc <desc>', 'Description (markdown supported)')
    .option(
      '--desc-file <path>',
      'Read the markdown description from a file (overrides --desc; keeps the ' +
        'shell command single-line for multi-line descriptions)',
    )
    .option('--adf-file <path>', 'Path to pre-built ADF JSON document (overrides --desc)')
    .option('--parent <key>', 'Parent issue key')
    .option('--labels <labels>', 'Comma-separated labels to set (e.g. a,b)')
    .option(
      '--fix-version <name>',
      "Set the fixVersion (validated against the project's versions; overridden by the v1 bug freeze when it applies)",
    )
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--attach <path>', 'File to attach (repeatable)', collect, [])
    .action(
      async (options: {
        type: string;
        title?: string;
        summary?: string;
        desc?: string;
        descFile?: string;
        adfFile?: string;
        parent?: string;
        labels?: string;
        fixVersion?: string;
        project?: string;
        attach: string[];
      }) => {
        const fields: Record<string, unknown> = {
          project: { key: options.project ?? projectKey() },
          summary: resolveTitle(options),
          issuetype: { name: options.type },
        };
        if (options.adfFile) {
          let adfBody: unknown;
          try {
            adfBody = JSON.parse(readFileSync(options.adfFile, 'utf8'));
          } catch (e) {
            console.error(`jira: cannot read --adf-file "${options.adfFile}": ${(e as Error).message}`);
            process.exit(1);
          }
          fields['description'] = adfBody;
        } else if (options.descFile) {
          fields['description'] = markdownToAdf(readBodyFile(options.descFile, '--desc-file'));
        } else if (options.desc) {
          fields['description'] = markdownToAdf(options.desc);
        }
        if (options.parent) fields['parent'] = { key: options.parent };
        const labels = options.labels !== undefined ? parseLabels(options.labels) : undefined;
        if (labels) fields['labels'] = labels;
        if (options.fixVersion !== undefined) {
          await assertVersionExists(options.project ?? projectKey(), options.fixVersion);
          fields['fixVersions'] = [{ name: options.fixVersion }];
        }
        // The v1 bug freeze (HIMMEL-3411) overrides any explicit --fix-version
        // on a post-cutoff Bug without the blocker label — freeze wins by design.
        const frozenTo = freezeFixVersion(options.type, labels, todayIso());
        if (frozenTo) {
          fields['fixVersions'] = [{ name: frozenTo }];
          // stderr: stdout stays the bare `Created KEY` line scripted callers capture.
          console.error(
            `jira: bug freeze (after ${BUG_FREEZE.cutoff}): fixVersion ${frozenTo}; ` +
              `label ${BUG_FREEZE.blockerLabel} to keep it in ${BUG_FREEZE.v1Version}`,
          );
        }

        const result = await request<CreateIssueResponse>('POST', '/issue', { fields });
        // Breadcrumb BEFORE attachments (same rationale as comment): the issue
        // exists even if a later attachment upload fails (HIMMEL-618 F11).
        writeJiraBreadcrumb(result.key);

        // Print the issue key to STDOUT immediately on success, BEFORE
        // attempting attachments. Scripted callers like
        //   KEY=$(jira create ... --attach foo)
        // capture stdout — if attachments fail and we exit 1, the key
        // has already been emitted so the caller still has it. The
        // attachment-failure message goes to stderr.
        console.log(`Created ${result.key}`);

        const attachments = options.attach ?? [];
        if (attachments.length === 0) return;
        try {
          const n = await uploadAll(result.key, attachments);
          console.error(`  attachments: ${n}`);
        } catch (e) {
          console.error(`Created ${result.key} but attachment failed: ${(e as Error).message}`);
          process.exit(1);
        }
      },
    );
}
