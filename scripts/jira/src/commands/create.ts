import { readFileSync } from 'node:fs';
import type { Command } from 'commander';
import { request, projectKey } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import type { CreateIssueResponse } from '../types.js';
import { uploadAll } from './attach-helper.js';
import { readBodyFile } from './body-file.js';
import { parseLabels } from './labels.js';
import { homeVerdict, lintPlainBlock, lintPlainBlockAdf, plainBlockVerdict, PLAIN_BLOCK_TEMPLATE } from '../plain-block.js';
import { SECTOR_FIELD, resolveSector } from './sector.js';
import { assertVersionExists, earliestUnreleased, fetchVersions } from './versions.js';

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
    .option('--labels <labels>', 'Comma-separated labels to set (e.g. a,b); `standalone` marks a ticket with no parent epic')
    .option('--sector <s>', 'Sector (single-select custom field; required for a Task, Story or Bug)')
    .option(
      '--fix-version <name>',
      "Set the fixVersion (validated against the project's versions; an explicit value wins over the Bug default of the earliest unreleased version)",
    )
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY env var)')
    .option('--attach <path>', 'File to attach (repeatable)', collect, [])
    .option(
      '--skeleton',
      'Print the four-heading body (Impact, What, Why, Agent detail) to fill, then exit; creates nothing',
    )
    .action(
      async (options: {
        skeleton?: boolean;
        type: string;
        title?: string;
        summary?: string;
        desc?: string;
        descFile?: string;
        adfFile?: string;
        parent?: string;
        labels?: string;
        sector?: string;
        fixVersion?: string;
        project?: string;
        attach: string[];
      }) => {
        if (options.skeleton) {
          console.log(PLAIN_BLOCK_TEMPLATE);
          return;
        }
        const fields: Record<string, unknown> = {
          project: { key: options.project ?? projectKey() },
          summary: resolveTitle(options),
          issuetype: { name: options.type },
        };
        let found: string[];
        if (options.adfFile) {
          let adfBody: unknown;
          try {
            adfBody = JSON.parse(readFileSync(options.adfFile, 'utf8'));
          } catch (e) {
            console.error(`jira: cannot read --adf-file "${options.adfFile}": ${(e as Error).message}`);
            process.exit(1);
          }
          fields['description'] = adfBody;
          found = lintPlainBlockAdf(adfBody);
        } else if (options.descFile) {
          const md = readBodyFile(options.descFile, '--desc-file');
          fields['description'] = markdownToAdf(md);
          found = lintPlainBlock(md);
        } else if (options.desc) {
          fields['description'] = markdownToAdf(options.desc);
          found = lintPlainBlock(options.desc);
        } else {
          found = lintPlainBlock('');
        }
        // The plain Impact/What/Why block is required; Epic and Subtask only warn.
        const verdict = plainBlockVerdict(options.type, found);
        if (verdict.action === 'refuse') {
          console.error(verdict.message);
          process.exit(1);
        }
        if (verdict.action === 'warn') console.error(verdict.message);
        const sector = options.sector !== undefined ? resolveSector(options.sector) : undefined;
        const labels = options.labels !== undefined ? parseLabels(options.labels) : undefined;
        // A Sector plus an epic or the standalone label; Epic and Subtask only warn.
        const home = homeVerdict(options.type, { sector, parent: options.parent, labels });
        if (home.action === 'refuse') {
          console.error(home.message);
          process.exit(1);
        }
        if (home.action === 'warn') console.error(home.message);
        if (options.parent) fields['parent'] = { key: options.parent };
        if (labels) fields['labels'] = labels;
        if (sector) fields[SECTOR_FIELD] = { value: sector };
        if (options.fixVersion !== undefined) {
          await assertVersionExists(options.project ?? projectKey(), options.fixVersion);
          fields['fixVersions'] = [{ name: options.fixVersion }];
        }
        // A Bug without an explicit --fix-version defaults to the earliest
        // unreleased version; an unreadable/empty version list files with no
        // fixVersion rather than guess. The release gate is the
        // v1-blocker label and priority, not the version default.
        if (options.fixVersion === undefined && options.type.toLowerCase() === 'bug') {
          let defaultVersion: string | undefined;
          try {
            defaultVersion = earliestUnreleased(await fetchVersions(options.project ?? projectKey()));
          } catch {
            defaultVersion = undefined;
          }
          // stderr: stdout stays the bare `Created KEY` line scripted callers capture.
          if (defaultVersion) {
            fields['fixVersions'] = [{ name: defaultVersion }];
            console.error(`jira: Bug defaults to fixVersion ${defaultVersion} (earliest unreleased); --fix-version overrides`);
          } else {
            console.error('jira: no unreleased version found; filing the Bug with no fixVersion');
          }
        }

        const result = await request<CreateIssueResponse>('POST', '/issue', { fields });
        // Breadcrumb BEFORE attachments (same rationale as comment): the issue
        // exists even if a later attachment upload fails.
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
