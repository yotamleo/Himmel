import { describe, test, expect } from "bun:test";
import {
  getAccessToken,
  buildAuthUrl,
  exchangeCode,
  RECONSENT_EXIT,
  ReconsentNeededError,
} from "./oauth";

// Fake fetchImpl helper: returns a Response-like object
function makeFetch(body: unknown, ok = true, status = 200) {
  return async (_url: string, _init: RequestInit) => ({
    ok,
    status,
    json: async () => body,
  });
}

// Fake fetchImpl that captures the request body so a test can assert on what
// was actually SUBMITTED, not just what the (unconditional) response claims.
function capturingFetch(body: unknown, captured: { init?: RequestInit }) {
  return async (_url: string, init: RequestInit) => {
    captured.init = init;
    return { ok: true, status: 200, json: async () => body };
  };
}

describe("getAccessToken", () => {
  test("happy path returns access_token", async () => {
    const fakeResp = { access_token: "fake-access-token", token_type: "Bearer" };
    const token = await getAccessToken(
      { clientId: "cid", clientSecret: "csec", refreshToken: "rtoken" },
      makeFetch(fakeResp),
    );
    expect(token).toBe("fake-access-token");
  });

  test("invalid_grant response throws ReconsentNeededError", async () => {
    const fakeResp = { error: "invalid_grant", error_description: "Token has been expired" };
    let caught: unknown;
    try {
      await getAccessToken(
        { clientId: "cid", clientSecret: "csec", refreshToken: "super-secret-rtoken" },
        makeFetch(fakeResp, false, 400),
      );
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(ReconsentNeededError);
    const err = caught as ReconsentNeededError;
    expect(err.exitCode).toBe(RECONSENT_EXIT);
    expect(err.exitCode).toBe(75);
    expect(err.message).toContain("re-consent");
    // Must not leak the refresh token
    expect(err.message).not.toContain("super-secret-rtoken");
  });

  test("unauthorized_client response throws ReconsentNeededError", async () => {
    const fakeResp = { error: "unauthorized_client" };
    let caught: unknown;
    try {
      await getAccessToken(
        { clientId: "cid", clientSecret: "csec", refreshToken: "super-secret-rtoken" },
        makeFetch(fakeResp, false, 401),
      );
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(ReconsentNeededError);
    const err = caught as ReconsentNeededError;
    expect(err.exitCode).toBe(75);
    expect(err.message).toContain("re-consent");
    expect(err.message).not.toContain("super-secret-rtoken");
  });
});

describe("buildAuthUrl", () => {
  test("contains expected params", () => {
    const url = buildAuthUrl("my-client-id");
    expect(url).toContain("accounts.google.com/o/oauth2/v2/auth");
    expect(url).toContain("my-client-id");
    // redirect_uri URL-encoded
    expect(url).toContain("redirect_uri=http");
    expect(url).toContain("localhost");
    expect(url).toContain("access_type=offline");
    expect(url).toContain("prompt=consent");
    expect(url).toContain("response_type=code");
  });

  test("requests exactly the required Google Health scope set", () => {
    // Pinned independently of GH_SCOPES — iterating the production export would
    // let a removed scope shrink both the requested URL and this check together
    // and still pass. This is the actual contract: what googlehealth.* read
    // scopes the app needs.
    const REQUIRED_SCOPES = [
      "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
      "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
      "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
      "https://www.googleapis.com/auth/googlehealth.nutrition.readonly",
      "https://www.googleapis.com/auth/googlehealth.ecg.readonly",
      "https://www.googleapis.com/auth/googlehealth.irn.readonly",
    ];
    const url = buildAuthUrl("cid");
    const requestedScopes = new URLSearchParams(url.split("?")[1]).get("scope")?.split(" ") ?? [];
    expect(new Set(requestedScopes)).toEqual(new Set(REQUIRED_SCOPES));
  });

  test("custom redirectUri is included", () => {
    const url = buildAuthUrl("cid", "http://localhost:8080");
    expect(url).toContain(encodeURIComponent("http://localhost:8080"));
  });
});

describe("exchangeCode", () => {
  test("happy path with bare code returns refreshToken and scope", async () => {
    const fakeResp = {
      access_token: "at",
      refresh_token: "rt-abc",
      scope: "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
      token_type: "Bearer",
    };
    const result = await exchangeCode(
      { clientId: "cid", clientSecret: "csec", code: "ABC" },
      makeFetch(fakeResp),
    );
    expect(result.refreshToken).toBe("rt-abc");
    expect(result.scope).toBe(fakeResp.scope);
  });

  test("accepts full redirect URL and submits only the extracted code, not the whole URL", async () => {
    const fakeResp = {
      access_token: "at",
      refresh_token: "rt-extracted",
      scope: "openid",
      token_type: "Bearer",
    };
    const captured: { init?: RequestInit } = {};
    const result = await exchangeCode(
      {
        clientId: "cid",
        clientSecret: "csec",
        code: "http://localhost/?code=ABC123&scope=openid",
      },
      capturingFetch(fakeResp, captured),
    );
    expect(result.refreshToken).toBe("rt-extracted");
    const submitted = new URLSearchParams(captured.init?.body as string);
    expect(submitted.get("code")).toBe("ABC123");
  });

  test("a bare code (no redirect wrapper) is submitted unchanged", async () => {
    const fakeResp = {
      access_token: "at",
      refresh_token: "rt-bare",
      scope: "openid",
      token_type: "Bearer",
    };
    const captured: { init?: RequestInit } = {};
    const result = await exchangeCode(
      { clientId: "cid", clientSecret: "csec", code: "ABC123" },
      capturingFetch(fakeResp, captured),
    );
    expect(result.refreshToken).toBe("rt-bare");
    const submitted = new URLSearchParams(captured.init?.body as string);
    expect(submitted.get("code")).toBe("ABC123");
  });

  test("throws when response lacks refresh_token", async () => {
    const fakeResp = { access_token: "at", token_type: "Bearer" };
    let caught: unknown;
    try {
      await exchangeCode(
        { clientId: "cid", clientSecret: "csec", code: "ABC" },
        makeFetch(fakeResp),
      );
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(Error);
    expect((caught as Error).message).toContain("prompt=consent");
  });
});
