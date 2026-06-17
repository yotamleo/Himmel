import type { Command } from 'commander';
import { getUser } from '../client.js';

export function registerAuth(program: Command): void {
  const auth = program.command('auth').description('Authentication');
  auth
    .command('status')
    .description('Check Bitbucket Cloud auth (GET /2.0/user); exit 0 if authenticated')
    .action(async () => {
      try {
        const u = await getUser();
        console.log(`Logged in to bitbucket.org as ${u.nickname ?? u.account_id ?? u.uuid}`);
      } catch (err) {
        process.stderr.write(`bitbucket: not authenticated: ${(err as Error).message}\n`);
        process.exit(1);
      }
    });
}
