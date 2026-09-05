---
name: vault-lint
description: Use to lint a vault, run a health check, or find orphans and broken wikilinks. Report-only, any Obsidian vault.
---

Run the vault-lint engine against a vault root. Deterministic, report-only, filesystem-only.

1. **Resolve the vault root.** Use the explicit `$ARGUMENTS` path if provided, else `cwd`. Abort
   if the path does not exist or has no `*.md` files.

2. **Run the engine as a single literal command, absolute path, no `cd`.** The
   cadence that runs this skill unattended fires with `cwd` set to the vault, not
   a himmel checkout — a repo-relative path forces a `cd <repo> && python …`
   paraphrase, which is a compound shape the cadence's engine-allow hook never
   grants (HIMMEL-2046). Resolve the himmel repo root from the `$HIMMEL_REPO`
   environment variable (auto-set on every adopted machine, HIMMEL-453/123) and
   substitute its **literal value** into the command text — do not write
   `$HIMMEL_REPO` or `${CLAUDE_PLUGIN_ROOT}` in the actual invocation: a `$`
   token in the engine path is refused outright, and `CLAUDE_PLUGIN_ROOT`
   resolves to the plugin's installed *cache* copy, not this repo, which the
   hook does not trust either. If `$HIMMEL_REPO` is unset, ask the operator for
   the himmel repo path (interactive) or abort the leg (unattended) rather than
   guessing:
   ```bash
   python "<himmel-repo-root>/marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py" "<vault>"
   ```
   e.g. `python "C:/Users/op/himmel/marketplace/plugins/obsidian-triage/skills/vault-lint/vault_lint.py" "<vault>"`.
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
