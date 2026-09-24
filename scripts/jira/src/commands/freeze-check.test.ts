import { describe, it, expect, beforeEach, vi } from 'vitest';

vi.mock('../client.js', () => ({
  request: vi.fn(),
  projectKey: () => 'HIMMEL',
}));

import { runFreezeCheck } from './freeze-check.js';
import { freezeCheckJql } from '../freeze.js';
import { request } from '../client.js';

const mockRequest = request as unknown as ReturnType<typeof vi.fn>;

const issue = (key: string) => ({
  key,
  fields: { summary: 's', status: { name: 'To Do' }, issuetype: { name: 'Bug' } },
});

describe('freeze-check (HIMMEL-3411)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('queries the freeze JQL and exits 0 when nothing leaked', async () => {
    mockRequest.mockResolvedValue({ issues: [] });
    expect(await runFreezeCheck('HIMMEL', '500')).toBe(0);
    const [, path] = mockRequest.mock.calls[0] as [string, string];
    expect(path).toContain(encodeURIComponent(freezeCheckJql('HIMMEL')));
  });

  it('lists each leak and exits 1', async () => {
    mockRequest.mockResolvedValue({ issues: [issue('HIMMEL-9001'), issue('HIMMEL-9002')] });
    expect(await runFreezeCheck('HIMMEL', '500')).toBe(1);
    expect(console.log).toHaveBeenCalledTimes(2);
    expect(console.error).toHaveBeenCalledWith(expect.stringMatching(/^freeze-check: 2 Bug/));
  });
});
