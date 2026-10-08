// HIMMEL-4480 PR4: the AG-UI page against the real server, driven by a journal that is APPENDED to
// while the page is open (a live stream over the real SSE path). Needs agui-web/dist
// (`cd scripts/config-ui/agui-web && bun install && bun run build`); skipped, loudly, when absent.
import { test, expect } from "@playwright/test";
import { CLOUD, FLEET, PRIOR_CONSOLE } from "../agui-fleet-fixture";
import { aguiBuilt, bootAgui, J, play, type AguiHarness } from "./agui-fixtures";

// HIMMEL-4711: a live page keeps tailing after a turn ends, so it reads idle (never "finished") until the stream closes.
const IDLE = /^idle · last event \d+s ago$/;

let h: AguiHarness;
test.skip(!aguiBuilt(), "agui-web/dist is not built: cd scripts/config-ui/agui-web && bun install && bun run build");
test.afterEach(async () => { await h?.stop(); });

test("1. appended journal lines render live: run start, a tool call, text, run end", async ({ page }) => {
  h = await bootAgui();
  await page.goto(h.url);
  await expect(page.getByText("Waiting for the agent's first event.")).toBeVisible();

  h.append(J.prompt("List the files in the repo root."));
  await expect(page.getByRole("status")).toHaveText("live");

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
  await expect(page.getByRole("status")).toHaveText(IDLE);
  await expect(page.locator(".top .meta")).toContainText(/^started \d\d:\d\d:\d\d.* · 1 turn · \d+ events/);
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
    await expect(page.getByRole("status")).toHaveText(IDLE);
    await expect(page.locator(".call")).toBeVisible();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await ctx.close();
  });
}

// HIMMEL-4669: the leg's /pr-check round with a critic subagent (SCENE), its transcript in a separate file.
// Steps are a few ms apart so the server's timestamp merge interleaves the two files as they were written.
const spaced = (h: AguiHarness) => play(h, undefined, () => new Promise((r) => setTimeout(r, 15)));

test("4. each agent is named with its role and model, its work under its name, and a filter shows one agent", async ({ page }) => {
  h = await bootAgui();
  await spaced(h);
  await page.goto(h.url);
  await expect(page.getByRole("status")).toHaveText(IDLE);
  const agents = page.locator(".agents .agent");
  await expect(agents).toHaveCount(2);
  await expect(agents.nth(0)).toContainText("HIMMEL-1957-N1290-check-ci-cap");
  await expect(agents.nth(0)).toContainText("leg · opus 5.5");
  await expect(agents.nth(1)).toContainText("correctness critic");
  await expect(agents.nth(1)).toContainText("critic · code-reviewer · sonnet 5.5");
  // the critic's Read sits in a block headed by the critic, one step in; the leg's calls do not
  const critic = page.locator(".block.sub", { hasText: "correctness critic" });
  await expect(critic.locator(".call", { hasText: "Read" })).toBeVisible();
  await expect(critic.locator(".call", { hasText: "Push the fix" })).toHaveCount(0);
  await expect(page.locator(".band")).toHaveCount(2);

  await agents.nth(1).click();
  await expect(agents.nth(1)).toHaveAttribute("aria-pressed", "true");
  await expect(page.locator(".call", { hasText: "Push the fix" })).toHaveCount(0);
  await expect(page.locator(".call", { hasText: "Grep" })).toBeVisible();
  await page.getByRole("button", { name: "Show every agent" }).click();
  await expect(page.locator(".call", { hasText: "Push the fix" })).toBeVisible();
});

test("5. failures are marked by kind, counted per agent, and the jump control walks them in order", async ({ page }) => {
  h = await bootAgui();
  await spaced(h);
  await page.goto(h.url);
  await expect(page.getByRole("status")).toHaveText(IDLE);
  await expect(page.locator(".fails-count")).toHaveText("4 failures");
  await expect(page.locator(".agents .agent").nth(0)).toContainText("4 failures");
  await expect(page.locator(".call.failed")).toHaveCount(3);
  await expect(page.locator(".call.failed.suite .badge")).toHaveText("suite failed");
  await expect(page.locator(".call.failed.denied .badge")).toHaveText("denied");
  await expect(page.locator(".call.failed.blocked .badge")).toHaveText("blocked");
  await expect(page.locator(".msg.failed.blocked")).toContainText("Holding for the console");
  await expect(page.locator(".bar.failed")).toHaveCount(3);

  // filtered to the critic (no failures), a jump shows everyone again and lands on the first failure
  await page.locator(".agents .agent").nth(1).click();
  await page.getByRole("button", { name: "Next failure" }).click();
  await expect(page.locator(".fails-count")).toHaveText("4 failures · 1 of 4");
  await expect(page.locator("#call-toolu_suite")).toBeFocused();
  await expect(page.locator("#call-toolu_suite")).toHaveAttribute("aria-expanded", "true");
  await expect(page.locator(".call.failed.suite .call-body")).toContainText("not ok 7");
  await page.getByRole("button", { name: "Next failure" }).click();
  await expect(page.locator("#call-toolu_push")).toBeFocused();
  await page.getByRole("button", { name: "Previous failure" }).click();
  await expect(page.locator("#call-toolu_suite")).toBeFocused();
});

