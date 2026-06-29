const BASE_URL = 'https://health.googleapis.com/v4';
const PAGE_CAP = 100;

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
  },
  fetchImpl: FetchLike = fetch as unknown as FetchLike,
): Promise<any[]> {
  const base = args.baseUrl ?? BASE_URL;

  if (args.method === 'dailyRollUp') {
    return fetchDailyRollUp(args.dataTypeId, args.accessToken, base, fetchImpl);
  }
  return fetchList(args.dataTypeId, args.accessToken, base, fetchImpl);
}

async function fetchList(
  dataTypeId: string,
  accessToken: string,
  base: string,
  fetchImpl: FetchLike,
): Promise<any[]> {
  const allPoints: any[] = [];
  let pageToken: string | undefined;
  let pages = 0;

  const headers = {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
  };

  while (true) {
    if (pages >= PAGE_CAP) {
      throw new Error(
        `fetchDataPoints: page cap (${PAGE_CAP}) hit for dataTypeId "${dataTypeId}" — possible infinite pagination`,
      );
    }

    const url = new URL(`${base}/users/me/dataTypes/${dataTypeId}/dataPoints`);
    if (pageToken) {
      url.searchParams.set('pageToken', pageToken);
    }

    const resp = await fetchImpl(url.toString(), { headers });
    pages++;

    if (!resp.ok) {
      throw new Error(`fetchDataPoints: HTTP ${resp.status} for dataTypeId "${dataTypeId}"`);
    }

    const data = (await resp.json()) as { dataPoints?: any[]; nextPageToken?: string };
    allPoints.push(...(data.dataPoints ?? []));

    if (!data.nextPageToken) break;
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
