// HIMMEL-4400: the manual checklist for the config UI (PR 1841, bundles), automated.
// Items 1-7 are the checklist; the last test is the safety contract.
import { test, expect, type Page } from "@playwright/test";
import { boot, BUNDLES, HIMMEL_ID, type BootOpts, type Harness, type Variant } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

async function open(page: Page, v: Variant = {}, o: BootOpts = {}) {
  h = await boot(v, o);
  await page.goto(h.url);
  await page.locator("#inventory .bhead").first().waitFor();
}
const heads = (region: string) => `#${region} .bhead`;
const titles = (page: Page, region: string) => page.locator(`${heads(region)} .bt`).allTextContents();
const head = (page: Page, title: string) => page.locator(`#inventory .bhead`, { has: page.locator(".bt", { hasText: new RegExp(`^${title}$`) }) });
const ALL = BUNDLES.map((b) => b.title);

test("1. Controls and Inventory render as bundles in table order", async ({ page }) => {
  await open(page);
  expect(await titles(page, "inventory")).toEqual(ALL);
  // Controls lists only bundles that hold a toggle, in the same table order.
  expect(await titles(page, "controls")).toEqual(["Vault & capture", "Ship workflow"]);
});

test("2. a bundle with no fail or warn row is collapsed; one with a fail or warn row opens", async ({ page }) => {
  await open(page);
  for (const t of ALL) {
    await expect(head(page, t), t).toHaveAttribute("aria-expanded", t === "Guards & safety" ? "true" : "false");
  }
  await expect(page.locator("#inventory .row-head", { hasText: "guard-fail" })).toBeVisible();
  await expect(page.locator("#inventory .row-head", { hasText: "qmd-binary" })).toHaveCount(0);
});

test("3. each header shows its headline health and only the non-zero counts", async ({ page }) => {
  await open(page);
  const bypass = head(page, "Bypass flags");
  await expect(bypass.locator(".bc")).toHaveText("48 off");
  await expect(bypass.locator(".st")).toHaveClass(/\boff\b/);
  const guards = head(page, "Guards & safety");
  await expect(guards.locator(".bc")).toHaveText("1 fail · 1 warn · 2 ok");
  await expect(guards.locator(".st")).toHaveClass(/\bfail\b/);
  await expect(head(page, "Lanes & models").locator(".bc")).toHaveText("1 ok");
});

test("4. show only problems hides healthy rows; header counts read n of N", async ({ page }) => {
  await open(page);
  await page.getByRole("switch", { name: /show only problems/ }).click();
  expect(await titles(page, "inventory")).toEqual(["Guards & safety"]);
  await expect(head(page, "Guards & safety").locator(".bn")).toHaveText("2 of 4");
  expect(await page.locator("#inventory .row-head .id").allTextContents()).toEqual(["guard-fail", "guard-warn"]);
});

test("5. searching C45 opens Search & graph with the hit row; clearing restores the default", async ({ page }) => {
  await open(page);
  await page.locator("#q").fill("C45");
  expect(await titles(page, "inventory")).toEqual(["Search & graph"]);
  await expect(head(page, "Search & graph")).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator("#inventory .row-head", { hasText: "doctor:C45-e2e-hit" })).toBeVisible();
  await page.locator("#q").fill("");
  expect(await titles(page, "inventory")).toEqual(ALL);
  await expect(head(page, "Search & graph")).toHaveAttribute("aria-expanded", "false");
  await expect(head(page, "Guards & safety")).toHaveAttribute("aria-expanded", "true");
});

