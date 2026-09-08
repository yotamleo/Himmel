---
description: Inspect or toggle the two-tier plugin profile (ALWAYS vs ON-DEMAND) — list, lean, full, enable/disable one.
argument-hint: [list [--json]|lean|full|enable <spec>|disable <spec>] [--dry-run]
---

himmel plugins split into two tiers (`docs/setup/settings-template.json`): ALWAYS (installed + enabled on every machine) and ON-DEMAND (installed but left disabled, reachable in one command). `list` shows both tiers with each plugin's live state; `lean` disables every enabled on-demand plugin; `full` enables all of them; `enable <spec>`/`disable <spec>` toggle one (a bare plugin name resolves if unambiguous). `disable` refuses the harness-operational floor (`handover@himmel`, `himmel-ops@himmel`, `qmd@himmel`).

Caveat: an opt-in reconcile (`HIMMEL_RECONCILE_PLUGINS=1`, e.g. via `/himmel-update`) writes the template map verbatim and turns an enabled on-demand plugin back off. To keep one on permanently on this machine, record `"<spec>": true` in `~/.claude/settings.local.json` as himmel reconciliation input; the next opt-in reconcile copies it into `settings.json`. Claude Code does not read that user sibling as a runtime settings layer.

Run:

```bash
bash scripts/machine-setup/plugin-profile.sh $ARGUMENTS
```
