import type { Command } from 'commander';
import { confluenceV2 } from '../../client.js';
import { adfToPlainText } from '../../adf-render.js';

export function pageGetPath(id: string): string {
  return `/pages/${id}?body-format=atlas_doc_format`;
}

interface PageV2 {
  id: string; title: string; spaceId: string;
  version?: { number: number };
  body?: { atlas_doc_format?: { value: string } };
  _links?: { webui?: string };
}

export function registerPageGet(page: Command): void {
  page.command('get <id>')
    .description('Get a Confluence page (renders body as text)')
    .action(async (id: string) => {
      const p = await confluenceV2<PageV2>('GET', pageGetPath(id));
      console.log(`# ${p.title}`);
      console.log(`id=${p.id} space=${p.spaceId} version=${p.version?.number ?? '?'}`);
      const raw = p.body?.atlas_doc_format?.value;
      if (raw) console.log('\n' + adfToPlainText(JSON.parse(raw)));
    });
}
