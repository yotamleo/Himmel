export const RECONSENT_EXIT = 75;

export class ReconsentNeededError extends Error {
  readonly exitCode = RECONSENT_EXIT;
  constructor(message: string) {
    super(message);
    this.name = "ReconsentNeededError";
  }
}

export const GH_SCOPES: string[] = [
  "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
  "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
  "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
  "https://www.googleapis.com/auth/googlehealth.nutrition.readonly",
  "https://www.googleapis.com/auth/googlehealth.ecg.readonly",
  "https://www.googleapis.com/auth/googlehealth.irn.readonly",
];

const TOKEN_URL = "https://oauth2.googleapis.com/token";

type FetchImpl = (url: string, init: RequestInit) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

export async function getAccessToken(
  cfg: { clientId: string; clientSecret: string; refreshToken: string },
  fetchImpl: FetchImpl = fetch as unknown as FetchImpl,
): Promise<string> {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    refresh_token: cfg.refreshToken,
  });

  const resp = await fetchImpl(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  const data = (await resp.json()) as Record<string, unknown>;

  if (!resp.ok) {
    const err = data["error"] as string | undefined;
    if (err === "invalid_grant" || err === "unauthorized_client") {
      throw new ReconsentNeededError(
        "Google Health re-consent needed (refresh token expired/invalid). Re-run auth-url + auth-exchange.",
      );
    }
    throw new Error(`Token refresh failed: ${err ?? resp.status}`);
  }

  return data["access_token"] as string;
}

export function buildAuthUrl(clientId: string, redirectUri = "http://localhost"): string {
  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: GH_SCOPES.join(" "),
    access_type: "offline",
    prompt: "consent",
    include_granted_scopes: "false",
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;
}

export async function exchangeCode(
  cfg: { clientId: string; clientSecret: string; code: string; redirectUri?: string },
  fetchImpl: FetchImpl = fetch as unknown as FetchImpl,
): Promise<{ refreshToken: string; scope: string }> {
  const redirectUri = cfg.redirectUri ?? "http://localhost";

  // Accept a full redirect URL or a bare code
  let code = cfg.code;
  const match = cfg.code.match(/[?&]code=([^&]+)/);
  if (match) {
    code = decodeURIComponent(match[1]);
  }

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    code,
    redirect_uri: redirectUri,
  });

  const resp = await fetchImpl(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  const data = (await resp.json()) as Record<string, unknown>;

  if (!resp.ok) {
    const err = data["error"] as string | undefined;
    throw new Error(`Code exchange failed: ${err ?? resp.status}`);
  }

  if (!data["refresh_token"]) {
    throw new Error(
      "No refresh_token in response. Ensure prompt=consent was set in the auth URL.",
    );
  }

  return {
    refreshToken: data["refresh_token"] as string,
    scope: (data["scope"] as string) ?? "",
  };
}
