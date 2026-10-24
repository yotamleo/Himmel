# himmel architecture — the diagrams

Five views of how the harness is wired. For the narrative version (what the
parts are, how one ticket moves through them and why it is built this way),
start with [`system-design.md`](system-design.md).

A box that names a repo path points at a file you can open and read. The one
exception is `scripts/jira/dist/index.js`, a generated build artifact that only
exists after a build (see "Keeping these accurate" below). The diagrams also contain actor and external-system boxes
(`Claude tool call`, `operator`, `Prometheus`, `Telegram`, `Atlassian REST`,
…) that deliberately name no file.

Words follow the [glossary](glossary.md): the **chief** is the session that
runs a shift, and each **worker** owns one ticket, one worktree and one pull
request. Many identifiers still carry the older names until their rename slice
lands (HIMMEL-5689). The chief's command and script are already `/chief` and
`chief.sh`, but its directories and markers say `console` (`console-kit/`,
`HIMMEL_CONSOLE_*`), and a worker's say `leg` (`headed-arm-leg.sh`,
`HIMMEL_CONSOLE_LEG`). A box shows the new word first and the identifier as it
is today.

These are the structural views. Four **behavioural** chains already have
diagrams in [`configuration.md`](configuration.md) and are not repeated here:
the ticket→ship chain, the tool-call permission chain, the Telegram bridge
router, and the delegation-lane routing tree. Read those for "what happens to
one call"; read this file for "what the layer is made of". The development
graph ([`guide/dev-graph.html`](guide/dev-graph.html), drawn from
[`guide/dev-graph/graph.json`](guide/dev-graph/graph.json)) shows every
decision a change meets on its way from dispatch to merge.

