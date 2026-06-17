import { describe, it, expect } from 'vitest';
import { Command } from 'commander';
import { registerRepo } from './repo.js';

// Command-layer smoke for the ingestion read verb (HIMMEL-329): assert `repo get`
// is registered with a --repo option. Inspecting the commander tree keeps this
// independent of cwd, the dist build, network, and auth (mirrors pr.test.ts).
function repoCommand(): Command {
  const program = new Command();
  registerRepo(program);
  const repo = program.commands.find((c) => c.name() === 'repo');
  if (!repo) throw new Error('repo command not registered');
  return repo;
}

describe('bitbucket repo subcommands', () => {
  it('registers view + get under `repo`', () => {
    const names = repoCommand()
      .commands.map((c) => c.name())
      .sort();
    expect(names).toEqual(expect.arrayContaining(['get', 'view']));
  });

  it('repo get exposes a --repo option', () => {
    const get = repoCommand().commands.find((c) => c.name() === 'get');
    expect(get).toBeDefined();
    expect(get?.options.some((o) => o.long === '--repo')).toBe(true);
  });
});
