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

// ── early-stop pagination ────────────────────────────────────────────────────

describe('fetchDataPoints early-stop', () => {
  const byDate = (p: any) => p.date as string | undefined;
  const stop = (windowFrom: string) => ({ windowFrom, pointDate: byDate });

  test('pageSize=1000 is sent on every page', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-07-08' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-07' }] },
    ]);

    await fetchDataPoints(
      { dataTypeId: 'steps', accessToken: 'tok', baseUrl: 'https://fake.api/v4' },
      impl,
    );

    expect(calls[0].url).toContain('pageSize=1000');
    expect(calls[1].url).toContain('pageSize=1000');
  });

  test('descending pages: arms when oldest clears the slacked threshold, breaks on the confirming page', async () => {
    const { impl, calls } = makePagedFetch([
      // page 1: newest-first, oldest (07-04) below windowFrom 07-07 minus the
      // 2-day slack (< 07-05) → ARM
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-04' }], nextPageToken: 'p2' },
      // page 2: ordered, boundary-consistent, fully below threshold → CONFIRM + break
      { dataPoints: [{ date: '2026-07-03' }, { date: '2026-07-02' }], nextPageToken: 'p3' },
      // never reached
      { dataPoints: [{ date: '2026-07-01' }], nextPageToken: 'p4' },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2); // stopped despite page 2's nextPageToken
    expect(result).toHaveLength(4); // both fetched pages collected
  });

  test('descending pages still inside the window: keeps paging', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-07' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-06' }, { date: '2026-07-05' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2);
    expect(result).toHaveLength(4);
  });

  test('pages inside the 2-day offset-jitter slack keep paging (no stop near the window edge)', async () => {
    const { impl, calls } = makePagedFetch([
      // Everything below windowFrom (07-07) but NOT below the slacked
      // threshold (07-05): offset jitter could still hide in-window points,
      // so no arm — full paging.
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-06' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-06' }, { date: '2026-07-05' }], nextPageToken: 'p3' },
      { dataPoints: [{ date: '2026-07-05' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(3);
    expect(result).toHaveLength(5);
  });

  test('oldest point exactly equal to windowFrom does not arm (boundary day is in-window)', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-07' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-06' }, { date: '2026-07-05' }], nextPageToken: 'p3' },
      { dataPoints: [{ date: '2026-07-04' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    // page 1 oldest == windowFrom → no arm; page 2 arms; page 3 confirms via
    // natural end (no nextPageToken).
    expect(calls).toHaveLength(3);
    expect(result).toHaveLength(5);
  });

  test('ascending page order disables early-stop for the whole fetch (order guard)', async () => {
    const { impl, calls } = makePagedFetch([
      // ascending: violates newest-first — early-stop permanently distrusted
      { dataPoints: [{ date: '2026-07-01' }, { date: '2026-07-02' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-03' }, { date: '2026-07-08' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'steps',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2);
    expect(result).toHaveLength(4);
  });

  test('mixed-order page never arms even when endpoints look descending', async () => {
    const { impl, calls } = makePagedFetch([
      // endpoints descend (07-08 >= 07-01) but the middle breaks monotonicity
      {
        dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-01' }, { date: '2026-07-05' }, { date: '2026-07-01' }],
        nextPageToken: 'p2',
      },
      { dataPoints: [{ date: '2026-07-07' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2); // must NOT stop on the mixed page
    expect(result).toHaveLength(5);
  });

  test('cross-page boundary violation fails closed to full paging', async () => {
    const { impl, calls } = makePagedFetch([
      // page 1 arms (oldest 07-04 < 07-07)…
      { dataPoints: [{ date: '2026-07-05' }, { date: '2026-07-04' }], nextPageToken: 'p2' },
      // …but page 2's newest (07-08) exceeds page 1's oldest — global order
      // broken → distrust, keep paging (page 2 holds in-window 07-07!)
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-07' }], nextPageToken: 'p3' },
      { dataPoints: [{ date: '2026-07-03' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(3); // all pages fetched — no data dropped
    expect(result).toHaveLength(5);
  });

  test('tie-only pre-window pages never arm — no strict decrease means no direction evidence', async () => {
    const { impl, calls } = makePagedFetch([
      // Two full pages of ONE repeated old date: non-increasing and
      // boundary-consistent, but direction-neutral — on an ascending feed
      // these could precede in-window data. Must NOT arm/confirm.
      { dataPoints: [{ date: '2026-07-05' }, { date: '2026-07-05' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-05' }, { date: '2026-07-05' }], nextPageToken: 'p3' },
      // ascending feed reveals in-window data later (boundary violation here)
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-07' }], nextPageToken: 'p4' },
      { dataPoints: [{ date: '2026-06-30' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(4); // all pages fetched — the 07-07/07-08 rows survive
    expect(result).toHaveLength(7);
  });

  test('strict cross-page decrease proves direction — ties alone within pages can then arm', async () => {
    const { impl, calls } = makePagedFetch([
      // page 1: tie-only (no proof yet, no arm)
      { dataPoints: [{ date: '2026-07-05' }, { date: '2026-07-05' }], nextPageToken: 'p2' },
      // page 2: newest 07-04 < page 1's oldest 07-05 — STRICT cross-page
      // decrease proves descending; page is pre-window → arm
      { dataPoints: [{ date: '2026-07-04' }, { date: '2026-07-04' }], nextPageToken: 'p3' },
      // page 3: confirm → break
      { dataPoints: [{ date: '2026-07-03' }, { date: '2026-07-03' }], nextPageToken: 'p4' },
      // never reached
      { dataPoints: [{ date: '2026-07-02' }], nextPageToken: 'p5' },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(3);
    expect(result).toHaveLength(6);
  });

  test('tied adjacent dates count as non-increasing (arm + confirm still fire)', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-08' }, { date: '2026-07-04' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-03' }, { date: '2026-07-03' }], nextPageToken: 'p3' },
      { dataPoints: [{ date: '2026-07-02' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2); // page 2 confirms the stop
    expect(result).toHaveLength(5);
  });

  test('single-point page never CONFIRMS a stop — armed state persists to the next 2-point page', async () => {
    const { impl, calls } = makePagedFetch([
      // page 1 arms (oldest 07-04 clears the slacked threshold 07-05)
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-04' }], nextPageToken: 'p2' },
      // page 2: single below-threshold point — direction-blind, must NOT confirm
      { dataPoints: [{ date: '2026-07-03' }], nextPageToken: 'p3' },
      // page 3: 2-point verified below-threshold page — NOW the stop confirms
      { dataPoints: [{ date: '2026-07-02' }, { date: '2026-07-01' }], nextPageToken: 'p4' },
      // never reached
      { dataPoints: [{ date: '2026-06-30' }], nextPageToken: 'p5' },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(3); // p2 (single) fetched, p3 confirms, p4 never
    expect(result).toHaveLength(5);
  });

  test('disorder revealed after a single-point page still fails closed (no data dropped)', async () => {
    const { impl, calls } = makePagedFetch([
      // page 1 arms (oldest 07-04 clears the slacked threshold 07-05)
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-04' }], nextPageToken: 'p2' },
      // page 2: single old point — stays armed, does not confirm
      { dataPoints: [{ date: '2026-07-03' }], nextPageToken: 'p3' },
      // page 3: newest 07-07 exceeds page 2's oldest (07-03) — boundary
      // violation reveals IN-WINDOW data → distrust, full paging
      { dataPoints: [{ date: '2026-07-07' }, { date: '2026-07-01' }], nextPageToken: 'p4' },
      { dataPoints: [{ date: '2026-06-30' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'heart-rate',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(4); // all pages fetched — the 07-07 row survives
    expect(result).toHaveLength(6);
  });

  test('single-point page never arms (cannot establish ordering direction)', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-07-01' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-06-30' }] },
    ]);

    const result = await fetchDataPoints(
      {
        dataTypeId: 'steps',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2); // lone pre-window point must not stop paging
    expect(result).toHaveLength(2);
  });

  test('page with one unparseable date among parseable ones: keeps paging', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-07-06' }, { bogus: true }, { date: '2026-07-05' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-04' }] },
    ]);

    await fetchDataPoints(
      {
        dataTypeId: 'steps',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2); // unverifiable page → no early-stop
  });

  test('fully unparseable page: keeps paging (no early-stop)', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ bogus: true }, { bogus: true }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-08' }] },
    ]);

    await fetchDataPoints(
      {
        dataTypeId: 'steps',
        accessToken: 'tok',
        baseUrl: 'https://fake.api/v4',
        earlyStop: stop('2026-07-07'),
      },
      impl,
    );

    expect(calls).toHaveLength(2);
  });

  test('no earlyStop: legacy full paging (backward compatible)', async () => {
    const { impl, calls } = makePagedFetch([
      { dataPoints: [{ date: '2026-07-08' }, { date: '2026-07-06' }], nextPageToken: 'p2' },
      { dataPoints: [{ date: '2026-07-05' }] },
    ]);

    const result = await fetchDataPoints(
      { dataTypeId: 'steps', accessToken: 'tok', baseUrl: 'https://fake.api/v4' },
      impl,
    );

    expect(calls).toHaveLength(2);
    expect(result).toHaveLength(3);
  });

  test('GOOGLE_HEALTH_PAGE_CAP env override raises the cap', async () => {
    const prev = process.env.GOOGLE_HEALTH_PAGE_CAP;
    process.env.GOOGLE_HEALTH_PAGE_CAP = '3';
    try {
      let caught: unknown;
      let pages = 0;
      const countingInfinite = async (_url: string, _init?: RequestInit) => {
        pages++;
        return {
          ok: true as const,
          status: 200,
          json: async () => ({ dataPoints: [], nextPageToken: 'more' }),
        };
      };
      try {
        await fetchDataPoints(
          { dataTypeId: 'steps', accessToken: 'tok', baseUrl: 'https://fake.api/v4' },
          countingInfinite,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught).toBeInstanceOf(Error);
      expect((caught as Error).message).toContain('(3)');
      expect(pages).toBe(3);
    } finally {
      if (prev === undefined) delete process.env.GOOGLE_HEALTH_PAGE_CAP;
      else process.env.GOOGLE_HEALTH_PAGE_CAP = prev;
    }
  });

  test('invalid GOOGLE_HEALTH_PAGE_CAP falls back to the default cap (100)', async () => {
    const prev = process.env.GOOGLE_HEALTH_PAGE_CAP;
    process.env.GOOGLE_HEALTH_PAGE_CAP = 'abc';
    try {
      let caught: unknown;
      try {
        await fetchDataPoints(
          { dataTypeId: 'steps', accessToken: 'tok', baseUrl: 'https://fake.api/v4' },
          makeInfiniteFetch(),
        );
      } catch (e) {
        caught = e;
      }
      expect(caught).toBeInstanceOf(Error);
      expect((caught as Error).message).toContain('(100)');
    } finally {
      if (prev === undefined) delete process.env.GOOGLE_HEALTH_PAGE_CAP;
      else process.env.GOOGLE_HEALTH_PAGE_CAP = prev;
    }
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
