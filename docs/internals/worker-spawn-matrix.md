# Worker-spawn matrix: native Hermes subagents vs external lane workers (HIMMEL-749)

> Draft status: evidence-based snapshot from this worktree plus this worker's live
> Hermes delegation surface. Treat any `UNVERIFIED` cell as a follow-up seed, not
> as a negative proof.

## Evidence read

Repository files read for this draft:

- `scripts/telegram/spawn-glm.ts`
- `scripts/telegram/run.ts`
- `scripts/telegram/glm-guard.ts`
- `scripts/telegram/run-prompt.md`
- `scripts/hermes/invoke.sh`
- `scripts/hermes/dispatch-trusted.sh`
- `scripts/hermes/assets/parity_guard.py`
- `scripts/codex/README.md`
- `scripts/codex/startup-health.sh`
- `scripts/codex/companion-liveness.sh`
- `scripts/codex/reap-mcp-fleet.sh`
- `scripts/codex/reap-mcp-fleet.ps1`
- `docs/internals/harness-compat.md`
- `docs/internals/lane-parity.md`
- `docs/hermes-runbook.md`

Live local Hermes surface checked:

- Config path verified: `$LOCALAPPDATA/hermes/profiles/himmel_agent/config.yaml` (Windows; `$HERMES_HOME/profiles/himmel_agent/config.yaml` in general).
- `delegation.model`, `delegation.provider`, `delegation.base_url`,
  `delegation.reasoning_effort`, and `delegation.api_mode` are blank in this
  profile.
- `delegation.max_concurrent_children=3`, `delegation.max_spawn_depth=1`,
  `delegation.max_iterations=50`, `delegation.child_timeout_seconds=600`,
  `delegation.inherit_mcp_toolsets=true`, `delegation.orchestrator_enabled=true`,
  `delegation.subagent_auto_approve=false`.
- Current-session `delegate_task` tool schema exposes task/context/role fields
  but no per-call `model` or `provider` argument. Per-call model selection for
  native subagents is therefore **not available on the surface I can verify**;
  global pinning through `delegation.model` / `delegation.provider` is the
  verified control. Anything beyond that is `UNVERIFIED` here.

Reading constraints for this draft:

- I did not read credential files, `.env`, OAuth stores, or API-key material.
- I did not execute any external lane worker; this is a document/source audit.
- I cite only paths actually read in this session; claims from the live Hermes
  tool schema are explicitly labelled as current-session surface, not repo fact.
- `GAP` means the repo evidence says a proof/control is missing or currently
  tracked as missing.
- `UNVERIFIED` means the inspected sources did not prove the cell either way.
- `Yes` / `No` / `Limited` cells name the source mechanism observed in the
  inspected files rather than assuming parity from another lane.

## Definitions: native Hermes subagent vs external lane worker

A **native Hermes subagent** is created by the in-process `delegate_task` tool.
It gets a separate conversation and terminal session, but it is still owned by
this parent Hermes process. It returns a summary back into the parent session.
It is not durable: if the parent process dies or is stopped, the background child
is lost. In this session, the tool surface does not accept a per-dispatch model;
it uses inherited/global delegation config unless the profile is globally pinned.

An **external lane worker** is a separate harness process spawned through a repo
launcher: Claude Code, Hermes one-shot, Codex/companion, or GLM-through-Claude.
It has OS/process-level isolation, its own logs/transcripts/outbox, and often a
dedicated git worktree/branch. The parent/operator inspects artifacts and merges
or pushes later. Guard coverage is lane-specific: Claude hooks for Claude Code,
`glm-guard` plus GLM env fences for the GLM lane, `parity_guard.py` for Hermes,
and Codex hook adapters / health probes for Codex.

This distinction matters because "spawn a worker" can mean either an in-process
Hermes child with inherited model/tool constraints, or an independent lane worker
with separate filesystem/process/session artifacts and separate guard wiring.

## Matrix

