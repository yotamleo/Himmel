import type { Command } from 'commander';
import { request, projectKey } from '../client.js';
import { formatIssue } from '../output.js';
import { BUG_FREEZE, freezeCheckJql } from '../freeze.js';
import { searchAllIssues } from './list.js';

/**
 * HIMMEL-3411: report Bugs filed after the freeze cutoff that sit in the v1
 * version without the blocker label. Exit 1 when any exist, so it can gate.
 */
export async function runFreezeCheck(project: string, limit: string): Promise<number> {
  const leaks = await searchAllIssues(freezeCheckJql(project), limit, request);
  for (const issue of leaks) console.log(formatIssue(issue));
  console.error(
    `freeze-check: ${leaks.length} Bug(s) created after ${BUG_FREEZE.cutoff} in ` +
      `${BUG_FREEZE.v1Version} without ${BUG_FREEZE.blockerLabel}`,
  );
  return leaks.length === 0 ? 0 : 1;
}

export function registerFreezeCheck(program: Command): void {
  program
    .command('freeze-check')
    .description(
      `Report Bugs created after ${BUG_FREEZE.cutoff} in fixVersion ${BUG_FREEZE.v1Version} ` +
        `without the ${BUG_FREEZE.blockerLabel} label (exit 1 if any)`,
    )
    .option('--project <key>', 'Project key (default: JIRA_PROJECT_KEY)')
    .option('--limit <n>', 'Max results (paged automatically above 100)', '500')
    .action(async (options: { project?: string; limit: string }) => {
      process.exitCode = await runFreezeCheck(options.project ?? projectKey(), options.limit);
    });
}
