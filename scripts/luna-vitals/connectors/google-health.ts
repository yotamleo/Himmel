/**
 * Google Health connector — wires auth, fetch, map, and derive into a single
 * `pull` that returns a ReviewArtifact, plus a thin argv CLI for pull/auth-url/auth-exchange.
 */
import { existsSync, readFileSync, writeFileSync } from 'fs';
import { join, dirname, resolve } from 'path';
import { MAPPINGS } from './map/table';
import { extractRows } from './map/shape';
import { aggregateRows, deriveRestingHeartRate, deriveSleep } from './map/derive';
import {
  getAccessToken,
  buildAuthUrl,
  exchangeCode,
  ReconsentNeededError,
  RECONSENT_EXIT,
} from './auth/oauth';
import { fetchDataPoints, filterByDateWindow } from './fetch/dataType';
import { type ExtractedRow, type ReviewArtifact, writeArtifact } from '../src/types';

// ── internal fetch type ───────────────────────────────────────────────────────

/**
 * Internal fetch shape — compatible with both getAccessToken (init required)
 * and fetchDataPoints (init optional). We cast once and reuse.
 */
type InternalFetch = (
  url: string,
  init: RequestInit,
) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

// ── pull ──────────────────────────────────────────────────────────────────────

/**
 * Fetch all supported Google Health data types and return a ReviewArtifact
 * for the given date window.
 *
 * Deterministic: identical inputs → identical JSON output (no Date.now, stable sort).
 * dailyRollUp mappings are skipped with a console.error note; they do not cause failure.
 */
export async function pull(opts: {
  from: string;
  to: string;
  cfg: { clientId: string; clientSecret: string; refreshToken: string };
  baseUrl?: string;
  fetchImpl?: typeof fetch;
}): Promise<ReviewArtifact> {
  const fetchFn = (opts.fetchImpl ?? fetch) as unknown as InternalFetch;

  // 1. Obtain access token.
  const accessToken = await getAccessToken(opts.cfg, fetchFn);

  // 2. Collect unique dataTypeIds; skip dailyRollUp (shape unverified).
  const skippedMetrics: string[] = [];
  const uniqueDataTypeIds = new Set<string>();

  for (const mapping of MAPPINGS) {
    if (mapping.method === 'dailyRollUp') {
      skippedMetrics.push(mapping.metric);
      continue;
    }
    uniqueDataTypeIds.add(mapping.dataTypeId);
  }

  if (skippedMetrics.length > 0) {
    console.error(
      `[google-health] skipped (dailyRollUp method, shape unverified): ${skippedMetrics.join(', ')}`,
    );
  }

  // 3. Fetch each dataType once.
  const fetched = new Map<string, unknown[]>();
  for (const dataTypeId of uniqueDataTypeIds) {
    const points = await fetchDataPoints(
      { dataTypeId, accessToken, baseUrl: opts.baseUrl },
      fetchFn,
    );
    fetched.set(dataTypeId, points);
  }

  // 4. Produce rows from each fetched response.
  const allRows: ExtractedRow[] = [];

  for (const [dataTypeId, points] of fetched) {
    const response = { dataPoints: points };

    if (dataTypeId === 'heart-rate') {
      // derive: 5th-percentile per day → rhr_bpm
      allRows.push(...deriveRestingHeartRate(response));
    } else if (dataTypeId === 'sleep') {
      // derive: longest session per date → sleep_hours + sleep_asleep_hours
      allRows.push(...deriveSleep(response));
    } else {
      // Standard path: for each mapping on this dataTypeId, extract + aggregate.
      const mappings = MAPPINGS.filter(
        (m) => m.dataTypeId === dataTypeId && m.method !== 'dailyRollUp',
      );
      for (const mapping of mappings) {
        const extracted = extractRows(mapping, response);
        allRows.push(...aggregateRows(mapping, extracted));
      }
    }
  }

  // 5. Filter by date window, sort deterministically.
  const filtered = filterByDateWindow(allRows, opts.from, opts.to) as ExtractedRow[];
  const sorted = [...filtered].sort((a, b) => {
    if (a.metric !== b.metric) return a.metric < b.metric ? -1 : 1;
    if (a.date !== b.date) return a.date < b.date ? -1 : 1;
    return 0;
  });

  return { bucket: `${opts.from}..${opts.to}`, rows: sorted, conflicts: [] };
}

// ── .env helpers ──────────────────────────────────────────────────────────────

