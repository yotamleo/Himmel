import { describe, test, expect, spyOn } from 'bun:test';
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

  test('dataPoint with no typed payload field → skipped WITH a stderr warning (HIMMEL-801)', () => {
    // A malformed point carrying only name/dataSource (no beatsPerMinute payload
    // field) is dropped — but no longer silently: a [google-health] stderr line fires.
    const errSpy = spyOn(console, 'error');
    try {
      const rows = deriveRestingHeartRate({
        dataPoints: [{ name: 'heartRate', dataSource: { platform: 'HEALTH_CONNECT' } }],
      });
      expect(rows).toEqual([]);
      expect(errSpy).toHaveBeenCalledWith(
        '[google-health] heart-rate dataPoint 0: no typed payload field - skipped',
      );
    } finally {
      errSpy.mockRestore();
    }
  });
});

// ── deriveSleep ───────────────────────────────────────────────────────────────

describe('deriveSleep', () => {
  test('dataPoint with no typed payload field → skipped WITH a warning (returned + stderr) (HIMMEL-801)', () => {
    // A malformed point with only name/dataSource (no typed sleep payload) is
    // dropped — now through the same warn() channel as the other parse-loop drops:
    // a durable, undated SleepWarning (index-embedded so it never dedup-collides)
    // plus the [google-health] stderr line.
    const errSpy = spyOn(console, 'error');
    try {
      const { rows, warnings } = deriveSleep({
        dataPoints: [{ name: 'sleep', dataSource: { platform: 'HEALTH_CONNECT' } }],
      });
      expect(rows).toEqual([]);
      expect(warnings).toContainEqual({
        date: undefined,
        text: 'sleep dataPoint 0: no typed payload field - skipped',
      });
      expect(errSpy).toHaveBeenCalledWith(
        '[google-health] sleep dataPoint 0: no typed payload field - skipped',
      );
    } finally {
      errSpy.mockRestore();
    }
  });

  test('2026-06-28: main session 8h31m (sleep_in_bed_hours=8.5); nap excluded from main value', async () => {
    // Fixture: session 1 (01:24Z–09:55Z = 511 min = main) + session 2 nap (14:00Z–14:40Z = 40 min).
    // Both end on 2026-06-28 local (UTC+2). Main = session 1 (511 > 40).
    const fixture = await loadFixture('sleep');
    const { rows } = deriveSleep(fixture);

    const inBedRow = rows.find(
      (r) => r.metric === 'sleep_in_bed_hours' && r.date === '2026-06-28',
    );
    expect(inBedRow).toBeDefined();
    // 511 min / 60 = 8.5167 → 8.5 (NOT 8.5 + 0.7 from nap)
    expect(inBedRow!.value).toBe(8.5);
  });

  test('2026-06-28: sleep_hours (asleep) < sleep_in_bed_hours (main session has AWAKE segment)', async () => {
    // Main session (01:24Z–09:55Z) starts with 20 min AWAKE stage.
    // Non-AWAKE stages sum: 86+55+50+95+45+55+105 = 491 min = 8.183→ 8.2 h
    const fixture = await loadFixture('sleep');
    const { rows } = deriveSleep(fixture);

    const inBedRow = rows.find(
      (r) => r.metric === 'sleep_in_bed_hours' && r.date === '2026-06-28',
    )!;
    const asleepRow = rows.find((r) => r.metric === 'sleep_hours' && r.date === '2026-06-28');
    expect(asleepRow).toBeDefined();
    expect(asleepRow!.value).toBe(8.2);
    expect(asleepRow!.value).toBeLessThan(inBedRow.value);
  });

  test('midnight-cross session → date = 2026-06-27 (local end date, not start date)', async () => {
    // Session 3: 2026-06-26T22:30Z – 2026-06-27T05:30Z, endUtcOffset "7200s"
    // Local end: 05:30Z + 2h = 07:30 → date 2026-06-27. Duration = 7h exactly.
    const fixture = await loadFixture('sleep');
    const { rows } = deriveSleep(fixture);

    const inBedRow = rows.find(
      (r) => r.metric === 'sleep_in_bed_hours' && r.date === '2026-06-27',
    );
    expect(inBedRow).toBeDefined();
    expect(inBedRow!.value).toBe(7.0);
    // Start date (2026-06-26) must NOT appear in output.
    expect(rows.some((r) => r.date === '2026-06-26')).toBe(false);
  });

  test('all emitted rows have correct metric, valid date, finite value, typed source', async () => {
    const fixture = await loadFixture('sleep');
    const { rows } = deriveSleep(fixture);

    // fixture has sessions on 2026-06-27 and 2026-06-28, both stage-backed → 4 rows total (2 per date)
    expect(rows.length).toBe(4);
    for (const row of rows) {
      expect(row.metric).toMatch(/^sleep_(hours|in_bed_hours)$/);
      expect(row.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(typeof row.value).toBe('number');
      expect(Number.isFinite(row.value)).toBe(true);
      expect(row.source).toMatch(/^google-health:sleep:/);
    }
  });

  test('classic session (no stages) → sleep_in_bed_hours only, no sleep_hours row, no warning', () => {
    // Fitbit classic-era sync: interval present, stages array absent/empty. An absent
    // stages field is the normal stage-less case — NO warning (HIMMEL-794).
    const fixture = {
      dataPoints: [
        {
          dataSource: { platform: 'IOS' },
          sleep: {
            interval: {
              startTime: '2018-03-01T23:00:00Z',
              startUtcOffset: '0s',
              endTime: '2018-03-02T07:00:00Z',
              endUtcOffset: '0s',
            },
          },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('sleep_in_bed_hours');
    expect(rows[0].value).toBe(8.0);
    expect(rows.some((r) => r.metric === 'sleep_hours')).toBe(false);
    expect(warnings).toEqual([]);
  });

  test('stages session → emits both sleep_hours (asleep) and sleep_in_bed_hours (span); clean → warnings []', () => {
    const fixture = {
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
              {
                startTime: '2026-01-01T22:00:00Z',
                endTime: '2026-01-01T22:30:00Z',
                type: 'AWAKE',
              },
              {
                startTime: '2026-01-01T22:30:00Z',
                endTime: '2026-01-02T06:00:00Z',
                type: 'LIGHT',
              },
            ],
          },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows.length).toBe(2);
    const inBedRow = rows.find((r) => r.metric === 'sleep_in_bed_hours')!;
    const asleepRow = rows.find((r) => r.metric === 'sleep_hours')!;
    expect(inBedRow.value).toBe(8.0); // full 22:00–06:00 span
    expect(asleepRow.value).toBe(7.5); // AWAKE 30min excluded
    expect(warnings).toEqual([]);
  });

  test('all-AWAKE stages session → sleep_in_bed_hours only, no sleep_hours row (asleep sum is 0)', () => {
    // Stages array is PRESENT (unlike the classic-session case above) but every
    // stage is AWAKE, so the non-AWAKE sum is 0 — distinguishes "stages absent"
    // from "stages present but zero asleep".
    const fixture = {
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
              {
                startTime: '2026-01-01T22:00:00Z',
                endTime: '2026-01-02T06:00:00Z',
                type: 'AWAKE',
              },
            ],
          },
        },
      ],
    };
    const { rows } = deriveSleep(fixture);

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('sleep_in_bed_hours');
    expect(rows[0].value).toBe(8.0);
    expect(rows.some((r) => r.metric === 'sleep_hours')).toBe(false);
  });

  test('malformed non-AWAKE stage timestamps → degraded: sleep_in_bed_hours only, no sleep_hours row', () => {
    // One valid 4h LIGHT stage + one DEEP stage with unparseable timestamps. The
    // malformed non-AWAKE stage marks the session's stage data DEGRADED: even though
    // the valid LIGHT stage would sum to 4h, sleep_hours is omitted entirely (it would
    // under-count sleep). sleep_in_bed_hours (session span) is unaffected; a stderr
    // warning is printed.
    const fixture = {
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
              {
                startTime: '2026-01-01T22:00:00Z',
                endTime: '2026-01-02T02:00:00Z',
                type: 'LIGHT',
              },
              {
                startTime: 'not-a-timestamp',
                endTime: 'also-garbage',
                type: 'DEEP',
              },
            ],
          },
        },
      ],
    };
    // The degraded warning goes BOTH to stderr (the pre-HIMMEL-793 operator signal)
    // and, since HIMMEL-794, into the returned warnings[] (the durable artifact copy).
    // Assert both while the spy is live — mockRestore() clears the recorded calls.
    const degradedText = 'sleep 2026-01-02: malformed stage timestamps - sleep_hours omitted (degraded stage data)';
    const errSpy = spyOn(console, 'error');
    try {
      const { rows, warnings } = deriveSleep(fixture);

      expect(rows.length).toBe(1);
      expect(rows[0].metric).toBe('sleep_in_bed_hours');
      expect(rows[0].value).toBe(8.0);
      expect(rows.some((r) => r.metric === 'sleep_hours')).toBe(false);
      expect(warnings.map((w) => w.text)).toContain(degradedText);
      expect(errSpy).toHaveBeenCalledWith(`[google-health] ${degradedText}`);
    } finally {
      errSpy.mockRestore();
    }
  });

  test('malformed AWAKE stage timestamps do NOT degrade (AWAKE never enters the sum) → both rows', () => {
    // A valid non-AWAKE (LIGHT) stage plus a garbage-timestamp AWAKE stage: the AWAKE
    // stage is skipped before its timestamps are parsed, so the malformed AWAKE
    // timestamps do not trigger the degraded path and both rows are emitted.
    const fixture = {
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
              {
                startTime: 'garbage',
                endTime: 'garbage',
                type: 'AWAKE',
              },
              {
                startTime: '2026-01-01T22:00:00Z',
                endTime: '2026-01-02T06:00:00Z',
                type: 'LIGHT',
              },
            ],
          },
        },
      ],
    };
    const { rows } = deriveSleep(fixture);

    expect(rows.length).toBe(2);
    const inBedRow = rows.find((r) => r.metric === 'sleep_in_bed_hours')!;
    const asleepRow = rows.find((r) => r.metric === 'sleep_hours')!;
    expect(inBedRow.value).toBe(8.0);
    expect(asleepRow.value).toBe(8.0); // full 8h LIGHT span, garbage AWAKE ignored
  });

  test('dataPoint whose interval lacks endTime → dropped, no rows, exact warning (HIMMEL-794 Fix D)', () => {
    // interval.startTime present but endTime absent — and no civilEndTime or
    // endUtcOffset either, so no end date is derivable and the warning is UNDATED.
    const fixture = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-01-01T22:00:00Z',
            },
          },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows).toEqual([]);
    expect(warnings).toContainEqual({
      date: undefined,
      text: 'sleep dataPoint 0: missing interval startTime/endTime - session dropped',
    });
  });

  test('REGRESSION: TWO sessions both missing intervals → two DISTINCT warnings (indices differ) (CR round 4)', () => {
    // The undated missing-interval text used to be a static string, so N dropped
    // sessions collapsed to 1 after merge's Set dedup. The embedded dataPoint index
    // keeps genuinely-distinct events textually distinct.
    const fixture = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: { interval: { startTime: '2026-01-01T22:00:00Z' } },
        },
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: { interval: { startTime: '2026-01-03T22:00:00Z' } },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows).toEqual([]);
    expect(warnings.map((w) => w.text)).toEqual([
      'sleep dataPoint 0: missing interval startTime/endTime - session dropped',
      'sleep dataPoint 1: missing interval startTime/endTime - session dropped',
    ]);
    // The two texts must be distinct — flat Set dedup must not collapse them.
    expect(new Set(warnings.map((w) => w.text)).size).toBe(2);
  });

  test('garbage endTime alongside endUtcOffset → UNDATED unparseable warning, no NaN embedded (CR round 4)', () => {
    // computeLocalDate on a garbage endTime yields "NaN-NaN-NaN" — the NaN-date
    // guard resets it to undefined, so the unparseable warning uses its undated
    // variant instead of embedding a garbage date.
    const fixture = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-01-01T22:00:00Z',
              endTime: 'garbage-end',
              endUtcOffset: '7200s',
            },
          },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows).toEqual([]);
    expect(warnings).toContainEqual({
      date: undefined,
      text: 'sleep dataPoint 0: unparseable interval start/end - session dropped',
    });
    expect(warnings.some((w) => w.text.includes('NaN'))).toBe(false);
  });

  test('dataPoint missing startTime but WITH civilEndTime → dropped, warning carries the date (CR round 2)', () => {
    // startTime absent but the end date IS derivable (civilEndTime present) — the
    // missing-interval warning must be dated so the pull-side window filter can
    // scope it (an undated warning would survive EVERY pull window).
    const fixture = {
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
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows).toEqual([]);
    expect(warnings).toContainEqual({
      date: '2026-01-02',
      text: 'sleep dataPoint 0 (2026-01-02): missing interval startTime/endTime - session dropped',
    });
  });

  test('session with no civilEndTime and no endUtcOffset → dropped, no rows, exact warning', () => {
    // An interval with startTime + endTime but neither civilEndTime nor endUtcOffset:
    // no local end date can be derived, so the session is dropped. HIMMEL-794: the
    // drop is now warned (stderr + artifact) instead of silent; row emission unchanged.
    const fixture = {
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
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows).toEqual([]);
    // No date derivable at all for this path — `date` is undefined (HIMMEL-794 Fix A).
    expect(warnings).toContainEqual({
      date: undefined,
      text: 'sleep dataPoint 0 ending 2026-01-02T06:00:00Z: no civilEndTime and no endUtcOffset - session dropped',
    });
  });

  test('session with unparseable interval start/end → dropped, no rows, exact warning', () => {
    // civilEndTime is present so a date IS derivable, but the interval start/end are
    // unparseable (Date.parse → NaN) → no duration → session dropped. HIMMEL-794: warned.
    const fixture = {
      dataPoints: [
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: 'garbage',
              endTime: 'also-garbage',
              civilEndTime: { date: { year: 2026, month: 1, day: 2 } },
            },
          },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows).toEqual([]);
    // civilEndTime made a date derivable, so the warning carries it (HIMMEL-794 Fix A).
    expect(warnings).toContainEqual({
      date: '2026-01-02',
      text: 'sleep dataPoint 0 (2026-01-02): unparseable interval start/end - session dropped',
    });
  });

  test('non-array "stages" field → sleep_in_bed_hours only, no sleep_hours, exact warning', () => {
    // stages is a STRING (present but non-array): coerced to [] (stage-less —
    // sleep_in_bed_hours emits from the interval, sleep_hours does not) and warned.
    // Contrast the classic case above, where an ABSENT stages field warns nothing.
    const fixture = {
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
            stages: 'not-an-array',
          },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    expect(rows.length).toBe(1);
    expect(rows[0].metric).toBe('sleep_in_bed_hours');
    expect(rows[0].value).toBe(8.0);
    expect(rows.some((r) => r.metric === 'sleep_hours')).toBe(false);
    // Single session IS the main session, so it still warns, now carrying its date.
    expect(warnings).toContainEqual({
      date: '2026-01-02',
      text: 'sleep 2026-01-02: non-array "stages" field - treated as stage-less (sleep_hours unavailable)',
    });
  });

  test('REGRESSION: malformed non-array stages on a shorter NAP session does not warn (main session wins) — HIMMEL-794 Fix B / codex-adv-2', () => {
    // A clean, longer main session (valid stages) plus a shorter same-date nap
    // session whose `stages` field is malformed. Only the MAIN session may warn —
    // a malformed nap that never contributes rows must not produce a warning that
    // contradicts the sleep_hours row emitted from the clean main session.
    const fixture = {
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
              { startTime: '2026-01-01T22:00:00Z', endTime: '2026-01-02T06:00:00Z', type: 'LIGHT' },
            ],
          },
        },
        {
          dataSource: { platform: 'HEALTH_CONNECT' },
          sleep: {
            interval: {
              startTime: '2026-01-02T14:00:00Z',
              startUtcOffset: '0s',
              endTime: '2026-01-02T14:40:00Z',
              endUtcOffset: '0s',
            },
            stages: 'not-an-array',
          },
        },
      ],
    };
    const { rows, warnings } = deriveSleep(fixture);

    const asleepRow = rows.find((r) => r.metric === 'sleep_hours' && r.date === '2026-01-02');
    expect(asleepRow).toBeDefined();
    expect(asleepRow!.value).toBe(8.0); // main session's full 8h LIGHT span
    expect(warnings.some((w) => w.text.includes('non-array "stages"'))).toBe(false);
  });

  test('empty dataPoints → { rows: [], warnings: [] }', () => {
    expect(deriveSleep({ dataPoints: [] })).toEqual({ rows: [], warnings: [] });
    expect(deriveSleep({})).toEqual({ rows: [], warnings: [] });
  });
});
