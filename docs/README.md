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
- [setup/rtk-md.md](setup/rtk-md.md) — the rtk token-cost proxy.

## Daily use & reference

- [commands-catalog.md](commands-catalog.md) — every project-local slash command.
- [tooling-catalog.md](tooling-catalog.md) — every tool, script, and plugin in active use.
- [jarvis-subsystems.md](jarvis-subsystems.md) — adopter usage map of the optional agentic-OS subsystems (GLM lane, quota-gauge, escalation channel, statusline, clipper pipeline).
- [operator-conventions.md](operator-conventions.md) — durable operator working-habits.
- [contributing.md](contributing.md) — the contribution workflow.
- [glm-offload.md](glm-offload.md) — the GLM-lane offload loop (spawn a GLM worker from the main session, review its diff through the normal CR loop).
- [token-economy.md](token-economy.md) — per-boundary token-optimizer policy — who owns which token cost and where it's paid.

## How enforcement works (internals)

- [internals/enforcement.md](internals/enforcement.md) — every hook, the pre-commit/pre-push gates, the guardrail matrix, and Claude-invocation billing.
- [internals/handover-system.md](internals/handover-system.md) — the full cross-session handover system + user-slug resolution.
- [internals/jira-plugin.md](internals/jira-plugin.md) — the local Jira CLI ↔ Atlassian MCP op mapping.
- [internals/stuck-playbook.md](internals/stuck-playbook.md) — guardrail-recovery escape hatches.
- [handover/overnight-mode.md](handover/overnight-mode.md) — the unattended overnight pipeline (11 phases, attestation, block criteria).
- [internals/context-architecture.md](internals/context-architecture.md) — the lean-surface doctrine: where knowledge lives (layering model, the nesting trap, memory-as-map).
- [internals/harness-compat.md](internals/harness-compat.md) — running himmel under Codex / other harnesses — the compatibility matrix + per-feature port/guard/accept decisions.
- [internals/environment-gotchas.md](internals/environment-gotchas.md) — Windows / Git-Bash / git-worktree / scheduler / Bash-tool / content-filter environment traps.
- [internals/egress-matrix.md](internals/egress-matrix.md) — the data-egress policy (owned corpus × provider × purpose) enforced by `scripts/guardrails/egress-matrix.json`.
- [internals/lesson-audit.md](internals/lesson-audit.md) · [internals/lesson-provenance.md](internals/lesson-provenance.md) — the self-evolving lessons-loop precision gate + provenance schema.

## Orchestration & lanes (HIMMEL-654 workstream series)

- [orchestration-patterns.md](orchestration-patterns.md) (+ [.notes.md](orchestration-patterns.notes.md) run log) — coordination doctrine for fan-outs, verify loops, and overnight shifts.
- [internals/ci-orchestrator.md](internals/ci-orchestrator.md) — the queue/scheduling layer over himmel's scarce CI compute.
- [internals/codex-orchestrator-audit.md](internals/codex-orchestrator-audit.md) — readiness audit for Codex-as-orchestrator.
- [internals/lane-parity.md](internals/lane-parity.md) — the living compatibility index across delegation lanes.
- [internals/validation-gates.md](internals/validation-gates.md) — placement doctrine for validation/quality gates across workflows.
- [internals/worker-spawn-matrix.md](internals/worker-spawn-matrix.md) — native Hermes subagents vs. external lane workers.

## Integrations

- [jira-projects.md](jira-projects.md) — Jira project setup + conventions.
- [telegram-bridge.md](telegram-bridge.md) · [internals/telegram-bridge.md](internals/telegram-bridge.md) — the Telegram bridge.
- [hermes-runbook.md](hermes-runbook.md) — the hermes junior-tier model lane.
- [luna/README.md](luna/README.md) — the luna companion second-brain vault guides (incl. [end-session-wiki](luna/end-session-wiki.md) + its [schema](luna/end-session-wiki-schema.md), [emergence-crystallization](luna/emergence-crystallization.md), [pr-lane-guard](luna/pr-lane-guard.md), [compounding](luna/compounding.md), [google-health-connector-setup](luna/google-health-connector-setup.md), [salus-health-series-substrate-design](luna/salus-health-series-substrate-design.md)).

## Setup (continued)

- [setup/cli-proxy-lane.md](setup/cli-proxy-lane.md) — the `cc-codex` CLIProxyAPI lane per-host bring-up checksheet.
- [setup/codex.md](setup/codex.md) — running himmel under OpenAI Codex (`codex-cli`) — step-by-step setup.
- [setup/windows-clean-machine.md](setup/windows-clean-machine.md) — factory-clean-Windows-11 → full himmel dev + lane fleet, remote-driven runbook.

## Process, security & audits

- [security-review.md](security-review.md) — the security-review playbook.
- [security/npm-policy.md](security/npm-policy.md) · [security/python-policy.md](security/python-policy.md) — supply-chain hygiene policy.
- [tool-adoption/rubric.md](tool-adoption/rubric.md) — the decision method every community-tool eval runs through.
- [tool-adoption/registry.md](tool-adoption/registry.md) — every evaluated tool, recorded.
- [tool-adoption/telemetry.md](tool-adoption/telemetry.md) — adoption-outcome telemetry for the registry.
- [license-audit.md](license-audit.md) · [skills-taxonomy-audit.md](skills-taxonomy-audit.md) — audits.
- [leak-scrub-runbook.md](leak-scrub-runbook.md) — what to do when sensitive data lands in the repo (and possibly the public mirror).
- `internals/public-propagation.md` — operator-personal, PRIVATE-only: how the private repo syncs code to the public mirror. Not linked here — the file is in `PRIVATE_PATHS` (`scripts/lib/public-clone-paths.sh`) and never propagates, so a link would 404 in the public mirror (this map does).

## Historical / working records (not a navigation target)

`adr/` (architecture decision records), `patches/` (dated point-fix logs),
and `specs/` (internal design/plan docs migrating to the state repo per
CLAUDE.md HIMMEL-409) hold dated, single-purpose artifacts kept for
provenance rather than day-to-day reference — browse the directory rather
than looking for an index here.

---

Working as an LLM in this repo? The machine-readable map is [`../llms.txt`](../llms.txt).
