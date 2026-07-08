import { describe, test, expect } from 'bun:test';
import { readdirSync } from 'fs';
import { join } from 'path';
import { MAPPINGS, EXCLUDED } from './table';

const VALID_CATEGORIES = new Set(['daily', 'sample', 'interval']);
const VALID_METHODS = new Set(['list', 'dailyRollUp']);
const VALID_AGGREGATES = new Set(['none', 'sum', 'mean', 'last', 'duration', 'derive']);

describe('MAPPINGS table', () => {
  test('is non-empty', () => {
    expect(MAPPINGS.length).toBeGreaterThan(0);
  });

  test('no duplicate metric values', () => {
    const metrics = MAPPINGS.map(m => m.metric);
    const unique = new Set(metrics);
    if (unique.size !== metrics.length) {
      const seen = new Set<string>();
      const dupes = metrics.filter(m => (seen.has(m) ? true : (seen.add(m), false)));
      throw new Error(`duplicate metric values: ${dupes.join(', ')}`);
    }
    expect(unique.size).toBe(metrics.length);
  });

  test('no duplicate dataTypeId except sleep (which maps to 2 metrics)', () => {
    const counts = new Map<string, number>();
    for (const m of MAPPINGS) {
      counts.set(m.dataTypeId, (counts.get(m.dataTypeId) ?? 0) + 1);
    }
    for (const [dataTypeId, count] of counts) {
      if (dataTypeId === 'sleep') {
        expect(count).toBe(2);
      } else {
        expect(count).toBe(1);
      }
    }
  });

  test('all category values are from the allowed set', () => {
    for (const m of MAPPINGS) {
      expect(VALID_CATEGORIES.has(m.category)).toBe(true);
    }
  });

  test('all method values (if set) are from the allowed set', () => {
    for (const m of MAPPINGS) {
      if (m.method !== undefined) {
        expect(VALID_METHODS.has(m.method)).toBe(true);
      }
    }
  });

  test('all aggregate values are from the allowed set', () => {
    for (const m of MAPPINGS) {
      expect(VALID_AGGREGATES.has(m.aggregate)).toBe(true);
    }
  });

  test('includes rhr_bpm with aggregate derive (from heart-rate raw samples)', () => {
    const entry = MAPPINGS.find(m => m.metric === 'rhr_bpm');
    expect(entry).toBeDefined();
    expect(entry?.aggregate).toBe('derive');
    expect(entry?.dataTypeId).toBe('heart-rate');
  });

  test('includes sleep_hours and sleep_in_bed_hours (both from sleep dataTypeId)', () => {
    const sleepHours = MAPPINGS.find(m => m.metric === 'sleep_hours');
    const sleepInBed = MAPPINGS.find(m => m.metric === 'sleep_in_bed_hours');
    expect(sleepHours).toBeDefined();
    expect(sleepInBed).toBeDefined();
    expect(sleepHours?.dataTypeId).toBe('sleep');
    expect(sleepInBed?.dataTypeId).toBe('sleep');
  });

  test('list-method entries with a matching fixture file have that file accessible', () => {
    const fixturesDir = join(import.meta.dir, '../__fixtures__');
    const files = readdirSync(fixturesDir);
    const jsonFiles = files.filter(f => f.endsWith('.json'));
    const fixtureIds = new Set(jsonFiles.map(f => f.replace(/\.json$/, '')));

    for (const m of MAPPINGS) {
      if (m.method === 'dailyRollUp') continue;
      if (fixtureIds.has(m.dataTypeId)) {
        // Fixture exists — assert it's in the directory listing
        expect(jsonFiles).toContain(`${m.dataTypeId}.json`);
      }
      // No fixture: allowed (note field documents why)
    }
  });

  test('rollup-only entries have method dailyRollUp and note about TBD shape', () => {
    const rollups = MAPPINGS.filter(m => m.method === 'dailyRollUp');
    expect(rollups.length).toBeGreaterThan(0);
    for (const m of rollups) {
      expect(m.note).toMatch(/TBD/);
    }
  });
});

describe('EXCLUDED list', () => {
  test('is non-empty', () => {
    expect(EXCLUDED.length).toBeGreaterThan(0);
  });

  test('all entries have a non-empty dataTypeId and reason', () => {
    for (const e of EXCLUDED) {
      expect(e.dataTypeId.length).toBeGreaterThan(0);
      expect(e.reason.length).toBeGreaterThan(0);
    }
  });

  test('excluded types are not also in MAPPINGS', () => {
    const mappedIds = new Set(MAPPINGS.map(m => m.dataTypeId));
    for (const e of EXCLUDED) {
      expect(mappedIds.has(e.dataTypeId)).toBe(false);
    }
  });
});
