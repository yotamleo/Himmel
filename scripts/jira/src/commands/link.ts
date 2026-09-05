import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';

interface IssueLinkType {
  name: string;
}

interface IssueLink {
  id: string;
  type: {
    name: string;
    inward: string;
    outward: string;
  };
  inwardIssue?: { key: string };
  outwardIssue?: { key: string };
}

interface IssueLinksResponse {
  fields: {
    issuelinks?: IssueLink[];
  };
}

type RequestFn = (
  method: string,
  path: string,
  body?: unknown,
) => Promise<unknown>;

interface DirectedIssueLink {
  link: IssueLink;
  inwardKey: string;
  outwardKey: string;
  currentSide: 'inward' | 'outward';
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

function directedIssueLink(
  currentKey: string,
  link: IssueLink,
): DirectedIssueLink | undefined {
  if (link.outwardIssue) {
    return {
      link,
      inwardKey: currentKey,
      outwardKey: link.outwardIssue.key,
      currentSide: 'inward',
    };
  }
  if (link.inwardIssue) {
    return {
      link,
      inwardKey: link.inwardIssue.key,
      outwardKey: currentKey,
      currentSide: 'outward',
    };
  }
  return undefined;
}

function formatDirectedIssueLink(currentKey: string, candidate: DirectedIssueLink): string {
  const { link, inwardKey, outwardKey, currentSide } = candidate;
  const otherKey = currentSide === 'inward' ? outwardKey : inwardKey;
  const relation = currentSide === 'inward' ? link.type.inward : link.type.outward;
  return `${link.id}\t${link.type.name}\tinward=${inwardKey}\toutward=${outwardKey}\t${currentKey} ${relation} ${otherKey}`;
}

export function formatIssueLinks(currentKey: string, links: IssueLink[]): string {
  const candidates = links
    .map((link) => directedIssueLink(currentKey, link))
    .filter((link): link is DirectedIssueLink => link !== undefined);
  if (!candidates.length) return `${currentKey}: no issue links`;
  return candidates
    .map((candidate) => formatDirectedIssueLink(currentKey, candidate))
    .join('\n');
}

function sameIssueKey(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function resolveIssueLink(
  links: IssueLink[],
  inwardKey: string,
  outwardKey: string,
  type?: string,
): DirectedIssueLink {
  const matches = links
    .map((link) => directedIssueLink(inwardKey, link))
    .filter((link): link is DirectedIssueLink => link !== undefined)
    .filter((candidate) =>
      sameIssueKey(candidate.inwardKey, inwardKey) &&
      sameIssueKey(candidate.outwardKey, outwardKey) &&
      (type === undefined || candidate.link.type.name.toLowerCase() === type.toLowerCase()),
    );
  const qualifier = type === undefined ? '' : `, type=${type}`;
  if (!matches.length) {
    throw new Error(
      `No issue link found with inward=${inwardKey}, outward=${outwardKey}${qualifier}.`,
    );
  }
  if (matches.length > 1) {
    const candidates = matches
      .map((candidate) => formatDirectedIssueLink(inwardKey, candidate))
      .join('\n');
    throw new Error(
      `Multiple issue links match inward=${inwardKey}, outward=${outwardKey}${qualifier}; refusing to delete:\n${candidates}`,
    );
  }
  return matches[0];
}

export async function unlinkIssueLink(
  inwardKey: string,
  outwardKey: string,
  type?: string,
  requestFn: RequestFn = request,
): Promise<IssueLink> {
  const issue = await requestFn(
    'GET',
    `/issue/${inwardKey}?fields=issuelinks`,
  ) as IssueLinksResponse;
  const match = resolveIssueLink(
    issue.fields.issuelinks ?? [],
    inwardKey,
    outwardKey,
    type,
  );
  await requestFn('DELETE', `/issueLink/${match.link.id}`);
  return match.link;
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

  program
    .command('links <key>')
    .description('List issue links with canonical inward/outward direction')
    .action(async (key: string) => {
      const issue = await request<IssueLinksResponse>(
        'GET',
        `/issue/${key}?fields=issuelinks`,
      );
      console.log(formatIssueLinks(key, issue.fields.issuelinks ?? []));
    });

  program
    .command('unlink <inwardKey> <outwardKey>')
    .description('Delete exactly one directed issue link')
    .option('--type <type>', 'Link type name used to disambiguate the pair')
    .action(async (
      inwardKey: string,
      outwardKey: string,
      opts: { type?: string },
    ) => {
      const deleted = await unlinkIssueLink(inwardKey, outwardKey, opts.type);
      writeJiraBreadcrumb(inwardKey);
      console.log(
        `Unlinked inward=${inwardKey} outward=${outwardKey} type=${deleted.type.name} id=${deleted.id}`,
      );
    });
}
