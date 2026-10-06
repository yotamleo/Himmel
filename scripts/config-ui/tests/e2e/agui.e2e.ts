// HIMMEL-4480 PR4: the AG-UI page against the real server, driven by a journal that is APPENDED to
// while the page is open (a live stream over the real SSE path). Needs agui-web/dist
// (`cd scripts/config-ui/agui-web && bun install && bun run build`); skipped, loudly, when absent.
import { test, expect } from "@playwright/test";
import { aguiBuilt, bootAgui, J, type AguiHarness } from "./agui-fixtures";

let h: AguiHarness;
test.skip(!aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build");
test.afterEach(async () => { await h?.stop(); });

test("1. appended journal lines render live: run start, a tool call, text, run end", async ({ page }) => {
  h = await bootAgui();
  await page.goto(h.url);
  await expect(page.getByText("Waiting for the agent's first event.")).toBeVisible();

  h.append(J.prompt("List the files in the repo root."));
  await expect(page.getByRole("status")).toHaveText("streaming");

  h.append(J.tool("toolu_ls", "Bash", { command: "ls", description: "List files" }));
  const call = page.locator(".call", { hasText: "Bash" });
  await expect(call).toContainText("List files");
  await expect(call).toContainText("running");

  h.append(J.result("toolu_ls", "README.md\nscripts"));
  await expect(call).toContainText("done");
  await call.locator(".call-head").click();
  await expect(call.locator(".call-body")).toContainText("README.md");

  h.append(J.text("Two entries: README.md and scripts."));
  await expect(page.locator(".msg", { hasText: "Two entries" })).toBeVisible();

  h.append(J.end());
  await expect(page.getByRole("status")).toHaveText("finished");
  await expect(page.locator(".top .meta")).toContainText("events");
});

test("2. a wrong token shows the page's error state, not a transcript", async ({ page }) => {
  h = await bootAgui(J.prompt("hi") + J.text("hello") + J.end());
  await page.goto(h.url.replace(/#t=[0-9a-f]{64}/, `#t=${"0".repeat(64)}`));
  await expect(page.getByRole("alert")).toContainText("The run stopped");
  await expect(page.getByRole("status")).toHaveText("stopped");
  await expect(page.locator(".msg")).toHaveCount(0);
});

for (const [name, scheme, size] of [
  ["dark at desktop width", "dark", { width: 1280, height: 800 }],
  ["light at desktop width", "light", { width: 1280, height: 800 }],
  ["dark at phone width", "dark", { width: 375, height: 700 }],
  ["light at phone width", "light", { width: 375, height: 700 }],
] as const) {
  test(`3. renders in ${name} with no horizontal overflow`, async ({ browser }) => {
    h = await bootAgui(J.prompt("go") + J.tool("toolu_a", "Bash", { command: "echo " + "x".repeat(200), description: "long" }) + J.result("toolu_a", "ok") + J.text("done") + J.end());
    const ctx = await browser.newContext({ colorScheme: scheme, viewport: size });
    const page = await ctx.newPage();
    await page.goto(h.url);
    await expect(page.getByRole("status")).toHaveText("finished");
    await expect(page.locator(".call")).toBeVisible();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await ctx.close();
  });
}
