#!/usr/bin/env node
import { Command } from 'commander';
import { registerGet } from './commands/get.js';
import { registerCreate } from './commands/create.js';
import { registerList } from './commands/list.js';
import { registerTransition } from './commands/transition.js';
import { registerTransitions } from './commands/transitions.js';
import { registerComment } from './commands/comment.js';
import { registerAttach } from './commands/attach.js';
import { registerEdit } from './commands/edit.js';
import { registerMove } from './commands/move.js';
import { registerProjects } from './commands/projects.js';
import { registerProjectCreate } from './commands/project-create.js';
import { registerLink } from './commands/link.js';

const program = new Command();

program
  .name('jira')
  .version('1.0.0')
  .description('Jira CLI for himmel project');

registerGet(program);
registerCreate(program);
registerList(program);
registerTransition(program);
registerTransitions(program);
registerComment(program);
registerAttach(program);
registerEdit(program);
registerMove(program);
registerProjects(program);
registerProjectCreate(program);
registerLink(program);

// HIMMEL-159: expose the CLI verbs over the Model Context Protocol on stdio.
// The MCP SDK is heavy, so import it lazily inside the action — keeping it out
// of the hot path for every other verb (and `--list-commands` below).
program
  .command('mcp')
  .description('Run an MCP server (stdio) exposing the jira verbs as MCP tools')
  .action(async () => {
    const { runMcpServer } = await import('./mcp.js');
    await runMcpServer();
  });

// Machine-readable command introspection (HIMMEL-231). Emits one
// registered verb name per line, then exits 0 — a STABLE surface the
// block-mcp-when-plugin-exists hook derives its blocked-set from, so the
// hook no longer hand-maintains a literal list that drifts when this CLI
// gains/loses a verb. Handled before parseAsync so it needs no network /
// JIRA_PROJECT_KEY and never dispatches a subcommand. Bare flag only
// (no value) to keep the contract trivial to parse.
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
