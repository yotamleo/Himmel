import { describe, test, expect } from 'bun:test';
import { readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { pull } from './google-health';
import { ReconsentNeededError, RECONSENT_EXIT } from './auth/oauth';
import { validateRow, writeArtifact } from '../src/types';

// ── fixture loader ────────────────────────────────────────────────────────────

const FIXTURE_DIR = join(import.meta.dir, '__fixtures__');

function loadFixture(name: string): { dataPoints: unknown[] } {
  return JSON.parse(readFileSync(join(FIXTURE_DIR, `${name}.json`), 'utf-8'));
}

// Pre-load fixtures keyed by dataTypeId.
// Unmapped dataTypeIds return { dataPoints: [] } in the fake fetchImpl below.
const FIXTURE_MAP: Record<string, { dataPoints: unknown[] }> = {
  'heart-rate': loadFixture('heart-rate'),
  'sleep': loadFixture('sleep'),
  'daily-resting-heart-rate': loadFixture('daily-resting-heart-rate'),
  'daily-oxygen-saturation': loadFixture('daily-oxygen-saturation'),
  'steps': loadFixture('steps'),
  'weight': loadFixture('weight'),
};

// ── fake fetchImpl ────────────────────────────────────────────────────────────

type FakeResponse = { ok: boolean; status: number; json(): Promise<unknown> };

/**
 * Routes by URL:
 *   - oauth2.googleapis.com/token → tokenOverride ?? { access_token: 't' }
 *   - .../dataTypes/<id>/dataPoints → FIXTURE_MAP[id] ?? { dataPoints: [] }
 *   - anything else → { dataPoints: [] }
 */
function makeFakeFetch(tokenOverride?: { ok: boolean; status: number; body: unknown }) {
  return async (url: string, _init?: RequestInit): Promise<FakeResponse> => {
    if (url.includes('oauth2.googleapis.com/token')) {
      const resp = tokenOverride ?? {
        ok: true,
        status: 200,
        body: { access_token: 't', token_type: 'Bearer' },
      };
      return { ok: resp.ok, status: resp.status, json: async () => resp.body };
    }

    const match = url.match(/\/dataTypes\/([^/?]+)\/dataPoints/);
    if (match) {
      const dataTypeId = match[1];
      const fixture = FIXTURE_MAP[dataTypeId] ?? { dataPoints: [] };
      return { ok: true, status: 200, json: async () => fixture };
    }

    return { ok: true, status: 200, json: async () => ({ dataPoints: [] }) };
  };
}

const FAKE_CFG = {
  clientId: 'fake-cid',
  clientSecret: 'fake-csec',
  refreshToken: 'fake-rtoken',
};

// ── helpers ───────────────────────────────────────────────────────────────────

/** Cast the fake fetchImpl to the pull() parameter type. */
function asFetch(fake: ReturnType<typeof makeFakeFetch>): typeof fetch {
  return fake as unknown as typeof fetch;
}

// ── tests ─────────────────────────────────────────────────────────────────────

describe('pull', () => {
  test('returns ReviewArtifact with expected derived and direct metrics', async () => {
    const artifact = await pull({
      from: '2024-01-01',
      to: '2026-12-31',
      cfg: FAKE_CFG,
      fetchImpl: asFetch(makeFakeFetch()),
    });

    expect(artifact.bucket).toBe('2024-01-01..2026-12-31');
    expect(Array.isArray(artifact.rows)).toBe(true);
    expect(Array.isArray(artifact.conflicts)).toBe(true);
    expect(artifact.conflicts).toHaveLength(0);
    expect(artifact.rows.length).toBeGreaterThan(0);

    const metrics = new Set(artifact.rows.map((r) => r.metric));

    // heart-rate → 5th-percentile derivation → rhr_bpm
    expect(metrics.has('rhr_bpm')).toBe(true);
    // sleep → both asleep duration and time-in-bed
    expect(metrics.has('sleep_hours')).toBe(true);
    expect(metrics.has('sleep_in_bed_hours')).toBe(true);
    // daily-oxygen-saturation → daily_spo2_pct
    expect(metrics.has('daily_spo2_pct')).toBe(true);
    // steps fixture
    expect(metrics.has('steps')).toBe(true);
    // weight fixture
    expect(metrics.has('weight_kg')).toBe(true);
  });

  test('every row passes validateRow', async () => {
    const artifact = await pull({
      from: '2024-01-01',
      to: '2026-12-31',
      cfg: FAKE_CFG,
      fetchImpl: asFetch(makeFakeFetch()),
    });

    for (const row of artifact.rows) {
      // validateRow throws on invalid date / non-finite value / empty metric or source.
      expect(() => validateRow(row)).not.toThrow();
    }
  });

  test('rows are sorted: metric asc, then date asc', async () => {
    const artifact = await pull({
      from: '2024-01-01',
      to: '2026-12-31',
      cfg: FAKE_CFG,
      fetchImpl: asFetch(makeFakeFetch()),
    });

    for (let i = 1; i < artifact.rows.length; i++) {
      const prev = artifact.rows[i - 1];
      const curr = artifact.rows[i];
      const cmp =
        prev.metric < curr.metric
          ? -1
          : prev.metric > curr.metric
            ? 1
            : prev.date < curr.date
              ? -1
              : prev.date > curr.date
                ? 1
                : 0;
      expect(cmp).toBeLessThanOrEqual(0);
    }
  });

  test('date window filters out-of-range rows', async () => {
    // Narrow to a single date; steps fixture has 2026-06-28 + 2026-06-27.
    // weight fixture has 2026-06-21 — should be excluded.
    const artifact = await pull({
      from: '2026-06-28',
      to: '2026-06-28',
      cfg: FAKE_CFG,
      fetchImpl: asFetch(makeFakeFetch()),
    });

    for (const row of artifact.rows) {
      expect(row.date).toBe('2026-06-28');
    }
    // steps on 2026-06-28 (count "1234" in fixture)
    const stepRows = artifact.rows.filter((r) => r.metric === 'steps');
    expect(stepRows.length).toBeGreaterThan(0);
    // weight is 2026-06-21 — must be excluded
    const weightRows = artifact.rows.filter((r) => r.metric === 'weight_kg');
    expect(weightRows).toHaveLength(0);
  });

  test('determinism: two pulls with identical inputs produce identical JSON', async () => {
    const fakeFetch = asFetch(makeFakeFetch());
    const opts = { from: '2024-01-01', to: '2026-12-31', cfg: FAKE_CFG, fetchImpl: fakeFetch };
    const a1 = await pull(opts);
    const a2 = await pull(opts);
    expect(JSON.stringify(a1)).toBe(JSON.stringify(a2));
  });

  test('artifact passes writeArtifact validation (validates rows + conflicts)', async () => {
    const artifact = await pull({
      from: '2024-01-01',
      to: '2026-12-31',
      cfg: FAKE_CFG,
      fetchImpl: asFetch(makeFakeFetch()),
    });
    const tmpPath = join(tmpdir(), `gh-connector-test-${Date.now()}.json`);
    // writeArtifact runs validateRow on every row; throws if any row is malformed.
    await expect(writeArtifact(tmpPath, artifact)).resolves.toBeUndefined();
  });

  test('earlyStop wiring: heart-rate pages bounded to 2 fetches (arm + confirm)', async () => {
    // A heart-rate endpoint that would page FOREVER without early-stop: every
    // response carries a nextPageToken and serves 2 descending, pre-window
    // sample points (all dates in May 2026, before the pull's from=2026-06-01).
    // If windowFrom + pointDate did NOT thread through pull() to the fetch layer,
    // this would page until the cap and throw. With early-stop it stops after the
    // arming page + the confirming page = exactly 2 calls.
    const state = { heartRateCalls: 0 };

    // pageNum (1-based) → 2 descending heart-rate points, each page older than the last.
    // Page 1: 2026-05-28, 2026-05-27; page 2: 2026-05-26, 2026-05-25; … — all
    // below the slacked stop threshold (from=2026-06-01 minus 2-day slack = 05-30),
    // so page 1 arms and page 2 confirms.
    function heartRatePage(pageNum: number): unknown[] {
      const baseMs = Date.UTC(2026, 4, 28); // 2026-05-28
      const idx0 = (pageNum - 1) * 2;
      return [0, 1].map((k) => {
        const d = new Date(baseMs - (idx0 + k) * 86_400_000);
        const y = d.getUTCFullYear();
        const m = d.getUTCMonth() + 1;
        const day = d.getUTCDate();
        return {
          dataSource: { recordingMethod: 'UNKNOWN', platform: 'HEALTH_CONNECT' },
          heartRate: {
            sampleTime: {
              physicalTime: `${y}-${String(m).padStart(2, '0')}-${String(day).padStart(2, '0')}T12:00:00Z`,
              utcOffset: '0s',
              civilTime: { date: { year: y, month: m, day }, time: { hours: 12, minutes: 0 } },
            },
            beatsPerMinute: String(60 + k),
            metadata: {},
          },
        };
      });
    }

    const earlyStopFetch = async (url: string, _init?: RequestInit): Promise<FakeResponse> => {
      if (url.includes('oauth2.googleapis.com/token')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({ access_token: 't', token_type: 'Bearer' }),
        };
      }
      const match = url.match(/\/dataTypes\/([^/?]+)\/dataPoints/);
      if (match && match[1] === 'heart-rate') {
        state.heartRateCalls++;
        const page = state.heartRateCalls;
        // nextPageToken on EVERY response → infinite without early-stop.
        return {
          ok: true,
          status: 200,
          json: async () => ({ dataPoints: heartRatePage(page), nextPageToken: `p${page + 1}` }),
        };
      }
      // Every other dataType: single empty page (no token → stops immediately).
      return { ok: true, status: 200, json: async () => ({ dataPoints: [] }) };
    };

    const artifact = await pull({
      from: '2026-06-01',
      to: '2026-06-30',
      cfg: FAKE_CFG,
      fetchImpl: earlyStopFetch as unknown as typeof fetch,
    });

    // (a) completes — did not throw the page-cap error.
    expect(artifact.bucket).toBe('2026-06-01..2026-06-30');
    // (b) bounded: arming page + confirming page = exactly 2 heart-rate fetches.
    expect(state.heartRateCalls).toBe(2);
  });

  test('reconsent: invalid_grant token response rejects with ReconsentNeededError (exitCode 75)', async () => {
    const fetchImpl = asFetch(
      makeFakeFetch({ ok: false, status: 400, body: { error: 'invalid_grant' } }),
    );

    let caught: unknown;
    try {
      await pull({ from: '2024-01-01', to: '2026-12-31', cfg: FAKE_CFG, fetchImpl });
    } catch (e) {
      caught = e;
    }

    expect(caught).toBeInstanceOf(ReconsentNeededError);
    const err = caught as ReconsentNeededError;
    expect(err.exitCode).toBe(RECONSENT_EXIT);
    expect(err.exitCode).toBe(75);
    // Error message must mention re-consent but must NOT leak the refresh token.
    expect(err.message.toLowerCase()).toContain('re-consent');
    expect(err.message).not.toContain('fake-rtoken');
  });

  test('degraded sleep date → artifact carries the warning in warnings[]', async () => {
    // A sleep payload whose main session has a malformed non-AWAKE stage → degraded.
    // pull must surface the deriveSleep warning durably on the returned artifact
    // (HIMMEL-794); row emission is unchanged (sleep_in_bed_hours only).
    const degradedSleep = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-01-01T22:00:00Z',
              startUtcOffset: '0s',
              endTime: '2026-01-02T06:00:00Z',
              endUtcOffset: '0s',
            },
            stages: [
              { startTime: '2026-01-01T22:00:00Z', endTime: '2026-01-02T02:00:00Z', type: 'LIGHT' },
              { startTime: 'not-a-timestamp', endTime: 'also-garbage', type: 'DEEP' },
            ],
          },
        },
      ],
    };

    const degradedFetch = async (url: string, _init?: RequestInit): Promise<FakeResponse> => {
      if (url.includes('oauth2.googleapis.com/token')) {
        return { ok: true, status: 200, json: async () => ({ access_token: 't', token_type: 'Bearer' }) };
      }
      const match = url.match(/\/dataTypes\/([^/?]+)\/dataPoints/);
      if (match && match[1] === 'sleep') {
        return { ok: true, status: 200, json: async () => degradedSleep };
      }
      return { ok: true, status: 200, json: async () => ({ dataPoints: [] }) };
    };

    const artifact = await pull({
      from: '2024-01-01',
      to: '2026-12-31',
      cfg: FAKE_CFG,
      fetchImpl: degradedFetch as unknown as typeof fetch,
    });

    expect(artifact.warnings).toContain(
      'sleep 2026-01-02: malformed stage timestamps - sleep_hours omitted (degraded stage data)',
    );
    const inBedRow = artifact.rows.find(
      (r) => r.metric === 'sleep_in_bed_hours' && r.date === '2026-01-02',
    );
    expect(inBedRow).toBeDefined();
    expect(inBedRow!.value).toBe(8.0);
    expect(artifact.rows.some((r) => r.metric === 'sleep_hours')).toBe(false);
  });

  test('clean pull → warnings key is ABSENT (undefined, not [])', async () => {
    // The fixtures are clean (no degraded/dropped/non-array sleep) → pull omits the
    // warnings key entirely, so a clean artifact is byte-identical to pre-HIMMEL-794.
    const artifact = await pull({
      from: '2024-01-01',
      to: '2026-12-31',
      cfg: FAKE_CFG,
      fetchImpl: asFetch(makeFakeFetch()),
    });
    expect(artifact.warnings).toBeUndefined();
  });

  /** Builds a fake fetchImpl that serves `sleepFixture` for the sleep dataType and empty pages otherwise. */
  function sleepOnlyFetch(sleepFixture: { dataPoints: unknown[] }) {
    return async (url: string, _init?: RequestInit): Promise<FakeResponse> => {
      if (url.includes('oauth2.googleapis.com/token')) {
        return { ok: true, status: 200, json: async () => ({ access_token: 't', token_type: 'Bearer' }) };
      }
      const match = url.match(/\/dataTypes\/([^/?]+)\/dataPoints/);
      if (match && match[1] === 'sleep') {
        return { ok: true, status: 200, json: async () => sleepFixture };
      }
      return { ok: true, status: 200, json: async () => ({ dataPoints: [] }) };
    };
  }

  test('degraded sleep date OUTSIDE the pull window → artifact has NO warnings key (HIMMEL-794 Fix A)', async () => {
    // Same degraded session as above (date 2026-01-02), but the pull window
    // (2024-01-01..2025-01-01) does not cover it — the dated warning must be
    // window-dropped exactly like its row is (rows are already filtered by window).
    const degradedSleep = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-01-01T22:00:00Z',
              startUtcOffset: '0s',
              endTime: '2026-01-02T06:00:00Z',
              endUtcOffset: '0s',
            },
            stages: [
              { startTime: '2026-01-01T22:00:00Z', endTime: '2026-01-02T02:00:00Z', type: 'LIGHT' },
              { startTime: 'not-a-timestamp', endTime: 'also-garbage', type: 'DEEP' },
            ],
          },
        },
      ],
    };

    const artifact = await pull({
      from: '2024-01-01',
      to: '2025-01-01',
      cfg: FAKE_CFG,
      fetchImpl: sleepOnlyFetch(degradedSleep) as unknown as typeof fetch,
    });

    expect(artifact.warnings).toBeUndefined();
    expect(artifact.rows.some((r) => r.date === '2026-01-02')).toBe(false);
  });

  test('no-date-derivable dropped session → warning is kept regardless of window (undateable = conservative keep)', async () => {
    // A session with no civilEndTime and no endUtcOffset has no derivable date, so
    // the warning's `date` is undefined — it must be kept no matter what the pull
    // window is (HIMMEL-794 Fix A: `!w.date` always keeps).
    const droppedSleep = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-01-01T22:00:00Z',
              endTime: '2026-01-02T06:00:00Z',
            },
          },
        },
      ],
    };

    const artifact = await pull({
      from: '2020-01-01',
      to: '2020-01-02',
      cfg: FAKE_CFG,
      fetchImpl: sleepOnlyFetch(droppedSleep) as unknown as typeof fetch,
    });

    expect(artifact.warnings).toContain(
      'sleep dataPoint 0 ending 2026-01-02T06:00:00Z: no civilEndTime and no endUtcOffset - session dropped',
    );
  });

  test('missing-startTime session with civilEndTime OUTSIDE the pull window → artifact has NO warnings key (CR round 2)', async () => {
    // The missing-interval warning is DATED when an end date is derivable
    // (civilEndTime here), so it must be window-scoped like any other dated
    // warning — an out-of-window malformed session must not pollute this artifact.
    const missingStartSleep = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              endTime: '2026-01-02T06:00:00Z',
              civilEndTime: { date: { year: 2026, month: 1, day: 2 } },
            },
          },
        },
      ],
    };

    const artifact = await pull({
      from: '2024-01-01',
      to: '2025-01-01',
      cfg: FAKE_CFG,
      fetchImpl: sleepOnlyFetch(missingStartSleep) as unknown as typeof fetch,
    });

    expect(artifact.warnings).toBeUndefined();
  });

  test('one pull producing two distinct warnings (dropped session + degraded date) → both present, in order', async () => {
    // First data point: dropped (no civilEndTime/endUtcOffset, no date). Second:
    // a valid, in-window main session degraded by a malformed non-AWAKE stage.
    // Parse-loop warnings (the drop) precede per-date warnings (the degradation) —
    // the two-phase order documented on deriveSleep.
    const twoWarningsSleep = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-05-01T22:00:00Z',
              endTime: '2026-05-02T06:00:00Z',
            },
          },
        },
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-01-01T22:00:00Z',
              startUtcOffset: '0s',
              endTime: '2026-01-02T06:00:00Z',
              endUtcOffset: '0s',
            },
            stages: [
              { startTime: '2026-01-01T22:00:00Z', endTime: '2026-01-02T02:00:00Z', type: 'LIGHT' },
              { startTime: 'not-a-timestamp', endTime: 'also-garbage', type: 'DEEP' },
            ],
          },
        },
      ],
    };

    const artifact = await pull({
      from: '2024-01-01',
      to: '2026-12-31',
      cfg: FAKE_CFG,
      fetchImpl: sleepOnlyFetch(twoWarningsSleep) as unknown as typeof fetch,
    });

    expect(artifact.warnings).toEqual([
      'sleep dataPoint 0 ending 2026-05-02T06:00:00Z: no civilEndTime and no endUtcOffset - session dropped',
      'sleep 2026-01-02: malformed stage timestamps - sleep_hours omitted (degraded stage data)',
    ]);
  });
});
