import type { Command } from 'commander';
import { request } from '../client.js';
import { formatIssue, formatIssueWithDescription, printJson } from '../output.js';
import type { JiraIssue } from '../types.js';

// Local widening: the get.ts fields query includes `labels` (HIMMEL-3610),
// but the shared JiraIssue type does not declare it — kept local rather than
// touching types.ts, which this ticket's scope excludes.
type IssueWithLabels = JiraIssue & { fields: JiraIssue['fields'] & { labels?: string[] } };

function labelsLine(issue: IssueWithLabels): string | undefined {
  const labels = issue.fields.labels;
  if (!labels || labels.length === 0) return undefined;
  return `Labels: ${labels.join(', ')}`;
}

export function registerGet(program: Command): void {
  program
    .command('get <key>')
    .description('Get a Jira issue (with description body by default)')
    .option('--json', 'Output raw JSON')
    .option(
      '--short',
      'Suppress the description body (one-line header only — backward-compatible with the pre-HIMMEL-121 output)',
    )
    .action(async (key: string, options: { json?: boolean; short?: boolean }) => {
      // Always fetch description from the API — output flag controls
      // display only, so --short still gets the field for --json
      // round-tripping (consistent --json payload shape regardless of
      // which display flag was used).
      let issue: IssueWithLabels;
      try {
        issue = await request<IssueWithLabels>(
          'GET',
          `/issue/${key}?fields=summary,status,issuetype,parent,assignee,description,labels`,
        );
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        process.stderr.write(`jira: get ${key} failed: ${msg}\n`);
        process.exit(1);
      }
      if (options.json) {
        printJson(issue);
      } else if (options.short) {
        // --short is documented as one-line header only (backward-compatible
        // with the pre-HIMMEL-121 output) and is consumed as a single line by
        // scripts/handover/pr-open.sh — never append the labels line here.
        console.log(formatIssue(issue));
      } else {
        // Distinguish "field not returned by API" (undefined — possible
        // when field-level perms hide description from this user) from
        // "issue genuinely has no body" (null). Both render the header,
        // but undefined gets a stderr hint so the operator knows to use
        // --json or check perms.
        if (issue.fields.description === undefined) {
          process.stderr.write(
            `jira: get ${key} returned no description field (field perms? try --json to confirm)\n`,
          );
        }
        console.log(formatIssueWithDescription(issue));
        const ll = labelsLine(issue);
        if (ll) console.log(ll);
      }
    });
}
