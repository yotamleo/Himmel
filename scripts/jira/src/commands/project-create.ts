import type { Command } from 'commander';
import { request } from '../client.js';

interface MyselfResponse {
  accountId: string;
  displayName: string;
}

interface CreateProjectResponse {
  id: number;
  key: string;
  self: string;
}

const DEFAULT_TEMPLATE = 'com.pyxis.greenhopper.jira:gh-simplified-kanban-classic';
const DEFAULT_TYPE = 'software';

export function registerProjectCreate(program: Command): void {
  program
    .command('project-create')
    .description('Create a new Jira project (requires admin permissions)')
    .requiredOption('--key <key>', 'Project key (uppercase, 2-10 chars)')
    .requiredOption('--name <name>', 'Project display name')
    .option('--type <type>', 'Project type: software, business, service_desk', DEFAULT_TYPE)
    .option('--template <template>', 'Project template key', DEFAULT_TEMPLATE)
    .option('--lead <accountId>', 'Lead account ID (defaults to authenticated user)')
    .action(
      async (options: {
        key: string;
        name: string;
        type: string;
        template: string;
        lead?: string;
      }) => {
        let leadAccountId = options.lead;
        if (!leadAccountId) {
          const me = await request<MyselfResponse>('GET', '/myself');
          leadAccountId = me.accountId;
        }
        const result = await request<CreateProjectResponse>('POST', '/project', {
          key: options.key,
          name: options.name,
          projectTypeKey: options.type,
          projectTemplateKey: options.template,
          leadAccountId,
        });
        console.log(`Created ${result.key} (id=${result.id})`);
      },
    );
}