test("6. long tool output shows its head with a control for the rest", async ({ page }) => {
  h = await bootAgui();
  await spaced(h);
  await page.goto(h.url);
  await expect(page.getByRole("status")).toHaveText(IDLE);
  const read = page.locator(".call", { hasText: "Read" });
  await read.locator(".call-head").click();
  await expect(read.locator(".call-body pre").last()).not.toContainText("line 40");
  await read.getByRole("button", { name: "Show all 40 lines" }).click();
  await expect(read.locator(".call-body pre").last()).toContainText("line 40");
});

test("7. the agent view keeps both themes and phone width free of horizontal overflow", async ({ browser }) => {
  h = await bootAgui();
  await spaced(h);
  for (const scheme of ["dark", "light"] as const) {
    const ctx = await browser.newContext({ colorScheme: scheme, viewport: { width: 375, height: 700 } });
    const page = await ctx.newPage();
    await page.goto(h.url);
    await expect(page.getByRole("status")).toHaveText(IDLE);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow).toBeLessThanOrEqual(0);
    await ctx.close();
  }
});

test("8. a running subagent shows running with its current call, then flips to done when its Agent call returns", async ({ page }) => {
  h = await bootAgui();
  await page.goto(h.url);
  const sub = { sub: "b4d2f1", model: "claude-sonnet-5-5" };
  h.append(J.prompt("Check the diff with a critic."));
  h.append(J.tool("toolu_agent", "Agent", { description: "diff critic", subagent_type: "pr-review-toolkit-himmel:code-reviewer", prompt: "Read check-ci.sh" }));
  h.appendSub("b4d2f1", J.prompt("Read check-ci.sh", sub));
  h.appendSub("b4d2f1", J.tool("toolu_r", "Read", { file_path: "scripts/check-ci.sh" }, sub));
  // by its name: the leg's own row also names the critic, in the Agent call it is running
  const critic = page.locator(".agents li", { has: page.locator(".agent-name", { hasText: "diff critic" }) });
  await expect(critic.locator(".agent-state")).toHaveText("running");
  await expect(critic.locator(".agent-now")).toContainText("Read scripts/check-ci.sh");
  await expect(page.locator(".agents-running")).toHaveText("2 running");
  await expect(page.getByRole("status")).toHaveText("live");

  h.appendSub("b4d2f1", J.result("toolu_r", "ok", sub));
  h.appendSub("b4d2f1", J.text("Looks right.", "end_turn", sub));
  await expect(critic.locator(".agent-now")).toContainText("last active"); // between calls: no current call
  await expect(critic.locator(".agent-state")).toHaveText("running"); // its Agent call is still open
  h.append(J.result("toolu_agent", "Looks right.", { use: { status: "completed", agentId: "b4d2f1" } }));
  await expect(critic.locator(".agent-state")).toHaveText("done");
  await expect(page.locator(".agents-running")).toHaveText("1 running");
  h.append(J.end());
  await expect(page.locator(".agents-running")).toHaveText("0 running");
  await expect(page.getByRole("status")).toHaveText(IDLE);
});

// HIMMEL-4712: `himmelctl ui --agui` with no session id opens the fleet landing over the fixture fleet (3 live +
// 1 wrapped); the wrapped leg sits in the closed section, never in the live list; a row opens its run's stream.
test("archived and released consoles show zero live sessions", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const fleet = await response.json();
    const console = fleet.sessions.find((r: any) => r.role === "console");
    fleet.sessions = [
      { ...console, name: "archived-console", console: "archived-console", live: false, state: "unknown" },
      { ...console, name: "released-console", console: "released-console", lock: "released" },
    ];
    await route.fulfill({ response, json: fleet });
  });
  await page.goto(h.url);
  await expect(page.locator(".top .meta")).toContainText("0 live");
  await expect(page.getByText("No live sessions.", { exact: true })).toBeVisible();
});

