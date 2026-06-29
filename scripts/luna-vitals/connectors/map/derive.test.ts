import { describe, test, expect } from 'bun:test';
import { join } from 'path';
import { aggregateRows, deriveRestingHeartRate, deriveSleep } from './derive';
import { extractRows } from './shape';
import { MAPPINGS } from './table';

const FIXTURES_DIR = join(import.meta.dir, '../__fixtures__');

async function loadFixture(name: string): Promise<{ dataPoints?: unknown[] }> {
  return Bun.file(join(FIXTURES_DIR, `${name}.json`)).json();
}

const findByTypeId = (dataTypeId: string) =>
  MAPPINGS.find((mp) => mp.dataTypeId === dataTypeId)!;

// ── aggregateRows ─────────────────────────────────────────────────────────────

describe('aggregateRows', () => {
  test('steps fixture — two different-day intervals stay as 2 rows (no cross-day merging)', async () => {
    const fixture = await loadFixture('steps');
    const mapping = findByTypeId('steps');
    const rows = extractRows(mapping, fixture);
    // fixture has one point on 2026-06-28 (count "1234") and one on 2026-06-27 (count "876")
    const agg = aggregateRows(mapping, rows);

    expect(agg.length).toBe(2);
    expect(agg.some((r) => r.date === '2026-06-28')).toBe(true);
    expect(agg.some((r) => r.date === '2026-06-27')).toBe(true);
    // single-day rows are passed through unchanged (value = 1234)
    const jun28 = agg.find((r) => r.date === '2026-06-28')!;
    expect(jun28.value).toBe(1234);
    const jun27 = agg.find((r) => r.date === '2026-06-27')!;
    expect(jun27.value).toBe(876);
  });

  test('sum — same-day: 1000 + 500 = 1500 (integer, steps)', () => {
    const mapping = findByTypeId('steps');
    const rows = [
      {
        metric: 'steps',
        date: '2026-06-28',
        value: 1000,
        source: 'google-health:steps:HEALTH_CONNECT',
      },
      {
        metric: 'steps',
        date: '2026-06-28',
        value: 500,
        source: 'google-health:steps:HEALTH_CONNECT',
      },
    ];
    const agg = aggregateRows(mapping, rows);

    expect(agg.length).toBe(1);
    expect(agg[0].date).toBe('2026-06-28');
    expect(agg[0].value).toBe(1500);
    expect(Number.isInteger(agg[0].value)).toBe(true);
    expect(agg[0].metric).toBe('steps');
  });

  test('sum — cross-day isolation: same rows on different dates remain separate', () => {
    const mapping = findByTypeId('steps');
    const rows = [
      {
        metric: 'steps',
        date: '2026-06-27',
        value: 400,
        source: 'google-health:steps:HEALTH_CONNECT',
      },
      {
        metric: 'steps',
        date: '2026-06-28',
        value: 600,
        source: 'google-health:steps:HEALTH_CONNECT',
      },
    ];
    const agg = aggregateRows(mapping, rows);

    expect(agg.length).toBe(2);
    expect(agg.find((r) => r.date === '2026-06-27')!.value).toBe(400);
    expect(agg.find((r) => r.date === '2026-06-28')!.value).toBe(600);
  });

  test('mean — same-day: (30 + 50) / 2 = 40 (hrv_ms inline)', () => {
    const mapping = findByTypeId('heart-rate-variability');
    const rows = [
      {
        metric: 'hrv_ms',
        date: '2026-06-28',
        value: 30,
        source: 'google-health:heart-rate-variability:HEALTH_CONNECT',
      },
      {
        metric: 'hrv_ms',
        date: '2026-06-28',
        value: 50,
        source: 'google-health:heart-rate-variability:HEALTH_CONNECT',
      },
    ];
    const agg = aggregateRows(mapping, rows);

    expect(agg.length).toBe(1);
    expect(agg[0].value).toBe(40);
    expect(agg[0].metric).toBe('hrv_ms');
  });

  test('mean — single-point day: value unchanged', () => {
    const mapping = findByTypeId('heart-rate-variability');
    const rows = [
      {
        metric: 'hrv_ms',
        date: '2026-06-28',
        value: 35.5,
        source: 'google-health:heart-rate-variability:HEALTH_CONNECT',
      },
    ];
    const agg = aggregateRows(mapping, rows);

    expect(agg.length).toBe(1);
    expect(agg[0].value).toBe(35.5);
  });

  test('none — rows passed through unchanged (no collapsing)', () => {
    const mapping = findByTypeId('daily-resting-heart-rate');
    const rows = [
      {
        metric: 'daily_rhr_bpm',
        date: '2026-06-28',
        value: 65,
        source: 'google-health:daily-resting-heart-rate:FITBIT',
      },
    ];
    const agg = aggregateRows(mapping, rows);
    expect(agg).toEqual(rows);
  });

  test('last — same-date two readings: keeps lexicographically latest source', () => {
    // HEALTH_CONNECT > FITBIT lexicographically → HEALTH_CONNECT row wins
    const mapping = findByTypeId('weight');
    const rows = [
      {
        metric: 'weight_kg',
        date: '2026-06-28',
        value: 90.0,
        source: 'google-health:weight:FITBIT',
      },
      {
        metric: 'weight_kg',
        date: '2026-06-28',
        value: 91.0,
        source: 'google-health:weight:HEALTH_CONNECT',
      },
    ];
    const agg = aggregateRows(mapping, rows);

    expect(agg.length).toBe(1);
    expect(agg[0].value).toBe(91.0);
    expect(agg[0].source).toBe('google-health:weight:HEALTH_CONNECT');
  });

  test('last — same-date same-source: keeps last row in input order', () => {
    const mapping = findByTypeId('weight');
    const rows = [
      {
        metric: 'weight_kg',
        date: '2026-06-28',
        value: 90.0,
        source: 'google-health:weight:HEALTH_CONNECT',
      },
      {
        metric: 'weight_kg',
        date: '2026-06-28',
        value: 91.5,
        source: 'google-health:weight:HEALTH_CONNECT',
      },
    ];
    const agg = aggregateRows(mapping, rows);

    expect(agg.length).toBe(1);
    // second row is the last in input order and has the same source → wins
    expect(agg[0].value).toBe(91.5);
  });

  test('empty input → []', () => {
    expect(aggregateRows(findByTypeId('steps'), [])).toEqual([]);
  });
});

