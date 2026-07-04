# GLM cap guard — premise captures (Task 0)

Captured 2026-07-03 ~22:15 UTC+2 by the main session (live ZAI key against the
real endpoints; this is a premise-capture run, not reproducible in a worker
session — the deny-hook blocks network CLIs there).

## Verdicts

- **0a envelope (`envelope-0a.txt`):** Anthropic-shaped envelope (`{"type":"error","error":{...}}`)
  with the z.ai numeric code + bracketed message embedded (`code:"1211"`,
  `[1211][Unknown Model...][<id>]`). Pass-through of message text CONFIRMED —
  the proxy surfaces z.ai's message strings verbatim, so the cap sentinels can
  key on message substrings.
- **0b CLI tail (`cli-tail-0b.txt`):** the `claude` CLI echoes the 429 body
  verbatim in its output tail (`...[1316][Usage limit reached for the past 5
  hours. Insufficient balance for extra usage]...`). Sentinel premise GO —
  Task 1's `detectGlmCap` fires on this tail.
- **0c monitor schema (`monitor-0c.json`, `monitor-0c.captured-at`):**
  - `percentage` polarity IS used — reads 13 percent after a fleet day (used,
    not remaining).
  - The 5-hour window is the `limits[]` entry with `nextResetTime` about 3.7h
    out from capture (the `unit:3` TOKENS_LIMIT).
  - A SECOND TOKENS_LIMIT entry (`unit:6`, weekly, +6d) coexists, so pickers
    MUST disambiguate by the within-5h rule — array order alone is ambiguous.
  - `level` = `"pro"`.

## GO/NO-GO

envelope=pass-through, cli-echo=yes, monitor=confirmed. **GO** — the 1316
message text reaches the CLI tail AND `percentage`=used is confirmed. The
downstream tasks build on these observed shapes.
