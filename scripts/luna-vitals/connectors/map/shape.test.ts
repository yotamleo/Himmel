import { describe, test, expect } from 'bun:test';
import { join } from 'path';
import { extractRows } from './shape';
import { MAPPINGS } from './table';

const FIXTURES_DIR = join(import.meta.dir, '../__fixtures__');

async function loadFixture(name: string): Promise<{ dataPoints?: unknown[] }> {
  return Bun.file(join(FIXTURES_DIR, `${name}.json`)).json();
}

const findByTypeId = (dataTypeId: string) =>
  MAPPINGS.find((mp) => mp.dataTypeId === dataTypeId)!;
const findByMetric = (metricName: string) =>
  MAPPINGS.find((mp) => mp.metric === metricName)!;

// ── Daily category ────────────────────────────────────────────────────────────

describe('extractRows — daily category', () => {
  test('daily-resting-heart-rate: 2 rows, value 77 (string→number), date "2024-09-16", FITBIT source', async () => {
    const fixture = await loadFixture('daily-resting-heart-rate');
    const mapping = findByTypeId('daily-resting-heart-rate');
    const rows = extractRows(mapping, fixture);

    expect(rows.length).toBe(2);

    const row = rows.find((r) => r.date === '2024-09-16');
    expect(row).toBeDefined();
    expect(row!.metric).toBe('daily_rhr_bpm');
    // value comes from the string "77" — assert numeric type and value
    expect(typeof row!.value).toBe('number');
    expect(row!.value).toBe(77);
    expect(row!.date).toBe('2024-09-16');
    expect(row!.source).toBe('google-health:daily-resting-heart-rate:FITBIT');
  });

  test('daily dates are exact ISO strings — no host-TZ dependence', async () => {
    // Civil dates come from {year, month, day} — no timezone arithmetic.
    const fixture = await loadFixture('daily-resting-heart-rate');
    const rows = extractRows(findByTypeId('daily-resting-heart-rate'), fixture);
    const dates = rows.map((r) => r.date).sort();
    expect(dates).toEqual(['2024-09-15', '2024-09-16']);
  });
});

// ── Sample category ───────────────────────────────────────────────────────────

describe('extractRows — sample category', () => {
  test('weight: weightGrams 94300 (number) → 94.3 kg', async () => {
    const fixture = await loadFixture('weight');
    const rows = extractRows(findByTypeId('weight'), fixture);

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('weight_kg');
    expect(rows[0].value).toBe(94.3);
    expect(rows[0].date).toBe('2026-06-21');
    expect(rows[0].source).toBe('google-health:weight:FITBIT');
  });

  test('height: heightMillimeters "1810" (string) → 181 cm', async () => {
    const fixture = await loadFixture('height');
    const rows = extractRows(findByTypeId('height'), fixture);

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('height_cm');
    expect(rows[0].value).toBe(181);
    expect(rows[0].date).toBe('2016-05-19');
  });

  test('missing dataSource.platform → source ends ":unknown"', () => {
    // heart-rate (rhr_bpm) has aggregate:'derive' so extractRows returns [] (R4).
    // Demonstrate the :unknown fallback via an inline heart-rate-variability point
    // (sample category, scalar valuePath, aggregate:'mean') without a platform field.
    const inlinePoint = {
      dataSource: { recordingMethod: 'DERIVED' }, // no platform
      heartRateVariability: {
        sampleTime: {
          physicalTime: '2024-09-15T11:35:00Z',
          utcOffset: '0s',
          civilTime: {
            date: { year: 2024, month: 9, day: 15 },
            time: { hours: 11, minutes: 35 },
          },
        },
        rootMeanSquareOfSuccessiveDifferencesMilliseconds: 25.0,
      },
    };
    const rows = extractRows(findByTypeId('heart-rate-variability'), {
      dataPoints: [inlinePoint],
    });

    expect(rows.length).toBe(1);
    expect(rows[0].source).toEndWith(':unknown');
    expect(rows[0].source).toBe('google-health:heart-rate-variability:unknown');
  });
});

// ── Interval category ─────────────────────────────────────────────────────────

