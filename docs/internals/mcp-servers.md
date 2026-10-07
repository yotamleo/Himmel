# MCP server and client inventory

Repository snapshot: 2026-10-07, HIMMEL-4819 slice 1. The migration target is
protocol revision **2025-11-25** and the split TypeScript SDK at exact stable
**2.3.1**. The parent ticket's alpha warning is stale: the npm registry lists
stable 2.0.0 through 2.3.1. Protocol revision and SDK major are independent;
v1 can already negotiate 2025-11-25.

The inventory covers tracked manifests, npm and Bun lockfiles, SDK imports,
vendored bundles, MCP launch configurations and the policy registry. Runtime
user configuration and upstream server source are not shipped here: **unknown**
is not a compliance claim. Policy counts below are *enumerated policy tools*,
not a live `tools/list`; aliases share one implementation. The first four
production implementations have source-derived counts instead.

| Server / client | Owner and repository evidence | SDK version | Transport | Tool count | Migration risk / disposition |
|---|---|---|---|---|---|
| `luna-correlate` server | `marketplace/plugins/luna-correlate/{package.json,bun.lock,server.ts,.mcp.json}` | Before: monolith 1.32.1; pilot target: split server **2.3.1** | stdio, Bun | **5** | Low: low-level handlers retain JSON schemas, custom validation and text/error output. Exact pin; regression initializes, lists tools, calls offline `series.load`, rejects bad arguments/unknown tools and checks EOF. |
| `jira` server | `scripts/jira/{package.json,package-lock.json,src/mcp.ts}`; CLI `mcp` verb | Manifest `^1.32.1`, lock **1.32.1** | stdio, Node | **13** | Medium: Jira writes, attachments, transition and roadmap dispatch. Deferred to **HIMMEL-4864**; preserve all handlers and typed errors. |
| `telegram` server | `marketplace/plugins/telegram-himmel/{package.json,bun.lock,server.ts,.mcp.json}` | Monolith **1.32.1** | stdio, Bun; Telegram network I/O is not MCP transport | **4** | High: notifications, bot/poller ownership, attachment paths and shutdown. Deferred to **HIMMEL-4865**; use isolated bot/network fixtures, not a live bot. |
| Obsidian Local REST API embedded server | `templates/luna-second-brain/.obsidian/plugins/obsidian-local-rest-api/{main.js,manifest.json}`; plugin **5.4.0** | Already split `@modelcontextprotocol/server`, `core`, `node` bundle; exact SDK release **not recorded** | Streamable HTTP (`NodeStreamableHTTPServerTransport`), sessionful/sessionless | **17** base + **2** signed-URL tools + **1** event-listener tool when enabled; extensions can add more | Medium: already v2 API (`McpServer.registerTool`, Standard Schema adapter). Re-vendor upstream, do not codemod compiled bundle; unknown exact pin needs upstream evidence. |
| `fake-mcp` test server | `scripts/testing/fixtures/fake-mcp-server.mjs` | **None**, handwritten JSON-RPC | newline-delimited stdio, Node | **1** (`fake_echo`) | No dependency migration. Credential-free fixture echoes requested protocol; default 2025-06-18 is not a supported-version negotiation implementation. |
| stdio regression test client | `marketplace/plugins/luna-correlate/tests/stdio.test.ts` | **None**, handwritten JSON-RPC test client | stdio subprocess | Calls the pilot's 5-tool list | No SDK object crossing. Uses literal 2025-11-25 initialize and offline fixtures. |
| Claude Code / Codex harness clients | `scripts/mcp/build-mcp-profiles.mjs`, `scripts/lanes/plugin-profiles.json`, `scripts/codex/` | External binaries; no in-repo SDK client imports | Configured stdio / HTTP | Server-dependent | Generated config is not an SDK client implementation. Upgrade client binaries separately; do not infer SDK from CLI version. |
| `qmd` / `plugin_qmd_qmd` | `marketplace/plugins/qmd/.mcp.json`, policy registry | External service, exact SDK **unknown** | HTTP `http://localhost:8181/mcp` | **4** policy entries | External package upgrade, not a repo codemod. Plugin and user registrations alias the same service. |
| `shadcn` / `plugin_shadcn-mcp_shadcn` | `marketplace/plugins/shadcn-mcp/.mcp.json` | External `shadcn@4.21.0`; SDK **unknown** | stdio (`npx … mcp`) | **7** policy entries | Pin is application version, not SDK version; upstream dependency audit needed. |
| `playwright` / `plugin_playwright_playwright` | `scripts/lanes/plugin-profiles.json` `mcpCatalog`; profile generator; policy registry | External `@playwright/mcp@0.0.83` in leg-e2e; generator fallback uses `@latest`; SDK **unknown** | stdio (`npx`) | **25** policy entries | Browser side effects; audit upstream and resolve mutable fallback separately. |
| `chrome-devtools` | `scripts/mcp/build-mcp-profiles.mjs`, `.claude/mcp-profiles/profiles.json` | External `chrome-devtools-mcp@latest`; SDK **unknown** | stdio (`npx`) | **Unknown**, not enumerated | Mutable upstream/browser tooling; no source codemod here. |
| `context7` / remote / plugin / `claude_ai_Context7` | Profile generator, profile definitions, policy registry | Hosted or external plugin; SDK **unknown** | Remote HTTP `https://mcp.context7.com/mcp` for generator; connector/plugin transport not recorded | **2** policy entries each | Hosted service cannot be migrated by this repo; query text egress remains governed by policy. |
| `obsidian-vault` | Profile definitions, policy registry | External `mcp-obsidian`, Python SDK exact version **unknown** | Local server; launch/transport resolved from user configuration | **15** policy entries | REST API compatibility and vault-write safety; separate from embedded Obsidian server above. |
| `plugin_obsidian-second-brain_vault` | Lane plugin profiles and policy registry | External plugin SDK **unknown**; source not vendored here | Not recorded in tracked launch config | **12** policy entries | Plugin-owned migration; strict profiles may strip its server while keeping skills. |
| `graphify` | Installer/upstream registration, policy registry | External Python graphify/MCP dependency; exact SDK **unknown** | Local graph server; user-owned launch config | **10** policy entries | Python service is outside TS codemod scope; preserve graph/data routing. |
| `onepassword` | `.claude/mcp-profiles/profiles.json` | User-scope external SDK **unknown** | Resolved from user configuration | **Unknown**, not enumerated | Secrets integration; operator-owned upgrade, not a repo migration. |
| `tokensave` | Policy registry and fleet cleanup references | External SDK **unknown** | Local service; transport not pinned here | **6** policy entries | External code-index server, no implementation in tracked source. |
| `himmelprobe` | Policy registry | **Unknown**; no tracked implementation found | Not recorded | **1** policy entry | Registry entry alone is not evidence of an installed server. |
| `claude_ai_Atlassian_MCP` / `plugin_atlassian_atlassian` | Policy registry | Hosted / external SDK **unknown** | Connector/plugin transport not recorded | **7** connector policy entries; plugin unenumerated | Prefer Jira CLI; hosted/backend policy is independent of SDK migration. |
| `claude_ai_Claude_Docs` | Policy registry | Hosted SDK **unknown** | Connector transport not recorded | **8** policy entries | Provider-owned; no local codemod. |
| `claude_ai_Gmail` | Policy registry | Hosted SDK **unknown** | Connector transport not recorded | **30** policy entries | Provider-owned; sending/deleting policy unchanged. |
| `claude_ai_Google_Calendar` | Policy registry | Hosted SDK **unknown** | Connector transport not recorded | **9** policy entries | Provider-owned; no local codemod. |
| `claude_ai_Google_Drive` | Policy registry | Hosted SDK **unknown** | Connector transport not recorded | **11** policy entries | Provider-owned; sharing/deleting policy unchanged. |
| `claude-in-chrome` | Policy registry | External SDK **unknown** | Browser integration; transport not pinned here | **11** policy entries | Operator browser and arbitrary-JS surface; no local source migration. |
| `plugin_builder-visual_agent-native-dispatch` | Policy registry | Hosted Builder.io SDK **unknown** | Hosted transport not recorded | **Unknown**, unenumerated | Provider-owned; egress guard remains authoritative. |
| Planned `himmel-bus` server | HIMMEL-4818 design / **HIMMEL-4827**; not implemented at this snapshot | Planned split server/client **2.3.1** | Planned stdio | **2** planned (`send`, `read`) | New-on-v2, not a remaining v1 migration. No edits in this slice. |

