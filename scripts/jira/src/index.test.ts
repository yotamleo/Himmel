import { describe, it, expect } from 'vitest';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Contract test for the `--list-commands` introspection flag (HIMMEL-231).
//
// The block-mcp-when-plugin-exists.sh hook derives its blocked-set by
// running `node dist/index.js --list-commands`. That output is therefore a
// SECURITY-RELEVANT CONTRACT, not a convenience: if a refactor moves the
// flag handling after parseAsync, changes the line format, pollutes the
// list with a `help` command, or makes it require JIRA_PROJECT_KEY, the
// hook silently fails OPEN and the MCP guardrail erodes with no test going
// red. This test pins the three properties the hook relies on.
//
// It spawns the BUILT CLI (the exact surface the hook consumes). `pretest`
// (npm run build) ensures dist is fresh before vitest runs.

const distIndex = fileURLToPath(new URL('../dist/index.js', import.meta.url));

// Verbs the hook's verb→MCP-method map keys on (block-mcp-when-plugin-exists.sh).
// If any of these stop being emitted, the corresponding MCP method stops
// being blocked — exactly the silent regression this test guards.
const HOOK_CRITICAL_VERBS = [
  'get',
  'create',
  'list',
  'edit',
  'comment',
  'transition',
  'projects',
  'link',
];

function listCommands(env: NodeJS.ProcessEnv): string[] {
  const out = execFileSync('node', [distIndex, '--list-commands'], {
    encoding: 'utf8',
    env,
  });
  return out
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
}

describe('--list-commands introspection contract', () => {
  it('exits 0 and emits one bare verb token per line', () => {
    const verbs = listCommands(process.env);
    expect(verbs.length).toBeGreaterThan(0);
    // Each line must be a bare verb token (no banner, usage, or "help <cmd>").
    for (const v of verbs) {
      expect(v).toMatch(/^[a-z][a-z-]*$/);
    }
  });

  it('emits every verb the block-mcp hook keys on', () => {
    const verbs = listCommands(process.env);
    for (const verb of HOOK_CRITICAL_VERBS) {
      expect(verbs).toContain(verb);
    }
  });

  it('does not emit a `help` command (would widen the blocked-set)', () => {
    expect(listCommands(process.env)).not.toContain('help');
  });

  it('works without JIRA_PROJECT_KEY (no network / env dependency)', () => {
    const env = { ...process.env };
    delete env.JIRA_PROJECT_KEY;
    // Must not throw (non-zero exit) and must still emit the verbs.
    const verbs = listCommands(env);
    expect(verbs).toContain('get');
  });
});
