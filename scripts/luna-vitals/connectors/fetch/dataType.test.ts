import { describe, test, expect } from 'bun:test';
import { fetchDataPoints, filterByDateWindow } from './dataType';

// ── fake fetchImpl helpers ────────────────────────────────────────────────────

type FakeCall = { url: string; headers: Record<string, string> };

/** Build a sequence-of-pages fake fetchImpl. Records every call made. */
function makePagedFetch(pages: Array<{ dataPoints: any[]; nextPageToken?: string }>) {
  const calls: FakeCall[] = [];
  let i = 0;
  const impl = async (url: string, init?: RequestInit) => {
    calls.push({
      url,
      headers: (init?.headers as Record<string, string>) ?? {},
    });
    const page = pages[i++] ?? { dataPoints: [] };
    return {
      ok: true as const,
      status: 200,
      json: async () => page,
    };
  };
  return { impl, calls };
}

/** Fake that always returns a nextPageToken (simulates runaway pagination). */
function makeInfiniteFetch() {
  return async (_url: string, _init?: RequestInit) => ({
    ok: true as const,
    status: 200,
    json: async () => ({ dataPoints: [], nextPageToken: 'always-more' }),
  });
}

function makeErrorFetch(status: number) {
  return async (_url: string, _init?: RequestInit) => ({
    ok: false as const,
    status,
    json: async () => ({}),
  });
}

// ── fetchDataPoints ──────────────────────────────────────────────────────────

describe('fetchDataPoints', () => {
  test('two-page list: concatenates dataPoints, correct Bearer header, pageToken on page 2', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-06-01' }, { date: '2026-06-02' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-06-03' }] },
    ]);

    const result = await fetchDataPoints(
      { dataTypeId: 'steps', accessToken: 'test-token', baseUrl: 'https://fake.api/v4' },
      impl,
    );

    // Correct total count and order
    expect(result).toHaveLength(3);
    expect(result[0].date).toBe('2026-06-01');
    expect(result[2].date).toBe('2026-06-03');

    // Exactly two calls
    expect(calls).toHaveLength(2);

    // Both calls carry Bearer header
    expect(calls[0].headers['Authorization']).toBe('Bearer test-token');
    expect(calls[1].headers['Authorization']).toBe('Bearer test-token');

    // First call: no pageToken query param
    expect(calls[0].url).not.toContain('pageToken');

    // Second call: pageToken=p2 in query string
    expect(calls[1].url).toContain('pageToken=p2');
  });

  test('empty nextPageToken stops paging after one call', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-06-10' }] },
    ]);

    const result = await fetchDataPoints(
      { dataTypeId: 'heart-rate', accessToken: 'tok', baseUrl: 'https://fake.api/v4' },
      impl,
    );

    expect(result).toHaveLength(1);
    expect(calls).toHaveLength(1);
  });

  test('page cap: throws after 100 pages and names the dataTypeId in the error', async () => {
    let caught: unknown;
    try {
      await fetchDataPoints(
        { dataTypeId: 'heart-rate-runaway', accessToken: 'tok', baseUrl: 'https://fake.api/v4' },
        makeInfiniteFetch(),
      );
    } catch (e) {
      caught = e;
    }

    expect(caught).toBeInstanceOf(Error);
    const msg = (caught as Error).message;
    expect(msg).toContain('heart-rate-runaway');
    expect(msg).toMatch(/cap/i);
  });

  test('non-ok HTTP 401: throws with status and dataTypeId, NOT the access token', async () => {
    const SECRET_TOKEN = 'super-secret-access-token';

    let caught: unknown;
    try {
      await fetchDataPoints(
        { dataTypeId: 'steps', accessToken: SECRET_TOKEN, baseUrl: 'https://fake.api/v4' },
        makeErrorFetch(401),
      );
    } catch (e) {
      caught = e;
    }

    expect(caught).toBeInstanceOf(Error);
    const msg = (caught as Error).message;
    expect(msg).toContain('401');
    expect(msg).toContain('steps');
    expect(msg).not.toContain(SECRET_TOKEN);
  });
});

// ── filterByDateWindow ───────────────────────────────────────────────────────

describe('filterByDateWindow', () => {
  const rows = [
    { date: '2024-12-31' },
    { date: '2025-05-15' },
    { date: '2026-05-31' },
    { date: '2026-06-01' }, // lower boundary — must include
    { date: '2026-06-15' },
    { date: '2026-06-30' }, // upper boundary — must include
    { date: '2026-07-01' },
    { date: '2026-12-25' },
  ];

  test('keeps only rows within 2026-06-01..2026-06-30 inclusive', () => {
    const result = filterByDateWindow(rows, '2026-06-01', '2026-06-30');
    expect(result).toHaveLength(3);
    expect(result.map((r) => r.date)).toEqual(['2026-06-01', '2026-06-15', '2026-06-30']);
  });

  test('boundary dates are inclusive; adjacent dates are excluded', () => {
    const result = filterByDateWindow(rows, '2026-06-01', '2026-06-30');
    const dates = result.map((r) => r.date);
    expect(dates).toContain('2026-06-01');
    expect(dates).toContain('2026-06-30');
    expect(dates).not.toContain('2026-05-31');
    expect(dates).not.toContain('2026-07-01');
  });
});