/** Walk up from startDir until we find a directory containing .env, or return undefined. */
function findEnvFile(startDir: string): string | undefined {
  let dir = resolve(startDir);
  while (true) {
    const candidate = join(dir, '.env');
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

/**
 * Write GOOGLE_HEALTH_REFRESH_TOKEN=<token> into the .env file at envPath.
 * Replaces an existing line if present; otherwise appends.
 * Sync read + sync write: both must succeed or neither takes effect (write is last).
 */
function updateEnvFile(envPath: string, refreshToken: string): void {
  const KEY = 'GOOGLE_HEALTH_REFRESH_TOKEN';
  const newLine = `${KEY}=${refreshToken}`;

  let content = '';
  if (existsSync(envPath)) {
    content = readFileSync(envPath, 'utf-8');
  }

  if (new RegExp(`^${KEY}=`, 'm').test(content)) {
    content = content.replace(new RegExp(`^${KEY}=.*$`, 'm'), newLine);
  } else {
    if (content && !content.endsWith('\n')) content += '\n';
    content += newLine + '\n';
  }

  writeFileSync(envPath, content, 'utf-8');
}

// ── argv helpers ──────────────────────────────────────────────────────────────

/** Same flag() helper as cli.ts: last occurrence wins. */
function flag(args: string[], name: string): string | undefined {
  const i = args.lastIndexOf(`--${name}`);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : undefined;
}

/**
 * Read and validate the three Google Health env vars.
 * Errors clearly if any are missing. Never logs their values.
 */
function requireEnvCfg(): { clientId: string; clientSecret: string; refreshToken: string } {
  const clientId = process.env.GOOGLE_HEALTH_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_HEALTH_CLIENT_SECRET;
  const refreshToken = process.env.GOOGLE_HEALTH_REFRESH_TOKEN;
  const missing: string[] = [];
  if (!clientId) missing.push('GOOGLE_HEALTH_CLIENT_ID');
  if (!clientSecret) missing.push('GOOGLE_HEALTH_CLIENT_SECRET');
  if (!refreshToken) missing.push('GOOGLE_HEALTH_REFRESH_TOKEN');
  if (missing.length > 0) {
    console.error(`[google-health] error: missing required env vars: ${missing.join(', ')}`);
    process.exit(1);
  }
  return { clientId: clientId!, clientSecret: clientSecret!, refreshToken: refreshToken! };
}

// ── main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);

  if (cmd === 'pull') {
    const from = flag(rest, 'from');
    const to = flag(rest, 'to');
    const out = flag(rest, 'out');
    if (!from || !to || !out) {
      console.error(
        'usage: pull --from YYYY-MM-DD --to YYYY-MM-DD --out <artifact.json>',
      );
      process.exit(1);
    }
    const cfg = requireEnvCfg();
    try {
      const artifact = await pull({ from, to, cfg });
      await writeArtifact(out, artifact);
      // Print row count per metric to stderr, sorted by metric name.
      const counts = new Map<string, number>();
      for (const row of artifact.rows) {
        counts.set(row.metric, (counts.get(row.metric) ?? 0) + 1);
      }
      for (const [metric, count] of [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
        console.error(`[google-health] ${metric}: ${count} rows`);
      }
      console.error(`[google-health] total ${artifact.rows.length} rows -> ${out}`);
    } catch (err) {
      if (err instanceof ReconsentNeededError) {
        console.error(err.message);
        process.exit(RECONSENT_EXIT);
      }
      throw err;
    }
  } else if (cmd === 'auth-url') {
    const clientId = process.env.GOOGLE_HEALTH_CLIENT_ID;
    if (!clientId) {
      console.error('[google-health] error: GOOGLE_HEALTH_CLIENT_ID env var is required');
      process.exit(1);
    }
    // Print to stdout — caller redirects or pastes this URL into a browser.
    console.log(buildAuthUrl(clientId));
  } else if (cmd === 'auth-exchange') {
    const code = flag(rest, 'code');
    const envPath = flag(rest, 'env-path');
    if (!code) {
      console.error('usage: auth-exchange --code <codeOrUrl> [--env-path <path>]');
      process.exit(1);
    }
    const clientId = process.env.GOOGLE_HEALTH_CLIENT_ID;
    const clientSecret = process.env.GOOGLE_HEALTH_CLIENT_SECRET;
    if (!clientId || !clientSecret) {
      const missing = (
        [
          !clientId && 'GOOGLE_HEALTH_CLIENT_ID',
          !clientSecret && 'GOOGLE_HEALTH_CLIENT_SECRET',
        ] as (string | false)[]
      ).filter(Boolean);
      console.error(`[google-health] error: missing required env vars: ${missing.join(', ')}`);
      process.exit(1);
    }
    const { refreshToken, scope } = await exchangeCode({ clientId, clientSecret, code });
    const resolvedEnvPath = envPath ?? findEnvFile(process.cwd());
    if (!resolvedEnvPath) {
      console.error(
        '[google-health] error: could not find .env file (walked up from cwd); pass --env-path',
      );
      process.exit(1);
    }
    updateEnvFile(resolvedEnvPath, refreshToken);
    // NEVER print the token; print confirmation (with resolved path) + granted scope.
    console.error(`OK: refresh token written to ${resolvedEnvPath}`);
    console.error(`Granted scope: ${scope}`);
  } else {
    console.error(
      `unknown command: ${cmd ?? '(none)'} — use pull|auth-url|auth-exchange`,
    );
    process.exit(1);
  }
}

if (import.meta.main) {
  main().catch((err) => {
    console.error(
      `[google-health] fatal: ${err instanceof Error ? err.message : String(err)}`,
    );
    process.exit(1);
  });
}
