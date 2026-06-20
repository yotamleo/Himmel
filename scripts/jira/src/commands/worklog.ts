import type { Command } from 'commander';
import { request } from '../client.js';
import { markdownToAdf } from '../adf.js';

export function buildWorklogBody(opts: { time: string; comment?: string; started?: string }): Record<string, unknown> {
  if (!opts.time || !opts.time.trim()) throw new Error('worklog add requires --time (e.g. "1h 30m")');
  const body: Record<string, unknown> = { timeSpent: opts.time };
  if (opts.comment !== undefined) body.comment = markdownToAdf(opts.comment);
  if (opts.started !== undefined) body.started = opts.started;
  return body;
}

interface Worklog { id: string; timeSpent: string; author?: { displayName: string }; started?: string }

export function registerWorklog(program: Command): void {
  const wl = program.command('worklog').description('Worklog operations');
  wl.command('add <key>')
    .description('Log work on an issue')
    .requiredOption('--time <t>', 'Time spent, Jira format (e.g. "1h 30m")')
    .option('--comment <c>', 'Worklog comment (markdown)')
    .option('--started <iso>', 'Start time, Jira ISO (e.g. 2026-06-20T10:00:00.000+0000)')
    .action(async (key: string, opts: { time: string; comment?: string; started?: string }) => {
      await request('POST', `/issue/${key}/worklog`, buildWorklogBody(opts));
      console.log(`Logged ${opts.time} on ${key}`);
    });
  wl.command('list <key>')
    .description('List worklog entries on an issue')
    .action(async (key: string) => {
      const r = await request<{ worklogs: Worklog[] }>('GET', `/issue/${key}/worklog`);
      for (const w of r.worklogs ?? []) {
        console.log(`${w.id}\t${w.timeSpent}\t${w.author?.displayName ?? ''}\t${w.started ?? ''}`);
      }
    });
}