| Spawn path | Worktree isolation | Guard / hook coverage | Per-dispatch model selection | Session artifacts | Push / PR authority | Permission-prompt handling | Supervision / liveness signal |
|---|---|---|---|---|---|---|---|
| **Hermes-native `delegate_task` subagent** | Separate terminal session; no repo worktree is created by the tool itself. Parent must brief/write-scope any worktree discipline. | Hermes tool guard surface inherited from parent profile/toolsets. For this profile, `parity_guard.py` is documented as the main-tier guard in `docs/hermes-runbook.md` and `docs/internals/lane-parity.md`, but whether a native child sees the exact same hook chain is **UNVERIFIED** from this task. | **No per-call model arg verified.** Current tool schema has no `model`/`provider`; global `delegation.model` / `delegation.provider` exist but are blank in `himmel_agent` config. | Child result returns into parent conversation. Tool docs state isolated context + terminal session; no durable transcript/outbox path verified here. | No special authority reduction by the tool. Must follow parent/user policy: no push/PR unless explicitly authorized. | `subagent_auto_approve=false` in config; exact child prompt/approval behavior is **UNVERIFIED**. | Parent receives completion summary. Not durable if parent exits. No external liveness probe verified. |
| **Hermes one-shot via `scripts/hermes/invoke.sh` / `dispatch-trusted.sh`** | `invoke.sh` runs in caller's current directory; no worktree creation. Isolation depends on caller creating/choosing a worktree first. | `invoke.sh` uses Hermes with default `todo` toolset unless `--toolsets` opts in. `dispatch-trusted.sh` sets `HERMES_EXTERNAL_WRITES_OK=1` and defaults to `--profile himmel_agent`; `parity_guard.py` remains the fence and fail-closes external writes unless the engine is trusted. | **Yes.** `invoke.sh --model <name>` passes `-m` into Hermes; `--profile` selects profile; `--toolsets` selects toolsets. | Optional `--log <path>` tees stdout/stderr. Hermes owns its normal session store; exact one-shot transcript path was not verified in repo files. | `dispatch-trusted.sh` allows trusted-engine external writes through `parity_guard.py`; push/PR still require operator authorization by higher-level policy. GLM/z.ai signals override the opt-in and are refused. | One-shot uses `-z` / yolo-style auto-approval in `invoke.sh`; therefore the default toolset is intentionally `todo` to avoid unattended terminal/browser/fs access unless a caller opts in. | Exit code is Hermes' return code; optional log file. No watchdog in `invoke.sh`; no internal timeout by design. |
| **External Claude Code worker (Telegram bounded run via `scripts/telegram/run.ts`)** | Runs in the provided `cwd` / `sessionCwd`; it does not itself create a worktree. Ticket/vault callers choose cwd. | Native Claude Code hooks for the spawned cwd. `run.ts` strips `TELEGRAM_OWN_POLLER`; vault sessions load vault-local hooks. | **Yes.** `run.ts` builds `claude --model <model>`; default `opus`, override via `TELEGRAM_CLAUDE_MODEL`. GLM lane passes a model override via `laneModel('glm')`. | Bus files: inbox/outbox/context paths are embedded in the prompt. The prompt contract appends replies to outbox JSONL and progress to `context.md`. Claude transcripts are under `~/.claude/projects/<escaped-cwd>` by Claude Code convention, but this row's launcher does not print that path. | Prompt permits audited Jira ops but not self-polling. Push/PR authority depends on the brief; no generic push tripwire in `run.ts`. | Bounded run closes stdin, so it cannot answer permission prompts. `run.ts` documents that unapproved tools fall through to prompts and are denied/hang; vault sessions may pass `--permission-mode bypassPermissions` only because the vault hooks still enforce containment. See permission-window follow-up **HIMMEL-748**. | `runSession` returns code, pid, capped/blocked/timedOut, and tail; kills process tree on timeout; detects usage caps and content-filter blocks. |
| **claude-glm / GLM worker via `scripts/telegram/spawn-glm.ts`** | **Yes.** `git worktree add <cwd>/.claude/worktrees/glm+<slug> -b glm/<slug>`; prompt says work only inside that dedicated worktree. | `glm-guard.ts` checks `.salus`, `phi-roots`, and `egress-denylist` fail-closed before the run. `spawn-glm.ts` poisons `remote.origin.pushurl` to `DISABLED-glm-quarantine`. GLM env is built by `glm-env`; Claude Code hooks also apply to the spawned Claude run where present. | **Limited / lane-pinned.** GLM run passes the lane model alias, not the poller default. Per-dispatch context window is selectable by `--context big|small`; no arbitrary per-call model flag in `spawn-glm.ts` was verified. | `sessionDir=<BRIDGE_ROOT>/glm-sessions/glm-<slug>-<ts>` contains `brief.md`, `meta.json`, `outbox.jsonl`, `context.md`, `run.log`, optional `grants.jsonl`, `respawn-handover.md`. Launcher prints `session-dir`, `transcript-dir`, and exit. | Prompt hard-rules: never push, never open PR; validating session owns git/PR. Push tripwire blocks default push path but is documented as not the load-bearing control. Jira writes are allowed via audited CLI. | Stdin-closed Claude run inherits the bounded-run permission posture. Guard-blocked steps should append an escalation JSON line to outbox and continue. Grants support read/write shape classification; autonomous mode refuses write-shaped grants and records escalation. See **HIMMEL-748** for permission-window parity. | `meta.json` transitions running -> done/failed/capped/blocked/timeout. Cap guard records `resume_at`, may arm `arm-resume.sh`, and writes respawn handover. `run.log` stores tail; quota gauge records GLM usage signals. |
| **Codex worker / Codex lane surfaces** | Codex itself uses the caller workspace. Branch provenance convention is `codex/<slug>` per `docs/internals/harness-compat.md`; dedicated worktree creation is outside the codex supervision scripts read here. | Codex direct guard path is `.codex/hooks.json` -> `.codex/run-hook.cmd` -> adapter -> native guard scripts per `harness-compat.md` / `lane-parity.md`. `scripts/codex/*` adds observability/supervision, not the primary guard fence. | **UNVERIFIED in repo files read.** Codex model selection surface is not described in the inspected `scripts/codex/*` supervision scripts. | Codex session rollouts live under `$CODEX_HOME/sessions/rollout-*.jsonl`; startup warnings in `$CODEX_HOME/logs_2.sqlite`. Codex companion job state lives under `$CLAUDE_PLUGIN_DATA/state/<slug>-<hash>/state.json` or fallbacks documented in `companion-liveness.sh`. | `lane-parity.md` marks `codex-direct` write-authority / external-write e2e proof as `GAP`; docs say native block hooks are reached through adapter, but codex external-write through-adapter proof remains missing. | `harness-compat.md` says Codex hooks block by stdout JSON `permissionDecision:"deny"`, not Claude exit 2; the adapter translates. Interactive permission-window parity is **UNVERIFIED** here and belongs with **HIMMEL-748**. | `startup-health.sh` reports degraded startup signals: ignored hooks, skill/plugin prompt truncation, oversized `_where-are-we`. `companion-liveness.sh` flags queued/running jobs with no live runner. `reap-mcp-fleet.{sh,ps1}` reports/reaps orphaned Windows MCP fleet processes. |

