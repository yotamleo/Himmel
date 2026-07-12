# himmel docs

Map of the `docs/` tree. New here? Start at **[getting-started.md](getting-started.md)**.

## Start here

- [getting-started.md](getting-started.md) — clone to your first PR-gated loop in ~15 minutes.
- [daily-loop.md](daily-loop.md) — one full loop (worktree → PR → merge → clean → handover), with every hook and gate explained where it fires.

## Setup

- [setup/new-machine.md](setup/new-machine.md) — fresh-machine setup: required tools + per-platform (Linux / macOS / Windows Git Bash) install.
- [setup/use-on-your-project.md](setup/use-on-your-project.md) — adopt the portable core (hooks + worktree workflow) in an existing repo.
- [setup/updating.md](setup/updating.md) — update the harness (`/himmel-update`) and upgrade luna vaults (`/luna-upgrade`); also points to the symmetric `scripts/uninstall.sh` teardown.
- [setup/global-claude-md.md](setup/global-claude-md.md) — Claude Code global config (`~/.claude/`).
- [setup/vms.md](setup/vms.md) — VM-based dev machines for cross-platform testing.
- [setup/claude-squad.md](setup/claude-squad.md) — optional `claude-squad` (cs) install.
- [setup/rtk-md.md](setup/rtk-md.md) — the rtk token-cost proxy.

## Daily use & reference

- [commands-catalog.md](commands-catalog.md) — every project-local slash command.
- [tooling-catalog.md](tooling-catalog.md) — every tool, script, and plugin in active use.
- [jarvis-subsystems.md](jarvis-subsystems.md) — adopter usage map of the optional agentic-OS subsystems (GLM lane, quota-gauge, escalation channel, statusline, clipper pipeline).
- [operator-conventions.md](operator-conventions.md) — durable operator working-habits.
- [contributing.md](contributing.md) — the contribution workflow.

## How enforcement works (internals)

- [internals/enforcement.md](internals/enforcement.md) — every hook, the pre-commit/pre-push gates, the guardrail matrix, and Claude-invocation billing.
- [internals/handover-system.md](internals/handover-system.md) — the full cross-session handover system + user-slug resolution.
- [internals/jira-plugin.md](internals/jira-plugin.md) — the local Jira CLI ↔ Atlassian MCP op mapping.
- [internals/stuck-playbook.md](internals/stuck-playbook.md) — guardrail-recovery escape hatches.
- [handover/overnight-mode.md](handover/overnight-mode.md) — the unattended overnight pipeline (11 phases, attestation, block criteria).

## Integrations

- [jira-projects.md](jira-projects.md) — Jira project setup + conventions.
- [telegram-bridge.md](telegram-bridge.md) · [internals/telegram-bridge.md](internals/telegram-bridge.md) — the Telegram bridge.
- [hermes-runbook.md](hermes-runbook.md) — the hermes junior-tier model lane.
- [luna/README.md](luna/README.md) — the luna companion second-brain vault guides (incl. [end-session-wiki](luna/end-session-wiki.md), [emergence-crystallization](luna/emergence-crystallization.md), [pr-lane-guard](luna/pr-lane-guard.md)).

## Process, security & audits

- [security-review.md](security-review.md) — the security-review playbook.
- [security/npm-policy.md](security/npm-policy.md) · [security/python-policy.md](security/python-policy.md) — supply-chain hygiene policy.
- [tool-adoption/rubric.md](tool-adoption/rubric.md) — the decision method every community-tool eval runs through.
- [tool-adoption/registry.md](tool-adoption/registry.md) — every evaluated tool, recorded.
- [tool-adoption/telemetry.md](tool-adoption/telemetry.md) — adoption-outcome telemetry for the registry.
- [license-audit.md](license-audit.md) · [skills-taxonomy-audit.md](skills-taxonomy-audit.md) — audits.

---

Working as an LLM in this repo? The machine-readable map is [`../llms.txt`](../llms.txt).
