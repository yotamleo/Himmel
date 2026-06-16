import type { Command } from 'commander';
import { uploadAll } from './attach-helper.js';

export function registerAttach(program: Command): void {
  program
    .command('attach <key> <paths...>')
    .description('Upload one or more files as attachments to an existing issue')
    .action(async (key: string, paths: string[]) => {
      try {
        const n = await uploadAll(key, paths);
        console.log(`Attached ${n} file(s) to ${key}`);
      } catch (e) {
        console.error(`jira: attach to ${key} failed: ${(e as Error).message}`);
        process.exit(1);
      }
    });
}
