---
name: qmd
description: Search markdown knowledge bases, notes, and docs with QMD. Use to search notes or look up information.
license: MIT
compatibility: Requires qmd CLI or MCP server. Install via `npm install -g @tobilu/qmd`.
metadata:
  author: tobi
  version: "2.0.0"
allowed-tools: Bash(qmd:*), mcp__qmd__*, mcp__plugin_qmd_qmd__*
---

# QMD - Quick Markdown Search

Local search engine for markdown content.

## Status

!`qmd status 2>/dev/null || echo "Not installed: npm install -g @tobilu/qmd"`

## MCP: `query`

```json
{
  "searches": [
    { "type": "lex", "query": "CAP theorem consistency" },
    { "type": "vec", "query": "tradeoff between consistency and availability" }
  ],
  "collections": ["docs"],
  "limit": 10
}
```

### Query Types

| Type | Method | Input |
|------|--------|-------|
| `lex` | BM25 | Keywords — exact terms, names, code |
| `vec` | Vector | Question — natural language |
| `hyde` | Vector | Answer — hypothetical result (50-100 words) |

### Writing Good Queries

**lex (keyword)**
- 2-5 terms, no filler words
- Exact phrase: `"connection pool"` (quoted)
- Exclude terms: `performance -sports` (minus prefix)
- Code identifiers work: `handleError async`

**vec (semantic)**
- Full natural language question
- Be specific: `"how does the rate limiter handle burst traffic"`
- Include context: `"in the payment service, how are refunds processed"`

**hyde (hypothetical document)**
- Write 50-100 words of what the *answer* looks like
- Use the vocabulary you expect in the result

**expand (auto-expand)**
- Use a single-line query (implicit) or `expand: question` on its own line
- Lets the local LLM generate lex/vec/hyde variations
- Do not mix `expand:` with other typed lines — it's either a standalone expand query or a full query document

### Intent (Disambiguation)

When a query term is ambiguous, add `intent` to steer results:

```json
{
  "searches": [
    { "type": "lex", "query": "performance" }
  ],
  "intent": "web page load times and Core Web Vitals"
}
```

Intent affects expansion, reranking, chunk selection, and snippet extraction. It does not search on its own — it's a steering signal that disambiguates queries like "performance" (web-perf vs team health vs fitness).

### Combining Types

| Goal | Approach |
|------|----------|
| Know exact terms | `lex` only |
| Don't know vocabulary | Use a single-line query (implicit `expand:`) or `vec` |
| Best recall | `lex` + `vec` |
| Complex topic | `lex` + `vec` + `hyde` |
| Ambiguous query | Add `intent` to any combination above |

First query gets 2x weight in fusion — put your best guess first.

### Lex Query Syntax

| Syntax | Meaning | Example |
|--------|---------|---------|
| `term` | Prefix match | `perf` matches "performance" |
| `"phrase"` | Exact phrase | `"rate limiter"` |
| `-term` | Exclude | `performance -sports` |

Note: `-term` only works in lex queries, not vec/hyde.

### Collection Filtering

```json
{ "collections": ["docs"] }              // Single
{ "collections": ["docs", "notes"] }     // Multiple (OR)
```

Omit to search all collections.

### What works here (himmel fork, measured)

Measured on a 38-query golden set with `scripts/eval/qmd-quality/qmd-quality.sh`
(HIMMEL-4184). Re-run it before changing this advice.

1. **Always scope `collections`.** This is the largest lever measured: hybrid
   MRR rose from 0.57 unscoped to 0.83 scoped. Unscoped vector hits are swamped
   by the large `luna` collection (handovers and session logs).
2. **Send `lex` + `vec`, with `lex` first.** Scoped hybrid beats either alone
   (MRR 0.83 vs lex 0.78 vs vec 0.43). Put ticket keys, file names, script and
   flag names in `lex`; they are what BM25 finds and embeddings miss.
3. **Keep a `-flag` out of `vec` and `hyde`.** A `vec` sub-query containing
   `--no-verify` is refused outright. Write `no-verify`, or move the term to
   `lex`.
4. **Leave rerank on (the default) and pass `intent`.** Once scoped, rerank is
   neutral to slightly positive (hit@5 0.92 vs 0.90) at about 1.5 s per query.
   Unscoped, it lowered MRR.

## Other MCP Tools

| Tool | Use |
|------|-----|
| `get` | Retrieve doc by path or `#docid` |
| `multi_get` | Retrieve multiple by glob/list |
| `status` | Collections and health |

## CLI

```bash
qmd query "question"              # Auto-expand + rerank
qmd query $'lex: X\nvec: Y'       # Structured
qmd query $'expand: question'     # Explicit expand
qmd query --json --explain "q"    # Show score traces (RRF + rerank blend)
qmd search "keywords"             # BM25 only (no LLM)
qmd get "#abc123"                 # By docid
qmd multi-get "journals/2026-*.md" -l 40  # Batch pull snippets by glob
qmd multi-get notes/foo.md,notes/bar.md   # Comma-separated list, preserves order
```

## HTTP API

```bash
curl -X POST http://localhost:8181/query \
  -H "Content-Type: application/json" \
  -d '{"searches": [{"type": "lex", "query": "test"}]}'
```

## Setup

```bash
npm install -g @tobilu/qmd
qmd collection add ~/notes --name notes
qmd embed
```
