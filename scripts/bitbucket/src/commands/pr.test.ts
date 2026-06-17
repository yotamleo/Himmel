import { describe, it, expect } from 'vitest';
import { Command } from 'commander';
import { registerPr } from './pr.js';

// Command-layer smoke for the review-thread verbs (spec §5.3): assert they are
// registered under `pr` with the expected required arguments. Inspecting the
// commander tree (vs spawning the built CLI) keeps this independent of cwd, the
// dist build, network, and auth. Full exit-code coverage is tracked in HIMMEL-341.
function prCommand(): Command {
  const program = new Command();
  registerPr(program);
  const pr = program.commands.find((c) => c.name() === 'pr');
  if (!pr) throw new Error('pr command not registered');
  return pr;
}

describe('bitbucket pr review-thread subcommands', () => {
  it('registers comments / reply / resolve under `pr`', () => {
    const names = prCommand()
      .commands.map((c) => c.name())
      .sort();
    expect(names).toEqual(expect.arrayContaining(['comments', 'reply', 'resolve']));
  });

  it('pr reply declares two required args (<id> <parentId>)', () => {
    const reply = prCommand().commands.find((c) => c.name() === 'reply');
    expect(reply).toBeDefined();
    // commander exposes registered positional args; reply takes <id> <parentId>.
    expect(reply?.registeredArguments).toHaveLength(2);
    expect(reply?.registeredArguments.every((a) => a.required)).toBe(true);
  });

  it('pr resolve declares two required args (<id> <commentId>)', () => {
    const resolve = prCommand().commands.find((c) => c.name() === 'resolve');
    expect(resolve?.registeredArguments).toHaveLength(2);
  });

  it('registers the ingestion `get` verb with a required <id> and a --repo option', () => {
    const get = prCommand().commands.find((c) => c.name() === 'get');
    expect(get).toBeDefined();
    expect(get?.registeredArguments).toHaveLength(1);
    expect(get?.registeredArguments[0].required).toBe(true);
    expect(get?.options.some((o) => o.long === '--repo')).toBe(true);
  });
});
