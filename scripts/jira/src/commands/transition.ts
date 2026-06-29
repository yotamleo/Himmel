import type { Command } from 'commander';
import { request } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';
import type { JiraTransition } from '../types.js';

export function findTransition(
  transitions: JiraTransition[],
  name: string,
): JiraTransition | undefined {
  return transitions.find(
    (t) => t.name.toLowerCase() === name.toLowerCase(),
  );
}

export function registerTransition(program: Command): void {
  program
    .command('transition <key> <status>')
    .description('Transition a Jira issue to a new status')
    .action(async (key: string, status: string) => {
      const { transitions } = await request<{ transitions: JiraTransition[] }>(
        'GET',
        `/issue/${key}/transitions`,
      );
      const match = findTransition(transitions, status);
      if (!match) {
        console.error(`Transition "${status}" not found. Available:`);
        for (const t of transitions) console.error(`- ${t.name}`);
        process.exit(1);
      }
      await request('POST', `/issue/${key}/transitions`, {
        transition: { id: match.id },
      });
      writeJiraBreadcrumb(key);
      console.log(`${key} → ${match.name}`);
    });
}
