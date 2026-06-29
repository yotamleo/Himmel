import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';

interface IssueLinkType {
  name: string;
}

/**
 * Case-insensitive match of a requested link-type name against the available
 * Jira issue-link types. Mirrors findTransition() — keeps the I/O out of the
 * matcher so it's unit-testable.
 */
export function findLinkType(
  types: IssueLinkType[],
  name: string,
): IssueLinkType | undefined {
  return types.find((t) => t.name.toLowerCase() === name.toLowerCase());
}

export function registerLink(program: Command): void {
  program
    .command('link <inwardKey> <outwardKey>')
    .description('Create an issue link between two issues')
    .option(
      '--type <type>',
      'Link type name (Relates, Blocks, Duplicate, Cloners)',
      'Relates',
    )
    .action(
      async (inwardKey: string, outwardKey: string, opts: { type: string }) => {
        // Validate the type up front so an unknown --type yields the list of
        // valid types instead of a raw 404 from the create call.
        const { issueLinkTypes } = await request<{
          issueLinkTypes: IssueLinkType[];
        }>('GET', '/issueLinkType');
        const match = findLinkType(issueLinkTypes, opts.type);
        if (!match) {
          console.error(`Link type "${opts.type}" not found. Available:`);
          for (const t of issueLinkTypes) console.error(`- ${t.name}`);
          process.exit(1);
        }
        // inwardKey/outwardKey map directly to Jira's inwardIssue/outwardIssue.
        // Directionality is whatever Jira defines for the type (e.g. for
        // "Blocks", outwardIssue blocks inwardIssue). Relates is symmetric.
        await request('POST', '/issueLink', {
          type: { name: match.name },
          inwardIssue: { key: inwardKey },
          outwardIssue: { key: outwardKey },
        });
        writeJiraBreadcrumb(inwardKey);
        console.log(`Linked ${inwardKey} ${match.name} ${outwardKey}`);
      },
    );
}
