// HIMMEL-4480 PR4: the recorder's own config; record-agui-gif.sh runs it. The e2e suite never does.
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "*.rec.ts",
  workers: 1,
  retries: 0,
  timeout: 60_000,
  reporter: [["list"]],
  use: { headless: true },
});
