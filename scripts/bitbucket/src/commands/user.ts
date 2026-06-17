import type { Command } from 'commander';
import { getUser } from '../client.js';
import { printJson, resolveSlug } from '../output.js';

export function registerUser(program: Command): void {
  program
    .command('user')
    .description('Get the authenticated user (GET /2.0/user)')
    .option('--slug', 'Print only the resolved user-slug (nickname → account_id → uuid)')
    .action(async (options: { slug?: boolean }) => {
      let user;
      try {
        user = await getUser();
      } catch (err) {
        process.stderr.write(`bitbucket: user failed: ${(err as Error).message}\n`);
        process.exit(1);
      }
      if (options.slug) {
        console.log(resolveSlug(user));
      } else {
        printJson(user);
      }
    });
}
