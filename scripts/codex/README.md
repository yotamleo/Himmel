# `scripts/codex/` — provision himmel under the Codex CLI (HIMMEL-597)

User-global install for the **Codex** side of himmel, the twin of the hermes
profile installer. The split:

| Side | Installer | Manages |
|------|-----------|---------|
| hermes (CR/model orchestrator) | `scripts/hermes/install-himmel-profile.{sh,ps1}` | the `himmel_agent` hermes profile |
| **codex CLI (harness/plugins)** | `scripts/codex/install-himmel-codex.{sh,ps1}` | himmel plugin enablement in `~/.codex/config.toml` |

`~/.codex/config.toml` is user-global and not repo-tracked, so — like the hermes
profile and like the Claude `~/.claude/settings.json` wiring in `setup.sh` — it
needs an installer rather than a hand edit. This is that installer.

## What it does

Drives the `codex` CLI (`codex plugin marketplace add` / `codex plugin add`) —
it **never hand-edits `config.toml`**, so Codex owns every config write (plugin
trust hashes, `[mcp_servers.*]` secrets, `\\?\` long-path marketplace sources,
line endings). It is **idempotent** and **non-destructive**:

1. Registers the `himmel` marketplace (`<repo>/marketplace`) if not already
   registered.
2. Enables the himmel plugin set if not already `installed, enabled`. Default
   set (all `@himmel`): `himmel-ops handover obsidian-triage telegram-himmel`.
   `himmel-ops` is the one that delivers the minerva / stuck-playbook / vm /
   himmel-doctor / himmel-update skills + the himmel-ops hooks to Codex
   (the HIMMEL-597 target).

It only ever *adds*; it never removes or disables a plugin, and a re-run on a
provisioned machine is a no-op.

## Usage

```sh
bash scripts/codex/install-himmel-codex.sh              # marketplace + default plugin set
bash scripts/codex/install-himmel-codex.sh --all        # also luna-correlate + pr-review-toolkit-himmel
bash scripts/codex/install-himmel-codex.sh --plugins=himmel-ops,handover
bash scripts/codex/install-himmel-codex.sh --dry-run    # report intended changes, change nothing
```

```powershell
pwsh -NoProfile -File scripts\codex\install-himmel-codex.ps1 -DryRun
pwsh -NoProfile -File scripts\codex\install-himmel-codex.ps1 -All
```

Env override: `CODEX_BIN` (path to the `codex` CLI). After a change, restart
Codex so the plugins load; new project hooks are trust-hashed on first use.

## Skill loading caveat

Enabling `himmel-ops` makes its **hooks** fire under Codex (e.g.
`inject-minerva-critic` via `${CLAUDE_PLUGIN_ROOT}` — fail-open, exit-0-only).
Whether an enabled plugin's **skills** auto-load under Codex vs only via
project-local `.agents/skills/<name>/` wrappers is delivery-dependent; the
**verified** skill-discovery path is `.agents/skills/` (HIMMEL-533). Guaranteed
wrappers for the minerva/stuck-playbook/vm cluster are tracked in
HIMMEL-604/607. See `docs/internals/harness-compat.md` §4.

## Scope

This installer is run-on-demand (like the hermes profile installer), separate
from the Claude `setup.sh` `[N/10]` flow. Wiring it into the broader setup /
`/himmel-update` flow is **HIMMEL-605** ("user-scope guardrail wiring for Codex").

## Tests

- `scripts/codex/test-install-himmel-codex.sh` — hermetic; stubs the `codex` CLI
  via `CODEX_BIN`, asserts marketplace-register-when-absent, per-plugin enable,
  idempotency, `--dry-run`, missing-CLI exit, non-destructiveness, `--plugins`.
  Auto-discovered by `scripts/ci/run-shell-tests.sh`.
- `scripts/codex/test-install-himmel-codex.ps1` — the Windows twin.

> Not to be confused with the project-local Codex **guardrail** wiring in the
> repo's `.codex/` dir (hooks adapter, HIMMEL-427/565). That fires guardrails
> *under* Codex; this provisions the user-global plugin set.
