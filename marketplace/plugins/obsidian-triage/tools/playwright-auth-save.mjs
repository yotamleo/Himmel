#!/usr/bin/env node
/**
 * playwright-auth-save.mjs — one-time interactive login + storage_state capture.
 *
 * Launches a headed playwright browser, lets the operator log in to x.com or
 * youtube.com via the real UI, then persists the resulting cookies + localStorage
 * as a storage_state JSON file under ~/.luna/playwright-state/.
 *
 * The crawler scripts (playwright-crawl-x.mjs, playwright-crawl-youtube.mjs)
 * load this storage_state to make authenticated requests without re-prompting.
 *
 * Usage:
 *   bun marketplace/plugins/obsidian-triage/tools/playwright-auth-save.mjs x
 *   bun marketplace/plugins/obsidian-triage/tools/playwright-auth-save.mjs youtube
 *
 * Exit codes:
 *   0 — storage_state saved
 *   1 — bad usage / unknown service
 *   2 — playwright module missing (run `bun install` in tools/ first)
 *   3 — login timeout (5 min default; operator can re-run)
 *
 * Constraints:
 *   - LUNA-27. Auth-session storage mandatory; public-anon view insufficient.
 *   - No headless mode. The whole point is to defer login to the operator.
 *   - storage_state path is gitignored at ~/.luna/playwright-state/<service>.json.
 */
import { mkdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const SERVICES = {
  x: {
    url: "https://x.com/login",
    // Authenticated UI shows the side-nav account switcher button. Public/logged-out
    // sees a "Sign in" CTA instead. Selector verified against current X DOM (2026-05).
    loggedInSelector: '[data-testid="SideNav_AccountSwitcher_Button"]',
    // Fallback: the home timeline column is also auth-gated.
    fallbackSelector: '[data-testid="primaryColumn"]',
  },
  youtube: {
    url: "https://www.youtube.com",
    // The avatar button in the masthead only renders when signed in. The
    // generic topbar menu shows even when logged out; the inner #avatar-btn
    // is the auth tell.
    loggedInSelector: "ytd-topbar-menu-button-renderer #avatar-btn",
    fallbackSelector: "#avatar-btn",
  },
};

function usage(code = 1) {
  console.error("Usage: playwright-auth-save.mjs <x|youtube>");
  console.error("");
  console.error("Saves storage_state to ~/.luna/playwright-state/<service>.json");
  console.error("after operator completes interactive login.");
  process.exit(code);
}

async function main() {
  const service = process.argv[2];
  if (!service || !SERVICES[service]) {
    usage(1);
  }
  const cfg = SERVICES[service];

  let chromium;
  try {
    ({ chromium } = await import("playwright"));
  } catch (e) {
    console.error("playwright module not installed.");
    console.error("Run: cd marketplace/plugins/obsidian-triage/tools && bun install");
    console.error("Underlying error:", e.message);
    process.exit(2);
  }

  const stateDir = join(homedir(), ".luna", "playwright-state");
  mkdirSync(stateDir, { recursive: true });
  const statePath = join(stateDir, `${service}.json`);

  console.log(`[auth-save] service: ${service}`);
  console.log(`[auth-save] state path: ${statePath}`);
  console.log(`[auth-save] launching headed browser; complete login in the window...`);

  // Use launchPersistentContext instead of `launch + newContext` — the latter hangs
  // silently in some bun + Windows shell combinations. Persistent context also
  // auto-handles a user-data-dir so the browser behaves like a normal Chrome profile
  // during the interactive login.
  //
  // userDataDir is allocated BEFORE the try-block so the finally can always reach it
  // even if launchPersistentContext throws. On Windows, chromium can hold leveldb /
  // SingletonLock files briefly after ctx.close() returns — rmSync may hit EBUSY;
  // we log and continue rather than swallow silently so leaked tmpdirs are surfaced.
  const userDataDir = join(tmpdir(), `pw-auth-save-${service}-${Date.now()}`);
  let ctx;
  let exitCode = 0;

  const cleanupUserDataDir = () => {
    try {
      rmSync(userDataDir, { recursive: true, force: true });
    } catch (e) {
      console.error(
        `[auth-save] cleanup skipped: ${e.code || e.message} at ${userDataDir} — remove manually`,
      );
    }
  };

  try {
    ctx = await chromium.launchPersistentContext(userDataDir, {
      headless: false,
      viewport: null,
      args: ["--start-maximized"],
    });
    const page = ctx.pages()[0] || (await ctx.newPage());
    await page.goto(cfg.url, { waitUntil: "domcontentloaded" });

    // Wait up to 5 minutes for either of the auth-gated selectors to appear.
    // Use Promise.race so whichever fires first wins.
    const TIMEOUT_MS = 5 * 60 * 1000;
    console.log(`[auth-save] waiting up to ${TIMEOUT_MS / 1000}s for login signal...`);
    console.log(`[auth-save] watching for selector: ${cfg.loggedInSelector}`);

    try {
      await Promise.race([
        page.waitForSelector(cfg.loggedInSelector, { timeout: TIMEOUT_MS, state: "attached" }),
        page.waitForSelector(cfg.fallbackSelector, { timeout: TIMEOUT_MS, state: "attached" }),
      ]);
    } catch (e) {
      console.error(`[auth-save] timeout reached without login signal.`);
      console.error(`[auth-save] re-run the script and complete the login flow in the browser.`);
      exitCode = 3;
      return;
    }

    // Give post-login redirects a moment to settle so we capture the final cookie set.
    await page.waitForTimeout(2000);

    await ctx.storageState({ path: statePath });
    console.log(`[auth-save] storage_state saved: ${statePath}`);
    console.log(`[auth-save] you can now run the crawler scripts.`);
  } finally {
    if (ctx) {
      try {
        await ctx.close();
      } catch (e) {
        console.error(`[auth-save] ctx.close warning: ${e.code || e.message}`);
      }
    }
    cleanupUserDataDir();
  }

  process.exit(exitCode);
}

// The inner finally block always runs cleanupUserDataDir(), even on throw — so
// reaching this outer catch only means an exception escaped finally itself
// (e.g. mkdirSync(stateDir) failed BEFORE userDataDir was allocated, or
// playwright import failed). No tmpdir leak hint here — cleanup either ran
// (via finally) or had nothing to clean (userDataDir not yet created).
main().catch((e) => {
  console.error("[auth-save] fatal:", e);
  process.exit(1);
});
