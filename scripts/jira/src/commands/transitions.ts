import type { Command } from 'commander';
import { request } from '../client.js';
import type { JiraTransition } from '../types.js';

export function formatTransitions(transitions: JiraTransition[]): string {
  if (transitions.length === 0) {
    return 'No available transitions for this issue.';
  }
  // id<TAB>name per line, mirroring the `list` / `get` table-of-tabs output
  // style used elsewhere in the CLI. Lets operators pipe through awk/cut.
  return transitions.map((t) => `${t.id}\t${t.name}`).join('\n');
}

export function registerTransitions(program: Command): void {
  program
    .command('transitions <key>')
    .description('List available transitions for a Jira issue (id<TAB>name per line)')
    .action(async (key: string) => {
      const { transitions } = await request<{ transitions: JiraTransition[] }>(
        'GET',
        `/issue/${key}/transitions`,
      );
      console.log(formatTransitions(transitions));
    });
}