- [1. The enforcement layers](#1-the-enforcement-layers)
- [2. The handover system](#2-the-handover-system)
- [3. The fleet: the chief and its workers](#3-the-fleet-the-chief-and-its-workers)
- [4. The Jira / backend seam](#4-the-jira--backend-seam)
- [5. The observability chain](#5-the-observability-chain)

---

## 1. The enforcement layers

himmel enforces structurally, at five independent stages. A rule that lives at
only one stage can be forgotten; the same invariant is often checked at two.
The live inventory is `.claude/settings.json`, the plugin `hooks.json` files,
and `.pre-commit-config.yaml`; this diagram shows the shape, not the list.

```mermaid
flowchart TD
    subgraph S1["1 · tool call — in-session, before the call runs"]
        TC["Claude tool call<br/>Bash · Edit · Read · Agent · MCP"]
        H1[".claude/settings.json — 33 PreToolUse hook scripts,<br/>run as ONE chained dispatch per matcher; the first refusal wins<br/>block-edit-on-main · block-read-secrets · block-destructive-commands<br/>block-git-stash · block-jira-compound-write · block-tail-pipe-on-gates<br/>block-rogue-claude-schedule · block-chokepoint-env-prefix<br/>block-edit-live-settings · block-write-into-main-checkout<br/>require-quiet-run · read-clamp · guard-pr-check-literal<br/>orchestrator-inline-guard · guard-memory-capture · guard-agent-model<br/>block-backend-tier · mcp-policy · check-cr-marker-on-pr-create<br/>auto-approve-safe-bash · auto-arm-on-cap · …"]
        H2["marketplace/plugins/himmel-ops/hooks/hooks.json — 15 PreToolUse guards<br/>block-docker-privesc · block-infra-destroy · block-merged-pr-commit<br/>block-unresolved-cr-merge · block-glm-external-writes<br/>block-graphify-egress · block-rogue-codex-exec<br/>block-lesson-enforcement-writes · block-agent-native-egress<br/>guard-implementor-dispatch · guard-console-dispatch<br/>guard-subagent-model · guard-console-foreground · guard-judge-writes · guard-rm-writes"]
        HG["marketplace/plugins/himmel-guard/hooks/hooks.json<br/>block-destructive-commands for adopter projects<br/>(off in the settings template; opt in per project)"]
        H3["scripts/hooks/guardrail-block.mjs<br/>installs 3 of them into USER scope (~/.claude/settings.json):<br/>auto-approve-safe-bash · block-edit-on-main · block-read-secrets<br/>so they still fire outside a himmel checkout"]
        H4["passive taps — record, never block<br/>scripts/trust/shadow-ledger.mjs<br/>scripts/observability/session-run-hook.ts"]
        TC --> H1
        TC --> H2
        TC --> HG
        TC --> H4
        H3 -.->|"installs into user scope"| H1
    end

    subgraph S2["2 · git commit"]
        PC["pre-commit stage — 62 hook ids<br/>.pre-commit-config.yaml<br/>shellcheck · gitleaks · worktree-isolation<br/>guardrail-matrices · artifact-leakage<br/>fail-open-lint · check-old-terms · oxlint ratchets"]
        CM["commit-msg stage — 1 hook id<br/>scripts/hooks/check-commit-msg.sh<br/>conventional commit + ticket ID"]
        PC --> CM
    end

    subgraph S3["3 · git push"]
        PP["pre-push stage — 14 hook ids<br/>no-push-to-main · no-force-push<br/>platforms-tested · security-reviewed<br/>pr-mergeable-gate · code-review-before-push<br/>check-old-terms · npm audit / licenses / signatures"]
    end

    subgraph S4["4 · CI — .github/workflows/ci.yml, on the pushed branch"]
        CI["21 jobs, most with a fail-fast twin · plan · ci-quick<br/>secret-scan · commit-lint · plugin-version-bump · lint<br/>node-suites · bun-suites · lanes-and-trust-suites<br/>guardrail-matrices · doc-invariants · security-scan<br/>shell-unit · guard-corpus-full · leak-classes · …"]
    end

    subgraph S5["5 · pull request + merge"]
        CR["the review-owed marker (CR marker) — three scripts, three roles:<br/>WRITTEN at push by check-cr-before-push.sh<br/>gh pr create REFUSED while it exists<br/>(check-cr-marker-on-pr-create.sh)<br/>CLEARED only by a clean /pr-check<br/>(scripts/cr/clear-cr-marker.sh)"]
        MG["merge gate<br/>scripts/hooks/block-unresolved-cr-merge.sh<br/>consumes the CI result AND review state:<br/>CI green AND zero unresolved threads;<br/>a worker also needs the chief's GO file"]
        MOG["scripts/handover/merge-on-green.sh<br/>the sanctioned merge: squash pinned to the checked head"]
        CR --> MG
        MG --> MOG
    end

    H1 --> S2
    CM --> S3
    PP --> S4
    PP --> CR
    CI --> MG

    H1 -.->|"exit 2"| BLOCK["BLOCKED — reason on stderr.<br/>Bypass is a session env var set in the<br/>LAUNCHING shell; a per-call prefix does not work."]
    PC -.->|"non-zero"| BLOCK
    PP -.->|"non-zero"| BLOCK
```

**Why five stages and not one.** Each stage sees something the others cannot. A
PreToolUse hook sees the *intent* of a single call but not the diff. A
pre-commit gate sees the staged diff but not the branch's history. A pre-push
gate sees the whole range and the remote. CI sees a clean machine. The merge
gate sees the CI result plus review state, which is why it comes last and why
the arrow runs CI → merge gate and never the reverse. An invariant that matters
gets checked wherever it is cheapest to catch, and the ones that matter most
get checked twice.

**What a starter install carries.** An adopter project gets a small subset:
the three user-facing guards (`auto-approve-safe-bash`, `block-edit-on-main`,
`block-read-secrets`) wired into its own `.claude/settings.json`, and — when it
has no `.pre-commit-config.yaml` — three native git gates placed by
`scripts/adopt.sh` (`check-worktree-isolation.sh`, `check-commit-msg.sh`,
`check-push-target.sh`). The rest of this diagram runs from a himmel checkout.

Per-hook behaviour, the guardrail matrix, and the bypass env var for each:
[`internals/enforcement.md`](internals/enforcement.md). Recovery when one
stops you: [`internals/stuck-playbook.md`](internals/stuck-playbook.md).

---

## 2. The handover system

Handover is how work survives a session boundary. State is plain markdown in a
directory the resolver picks; nothing about it is opaque or lossy.

```mermaid
flowchart TD
    subgraph R["resolution — scripts/lib/handover-path.sh"]
        HR["handover_root()<br/>PURE — never mkdirs, rc=2 if absent"]
        HRE["handover_root_ensure()<br/>creates the Mode A dir on demand"]
        MA["Mode A · inline<br/>&lt;repo&gt;/handovers<br/>(HANDOVER_DIR unset)"]
        MB["Mode B · external<br/>$HANDOVER_DIR<br/>fails CLOSED (rc=2) on a bad path"]
        HR --> MA
        HR --> MB
        HRE --> HR
    end

    subgraph L["layout"]
        BUCKET["&lt;root&gt;/&lt;USER_SLUG&gt;/&lt;repo-bucket&gt;/<br/>cross · himmel · luna · luna_brain"]
        REG["~/.claude/handover/registry.json<br/>source of truth for tracked repos<br/>read/written only via /handover repos|register|init"]
    end

    subgraph W["writing state"]
        CMD["/handover — snapshot the session"]
        AC["scripts/handover/auto-commit.sh<br/>Mode B only"]
        PO["scripts/handover/pr-open.sh<br/>scripts/handover/pr-merge.sh"]
        FL["scripts/handover/flush.sh<br/>session-end consolidation sweep"]
    end

    subgraph C["continuity across sessions"]
        QL["scripts/handover/queue-lock.sh<br/>ONE writer per queue.<br/>Lock is a DIRECTORY (atomic mkdir);<br/>release needs the printed release-token"]
        AR["scripts/handover/arm-resume.sh<br/>a scheduled launch (arming) through at / crontab<br/>(schtasks on Windows); dedupes per handover,<br/>self-deletes its own slot"]
        RES["/handover-resume · /handover-resume-armed<br/>scripts/handover/resume*.sh"]
        NEXT["next session — reads the same markdown,<br/>resumes at the recorded stop point"]
        QL --> AR --> NEXT
        RES --> NEXT
    end

    MB --> BUCKET
    MA --> BUCKET
    REG --> BUCKET
    BUCKET --> W
    W --> C
```

**The invariant that makes it work.** One worker is one file: state and orders
never split across two documents, so a resuming session cannot read half the
picture. The queue lock is structural rather than advisory because prose
coordination between two armed sessions failed three ways in one night. The
escalation is recorded in `scripts/handover/queue-lock.sh`'s own header.

Full flows and the resolver contract:
[`internals/handover-system.md`](internals/handover-system.md).

---

## 3. The fleet: the chief and its workers

More than one Claude session runs at a time. The fleet model says who may
write what, who may spawn whom, and how a revision reaches a running agent.
The chief starts its workers in parallel waves; a dependency chain is a set of
workers that must run in order, because each needs the one before it to merge.

```mermaid
flowchart TD
    OP["operator"] --> CON["the chief<br/>runs the shift; holds no worktree<br/>(chief.sh, console-kit/)"]

    CON -->|"SendMessage / ListAgents"| P1["worker<br/>one ticket · one worktree · one PR<br/>(launched by headed-arm-leg.sh)"]
    CON -->|"SendMessage / ListAgents"| P2["worker<br/>one ticket · one worktree · one PR"]
    CON -.->|"a parallel wave: started together,<br/>collision-checked, capped by HIMMEL_FLEET_CAP"| P2

    P1 --> GD{"scripts/hooks/guard-implementor-dispatch.sh<br/>refuses an implementation-shaped native Agent dispatch<br/>(haiku and read-only helpers are exempt) when Claude usage<br/>is ≥80% of the 5-hour window (IMPL_GUARD_HARD)<br/>or ≥85% of the weekly window (IMPL_GUARD_WEEKLY_HARD);<br/>with no live reset time it only warns"}
    GD --> NAT["native subagents — the default fleet<br/>haiku · sonnet · opus · fable<br/>every dispatch names its model"]

    P1 -.->|"registry, impl-dormant"| EXT["scripts/lanes/lanes.json — 16 lanes:<br/>the 4 native tiers plus external ones<br/>(claudex · codex · hermes · openrouter · ollama · …).<br/>No defaultImplLane by operator ruling —<br/>an unqualified impl dispatch refuses to the native path.<br/>Query the live set with /lanes"]

    NAT --> RT["revision channel (RETASK)<br/>every brief carries a fresh token (nonce).<br/>EXPANSION / REDIRECT needs the echoed token;<br/>narrowing and halt are tokenless (fail-safe).<br/>A revision arrives as a direct message — never in a tool result."]

    P1 --> SW["single-writer<br/>many readers, ONE writer.<br/>Never fan parallel writes at one artifact."]
    P1 --> QL["queue-lock.sh<br/>one session per handover queue"]

    NAT --> WORK["a worker commits on its own branch;<br/>the chief owns approval and merge"]
    WORK --> CRL["/pr-check → review-owed marker cleared → READY"]
    CRL --> GO["the chief's GO file<br/>scripts/handover/console-kit/go.sh<br/>signed for one PR and one head; a worker never writes its own"]
    GO --> MOG["scripts/handover/merge-on-green.sh<br/>merge gate → squash merge"]
```

**Caps that are not model-tuned.** Spawn depth and concurrency come from
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, so read the environment; unset means
the harness default applies. Haiku does not spawn.

Every decision a change meets between dispatch and merge — the usage check,
the fleet cap, the review-round cap, the ready-check, the judge, the GO file —
is drawn in the development graph
([`guide/dev-graph.html`](guide/dev-graph.html)); the local dashboard shows the
same graph on its Workflow page. Tier semantics, effort-before-tier, and cost:
[`internals/lane-calibration.md`](internals/lane-calibration.md). The revision
channel's threat model: [`internals/retask-channel.md`](internals/retask-channel.md).
Native subagents vs. external lane workers:
[`internals/worker-spawn-matrix.md`](internals/worker-spawn-matrix.md).

---

## 4. The Jira / backend seam

An MCP server costs context on every session that loads it. A local CLI costs
nothing until it is called. himmel routes issue-tracker work to the CLI and
keeps MCP for the individual ops a backend's CLI does not implement. A hook
enforces that routing, so Claude does not have to remember it.

```mermaid
flowchart TD
    INT["agent needs a Jira op"] --> REG["scripts/backends.json<br/>per-service chain: [cli, api, mcp]<br/>jira · confluence · bitbucket · github"]

    REG --> BT{"scripts/hooks/block-backend-tier.sh<br/>PreToolUse on mcp__plugin_atlassian_atlassian__.*<br/>and mcp__claude_ai_Atlassian_MCP__.*"}
    BT -->|"an equivalent CLI verb exists"| DENY["DENIED — use the CLI"]
    BT -->|"that op has no CLI equivalent"| MCP["Atlassian MCP server"]

    DENY --> CLI["scripts/jira/dist/index.js<br/>44 verbs: get create list transition comment edit<br/>link assign worklog sprint versions fix-version<br/>mirror roadmap rank resolution …<br/>(--list-commands prints them all)"]

    CLI --> API["Atlassian REST<br/>JIRA_BASE_URL · JIRA_EMAIL · JIRA_API_TOKEN · JIRA_PROJECT_KEY"]
    MCP --> API

    CLI -.->|"--list-commands<br/>one verb per line"| BT

    CLI -.->|"jira mcp"| SELF["the same verbs re-exposed over MCP on stdio,<br/>lazily imported so the SDK stays off the hot path"]
```

**The gate asks the CLI.** It keeps no hand-maintained list of blocked MCP
tools; it asks the CLI what verbs it has. Adding a verb tightens the gate
automatically; removing one loosens it. `block-backend-tier.sh` generalised the
older Jira-only `block-mcp-when-plugin-exists.sh` to the services in
`scripts/backends.json` that have an MCP prefix: Jira and Confluence. GitHub and
Bitbucket are registered there with no MCP prefix, so this gate does not route
them. The older script is no longer wired as a hook.

Invocation shape (absolute path from the primary checkout, because `dist/` is
an untracked build artifact and a worktree lacks it) and the full op ↔ MCP
mapping: [`internals/jira-plugin.md`](internals/jira-plugin.md).

---

## 5. The observability chain

The stack is local, passive, and read-only. The exporter never writes a
ledger, never mutates the vault, never starts or kills a process. Missing data
stays missing rather than being invented.

```mermaid
flowchart LR
    subgraph WRITE["writers — hooks, riding existing chokepoints"]
        HK["scripts/observability/session-run-hook.ts<br/>SessionStart · SessionEnd · PreToolUse/PostToolUse on Agent"]
        SL["session-run-ledger.ts<br/>fixed field order, single O_APPEND write,<br/>rotates at 10MB, never blocks the hook"]
        LED["~/.himmel/session-runs.jsonl"]
        FLOW["~/.himmel/flow-runs.jsonl<br/>the pipeline-cadence runs"]
        HK --> SL --> LED
    end

    subgraph READ["reader — pure"]
        EXP["scripts/observability/flow-exporter.ts<br/>Bun HTTP server on 127.0.0.1:9877"]
        LED --> EXP
        FLOW --> EXP
    end

    subgraph SCRAPE["scripts/observability/prometheus.yml"]
        PROM["Prometheus · scrape_interval 60s<br/>flow-exporter scrape_timeout 30s"]
        WEXP["windows_exporter<br/>127.0.0.1:9182"]
        EXP --> PROM
        WEXP --> PROM
    end

    subgraph VIEW["Grafana"]
        DASH["dashboards/war-room-system.json"]
        ALERT["provisioning/alerting/rules.yaml<br/>unified alerting — the ONLY delivery path"]
        PROM --> DASH
        PROM --> ALERT
    end

    ALERT --> TG["Telegram"]

    EXP -.-> M["47 metric families, for example:<br/>flow_run_in_flight · flow_run_outcome_total · flow_run_stalled_current<br/>session_active_total · session_dead_total · subagent_active_total<br/>himmel_tool_calls_total · himmel_tool_denials_total · himmel_tool_errors_total<br/>hook_chain_budget_events_recent · lane_quota_used_pct<br/>himmel_eval_metric_value · graphify_shipped_graph_age_seconds<br/>scheduled_task_next_run_timestamp · luna_git_unpushed_commits"]
```

**The record that never gets written is the important one.** `SessionEnd` is a
graceful-exit hook: a crash, an OOM, or a window the operator eventually closes
emits `session_start` and no `session_end`, ever. So the *reader* decides
liveness, from transcript mtime; the writer does not assert it. The same
reasoning splits an expired unpaired row into `abandoned` (its pid is confirmed
dead: real hygiene information, but nothing is hung and nobody can act, so it
must not page) and `stalled` (everything else).

`alerts.rules.yml` is loaded into Prometheus for self-visibility and
`promtool` testability only; no Alertmanager is installed, so nothing there is
ever delivered. Details and the passivity invariant:
[`../scripts/observability/README.md`](../scripts/observability/README.md).

---

## Keeping these accurate

When you move or rename a file a box above names, this file is part of
the change, the same rule that governs
[`commands-catalog.md`](commands-catalog.md). Every count here is derivable:
the hook scripts per surface from the `PreToolUse` arrays of
`.claude/settings.json` (33 unique scripts) and the himmel-ops `hooks.json`
(15); the gate ids and their split across the three git stages (62
pre-commit, 14 pre-push, 1 commit-msg) from `.pre-commit-config.yaml`; the job
count from `.github/workflows/ci.yml` (21 jobs, not counting the `fail-fast-*`
twins); the lane count from `scripts/lanes/lanes.json`; the verb count from
`node scripts/jira/dist/index.js --list-commands` (44 verbs plus `mcp`); the
metric families from the `addFamily` calls in
`scripts/observability/flow-exporter.ts`. Re-derive rather than trust them if
a diagram and the code disagree.
