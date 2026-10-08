import type { Command } from 'commander';
import { request, severityField } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import { markdownToAdf } from '../adf.js';
import { readBodyFile } from './body-file.js';
import { parseLabels } from './labels.js';
import { assertVersionExists, buildFixVersionBody, projectFromKey } from './versions.js';

export interface EditOptions {
  priority?: string;
  severity?: string;
  title?: string;
  description?: string;
  parent?: string;
  labels?: string;
  addLabels?: string;
  fixVersion?: string;
  addFixVersion?: string;
}

export function buildEditFields(opts: EditOptions): Record<string, unknown> {
  if (opts.labels !== undefined && opts.addLabels !== undefined) {
    throw new Error(
      'Edit --labels and --add-labels are mutually exclusive: --labels replaces the full ' +
        'label set, --add-labels appends to it — pick one.',
    );
  }
  if (opts.fixVersion !== undefined && opts.addFixVersion !== undefined) {
    throw new Error(
      'Edit --fix-version and --add-fix-version are mutually exclusive: --fix-version replaces ' +
        'the full fixVersion set, --add-fix-version appends to it — pick one.',
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
  // --labels is FULL-REPLACE (HIMMEL-243): the comma-separated set becomes
  // the issue's complete label list — any existing label not in the set is
  // removed. Use --add-labels (HIMMEL-3610) for an incremental, non-destructive
  // append instead.
  if (opts.labels !== undefined) fields['labels'] = parseLabels(opts.labels);
  // --fix-version is FULL-REPLACE, same rationale as --labels: a single-valued
  // field the operator explicitly wants set. --add-fix-version (HIMMEL-3713)
  // appends via Jira's atomic `update` operation instead.
  if (opts.fixVersion !== undefined) fields['fixVersions'] = [{ name: opts.fixVersion }];
  if (
    Object.keys(fields).length === 0 &&
    opts.addLabels === undefined &&
    opts.addFixVersion === undefined
  ) {
    throw new Error(
      'Edit requires at least one of --priority, --severity, --title, --desc, --parent, ' +
        '--labels, --add-labels, --fix-version, or --add-fix-version',
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

// Jira field names edit sends, in read-back order (HIMMEL-4644).
function readBackFieldNames(o: EditOptions): string[] {
  const names: string[] = [];
  if (o.priority) names.push('priority');
  if (o.severity) {
    const sev = severityField();
    if (sev) names.push(sev);
  }
  if (o.title !== undefined) names.push('summary');
  if (o.description !== undefined) names.push('description');
  if (o.parent) names.push('parent');
  if (o.labels !== undefined || o.addLabels !== undefined) names.push('labels');
  if (o.fixVersion !== undefined || o.addFixVersion !== undefined) names.push('fixVersions');
  return [...new Set(names)];
}

// Plain text of an ADF node: every `text` leaf, whitespace collapsed. Jira
// normalises ADF on save, so descriptions are compared as text, not structure.
function adfText(node: unknown): string {
  const walk = (n: unknown): string => {
    if (!n || typeof n !== 'object') return '';
    const o = n as { text?: unknown; content?: unknown };
    const own = typeof o.text === 'string' ? o.text : '';
    const kids = Array.isArray(o.content) ? o.content.map(walk).join('') : '';
    return own + kids;
  };
  return walk(node).replace(/\s+/g, ' ').trim();
}

// Returns one message per sent field whose read-back value differs.
function verifyReadBack(
  key: string,
  o: EditOptions,
  sent: Record<string, unknown>,
  got: Record<string, unknown>,
): string[] {
  const out: string[] = [];
  const bad = (label: string, requested: string, actual: string | undefined): void => {
    out.push(
      `Edit ${key}: ${label} was not changed — requested '${requested}' but the issue ` +
        `still reads '${actual || 'none'}' after the PUT.`,
    );
  };
  const same = (a: string | undefined, b: string): boolean => a?.toLowerCase() === b.toLowerCase();
  const labels = Array.isArray(got['labels']) ? (got['labels'] as string[]) : [];
  const versions = Array.isArray(got['fixVersions'])
    ? (got['fixVersions'] as Array<{ name?: string }>).map((v) => v.name ?? '')
    : [];

  if (o.priority) {
    const actual = (got['priority'] as { name?: string } | null | undefined)?.name;
    if (!same(actual, o.priority)) bad('priority', o.priority, actual);
  }
  const sev = severityField();
  if (o.severity && sev) {
    const actual = (got[sev] as { value?: string } | null | undefined)?.value;
    if (!same(actual, o.severity)) bad('severity', o.severity, actual);
  }
  if (o.title !== undefined) {
    const actual = got['summary'] as string | undefined;
    if (actual?.trim() !== o.title.trim()) bad('title', o.title, actual);
  }
  if (o.description !== undefined) {
    const want = adfText(sent['description']);
    const actual = adfText(got['description']);
    if (actual !== want) bad('description', want, actual);
  }
  if (o.parent) {
    const actual = (got['parent'] as { key?: string } | null | undefined)?.key;
    if (!same(actual, o.parent)) bad('parent', o.parent, actual);
  }
  if (o.labels !== undefined) {
    const want = parseLabels(o.labels);
    if (want.length !== new Set(labels).size || !want.every((l) => labels.includes(l))) {
      bad('labels', want.join(', '), labels.join(', '));
    }
  }
  if (o.addLabels !== undefined) {
    const want = parseLabels(o.addLabels);
    if (!want.every((l) => labels.includes(l))) bad('add-labels', want.join(', '), labels.join(', '));
  }
  if (o.fixVersion !== undefined) {
    if (versions.length !== 1 || versions[0] !== o.fixVersion) {
      bad('fix-version', o.fixVersion, versions.join(', '));
    }
  }
  if (o.addFixVersion !== undefined && !versions.includes(o.addFixVersion)) {
    bad('add-fix-version', o.addFixVersion, versions.join(', '));
  }
  return out;
}

export function registerEdit(program: Command): void {
  program
    .command('edit <key>')
    .description(
      'Edit a Jira issue (priority, severity, title, description, parent, labels, and/or fix version)',
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
    .option(
      '--fix-version <name>',
      'REPLACE the issue fixVersions with this single version (validated against the ' +
        "project's versions; full-replace)",
    )
    .option(
      '--add-fix-version <name>',
      'APPEND this version to fixVersions without touching existing ones ' +
        '(validated against the project\'s versions; mutually exclusive with --fix-version)',
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
      if (options.fixVersion !== undefined) {
        await assertVersionExists(projectFromKey(key), options.fixVersion);
      }
      if (options.addFixVersion !== undefined) {
        await assertVersionExists(projectFromKey(key), options.addFixVersion);
      }
      const body: { fields?: Record<string, unknown>; update?: Record<string, unknown> } = {};
      if (Object.keys(fields).length > 0) body.fields = fields;
      const update: Record<string, unknown> = {};
      if (options.addLabels !== undefined) {
        Object.assign(update, buildAddLabelsUpdate(options.addLabels));
      }
      if (options.addFixVersion !== undefined) {
        Object.assign(update, buildFixVersionBody('add', options.addFixVersion).update);
      }
      if (Object.keys(update).length > 0) body.update = update;
      await request('PUT', `/issue/${key}`, body);
      // HIMMEL-4640: a 2xx PUT does not prove the field changed (Jira can drop a
      // field its edit screen or scheme does not take), so read the priority
      // back and fail loud instead of reporting a silent no-op as "edited".
      // HIMMEL-4644: same for every other field edit sends — one GET covers all.
      const names = readBackFieldNames(options);
      if (names.length > 0) {
        const got = await request<{ fields?: Record<string, unknown> }>(
          'GET',
          `/issue/${key}?fields=${names.join(',')}`,
        );
        const mismatches = verifyReadBack(key, options, fields, got.fields ?? {});
        if (mismatches.length > 0) throw new Error(mismatches.join('\n'));
      }
      writeJiraBreadcrumb(key);
      console.log(`${key} edited`);
    });
}
