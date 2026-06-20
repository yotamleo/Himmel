import { join, basename } from 'node:path';
import type { Command } from 'commander';
import { request, downloadTo, baseUrl } from '../client.js';

interface Attachment { id: string; filename: string; size?: number; author?: { displayName: string }; created?: string; }
interface IssueAttachments { fields: { attachment?: Attachment[] } }

export function pickAttachments(
  issue: IssueAttachments,
  idArg: string | undefined,
  all: boolean,
): Attachment[] {
  const list = issue.fields.attachment ?? [];
  if (all) {
    const names = new Set<string>();
    for (const a of list) {
      if (names.has(a.filename)) throw new Error(`duplicate filename "${a.filename}" — cannot --all into one dir`);
      names.add(a.filename);
    }
    return list;
  }
  if (!idArg) throw new Error('download requires an attachment id or --all');
  const hit = list.find((a) => a.id === idArg);
  if (!hit) throw new Error(`no attachment with id ${idArg} on the issue`);
  return [hit];
}

export function registerAttachments(program: Command): void {
  program
    .command('attachments <key>')
    .description('List attachments on an issue')
    .action(async (key: string) => {
      const issue = await request<IssueAttachments>('GET', `/issue/${key}?fields=attachment`);
      const list = issue.fields.attachment ?? [];
      if (!list.length) { console.log(`${key}: no attachments`); return; }
      for (const a of list) {
        console.log(`${a.id}\t${a.filename}\t${a.size ?? '?'}b\t${a.author?.displayName ?? ''}`);
      }
    });

  program
    .command('download <key> [attachmentId]')
    .description('Download one attachment (by id) or --all from an issue')
    .option('--all', 'Download every attachment')
    .option('--out <dir>', 'Output directory (default cwd)', '.')
    .action(async (key: string, attachmentId: string | undefined, opts: { all?: boolean; out: string }) => {
      const issue = await request<IssueAttachments>('GET', `/issue/${key}?fields=attachment`);
      const picked = pickAttachments(issue, attachmentId, Boolean(opts.all));
      for (const a of picked) {
        // basename() the server-supplied filename so a malicious/odd name
        // (e.g. containing ../) cannot write outside --out.
        const out = join(opts.out, basename(a.filename));
        const n = await downloadTo(`${baseUrl()}/rest/api/3/attachment/content/${a.id}`, out);
        console.log(`${out} (${n}b)`);
      }
    });
}
