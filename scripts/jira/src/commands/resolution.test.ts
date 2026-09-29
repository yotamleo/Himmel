import { describe, it, expect } from 'vitest';
import { syncResolution } from './resolution.js';

interface Call { method: string; path: string; body?: unknown }
interface Transition { id: string; name: string; to: { id: string } }

const CLOSED = { id: '6', name: 'Closed' };

// Resolution is not on the edit screen, so the only write path is the
// workflow: a self-transition re-runs the target status's post-function.
function stub(before: string | null, after: string | null, transitions: Transition[] = [{ id: '5', name: 'Closed', to: { id: '6' } }]) {
  const calls: Call[] = [];
  let reads = 0;
  const req = (async (method: string, path: string, body?: unknown) => {
    calls.push({ method, path, body });
    if (path === '/issue/HIMMEL-1?fields=status,resolution') {
      const res = reads++ === 0 ? before : after;
      return { fields: { status: CLOSED, resolution: res ? { name: res } : null } };
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

  it('picks the transition by destination status, not by name', async () => {
    const { req, calls } = stub(null, 'Done', [
      { id: '4', name: 'Closed', to: { id: '9' } }, // named like the status, goes elsewhere
      { id: '5', name: 'Re-close', to: { id: '6' } },
    ]);
    await syncResolution('HIMMEL-1', req);
    expect(calls.find((c) => c.method === 'POST')?.body).toEqual({ transition: { id: '5' } });
  });

  it('fails loud when the status has no self-transition', async () => {
    const { req } = stub(null, null, [{ id: '1', name: 'Closed', to: { id: '1' } }]);
    await expect(syncResolution('HIMMEL-1', req)).rejects.toThrow(/no self-transition/);
  });

  it('fails loud when the status changed underneath', async () => {
    let reads = 0;
    const req = (async (method: string, path: string) => {
      if (path.endsWith('?fields=status,resolution')) {
        return { fields: { status: reads++ === 0 ? CLOSED : { id: '1', name: 'To Do' }, resolution: null } };
      }
      if (method === 'GET') return { transitions: [{ id: '5', name: 'Closed', to: { id: '6' } }] };
      return '';
    }) as never;
    await expect(syncResolution('HIMMEL-1', req)).rejects.toThrow(/status changed/);
  });
});
