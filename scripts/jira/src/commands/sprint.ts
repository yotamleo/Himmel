import type { Command } from 'commander';
import { agileRequest, boardId } from '../client.js';
import { writeJiraBreadcrumb } from '../breadcrumb.js';

export function resolveBoard(optBoard?: string): string {
  const b = optBoard ?? boardId();
  if (!b) throw new Error('sprints needs --board <id> or the JIRA_BOARD_ID env var');
  return b;
}

export function sprintTarget(target: string): { backlog: boolean; sprintId?: string } {
  if (target.trim().toLowerCase() === 'backlog') return { backlog: true };
  return { backlog: false, sprintId: target };
}

export function registerSprint(program: Command): void {
  program.command('boards')
    .description('List Agile boards (id, name, type)')
    .action(async () => {
      const r = await agileRequest<{ values: Array<{ id: number; name: string; type: string }> }>(
        'GET', '/board');
      for (const b of r.values ?? []) console.log(`${b.id}\t${b.type}\t${b.name}`);
    });
  program.command('sprints')
    .description('List sprints for a board')
    .option('--board <id>', 'Board id (default: JIRA_BOARD_ID)')
    .action(async (opts: { board?: string }) => {
      const board = resolveBoard(opts.board);
      const r = await agileRequest<{ values: Array<{ id: number; name: string; state: string }> }>(
        'GET', `/board/${board}/sprint`);
      for (const s of r.values ?? []) console.log(`${s.id}\t${s.state}\t${s.name}`);
    });
  program.command('sprint <key> <target>')
    .description('Move an issue to a sprint id, or to the backlog')
    .action(async (key: string, target: string) => {
      const t = sprintTarget(target);
      if (t.backlog) {
        await agileRequest('POST', '/backlog/issue', { issues: [key] });
        writeJiraBreadcrumb(key);
        console.log(`${key} moved to backlog`);
      } else {
        await agileRequest('POST', `/sprint/${t.sprintId}/issue`, { issues: [key] });
        writeJiraBreadcrumb(key);
        console.log(`${key} moved to sprint ${t.sprintId}`);
      }
    });
}
