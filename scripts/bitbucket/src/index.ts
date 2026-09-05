#!/usr/bin/env node
import { Command } from 'commander';
import { registerAuth } from './commands/auth.js';
import { registerUser } from './commands/user.js';
import { registerRepo } from './commands/repo.js';
import { registerPr } from './commands/pr.js';
import { registerIssue } from './commands/issue.js';

const program = new Command();

program
  .name('bitbucket')
  .version('1.0.0')
  .description('Bitbucket Cloud CLI for himmel (forge-dispatch transport)');

registerAuth(program);
registerUser(program);
registerRepo(program);
registerPr(program);
registerIssue(program);

// Machine-readable command introspection, mirroring the Jira CLI (HIMMEL-231):
// emit one top-level verb per line, then exit 0. Needs no network.
if (process.argv.includes('--list-commands')) {
  for (const cmd of program.commands) {
    console.log(cmd.name());
  }
  process.exit(0);
}

program.parseAsync(process.argv).catch((err: Error) => {
  console.error(err.message);
  process.exit(1);
});