// ── deriveRestingHeartRate ────────────────────────────────────────────────────

describe('deriveRestingHeartRate', () => {
  test('heart-rate fixture: rhr near low end (5th pctile ≈ 59), integer, date 2026-06-28', async () => {
    // Fixture has two samples on 2026-06-28: bpm "81" and "58".
    // 5th percentile of sorted [58, 81]: h = 0.05, value = 58 + 0.05*(81-58) ≈ 59.15 → 59
    const fixture = await loadFixture('heart-rate');
    const rows = deriveRestingHeartRate(fixture);

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('rhr_bpm');
    expect(rows[0].date).toBe('2026-06-28');
    expect(Number.isInteger(rows[0].value)).toBe(true);
    // 5th percentile of [58, 81] ≈ 59 — near the low end, well below the mean of 69.5
    expect(rows[0].value).toBeGreaterThanOrEqual(58);
    expect(rows[0].value).toBeLessThanOrEqual(62);
    expect(rows[0].source).toBe('google-health:heart-rate:HEALTH_CONNECT');
  });

  test('single-sample day: rhr equals that sample (rounded)', () => {
    const fixture = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          heartRate: {
            sampleTime: {
              civilTime: { date: { year: 2026, month: 6, day: 28 } },
            },
            beatsPerMinute: '63',
          },
        },
      ],
    };
    const rows = deriveRestingHeartRate(fixture);
    expect(rows.length).toBe(1);
    expect(rows[0].value).toBe(63);
  });

  test('empty dataPoints → []', () => {
    expect(deriveRestingHeartRate({ dataPoints: [] })).toEqual([]);
    expect(deriveRestingHeartRate({})).toEqual([]);
  });

  test('multi-day samples: one row per day', () => {
    const fixture = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          heartRate: {
            sampleTime: {
              civilTime: { date: { year: 2026, month: 6, day: 27 } },
            },
            beatsPerMinute: '70',
          },
        },
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          heartRate: {
            sampleTime: {
              civilTime: { date: { year: 2026, month: 6, day: 28 } },
            },
            beatsPerMinute: '65',
          },
        },
      ],
    };
    const rows = deriveRestingHeartRate(fixture);
    expect(rows.length).toBe(2);
    expect(rows.some((r) => r.date === '2026-06-27')).toBe(true);
    expect(rows.some((r) => r.date === '2026-06-28')).toBe(true);
  });
});

