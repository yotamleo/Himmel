# Jarvis subsystems — adopter usage reference

himmel is evolving into an "agentic OS": Claude-main orchestrates a fleet across
model backends, routes each task to the right model, validates with diverse
critics, under a command-and-control surface, on a token-economical footing
(epic **HIMMEL-654**). This page is the **adopter-facing** map of the optional
subsystems that make that up — what each is, whether it's on by default, how to
enable it, and where the deep docs live.

> **Default posture: every optional *lane* is OFF until you configure it** —
> GLM, the escalation channel, the statusline, and the clipper pipeline each
> need a key, flag, or vault before they do anything. The root `CLAUDE.md`
> delegation table directs skipping absent lanes. Enable only the subsystems
> you want.

| Subsystem | Status | Default | Enable with |
|---|---|---|---|
| [GLM offload lane](#glm-offload-lane) | shipped | **off** | `ZAI_API_KEY` |
| [Quota-gauge (cross-lane quota observability)](#quota-gauge--cross-lane-quota-observability) | shipped | **on** (passive) | no setup — reads only |
| [Escalation channel](#escalation-channel) | shipped | **off** | rides the GLM lane |
| [Statusline](#statusline) | shipped | opt-in | `scripts/lib/wire-statusline.sh` |
| [Clipper pipeline](#clipper-pipeline) | shipped | opt-in | luna vault + `/harvest-clips` |
| [Mission Control / C&C](#mission-control--cc) | **planned** | — | WS8 (not yet shipped) |

---

## GLM offload lane

**What it is.** A way to offload well-scoped implementation chunks to a GLM
(Z.ai) worker running `claude` against the Z.ai Anthropic-compatible endpoint,
under himmel's full hook/guardrail set. The worker spawns into its own git
worktree, is inspected, and its output is validated before anything merges.

**Gating (off by default).** The lane is inert unless you set `ZAI_API_KEY`
(env or a config file). `scripts/telegram/glm-env.ts` **throws** if the key is
absent, so `spawn-glm.ts` / the `claude-glm` launchers simply cannot start
without it. There is no SessionStart auto-activation.

**Safety.** Third-party lanes have no auto-mode classifier and usually run under
`--permission-mode bypassPermissions`, so himmel substitutes a **deterministic
deny hook** (`scripts/hooks/block-glm-external-writes.sh`): on the GLM lane
(detected via `ANTHROPIC_BASE_URL` containing `api.z.ai`) it hard-blocks
`git push`, remote-url rewrites, PR/merge, and network CLIs. Audited-and-
recoverable actions (the Jira CLI, `gh issue`, read-only `gh pr view`, qmd KB
reads) are carved out.

**Use it.** `bun scripts/telegram/spawn-glm.ts <task>` spawns a worker; see
**[glm-offload.md](glm-offload.md)** for the spawn→inspect→validate runbook and
the batch fan-out pattern. Chunk large plans — GLM workers choke on 500+-line
plans.

**Cost.** Pay via the GLM Coding Plan usage bank; per-token router lanes are
deliberately off (see **[token-economy.md](token-economy.md)**).

## Quota-gauge — cross-lane quota observability

**What it is.** A passive observability layer that answers "how much quota is
left, per lane (Claude / GLM / Codex / Alibaba)?" — an append-only JSONL
ledger, fail-open (a write failure never breaks a session), that **never**
routes, arms, spawns, or blocks.

**Status: shipped** (#873/#877). The ledger, path resolver, and row-builders
live in **`scripts/telegram/quota-gauge.ts`** (TS twin) and
**`scripts/lib/quota-gauge-ledger.sh`** (bash twin, byte-identical canonical
record), with the shared path resolver in
**`scripts/lib/quota-gauge-ledger-path.sh`**. Lane writers piggyback existing
touchpoints (e.g. GLM's cap-guard) — no new fetch, no new poll — so there is
no separate enable step; the ledger just accumulates as those touchpoints run.

**Name history.** Originally shipped as "headroom" (WS9). Renamed
`headroom` → `quota-gauge` in HIMMEL-697 to free the "Headroom" name for the
unrelated HIMMEL-622 tool-adoption candidate.

## Escalation channel

**What it is.** A way for a sandboxed GLM worker that hits a gated capability
(e.g. it needs a push the deny hook blocks) to **ask** the parent/operator for a
scoped grant instead of deadlocking or running under blanket bypass.

**How it works.** Workers only ever **append** an escalation request to their
session's `outbox.jsonl`. The parent/operator is the single adjudicator per
session and responds via a lean CLI:

```sh
bun scripts/telegram/adjudicate.ts list                    # surface pending escalations
bun scripts/telegram/adjudicate.ts grant  <sessionDir> --arm <arm> --pattern <re> [--ttl m] [--uses n]
bun scripts/telegram/adjudicate.ts refuse <sessionDir> <index>
```

A **grant** whitelists exactly one command shape on one deny arm
(`git-push` / `git-url` / `gh` / `network`), TTL- and use-bounded. The deny hook
folds valid grant patterns into its allowed-count, so a grant re-enables one
narrow capability without lifting the wall. A refusal clears the escalation.

**Enable.** It rides the GLM lane — no separate setup; it's live whenever GLM
workers are running.

## Statusline

**What it is.** A terminal statusline for Claude Code showing session context
(usage window, ledger segment, configurable bottom-row period). The current
default renderer is **claude-hud**
(`marketplace/plugins/claude-hud/dist/index.js`, HIMMEL-718), a forked Node
renderer; the vendored bash bar in **`scripts/statusline/`** is retained as
the rollback fallback.

**Use it.** Wire it into `~/.claude/settings.json` via
**`scripts/lib/wire-statusline.sh`** (roll back via
**`scripts/lib/unwire-statusline.sh`**, which repoints `.statusLine` to the
bash wrapper `scripts/where-are-we/statusline.sh` — this composes the
vendored `scripts/statusline/` bar with a where-are-we ledger line). See
**[../scripts/statusline/README.md](../scripts/statusline/README.md)** for the
vendored bar's options and
**[../scripts/statusline/VENDORED.md](../scripts/statusline/VENDORED.md)**
for the fork-sync provenance. If the configured statusline command path is
removed or absent, the statusline silently disappears instead of reporting an
error.

## Clipper pipeline

**What it is.** An autonomous, staged pipeline that turns raw clips (web
captures, Telegram forwards) dropped into a luna vault's `Clippings/` into
triaged, synthesized, filed knowledge — the capture arm of the luna second-brain.

**The stages** (each an idempotent `obsidian-triage` skill, safe to re-run):

1. **`/harvest-clips`** — marks each clip harvest-ready; GitHub URLs are
   dispatched to repo synthesis.
2. **`/triage-clips`** — summarizes, infers tags against the vault tag set,
   suggests related notes, extracts action items to the daily note.
3. **`/synthesize-clips`** — cross-clip synthesis: recurring themes → synthesis
   pages + proposed vault restructuring.
4. **`/archive-clips`** — graduates fully-processed clips out of the inbox into
   `Clippings/_done/`, rewriting inbound links.

**Enable.** Requires a luna second-brain vault — scaffold one via the
`obsidian-second-brain` skill (or the `templates/luna-second-brain` template),
then keep it current with `/luna-upgrade`. Run the stages on demand, or arm them
on a cadence.

## Mission Control / C&C

**Status: planned (WS8), not yet shipped.** The command-and-control / "war room"
surface for observing and steering the fleet is specced but not built. This
section is a placeholder; it will document the shipped surface once WS8 lands.
Until then, fleet state is surfaced through the `where-are-we` ledger and the
`/morning-report` command.

---

*Deep-dive docs:* [glm-offload.md](glm-offload.md) ·
[token-economy.md](token-economy.md) · [hermes-runbook.md](hermes-runbook.md) ·
[internals/enforcement.md](internals/enforcement.md) (the hooks that gate these
lanes) · [internals/telegram-bridge.md](internals/telegram-bridge.md).
