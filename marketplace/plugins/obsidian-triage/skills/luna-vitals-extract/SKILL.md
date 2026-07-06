---
name: luna-vitals-extract
description: Use when backfilling salus health series for one vault time-bucket (HIMMEL-355). Extracts (date, metric, value) tuples for the tracked vitals from the bucket's notes — deterministic structured entries via the luna-vitals CLI, plus an LLM pass over prose/timeline — and writes ONE per-bucket review artifact for operator review. One bucket per armed slot (single-writer). Never writes 50-Vitals/ directly.
---

Extract health-series rows for ONE time-bucket into a review artifact. Inputs: a date range
`<START>..<END>` and the artifact output path `<ARTIFACT>`. Tracked metrics: migraine, skin_flare,
sleep_hours, hrv_ms, rhr_bpm.

1. **Locate** health-relevant notes in the bucket: use qmd over collection `salus` (and 20-Timeline/,
   daily notes) filtered to the date range. Collect the file paths.
2. **Deterministic pass:** for each structured file, run
   `bun run <repo>/scripts/luna-vitals/cli.ts parse <file> --note-date <date-if-daily> --out <tmp/det-N.json>`.
3. **LLM pass:** read the prose/timeline files. Extract ONLY explicit dated values (e.g. "14 Jun 2024 —
   migraine, bad day" → migraine on 2024-06-14; map qualitative→the metric's scale using the registry
   `50-Vitals/_series.md`). Do NOT infer from relative statements ("worse lately"). Record each as a row
   `{metric,date,value,source}` where source = "<file>: <quote>". Write these as one artifact
   `{bucket:"<START>..<END>", rows:[...], conflicts:[]}` to `<tmp/llm.json>` (same schema as the CLI).
4. **Merge** this bucket's artifacts, routing the deterministic-parse artifacts and the LLM artifact
   into their respective pools so deterministic values win on overlap:
   `bun run <repo>/scripts/luna-vitals/cli.ts merge --det <tmp/det-*.json> --llm <tmp/llm.json> --out <ARTIFACT>`.
5. **Report** the row count per metric and any conflicts. STOP — do not write 50-Vitals/. The operator
   reviews `<ARTIFACT>`, then the single-writer merge + `write` step lands it.