describe('extractRows — interval category', () => {
  test('distance: millimeters "5000000" (string) → 5 km', () => {
    // No distance fixture on disk — craft an inline point to verify km conversion.
    const distancePoint = {
      dataSource: { platform: 'HEALTH_CONNECT' },
      distance: {
        interval: {
          startTime: '2026-06-28T08:00:00Z',
          startUtcOffset: '7200s',
          endTime: '2026-06-28T09:00:00Z',
          endUtcOffset: '7200s',
        },
        millimeters: '5000000',
      },
    };
    const rows = extractRows(findByTypeId('distance'), { dataPoints: [distancePoint] });

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('distance_km');
    expect(rows[0].value).toBe(5);
    // endTime 09:00Z + 7200s → local 11:00 → 2026-06-28
    expect(rows[0].date).toBe('2026-06-28');
  });

  test('steps: count "6" (string) → 6 (number)', () => {
    // Inline point to verify string-to-number coercion on the count field.
    const stepsPoint = {
      dataSource: { platform: 'HEALTH_CONNECT' },
      steps: {
        interval: {
          startTime: '2026-06-28T08:00:00Z',
          startUtcOffset: '7200s',
          endTime: '2026-06-28T09:00:00Z',
          endUtcOffset: '7200s',
        },
        count: '6',
      },
    };
    const rows = extractRows(findByTypeId('steps'), { dataPoints: [stepsPoint] });

    expect(rows.length).toBe(1);
    expect(typeof rows[0].value).toBe('number');
    expect(rows[0].value).toBe(6);
  });

  test('steps fixture: 2 rows with correct local dates (endTime + offset)', async () => {
    const fixture = await loadFixture('steps');
    const rows = extractRows(findByTypeId('steps'), fixture);

    expect(rows.length).toBe(2);
    // endTime "2026-06-28T09:00:00Z" + 7200s → local 11:00 → 2026-06-28
    expect(rows.some((r) => r.date === '2026-06-28')).toBe(true);
    // endTime "2026-06-27T11:00:00Z" + 7200s → local 13:00 → 2026-06-27
    expect(rows.some((r) => r.date === '2026-06-27')).toBe(true);
    // all values are finite numbers (coerced from strings)
    expect(rows.every((r) => typeof r.value === 'number' && Number.isFinite(r.value))).toBe(true);
  });

  test('active-minutes: nested activeMinutesByActivityLevel[] sums string values to 8', () => {
    // Exercises the special branch in extractValue that sums array elements.
    // A field typo (e.g. activeMinutes vs activeMin) would silently drop all rows and still
    // pass without this test.
    const activeMinutesPoint = {
      dataSource: { platform: 'HEALTH_CONNECT' },
      activeMinutes: {
        interval: {
          startTime: '2026-06-28T08:00:00Z',
          endTime: '2026-06-28T09:00:00Z',
          endUtcOffset: '0s',
          civilEndTime: { date: { year: 2026, month: 6, day: 28 } },
        },
        activeMinutesByActivityLevel: [
          { activityLevel: 'LIGHT', activeMinutes: '5' },
          { activityLevel: 'MODERATE', activeMinutes: '3' },
        ],
      },
    };
    const rows = extractRows(findByTypeId('active-minutes'), { dataPoints: [activeMinutesPoint] });

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('active_minutes');
    expect(rows[0].value).toBe(8);
    expect(rows[0].date).toBe('2026-06-28');
  });

  test('exercise: duration 30 min (17:00Z–17:30Z), date 2026-06-28', async () => {
    const fixture = await loadFixture('exercise');
    const rows = extractRows(findByTypeId('exercise'), fixture);

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('exercise_minutes');
    expect(rows[0].value).toBe(30);
    // endTime "2026-06-28T17:30:00Z" + 7200s → local 19:30 → 2026-06-28
    expect(rows[0].date).toBe('2026-06-28');
  });
});

// ── R4 deferred (returns []) ──────────────────────────────────────────────────

describe('extractRows — R4 deferred (returns [])', () => {
  test('heart-rate (aggregate:derive) → []', async () => {
    const fixture = await loadFixture('heart-rate');
    expect(extractRows(findByTypeId('heart-rate'), fixture)).toEqual([]);
  });

  test('sleep_hours mapping → [] (main-session selection handled in R4)', async () => {
    const fixture = await loadFixture('sleep');
    expect(extractRows(findByMetric('sleep_hours'), fixture)).toEqual([]);
  });

  test('sleep_asleep_hours mapping → [] (stage summation handled in R4)', async () => {
    const fixture = await loadFixture('sleep');
    expect(extractRows(findByMetric('sleep_asleep_hours'), fixture)).toEqual([]);
  });

  test('dailyRollUp method mapping (floors) → []', () => {
    const floorsMapping = findByTypeId('floors');
    // dataPoints content is irrelevant — short-circuits on method check.
    expect(extractRows(floorsMapping, { dataPoints: [{}] })).toEqual([]);
  });
});
