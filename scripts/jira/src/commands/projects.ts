import type { Command } from 'commander';
import { request } from '../client.js';

interface JiraProject {
  id: string;
  key: string;
  name: string;
  projectTypeKey?: string;
  archived?: boolean;
}

interface JiraProjectSearchResult {
  values: JiraProject[];
  total: number;
  isLast: boolean;
}

export function registerProjects(program: Command): void {
  program
    .command('projects')
    .description('List Jira projects visible to the authenticated user')
    .option('--limit <n>', 'Max results', '50')
    .action(async (options: { limit: string }) => {
      const result = await request<JiraProjectSearchResult>(
        'GET',
        `/project/search?maxResults=${options.limit}&orderBy=key`,
      );
      for (const p of result.values) {
        console.log(`${p.key}\t${p.id}\t${p.name}`);
      }
    });
}
