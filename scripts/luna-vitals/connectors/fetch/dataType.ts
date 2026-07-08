const BASE_URL = 'https://health.googleapis.com/v4';
// Default 100; GOOGLE_HEALTH_PAGE_CAP overrides for full-history backfills.
const PAGE_CAP = 100;
// API default is 50; 1000 is the verified maximum (probed live 2026-07-08).
const PAGE_SIZE = 1000;

function pageCap(): number {
  const env = Number(process.env.GOOGLE_HEALTH_PAGE_CAP);
  return Number.isFinite(env) && env > 0 ? env : PAGE_CAP;
}

/** Extract the civil date (YYYY-MM-DD) of one raw dataPoint; undefined if unparseable. */
export type PointDate = (point: unknown) => string | undefined;

// Early-stop slack in days. pointDate yields LOCAL civil dates while the
// API's (observed) newest-first order is presumably keyed on raw timestamps;
// mixed UTC offsets can skew local dates vs raw order by up to ~26h
// (-12h..+14h). Stopping only once pages are this many days BEFORE the
// window start makes offset jitter unable to hide an in-window point.
const EARLY_STOP_SLACK_DAYS = 2;

/** ISO date (YYYY-MM-DD) minus N days, in pure UTC date math. */
function isoMinusDays(iso: string, days: number): string {
  const d = new Date(Date.parse(`${iso}T00:00:00Z`) - days * 86_400_000);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

type FetchLike = (
  url: string,
  init?: RequestInit,
) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

export async function fetchDataPoints(
  args: {
    dataTypeId: string;
    method?: 'list' | 'dailyRollUp';
    accessToken: string;
    baseUrl?: string;
    /**
     * Enables early-stop paging (see fetchList). windowFrom is the window
     * start (YYYY-MM-DD); pointDate extracts one point's civil date. They are
     * one object because neither means anything without the other.
     */
    earlyStop?: { windowFrom: string; pointDate: PointDate };
  },
  fetchImpl: FetchLike = fetch as unknown as FetchLike,
): Promise<any[]> {
  const base = args.baseUrl ?? BASE_URL;

  if (args.method === 'dailyRollUp') {
    return fetchDailyRollUp(args.dataTypeId, args.accessToken, base, fetchImpl);
  }
  return fetchList(args, base, fetchImpl);
}

/**
 * Scan one page: verify every point has a parseable date and the page is
 * non-increasing (newest-first). On success, newest/oldest are the page's
 * first/last dates.
 */
function scanDescending(
  points: unknown[],
  pointDate: PointDate,
): { ok: boolean; newest?: string; oldest?: string; strictDecrease?: boolean } {
  let prev: string | undefined;
  let newest: string | undefined;
  let strictDecrease = false;
  for (const p of points) {
    const d = pointDate(p);
    if (!d || (prev !== undefined && d > prev)) return { ok: false };
    if (prev !== undefined && d < prev) strictDecrease = true;
    if (newest === undefined) newest = d;
    prev = d;
  }
  return { ok: true, newest, oldest: prev, strictDecrease };
}

/**
 * Page through a list dataType.
 *
 * Early stop: the API returns points newest-first (verified live 2026-07-08).
 * Once pages fall entirely before earlyStop.windowFrom, later pages are older
 * still — stop paging. The ordering is a live observation, NOT a documented
 * contract, and a false stop silently drops in-window data, so every
 * detectable violation fails closed to full paging:
 *   - every point on a page must have a parseable date and the page must be
 *     non-increasing, or early-stop is disabled for the rest of this fetch;
 *   - each page's newest date must not exceed the previous page's oldest
 *     (cross-page boundary), or early-stop is disabled likewise;
 *   - a stop only ARMS when a verified page (>= 2 points) ends before
 *     windowFrom minus a 2-day offset-jitter slack (local civil dates can
 *     skew ~26h against the presumed raw-timestamp page order); the actual
 *     break requires the NEXT page to confirm — also verified-ordered,
 *     boundary-consistent, and fully below the slacked threshold;
 *   - tied dates are direction-neutral: arming additionally requires one
 *     STRICT date decrease seen in or across pages (directionProven).
 * Undetectable disorder (in-window data hidden beyond two verified-ordered,
 * pre-window pages) would defeat any client short of full-history paging,
 * which is the structural failure this early-stop exists to fix (HIMMEL-771).
 */
async function fetchList(
  args: {
    dataTypeId: string;
    accessToken: string;
    earlyStop?: { windowFrom: string; pointDate: PointDate };
  },
  base: string,
  fetchImpl: FetchLike,
): Promise<any[]> {
  const { dataTypeId, accessToken, earlyStop } = args;
  const allPoints: any[] = [];
  let pageToken: string | undefined;
  let pages = 0;
  const cap = pageCap();

  let orderTrusted = true; // false = a violation was seen; early-stop disabled
  let stopArmed = false; // previous page ended pre-window; this page must confirm
  let prevPageOldest: string | undefined;
  // Stop threshold: windowFrom minus the offset-jitter slack (see above).
  const stopBefore = earlyStop
    ? isoMinusDays(earlyStop.windowFrom, EARLY_STOP_SLACK_DAYS)
    : '';
  // Tied dates are non-increasing but direction-NEUTRAL: pages of one repeated
  // date would pass every monotonic/boundary check even on an ascending feed.
  // A stop may only arm after at least one STRICT decrease has proven the
  // feed's direction (within a page, or strictly across a page boundary).
  let directionProven = false;

  const headers = {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
  };

  while (true) {
    if (pages >= cap) {
      throw new Error(
        `fetchDataPoints: page cap (${cap}) hit for dataTypeId "${dataTypeId}" — possible infinite pagination`,
      );
    }

    const url = new URL(`${base}/users/me/dataTypes/${dataTypeId}/dataPoints`);
    url.searchParams.set('pageSize', String(PAGE_SIZE));
    if (pageToken) {
      url.searchParams.set('pageToken', pageToken);
    }

    const resp = await fetchImpl(url.toString(), { headers });
    pages++;

    if (!resp.ok) {
      throw new Error(`fetchDataPoints: HTTP ${resp.status} for dataTypeId "${dataTypeId}"`);
    }

    const data = (await resp.json()) as { dataPoints?: any[]; nextPageToken?: string };
    const pagePoints = data.dataPoints ?? [];
    allPoints.push(...pagePoints);

    if (!data.nextPageToken) break;

    if (earlyStop && orderTrusted && pagePoints.length > 0) {
      const scan = scanDescending(pagePoints, earlyStop.pointDate);
      const boundaryOk =
        scan.ok && (prevPageOldest === undefined || scan.newest! <= prevPageOldest);

      if (!scan.ok || !boundaryOk) {
        // Detected disorder — fail closed: no early-stop for this fetch.
        orderTrusted = false;
        stopArmed = false;
      } else {
        if (
          scan.strictDecrease ||
          (prevPageOldest !== undefined && scan.newest! < prevPageOldest)
        ) {
          directionProven = true;
        }
        if (pagePoints.length >= 2) {
          // Only a page with >= 2 points can carry ordering evidence — the
          // same threshold for arming AND confirming.
          if (stopArmed && scan.newest! < stopBefore) {
            // Look-ahead confirmation: this page is verified-ordered,
            // boundary-consistent, and entirely below the slacked threshold.
            break;
          }
          prevPageOldest = scan.oldest;
          stopArmed = directionProven && scan.oldest! < stopBefore;
        } else {
          // Single-point page: boundary-consistent but direction-blind — it
          // neither confirms a stop nor re-arms; keep the prior armed state
          // and keep paging until a two-point page settles it.
          prevPageOldest = scan.oldest;
        }
      }
    }

    pageToken = data.nextPageToken;
  }

  return allPoints;
}

/**
 * NOTE: The dailyRollUp wire-shape is UNVERIFIED — all test requests against the live API
 * returned HTTP 400. This implementation follows the AIP-158 custom-method convention
 * (GET to `.../dataPoints:dailyRollUp`). The response is parsed defensively (`dataPoints?`
 * optional). Gate this path with a shape-confirmed integration test before enabling in
 * production. It is isolated here so that failure in this path cannot affect list-type fetches.
 */
async function fetchDailyRollUp(
  dataTypeId: string,
  accessToken: string,
  base: string,
  fetchImpl: FetchLike,
): Promise<any[]> {
  const url = `${base}/users/me/dataTypes/${dataTypeId}/dataPoints:dailyRollUp`;
  const headers = {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
  };

  const resp = await fetchImpl(url, { headers });

  if (!resp.ok) {
    throw new Error(
      `fetchDataPoints(dailyRollUp): HTTP ${resp.status} for dataTypeId "${dataTypeId}"`,
    );
  }

  const data = (await resp.json()) as { dataPoints?: any[] };
  return data.dataPoints ?? [];
}

/**
 * Keep only rows whose `date` field falls within [from, to] inclusive.
 * Comparison is lexicographic on YYYY-MM-DD strings, which is correct for ISO dates.
 * Pure: no side-effects.
 */
export function filterByDateWindow(
  rows: { date: string }[],
  from: string,
  to: string,
): typeof rows {
  return rows.filter((r) => r.date >= from && r.date <= to);
}