// ── deriveSleep ───────────────────────────────────────────────────────────────

describe('deriveSleep', () => {
  test('2026-06-28: main session 8h31m (sleep_hours=8.5); nap excluded from main value', async () => {
    // Fixture: session 1 (01:24Z–09:55Z = 511 min = main) + session 2 nap (14:00Z–14:40Z = 40 min).
    // Both end on 2026-06-28 local (UTC+2). Main = session 1 (511 > 40).
    const fixture = await loadFixture('sleep');
    const rows = deriveSleep(fixture);

    const hoursRow = rows.find((r) => r.metric === 'sleep_hours' && r.date === '2026-06-28');
    expect(hoursRow).toBeDefined();
    // 511 min / 60 = 8.5167 → 8.5 (NOT 8.5 + 0.7 from nap)
    expect(hoursRow!.value).toBe(8.5);
  });

  test('2026-06-28: sleep_asleep_hours < sleep_hours (main session has AWAKE segment)', async () => {
    // Main session (01:24Z–09:55Z) starts with 20 min AWAKE stage.
    // Non-AWAKE stages sum: 86+55+50+95+45+55+105 = 491 min = 8.183→ 8.2 h
    const fixture = await loadFixture('sleep');
    const rows = deriveSleep(fixture);

    const hoursRow = rows.find((r) => r.metric === 'sleep_hours' && r.date === '2026-06-28')!;
    const asleepRow = rows.find(
      (r) => r.metric === 'sleep_asleep_hours' && r.date === '2026-06-28',
    );
    expect(asleepRow).toBeDefined();
    expect(asleepRow!.value).toBe(8.2);
    expect(asleepRow!.value).toBeLessThan(hoursRow.value);
  });

  test('midnight-cross session → date = 2026-06-27 (local end date, not start date)', async () => {
    // Session 3: 2026-06-26T22:30Z – 2026-06-27T05:30Z, endUtcOffset "7200s"
    // Local end: 05:30Z + 2h = 07:30 → date 2026-06-27. Duration = 7h exactly.
    const fixture = await loadFixture('sleep');
    const rows = deriveSleep(fixture);

    const hoursRow = rows.find((r) => r.metric === 'sleep_hours' && r.date === '2026-06-27');
    expect(hoursRow).toBeDefined();
    expect(hoursRow!.value).toBe(7.0);
    // Start date (2026-06-26) must NOT appear in output.
    expect(rows.some((r) => r.date === '2026-06-26')).toBe(false);
  });

  test('all emitted rows have correct metric, valid date, finite value, typed source', async () => {
    const fixture = await loadFixture('sleep');
    const rows = deriveSleep(fixture);

    // fixture has sessions on 2026-06-27 and 2026-06-28 → 4 rows total (2 per date)
    expect(rows.length).toBe(4);
    for (const row of rows) {
      expect(row.metric).toMatch(/^sleep_(hours|asleep_hours)$/);
      expect(row.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(typeof row.value).toBe('number');
      expect(Number.isFinite(row.value)).toBe(true);
      expect(row.source).toMatch(/^google-health:sleep:/);
    }
  });

  test('empty dataPoints → []', () => {
    expect(deriveSleep({ dataPoints: [] })).toEqual([]);
    expect(deriveSleep({})).toEqual([]);
  });
});
