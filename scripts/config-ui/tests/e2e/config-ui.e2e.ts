// HIMMEL-4400: the manual checklist for the config UI (PR 1841, bundles), automated.
// Items 1-7 are the checklist; the last test is the safety contract.
import { test, expect, type Page } from "@playwright/test";
import { boot, BUNDLES, HIMMEL_ID, type Harness, type Variant } from "./fixtures";

let h: Harness;
test.afterEach(async () => { await h?.stop(); });

async function open(page: Page, v: Variant = {}) {
  h = await boot(v);
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

test("rail page links are [Config]; Config is current and the hash is #/config", async ({ page }) => {
  await open(page);
  expect(await page.locator("nav.pages a").allTextContents()).toEqual(["Config"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  expect(await page.evaluate(() => location.hash)).toBe("#/config");
});

test("at 390 px the page does not scroll horizontally", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await open(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});
