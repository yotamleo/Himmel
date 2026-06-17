# marketplace/plugins — vendored + forked plugins

Loads only when working in this subtree. Conventions for authoring and
maintaining the Claude Code plugins shipped from this repo.

## Layout
Each plugin has a `.claude-plugin/` manifest plus the component dirs it
needs (`commands/`, `skills/`, `agents/`, `tools/`). Live plugins:
`handover`, `obsidian-triage`, `pr-review-toolkit-himmel`, `telegram-himmel`,
`himmel-ops`.

## Conventions
- **Plugin specs belong in `<plugin>/README.md`** (luna-docs tier-1,
  HIMMEL-138) — not in `docs/`. Author there (obsidian-triage and
  pr-review-toolkit-himmel already do; handover predates the convention).
- Forks keep the upstream `LICENSE` file and document the fork delta in
  the plugin's `README.md`, so the divergence from upstream is auditable.
- A plugin's skills follow the same authoring rules as any skill — invoke
  the `skill-creator` / `plugin-dev` skills rather than hand-rolling.
- **Test a plugin that declares its own deps via `bash scripts/plugin-test.sh
  <plugin>`**, not raw `bun test` (HIMMEL-366). A fresh worktree only installs
  `scripts/jira/` deps, so raw `bun test` here starts RED ("Cannot find module
  '@modelcontextprotocol/sdk/…'") and masks real regressions; the helper
  `bun install`s first so the baseline is GREEN.

## Reference
- Tooling catalog (what each plugin does):
  [`docs/tooling-catalog.md`](../../docs/tooling-catalog.md).