test("a wrapped session with no console retains a collapsed sidebar drill-in", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const fleet = await response.json();
    const wrapped = fleet.sessions.find((r: any) => r.state === "wrapped");
    fleet.sessions = [{ ...wrapped, console: "gone-console", parent: "gone-console" }];
    await route.fulfill({ response, json: fleet });
  });
  await page.goto(h.url);
  const wrapped = page.locator(".fleet-menu .fleet-menu-wrapped");
  await expect(wrapped).not.toHaveAttribute("open", "");
  await wrapped.locator("summary").click();
  await expect(wrapped.getByRole("link", { name: FLEET.wrapped.name, exact: true })).toHaveAttribute("href", new RegExp(`&run=${FLEET.wrapped.run}$`));
});
test("9. the fleet landing lists 3 live sessions and 1 wrapped one, and a row opens that session's stream", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  expect(h.url).not.toContain("&run=");
  await page.goto(h.url);
  const live = page.locator(".fleet .fleet-row:not(.finished)");
  await expect(live).toHaveCount(3);
  await expect(live.nth(0)).toContainText(FLEET.console.name);
  await expect(live.nth(0)).toContainText("console");
  const leg = live.filter({ hasText: FLEET.leg.name });
  await expect(leg).toContainText("HIMMEL-901 · PR 1901");
  await expect(leg).toContainText("1 of 1 subagents running");
  await expect(leg).toContainText("1 failure");
  await expect(leg.locator(".state")).toHaveText("running");
  await expect(live.filter({ hasText: FLEET.idle.name }).locator(".state")).toHaveText("idle");
  await expect(live.filter({ hasText: FLEET.wrapped.name })).toHaveCount(0);
  // HIMMEL-4751: the leg sits in its console's subtree; each row says where it hangs and what it has spent.
  await expect(page.getByRole("region", { name: FLEET.console.name }).getByRole("list", { name: "Live sessions" }).locator(".fleet-row")).toHaveText([new RegExp(FLEET.leg.name)]);
  await expect(leg.locator(".fleet-graph")).toHaveText(`under ${FLEET.console.name}`);
  await expect(live.nth(0).locator(".fleet-graph")).toHaveText(`under the operator · successor to ${PRIOR_CONSOLE} (not live)`);
  await expect(leg.locator(".fleet-usage")).toHaveText("context 20% of 200.0k (autocompact) · 3 calls · in 30 · out 300 · cache read 120.0k · cache write 0 · cost-eq 13.5k");
  await expect(leg.locator(".fleet-agent")).toHaveCount(1);
  await expect(live.filter({ hasText: FLEET.idle.name }).locator(".fleet-usage")).toHaveText(/not measured/);
  await leg.locator(".fleet-rel").click();
  await expect(live.nth(0)).toBeFocused();

  const closed = page.locator("details.fleet-closed");
  await expect(closed.locator("summary")).toHaveText("Wrapped (1)");
  await expect(closed).not.toHaveAttribute("open", "");
  await closed.locator("summary").click();
  const wrapped = page.getByRole("list", { name: "Wrapped sessions" }).locator(".fleet-row");
  await expect(wrapped).toHaveCount(1);
  await expect(wrapped.locator(".state")).toHaveText("wrapped");

  await leg.locator("a.fleet-head").click();
  await expect(page).toHaveURL(new RegExp(`&run=${FLEET.leg.run}$`));
  await expect(page.locator(".top .run")).toHaveText(`run ${FLEET.leg.run}`);
  await expect(page.locator(".call", { hasText: "Push" })).toBeVisible();
});

