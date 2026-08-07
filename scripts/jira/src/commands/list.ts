import type { Command } from 'commander';
import { request, projectKey } from '../client.js';
import { formatIssue } from '../output.js';
import type { JiraIssue, JiraSearchResult } from '../types.js';

const DEFAULT_STATUSES = ['To Do', 'In Progress'];

/**
 * Build a JQL `status in (...)` clause from a CLI --status arg.
 *
 * HIMMEL-112: pre-fix, the CLI interpolated --status verbatim into JQL,
 * which broke on multi-word values (`status in (To Do)` → JQL parse error
 * because `To` is taken as a JQL keyword/value boundary). Even the CLI's
 * own --help-documented default value `"To Do","In Progress"` worked ONLY
 * because it was already pre-quoted in the source; any operator-supplied
 * value triggered the bug.
 *
 * Now: split on comma, trim, drop empties, JQL-quote each token, join with
 * commas. Inner double-quotes are backslash-escaped per JQL spec.
 */
export function jqlStatusClause(statusArg: string | undefined): string {
  const parts = statusArg !== undefined && statusArg.length > 0
    ? statusArg.split(',').map((s) => s.trim()).filter((s) => s.length > 0)
    : DEFAULT_STATUSES;
  if (parts.length === 0) {
    // Empty after trim/filter (e.g. `--status ","`). Fall back to defaults
    // rather than emitting `status in ()` which would be a JQL syntax error.
    parts.push(...DEFAULT_STATUSES);
  }
  const quoted = parts.map((s) => `"${s.replace(/"/g, '\\"')}"`).join(',');
  return `status in (${quoted})`;
}

/** Inputs to {@link resolveListJql}. */
export interface ListJqlOptions {
  jql?: string;
  project?: string;
  type?: string;
  status?: string;
  label?: string;
}

/**
 * Resolve the JQL to query.
 *
 * HIMMEL-215: when `--jql` is supplied, pass it through verbatim — this is
 * the arbitrary-search escape hatch that the block-mcp hook points
 * `searchJiraIssuesUsingJql` at, so it must support any JQL the operator
 * writes (cross-status, free-text, ORDER BY, etc.) without the CLI adding
 * project/status/type clauses on top. An empty or whitespace-only `--jql`
 * is treated as not supplied (mirrors `jqlStatusClause`'s trim-then-default).
 * Without `--jql`, behaviour is unchanged: build
 * `project AND status [AND issuetype] [AND labels] ORDER BY created`.
 *
 * HIMMEL-243: `--label` composes a `labels = "<l>"` clause into the built
 * JQL alongside the project/status/type filters. Precedence matches the
 * existing flags: `--jql` still wins — when supplied, `--label` (like
 * `--project`/`--type`/`--status`) is ignored. An empty or whitespace-only
 * `--label` is treated as not supplied (mirrors the `--jql` trim behaviour).
 */
export function resolveListJql(options: ListJqlOptions): string {
  const rawJql = options.jql?.trim();
  if (rawJql !== undefined && rawJql.length > 0) {
    return rawJql;
  }
  const proj = options.project ?? projectKey();
  let jql = `project=${proj} AND ${jqlStatusClause(options.status)}`;
  if (options.type) jql += ` AND issuetype="${options.type}"`;
  const label = options.label?.trim();
  if (label !== undefined && label.length > 0) {
    jql += ` AND labels = "${label.replace(/"/g, '\\"')}"`;
  }
  jql += ' ORDER BY created DESC';
  return jql;
}

/** Jira Cloud `/search/jql` hard-caps a single page at 100 (HIMMEL-1602). */
const PAGE_MAX = 100;

/**
 * Fetch up to `limit` issues, following `nextPageToken` as needed.
 *
 * Why this exists: the endpoint SILENTLY clamps `maxResults` to 100 — asking
 * for 999 returned exactly 100 with no error and no indication more existed,
 * so every count taken through this CLI was quietly truncated. A consolidation
 * pass read "100 open tickets" when the real figure was 389.
 *
 * A non-numeric or non-positive `--limit` falls back to the default rather
 * than sending garbage to Jira or looping forever.
 */
export async function searchAllIssues(
  jql: string,
  limit: string,
  req: typeof request,
): Promise<JiraIssue[]> {
  const want = Number.parseInt(limit, 10);
  const target = Number.isFinite(want) && want > 0 ? want : 25;

  const issues: JiraIssue[] = [];
  let token: string | undefined;
  // Guard against a Jira cursor that does not advance: a repeated nextPageToken
  // paired with non-empty pages would otherwise loop forever, pushing duplicate
  // issues until `target`. Track consumed tokens and fail loud on a repeat
  // (HIMMEL-1624).
  const seenTokens = new Set<string>();

  do {
    if (token !== undefined) {
      if (seenTokens.has(token)) {
        throw new Error(
          `jira list: pagination loop detected — nextPageToken "${token}" repeated by the API`,
        );
      }
      seenTokens.add(token);
    }
    const page = Math.min(PAGE_MAX, target - issues.length);
    const cursor = token === undefined ? '' : `&nextPageToken=${encodeURIComponent(token)}`;
    const result = await req<JiraSearchResult>(
      'GET',
      `/search/jql?jql=${encodeURIComponent(jql)}&fields=summary,status,issuetype&maxResults=${page}${cursor}`,
    );
    issues.push(...result.issues);
    token = result.nextPageToken;
    // A page that returns nothing ends the walk even if a token came back —
    // without this an empty-but-tokened page would spin forever.
    if (result.issues.length === 0) break;
  } while (token !== undefined && issues.length < target);

  return issues.slice(0, target);
}

export function registerList(program: Command): void {
  program
    .command('list')
    .description('List Jira issues')
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY)')
    .option('--type <type>', 'Filter by issue type (Epic, Story, Task, Subtask)')
    .option(
      '--status <status>',
      'Comma-separated status filter (default: "To Do,In Progress")',
    )
    .option('--label <label>', 'Filter by a single label (composed into the built JQL)')
    .option(
      '--jql <jql>',
      'Raw JQL passthrough (overrides --project/--type/--status/--label)',
    )
    .option('--limit <n>', 'Max results (paged automatically above 100)', '25')
    .action(
      async (options: ListJqlOptions & { limit: string }) => {
        const jql = resolveListJql(options);
        for (const issue of await searchAllIssues(jql, options.limit, request)) {
          console.log(formatIssue(issue));
        }
      },
    );
}