test("6. Tab to a header; Enter or Space toggles it; focus stays on that header", async ({ page }) => {
  await open(page);
  const key = "inventory|search";
  const focused = () => page.evaluate(() => (document.activeElement as HTMLElement | null)?.dataset?.b ?? null);
  await page.locator("#q").focus();
  let n = 0;
  while ((await focused()) !== key) {
    if (++n > 120) throw new Error("Tab never reached the Search & graph header");
    await page.keyboard.press("Tab");
  }
  const sh = head(page, "Search & graph");
  await expect(sh).toHaveAttribute("aria-expanded", "false");
  await page.keyboard.press("Enter");
  await expect(sh).toHaveAttribute("aria-expanded", "true");
  expect(await focused()).toBe(key);
  await page.keyboard.press("Space");
  await expect(sh).toHaveAttribute("aria-expanded", "false");
  expect(await focused()).toBe(key);
});

test("7. Unsorted is absent with 0 unmapped rows; with one it is always open and last", async ({ page }) => {
  await open(page);
  expect(await titles(page, "inventory")).not.toContain("Unsorted");
  await h.stop();
  await open(page, { unmapped: true });
  const t = await titles(page, "inventory");
  expect(t[t.length - 1]).toBe("Unsorted");
  expect(t).toEqual([...ALL, "Unsorted"]);
  await expect(head(page, "Unsorted")).toHaveAttribute("aria-expanded", "true");
  await head(page, "Unsorted").click(); // always open: a toggle must not collapse it
  await expect(head(page, "Unsorted")).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator("#inventory .row-head", { hasText: "orphan-row" })).toBeVisible();
});

test("safety: a toggle shows only a dry-run plan; nothing runs without the typed consent; cancel clears it", async ({ page }) => {
  await open(page);
  await page.locator("#controls .bhead", { hasText: "Vault & capture" }).click(); // healthy bundle: collapsed by default
  await page.locator('#controls button[data-act="plan"][data-target="pipeline"]').click();
  const plan = page.locator("#controls .plan");
  await expect(plan).toContainText("dry-run · nothing has changed");
  await expect(plan.locator("pre")).toContainText("--dry-run");
  const confirm = plan.locator('button[data-act="run"]');
  await expect(confirm).toBeDisabled();
  await plan.locator('input[data-act="consent"]').fill("not-the-target");
  await expect(confirm).toBeDisabled();
  await plan.locator('input[data-act="consent"]').fill((await plan.locator("label b").innerText()).trim());
  await expect(confirm).toBeEnabled(); // typed consent matches; still nothing has run: cancel, never confirm
  await plan.locator('button[data-act="close"]').click();
  await expect(page.locator("#controls .plan")).toHaveCount(0);
  const ran = h.argv();
  expect(ran.length).toBeGreaterThan(0);
  expect(ran.every((l) => l.endsWith("--dry-run")), ran.join("\n")).toBe(true);
  expect(h.stateFiles()).toEqual([]);
});

// HIMMEL-4405 PR-a: the shared header and the page links.
test("header shows describe, the 12-char commit, checkout and feed time", async ({ page }) => {
  await open(page);
  const top = page.locator("header.top");
  await expect(top).toContainText(HIMMEL_ID.describe);
  await expect(top).toContainText(HIMMEL_ID.commit.slice(0, 12));
  await expect(top).not.toContainText(HIMMEL_ID.commit.slice(0, 13));
  await expect(top).toContainText(HIMMEL_ID.checkout);
  await expect(top).toContainText("2026-10-04 14:02");
});

test("header without feed.himmel reads version unknown, never blank", async ({ page }) => {
  await open(page, { noIdentity: true });
  await expect(page.locator("header.top")).toContainText("version unknown (feed has no himmel identity)");
});

