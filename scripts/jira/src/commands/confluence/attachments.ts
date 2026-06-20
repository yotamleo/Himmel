import { join, basename } from 'node:path';
import type { Command } from 'commander';
import { confluenceV2, uploadMultipart, downloadTo, baseUrl, confluenceAuthHeader } from '../../client.js';

interface PageAttachment { id: string; title: string; downloadLink: string }

export function pickPageAttachments(list: PageAttachment[], idArg: string | undefined, all: boolean): PageAttachment[] {
  if (all) {
    const names = new Set<string>();
    for (const a of list) {
      if (names.has(a.title)) throw new Error(`duplicate filename "${a.title}" — cannot --all into one dir`);
      names.add(a.title);
    }
    return list;
  }
  if (!idArg) throw new Error('download requires an attachment id or --all');
  const hit = list.find((a) => a.id === idArg);
  if (!hit) throw new Error(`no attachment with id ${idArg} on the page`);
  return [hit];
}

export function registerAttachments(program: Command): void {
  program.command('attachments <pageId>')
    .description('List attachments on a page')
    .action(async (pageId: string) => {
      const r = await confluenceV2<{ results: PageAttachment[] }>('GET', `/pages/${pageId}/attachments`);
      for (const a of r.results ?? []) console.log(`${a.id}\t${a.title}`);
    });
  program.command('attach <pageId> <paths...>')
    .description('Upload file(s) as page attachments')
    .action(async (pageId: string, paths: string[]) => {
      // v1 multipart upload — caller composes the full URL (no v2 upload endpoint).
      const url = `${baseUrl()}/wiki/rest/api/content/${pageId}/child/attachment`;
      let n = 0;
      for (const p of paths) { await uploadMultipart(url, p, 'file', confluenceAuthHeader()); n++; }
      console.log(`Attached ${n} file(s) to page ${pageId}`);
    });
  program.command('download <pageId> [attachmentId]')
    .description('Download one page attachment (by id) or --all')
    .option('--all', 'Download every attachment')
    .option('--out <dir>', 'Output directory (default cwd)', '.')
    .action(async (pageId: string, attachmentId: string | undefined, opts: { all?: boolean; out: string }) => {
      const r = await confluenceV2<{ results: PageAttachment[] }>('GET', `/pages/${pageId}/attachments`);
      const picked = pickPageAttachments(r.results ?? [], attachmentId, Boolean(opts.all));
      for (const a of picked) {
        // basename() guards against a server-supplied title escaping --out.
        const out = join(opts.out, basename(a.title));
        const n = await downloadTo(`${baseUrl()}${a.downloadLink}`, out, confluenceAuthHeader()); // downloadLink is /wiki/...-rooted
        console.log(`${out} (${n}b)`);
      }
    });
}
