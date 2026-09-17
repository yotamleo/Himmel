---
type: tool_used
tool: mcp__plugin_qmd_qmd__query
input_match: '^(?!.*"collections":\s*\[\s*"himmel"\s*\]).*$'
min: 0
max: 0
---

Rejects any `query` call scoped outside `["himmel"]` — `scoped-query.md`'s
`min: 1` only proves one call was in scope and misses the others (HIMMEL-2938).
The regex is a whole-input negative match (not a `"collections":` substring
match): it also catches a call that omits the `collections` key entirely,
which the substring form let through since an absent key never contains the
literal text `"collections":` at all (CR round 1 on this PR).
