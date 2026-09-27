import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// HIMMEL-370: every test run gets its own throwaway cache dir, set before any test
// file imports src/kp.ts or src/fetchFactors.ts (both resolve their cache path once,
// at import time, from this env var). No test can then ever write through to the
// operator's real cache at marketplace/plugins/luna-correlate/cache/.
const testCacheDir = mkdtempSync(join(tmpdir(), "luna-correlate-test-cache-"));
process.env.LUNA_CORRELATE_CACHE_DIR = testCacheDir;
process.on("exit", () => rmSync(testCacheDir, { recursive: true, force: true }));
