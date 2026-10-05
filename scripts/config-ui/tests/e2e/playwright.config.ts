// HIMMEL-4400: one headless Chromium, serial. Each test boots its own real
// `himmelctl ui` (stub feed via CONFIG_UI_HIMMELCTL), see fixtures.ts.
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  // not *.spec.ts: `bun test scripts/config-ui` (CI) would pick that up and choke on @playwright/test
  testMatch: "*.e2e.ts",
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 30_000,
  reporter: [["list"]],
  use: { headless: true },
});
