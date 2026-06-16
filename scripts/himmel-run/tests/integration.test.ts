import { describe, it, expect } from 'vitest';
import { run } from '../src/run.js';

const skip = process.env.JIRA_E2E !== '1';

describe.skipIf(skip)('JIRA_E2E integration (skipped unless JIRA_E2E=1)', () => {
  it('creates → reads back a task in HIMTEST', async () => {
    const jira = ['node', `${process.cwd()}/../jira/dist/index.js`];
    const r1 = await run({
      tag: 'jira-e2e',
      cmd: [...jira, 'create', '--type', 'Task', '--project', 'HIMTEST', '--title', 'e2e-smoke-' + Date.now()],
      summaryRegex: '^Created ([A-Z]+-\\d+)',
    });
    expect(r1.exitCode).toBe(0);
    expect(r1.summary).toMatch(/^HIMTEST-\d+$/);

    const r2 = await run({
      tag: 'jira-e2e',
      cmd: [...jira, 'get', r1.summary],
    });
    expect(r2.exitCode).toBe(0);
    expect(r2.summary).toContain(r1.summary);
  }, 30_000);
});