## Cross-path notes

- Native Hermes subagents are cheap to dispatch but weakly isolated compared to
  external lanes: no automatic worktree, no durable outbox, no per-call model
  selector verified in this session.
- External lane workers carry their own artifact contract. The parent should
  review session artifacts and branch state rather than trusting a final message.
- The GLM worker has the clearest worker artifact contract: dedicated worktree,
  branch, `glm-sessions` directory, outbox/context/meta/log files, and printed
  transcript directory.
- The Hermes one-shot lane has the clearest model/toolset selector: `--model`,
  `--profile`, `--toolsets`, and optional `--log`.
- Codex supervision is mostly observability around an external harness: startup
  health, companion-job liveness, and Windows MCP-fleet reaping.

## Gaps and follow-up proof needed

- `UNVERIFIED` - Native Hermes child hook parity: prove whether a `delegate_task`
  child in `himmel_agent` always runs through the same `parity_guard.py` hook as
  the parent. Proof wanted: a no-token/low-token child fixture that attempts a
  known denied operation and records the denial path.
- `UNVERIFIED` - Native Hermes durable artifacts: identify where, if anywhere,
  native child transcripts/logs are stored outside the parent session DB, and
  whether operators can inspect them after parent exit.
- `UNVERIFIED` - Native Hermes per-dispatch model: this session verifies no
  per-call `model`/`provider` field in `delegate_task`; proof wanted from Hermes
  source/docs if another hidden surface exists. Otherwise document "global pin
  only" as the contract.
- `GAP` - Native Hermes worktree isolation: `delegate_task` does not create a
  worktree. If native Hermes workers are expected to edit code independently,
  add a wrapper/brief convention that creates or assigns a worktree before the
  child writes.
