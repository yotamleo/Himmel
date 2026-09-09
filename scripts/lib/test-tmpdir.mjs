// scripts/lib/test-tmpdir.mjs — HIMMEL-2797. Shared temp-dir helper for
// .test.mjs suites: mkdtempSync + a self-registered process-exit cleanup, so
// a suite that creates a temp dir never has to remember to remove it (and a
// test that throws mid-way still gets cleaned up, since the exit handler
// runs regardless of which test failed). Usable from node --test and bun
// alike — it registers on `process`, not on a runner-specific hook.
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dirs = new Set();
let exitHandlerRegistered = false;

export function makeTmpDir(prefix) {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.add(dir);
  if (!exitHandlerRegistered) {
    exitHandlerRegistered = true;
    process.on('exit', () => {
      for (const d of dirs) {
        try {
          rmSync(d, { recursive: true, force: true });
        } catch {
          /* best-effort cleanup */
        }
      }
    });
  }
  return dir;
}
