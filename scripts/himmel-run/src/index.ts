#!/usr/bin/env node
import { Command } from 'commander';
import { run } from './run.js';

/**
 * Resolve the recovery command from CLI options.
 *
 * HIMMEL-101 §8: --then-cmd-json accepts a JSON array of strings, which handles
 * args containing commas and avoids shell-quoting hazards. --then-cmd is retained
 * for compatibility but warns the operator to migrate.
 *
 * Exits the process with code 2 on invalid input (matches commander's bad-arg pattern).
 */
export function resolveThenCmd(
  thenCmd: string | undefined,
  thenCmdJson: string | undefined,
): string[] | undefined {
  if (thenCmdJson) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(thenCmdJson);
    } catch (e) {
      process.stderr.write(
        `himmel-run: --then-cmd-json is not valid JSON: ${(e as Error).message}\n`,
      );
      process.exit(2);
      return undefined; // unreachable in CLI; lets unit tests with mocked exit return cleanly
    }
    if (!Array.isArray(parsed) || parsed.some((x) => typeof x !== 'string')) {
      process.stderr.write(
        'himmel-run: --then-cmd-json must be a JSON array of strings\n',
      );
      process.exit(2);
      return undefined;
    }
    if ((parsed as string[]).length === 0) {
      process.stderr.write('himmel-run: --then-cmd-json must be non-empty\n');
      process.exit(2);
      return undefined;
    }
    return parsed as string[];
  }
  if (thenCmd) {
    process.stderr.write(
      'himmel-run: --then-cmd is deprecated and breaks on args containing commas — switch to --then-cmd-json\n',
    );
    return thenCmd.split(',');
  }
  return undefined;
}

const program = new Command();

program
  .name('himmel-run')
  .description('Token-discipline runner for CLI plugins')
  .version('0.1.0');

program
  .argument('<tag>', 'tag for cache/log namespacing (e.g. jira, gh)')
  .option('--summary-jq <expr>', 'jq expression against stdout JSON')
  .option('--summary-regex <re>', 'regex; first capture group becomes summary')
  .option('--retry-on <codes>', 'comma-sep exit codes to retry', (v) =>
    v.split(',').map(Number),
  )
  .option('--retry-jitter <ms,ms>', 'base,cap retry delay', (v) => {
    const [a, b] = v.split(',').map(Number);
    return [a, b] as [number, number];
  })
  .option('--on-stderr-match <re>', 'recovery trigger pattern')
  .option('--then-cmd <cmd>', 'DEPRECATED — use --then-cmd-json. Comma-separated args (no shell quoting, no commas-in-args).')
  .option('--then-cmd-json <json>', 'recovery command as JSON array, e.g. \'["node","script.js","--flag"]\'')
  .option('--redact-regex <patterns>', 'comma-sep regex patterns', (v) => v.split(','))
  .option('--no-cache', "don't write index entry")
  .option('--inspect <runId>', 'replay log for runId then exit')
  .allowUnknownOption(false)
  .action(async (tag: string, opts) => {
    const dashIdx = process.argv.lastIndexOf('--');
    const wrapped = dashIdx >= 0 ? process.argv.slice(dashIdx + 1) : [];

    if (opts.inspect) {
      const { inspect } = await import('./inspect.js');
      const out = await inspect(tag, opts.inspect);
      process.stdout.write(out);
      process.exit(0);
    }

    if (wrapped.length === 0) {
      console.error('himmel-run: missing wrapped command after --');
      process.exit(2);
    }

    const res = await run({
      tag,
      cmd: wrapped as [string, ...string[]],
      summaryJq: opts.summaryJq,
      summaryRegex: opts.summaryRegex,
      retryOn: opts.retryOn,
      retryJitterMs: opts.retryJitter,
      onStderrMatch: opts.onStderrMatch,
      thenCmd: resolveThenCmd(opts.thenCmd, opts.thenCmdJson),
      redactRegex: opts.redactRegex,
      noCache: opts.noCache,
    });

    const line = `exit=${res.exitCode} | ${res.summary} | run=${res.runId}`;
    process.stdout.write(line.slice(0, 200) + '\n');
    process.exit(res.exitCode);
  });

// gc subcommand
program
  .command('gc <tag>')
  .description('Garbage-collect old index entries (> 30 days)')
  .option('--max-age-days <n>', 'age threshold', '30')
  .action(async (tag: string, opts) => {
    const { gc } = await import('./gc.js');
    const removed = await gc(tag, Number(opts.maxAgeDays));
    console.log(`himmel-run gc ${tag}: removed ${removed} entries`);
  });

// Only parse argv when invoked as a CLI entry point (not when imported for tests).
// ESM equivalent of `if (require.main === module)`: compare module URL to argv[1].
import { fileURLToPath } from 'node:url';
import { realpathSync } from 'node:fs';
const isEntryPoint = (() => {
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1] ?? '');
  } catch (e) {
    process.stderr.write(`himmel-run: entry-point detection failed: ${(e as Error).message}\n`);
    return false;
  }
})();
if (isEntryPoint) {
  program.parseAsync(process.argv);
}
