---
allowed-tools: Bash, Read, Skill
description: Content-preserving upgrade of a luna-second-brain vault to the current himmel template. --check just reports.
argument-hint: [--check] [--vault <path>] [--template-dir <path>]
---

# /luna-upgrade — slash-command wrapper (HIMMEL-389)

Invoke the `obsidian-triage:luna-upgrade` skill via the `Skill` tool with `$ARGUMENTS` as the literal `args` parameter — do NOT inline or paraphrase the runbook body here, the skill is the single source of truth.

Execute exactly this tool call (substituting `$ARGUMENTS` literally — Claude Code's slash-command preprocessor replaces it with whatever the operator typed after `/luna-upgrade`):

```
Skill { skill: "obsidian-triage:luna-upgrade", args: "$ARGUMENTS" }
```

This wrapper exists so the operator can keep typing `/luna-upgrade` at the user prompt without learning the `/<plugin>:<skill>` form, mirroring `/luna-ingest`. Keep it a thin wrapper — never duplicate the runbook body.

If the `Skill` tool refuses the `obsidian-triage:luna-upgrade` invocation ("skill not found" or similar): the skill is unavailable, but the engine it wraps is not — fall back to it directly instead of failing (HIMMEL-1153; the lean plugin floor, HIMMEL-1032, disables `obsidian-triage@himmel` by policy on some machines, which trips this same "unavailable" path even though the plugin is vendored+installed).

**Diagnose before reporting** — distinguish disabled-by-policy from a genuinely-unconfigured state. `marketplace/plugins/obsidian-triage/` is tracked in git, so it existing on disk is true in every himmel checkout and proves nothing about whether the plugin is installed/enabled — only the `enabledPlugins` config does:
- Check `.claude/settings.local.json` first, then `~/.claude/settings.json`, for an `"obsidian-triage@himmel"` entry — local overrides global when both are present.
- Effective value `false` → **disabled by policy** (e.g. the lean plugin floor, HIMMEL-1032). Remedy: flip it to `true` in whichever file carries the `false` (prefer `.claude/settings.local.json`).
- No entry in either file → **enabled state unknown/defaulted** — say so honestly, do NOT confidently claim "not installed". Give both remedies: add `"obsidian-triage@himmel": true` to `.claude/settings.local.json`, or `/plugin install obsidian-triage` from the himmel marketplace if it was never registered at all.

**Then run the fallback regardless** — `templates/luna-second-brain/scripts/upgrade.sh` is the plugin-independent engine the skill wraps. Resolve the himmel checkout, translate `$ARGUMENTS`' `--vault <path>` to the engine's `--vault-dir <path>`. Resolve `--template-dir` too: if `$ARGUMENTS` supplies one, use it verbatim; otherwise default to `$HIMMEL_DIR/templates/luna-second-brain` — do NOT hardcode the default into the commands below and silently drop an operator-supplied override.

- **`--check` in `$ARGUMENTS`:** single pass — run `--check` and surface the one-line result verbatim; the engine makes no changes, so there is nothing to gate.
- **Otherwise (apply path):** mirror the skill's own dry-run → confirm → apply contract — do NOT run straight to `--yes`. A non-interactive `Bash` call hits EOF on the engine's confirm prompt, silently answers "no", and it exits **0** having changed nothing (prints `aborted — no changes made.`); trusting the exit code alone would misreport that as success.
  1. Run `bash "$HIMMEL_DIR/templates/luna-second-brain/scripts/upgrade.sh" --template-dir "<resolved template-dir>" --vault-dir "<vault>" --dry-run` and show the operator the printed plan.
  2. Ask the operator to confirm via AskUserQuestion (mirrors the skill's Step 4). If they decline, STOP — make no changes.
  3. On confirmation, re-run the identical command with `--yes` instead of `--dry-run`.
  4. Read the engine's own stdout, not just its exit code — if it printed `aborted — no changes made.`, that is **not an apply** regardless of the (0) exit; report that nothing changed, don't claim success.

Prefix whichever report you give with the Step-A diagnosis (disabled-by-policy vs unknown/unconfigured) so the operator gets the honest remedy either way. If the himmel checkout itself can't be resolved, fail loudly instead of guessing a path — do NOT inline the skill's runbook logic beyond this mechanical fallback.
