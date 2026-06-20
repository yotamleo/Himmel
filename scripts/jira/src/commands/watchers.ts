import type { Command } from 'commander';
import { request, resolveAccountId } from '../client.js';

export function watcherDeletePath(key: string, accountId: string): string {
  return `/issue/${key}/watchers?accountId=${encodeURIComponent(accountId)}`;
}

async function selfAccountId(): Promise<string> {
  const me = await request<{ accountId: string }>('GET', '/myself');
  return me.accountId;
}

export function registerWatchers(program: Command): void {
  program.command('watch <key> [user]')
    .description('Add a watcher (default: yourself)')
    .action(async (key: string, user?: string) => {
      const accountId = user ? await resolveAccountId(user) : await selfAccountId();
      await request('POST', `/issue/${key}/watchers`, accountId);
      console.log(`Watching ${key} as ${accountId}`);
    });
  program.command('unwatch <key> [user]')
    .description('Remove a watcher (default: yourself)')
    .action(async (key: string, user?: string) => {
      const accountId = user ? await resolveAccountId(user) : await selfAccountId();
      await request('DELETE', watcherDeletePath(key, accountId));
      console.log(`Unwatched ${key} for ${accountId}`);
    });
  program.command('watchers <key>')
    .description('List watchers on an issue')
    .action(async (key: string) => {
      const r = await request<{ watchers: Array<{ accountId: string; displayName: string }> }>(
        'GET', `/issue/${key}/watchers`);
      for (const w of r.watchers ?? []) console.log(`${w.accountId}\t${w.displayName}`);
    });
}
