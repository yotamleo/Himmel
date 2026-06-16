#!/usr/bin/env node
import { runInit } from './init-flow.mjs';

try {
  const result = await runInit();
  process.stdout.write(result.summary + '\n');
  process.exit(result.exitCode);
} catch (e) {
  process.stderr.write(`gh init: unexpected error: ${e && e.message ? e.message : String(e)}\n`);
  process.exit(1);
}
