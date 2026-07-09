# qmd (himmel fork)

`[yotamleo fork]` of `qmd@qmd` (upstream [tobi/qmd](https://github.com/tobi/qmd),
plugin manifest v0.1.0).

## Why this fork

Claude Code eagerly spawns every enabled plugin's MCP server at session start
(no native lazy spawn). Upstream qmd declares a **stdio** server
(`{"command": "qmd", "args": ["mcp"]}`), so **every** session spawns its own
`qmd mcp` process and loads the same read-only search index into RAM again —
the largest per-session MCP footprint on this machine (HIMMEL-592).

## The change

Two deltas vs upstream. The main one: the `qmd` MCP server is declared as a
shared **HTTP** endpoint instead of a per-session stdio process
(`marketplace/plugins/qmd/.mcp.json`):

```json
{ "mcpServers": { "qmd": { "type": "http", "url": "http://localhost:8181/mcp" } } }
```

All sessions now address ONE `qmd mcp --http --daemon` on `localhost:8181`.
The daemon is brought up lazily by the plugin's own SessionStart hook
(`hooks/hooks.json` -> `${CLAUDE_PLUGIN_ROOT}/scripts/ensure-qmd-daemon.sh`),
so the startup path ships INSIDE the plugin and works from ANY session in ANY
repo where the plugin is enabled — not just himmel checkouts. The ensure
script is idempotent (alive-probe short-circuits), bounds the daemon start
with `timeout(1)` so a hung start cannot stall SessionStart, and fails loudly
on a foreign listener holding port 8181. A manual PowerShell twin for
operators lives in the himmel repo at `scripts/qmd/ensure-qmd-daemon.ps1`.

The plugin **name stays `qmd`** and the server **name stays `qmd`**, so the
skill reference (`qmd:qmd`) and the MCP tool prefix
(`mcp__plugin_qmd_qmd__*`) are identical to upstream in NAME — the one
intentional content delta below (the skill's `allowed-tools` line) is the
second fork delta; everything else in the skill tree is verbatim upstream.

The `skills/qmd/` skill is copied from upstream with ONE line changed (the
upstream `release` skill, which is qmd-repo maintenance tooling, is not
vendored): the skill's `allowed-tools` gains `mcp__plugin_qmd_qmd__*` —
upstream allows only `mcp__qmd__*`, which does not match the plugin-scoped
tool prefix the plugin itself produces (pre-existing upstream mismatch;
harmless there, fixed here since we own the copy).

## Freshness & lifecycle

The index is sqlite+WAL, read per query, so a shared daemon serves docs added
by `qmd update` immediately — no restart or watch needed. Stop the daemon with
`qmd mcp stop`. Blast radius: a shared-daemon crash affects all sessions' qmd,
acceptable for a read-only index (a connect failure is loud in `/mcp`, not a
silent empty index).

## Upstream watch

The standalone `qmd` CLI (bun: `bun add -g @tobilu/qmd`) still updates
independently; this fork only pins the plugin **manifest + skill**, which is
low-churn. Re-sync `skills/qmd/` from `tobi/qmd` if the upstream search skill
changes materially.