// HIMMEL-4711: one app across two documents. The console's rail reaches the fleet, a fleet row reaches its run view,
// the rail there reaches back to Config and Health, and the token never rides a request line.
test("10. console to Fleet to a run view and back: one rail, the token in the fragment only", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  const tok = /#t=([0-9a-f]{64})/.exec(h.url)![1];
  const lines: string[] = [];
  page.on("request", (r) => lines.push(r.url()));
  await page.goto(h.url.replace("/agui/#t=", "/#t="));
  const rail = page.locator("nav.pages a");
  await expect(rail).toHaveText(["Config", "Health", "Fleet"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  expect(await page.evaluate(() => location.hash)).toBe("#/config");
  await expect(rail.filter({ hasText: "Fleet" }).locator(".st-dot")).toHaveClass(/\bok\b/);

  await rail.filter({ hasText: "Fleet" }).click();
  await expect(page).toHaveURL(new RegExp(`/agui/#t=${tok}$`));
  await expect(rail).toHaveText(["Config", "Health", "Fleet"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Fleet");
  const leg = page.locator(".fleet .fleet-row:not(.finished)").filter({ hasText: FLEET.leg.name });
  await expect(leg.locator("a.fleet-link")).toHaveAttribute("href", `/#t=${tok}&page=health`);

  await leg.locator("a.fleet-head").click();
  await expect(page).toHaveURL(new RegExp(`&run=${FLEET.leg.run}$`));
  await expect(rail).toHaveText(["Config", "Health", "Fleet", "Run"]);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Run");
  await expect(page.locator(".call", { hasText: "Push" })).toBeVisible();

  await rail.filter({ hasText: "Config" }).click();
  await expect(page).toHaveURL(/\/#\/config$/);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Config");
  await page.goBack();
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Run");

  await page.goto(h.url);
  await page.locator(".fleet .fleet-row:not(.finished)").filter({ hasText: FLEET.leg.name }).locator("a.fleet-link").click();
  await expect(page).toHaveURL(/\/#\/health$/);
  await expect(page.locator('nav.pages a[aria-current="page"]')).toHaveText("Health");

  expect(lines.length).toBeGreaterThan(0);
  for (const u of lines) expect(new URL(u).pathname + new URL(u).search).not.toContain(tok);
});

test("12. two-console side menu, deep-linked page, and identical menu/row drill-in", async ({ page }) => {
  h = await bootAgui("", { fleet: true });
  const other = "HIMMEL-project-console";
  await page.route("**/api/agui/fleet", async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    const console = body.sessions.find((r: any) => r.name === FLEET.console.name);
    body.sessions.push({ ...console, name: other, console: other, predecessor: null });
    const child = body.sessions.find((r: any) => r.name === FLEET.idle.name);
    Object.assign(child, { role: "leg", parent: other, console: other, lane: "claudex" });
    await route.fulfill({ response, json: body });
  });
  await page.goto(`${h.url}&console=${other}`);
  await expect(page.locator(".top .run")).toHaveText(other);
  await expect(page.locator(".fleet-console h2")).toHaveText(other);
  await expect(page.locator(".fleet")).toContainText(FLEET.idle.name);
  await expect(page.locator(".fleet")).not.toContainText(FLEET.leg.name);
  const menu = page.getByRole("navigation", { name: "Consoles" });
  await expect(menu.locator("a.console-page")).toHaveCount(2);
  await menu.locator("a.console-page", { hasText: FLEET.console.name }).click();
  await expect(page.locator(".fleet-console h2")).toHaveText(FLEET.console.name);
  const leg = page.locator(".fleet .fleet-row", { hasText: FLEET.leg.name });
  const rowHref = await leg.locator("a.fleet-head").getAttribute("href");
  const menuLeg = menu.getByRole("link", { name: FLEET.leg.name, exact: true });
  await expect(menuLeg).toHaveAttribute("href", rowHref!);
  await menuLeg.click();
  await expect(page.locator(".top .run")).toHaveText(`run ${FLEET.leg.run}`);
  await expect(page.locator(".call", { hasText: "Push" })).toBeVisible();
  await menu.getByRole("link", { name: FLEET.console.name, exact: true }).last().click();
  await expect(page.locator(".top .run")).toHaveText(`run ${FLEET.console.run}`);
});

// HIMMEL-4791: a cloud session is a node under its console with its shepherd leg under it; it links its session,
// says its phase, and says its tokens are not measured (never a zero). A merged one sits with the wrapped.
test("11. cloud sessions: a node under the console, its shepherd under it, tokens not measured", async ({ page }) => {
  h = await bootAgui("", { fleet: true, cloud: true });
  await page.goto(h.url);
  const live = page.locator(".fleet .fleet-row:not(.finished)");
  const done = live.filter({ hasText: "cloud-HIMMEL-905" }).first();
  await expect(done.locator(".fleet-role")).toHaveText("cloud · cloud bank");
  await expect(done.locator(".fleet-meta")).toHaveText("HIMMEL-905 · PR 1905 · CLOUD-DONE, shepherd's turn · cloud session");
  await expect(done.locator("a.fleet-cloud")).toHaveAttribute("href", CLOUD.url);
  await expect(done.locator(".fleet-usage")).toHaveText("tokens not measured: a cloud session keeps no local journal and no source exposes its usage");
  await expect(done.locator(".fleet-graph")).toHaveText(`under ${FLEET.console.name}`);
  await expect(page.getByRole("list", { name: "Under cloud-HIMMEL-905" }).locator(".fleet-row")).toHaveText([new RegExp(CLOUD.shepherd.name)]);
  await expect(live.filter({ hasText: "cloud-HIMMEL-906" }).locator(".fleet-meta")).toHaveText("HIMMEL-906 · no CLOUD-DONE yet");
  await expect(page.getByRole("region", { name: "Orphans" }).filter({ has: page.locator(".fleet-row") })).toContainText("cloud session without a shepherd");
  await expect(live.filter({ hasText: "cloud-HIMMEL-907" })).toHaveCount(0);
  const console = page.getByRole("region", { name: FLEET.console.name });
  await console.locator("details.fleet-closed summary").click();
  await expect(console.getByRole("list", { name: "Wrapped sessions" }).locator(".fleet-row").filter({ hasText: "cloud-HIMMEL-907" }).locator(".fleet-meta")).toHaveText("HIMMEL-907 · PR 1907 · PR merged · cloud session");
});
