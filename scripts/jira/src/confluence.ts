#!/usr/bin/env node
import { Command } from 'commander';
import { registerPageGet } from './commands/confluence/page-get.js';
import { registerPageWrite } from './commands/confluence/page-write.js';
import { registerSearch } from './commands/confluence/search.js';
import { registerComment } from './commands/confluence/comment.js';
import { registerAttachments } from './commands/confluence/attachments.js';

const program = new Command();
program.name('confluence').version('1.0.0').description('Confluence CLI for himmel project');

const page = program.command('page').description('Page operations');
registerPageGet(page);
registerPageWrite(page);

registerSearch(program);
registerComment(program);
registerAttachments(program);

// Machine-readable command introspection (mirrors index.ts). Emits one verb
// path per line so block-backend-tier.sh can map Confluence MCP methods to CLI
// verbs. Top-level verbs emit bare (search, spaces, …); page verbs emit
// space-joined (page get, …). The routing hook's _CONFLUENCE_VERB_METHOD_MAP
// must use these exact strings.
if (process.argv.includes('--list-commands')) {
  const walk = (cmd: Command, prefix: string): void => {
    for (const c of cmd.commands) {
      if (c.name() === 'help') continue; // commander auto-adds help — don't emit it
      const name = `${prefix}${c.name()}`;
      if (c.commands.length) walk(c, `${name} `);
      else console.log(name);
    }
  };
  walk(program, '');
  process.exit(0);
}

program.parseAsync(process.argv).catch((err: Error) => {
  console.error(err.message);
  process.exit(1);
});
