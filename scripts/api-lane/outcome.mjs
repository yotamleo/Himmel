// HIMMEL-4985: reads the JSON result file of a launcher run and prints
// the verified total_cost_usd (six places) or nothing. Verified means a terminal
// success result object with a finite non-negative cost; anything else leaves the
// reservation unknown, never settled.
import { readFileSync } from 'node:fs';

try {
  const r = JSON.parse(readFileSync(process.argv[2], 'utf8'));
  const ok = r && typeof r === 'object' && r.type === 'result' && r.is_error === false
    && typeof r.total_cost_usd === 'number' && Number.isFinite(r.total_cost_usd) && r.total_cost_usd >= 0;
  if (ok) console.log(r.total_cost_usd.toFixed(6));
} catch { /* unparseable output: cost stays unverified */ }
