# jira-cli

The himmel Jira CLI. Run from the repo root as
`node scripts/jira/dist/index.js <op>`. ESM, arg-parsing via `commander`,
one file per op in `src/commands/`. Prefer this over the Atlassian MCP
server (cheaper per call, dogfoods shipped code).

## Build & test

```bash
cd scripts/jira
npm install
npm run build   # tsc → dist/ (gitignored)
npm test        # vitest
```

`JIRA_PROJECT_KEY` is required at runtime (no `HIMMEL` fallback). The CLI
auto-loads the repo-root `.env`.

## Verbs

`get`, `create`, `list`, `transition`, `transitions`, `comment`, `attach`,
`edit`, `projects`, `project-create` (plus `move`, `link`). Run
`node scripts/jira/dist/index.js --help` for the full option set.

## MCP server (HIMMEL-159)

`jira mcp` boots a [Model Context Protocol](https://modelcontextprotocol.io)
server on stdio that exposes the ten verbs above as MCP tools. Each tool's
input schema mirrors the corresponding CLI option/argument semantics and
routes to the same underlying Jira REST client — so the MCP and CLI surfaces
behave identically.

Register it with gemini-cli (replace `<himmel>` with the absolute path to
this repo):

```bash
gemini mcp add jira -- node <himmel>/scripts/jira/dist/index.js mcp
```

The tools require the same `JIRA_*` environment the CLI uses; the server
inherits them from the launching process / repo-root `.env`.
