# end-session-wiki fixture transcripts (HIMMEL-576)

Hermetic JSONL fixtures for the husk-skip gate + crystallization tests.

| file | content | HAS_CONTENT | husk? |
|------|---------|-------------|-------|
| `contentless.jsonl`       | user + last-prompt only, no assistant | 0 | **husk** |
| `empty-ts.jsonl`          | contentless AND no `.timestamp`       | 0 | **husk** (flood seed: fallback ts) |
| `thinking-tool-only.jsonl`| assistant thinking+tool_use, no text  | 1 | not husk (crystallizable) |
| `normal.jsonl`            | assistant text + command              | 1 | not husk |

Known husk count: **2 of 4**. A backfill over this corpus must write **0** husk notes.
