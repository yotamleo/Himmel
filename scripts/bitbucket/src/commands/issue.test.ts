import { describe, it, expect } from 'vitest';
import { Command } from 'commander';
import { registerIssue } from './issue.js';

// Command-layer smoke for the ingestion read verb (HIMMEL-329): assert `issue get`
// is registered with a required <id> and a --repo option. Full exit-code coverage
// (404 → exit 3) is tracked in HIMMEL-341.
function issueCommand(): Command {
  const program = new Command();
  registerIssue(program);
  const issue = program.commands.find((c) => c.name() === 'issue');
  if (!issue) throw new Error('issue command not registered');
  return issue;
}

describe('bitbucket issue subcommands', () => {
  it('registers create + get under `issue`', () => {
    const names = issueCommand()
      .commands.map((c) => c.name())
      .sort();
    expect(names).toEqual(expect.arrayContaining(['create', 'get']));
  });

  it('issue get declares a required <id> and a --repo option', () => {
    const get = issueCommand().commands.find((c) => c.name() === 'get');
    expect(get).toBeDefined();
    expect(get?.registeredArguments).toHaveLength(1);
    expect(get?.registeredArguments[0].required).toBe(true);
    expect(get?.options.some((o) => o.long === '--repo')).toBe(true);
  });
});
