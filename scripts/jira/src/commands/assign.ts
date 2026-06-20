import type { Command } from 'commander';
import { request, resolveAccountId } from '../client.js';

export async function buildAssignBody(user: string): Promise<{ accountId: string | null }> {
  const u = user.trim().toLowerCase();
  if (u === '-' || u === 'unassigned' || u === 'none') return { accountId: null };
  if (u === 'auto' || u === '-1') return { accountId: '-1' };
  return { accountId: await resolveAccountId(user) };
}

export function registerAssign(program: Command): void {
  program
    .command('assign <key> <user>')
    .description('Set the assignee (email or accountId; "-"/"unassigned" clears, "auto" = default)')
    .action(async (key: string, user: string) => {
      const body = await buildAssignBody(user);
      await request('PUT', `/issue/${key}/assignee`, body);
      console.log(`${key} assigned to ${body.accountId ?? '(unassigned)'}`);
    });
}