## Pilot migration

The official `@modelcontextprotocol/codemod@2.3.1 v1-to-v2 .` is run at the
pilot package root, first with `--dry-run`. It replaces the server/stdio
imports and schema-constant handler registration with literal method names
(`tools/list`, `tools/call`). Keep the low-level `Server`: replacing it with
high-level `McpServer.registerTool` would also change schema validation and
unknown-tool error dispatch, contrary to this pilot's behavior-preservation
contract. The five JSON schemas and business logic remain unchanged.

The codemod emits a caret dependency; tighten it to exact **2.3.1**, regenerate
`bun.lock`, and remove the v1 monolith only after no imports remain. The plugin
manifest advances from **0.2.6** through **0.2.7** to **0.2.8** (independent
schema-baseline review fix); the existing wire server identity
is intentionally unchanged. Tests use no client SDK and never pass objects
between SDK majors. Only `factors.cache` retains the existing public-network
path; the new stdio test calls no network tool.

## Staged completion

- **HIMMEL-4864**: Jira CLI server migration.
- **HIMMEL-4865**: telegram-himmel server migration.
- **HIMMEL-4866**: doctor/CI lint against new v1 dependencies/imports after
  remaining first-party migrations, with explicit vendored/external policy.

These follow-ups are linked by comment from **HIMMEL-4819**. Slice 1 does not
complete the parent ticket. Exact unknown external/bundled versions are not
silently counted as compliant.

## Reproduce the inventory

From the repository root, inspect `git grep -n @modelcontextprotocol/` and
`git ls-files '*package.json' '*bun.lock' '*package-lock.json' '*mcp*'`.
Read the embedded bundle's `node_modules/@modelcontextprotocol/…` comments,
`this.tool` registrations, and HTTP transport construction; do not execute it
outside Obsidian. Cross-check `.mcp.json`, `.claude/mcp-profiles/profiles.json`,
`scripts/mcp/build-mcp-profiles.mjs`, `scripts/lanes/plugin-profiles.json` and
`scripts/guardrails/mcp-policy.json`. There are no tracked production TS SDK
client imports at this snapshot.

Run the pilot through `bash scripts/plugin-test.sh luna-correlate`, which
bootstraps dependencies before `bun test`. Record actual RED/GREEN evidence in
the PR/handover; this inventory is not a claim that an unrun test passed.

References: [official v1-to-v2 migration guide](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/migration/upgrade-to-v2.md),
[server package registry](https://www.npmjs.com/package/@modelcontextprotocol/server),
[MCP specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25).
