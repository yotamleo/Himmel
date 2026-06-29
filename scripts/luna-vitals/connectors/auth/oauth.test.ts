import { describe, test, expect } from "bun:test";
import {
  getAccessToken,
  buildAuthUrl,
  exchangeCode,
  GH_SCOPES,
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

  test("contains all 6 scope strings", () => {
    const url = buildAuthUrl("cid");
    for (const scope of GH_SCOPES) {
      // Scopes are URL-encoded in the query string
      expect(url).toContain(encodeURIComponent(scope));
    }
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

  test("accepts full redirect URL and extracts code", async () => {
    const fakeResp = {
      access_token: "at",
      refresh_token: "rt-extracted",
      scope: "openid",
      token_type: "Bearer",
    };
    const result = await exchangeCode(
      {
        clientId: "cid",
        clientSecret: "csec",
        code: "http://localhost/?code=ABC123&scope=openid",
      },
      makeFetch(fakeResp),
    );
    expect(result.refreshToken).toBe("rt-extracted");
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