- `UNVERIFIED` - Hermes one-shot transcript path: `invoke.sh` exposes `--log`,
  but this draft did not verify the exact Hermes session transcript path for
  one-shots. Proof wanted: run a harmless one-shot and record the session id/path.
- `GAP` - Hermes one-shot timeout/watchdog: `invoke.sh` intentionally has no
  internal timeout. If used for unattended work rather than CR pings, the caller
  must wrap it in an external timeout/supervisor.
- `UNVERIFIED` - External Claude Code worker push/PR policy outside GLM:
  `run.ts` does not have the GLM push tripwire. Proof wanted: identify every
  caller that passes worktree/branch briefs into bounded Claude runs and whether
  those briefs prohibit push/PR.
- `GAP` - Permission-window parity (**HIMMEL-748**): bounded Claude/GLM runs close
  stdin and cannot answer prompts; vault runs use `bypassPermissions`; Codex and
  Hermes one-shots use different approval paths. Need one matrix of which prompts
  can appear, which are auto-approved/denied, and which stall.
- `GAP` - Startup context parity: Codex has `startup-health.sh`; GLM has prompt
  window preflight; Hermes one-shot/native subagents do not have a comparable
  startup-context degradation detector documented here.
- `GAP` - Codex direct guard proofs (**HIMMEL-745**): `lane-parity.md` still marks
  codex-direct write-authority / external-write through-adapter proof as `GAP`.
  Need e2e proof that the Codex adapter blocks the external-write shapes, not
  only that the native guard scripts and adapter unit path exist.
- `UNVERIFIED` - Codex worker per-dispatch model: the inspected supervision files
  do not document model selection. Proof wanted from the actual codex dispatch
  command/config used by the fleet.
- `UNVERIFIED` - Codex worktree isolation: the inspected files document branch
  provenance and supervision, not the dispatcher that creates or assigns Codex
  worktrees. Proof wanted from the fleet dispatcher or dynamic lane registry.
- `GAP` - Dynamic lane registry (**HIMMEL-689**): this matrix is static. A living
  registry should name each lane, dispatcher command, model selector, guard proof,
  artifact root, and liveness probe so orchestrators do not route by stale prose.
- `UNVERIFIED` - `external Claude Code worker` row is represented here by the
  Telegram bounded-run launcher because that is the concrete external Claude
  worker path read for this task. If there is another non-Telegram Claude worker
  dispatcher, add it as a separate row with its own artifact and authority proof.

## Approval-window / permission contract (HIMMEL-748 — ratified 2026-07-07)

Operator-ratified decision: **no hermes-native auto-classifier.** Only Claude
Code carries a native semantic classifier; the fleet does not re-implement a
weaker copy. The lane contract is deterministic-guard + escalation + post-hoc
validation:

1. **hermes (native subagent AND one-shot):** `parity_guard.py`
   (`pre_tool_call`, deny-JSON, fail-closed) is the ONLY decision layer;
   `approvals.mode` never substitutes for it. A parity_guard denial is final
   for the worker — the worker escalates via its report channel and continues.
   `delegation.subagent_auto_approve` stays `false`.
2. **hermes-spawned Claude Code / GLM workers:** the worker inherits the
   CLAUDE-side decision stack (hooks + settings allow-list + classifier where
   the lane has one). hermes MUST NOT proxy or re-answer the worker's
   permission prompts. Bounded workers run stdin-closed: an un-allowlisted
   prompt is a deterministic denial, surfaced as an outbox escalation line
   (`{"type":"escalation",...}`, the HIMMEL-314/682 grants contract), never a
   stall.
3. **Approval-window UX term:** a hermes approval window for a SPAWN shows the
   lane, branch, and toolset/grant list — the policy surface — not raw command
   text. Approving a spawn approves its declared grant envelope, nothing more.
4. **Post-hoc validation stays load-bearing:** the parent session reviews the
   branch diff + outbox/artifacts before any push/PR (single-writer ship flow).

Evidence note (codex-direct, HIMMEL-745 probe 2026-07-07): the deterministic
hook path denied a patch-tool write on a main checkout, while a terminal-path
write (`pwsh Set-Content`) went through — the fix for such gaps is structural
(extend the hook matcher to the terminal tool), not a classifier copy, which
is exactly the posture this contract locks in.
