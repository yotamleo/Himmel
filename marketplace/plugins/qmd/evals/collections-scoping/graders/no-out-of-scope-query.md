---
type: tool_used
tool: mcp__plugin_qmd_qmd__query
input_match: '"collections":\s*(?!\[\s*"himmel"\s*\])\['
min: 0
max: 0
---

Rejects any `query` call scoped outside `["himmel"]` — `scoped-query.md`'s
`min: 1` only proves one call was in scope and misses the others (HIMMEL-2938).
