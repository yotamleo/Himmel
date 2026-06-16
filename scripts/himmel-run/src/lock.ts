import lockfile from 'proper-lockfile';

// In-process queue per target path — prevents same-process races that the
// file-system lock alone cannot serialize (both callers would race to acquire
// before either has written the lockfile to disk).
const queues = new Map<string, Promise<unknown>>();

export async function withLock<T>(target: string, fn: () => Promise<T>): Promise<T> {
  const prev = queues.get(target) ?? Promise.resolve();

  const next = prev.then(async () => {
    const release = await lockfile.lock(target, {
      stale: 30_000,
      retries: { retries: 10, factor: 1.5, minTimeout: 50, maxTimeout: 500 },
    });
    try {
      return await fn();
    } finally {
      await release();
    }
  });

  // Store a version that never rejects so the chain stays alive.
  queues.set(target, next.catch(() => undefined));

  return next;
}
