---
name: vault-lint
description: Use when the operator wants to lint a vault, run a vault health check, perform a wiki audit, or find orphans and broken wikilinks. Filesystem-only, report-only (no auto-fix in v1). Runs a single deterministic Python pass that converges on large PARA vaults where agent-crawl lint does not. Vault-agnostic — works on any Obsidian vault, not just luna.
---

Run the vault-lint engine against a vault root. Deterministic, report-only, filesystem-only.

1. **Resolve the vault root.** Use the explicit `$ARGUMENTS` path if provided, else `cwd`. Abort
   if the path does not exist or has no `*.md` files.

2. **Run the engine:**
   ```bash
   python "marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py" "<vault>"
   ```
   The engine loads `<vault>/.vault-lint.json` if present, otherwise uses its shipped defaults.
   It writes the report to the configured `report_path` (default `<vault>/_lint-report-{date}.md`,
   date-substituted) and prints a JSON summary to stdout.

3. **Read the printed JSON summary.** Surface to the operator:
   ```
   N real findings → <report_path>
   ```
   Do NOT re-walk the vault from Claude — the engine is the single deterministic pass. Repeating
   the crawl in Claude produces non-deterministic, over-reported results (the over-report collapse —
   hundreds of raw issues down to a handful of real ones — is baked into the engine's resolver and
   by-design exemptions; re-crawling from scratch loses it).

4. **Filesystem-only:** never call WebFetch, WebSearch, or any MCP tool. In an `egress_locked`
   vault these are blocked by a hook anyway — rely solely on the engine output.

5. **Report-only:** never auto-fix findings in v1. Findings are informational; the operator decides
   what to act on.

---

**Flags:** `--json` prints full per-finding detail (useful for piping); `--config PATH` overrides
the profile location; `--no-report` suppresses the written report (stdout-only run).

**Vendor-drift guard:** `marketplace/plugins/obsidian-triage/skills/vault-lint/check-vendor-drift.sh`
(lean-invoke — run manually or via `/himmel-update`; not a pre-commit hook) flags when the upstream
`claude-obsidian:wiki-lint` this skill generalizes has changed, so capability gaps surface for review.
