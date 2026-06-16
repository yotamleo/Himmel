import { adfToPlainText } from './adf-render.js';
import type { JiraIssue } from './types.js';

export function formatIssue(issue: JiraIssue): string {
  return [
    issue.key,
    issue.fields.issuetype.name,
    issue.fields.status.name,
    issue.fields.summary,
  ].join('\t');
}

// formatIssueWithDescription — header line (formatIssue output) plus a
// blank line plus the description rendered as plain text. Used by
// `get` so callers/Claude can read the issue body inline. `list` stays
// on formatIssue (one tab-separated line per issue) to keep output
// scannable. Description-less issues just emit the header line.
export function formatIssueWithDescription(issue: JiraIssue): string {
  const header = formatIssue(issue);
  const body = adfToPlainText(issue.fields.description);
  if (!body) return header;
  return `${header}\n\n${body}`;
}

export function printJson(data: unknown): void {
  console.log(JSON.stringify(data, null, 2));
}
