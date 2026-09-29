import { describe, it, expect } from 'vitest';
import { syncResolution } from './resolution.js';

interface Call { method: string; path: string; body?: unknown }

// Resolution is not on the edit screen, so the only write path is the
// workflow: a self-transition re-runs the target status's post-function.
function stub(before: string | null, after: string | null, transitions = [{ id: '5', name: 'Closed' }]) {
  const calls: Call[] = [];
  let reads = 0;
  const req = (async (method: string, path: string, body?: unknown) => {
    calls.push({ method, path, body });
    if (path === '/issue/HIMMEL-1?fields=status,resolution') {
      const res = reads++ === 0 ? before : after;
      return { fields: { status: { name: 'Closed' }, resolution: res ? { name: res } : null } };
    }
    if (path === '/issue/HIMMEL-1/transitions' && method === 'GET') return { transitions };
    return '';
  }) as never;
  return { req, calls };
}

describe('syncResolution', () => {
  it('self-transitions and reports the before/after resolution', async () => {
    const { req, calls } = stub(null, 'Done');
    expect(await syncResolution('HIMMEL-1', req)).toBe('HIMMEL-1 Closed: resolution (none) -> Done');
    expect(calls.find((c) => c.method === 'POST')).toEqual({
      method: 'POST',
      path: '/issue/HIMMEL-1/transitions',
      body: { transition: { id: '5' } },
    });
  });

  it('fails loud when the status has no self-transition', async () => {
    const { req } = stub(null, null, [{ id: '1', name: 'To Do' }]);
    await expect(syncResolution('HIMMEL-1', req)).rejects.toThrow(/no self-transition/);
  });

  it('fails loud when the status changed underneath', async () => {
    const calls: string[] = [];
    let reads = 0;
    const req = (async (method: string, path: string) => {
      calls.push(path);
      if (path.endsWith('?fields=status,resolution')) {
        return { fields: { status: { name: reads++ === 0 ? 'Closed' : 'To Do' }, resolution: null } };
      }
      if (method === 'GET') return { transitions: [{ id: '5', name: 'Closed' }] };
      return '';
    }) as never;
    await expect(syncResolution('HIMMEL-1', req)).rejects.toThrow(/status changed/);
  });
});
