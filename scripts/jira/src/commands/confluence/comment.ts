import type { Command } from 'commander';
import { confluenceV2 } from '../../client.js';
import { markdownToAdf } from '../../adf.js';
import { readBodyFile } from '../body-file.js';
import { adfToPlainText } from '../../adf-render.js';

type Adf = ReturnType<typeof markdownToAdf>;

export function buildCommentBody(pageId: string, adf: Adf): Record<string, unknown> {
  return { pageId, body: { representation: 'atlas_doc_format', value: JSON.stringify(adf) } };
}

interface CommentV2 { id: string; body?: { atlas_doc_format?: { value: string } } }

export function registerComment(program: Command): void {
  program.command('comments <pageId>')
    .description('List footer comments on a page')
    .action(async (pageId: string) => {
      const r = await confluenceV2<{ results: CommentV2[] }>(
        'GET', `/pages/${pageId}/footer-comments?body-format=atlas_doc_format`);
      for (const c of r.results ?? []) {
        const raw = c.body?.atlas_doc_format?.value;
        console.log(`--- ${c.id} ---`);
        if (raw) console.log(adfToPlainText(JSON.parse(raw)));
      }
    });
  program.command('comment <pageId> [text]')
    .description('Add a footer comment to a page (markdown)')
    .option('--body-file <path>', 'Markdown comment file (overrides [text])')
    .action(async (pageId: string, text: string | undefined, opts: { bodyFile?: string }) => {
      const md = opts.bodyFile ? readBodyFile(opts.bodyFile, '--body-file') : text;
      if (md === undefined) { console.error('comment requires [text] or --body-file'); process.exit(1); }
      const r = await confluenceV2<{ id: string }>('POST', '/footer-comments',
        buildCommentBody(pageId, markdownToAdf(md)));
      console.log(`Added comment ${r.id} to page ${pageId}`);
    });
}
