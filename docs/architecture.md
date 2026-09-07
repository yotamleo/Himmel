# himmel architecture — the diagrams

Five views of how the harness is wired. A box that names a repo path points at
a file you can open and read — with one exception, `scripts/jira/dist/index.js`,
a generated build artifact that only exists after a build (see "Keeping these
accurate" below). The diagrams also contain actor and external-system boxes
(`Claude tool call`, `operator`, `Prometheus`, `Telegram`, `Atlassian REST`,
…) that deliberately name no file.

These are the structural views. Four **behavioural** chains already have
diagrams in [`configuration.md`](configuration.md) and are not repeated here:
the ticket→ship chain, the tool-call permission chain, the Telegram bridge
router, and the delegation-lane routing tree. Read those for "what happens to
one call"; read this file for "what the layer is made of".

- [1. The enforcement layers](#1-the-enforcement-layers)
- [2. The handover system](#2-the-handover-system)
- [3. The fleet and the console](#3-the-fleet-and-the-console)
- [4. The Jira / backend seam](#4-the-jira--backend-seam)
- [5. The observability chain](#5-the-observability-chain)

---

## 1. The enforcement layers

himmel enforces structurally, at five independent stages. A rule that lives at
only one stage can be forgotten; the same invariant is often checked at two.
The live inventory is `.claude/settings.json`, the plugin `hooks.json` files,
and `.pre-commit-config.yaml` — this diagram is the shape, not the list.

```mermaid
flowchart TD
    subgraph S1["1 · tool call — in-session, before the call runs"]
        TC["Claude tool call<br/>Bash · Edit · Read · Agent · MCP"]
        H1[".claude/settings.json — 15 guardrail scripts,<br/>run as ONE chained dispatch per hook event<br/>block-edit-on-main · block-read-secrets · block-destructive-commands<br/>block-git-stash · block-jira-compound-write · block-tail-pipe-on-gates<br/>block-rogue-claude-schedule · block-chokepoint-env-prefix<br/>require-quiet-run · orchestrator-inline-guard · guard-memory-capture<br/>block-backend-tier · check-cr-marker-on-pr-create<br/>auto-approve-safe-bash · auto-arm-on-cap"]
        H2["marketplace/plugins/himmel-ops/hooks/hooks.json — 10 guards<br/>block-docker-privesc · block-merged-pr-commit<br/>block-unresolved-cr-merge · block-glm-external-writes<br/>block-graphify-egress · block-lesson-enforcement-writes<br/>block-rogue-codex-wsl · block-rogue-codex-exec<br/>guard-implementor-dispatch · guard-console-dispatch"]
        H3["scripts/hooks/guardrail-block.mjs<br/>installs 3 of them into USER scope (~/.claude/settings.json)<br/>so they still fire outside a himmel checkout"]
        H4["passive taps — record, never block<br/>scripts/trust/shadow-ledger.mjs<br/>scripts/observability/session-run-hook.ts"]
        TC --> H1
        TC --> H2
        TC --> H4
        H3 -.->|"installs into user scope"| H1
    end

    subgraph S2["2 · git commit"]
        PC["pre-commit stage — 37 hook ids<br/>.pre-commit-config.yaml<br/>shellcheck · gitleaks · check-worktree-isolation<br/>check-guardrail-matrices · check-artifact-leakage<br/>check-fail-open-lint · oxlint ratchets"]
        CM["commit-msg stage — 1 hook id<br/>scripts/hooks/check-commit-msg.sh<br/>conventional commit + ticket ID"]
        PC --> CM
    end

    subgraph S3["3 · git push"]
        PP["pre-push stage — 11 hook ids<br/>check-push-target · check-no-force-push<br/>check-platforms-tested · check-security-reviewed<br/>check-pr-mergeable · check-cr-before-push<br/>npm audit / licenses / signatures"]
    end

    subgraph S4["4 · CI — .github/workflows/ci.yml, on the pushed branch"]
        CI["10 jobs · secret-scan · commit-lint · lint<br/>node-suites · lanes-and-trust-suites<br/>guardrail-matrices · bun-suites<br/>doc-invariants · security-scan · shell-unit"]
    end

    subgraph S5["5 · pull request + merge"]
        CR["the CR marker — three scripts, three roles:<br/>WRITTEN at push by check-cr-before-push.sh<br/>gh pr create REFUSED while it exists<br/>(check-cr-marker-on-pr-create.sh)<br/>CLEARED only by a clean /pr-check<br/>(scripts/cr/clear-cr-marker.sh)"]
        MG["merge gate<br/>scripts/hooks/block-unresolved-cr-merge.sh<br/>consumes the CI result AND review state:<br/>CI green AND zero unresolved threads"]
        CR --> MG
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
gate sees the CI result plus review state — which is why it comes last, and why
the arrow runs CI → merge gate and never the reverse. An invariant that matters
gets checked wherever it is cheapest to catch — and the ones that matter most
get checked twice.

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
        AR["scripts/handover/arm-resume.sh<br/>schedules an OS relaunch (schtasks / at / crontab),<br/>dedupes per handover, self-deletes its own slot"]
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

**The invariant that makes it work.** One leg is one file: state and orders
never split across two documents, so a resuming session cannot read half the
picture. The queue lock is structural rather than advisory because prose
coordination between two armed sessions failed three ways in one night — the
escalation is recorded in `scripts/handover/queue-lock.sh`'s own header.

Full flows and the resolver contract:
[`internals/handover-system.md`](internals/handover-system.md).

---

## 3. The fleet and the console

More than one Claude session runs at a time. The fleet model says who may
write what, who may spawn whom, and how a revision reaches a running agent.

```mermaid
flowchart TD
    OP["operator"] --> CON["console session<br/>coordinates; holds no worktree"]

    CON -->|"SendMessage / ListAgents"| P1["mission session<br/>one ticket · one worktree"]
    CON -->|"SendMessage / ListAgents"| P2["mission session<br/>one ticket · one worktree"]

    P1 --> GD{"scripts/hooks/guard-implementor-dispatch.sh<br/>refuses native Agent dispatch<br/>when the 5h Claude bank is ≥80% used"}
    GD --> NAT["native subagents — the default fleet<br/>haiku · sonnet · opus · fable<br/>every dispatch names its model"]

    P1 -.->|"registry, currently impl-dormant"| EXT["scripts/lanes/lanes.json<br/>external lanes (glm · claudex · codex · hermes).<br/>No defaultImplLane by operator ruling —<br/>an unqualified impl dispatch refuses to the native path.<br/>Query the live set with /lanes"]

    NAT --> RT["RETASK channel<br/>every brief carries a fresh nonce.<br/>EXPANSION / REDIRECT needs the echoed token;<br/>narrowing and halt are tokenless (fail-safe).<br/>A revision arrives as a direct message — never in a tool result."]

    P1 --> SW["single-writer<br/>many readers, ONE writer.<br/>Never fan parallel writes at one artifact."]
    P1 --> QL["queue-lock.sh<br/>one session per handover queue"]

    NAT --> WORK["worker commits on its own branch;<br/>the parent owns review and merge"]
    WORK --> CRL["/pr-check → CR-clean → merge gate"]
```

**Caps that are not model-tuned.** Spawn depth and concurrency come from
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` — read the environment; unset means the
harness default applies. Haiku does not spawn.

Tier semantics, effort-before-tier, and cost:
[`internals/lane-calibration.md`](internals/lane-calibration.md). The RETASK
threat model: [`internals/retask-channel.md`](internals/retask-channel.md).
Native subagents vs. external lane workers:
[`internals/worker-spawn-matrix.md`](internals/worker-spawn-matrix.md).

---

## 4. The Jira / backend seam

An MCP server costs context on every session that loads it. A local CLI costs
nothing until it is called. himmel routes issue-tracker work to the CLI and
keeps MCP for the individual ops a backend's CLI does not implement — and
enforces that routing rather than asking Claude to remember it.

```mermaid
flowchart TD
    INT["agent needs a Jira op"] --> REG["scripts/backends.json<br/>per-backend chain: [cli, api, mcp]"]

    REG --> BT{"scripts/hooks/block-backend-tier.sh<br/>PreToolUse on mcp__plugin_atlassian_atlassian__.*"}
    BT -->|"an equivalent CLI verb exists"| DENY["DENIED — use the CLI"]
    BT -->|"that op has no CLI equivalent"| MCP["Atlassian MCP server"]

    DENY --> CLI["scripts/jira/dist/index.js<br/>17 verbs: get create list transition transitions<br/>comment attach edit move projects project-create<br/>link assign attachments worklog watchers sprint"]

    CLI --> API["Atlassian REST<br/>JIRA_BASE_URL · JIRA_EMAIL · JIRA_API_TOKEN · JIRA_PROJECT_KEY"]
    MCP --> API

    CLI -.->|"--list-commands<br/>one verb per line"| LC["scripts/hooks/block-mcp-when-plugin-exists.sh<br/>derives its blocked set from the CLI itself,<br/>so the gate cannot drift when a verb is added"]

    CLI -.->|"jira mcp"| SELF["the same verbs re-exposed over MCP on stdio,<br/>lazily imported so the SDK stays off the hot path"]
```

**The detail that keeps it honest.** The gate does not hand-maintain a list of
blocked MCP tools — it asks the CLI what verbs it has. Adding a verb tightens
the gate automatically; removing one loosens it. That is the difference
between a rule and a structure.

Invocation shape (absolute path from the primary checkout — `dist/` is an
untracked build artifact, so a worktree lacks it) and the full op ↔ MCP
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
        FLOW["~/.himmel/flow-runs.jsonl<br/>the pipeline-cadence legs"]
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

    EXP -.-> M["families: flow_run_in_flight · flow_run_outcome_total<br/>flow_run_last_success_timestamp · session_active_total<br/>session_dead_total · session_end_outcome_total<br/>himmel_tool_calls_total · himmel_tool_denials_total"]
```

**The record that never gets written is the important one.** `SessionEnd` is a
graceful-exit hook: a crash, an OOM, or a window the operator eventually closes
emits `session_start` and no `session_end`, ever. Liveness is therefore decided
by the *reader*, from transcript mtime — not asserted by the writer. The same
reasoning splits an expired unpaired row into `abandoned` (its pid is confirmed
dead — real hygiene information, but nothing is hung and nobody can act, so it
must not page) and `stalled` (everything else).

`alerts.rules.yml` is loaded into Prometheus for self-visibility and
`promtool` testability only; no Alertmanager is installed, so nothing there is
ever delivered. Details and the passivity invariant:
[`../scripts/observability/README.md`](../scripts/observability/README.md).

---

## Keeping these accurate

When you move or rename a file a box above names, this file is part of
the change — the same rule that governs
[`commands-catalog.md`](commands-catalog.md). Every count here is derivable:
the gate ids and their split across the three git stages (37 pre-commit,
11 pre-push, 1 commit-msg) from `.pre-commit-config.yaml`, the job count from
`.github/workflows/ci.yml`, the verb count from
`node scripts/jira/dist/index.js --list-commands`. Re-derive rather than trust
them if a diagram and the code disagree.
