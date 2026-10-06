// HIMMEL-4480 PR4: records the README GIF's frames. Not part of the e2e suite (playwright.record.config.ts
// matches *.rec.ts only); record-agui-gif.sh runs it and encodes the frames.
// The run is a fixture journal APPENDED to while the page is open: a live stream over the real SSE path.
// HIMMEL-4669: the scene is a leg's /pr-check round with a critic subagent (SCENE in agui-fixtures.ts), at 960 px
// so the GIF needs no downscale, with a caption naming what is shown. Frames are lossless screenshots taken
// every FRAME_MS from the first event on (no empty lead-in; video's compression noise made every GIF frame
// differ). The page follows the newest event, then ends on the overview and holds it.
import { test } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { bootAgui, play } from "./agui-fixtures";

export const FRAME_MS = 125; // record-agui-gif.sh encodes at 1000 / FRAME_MS = 8 fps
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const CAPTION = "himmel · a live Claude Code run, streamed as AG-UI events over SSE: who did what, and where it failed";

test("record the AG-UI page streaming a live run", async ({ browser }) => {
  const dir = process.env.AGUI_FRAMES;
  if (!dir) throw new Error("AGUI_FRAMES (output frame directory) is required; run record-agui-gif.sh");
  mkdirSync(dir, { recursive: true });
  const h = await bootAgui();
  const ctx = await browser.newContext({ colorScheme: "dark", viewport: { width: 960, height: 600 } });
  try {
    const page = await ctx.newPage();
    await page.goto(h.url);
    await page.getByText("Waiting for the agent's first event.").waitFor();
    // The caption is the recorder's, not the page's: a fixed strip along the bottom edge.
    await page.evaluate((text) => {
      const c = document.createElement("div");
      c.textContent = text;
      c.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:9;padding:7px 16px;background:#1f2a35;color:#e8e2d6;"
        + "font:12.5px 'IBM Plex Mono',ui-monospace,monospace;border-top:1px solid #2a2f34";
      document.body.append(c);
      document.body.style.paddingBottom = "40px";
    }, CAPTION);

    let capturing = false, n = 0, frames: Promise<void> | undefined;
    const capture = async () => {
      while (capturing) {
        const t = Date.now();
        await page.screenshot({ path: join(dir, `${String(n++).padStart(5, "0")}.png`) });
        await sleep(Math.max(0, FRAME_MS - (Date.now() - t)));
      }
    };
    const follow = () => page.evaluate(() => window.scrollTo({ top: document.body.scrollHeight })).catch(() => {});
    let step = 0;
    await play(h, undefined, async (ms) => {
      if (++step === 2) { // the prompt is in: frames start with its first paint
        await page.locator(".msg").first().waitFor();
        capturing = true;
        frames = capture();
      }
      await follow();
      await sleep(ms);
    });
    await page.getByRole("status").filter({ hasText: "finished" }).waitFor();
    await sleep(1200);
    await page.evaluate(() => window.scrollTo({ top: 0 }));
    await sleep(2400); // the closing frame: the strip, the agents, the filled review panel
    capturing = false;
    await frames;
  } finally {
    await ctx.close().catch(() => {});
    await h.stop();
  }
});
