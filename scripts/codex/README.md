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

3. **Sanitizes external-plugin `hooks.json`** as a final phase (HIMMEL-651): a
   few external plugins (warp, hookify, ralph-loop, security-guidance) ship a
   top-level `description` that Codex's strict parser rejects ("unknown field
   description"), skipping those hooks with a boot warning. The installer strips
   it via `sanitize-plugin-hooks.{sh,ps1}` (idempotent; non-fatal). himmel-owned
   plugins never ship that shape.

For plugin enablement it only ever *adds* — it never removes or disables a
plugin, and a re-run on a provisioned machine is a no-op. (The sanitize phase
edits external-plugin cache files in place, removing only the offending
`description` key.)

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

Run the hooks sanitizer standalone (e.g. after a `codex` plugin update re-adds a
`description`) — env override `CODEX_HOME` (default `~/.codex`):

```sh
bash scripts/codex/sanitize-plugin-hooks.sh              # strip in place
bash scripts/codex/sanitize-plugin-hooks.sh --dry-run    # report, change nothing
```

```powershell
pwsh -NoProfile -File scripts\codex\sanitize-plugin-hooks.ps1 -DryRun
```

## Dispatching codex impl workers (lane chokepoint, HIMMEL-741/781)

The `codex-exec` impl lane (`scripts/lanes/lanes.json`) dispatches codex CLI
sandbox workers into git worktrees **only through the chokepoint wrapper**
(structural > instructional — the rules live in code, not prose):

```sh
bash scripts/codex/dispatch-codex-exec.sh --worktree <worktree-path> [codex exec args...]
```

The wrapper enforces the three invariants from the HIMMEL-741 diagnosis:

1. **ACL preflight, fail-closed.** It runs
   `normalize-worktree-acl.sh <worktree>` before the codex CLI is invoked
   (after the argument checks) and aborts the dispatch if
   that fails. Aged worktrees under `.claude\worktrees\` develop
   subdirectories that missed the sandbox SID inheritance; the sandbox then
   fails with access denials that look like a broken `codex exec`. The
   preflight is a no-op on non-Windows platforms.
2. **Model pinned to `gpt-5.5`.** Codex-variant model names (e.g.
   `gpt-5.5-codex`) return HTTP 400 under ChatGPT-plan auth; the plain name
   routes correctly. A caller-named `--model` overrides the pin with a WARN.
3. **`--background` refused.** Companion background jobs die silently
   (upstream bug); use the default wait behavior and pair long runs with
   `scripts/codex/companion-liveness.sh`.
4. **Workspace-redirect and sandbox-widening flags refused.** `-C`/`--cd`,
   `--add-dir`, `-s`/`--sandbox danger-full-access`, the approval-bypass
   flags, and the config/profile overrides (`-c`/`--config`,
   `-p`/`--profile` — either can rewrite `sandbox_permissions`) would point
   codex at a directory the ACL preflight never touched or drop the sandbox
   entirely — the wrapper rejects them all.

Tests: `scripts/codex/test-dispatch-codex-exec.sh` (hermetic; stubs the codex
CLI via `CODEX_BIN` and the preflight via `CODEX_ACL_NORMALIZE`).

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
