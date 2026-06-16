import type { Command } from 'commander';
import { request } from '../client.js';
import { formatIssue, formatIssueWithDescription, printJson } from '../output.js';
import type { JiraIssue } from '../types.js';

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
      let issue: JiraIssue;
      try {
        issue = await request<JiraIssue>(
          'GET',
          `/issue/${key}?fields=summary,status,issuetype,parent,assignee,description`,
        );
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        process.stderr.write(`jira: get ${key} failed: ${msg}\n`);
        process.exit(1);
      }
      if (options.json) {
        printJson(issue);
      } else if (options.short) {
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
      }
    });
}
