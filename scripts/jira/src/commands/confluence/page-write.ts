import type { Command } from 'commander';
import { confluenceV2, resolveSpaceId } from '../../client.js';
import { markdownToAdf } from '../../adf.js';
import { readBodyFile } from '../body-file.js';

type Adf = ReturnType<typeof markdownToAdf>;

export function buildCreateBody(p: { spaceId: string; title: string; adf: Adf; parentId?: string }): Record<string, unknown> {
  const body: Record<string, unknown> = {
    spaceId: p.spaceId, status: 'current', title: p.title,
    body: { representation: 'atlas_doc_format', value: JSON.stringify(p.adf) },
  };
  if (p.parentId) body.parentId = p.parentId;
  return body;
}

export function buildUpdateBody(p: { id: string; currentVersion: number; title: string; adf?: Adf }): Record<string, unknown> {
  const body: Record<string, unknown> = {
    id: p.id, status: 'current', title: p.title, version: { number: p.currentVersion + 1 },
  };
  if (p.adf) body.body = { representation: 'atlas_doc_format', value: JSON.stringify(p.adf) };
  return body;
}

interface PageMeta { title: string; version?: { number: number } }

export function registerPageWrite(page: Command): void {
  page.command('create')
    .description('Create a Confluence page (body from markdown file)')
    .requiredOption('--space <key>', 'Space key')
    .requiredOption('--title <t>', 'Page title')
    .requiredOption('--body-file <path>', 'Markdown body file (converted to ADF)')
    .option('--parent <id>', 'Parent page id')
    .action(async (opts: { space: string; title: string; bodyFile: string; parent?: string }) => {
      const spaceId = await resolveSpaceId(opts.space);
      const adf = markdownToAdf(readBodyFile(opts.bodyFile, '--body-file'));
      const r = await confluenceV2<{ id: string }>('POST', '/pages',
        buildCreateBody({ spaceId, title: opts.title, adf, parentId: opts.parent }));
      console.log(`Created page ${r.id}`);
    });
  page.command('update <id>')
    .description('Update a Confluence page (auto version-bump)')
    .option('--title <t>', 'New title (defaults to existing)')
    .option('--body-file <path>', 'New markdown body file')
    .action(async (id: string, opts: { title?: string; bodyFile?: string }) => {
      if (opts.title === undefined && opts.bodyFile === undefined) {
        console.error('page update requires --title and/or --body-file');
        process.exit(1);
      }
      const cur = await confluenceV2<PageMeta>('GET', `/pages/${id}`);
      // Don't fabricate a version: a wrong number → opaque 409. Fail clearly.
      const currentVersion = cur.version?.number;
      if (currentVersion === undefined) {
        throw new Error(`could not determine current version of page ${id}`);
      }
      const adf = opts.bodyFile ? markdownToAdf(readBodyFile(opts.bodyFile, '--body-file')) : undefined;
      await confluenceV2('PUT', `/pages/${id}`, buildUpdateBody({
        id, currentVersion, title: opts.title ?? cur.title, adf,
      }));
      console.log(`Updated page ${id}`);
    });
  page.command('delete <id>')
    .description('Delete (trash) a Confluence page')
    .action(async (id: string) => {
      await confluenceV2('DELETE', `/pages/${id}`);
      console.log(`Deleted page ${id}`);
    });
}