test("rail page links are [Config, Health, Fleet]; Config is current and the hash is #/config", async ({ page }) => {
  await open(page);
  expect(await page.locator("nav.pages a").allTextContents()).toEqual(["Config", "Health", "Fleet"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  expect(await page.evaluate(() => location.hash)).toBe("#/config");
});

test("at 390 px the page does not scroll horizontally", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await open(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});

// HIMMEL-4405 PR-b: the Health page.
const LEDGER = [
  { ts: "2026-10-05T01:00:00Z", leg: "old", verdict: "SKIPPED-BANK", five_hour: "91.0", seven_day: "77.0", age: "3", degraded: false },
  { ts: "2026-10-05T02:00:00Z", leg: "l", verdict: "PROCEED", five_hour: "22.0", seven_day: "86.0", age: "12", degraded: false },
  { ts: "2026-10-05T02:30:00Z", leg: "claudex", verdict: "PROCEED", five_hour: "", seven_day: "", age: "", degraded: false },
];
const PAGE_ALERT = { labels: { alertname: "E2EPageAlert", severity: "page" }, annotations: { summary: "e2e-page-alert-summary" } };
const SECTIONS = ["Is himmel healthy?", "What is broken, and what do I do", "Scheduled jobs", "Legs and the usage bank", "Search and graph freshness"];

async function openHealth(page: Page, v: Variant = {}, o: BootOpts = {}) {
  await open(page, v, o);
  await page.locator("nav.pages a", { hasText: "Health" }).click();
  await page.locator("#verdict .word").waitFor();
}
const verdictWord = (page: Page) => page.locator("#verdict .word");

test("health: Config to Health to browser back; aria-current follows; one header on both", async ({ page }) => {
  await open(page);
  expect(await page.locator("nav.pages a").allTextContents()).toEqual(["Config", "Health", "Fleet"]);
  await page.locator("nav.pages a", { hasText: "Health" }).click();
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Health");
  expect(await page.evaluate(() => location.hash)).toBe("#/health");
  await expect(page.locator("header.top")).toHaveCount(1);
  await expect(page.locator("header.top")).toContainText(HIMMEL_ID.describe);
  await page.goBack();
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  await expect(page.locator("#inventory .bhead").first()).toBeVisible();
});

test("health: reloading at #/health starts loadHealth without a page error", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await openHealth(page);
  await page.reload();
  await page.locator("#verdict .word").waitFor();
  expect(errors).toEqual([]);
  await expect(page.locator("#bank, #legs").first()).not.toContainText("loading");
});

test("health: the five sections appear in spec order", async ({ page }) => {
  await openHealth(page);
  expect(await page.locator("main h2").allTextContents()).toEqual(SECTIONS);
});

test("health: fail first with remedy; open in Config lands on the row", async ({ page }) => {
  await openHealth(page, { failDetail: "e2e-fail-detail" });
  const rows = page.locator("#broken .hrow");
  expect(await rows.locator(".id").allTextContents()).toEqual(["guard-fail", "guard-warn"]);
  await expect(rows.first()).toContainText("e2e-fail-detail");
  await expect(rows.first()).toContainText("fix-guard-cmd");
  await expect(rows.first().locator('[data-act="copy"]')).toBeVisible();
  await rows.first().locator('[data-act="open-config"]').click();
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  await expect(page.locator("#q")).toHaveValue("guard-fail");
  await expect(page.locator("#inventory .row-head", { hasText: "guard-fail" })).toBeVisible();
});

test("health: the verdict names its inputs; cadence jobs and search rows come from the feed", async ({ page }) => {
  await openHealth(page);
  await expect(verdictWord(page)).toHaveText("Act now");
  await expect(page.locator("#verdict")).toContainText("1 fail · 1 warn");
  await expect(page.locator("#jobs")).toContainText("luna-pipeline");
  await expect(page.locator("#jobs")).toContainText("armed e2e");
  await expect(page.locator("#jobs")).toContainText("ran-e2e-evidence");
  await expect(page.locator("#search")).toContainText("qmd-binary");
  await expect(page.locator("#search")).toContainText("C45-e2e-hit");
});

test("health: bank card shows the newest row with bank numbers; I2 the ledger is never appended; the card follows the fixture", async ({ page }) => {
  await openHealth(page, {}, { ledger: LEDGER });
  const bank = page.locator("#bank");
  await expect(bank).toContainText("Last bank preflight");
  await expect(bank).toContainText("PROCEED");
  await expect(bank).toContainText("86.0");
  await expect(bank).toContainText("22.0");
  await expect(bank).not.toContainText("SKIPPED-BANK"); // an older row, and the newest row has no bank numbers
  expect(h.ledgerLines()).toBe(LEDGER.length);
  h.writeLedger([{ ...LEDGER[1], seven_day: "55.5" }]);
  await page.locator('[data-act="refresh-health"]').click();
  await expect(bank).toContainText("55.5");
  expect(h.ledgerLines()).toBe(1);
});

test("health: legs card shows the leg doc and its marker from the real parsers (BLOCKED flips it)", async ({ page }) => {
  await openHealth(page, {}, { handover: { bullet: "- 03:00 LIVE — x" } });
  const legs = page.locator("#legs");
  await expect(legs).toContainText("HIMMEL-9999-N1-e2e-leg-RESUME.md");
  await expect(legs.locator(".leg .mk")).toHaveText("LIVE");
  h.setBullet("- 03:05 BLOCKED — y");
  await page.locator('[data-act="refresh-health"]').click();
  await expect(legs.locator(".leg .mk")).toHaveText("BLOCKED");
});

test("health: with the feed pending the verdict is No data and bank and legs still render (D2)", async ({ page }) => {
  h = await boot({}, { ledger: LEDGER, handover: { bullet: "- 03:00 LIVE — x" }, feedDelayMs: 5000 });
  await page.goto(h.url);
  await page.evaluate(() => { location.hash = "#/health"; });
  await expect(verdictWord(page)).toHaveText("No data");
  await expect(page.locator("#bank")).toContainText("86.0");
  await expect(page.locator("#legs")).toContainText("LIVE");
  await expect(verdictWord(page)).toHaveText("Act now", { timeout: 20_000 }); // the feed lands, the verdict follows
});

test("health: returning to Config before the feed lands shows loading, not Health content (HIMMEL-4443)", async ({ page }) => {
  h = await boot({}, { ledger: LEDGER, handover: { bullet: "- 03:00 LIVE — x" }, feedDelayMs: 5000 });
  await page.goto(h.url);
  await page.evaluate(() => { location.hash = "#/health"; });
  await expect(verdictWord(page)).toHaveText("No data");
  await page.locator("nav.pages a", { hasText: "Config" }).click();
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  await expect(page.locator("main #verdict")).toHaveCount(0);
  await expect(page.locator("#status")).toHaveText("loading…");
  await expect(page.locator("#inventory .bhead").first()).toBeVisible({ timeout: 20_000 }); // the feed lands and Config paints
});

test("health: a firing page alert makes the verdict Act now and shows its summary", async ({ page }) => {
  await openHealth(page, { clean: true }, { prom: { alerts: [PAGE_ALERT] } });
  await expect(verdictWord(page)).toHaveText("Act now");
  await expect(page.locator("#verdict")).toContainText("alerts: 1 firing");
  await expect(page.locator("#broken .alert")).toContainText("E2EPageAlert");
  await expect(page.locator("#broken .alert")).toContainText("e2e-page-alert-summary");
});

test("health: every source absent leaves No data cards that name the source; verdict says alerts not checked (I3, I6)", async ({ page }) => {
  await openHealth(page, { clean: true });
  await expect(verdictWord(page)).toHaveText("All clear");
  await expect(page.locator("#verdict")).toContainText("alerts not checked");
  await expect(page.locator("#bank .nodata")).toContainText("bank-preflight ledger");
  await expect(page.locator("#legs .nodata")).toContainText("fleet manifest");
  await expect(page.locator("#verdict .nodata")).toContainText("monitoring tier not running");
  expect(await page.locator("main h2").allTextContents()).toEqual(SECTIONS);
});

test("health: at 390 px the page does not scroll horizontally", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await openHealth(page, {}, { ledger: LEDGER, handover: { bullet: "- 03:00 LIVE — x" }, prom: { alerts: [PAGE_ALERT] } });
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});
