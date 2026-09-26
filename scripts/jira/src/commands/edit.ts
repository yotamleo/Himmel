import type { Command } from 'commander';
import { request, severityField } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import { readBodyFile } from './body-file.js';
import { parseLabels } from './labels.js';

export interface EditOptions {
  priority?: string;
  severity?: string;
  title?: string;
  description?: string;
  parent?: string;
  labels?: string;
  addLabels?: string;
}

export function buildEditFields(opts: EditOptions): Record<string, unknown> {
  if (opts.labels !== undefined && opts.addLabels !== undefined) {
    throw new Error(
      'Edit --labels and --add-labels are mutually exclusive: --labels replaces the full ' +
        'label set, --add-labels appends to it — pick one.',
    );
  }
  const fields: Record<string, unknown> = {};
  if (opts.priority) fields['priority'] = { name: opts.priority };
  if (opts.severity) {
    const field = severityField();
    if (!field) {
      throw new Error(
        'Edit --severity requires the JIRA_SEVERITY_FIELD env var to name the ' +
          'custom field ID (e.g. customfield_10016). Set it in .env and retry.',
      );
    }
    fields[field] = { value: opts.severity };
  }
  // Jira's REST field name is `summary`; the CLI surfaces it as `--title`
  // because that's what every other ticket-system surface (GitHub PRs, gh CLI,
  // the create subcommand) calls it. Same string, different name.
  if (opts.title !== undefined) fields['summary'] = opts.title;
  // Description must be ADF (Atlassian Document Format). Pipe through the
  // shared markdownToAdf converter so `--desc` accepts plain markdown like
  // every other description-bearing subcommand.
  if (opts.description !== undefined) fields['description'] = markdownToAdf(opts.description);
  // Re-parent under an epic (or convert to/from a child). Mirrors
  // `create --parent`: Jira's field is `parent: { key }`. Closes the gap
  // that otherwise forced an MCP editJiraIssue fallback (blocked by the
  // plugin-first hook).
  if (opts.parent) fields['parent'] = { key: opts.parent };
  // Labels are FULL-REPLACE (HIMMEL-243): the comma-separated set becomes
  // the issue's complete label list — any existing label not in the set is
  // removed. Deliberately no --add-label/--remove-label incremental ops.
  if (opts.labels !== undefined) fields['labels'] = parseLabels(opts.labels);
  if (Object.keys(fields).length === 0 && opts.addLabels === undefined) {
    throw new Error(
      'Edit requires at least one of --priority, --severity, --title, --desc, --parent, ' +
        '--labels, or --add-labels',
    );
  }
  return fields;
}

// Jira's atomic `update` operation for labels (HIMMEL-3610): unlike `fields.labels`
// (full-replace), `update.labels: [{ add: '<label>' }, ...]` appends without ever
// reading or replacing the issue's existing label set.
export function buildAddLabelsUpdate(addLabels: string): { labels: Array<{ add: string }> } {
  return { labels: parseLabels(addLabels).map((label) => ({ add: label })) };
}

export function registerEdit(program: Command): void {
  program
    .command('edit <key>')
    .description(
      'Edit a Jira issue (priority, severity, title, description, parent, and/or labels)',
    )
    .option('--priority <p>', 'Priority: Highest|High|Medium|Low|Lowest')
    .option('--severity <s>', 'Severity (custom field): free text')
    .option('--title <t>', 'New summary/title (plain text)')
    .option(
      '--desc <d>',
      'New description (markdown; converted to ADF). Alias of --description.',
    )
    .option('--description <d>', 'New description (markdown; converted to ADF)')
    .option(
      '--desc-file <path>',
      'Read the markdown description from a file (overrides --desc/--description; ' +
        'keeps the shell command single-line for multi-line descriptions)',
    )
    .option('--parent <key>', 'Parent issue key (e.g. epic) — re-parents the issue')
    .option(
      '--labels <labels>',
      'REPLACE the issue labels with this comma-separated set (full-replace: ' +
        'existing labels not listed are removed)',
    )
    .option(
      '--add-labels <labels>',
      'APPEND these comma-separated labels without touching existing ones ' +
        '(mutually exclusive with --labels)',
    )
    .action(async (key: string, options: EditOptions & { desc?: string; descFile?: string }) => {
      // `--desc` and `--description` are aliases; whichever the operator
      // passed wins (and if both, --description wins because it's parsed
      // last by commander's option-order). `--desc-file` overrides both — it
      // is the escape hatch for multi-line bodies that can't go inline.
      if (options.descFile !== undefined) {
        options.description = readBodyFile(options.descFile, '--desc-file');
      } else if (options.desc !== undefined && options.description === undefined) {
        options.description = options.desc;
      }
      const fields = buildEditFields(options);
      const body: { fields?: Record<string, unknown>; update?: ReturnType<typeof buildAddLabelsUpdate> } = {};
      if (Object.keys(fields).length > 0) body.fields = fields;
      if (options.addLabels !== undefined) body.update = buildAddLabelsUpdate(options.addLabels);
      await request('PUT', `/issue/${key}`, body);
      writeJiraBreadcrumb(key);
      console.log(`${key} edited`);
    });
}
