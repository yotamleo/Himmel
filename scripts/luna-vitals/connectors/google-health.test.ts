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
    // sleep → both time-in-bed and asleep duration
    expect(metrics.has('sleep_hours')).toBe(true);
    expect(metrics.has('sleep_asleep_hours')).toBe(true);
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
});
