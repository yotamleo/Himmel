# shadcn-mcp

himmel-owned wrapper plugin (HIMMEL-4012) that exposes the official shadcn/ui
registry MCP server to the `design` profile. Upstream ships no Claude plugin,
only the `shadcn` npm CLI (`npx shadcn mcp`, docs: https://ui.shadcn.com/docs/mcp,
repo https://github.com/shadcn-ui/ui, MIT).

- No API key. The server reads and writes a project's `components.json`
  registry only when asked.
- `npx` downloads the package from npm on first use.
- The version pin lives in `.mcp.json` (`shadcn@4.21.0`); bump it by hand in a
  PR (no drift row: the npm tag shape is not tracked by `check-plugin-drift.sh`).
