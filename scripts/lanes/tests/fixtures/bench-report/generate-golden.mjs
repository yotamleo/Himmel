// One-off generator used to produce golden.md — NOT part of the test suite
// itself (no .test.mjs suffix, so node --test never picks it up). Re-run
// manually if report.mjs's rendering intentionally changes shape.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderReport } from '../../../bench/report.mjs';
import { syntheticRuns, syntheticTokenRows } from './synthetic-runs.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const text = renderReport({ runs: syntheticRuns, tokenRowsByRunId: syntheticTokenRows() });
writeFileSync(join(here, 'golden.md'), text);
process.stdout.write(text);
