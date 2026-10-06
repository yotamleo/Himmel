// HIMMEL-4480 PR4: records the README video. Not part of the e2e suite (playwright.record.config.ts
// matches *.rec.ts only); record-agui-gif.sh runs it and converts the video to a GIF.
// The run is a fixture journal APPENDED to while the page is open: a live stream over the real SSE path.
import { test, type BrowserContext } from "@playwright/test";
import { bootAgui, J } from "./agui-fixtures";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("record the AG-UI page streaming a live run", async ({ browser }) => {
  const out = process.env.AGUI_WEBM;
  if (!out) throw new Error("AGUI_WEBM (output .webm path) is required; run record-agui-gif.sh");
  const h = await bootAgui();
  const size = { width: 1100, height: 560 };
  let ctx: BrowserContext | undefined;
  try {
    ctx = await browser.newContext({ colorScheme: "dark", viewport: size, recordVideo: { dir: process.env.AGUI_VIDEO_DIR ?? "/tmp", size } });
    const page = await ctx.newPage();
    await page.goto(h.url);
    await page.getByText("Waiting for the agent's first event.").waitFor();
    await sleep(900);
    h.append(J.prompt("Find the config UI port and check the tests still pass."));
    await sleep(900);
    h.append(J.text("Looking for where the port is chosen, and running the suite alongside.", "tool_use"));
    await sleep(1100);
    h.append(J.tool("toolu_grep", "Grep", { pattern: "port", description: "Search for the port" }));
    h.append(J.tool("toolu_test", "Bash", { command: "bun test scripts/config-ui --dots", description: "Run the config-ui suite" }));
    await sleep(1800);
    h.append(J.result("toolu_grep", "server.ts:92: port: 0"));
    await sleep(1500);
    h.append(J.result("toolu_test", "120 pass\n0 fail"));
    await sleep(1000);
    h.append(J.text("The server binds port 0 so the OS picks one, and all 120 tests pass."));
    await sleep(1300);
    h.append(J.end());
    await page.getByRole("status").filter({ hasText: "finished" }).waitFor();
    await sleep(1500);
    await ctx.close();
    await page.video()!.saveAs(out);
  } finally {
    await ctx?.close().catch(() => {});
    await h.stop();
  }
});
